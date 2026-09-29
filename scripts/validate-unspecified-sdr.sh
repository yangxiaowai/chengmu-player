#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
report="${1:-.build/unspecified-sdr/green.json}"
mode="${2:-green}"
fixture_dir=$(mktemp -d "${TMPDIR:-/tmp/}cinema-unspecified-sdr.XXXXXX")
server_pid=""
cleanup() { if [[ -n "$server_pid" ]]; then kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; fi; }
trap cleanup EXIT
mkdir -p "$(dirname "$report")" "$fixture_dir/hls"
for name in unspecified reference unspecified-srgb reference-srgb; do
  primaries=undef
  primaries_code=2
  transfer=bt709
  [[ "$name" == reference* ]] && primaries=bt709
  [[ "$name" == reference* ]] && primaries_code=1
  [[ "$name" == *-srgb ]] && transfer=iec61966-2-1
  ffmpeg -hide_banner -loglevel error -f lavfi -i 'smptebars=size=320x180:rate=24:duration=2' -c:v libx264 -preset ultrafast -x264-params "colorprim=$primaries:transfer=$transfer:colormatrix=bt709" -color_primaries "$primaries_code" -color_trc "$transfer" -colorspace bt709 -pix_fmt yuv420p -g 24 -movflags +write_colr -y "$fixture_dir/$name.mp4"
done
for name in unspecified reference; do
  ffmpeg -hide_banner -loglevel error -i "$fixture_dir/$name-srgb.mp4" -c copy -hls_time 1 -hls_list_size 0 -hls_segment_filename "$fixture_dir/hls/$name-%03d.ts" "$fixture_dir/hls/$name.m3u8"
done
python3 - "$fixture_dir/hls" "$fixture_dir/port" > "$fixture_dir/http.log" 2>&1 <<'PY' &
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from functools import partial
from pathlib import Path
import sys
server = ThreadingHTTPServer(('127.0.0.1', 0), partial(SimpleHTTPRequestHandler, directory=sys.argv[1]))
Path(sys.argv[2]).write_text(str(server.server_port)); server.serve_forever()
PY
server_pid=$!
for _ in $(seq 1 100); do [[ -s "$fixture_dir/port" ]] && break; sleep 0.02; done
flags=()
policy="Sources/CinemaApp/VideoProcessingPolicy.swift"
if [[ "$mode" == red ]]; then
  flags=(-D UNSPECIFIED_SDR_BASELINE)
  policy="$fixture_dir/VideoProcessingPolicyBaseline.swift"
  git show HEAD:Sources/CinemaApp/VideoProcessingPolicy.swift > "$policy"
fi
swiftc "${flags[@]}" -parse-as-library -swift-version 5 -target arm64-apple-macos15.0 -I .build/out/Products/Debug -L .build/out/Products/Debug -lCinemaCore "$policy" scripts/validation/unspecified-sdr/main.swift -o "$fixture_dir/check"
"$fixture_dir/check" "$fixture_dir" "$report" "http://127.0.0.1:$(cat "$fixture_dir/port")/unspecified.m3u8"
