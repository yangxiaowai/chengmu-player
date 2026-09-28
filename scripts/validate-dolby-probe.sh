#!/bin/bash
# Reads public official HLS metadata and runs one independent muted player for at most 20 seconds.
set -euo pipefail
cd "$(dirname "$0")/.."
report="${1:-docs/validation/v0.2.9/official-dolby-probe.json}"
probe_dir=$(mktemp -d "${TMPDIR:-/tmp/}cinema-dolby-probe.XXXXXX")
trap 'rm -rf "$probe_dir"' EXIT
mkdir -p "$(dirname "$report")"
xcrun swiftc -parse-as-library -swift-version 5 -target arm64-apple-macos15.0 scripts/validation/dolby-probe/main.swift -o "$probe_dir/probe"
"$probe_dir/probe" "$report"
