#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
report="${1:-docs/validation/v0.3.6/compression-cleaner.json}"
mode="${2:-green}"
# Optional third argument: directory containing the 480x200 RGBA32F temporal exports.
work=$(mktemp -d "${TMPDIR:-/tmp/}cinema-compression-cleaner.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$(dirname "$report")"
flags=(); extra=(Sources/CinemaApp/CompressionCleaner.swift)
if [[ "$mode" == red ]]; then flags=(-D CLEANER_BASELINE); fi
swiftc -emit-module -emit-library -module-name CinemaCore -swift-version 5 -target arm64-apple-macos15.0 Sources/CinemaCore/*.swift -o "$work/libCinemaCore.dylib" -emit-module-path "$work/CinemaCore.swiftmodule"
swiftc -O -parse-as-library -swift-version 5 -target arm64-apple-macos15.0 -I "$work" -L "$work" -lCinemaCore -Xlinker -rpath -Xlinker "$work" "${flags[@]}" Sources/CinemaApp/VideoProcessingPolicy.swift Sources/CinemaApp/TemporalRestorer.swift Sources/CinemaApp/DetailScaler.swift Sources/CinemaApp/EnhancementPipeline.swift "${extra[@]}" scripts/validation/compression-cleaner/main.swift -o "$work/check"
if [[ $# -ge 3 ]]; then
    "$work/check" "$report" "$3"
else
    "$work/check" "$report"
fi
