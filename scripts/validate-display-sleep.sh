#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
report="${1:-docs/validation/v0.3.8/display-sleep.json}"
work=$(mktemp -d "${TMPDIR:-/tmp/}chengmu-display-sleep.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$(dirname "$report")"
ffmpeg -hide_banner -loglevel error -f lavfi -i 'testsrc2=size=320x180:rate=24:duration=8' -c:v libx264 -preset ultrafast -pix_fmt yuv420p -x264-params 'colorprim=bt709:transfer=bt709:colormatrix=bt709' -movflags +write_colr -y "$work/video.mp4"
swiftc -emit-module -emit-library -static -module-name CinemaCore -swift-version 5 -target arm64-apple-macos15.0 Sources/CinemaCore/*.swift -emit-module-path "$work/CinemaCore.swiftmodule" -o "$work/libCinemaCore.a"
extra=()
if [[ -f Sources/CinemaApp/PlaybackDisplaySleepGuard.swift ]]; then extra+=(Sources/CinemaApp/PlaybackDisplaySleepGuard.swift); fi
swiftc -parse-as-library -swift-version 5 -target arm64-apple-macos15.0 -I "$work" -L "$work" -lCinemaCore \
  Sources/CinemaApp/PlaybackController.swift Sources/CinemaApp/DirectProgressiveResourceLoader.swift "${extra[@]}" Sources/CinemaApp/QualityPerformanceController.swift Sources/CinemaApp/FrameInterpolator.swift Sources/CinemaApp/InterpolatedFramePipeline.swift Sources/CinemaApp/EnhancementPipeline.swift Sources/CinemaApp/CompressionCleaner.swift Sources/CinemaApp/TemporalRestorer.swift Sources/CinemaApp/DetailScaler.swift Sources/CinemaApp/MediaExperienceInspector.swift Sources/CinemaApp/VideoProcessingPolicy.swift Sources/CinemaApp/AdSkipController.swift Sources/CinemaApp/AdFrameAnalyzer.swift Tests/AppModelSmoke/DisplaySleepSmoke.swift -o "$work/check"
"$work/check" "$work/video.mp4" "$report" --validate
