#!/bin/bash
# Headless AVFoundation regression. ffmpeg/Python are fixture tools, not application dependencies.
set -euo pipefail
cd "$(dirname "$0")/.."
sample="${1:-}"
report="${2:-docs/validation/v0.2.4/seek-preview-headless.json}"
validation_directory=$(mktemp -d "${TMPDIR:-/tmp/}cinema-seek-preview.XXXXXX")
server_pid=""
cleanup() {
  if [[ -n "$server_pid" ]]; then kill "$server_pid" 2>/dev/null || true; fi
  rm -rf "$validation_directory"
}
trap cleanup EXIT
mkdir -p "$validation_directory/hls" "$(dirname "$report")"
if [[ -z "$sample" ]]; then
  sample="$validation_directory/synthetic-preview.mp4"
  ffmpeg -hide_banner -loglevel error -f lavfi -i "testsrc2=size=960x540:rate=24:duration=30" \
    -c:v libx264 -preset ultrafast -crf 20 -pix_fmt yuv420p \
    -g 24 -keyint_min 24 -sc_threshold 0 -movflags +faststart "$sample"
fi
ffmpeg -hide_banner -loglevel error -i "$sample" -c copy -hls_time 1 -hls_list_size 0 -hls_segment_filename "$validation_directory/hls/segment-%03d.ts" "$validation_directory/hls/ordinary.m3u8"
ffmpeg -hide_banner -loglevel error -display_rotation 90 -i "$sample" -c copy "$validation_directory/rotated.mp4"
python3 - "$validation_directory/hls" "$validation_directory/port" > "$validation_directory/http.log" 2>&1 <<'PY' &
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from functools import partial
from pathlib import Path
import sys
server = ThreadingHTTPServer(('127.0.0.1', 0), partial(SimpleHTTPRequestHandler, directory=sys.argv[1]))
Path(sys.argv[2]).write_text(str(server.server_port))
server.serve_forever()
PY
server_pid=$!
for _ in $(seq 1 100); do
  if [[ -s "$validation_directory/port" ]]; then break; fi
  sleep 0.02
done
port=$(cat "$validation_directory/port")
swiftc -parse-as-library -swift-version 5 -target arm64-apple-macos15.0 \
  Sources/CinemaApp/SeekPreviewController.swift scripts/validation/seek-preview/main.swift \
  -o "$validation_directory/check"
"$validation_directory/check" "$sample" "http://127.0.0.1:$port/ordinary.m3u8" "$validation_directory/rotated.mp4" "$report"
