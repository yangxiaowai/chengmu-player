#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_config="${1:-release}"
bash scripts/swift.sh build -c "$build_config"
if [ "$build_config" = release ]; then product_dir=".build/out/Products/Release"; else product_dir=".build/out/Products/Debug"; fi
if [ ! -f "$product_dir/Cinema" ]; then
  product_dir="$(bash scripts/swift.sh build -c "$build_config" --show-bin-path | tail -n 1)"
fi
app_dir="$PWD/dist/映川.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$product_dir/Cinema" "$app_dir/Contents/MacOS/Cinema.new"
mv -f "$app_dir/Contents/MacOS/Cinema.new" "$app_dir/Contents/MacOS/Cinema"
swift scripts/make-icon.swift .build/AppIcon.iconset
iconutil -c icns .build/AppIcon.iconset -o "$app_dir/Contents/Resources/AppIcon.icns"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>映川</string>
<key>CFBundleDisplayName</key><string>映川</string>
<key>CFBundleIdentifier</key><string>local.yingchuan.cinema</string>
<key>CFBundleExecutable</key><string>Cinema</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.7</string>
<key>CFBundleVersion</key><string>9</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoadsForMedia</key><true/></dict>
</dict></plist>
PLIST
codesign --force --sign - "$app_dir"
printf '%s\n' "$app_dir"
