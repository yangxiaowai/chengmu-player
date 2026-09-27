#!/bin/bash
# Compile the GPU pixel regression against an already-built CinemaCore. No package build is triggered.
set -euo pipefail
cd "$(dirname "$0")/.."
core_products="${1:-.build/out/Products/Release}"
if [[ ! -f "$core_products/CinemaCore.o" ]]; then
  printf 'Build CinemaCore first; expected %s/CinemaCore.o\n' "$core_products" >&2
  exit 1
fi
validation_directory=$(mktemp -d "${TMPDIR:-/tmp/}cinema-ad-pixels.XXXXXX")
trap 'rm -rf "$validation_directory"' EXIT
swiftc -swift-version 5 -target arm64-apple-macos15.0 -I "$core_products" \
  Sources/CinemaApp/EnhancementPipeline.swift Sources/CinemaApp/VideoSurface.swift \
  scripts/validation/ad-cleanup-pixels/main.swift "$core_products/CinemaCore.o" \
  -o "$validation_directory/check"
"$validation_directory/check"
