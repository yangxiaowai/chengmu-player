#!/bin/bash
# Run through conda searchformoney: Python is a local test server only.
set -euo pipefail
cd "$(dirname "$0")/.."
report="${1:-.build/playable-media-http.json}"
work=$(mktemp -d "${TMPDIR:-/tmp/}cinema-playable-media.XXXXXX")
server_pid=""
cleanup() { if [[ -n "$server_pid" ]]; then kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; fi; rm -rf "$work"; }
trap cleanup EXIT
mkdir -p "$work/core" "$(dirname "$report")"
ffmpeg -hide_banner -loglevel error -f lavfi -i 'testsrc2=size=160x90:rate=8:duration=1' -c:v libx264 -movflags +faststart "$work/fixture.mp4"
python3 - "$work" > "$work/server.log" 2>&1 <<'PY' &
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Lock
import json, sys, time
p = Path(sys.argv[1]); media = (p / 'fixture.mp4').read_bytes() + bytes(2 * 1024 * 1024)
stats = {'head': 0, 'range': 0, 'ignoredBytes': 0}; lock = Lock()
manifest = b'#EXTM3U\n#EXT-X-VERSION:3\n#EXTINF:2,\nsegment.ts\n#EXT-X-ENDLIST\n'
class Server(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_HEAD(self):
        with lock: stats['head'] += 1
        self.send_response(405); self.end_headers()
    def do_GET(self):
        if self.path == '/stats':
            with lock: body = json.dumps(stats).encode()
        elif self.path == '/slow':
            time.sleep(3); return
        elif self.path == '/redirect-file':
            self.send_response(302); self.send_header('Location', 'file:///etc/passwd'); self.end_headers(); return
        elif self.path == '/playlist': body = manifest
        elif self.path == '/html': body = b'<!DOCTYPE html><html>error</html>'
        else: body = media
        requested = self.headers.get('Range')
        if requested and self.path in ('/file', '/ignores-range'):
            with lock: stats['range'] += 1
        partial = bool(requested and self.path in ('/file', '/bad-range'))
        if partial:
            body = body[:65536]; self.send_response(206)
            self.send_header('Content-Range', ('bytes 7-' if self.path == '/bad-range' else 'bytes 0-') + str(len(body) - 1) + '/' + str(len(media)))
        else: self.send_response(200)
        self.send_header('Content-Length', str(len(body))); self.end_headers()
        try:
            if self.path == '/ignores-range':
                for i in range(0, len(body), 4096):
                    block = body[i:i+4096]; self.wfile.write(block); self.wfile.flush()
                    with lock: stats['ignoredBytes'] += len(block)
                    time.sleep(0.004)
            else: self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError): pass
server = ThreadingHTTPServer(('127.0.0.1', 0), Server)
(p / 'port').write_text(str(server.server_port))
server.serve_forever()
PY
server_pid=$!
for _ in $(seq 1 100); do [[ -s "$work/port" ]] && break; sleep 0.02; done
port=$(cat "$work/port")
swiftc -swift-version 5 -target arm64-apple-macos15.0 -emit-module -emit-library -static -module-name CinemaCore Sources/CinemaCore/*.swift -emit-module-path "$work/core/CinemaCore.swiftmodule" -o "$work/core/libCinemaCore.a"
swiftc -parse-as-library -swift-version 5 -target arm64-apple-macos15.0 -I "$work/core" -L "$work/core" -lCinemaCore scripts/validation/playable-media/main.swift -o "$work/check"
"$work/check" "http://127.0.0.1:$port/" "$report"
