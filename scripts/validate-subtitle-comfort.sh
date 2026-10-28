#!/bin/bash
# Isolated compile and local audio/SRT fixtures. Does not use SwiftPM or open a window.
set -euo pipefail
cd "$(dirname "$0")/.."
report="${1:-docs/validation/v0.4.1/subtitle-comfort-green.json}"
validation_directory=$(mktemp -d "${TMPDIR:-/tmp/}cinema-subtitle-comfort.XXXXXX")
trap 'rm -rf "$validation_directory"' EXIT
mkdir -p "$validation_directory/core" "$(dirname "$report")"
cat > "$validation_directory/embedded.srt" <<'SRT'
1
00:00:00,000 --> 00:00:25,000
Native subtitle fixture
SRT
# Two native tracks with distinct language identities, built entirely offline.
ffmpeg -hide_banner -loglevel error -f lavfi -i 'color=c=black:s=160x90:r=1:d=30' \
  -i "$validation_directory/embedded.srt" -map 0:v -map 1:s -map 1:s -c:v libx264 -c:s mov_text \
  -metadata:s:s:0 language=eng -metadata:s:s:1 language=zho -y "$validation_directory/embedded.mp4"
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macos15.0" -emit-module -emit-library -static -module-name CinemaCore \
  Sources/CinemaCore/*.swift -emit-module-path "$validation_directory/core/CinemaCore.swiftmodule" -o "$validation_directory/core/libCinemaCore.a"
xcrun swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos15.0" \
  -I "$validation_directory/core" -L "$validation_directory/core" -lCinemaCore \
  Sources/CinemaApp/PlaybackController.swift Sources/CinemaApp/DirectProgressiveResourceLoader.swift Sources/CinemaApp/PlaybackDisplaySleepGuard.swift Sources/CinemaApp/QualityPerformanceController.swift Sources/CinemaApp/FrameInterpolator.swift Sources/CinemaApp/InterpolatedFramePipeline.swift Sources/CinemaApp/EnhancementPipeline.swift Sources/CinemaApp/CompressionCleaner.swift Sources/CinemaApp/TemporalRestorer.swift Sources/CinemaApp/DetailScaler.swift \
  Sources/CinemaApp/MediaExperienceInspector.swift Sources/CinemaApp/VideoProcessingPolicy.swift Sources/CinemaApp/AdSkipController.swift Sources/CinemaApp/AdFrameAnalyzer.swift \
  Tests/AppModelSmoke/SubtitleComfortSmoke.swift -o "$validation_directory/check"
status=0
"$validation_directory/check" --validate "$validation_directory" > "$report" || status=$?
cat "$report"
exit "$status"
