#!/bin/bash
# Perceptual regression fixtures: compare equal display sizes against known clean pixels.
# Usage: bash scripts/validate-picture-quality.sh [report.json] [EnhancementPipeline.swift] [displayWidth]
set -euo pipefail
cd "$(dirname "$0")/.."
report="${1:-docs/validation/picture-quality/report.json}"
pipeline="${2:-Sources/CinemaApp/EnhancementPipeline.swift}"
display_width="${3:-960}"
work=$(mktemp -d "${TMPDIR:-/tmp/}cinema-picture-quality.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$(dirname "$report")"
swiftc -emit-module -emit-library -module-name CinemaCore -swift-version 5 -target arm64-apple-macos15.0 Sources/CinemaCore/*.swift -o "$work/libCinemaCore.dylib" -emit-module-path "$work/CinemaCore.swiftmodule"
swiftc -O -parse-as-library -swift-version 5 -target arm64-apple-macos15.0 -I "$work" -L "$work" -lCinemaCore -Xlinker -rpath -Xlinker "$work" "$pipeline" Sources/CinemaApp/TemporalRestorer.swift scripts/validation/picture-quality/main.swift -o "$work/check"
"$work/check" "$report" "$pipeline" "$display_width"
