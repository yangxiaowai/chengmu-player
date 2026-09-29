#!/bin/bash
# Sequential, equal-scale film restoration assessment. No SwiftPM state is shared.
# Usage: bash scripts/validate-restoration-film.sh [report.json] [fixture-directory]
# Set FILM_VALIDATION_COMPILE_ONLY=1 to compile without using the GPU.
set -euo pipefail
cd "$(dirname "$0")/.."
report="${1:-docs/validation/restoration-film/report.json}"
fixtures="${2:-.build/restoration-lab}"
work=$(mktemp -d "${TMPDIR:-/tmp/}yingchuan-film-validation.XXXXXX")
trap 'rm -rf "$work"' EXIT
swiftc -emit-module -emit-library -module-name CinemaCore -swift-version 5 -target arm64-apple-macos26.0 \
    Sources/CinemaCore/*.swift -o "$work/libCinemaCore.dylib" -emit-module-path "$work/CinemaCore.swiftmodule"
swiftc -O -parse-as-library -swift-version 5 -target arm64-apple-macos26.0 \
    -I "$work" -L "$work" -lCinemaCore -Xlinker -rpath -Xlinker "$work" \
    Sources/CinemaApp/EnhancementPipeline.swift Sources/CinemaApp/TemporalRestorer.swift Sources/CinemaApp/DetailScaler.swift scripts/validation/restoration-film/main.swift \
    -o "$work/check"
if [[ "${FILM_VALIDATION_COMPILE_ONLY:-0}" == "1" ]]; then
    echo "Film assessment compiled; GPU execution intentionally deferred."
    exit 0
fi
mkdir -p "$(dirname "$report")"
"$work/check" "$report" "$fixtures"
