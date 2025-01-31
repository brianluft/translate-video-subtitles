import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

@MainActor
public class SubtitleOverlayRenderer {
    public struct Style: Sendable {
        public let font: Font
        public let textColor: Color
        public let backgroundColor: Color
        public let cornerRadius: CGFloat
        public let padding: EdgeInsets

        public static let `default` = Style(
            font: .system(size: 16, weight: .medium),
            textColor: .white,
            backgroundColor: Color.black.opacity(0.7),
            cornerRadius: 4,
            padding: EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
        )

        public init(
            font: Font,
            textColor: Color,
            backgroundColor: Color,
            cornerRadius: CGFloat,
            padding: EdgeInsets
        ) {
            self.font = font
            self.textColor = textColor
            self.backgroundColor = backgroundColor
            self.cornerRadius = cornerRadius
            self.padding = padding
        }
    }

    private let style: Style
    private var textSizeCache: [String: CGSize] = [:]

    public init(style: Style = .default) {
        self.style = style
    }

    private func measureText(_ text: String) -> CGSize {
        if let cached = textSizeCache[text] {
            return cached
        }

        #if os(iOS)
        let systemFont = UIFont.systemFont(ofSize: 16, weight: .medium)
        #else
        let systemFont = NSFont.systemFont(ofSize: 16, weight: .medium)
        #endif

        let size = (text as NSString).boundingRect(
            with: CGSize(width: CGFloat.infinity, height: CGFloat.infinity),
            options: [.usesLineFragmentOrigin],
            attributes: [.font: systemFont],
            context: nil
        ).size

        // Add padding
        let paddedSize = CGSize(
            width: size.width + style.padding.leading + style.padding.trailing,
            height: size.height + style.padding.top + style.padding.bottom
        )

        textSizeCache[text] = paddedSize
        return paddedSize
    }

    private func adjustPosition(
        _ originalPosition: CGPoint,
        size: CGSize,
        in bounds: CGSize,
        avoiding occupiedRects: inout [CGRect]
    ) -> CGPoint {
        var position = originalPosition

        // Create rect for this subtitle
        let rect = CGRect(
            x: position.x - size.width / 2,
            y: position.y - size.height / 2,
            width: size.width,
            height: size.height
        )

        // Keep subtitle on screen
        if rect.minX < 0 {
            position.x = size.width / 2
        } else if rect.maxX > bounds.width {
            position.x = bounds.width - size.width / 2
        }

        if rect.minY < 0 {
            position.y = size.height / 2
        } else if rect.maxY > bounds.height {
            position.y = bounds.height - size.height / 2
        }

        // Avoid overlaps by shifting vertically
        var adjustedRect = CGRect(
            x: position.x - size.width / 2,
            y: position.y - size.height / 2,
            width: size.width,
            height: size.height
        )

        while occupiedRects.contains(where: { $0.intersects(adjustedRect) }) {
            // Try moving up first since subtitles are usually at bottom
            position.y -= size.height + 4 // Add small gap

            // If moving up puts us off screen, try moving down instead
            if position.y - size.height / 2 < 0 {
                position.y = originalPosition.y + size.height + 4
            }

            adjustedRect = CGRect(
                x: position.x - size.width / 2,
                y: position.y - size.height / 2,
                width: size.width,
                height: size.height
            )
        }

        occupiedRects.append(adjustedRect)
        return position
    }

    public func createSubtitleOverlay(for segments: [(segment: TextSegment, text: String)]) -> some View {
        GeometryReader { geometry in
            ZStack {
                ForEach(segments, id: \.segment.id) { [self] segment in
                    let textSize = measureText(segment.text)
                    let originalPosition = CGPoint(
                        x: segment.segment.position.midX * geometry.size.width,
                        y: segment.segment.position.midY * geometry.size.height
                    )

                    // Store and adjust positions to prevent overlaps
                    var occupiedRects: [CGRect] = []
                    let adjustedPosition = adjustPosition(
                        originalPosition,
                        size: textSize,
                        in: geometry.size,
                        avoiding: &occupiedRects
                    )

                    Text(segment.text)
                        .font(style.font)
                        .foregroundColor(style.textColor)
                        .padding(style.padding)
                        .background(style.backgroundColor)
                        .cornerRadius(style.cornerRadius)
                        .position(adjustedPosition)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
