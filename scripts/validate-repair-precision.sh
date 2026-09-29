#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
report="${1:-docs/validation/v0.3.5/repair-precision.json}"
sources="${2:-Sources/CinemaApp}"
work=$(mktemp -d "${TMPDIR:-/tmp/}cinema-repair-precision.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$(dirname "$report")"
swiftc -emit-module -emit-library -module-name CinemaCore -swift-version 5 -target arm64-apple-macos15.0 Sources/CinemaCore/*.swift -o "$work/libCinemaCore.dylib" -emit-module-path "$work/CinemaCore.swiftmodule"
swiftc -O -parse-as-library -swift-version 5 -target arm64-apple-macos15.0 -I "$work" -L "$work" -lCinemaCore -Xlinker -rpath -Xlinker "$work" Sources/CinemaApp/TemporalRestorer.swift "$sources/DetailScaler.swift" Sources/CinemaApp/VideoProcessingPolicy.swift "$sources/EnhancementPipeline.swift" Sources/CinemaApp/CompressionCleaner.swift scripts/validation/repair-precision/main.swift -o "$work/check"
"$work/check" "$report"
