#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
report="${1:-docs/validation/v0.4.0/quality-queue.json}"
work=$(mktemp -d "${TMPDIR:-/tmp/}chengmu-quality-queue.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$(dirname "$report")"
swiftc -emit-module -emit-library -static -module-name CinemaCore -swift-version 5 -target arm64-apple-macos15.0 Sources/CinemaCore/*.swift -emit-module-path "$work/CinemaCore.swiftmodule" -o "$work/libCinemaCore.a"
swiftc -parse-as-library -swift-version 5 -target arm64-apple-macos15.0 -I "$work" -L "$work" -lCinemaCore Sources/CinemaApp/MediaQualityController.swift Tests/AppModelSmoke/MediaQualityQueueSmoke.swift -o "$work/check"
"$work/check" "$report"
