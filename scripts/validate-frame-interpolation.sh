#!/bin/bash
# True VT motion interpolation and 60 Hz timestamp-grid checks, isolated from SwiftPM.
set -euo pipefail
cd "$(dirname "$0")/.."
report="${1:-docs/validation/v0.3.4/frame-interpolation.json}"
work=$(mktemp -d "${TMPDIR:-/tmp/}cinema-frame-interpolation.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$(dirname "$report")"
swiftc -emit-module -emit-library -module-name CinemaCore -swift-version 5 -target arm64-apple-macos26.0 Sources/CinemaCore/*.swift -o "$work/libCinemaCore.dylib" -emit-module-path "$work/CinemaCore.swiftmodule"
swiftc -O -swift-version 5 -target arm64-apple-macos26.0 -I "$work" -L "$work" -lCinemaCore -Xlinker -rpath -Xlinker "$work" Sources/CinemaApp/VideoProcessingPolicy.swift Sources/CinemaApp/DetailScaler.swift Sources/CinemaApp/TemporalRestorer.swift Sources/CinemaApp/EnhancementPipeline.swift Sources/CinemaApp/CompressionCleaner.swift Sources/CinemaApp/FrameInterpolator.swift Sources/CinemaApp/InterpolatedFramePipeline.swift scripts/validation/frame-interpolation/main.swift -o "$work/check"
"$work/check" "$report"
