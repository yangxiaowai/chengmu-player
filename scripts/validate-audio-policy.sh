#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
validation_directory=$(mktemp -d "${TMPDIR:-/tmp/}cinema-audio-policy.XXXXXX")
trap 'rm -rf "$validation_directory"' EXIT
mkdir -p "$validation_directory/core"
xcrun swiftc -swift-version 5 -target arm64-apple-macos15.0 -emit-module -emit-library -static -module-name CinemaCore Sources/CinemaCore/*.swift -emit-module-path "$validation_directory/core/CinemaCore.swiftmodule" -o "$validation_directory/core/libCinemaCore.a"
# Compile the real colour policy without creating a Metal surface.
xcrun swiftc -parse-as-library -swift-version 5 -target arm64-apple-macos15.0 -I "$validation_directory/core" -L "$validation_directory/core" -lCinemaCore Sources/CinemaApp/PlaybackController.swift Sources/CinemaApp/QualityPerformanceController.swift Sources/CinemaApp/FrameInterpolator.swift Sources/CinemaApp/InterpolatedFramePipeline.swift Sources/CinemaApp/VideoProcessingPolicy.swift Sources/CinemaApp/EnhancementPipeline.swift Sources/CinemaApp/CompressionCleaner.swift Sources/CinemaApp/TemporalRestorer.swift Sources/CinemaApp/DetailScaler.swift Sources/CinemaApp/AdSkipController.swift Sources/CinemaApp/AdFrameAnalyzer.swift Sources/CinemaApp/MediaExperienceInspector.swift scripts/validation/media-experience/audio-policy.swift -o "$validation_directory/check"
"$validation_directory/check" --validate
