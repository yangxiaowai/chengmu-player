#!/bin/bash
# Independent compilation: does not use or lock the app's SwiftPM build directory.
set -euo pipefail
cd "$(dirname "$0")/.."
report="${1:-docs/validation/v0.2.6/playback-stability-headless.json}"
validation_directory=$(mktemp -d "${TMPDIR:-/tmp/}cinema-playback-stability.XXXXXX")
server_pid=""
cleanup() { if [[ -n "$server_pid" ]]; then kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; fi; rm -rf "$validation_directory"; }
trap cleanup EXIT
mkdir -p "$validation_directory/core" "$(dirname "$report")"
python3 - "$validation_directory" > "$validation_directory/http.log" 2>&1 <<'PY' &
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path
import sys, time, wave
p=Path(sys.argv[1])
with wave.open(str(p/'silent.wav'),'wb') as f:
    f.setnchannels(1); f.setsampwidth(2); f.setframerate(8000); f.writeframes(bytes(120*8000*2))
class Pending(BaseHTTPRequestHandler):
    released=False
    def do_HEAD(self):
        self.send_response(200); self.send_header('Content-Type','audio/wav'); self.send_header('Content-Length',str((p/'silent.wav').stat().st_size)); self.send_header('Accept-Ranges','bytes'); self.end_headers()
    def do_GET(self):
        if self.path == '/release':
            Pending.released=True
            self.send_response(200); self.end_headers(); self.wfile.write(b'ok'); return
        if self.path == '/resume.wav' and Pending.released:
            data=(p/'silent.wav').read_bytes(); total=len(data)
            request_range=self.headers.get('Range')
            if request_range:
                bounds=request_range.replace('bytes=','').split('-'); start=int(bounds[0] or 0); end=min(int(bounds[1]) if bounds[1] else total-1,total-1)
                data=data[start:end+1]
                self.send_response(206); self.send_header('Content-Range',f'bytes {start}-{end}/{total}')
            else: self.send_response(200)
            self.send_header('Content-Type','audio/wav'); self.send_header('Accept-Ranges','bytes'); self.send_header('Content-Length',str(len(data))); self.end_headers(); self.wfile.write(data); return
        time.sleep(45)
        try: self.send_error(404)
        except (BrokenPipeError, ConnectionResetError): pass
server=ThreadingHTTPServer(('127.0.0.1',0),Pending)
(p/'port').write_text(str(server.server_port))
server.serve_forever()
PY
server_pid=$!
for _ in $(seq 1 100); do [[ -s "$validation_directory/port" ]] && break; sleep 0.02; done
port=$(cat "$validation_directory/port")
swiftc -swift-version 5 -target arm64-apple-macos15.0 -emit-module -emit-library -static -module-name CinemaCore \
    Sources/CinemaCore/*.swift -emit-module-path "$validation_directory/core/CinemaCore.swiftmodule" -o "$validation_directory/core/libCinemaCore.a"
swiftc -parse-as-library -swift-version 5 -target arm64-apple-macos15.0 \
    -I "$validation_directory/core" -L "$validation_directory/core" -lCinemaCore \
    Sources/CinemaApp/PlaybackController.swift Sources/CinemaApp/QualityPerformanceController.swift Sources/CinemaApp/FrameInterpolator.swift Sources/CinemaApp/InterpolatedFramePipeline.swift Sources/CinemaApp/EnhancementPipeline.swift Sources/CinemaApp/CompressionCleaner.swift Sources/CinemaApp/TemporalRestorer.swift Sources/CinemaApp/DetailScaler.swift \
    Sources/CinemaApp/MediaExperienceInspector.swift Sources/CinemaApp/VideoProcessingPolicy.swift \
    Sources/CinemaApp/AdSkipController.swift Sources/CinemaApp/AdFrameAnalyzer.swift \
    Tests/AppModelSmoke/PlaybackStabilitySmoke.swift -o "$validation_directory/check"
"$validation_directory/check" --validate "$validation_directory/silent.wav" "http://127.0.0.1:$port/pending.m3u8" > "$report"
cat "$report"
