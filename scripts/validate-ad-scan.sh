#!/bin/bash
# Isolated native OCR/AVFoundation tests; fixture encoders are not application dependencies.
set -euo pipefail
cd "$(dirname "$0")/.."
report="${1:-docs/validation/v0.2.8/ad-scan-green.json}"
mode="${2:-green}"
fixture_dir=$(mktemp -d "${TMPDIR:-/tmp/}cinema-ad-scan.XXXXXX")
server_pid=""
cleanup() { if [[ -n "$server_pid" ]]; then kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; fi; rm -rf "$fixture_dir"; }
trap cleanup EXIT
mkdir -p "$(dirname "$report")" "$fixture_dir/hls"
swiftc -emit-module -emit-library -module-name CinemaCore -swift-version 5 -target arm64-apple-macos15.0 Sources/CinemaCore/*.swift -o "$fixture_dir/libCinemaCore.dylib" -emit-module-path "$fixture_dir/CinemaCore.swiftmodule"
if [[ "$mode" == "red" ]]; then
  swiftc -D AD_SCAN_BASELINE -parse-as-library -swift-version 5 -target arm64-apple-macos15.0 -I "$fixture_dir" -L "$fixture_dir" -lCinemaCore -Xlinker -rpath -Xlinker "$fixture_dir" scripts/validation/ad-scan/main.swift -o "$fixture_dir/check"
  "$fixture_dir/check" "$fixture_dir" "http://127.0.0.1:1/ordinary.m3u8" "$report"
  exit
fi
swiftc -parse-as-library -swift-version 5 scripts/validation/ad-scan/fixtures.swift -o "$fixture_dir/create-fixtures"
"$fixture_dir/create-fixtures" "$fixture_dir"
for kind in ordinary advertisement subtitle corner brand; do
  ffmpeg -hide_banner -loglevel error -loop 1 -i "$fixture_dir/$kind.png" -f lavfi -i 'sine=frequency=220:sample_rate=48000' -t 3 -vf 'fps=24,format=yuv420p' -c:v libx264 -preset ultrafast -crf 18 -g 24 -sc_threshold 0 -c:a aac -movflags +faststart "$fixture_dir/$kind.mp4"
done
ffmpeg -hide_banner -loglevel error -loop 1 -t 16 -i "$fixture_dir/ordinary.png" -loop 1 -t 12 -i "$fixture_dir/advertisement.png" -loop 1 -t 12 -i "$fixture_dir/ordinary.png" -f lavfi -i 'sine=frequency=220:sample_rate=48000' -filter_complex '[0:v][1:v][2:v]concat=n=3:v=1:a=0,fps=24,format=yuv420p[v]' -map '[v]' -map 3:a -t 40 -c:v libx264 -preset ultrafast -crf 18 -g 24 -sc_threshold 0 -c:a aac -movflags +faststart "$fixture_dir/sequence.mp4"
mkdir -p .build
cp "$fixture_dir/sequence.mp4" .build/ad-skip-fixture.mp4
cat > .build/ad-skip-fixture.srt <<'SRT'
1
00:00:00,000 --> 00:00:15,999
正常剧情字幕：广告前

2
00:00:16,000 --> 00:00:27,999
广告时段字幕：保留原时间轴

3
00:00:28,000 --> 00:00:40,000
正常剧情字幕：广告后
SRT
ffmpeg -hide_banner -loglevel error -i "$fixture_dir/sequence.mp4" -c copy -hls_time 1 -hls_list_size 0 -hls_segment_filename "$fixture_dir/hls/segment-%03d.ts" "$fixture_dir/hls/ordinary.m3u8"
python3 - "$fixture_dir/hls" "$fixture_dir/port" > "$fixture_dir/http.log" 2>&1 <<'PY' &
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from functools import partial
from pathlib import Path
import sys
server = ThreadingHTTPServer(('127.0.0.1', 0), partial(SimpleHTTPRequestHandler, directory=sys.argv[1]))
Path(sys.argv[2]).write_text(str(server.server_port))
server.serve_forever()
PY
server_pid=$!
for _ in $(seq 1 100); do [[ -s "$fixture_dir/port" ]] && break; sleep 0.02; done
port=$(cat "$fixture_dir/port")
swiftc -parse-as-library -swift-version 5 -target arm64-apple-macos15.0 -I "$fixture_dir" -L "$fixture_dir" -lCinemaCore -Xlinker -rpath -Xlinker "$fixture_dir" Sources/CinemaApp/AdFrameAnalyzer.swift Sources/CinemaApp/AdSkipController.swift scripts/validation/ad-scan/main.swift -o "$fixture_dir/check"
"$fixture_dir/check" "$fixture_dir" "http://127.0.0.1:$port/ordinary.m3u8" "$report"
