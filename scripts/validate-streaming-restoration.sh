#!/bin/bash
# Validate the real production enhancement pipeline with isolated synthetic SDR frames.
set -euo pipefail
cd "$(dirname "$0")/.."
report="${1:-docs/validation/restoration/streaming-pipeline.json}"
work=$(mktemp -d "${TMPDIR:-/tmp/}cinema-streaming-restoration.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$(dirname "$report")"
swiftc -emit-module -emit-library -module-name CinemaCore -swift-version 5 -target arm64-apple-macos15.0 Sources/CinemaCore/*.swift -o "$work/libCinemaCore.dylib" -emit-module-path "$work/CinemaCore.swiftmodule"
swiftc -O -parse-as-library -swift-version 5 -target arm64-apple-macos15.0 -I "$work" -L "$work" -lCinemaCore -Xlinker -rpath -Xlinker "$work" Sources/CinemaApp/TemporalRestorer.swift Sources/CinemaApp/EnhancementPipeline.swift scripts/validation/streaming-restoration/main.swift -o "$work/check"
"$work/check" "$report"
