#!/bin/bash
# Uses the existing CinemaCore product; never invokes SwiftPM or controls user UI.
set -euo pipefail
cd "$(dirname "$0")/.."
report="${1:-docs/validation/v0.2.6/episode-source-green.json}"
validation_directory=$(mktemp -d "${TMPDIR:-/tmp/}cinema-episode-source.XXXXXX")
trap 'rm -rf "$validation_directory"' EXIT
core_directory=".build/out/Products/Debug"
if [[ ! -e "$core_directory/libCinemaCore.a" ]]; then
  echo "Existing Debug CinemaCore build required; this script does not rebuild it." >&2
  exit 2
fi
mkdir -p "$(dirname "$report")"
xcrun swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos15.0" \
  -I "$core_directory" -L "$core_directory" -lCinemaCore \
  Sources/CinemaApp/AppModel.swift Sources/CinemaApp/SourceAccessController.swift \
  Sources/CinemaApp/PlaybackController.swift Sources/CinemaApp/EnhancementPipeline.swift Sources/CinemaApp/TemporalRestorer.swift Sources/CinemaApp/DetailScaler.swift \
  Sources/CinemaApp/AdSkipController.swift Sources/CinemaApp/AdFrameAnalyzer.swift \
  Tests/AppModelSmoke/EpisodeSourceInteractionSmoke.swift -o "$validation_directory/check"
validation_status=0
"$validation_directory/check" --validate > "$report" || validation_status=$?
cat "$report"
exit "$validation_status"
