#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
report="${1:-docs/validation/v0.4.3/response-http.json}"
work=$(mktemp -d "${TMPDIR:-/tmp/}chengmu-response-http.XXXXXX")
server_pid=""
cleanup() { if [[ -n "$server_pid" ]]; then kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; fi; rm -rf "$work"; }
trap cleanup EXIT
mkdir -p "$work/core" "$(dirname "$report")"
python3 - "$work" <<'PY' &
from http.server import ThreadingHTTPServer,BaseHTTPRequestHandler
from pathlib import Path
import sys,time,json,threading
stats={'bodyBytes':0,'cancelRequests':0};lock=threading.Lock()
class Handler(BaseHTTPRequestHandler):
    def log_message(self,*args):pass
    def do_HEAD(self):self.do_GET()
    def do_GET(self):
        path=self.path.strip('/')
        if path=='stats':
            data=json.dumps(stats).encode();self.send_response(200);self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data);return
        if path in ('timeout','cancel'):
            if path=='cancel':
                with lock:stats['cancelRequests']+=1
            time.sleep(5);return
        if path=='slow-headers':time.sleep(.2)
        if path=='redirect':
            self.send_response(302);self.send_header('Location','/fast');self.send_header('Content-Length','0');self.end_headers();return
        self.send_response(503 if path=='http-error' else (405 if path=='method-not-supported' else 200))
        self.send_header('Content-Type','application/vnd.apple.mpegurl')
        self.send_header('Content-Length','0' if path=='empty' else ('10485760' if path in ('large-body','never-body') else '7'))
        self.end_headers();self.wfile.flush()
        if self.command=='HEAD':return
        if path=='never-body':time.sleep(5);return
        try:
            if path=='large-body':
                for _ in range(160):
                    self.wfile.write(bytes(65536));self.wfile.flush()
                    with lock:stats['bodyBytes']+=65536
                    time.sleep(.02)
            elif path!='empty':self.wfile.write(b'#EXTM3U')
        except (BrokenPipeError,ConnectionResetError):pass
server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
Path(sys.argv[1],'port').write_text(str(server.server_port));server.serve_forever()
PY
server_pid=$!
for _ in {1..100}; do [[ -f "$work/port" ]] && break; sleep .02; done
port=$(cat "$work/port")
swiftc -emit-module -emit-library -static -module-name CinemaCore -swift-version 5 -target arm64-apple-macos15.0 Sources/CinemaCore/*.swift -emit-module-path "$work/core/CinemaCore.swiftmodule" -o "$work/core/libCinemaCore.a"
swiftc -parse-as-library -swift-version 5 -target arm64-apple-macos15.0 -I "$work/core" -L "$work/core" -lCinemaCore scripts/validation/media-response/main.swift -o "$work/check"
"$work/check" "http://127.0.0.1:$port" "$report"
