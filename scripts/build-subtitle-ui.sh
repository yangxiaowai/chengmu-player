#!/bin/bash
# Independent native UI host for manual CUA verification. Builds only; never launches.
set -euo pipefail
cd "$(dirname "$0")/.."
preview_root="$PWD/.build/subtitle-ui-build"
preview_app="$PWD/.build/SubtitleComfortPreview.app"
mkdir -p "$preview_root/core" "$preview_app/Contents/MacOS" "$preview_app/Contents/Resources"
cat > "$preview_app/Contents/Resources/local-film.srt" <<'SRT'
1
00:00:00,000 --> 00:00:10,000
夜色渐深，故事继续。
As the evening settles, the story continues.
SRT
ffmpeg -hide_banner -loglevel error -f lavfi \
  -i 'color=c=0x1b3546:s=960x540:r=24:d=10' \
  -f lavfi -i 'anullsrc=r=48000:cl=stereo' \
  -t 10 -c:v libx264 -pix_fmt yuv420p -c:a aac -movflags +faststart \
  -y "$preview_app/Contents/Resources/local-film.mp4"
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macos15.0" \
  -emit-module -emit-library -static -module-name CinemaCore Sources/CinemaCore/*.swift \
  -emit-module-path "$preview_root/core/CinemaCore.swiftmodule" -o "$preview_root/core/libCinemaCore.a"
preview_sources=()
for preview_source in Sources/CinemaApp/*.swift; do
  [[ "$preview_source" == "Sources/CinemaApp/CinemaApp.swift" ]] || preview_sources+=("$preview_source")
done
xcrun swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos15.0" \
  -I "$preview_root/core" -L "$preview_root/core" -lCinemaCore \
  "${preview_sources[@]}" scripts/validation/subtitle-ui/main.swift \
  -o "$preview_app/Contents/MacOS/SubtitleComfortPreview"
cat > "$preview_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>澄幕 · 字幕预览</string>
<key>CFBundleDisplayName</key><string>澄幕 · 字幕预览</string>
<key>CFBundleIdentifier</key><string>local.chengmu.subtitle-ui-preview</string>
<key>CFBundleExecutable</key><string>SubtitleComfortPreview</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.4.1</string>
<key>CFBundleVersion</key><string>24</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force --sign - "$preview_app"
codesign --verify --strict --deep "$preview_app"
printf 'Built: %s\nLaunch: open -n "%s" --args --validate\n' "$preview_app" "$preview_app"
