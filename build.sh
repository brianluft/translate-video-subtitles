#!/bin/zsh
set -uo pipefail
set +e

NUM_CORES=$(sysctl -n hw.ncpu)
if [ -z "$NUM_CORES" ]; then
  echo "sysctl failed to get number of cores"
  exit 1
fi

echo "--- Copy Assets ---"
(cd assets && ./copy.sh 2>&1) > log
EXIT_CODE=$?
if [ $EXIT_CODE -ne 0 ]; then
  cat log
  echo "assets/copy.sh failed with exit code $EXIT_CODE"
  exit 1
fi

echo "--- BuildTools Resolve ---"
(cd BuildTools && NSUnbufferedIO=YES swift package resolve 2>&1) > log
EXIT_CODE=$?
if [ $EXIT_CODE -ne 0 ]; then
  cat log
  echo "swift package resolve failed with exit code $EXIT_CODE"
  exit 1
fi

echo "--- Build SwiftFormat ---"
(cd BuildTools && NSUnbufferedIO=YES swift build -q -c release --product swiftformat 2>&1) > log
EXIT_CODE=$?
if [ $EXIT_CODE -ne 0 ]; then
  cat log
  echo "swift build failed with exit code $EXIT_CODE"
  exit 1
fi

SWIFTFORMAT=$(find BuildTools/.build -type f -name swiftformat | grep apple-macosx | grep -v dSYM | grep release)
if [ -z "$SWIFTFORMAT" ]; then
  echo "swiftformat not found"
  exit 1
fi

echo "--- Clean ---"
NSUnbufferedIO=YES xcodebuild clean -quiet -workspace TranslateVideoSubtitles.xcworkspace -scheme TranslateVideoSubtitles -configuration Debug -destination 'generic/platform=iOS Simulator' 2>&1 > log
EXIT_CODE=$?
if [ $EXIT_CODE -ne 0 ]; then
  cat log
  echo "xcodebuild clean failed with exit code $EXIT_CODE"
  exit 1
fi

(cd VideoSubtitlesLib && rm -rf .build)

echo "--- Format ---"
($SWIFTFORMAT . 2>&1) > log
EXIT_CODE=$?
if [ $EXIT_CODE -ne 0 ]; then
  cat log
  echo "swiftformat failed with exit code $EXIT_CODE"
  exit 1
fi

echo "--- Build ---"
NSUnbufferedIO=YES xcodebuild -quiet -workspace TranslateVideoSubtitles.xcworkspace -scheme TranslateVideoSubtitles -configuration Debug -destination 'generic/platform=iOS Simulator' -jobs $NUM_CORES 2>&1
EXIT_CODE=$?
if [ $EXIT_CODE -ne 0 ]; then
  echo "xcodebuild failed with exit code $EXIT_CODE"
  exit 1
fi

echo "--- Test ---"
(cd VideoSubtitlesLib && NSUnbufferedIO=YES swift test -q -j $NUM_CORES 2>&1) | grep -v '^\[' | grep -v "^Test Case.*started" | grep -v '^Test.*passed'
EXIT_CODE=$?
if [ $EXIT_CODE -ne 0 ]; then
  echo "swift test failed with exit code $EXIT_CODE"
  exit 1
fi

echo "--- Lint ---"
swift package --package-path BuildTools --allow-writing-to-package-directory swiftlint --quiet --config ../.swiftlint.yml ..
EXIT_CODE=$?
if [ $EXIT_CODE -ne 0 ]; then
  echo "swiftlint failed with exit code $EXIT_CODE"
  exit 1
fi

echo "===SUCCESS==="
