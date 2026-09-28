#!/bin/bash
# Actual native causal restoration, deterministic synthetic frames, no application or network.
set -euo pipefail
cd "$(dirname "$0")/.."
report="${1:-docs/validation/temporal-restoration/report.json}"
work=$(mktemp -d "${TMPDIR:-/tmp/}cinema-temporal-restoration.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$(dirname "$report")"
swiftc -O -parse-as-library -swift-version 5 -target arm64-apple-macos15.0 Sources/CinemaApp/TemporalRestorer.swift scripts/validation/temporal-restoration/main.swift -o "$work/check"
"$work/check" "$report"
