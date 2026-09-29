#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
report="${1:-docs/validation/v0.2.8/ad-skip-playback.json}"
validation_directory=$(mktemp -d "${TMPDIR:-/tmp/}cinema-ad-playback.XXXXXX")
trap 'rm -rf "$validation_directory"' EXIT
mkdir -p "$validation_directory/core" "$(dirname "$report")"
test -f .build/ad-skip-fixture.mp4
test -f .build/ad-skip-fixture.srt
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macos15.0" -emit-module -emit-library -static -module-name CinemaCore \
  Sources/CinemaCore/*.swift -emit-module-path "$validation_directory/core/CinemaCore.swiftmodule" -o "$validation_directory/core/libCinemaCore.a"
xcrun swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos15.0" \
  -I "$validation_directory/core" -L "$validation_directory/core" -lCinemaCore \
  Sources/CinemaApp/PlaybackController.swift Sources/CinemaApp/QualityPerformanceController.swift Sources/CinemaApp/FrameInterpolator.swift Sources/CinemaApp/InterpolatedFramePipeline.swift Sources/CinemaApp/EnhancementPipeline.swift Sources/CinemaApp/CompressionCleaner.swift Sources/CinemaApp/TemporalRestorer.swift Sources/CinemaApp/DetailScaler.swift \
  Sources/CinemaApp/MediaExperienceInspector.swift Sources/CinemaApp/VideoProcessingPolicy.swift \
  Sources/CinemaApp/AdSkipController.swift Sources/CinemaApp/AdFrameAnalyzer.swift \
  Tests/AppModelSmoke/AdSkipPlaybackSmoke.swift -o "$validation_directory/check"
validation_status=0
"$validation_directory/check" "$PWD/.build/ad-skip-fixture.mp4" "$PWD/.build/ad-skip-fixture.srt" --validate > "$report" || validation_status=$?
cat "$report"
exit "$validation_status"
