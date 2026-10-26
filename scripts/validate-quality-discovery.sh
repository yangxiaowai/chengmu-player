#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
destination="${1:-docs/validation/v0.4.0/ui}"
work=$(mktemp -d "${TMPDIR:-/tmp/}chengmu-quality-ui.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$destination"
swiftc -emit-module -emit-library -static -module-name CinemaCore -swift-version 5 -target arm64-apple-macos15.0 Sources/CinemaCore/*.swift -emit-module-path "$work/CinemaCore.swiftmodule" -o "$work/libCinemaCore.a"
sources=()
for source in Sources/CinemaApp/*.swift; do [[ "$source" == */CinemaApp.swift ]] || sources+=("$source"); done
swiftc -parse-as-library -swift-version 5 -target arm64-apple-macos15.0 -I "$work" -L "$work" -lCinemaCore "${sources[@]}" Tests/AppModelSmoke/QualityDiscoverySmoke.swift -o "$work/check"
ffmpeg -v error -f lavfi -i 'color=c=0x17252f:s=960x540:r=24:d=3' -c:v libx264 -pix_fmt yuv420p -movflags +faststart "$work/player.mp4"
YINGCHUAN_PROFILE_DIRECTORY="$work/profile" "$work/check" "$destination" "$work/player.mp4" --validate
