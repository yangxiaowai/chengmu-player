#!/bin/bash
# Independent compile and offscreen AppKit fixture; no user UI or SwiftPM lock.
# Optional second argument selects a recorded Git baseline for reproducible red runs.
set -euo pipefail
cd "$(dirname "$0")/.."
report="${1:-docs/validation/v0.2.7/control-visibility-green.json}"
source_ref="${2:-}"
validation_directory=$(mktemp -d "${TMPDIR:-/tmp/}cinema-control-visibility.XXXXXX")
trap 'rm -rf "$validation_directory"' EXIT
mkdir -p "$validation_directory/core" "$(dirname "$report")"
if [[ -n "$source_ref" ]]; then
  git show "$source_ref:Sources/CinemaApp/PlayerPresentationController.swift" > "$validation_directory/PlayerPresentationController.swift"
  git show "$source_ref:Sources/CinemaCore/FullscreenControlsPolicy.swift" > "$validation_directory/FullscreenControlsPolicy.swift"
else
  cp Sources/CinemaApp/PlayerPresentationController.swift "$validation_directory/PlayerPresentationController.swift"
  if [[ -f Sources/CinemaCore/PlaybackControlsPolicy.swift ]]; then
    cp Sources/CinemaCore/PlaybackControlsPolicy.swift "$validation_directory/FullscreenControlsPolicy.swift"
  else
    cp Sources/CinemaCore/FullscreenControlsPolicy.swift "$validation_directory/FullscreenControlsPolicy.swift"
  fi
fi
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macos15.0" -emit-module -emit-library -static -module-name CinemaCore \
  "$validation_directory/FullscreenControlsPolicy.swift" \
  -emit-module-path "$validation_directory/core/CinemaCore.swiftmodule" -o "$validation_directory/core/libCinemaCore.a"
xcrun swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos15.0" \
  -I "$validation_directory/core" -L "$validation_directory/core" -lCinemaCore \
  "$validation_directory/PlayerPresentationController.swift" Tests/AppModelSmoke/ControlVisibilitySmoke.swift \
  -o "$validation_directory/check"
validation_status=0
CINEMA_VISIBILITY_SOURCE="${source_ref:-working-tree}" "$validation_directory/check" --validate > "$report" || validation_status=$?
cat "$report"
exit "$validation_status"
