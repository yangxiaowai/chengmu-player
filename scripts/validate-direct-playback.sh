#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
report="${1:-.build/direct-playback.json}"
tmp=$(mktemp -d "${TMPDIR:-/tmp/}cinema-direct.XXXXXX")
server_pid=""
cleanup() { if [[ -n "$server_pid" ]]; then kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; fi; rm -rf "$tmp"; }
trap cleanup EXIT
mkdir -p "$tmp/core" "$tmp/core-sources" "$(dirname "$report")"
cp Sources/CinemaCore/*.swift "$tmp/core-sources/"
ffmpeg -hide_banner -loglevel error -f lavfi -i 'testsrc2=size=640x360:rate=24:duration=10' -c:v libx264 -preset ultrafast -g 24 -movflags +faststart "$tmp/test.mp4"
ffmpeg -hide_banner -loglevel error -i "$tmp/test.mp4" -c copy -hls_time 1 -hls_list_size 0 -hls_segment_filename "$tmp/hls-%03d.ts" "$tmp/generated.m3u8"
awk 'NR==1 { print; print "#EXT-X-KEY:METHOD=NONE"; next } { print }' "$tmp/generated.m3u8" > "$tmp/playlist.m3u8"
sed 's/hls-/late-hls-/g' "$tmp/generated.m3u8" > "$tmp/late.m3u8"
python3 - "$tmp" > "$tmp/server.log" 2>&1 <<'PY' &
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit
import sys,time
root=Path(sys.argv[1]); data=(root/'test.mp4').read_bytes()
class Server(BaseHTTPRequestHandler):
 def do_GET(self):
  route=urlsplit(self.path).path
  if route in ('/playlist.m3u8','/late.m3u8') or ((route.startswith('/hls-') or route.startswith('/late-hls-')) and route.endswith('.ts')):
   path=root/route.removeprefix('/').removeprefix('late-')
   if route == '/late.m3u8': path=root/'late.m3u8'
   if route == '/late-hls-005.ts' and self.headers.get('User-Agent') == 'Cinema-HLS-Direct/1.0':
    (root/'late-requested').write_text('requested')
    until=time.monotonic()+10
    while not (root/'late-fail').exists() and time.monotonic()<until: time.sleep(.02)
    self.send_error(503); return
   if not path.is_file(): self.send_error(404); return
   body=path.read_bytes(); self.send_response(200); self.send_header('Content-Type','application/vnd.apple.mpegurl' if route.endswith('.m3u8') else 'video/mp2t'); self.send_header('Content-Length',str(len(body))); self.end_headers()
   try: self.wfile.write(body)
   except (BrokenPipeError,ConnectionResetError): pass
   return
  direct=self.headers.get('User-Agent')=='Cinema-Direct/1.0'
  if direct and route == '/denied.mp4': self.send_error(403); return
  if direct and route == '/slow.mp4':
   (root/'slow-started').write_text('reached')
   time.sleep(10)
  if direct and route == '/basic.mp4':
   (root/'basic-challenge').write_text('reached')
   if self.headers.get('Authorization'): (root/'direct-authorization').write_text('unexpected')
   self.send_response(401); self.send_header('WWW-Authenticate','Basic realm="cinema-test"'); self.end_headers(); return
  if route == '/cookie-redirect.mp4':
   self.send_response(302); self.send_header('Location',f'http://localhost:{self.server.server_port}/good.mp4'); self.end_headers(); return
  if route == '/redirect.mp4':
   self.send_response(302); self.send_header('Location','/good.mp4?token=signed'); self.end_headers(); return
  start,end=0,len(data)-1
  request_range=self.headers.get('Range')
  if request_range:
   bounds=request_range.removeprefix('bytes=').split('-'); start=int(bounds[0] or 0); end=min(int(bounds[1]) if bounds[1] else end,end)
   self.send_response(206)
   declared_end = len(data)+5 if direct and route == '/bad-range.mp4' else end
   self.send_header('Content-Range',f'bytes {start}-{declared_end}/{len(data)}')
  else: self.send_response(200)
  body=data[start:end+1]; self.send_header('Accept-Ranges','bytes'); self.send_header('Content-Type','video/mp4'); self.send_header('Content-Length',str(len(body))); self.end_headers()
  try:
   if direct and route == '/throttle.mp4':
    for i in range(0, len(body), 32768):
     while (root/'throttle-paused').exists(): time.sleep(.02)
     self.wfile.write(body[i:i+32768]); self.wfile.flush(); time.sleep(.08)
   else: self.wfile.write(body)
  except (BrokenPipeError,ConnectionResetError): pass
server=ThreadingHTTPServer(('127.0.0.1',0),Server); (root/'port').write_text(str(server.server_port)); server.serve_forever()
PY
server_pid=$!
for _ in $(seq 1 100); do [[ -s "$tmp/port" ]] && break; sleep 0.02; done
port=$(cat "$tmp/port")
swiftc -swift-version 5 -target arm64-apple-macos15.0 -emit-module -emit-library -static -module-name CinemaCore \
  "$tmp"/core-sources/*.swift -emit-module-path "$tmp/core/CinemaCore.swiftmodule" -o "$tmp/core/libCinemaCore.a"
swiftc -parse-as-library -swift-version 5 -target arm64-apple-macos15.0 -I "$tmp/core" -L "$tmp/core" -lCinemaCore \
  Sources/CinemaApp/PlaybackController.swift Sources/CinemaApp/DirectHLSRelay.swift Sources/CinemaApp/DirectProgressiveResourceLoader.swift Sources/CinemaApp/SeekPreviewController.swift Sources/CinemaApp/PlaybackDisplaySleepGuard.swift Sources/CinemaApp/QualityPerformanceController.swift Sources/CinemaApp/FrameInterpolator.swift Sources/CinemaApp/InterpolatedFramePipeline.swift Sources/CinemaApp/EnhancementPipeline.swift Sources/CinemaApp/CompressionCleaner.swift Sources/CinemaApp/TemporalRestorer.swift Sources/CinemaApp/DetailScaler.swift \
  Sources/CinemaApp/MediaExperienceInspector.swift Sources/CinemaApp/VideoProcessingPolicy.swift Sources/CinemaApp/AdSkipController.swift Sources/CinemaApp/AdFrameAnalyzer.swift Tests/AppModelSmoke/DirectPlaybackSmoke.swift -o "$tmp/check"
"$tmp/check" "http://127.0.0.1:$port" "$tmp/test.mp4" > "$report"
test -s "$tmp/basic-challenge"
test ! -e "$tmp/direct-authorization"
cat "$report"
