#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
report="${1:-.build/preview-frame-accuracy.json}"
work=$(mktemp -d "${TMPDIR:-/tmp/}chengmu-preview-accuracy.XXXXXX")
server_pid=""
cleanup() { if [[ -n "$server_pid" ]]; then kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; fi; rm -rf "$work"; }
trap cleanup EXIT
mkdir -p "$work/hls" "$(dirname "$report")"
ffmpeg -hide_banner -loglevel error \
  -f lavfi -i 'color=c=red:s=320x180:r=24:d=4' \
  -f lavfi -i 'color=c=0x00ff00:s=320x180:r=24:d=4' \
  -f lavfi -i 'color=c=blue:s=320x180:r=24:d=4' \
  -f lavfi -i 'color=c=yellow:s=320x180:r=24:d=4' \
  -f lavfi -i 'anullsrc=channel_layout=stereo:sample_rate=48000' \
  -filter_complex '[0:v][1:v][2:v][3:v]concat=n=4:v=1:a=0[v]' -map '[v]' -map 4:a -t 16 \
  -c:v libx264 -preset ultrafast -g 24 -keyint_min 24 -sc_threshold 0 -pix_fmt yuv420p -c:a aac -movflags +faststart "$work/colors.mp4"
cp "$work/colors.mp4" "$work/hls/colors.mp4"
ffmpeg -hide_banner -loglevel error -display_rotation 90 -i "$work/colors.mp4" -map 0 -c copy "$work/hls/rotated.mp4"
ffmpeg -hide_banner -loglevel error -i "$work/colors.mp4" -c copy -hls_time 1 -hls_list_size 0 \
  -hls_segment_filename "$work/hls/segment-%03d.ts" "$work/hls/colors.m3u8"
python3 - "$work/hls" "$work/port" > "$work/http.log" 2>&1 <<'PY' &
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from functools import partial
from pathlib import Path
import sys,time
class Handler(SimpleHTTPRequestHandler):
    def serve_opaque(self, body=True):
        name = {'/opaque-mp4': 'colors.mp4', '/opaque-rotated': 'rotated.mp4'}.get(self.path)
        if name is None: return False
        data = Path(sys.argv[1]).joinpath(name).read_bytes()
        total = len(data)
        start, end = 0, total - 1
        request_range = self.headers.get('Range')
        if request_range:
            bounds = request_range.removeprefix('bytes=').split('-')
            start = int(bounds[0] or 0)
            end = min(int(bounds[1]) if bounds[1] else end, end)
            self.send_response(206)
            self.send_header('Content-Range', f'bytes {start}-{end}/{total}')
        else: self.send_response(200)
        self.send_header('Content-Type', 'video/mp4')
        self.send_header('Accept-Ranges', 'bytes')
        self.send_header('Content-Length', str(end - start + 1))
        self.end_headers()
        if body:
            try: self.wfile.write(data[start:end+1])
            except (BrokenPipeError, ConnectionResetError): pass
        return True
    def do_HEAD(self):
        if not self.serve_opaque(False): super().do_HEAD()
    def do_GET(self):
        if self.serve_opaque(): return
        if self.path.startswith('/segment-01') and Path(sys.argv[2]).parent.joinpath('delay-enabled').exists():
            Path(sys.argv[2]).parent.joinpath('delayed-segment-requested').write_text('started')
            time.sleep(3)
        if self.path == '/slow.m3u8':
            time.sleep(4.8)
            self.path = '/colors.m3u8'
        super().do_GET()
server = ThreadingHTTPServer(('127.0.0.1', 0), partial(Handler, directory=sys.argv[1]))
Path(sys.argv[2]).write_text(str(server.server_port))
server.serve_forever()
PY
server_pid=$!
for _ in $(seq 1 100); do [[ -s "$work/port" ]] && break; sleep 0.02; done
port=$(cat "$work/port")
swiftc -parse-as-library -swift-version 5 -target arm64-apple-macos15.0 \
  Sources/CinemaApp/DirectHLSRelay.swift Sources/CinemaApp/SeekPreviewController.swift \
  Tests/AppModelSmoke/PreviewFrameAccuracySmoke.swift -o "$work/check"
"$work/check" "$work/colors.mp4" "http://127.0.0.1:$port/colors.m3u8" "$report" "$work"
