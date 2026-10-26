#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
destination="${1:-docs/validation/v0.4.2/ui}"
work=$(mktemp -d "${TMPDIR:-/tmp/}chengmu-series-history.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$destination" "$work/core"
ffmpeg -hide_banner -loglevel error -f lavfi -i 'color=c=black:s=160x90:r=1:d=30' -c:v libx264 -y "$work/1.mp4"
cp "$work/1.mp4" "$work/2.mp4"
cp "$work/1.mp4" "$work/3.mp4"
swiftc -emit-module -emit-library -static -module-name CinemaCore -swift-version 5 -target arm64-apple-macos15.0 Sources/CinemaCore/*.swift -emit-module-path "$work/core/CinemaCore.swiftmodule" -o "$work/core/libCinemaCore.a"
sources=()
for source in Sources/CinemaApp/*.swift; do [[ "$source" == */CinemaApp.swift ]] || sources+=("$source"); done
swiftc -parse-as-library -swift-version 5 -target arm64-apple-macos15.0 -I "$work/core" -L "$work/core" -lCinemaCore "${sources[@]}" Tests/AppModelSmoke/SeriesHistorySmoke.swift -o "$work/check"
YINGCHUAN_PROFILE_DIRECTORY="$work/profile" "$work/check" "$destination" "$work" --validate
