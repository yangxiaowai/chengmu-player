#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
report="${1:-docs/validation/v0.3.4/quality-performance.json}"
work=$(mktemp -d "${TMPDIR:-/tmp/}cinema-quality-performance.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$(dirname "$report")"
swiftc -emit-module -emit-library -module-name CinemaCore -swift-version 5 -target arm64-apple-macos15.0 Sources/CinemaCore/*.swift -o "$work/libCinemaCore.dylib" -emit-module-path "$work/CinemaCore.swiftmodule"
swiftc -O -parse-as-library -swift-version 5 -target arm64-apple-macos15.0 -I "$work" -L "$work" -lCinemaCore -Xlinker -rpath -Xlinker "$work" \
    Sources/CinemaApp/VideoProcessingPolicy.swift Sources/CinemaApp/EnhancementPipeline.swift Sources/CinemaApp/CompressionCleaner.swift \
    Sources/CinemaApp/TemporalRestorer.swift Sources/CinemaApp/DetailScaler.swift \
    Sources/CinemaApp/FrameInterpolator.swift Sources/CinemaApp/InterpolatedFramePipeline.swift \
    Sources/CinemaApp/QualityPerformanceController.swift scripts/validation/quality-performance/main.swift -o "$work/check"
"$work/check" "$report"
