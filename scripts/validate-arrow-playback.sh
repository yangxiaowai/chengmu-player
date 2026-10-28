#!/bin/bash
# Headless integration of the actual NSSlider and PlaybackController.
set -euo pipefail
cd "$(dirname "$0")/.."
report="${1:-.build/arrow-playback-integration.log}"
work=$(mktemp -d "${TMPDIR:-/tmp/}chengmu-arrow-playback.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/core" "$work/profile" "$(dirname "$report")"
ffmpeg -hide_banner -loglevel error -f lavfi -i 'anullsrc=r=8000:cl=mono' -t 600 -c:a pcm_s16le "$work/silent.wav"
swiftc -swift-version 5 -target arm64-apple-macos15.0 -emit-module -emit-library -static -module-name CinemaCore \
  Sources/CinemaCore/*.swift -emit-module-path "$work/core/CinemaCore.swiftmodule" -o "$work/core/libCinemaCore.a"
{ printf 'import Foundation\nimport AppKit\nimport SwiftUI\nimport CinemaCore\n'; awk 'found { print } /^private struct TimelineLocation/ { found=1; print }' Sources/CinemaApp/SeekBar.swift; awk 'found { print } /^private struct PlaybackKeyboardSurface/ { found=1; print }' Sources/CinemaApp/PlayerView.swift; cat Tests/AppModelSmoke/ArrowPlaybackIntegrationSmoke.swift; } > "$work/Integration.swift"
swiftc -parse-as-library -swift-version 5 -target arm64-apple-macos15.0 -I "$work/core" -L "$work/core" -lCinemaCore \
  Sources/CinemaApp/PlaybackController.swift Sources/CinemaApp/PlayerPresentationController.swift Sources/CinemaApp/DirectHLSRelay.swift Sources/CinemaApp/DirectProgressiveResourceLoader.swift \
  Sources/CinemaApp/PlaybackDisplaySleepGuard.swift Sources/CinemaApp/QualityPerformanceController.swift Sources/CinemaApp/FrameInterpolator.swift \
  Sources/CinemaApp/InterpolatedFramePipeline.swift Sources/CinemaApp/VideoProcessingPolicy.swift Sources/CinemaApp/EnhancementPipeline.swift \
  Sources/CinemaApp/CompressionCleaner.swift Sources/CinemaApp/TemporalRestorer.swift Sources/CinemaApp/DetailScaler.swift \
  Sources/CinemaApp/MediaExperienceInspector.swift Sources/CinemaApp/AdSkipController.swift Sources/CinemaApp/AdFrameAnalyzer.swift "$work/Integration.swift" -o "$work/check"
YINGCHUAN_PROFILE_DIRECTORY="$work/profile" "$work/check" "$work/silent.wav" > "$report"
cat "$report"
