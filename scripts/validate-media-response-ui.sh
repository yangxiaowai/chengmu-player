#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
destination="${1:-docs/validation/v0.4.3/ui}"
work=$(mktemp -d "${TMPDIR:-/tmp/}chengmu-response-ui.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$destination" "$work/core"
swiftc -emit-module -emit-library -static -module-name CinemaCore -swift-version 5 -target arm64-apple-macos15.0 Sources/CinemaCore/*.swift -emit-module-path "$work/core/CinemaCore.swiftmodule" -o "$work/core/libCinemaCore.a"
sources=()
for source in Sources/CinemaApp/*.swift; do [[ "$source" == */CinemaApp.swift ]] || sources+=("$source"); done
swiftc -parse-as-library -swift-version 5 -target arm64-apple-macos15.0 -I "$work/core" -L "$work/core" -lCinemaCore "${sources[@]}" Tests/AppModelSmoke/MediaResponseUISmoke.swift -o "$work/check"
YINGCHUAN_PROFILE_DIRECTORY="$work/profile" "$work/check" "$destination" --validate
