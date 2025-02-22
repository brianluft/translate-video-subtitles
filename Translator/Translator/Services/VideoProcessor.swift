import AVFoundation
import Foundation
import os
import PhotosUI
import SwiftUI
import Translation

/// Specifies which method to use for detecting text in videos
public enum DetectionMode {
    /// Use OCR to detect burned-in subtitles
    case subtitles
    /// Use speech recognition to detect spoken words
    case speech
}

/// This class is responsible for handling the video processing logic.
/// It is responsible for detecting subtitles or speech, translating them, and saving the processed video.
@MainActor
final class VideoProcessor {
    // MARK: - Instance Properties

    @Published var progress: Double = 0
    @Published var showError: Bool = false
    @Published var errorMessage: String = ""
    @Published var processingComplete: Bool = false
    @Published var readyToPlay: Bool = false

    var processedVideo: ProcessedMedia

    private var _isCancelled = false
    var isCancelled: Bool {
        get async {
            await MainActor.run { _isCancelled }
        }
    }

    private var processingStartTime: TimeInterval = 0
    private var detector: (any TextDetector)?
    private var translator: TranslationService?
    private var cancellationTask: Task<Void, Never>?

    private let sourceLanguage: Locale.Language
    private let destinationLanguage: Locale.Language
    private let detectionMode: DetectionMode

    init(sourceLanguage: Locale.Language, processedVideo: ProcessedMedia, detectionMode: DetectionMode = .subtitles) {
        self.sourceLanguage = sourceLanguage
        self.processedVideo = processedVideo
        self.detectionMode = detectionMode
        // For consistency, we preserve the idea of the "current language" as the destination
        self.destinationLanguage = Locale.current.language
    }

    func processVideo(_ item: PhotosPickerItem, translationSession: TranslationSession) async {
        processingStartTime = ProcessInfo.processInfo.systemUptime
        // Create a task we can wait on during cancellation
        cancellationTask = Task { @MainActor in
            do {
                // Check for cancellation before starting
                if await isCancelled {
                    return
                }

                // Load video from PhotosPickerItem
                guard let videoData = try await item.loadTransferable(type: Data.self) else {
                    throw NSError(
                        domain: "VideoProcessing",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to load video data"]
                    )
                }

                // Create directory if needed
                try? FileManager.default.createDirectory(
                    at: TempFileManager.temporaryVideoDirectory,
                    withIntermediateDirectories: true
                )

                // Save to temporary file
                let tempURL = TempFileManager.temporaryVideoDirectory.appendingPathComponent(UUID().uuidString + ".mov")
                try videoData.write(to: tempURL)

                // Create AVAsset
                let asset = AVURLAsset(url: tempURL)

                // Get video size
                var videoSize: CGSize?
                if let tracks = try? await asset.loadTracks(withMediaType: .video),
                   let track = tracks.first {
                    if let size = try? await track.load(.naturalSize),
                       let transform = try? await track.load(.preferredTransform) {
                        videoSize = size.applying(transform)
                        videoSize = CGSize(width: abs(videoSize?.width ?? 0), height: abs(videoSize?.height ?? 0))
                    }
                }

                processedVideo.updateVideo(url: tempURL, size: videoSize)

                // Initialize processing components with Sendable closures
                let detectionDelegate = DetectionDelegate(
                    progressHandler: { [weak self] progress in
                        Task { @MainActor [weak self] in
                            self?.handleDetectionProgress(progress: progress)
                        }
                    },
                    frameHandler: { [weak self] frame in
                        Task { @MainActor [weak self] in
                            self?.handleDetectionFrame(frame)
                        }
                    },
                    didComplete: { [weak self] in
                        Task { @MainActor [weak self] in
                            self?.handleDetectionComplete()
                        }
                    },
                    didFail: { [weak self] error in
                        Task { @MainActor [weak self] in
                            self?.handleDetectionFail(error: error)
                        }
                    }
                )

                let translationDelegate = TranslationDelegate(
                    progressHandler: { [weak self] progress in
                        Task { @MainActor [weak self] in
                            self?.handleTranslationProgress(progress: progress)
                        }
                    },
                    didComplete: { [weak self] in
                        Task { @MainActor [weak self] in
                            self?.handleTranslationComplete()
                        }
                    },
                    didFail: { [weak self] error in
                        Task { @MainActor [weak self] in
                            self?.handleTranslationFail(error: error)
                        }
                    }
                )

                translator = TranslationService(
                    session: translationSession,
                    delegate: translationDelegate,
                    target: destinationLanguage
                )

                // Create appropriate detector based on mode
                detector = try await createDetector(
                    for: asset,
                    delegate: detectionDelegate,
                    translationService: translator
                )

                // Detect text
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    Task { @MainActor in
                        do {
                            if let detector {
                                try await withThrowingTaskGroup(of: Void.self) { group in
                                    group.addTask {
                                        let shouldContinue = await !(self.isCancelled)
                                        if shouldContinue {
                                            try await detector.detectText()
                                        }
                                    }
                                    _ = try await group.next()
                                }

                                let shouldComplete = await !(self.isCancelled)
                                if shouldComplete {
                                    continuation.resume()
                                } else {
                                    continuation.resume(throwing: CancellationError())
                                }
                            } else {
                                continuation.resume(throwing: NSError(
                                    domain: "VideoProcessing",
                                    code: -1,
                                    userInfo: [NSLocalizedDescriptionKey: "Detector not initialized"]
                                ))
                            }
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }

            } catch {
                showError = true
                errorMessage = error.localizedDescription
            }
        }

        // Wait for the processing task to complete
        await cancellationTask?.value
    }

    private func createDetector(
        for asset: AVAsset,
        delegate: TextDetectionDelegate,
        translationService: TranslationService?
    ) async throws -> any TextDetector {
        switch detectionMode {
        case .subtitles:
            return SubtitleTextDetector(
                videoAsset: asset,
                delegate: delegate,
                recognitionLanguages: [sourceLanguage.languageCode?.identifier ?? "en-US"],
                translationService: translationService
            )
        case .speech:
            return try SpokenTextDetector(
                videoAsset: asset,
                delegate: delegate,
                recognitionLocale: Locale(identifier: sourceLanguage.languageCode?.identifier ?? "en_US"),
                translationService: translationService
            )
        }
    }

    func processVideo(_ url: URL, translationSession: TranslationSession) async {
        processingStartTime = ProcessInfo.processInfo.systemUptime
        // Create a task we can wait on during cancellation
        cancellationTask = Task { @MainActor in
            do {
                // Check for cancellation before starting
                if await isCancelled {
                    return
                }

                // Create directory if needed
                try? FileManager.default.createDirectory(
                    at: TempFileManager.temporaryVideoDirectory,
                    withIntermediateDirectories: true
                )

                // Copy to temporary file
                let tempURL = TempFileManager.temporaryVideoDirectory.appendingPathComponent(UUID().uuidString + ".mov")
                try FileManager.default.copyItem(at: url, to: tempURL)

                // Create AVAsset
                let asset = AVURLAsset(url: tempURL)

                // Get video size
                var videoSize: CGSize?
                if let tracks = try? await asset.loadTracks(withMediaType: .video),
                   let track = tracks.first {
                    if let size = try? await track.load(.naturalSize),
                       let transform = try? await track.load(.preferredTransform) {
                        videoSize = size.applying(transform)
                        videoSize = CGSize(width: abs(videoSize?.width ?? 0), height: abs(videoSize?.height ?? 0))
                    }
                }

                processedVideo.updateVideo(url: tempURL, size: videoSize)

                // Initialize processing components with Sendable closures
                let detectionDelegate = DetectionDelegate(
                    progressHandler: { [weak self] progress in
                        Task { @MainActor [weak self] in
                            self?.handleDetectionProgress(progress: progress)
                        }
                    },
                    frameHandler: { [weak self] frame in
                        Task { @MainActor [weak self] in
                            self?.handleDetectionFrame(frame)
                        }
                    },
                    didComplete: { [weak self] in
                        Task { @MainActor [weak self] in
                            self?.handleDetectionComplete()
                        }
                    },
                    didFail: { [weak self] error in
                        Task { @MainActor [weak self] in
                            self?.handleDetectionFail(error: error)
                        }
                    }
                )

                let translationDelegate = TranslationDelegate(
                    progressHandler: { [weak self] progress in
                        Task { @MainActor [weak self] in
                            self?.handleTranslationProgress(progress: progress)
                        }
                    },
                    didComplete: { [weak self] in
                        Task { @MainActor [weak self] in
                            self?.handleTranslationComplete()
                        }
                    },
                    didFail: { [weak self] error in
                        Task { @MainActor [weak self] in
                            self?.handleTranslationFail(error: error)
                        }
                    }
                )

                translator = TranslationService(
                    session: translationSession,
                    delegate: translationDelegate,
                    target: destinationLanguage
                )

                // Create appropriate detector based on mode
                detector = try await createDetector(
                    for: asset,
                    delegate: detectionDelegate,
                    translationService: translator
                )

                // Detect text
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    Task { @MainActor in
                        do {
                            if let detector {
                                try await withThrowingTaskGroup(of: Void.self) { group in
                                    group.addTask {
                                        let shouldContinue = await !(self.isCancelled)
                                        if shouldContinue {
                                            try await detector.detectText()
                                        }
                                    }
                                    _ = try await group.next()
                                }

                                let shouldComplete = await !(self.isCancelled)
                                if shouldComplete {
                                    continuation.resume()
                                } else {
                                    continuation.resume(throwing: CancellationError())
                                }
                            } else {
                                continuation.resume(throwing: NSError(
                                    domain: "VideoProcessing",
                                    code: -1,
                                    userInfo: [NSLocalizedDescriptionKey: "Detector not initialized"]
                                ))
                            }
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }

            } catch {
                showError = true
                errorMessage = error.localizedDescription
            }
        }

        // Wait for the processing task to complete
        await cancellationTask?.value
    }

    func cancelProcessing() async {
        await MainActor.run { _isCancelled = true }

        // Cancel any ongoing detection
        detector?.cancelDetection()

        // Cancel any ongoing translation
        translator?.cancelTranslation()

        // Wait for any ongoing tasks to complete
        if let task = cancellationTask {
            await task.value
        }

        // Clean up temporary video file
        try? FileManager.default.removeItem(at: processedVideo.currentURL)
    }

    // MARK: - Detection Delegate Handlers

    private func handleDetectionProgress(progress: Float) {
        self.progress = Double(progress) // Use full progress range for detection
    }

    private func handleDetectionComplete() {
        Task { @MainActor in
            processingComplete = true
            readyToPlay = true
        }
    }

    private func handleDetectionFail(error: Error) {
        showError = true
        errorMessage = error.localizedDescription
    }

    private func handleDetectionFrame(_ frame: FrameSegments) {
        Task { @MainActor in
            let currentTime = ProcessInfo.processInfo.systemUptime
            let elapsedTime = currentTime - processingStartTime
            let processingRate = frame.timestamp / elapsedTime

            if frame.timestamp >= 5.0 && processingRate > 1.0 {
                readyToPlay = true
            }

            processedVideo.appendFrameSegments([frame])
        }
    }

    // MARK: - Translation Delegate Handlers

    private func handleTranslationProgress(progress: Float) {
        // Translation progress no longer affects the progress bar
    }

    private func handleTranslationComplete() {
        // Handled in detection complete when creating ProcessedMedia
    }

    private func handleTranslationFail(error: Error) {
        showError = true
        errorMessage = error.localizedDescription
    }
}

// MARK: - Delegate Wrappers

private final class DetectionDelegate: TextDetectionDelegate, @unchecked Sendable {
    private let progressHandler: @Sendable (Float) -> Void
    private let frameHandler: @Sendable (FrameSegments) -> Void
    private let completionHandler: @Sendable () -> Void
    private let failureHandler: @Sendable (Error) -> Void

    init(
        progressHandler: @escaping @Sendable (Float) -> Void,
        frameHandler: @escaping @Sendable (FrameSegments) -> Void,
        didComplete: @escaping @Sendable () -> Void,
        didFail: @escaping @Sendable (Error) -> Void
    ) {
        self.progressHandler = progressHandler
        self.frameHandler = frameHandler
        completionHandler = didComplete
        failureHandler = didFail
    }

    func detectionDidProgress(_ progress: Float) {
        progressHandler(progress)
    }

    func detectionDidReceiveFrame(_ frame: FrameSegments) {
        frameHandler(frame)
    }

    func detectionDidComplete() {
        completionHandler()
    }

    func detectionDidFail(with error: Error) {
        failureHandler(error)
    }
}

private final class TranslationDelegate: TranslationProgressDelegate, @unchecked Sendable {
    private let progressHandler: @Sendable (Float) -> Void
    private let completionHandler: @Sendable () -> Void
    private let failureHandler: @Sendable (Error) -> Void

    init(
        progressHandler: @escaping @Sendable (Float) -> Void,
        didComplete: @escaping @Sendable () -> Void,
        didFail: @escaping @Sendable (Error) -> Void
    ) {
        self.progressHandler = progressHandler
        completionHandler = didComplete
        failureHandler = didFail
    }

    func translationDidProgress(_ progress: Float) async {
        progressHandler(progress)
    }

    func translationDidComplete() async {
        completionHandler()
    }

    func translationDidFail(with error: Error) async {
        failureHandler(error)
    }
}
