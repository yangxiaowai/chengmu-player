#!/bin/bash
# Proves one decoded playback frame feeds both enhancement and ad recognition.
# Builds the synthetic Chinese-card fixture, plays it through the real surface, and runs real OCR.
set -euo pipefail
cd "$(dirname "$0")/.."
report="${1:-docs/validation/v0.2.9/shared-frame-ad-scan.json}"
fixture_dir=$(mktemp -d "${TMPDIR:-/tmp/}cinema-shared-scan.XXXXXX")
trap 'rm -rf "$fixture_dir"' EXIT
mkdir -p "$(dirname "$report")"
swiftc -emit-module -emit-library -module-name CinemaCore -swift-version 5 -target arm64-apple-macos15.0 Sources/CinemaCore/*.swift -o "$fixture_dir/libCinemaCore.dylib" -emit-module-path "$fixture_dir/CinemaCore.swiftmodule"
swiftc -parse-as-library -swift-version 5 scripts/validation/ad-scan/fixtures.swift -o "$fixture_dir/create-fixtures"
"$fixture_dir/create-fixtures" "$fixture_dir"
ffmpeg -hide_banner -loglevel error -loop 1 -t 16 -i "$fixture_dir/ordinary.png" -loop 1 -t 12 -i "$fixture_dir/advertisement.png" -loop 1 -t 12 -i "$fixture_dir/ordinary.png" -f lavfi -i 'sine=frequency=220:sample_rate=48000' -filter_complex '[0:v][1:v][2:v]concat=n=3:v=1:a=0,fps=24,format=yuv420p[v]' -map '[v]' -map 3:a -t 40 -c:v libx264 -preset ultrafast -crf 18 -g 24 -sc_threshold 0 -c:a aac -movflags +faststart "$fixture_dir/sequence.mp4"
swiftc -parse-as-library -swift-version 5 -target arm64-apple-macos15.0 -I "$fixture_dir" -L "$fixture_dir" -lCinemaCore -Xlinker -rpath -Xlinker "$fixture_dir" Sources/CinemaApp/AdFrameAnalyzer.swift Sources/CinemaApp/AdSkipController.swift Sources/CinemaApp/VideoProcessingPolicy.swift Sources/CinemaApp/VideoSurface.swift Sources/CinemaApp/EnhancementPipeline.swift Sources/CinemaApp/MediaExperienceInspector.swift Sources/CinemaApp/PlaybackController.swift Tests/AppModelSmoke/SharedFrameAdScanSmoke.swift -o "$fixture_dir/check"
"$fixture_dir/check" "$fixture_dir/sequence.mp4" "$report" --validate
