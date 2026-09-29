#!/bin/bash
# Reproduces "4K cannot be turned on": the picture switch must never silently swallow a mode choice.
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d "${TMPDIR:-/tmp/}cinema-picture-switch.XXXXXX")
trap 'rm -rf "$work"' EXIT
swiftc -emit-module -emit-library -module-name CinemaCore -swift-version 5 -target arm64-apple-macos15.0 Sources/CinemaCore/*.swift -o "$work/libCinemaCore.dylib" -emit-module-path "$work/CinemaCore.swiftmodule"
swiftc -parse-as-library -swift-version 5 -target arm64-apple-macos15.0 -I "$work" -L "$work" -lCinemaCore -Xlinker -rpath -Xlinker "$work" \
  Sources/CinemaApp/PlaybackController.swift Sources/CinemaApp/QualityPerformanceController.swift Sources/CinemaApp/FrameInterpolator.swift Sources/CinemaApp/InterpolatedFramePipeline.swift Sources/CinemaApp/VideoProcessingPolicy.swift Sources/CinemaApp/EnhancementPipeline.swift Sources/CinemaApp/CompressionCleaner.swift Sources/CinemaApp/TemporalRestorer.swift Sources/CinemaApp/DetailScaler.swift Sources/CinemaApp/AdSkipController.swift \
  Sources/CinemaApp/AdFrameAnalyzer.swift Sources/CinemaApp/MediaExperienceInspector.swift \
  Tests/AppModelSmoke/PicturePipelineSwitchSmoke.swift -o "$work/check"
"$work/check"
