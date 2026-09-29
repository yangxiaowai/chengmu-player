#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
report="${1:-.build/target-playback/report.json}"
# Keep the default 1080p contract. A separate 720p report is an explicit feasibility check.
case "${TARGET_PLAYBACK_RESOLUTION:-1080}" in
  720|1080) ;;
  *) echo 'TARGET_PLAYBACK_RESOLUTION must be 720 or 1080' >&2; exit 2 ;;
esac
work=$(mktemp -d "${TMPDIR:-/tmp/}cinema-target-playback.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$(dirname "$report")"
# Build only an isolated test executable; never touch the app's SwiftPM products or user profile.
swiftc -emit-module -emit-library -module-name CinemaCore -swift-version 5 -target arm64-apple-macos15.0 Sources/CinemaCore/*.swift -o "$work/libCinemaCore.dylib" -emit-module-path "$work/CinemaCore.swiftmodule"
swiftc -O -parse-as-library -swift-version 5 -target arm64-apple-macos15.0 -I "$work" -L "$work" -lCinemaCore -Xlinker -rpath -Xlinker "$work" Sources/CinemaApp/VideoProcessingPolicy.swift Sources/CinemaApp/VideoSurface.swift Sources/CinemaApp/LookaheadVideoDecoder.swift Sources/CinemaApp/FrameInterpolator.swift Sources/CinemaApp/InterpolatedFramePipeline.swift Sources/CinemaApp/EnhancementPipeline.swift Sources/CinemaApp/CompressionCleaner.swift Sources/CinemaApp/TemporalRestorer.swift Sources/CinemaApp/DetailScaler.swift scripts/validation/target-playback/main.swift -o "$work/check"
if [[ "${TARGET_PLAYBACK_COMPILE_ONLY:-0}" == 1 ]]; then
  echo "Target playback harness compiled; GPU execution deferred."
  exit 0
fi
ffmpeg -hide_banner -loglevel error -f lavfi -i 'testsrc2=size=1280x720:rate=24:duration=45' -f lavfi -i 'sine=frequency=440:sample_rate=48000:duration=45' -threads 2 -c:v libx264 -preset ultrafast -pix_fmt yuv420p -x264-params 'colorprim=bt709:transfer=bt709:colormatrix=bt709' -color_primaries bt709 -color_trc bt709 -colorspace bt709 -c:a aac -movflags +faststart -y "$work/fixture.mp4"
flags=()
[[ "${TARGET_PLAYBACK_CLOCK_DIAGNOSTIC:-0}" == 1 ]] && flags=(--diagnose-clock)
[[ "${TARGET_PLAYBACK_OUTPUT_DIAGNOSTIC:-0}" == 1 ]] && flags=(--diagnose-output)
[[ "${TARGET_PLAYBACK_DUAL_DIAGNOSTIC:-0}" == 1 ]] && flags=(--diagnose-dual-player)
[[ "${TARGET_PLAYBACK_TEARDOWN_DIAGNOSTIC:-0}" == 1 ]] && flags=(--diagnose-dual-teardown)
[[ "${TARGET_PLAYBACK_CHURN_DIAGNOSTIC:-0}" == 1 ]] && flags=(--diagnose-output-churn)
"$work/check" "$work/fixture.mp4" "$report" "${flags[@]}"
