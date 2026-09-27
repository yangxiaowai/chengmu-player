#!/bin/bash
# Exercise the real private native slider without showing or activating a window.
set -euo pipefail
cd "$(dirname "$0")/.."
report="${1:-docs/validation/v0.2.4/seek-bar-interaction.json}"
validation_directory=$(mktemp -d "${TMPDIR:-/tmp/}cinema-seek-bar.XXXXXX")
cleanup() { rm -rf "$validation_directory"; }
trap cleanup EXIT
mkdir -p "$(dirname "$report")"
python3 - "$validation_directory/Interaction.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Sources/CinemaApp/SeekBar.swift').read_text()
marker = 'private struct TimelineLocation'
if source.count(marker) != 1:
    raise SystemExit('SeekBar native section moved; update the test extraction explicitly.')
native = source[source.index(marker):]
test = Path('Tests/AppModelSmoke/SeekBarInteractionSmoke.swift').read_text()
Path(sys.argv[1]).write_text('import Foundation\nimport AppKit\n' + native + '\n' + test)
PY
xcrun swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos15.0" \
  Sources/CinemaCore/SeekTimelineGeometry.swift "$validation_directory/Interaction.swift" \
  -o "$validation_directory/check"
"$validation_directory/check" > "$report"
cat "$report"
