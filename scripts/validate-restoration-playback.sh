#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
report="${1:-docs/validation/v0.3.2/restoration-playback.json}"
work=$(mktemp -d "${TMPDIR:-/tmp/}cinema-restoration-playback.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$(dirname "$report")"
ffmpeg -hide_banner -loglevel error -f lavfi -i 'testsrc2=size=1280x720:rate=24:duration=16' -vf 'noise=alls=3:allf=t+u:all_seed=7' -c:v libx264 -crf 29 -preset ultrafast -x264-params 'colorprim=bt709:transfer=bt709:colormatrix=bt709' -pix_fmt yuv420p -movflags +write_colr -y "$work/sdr.mp4"
swiftc -emit-module -emit-library -module-name CinemaCore -swift-version 5 -target arm64-apple-macos15.0 Sources/CinemaCore/*.swift -o "$work/libCinemaCore.dylib" -emit-module-path "$work/CinemaCore.swiftmodule"
swiftc -O -parse-as-library -swift-version 5 -target arm64-apple-macos15.0 -I "$work" -L "$work" -lCinemaCore -Xlinker -rpath -Xlinker "$work" Sources/CinemaApp/VideoProcessingPolicy.swift Sources/CinemaApp/VideoSurface.swift Sources/CinemaApp/EnhancementPipeline.swift Sources/CinemaApp/TemporalRestorer.swift scripts/validation/restoration-playback/main.swift -o "$work/check"
"$work/check" "$work/sdr.mp4" "$report"
