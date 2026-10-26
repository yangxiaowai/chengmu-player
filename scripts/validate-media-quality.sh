#!/bin/bash
# Development fixtures use ffmpeg; the app's probe depends only on AVFoundation.
set -euo pipefail
cd "$(dirname "$0")/.."
report_dir="${1:-docs/validation/v0.4.0}"
mkdir -p "$report_dir"
report_dir="$(cd "$report_dir" && pwd)"
probe_dir=$(mktemp -d "${TMPDIR:-/tmp/}cinema-media-quality.XXXXXX")
server_pid=""
cleanup() {
  if [ -n "$server_pid" ]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -rf "$probe_dir"
}
trap cleanup EXIT
command -v ffmpeg >/dev/null
ffmpeg -v error -f lavfi -i 'testsrc2=size=640x360:rate=24' -t 1 -c:v libx264 -pix_fmt yuv420p -movflags +faststart "$probe_dir/landscape.mp4"
ffmpeg -v error -display_rotation 90 -i "$probe_dir/landscape.mp4" -c copy "$probe_dir/portrait-rotation.mp4"
ffmpeg -v error -i "$probe_dir/landscape.mp4" -c copy -hls_time 1 -hls_segment_filename "$probe_dir/local%03d.ts" -f hls "$probe_dir/local.m3u8"
sed 's/local000.ts/hang-hls-timeout.ts/' "$probe_dir/local.m3u8" > "$probe_dir/stall-timeout.m3u8"
sed 's/local000.ts/hang-hls-cancel.ts/' "$probe_dir/local.m3u8" > "$probe_dir/stall-cancel.m3u8"
cp "$probe_dir/landscape.mp4" "$probe_dir/claimed-4K.mp4"
ffmpeg -v error -f lavfi -i 'sine=frequency=440:sample_rate=48000' -t 0.2 -c:a aac "$probe_dir/audio-only.m4a"
printf 'not a video\n' > "$probe_dir/bad.mp4"

conda run -n searchformoney --no-capture-output python -u - "$probe_dir" "$report_dir/backend-http-events.jsonl" <<'PY' &
import http.server
import json
import pathlib
import re
import socket
import sys
import threading
import time

fixtures = pathlib.Path(sys.argv[1])
events = pathlib.Path(sys.argv[2])
events.write_text('')
lock = threading.Lock()

def record(kind, path):
    with lock:
        with events.open('a') as stream:
            stream.write(json.dumps({'event': kind, 'path': path, 'time': time.time()}) + '\n')

class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(fixtures), **kwargs)
    def log_message(self, *args):
        pass
    def do_GET(self):
        if not self.path.startswith('/hang-'):
            source = fixtures / pathlib.Path(self.path).name
            if not source.is_file():
                return self.send_error(404)
            payload = source.read_bytes()
            start, end = 0, len(payload) - 1
            match = re.fullmatch(r'bytes=(\d*)-(\d*)', self.headers.get('Range', ''))
            if match:
                if match[1]:
                    start = int(match[1])
                    end = min(int(match[2]), end) if match[2] else end
                elif match[2]:
                    start = max(0, len(payload) - int(match[2]))
                if start > end or start >= len(payload):
                    self.send_response(416)
                    self.send_header('Content-Range', f'bytes */{len(payload)}')
                    self.end_headers()
                    return
            self.send_response(206 if match else 200)
            self.send_header('Content-Type', 'application/vnd.apple.mpegurl' if source.suffix == '.m3u8' else 'video/mp2t' if source.suffix == '.ts' else 'video/mp4')
            self.send_header('Accept-Ranges', 'bytes')
            self.send_header('Content-Length', str(end - start + 1))
            if match:
                self.send_header('Content-Range', f'bytes {start}-{end}/{len(payload)}')
            self.end_headers()
            self.wfile.write(payload[start:end + 1])
            return
        record('accepted', self.path)
        self.connection.settimeout(0.1)
        # Accept the request, send no response bytes, and observe actual close.
        while True:
            try:
                if not self.connection.recv(4096):
                    record('disconnected', self.path)
                    return
            except socket.timeout:
                continue
            except (ConnectionResetError, OSError):
                record('disconnected', self.path)
                return

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
(fixtures / 'server-port').write_text(str(server.server_port))
server.serve_forever()
PY
server_pid=$!
for attempt in {1..100}; do
  if [ -s "$probe_dir/server-port" ]; then break; fi
  if ! kill -0 "$server_pid" 2>/dev/null; then echo "Fixture server failed" >&2; exit 1; fi
  sleep 0.1
done
test -s "$probe_dir/server-port"
port=$(cat "$probe_dir/server-port")
xcrun swiftc -parse-as-library -swift-version 5 -target arm64-apple-macos15.0 \
  Sources/CinemaCore/MediaQualityProbe.swift scripts/validation/media-quality/main.swift -o "$probe_dir/probe"
"$probe_dir/probe" "$probe_dir" "http://127.0.0.1:$port" "$report_dir/backend-media-quality.json" \
  | tee "$report_dir/backend-media-quality.log"

conda run -n searchformoney --no-capture-output python - "$report_dir/backend-http-events.jsonl" <<'PY'
import json
import pathlib
import sys
import time

path = pathlib.Path(sys.argv[1])
for _ in range(20):
    rows = [json.loads(line) for line in path.read_text().splitlines()]
    if all(any(row['event'] == 'disconnected' and row['path'] == name for row in rows)
           for name in ['/hang-timeout.mp4', '/hang-cancel.mp4', '/hang-hls-timeout.ts', '/hang-hls-cancel.ts']):
        break
    time.sleep(0.05)
else:
    raise SystemExit('AVFoundation did not release both stalled HTTP reads')
for name in ['/hang-timeout.mp4', '/hang-cancel.mp4', '/hang-hls-timeout.ts', '/hang-hls-cancel.ts']:
    accepted = next(row['time'] for row in rows if row['event'] == 'accepted' and row['path'] == name)
    disconnected = next(row['time'] for row in rows if row['event'] == 'disconnected' and row['path'] == name)
    assert disconnected - accepted < 2, (name, disconnected - accepted)
print('PASS: server observed all stalled asset/HLS connections close within 2 seconds')
PY
