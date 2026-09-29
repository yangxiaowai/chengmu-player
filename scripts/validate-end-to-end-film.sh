#!/bin/bash
# Two real production pipelines, identical sequential decoded film buffers.
# END_TO_END_FILM_COMPILE_ONLY=1 compiles without GPU use and retains executable.
set -euo pipefail
cd "$(dirname "$0")/.."
report="${1:-docs/validation/v0.3.6/end-to-end-film.json}"
fixtures="${2:-.build/restoration-lab}"
resolutions="${3:-source}"
work=".build/repair-v036/end-to-end-film"
mkdir -p "$work" "$(dirname "$report")"
swiftc -emit-module -emit-library -module-name CinemaCore -swift-version 5 -target arm64-apple-macos26.0 \
    Sources/CinemaCore/*.swift -o "$work/libCinemaCore.dylib" -emit-module-path "$work/CinemaCore.swiftmodule"
swiftc -O -parse-as-library -swift-version 5 -target arm64-apple-macos26.0 \
    -I "$work" -L "$work" -lCinemaCore -Xlinker -rpath -Xlinker "$(pwd)/$work" \
    Sources/CinemaApp/VideoProcessingPolicy.swift Sources/CinemaApp/EnhancementPipeline.swift \
    Sources/CinemaApp/CompressionCleaner.swift Sources/CinemaApp/TemporalRestorer.swift \
    Sources/CinemaApp/DetailScaler.swift docs/validation/v0.3.6/end-to-end-film.swift \
    -o "$work/check"
if [[ "${END_TO_END_FILM_COMPILE_ONLY:-0}" == "1" ]]; then
    echo "End-to-end film compiled. GPU execution deferred; executable: $work/check"
    exit 0
fi
"$work/check" "$report" "$fixtures" "$resolutions"
