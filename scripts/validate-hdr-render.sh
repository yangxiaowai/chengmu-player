#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
report="${1:-docs/validation/v0.2.9/hdr-render-green.json}"
mode="${2:-green}"
fixture_dir=$(mktemp -d "${TMPDIR:-/tmp/}cinema-hdr-render.XXXXXX")
server_pid=""
cleanup() { if [[ -n "$server_pid" ]]; then kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; fi; }
trap cleanup EXIT
mkdir -p "$(dirname "$report")" "$fixture_dir/hls"
ffmpeg -hide_banner -loglevel error -f lavfi -i 'testsrc2=size=320x180:rate=24:duration=4' -c:v libx264 -preset ultrafast -x264-params 'colorprim=bt709:transfer=bt709:colormatrix=bt709' -pix_fmt yuv420p -movflags +write_colr -y "$fixture_dir/sdr709.mp4"
if [[ "$mode" != red ]]; then
  # Keep the coded raster identical; only the sample aspect ratio changes. The longer
  # clip leaves time for the real surface and its independent lookahead decoder to start.
  for sar in 1 2; do
    ffmpeg -hide_banner -loglevel error -f lavfi -i 'testsrc2=size=640x360:rate=24:duration=30' -vf "setsar=$sar/1" -c:v libx264 -preset ultrafast -x264-params 'colorprim=bt709:transfer=bt709:colormatrix=bt709' -pix_fmt yuv420p -movflags +write_colr -y "$fixture_dir/compression-sar$sar.mp4"
    ffprobe -v error -select_streams v:0 -show_entries stream=width,height,sample_aspect_ratio,display_aspect_ratio,color_transfer,color_primaries,color_space -of json "$fixture_dir/compression-sar$sar.mp4" > "$fixture_dir/compression-sar$sar.json"
  done
fi
for format in pq hlg; do
  transfer=smpte2084
  [[ "$format" == hlg ]] && transfer=arib-std-b67
  ffmpeg -hide_banner -loglevel error -f lavfi -i 'testsrc2=size=320x180:rate=24:duration=4' -c:v libx265 -preset ultrafast -x265-params "pools=none:frame-threads=1:log-level=error:colorprim=bt2020:transfer=$transfer:colormatrix=bt2020nc" -pix_fmt yuv420p10le -tag:v hvc1 -movflags +write_colr -y "$fixture_dir/$format.mp4"
done
ffmpeg -hide_banner -loglevel error -i "$fixture_dir/sdr709.mp4" -c copy -hls_time 1 -hls_list_size 0 -hls_segment_filename "$fixture_dir/hls/segment-%03d.ts" "$fixture_dir/hls/sdr.m3u8"
python3 - "$fixture_dir/hls" "$fixture_dir/port" > "$fixture_dir/http.log" 2>&1 <<'PY' &
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from functools import partial
from pathlib import Path
import sys
server = ThreadingHTTPServer(('127.0.0.1',0),partial(SimpleHTTPRequestHandler,directory=sys.argv[1]))
Path(sys.argv[2]).write_text(str(server.server_port)); server.serve_forever()
PY
server_pid=$!
for _ in $(seq 1 100); do [[ -s "$fixture_dir/port" ]] && break; sleep 0.02; done
swiftc -emit-module -emit-library -module-name CinemaCore -swift-version 5 -target arm64-apple-macos15.0 Sources/CinemaCore/*.swift -o "$fixture_dir/libCinemaCore.dylib" -emit-module-path "$fixture_dir/CinemaCore.swiftmodule"
flags=()
[[ "$mode" == red ]] && flags=(-D HDR_RENDER_BASELINE)
# The red run compiles the last committed surface, which is the behaviour this change replaces.
surface="Sources/CinemaApp/VideoSurface.swift"
policy="Sources/CinemaApp/VideoProcessingPolicy.swift"
if [[ "$mode" == red ]]; then
  surface="$fixture_dir/VideoSurfaceBaseline.swift"
  git show HEAD:Sources/CinemaApp/VideoSurface.swift > "$surface"
fi
swiftc "${flags[@]}" -parse-as-library -swift-version 5 -target arm64-apple-macos15.0 -I "$fixture_dir" -L "$fixture_dir" -lCinemaCore -Xlinker -rpath -Xlinker "$fixture_dir" "$policy" "$surface" Sources/CinemaApp/LookaheadVideoDecoder.swift Sources/CinemaApp/FrameInterpolator.swift Sources/CinemaApp/InterpolatedFramePipeline.swift Sources/CinemaApp/EnhancementPipeline.swift Sources/CinemaApp/CompressionCleaner.swift Sources/CinemaApp/TemporalRestorer.swift Sources/CinemaApp/DetailScaler.swift scripts/validation/hdr-render/main.swift -o "$fixture_dir/check"
"$fixture_dir/check" "$fixture_dir" "$report" "http://127.0.0.1:$(cat "$fixture_dir/port")/sdr.m3u8"
