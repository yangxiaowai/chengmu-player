#!/bin/bash
# Independent pixel and completed-GPU checks; never invokes the shared SwiftPM build.
set -euo pipefail
cd "$(dirname "$0")/.."
report="${1:-.build/detail-scale-probe/independent-validation.json}"
source_path="${2:-Sources/CinemaApp/DetailScaler.swift}"
if [[ $# -lt 2 && ! -f "$source_path" ]]; then source_path=".build/detail-scale-probe/DetailScaler.swift"; fi
[[ -f "$source_path" ]] || { echo "Missing scaler source: $source_path" >&2; exit 1; }
work=$(mktemp -d "${TMPDIR:-/tmp/}cinema-detail-scaling.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$(dirname "$report")"
swiftc -O -parse-as-library -swift-version 5 -target arm64-apple-macos15.0 "$source_path" Sources/CinemaApp/TemporalRestorer.swift scripts/validation/detail-scaling/main.swift -o "$work/check"
"$work/check" "$report" "$source_path"
