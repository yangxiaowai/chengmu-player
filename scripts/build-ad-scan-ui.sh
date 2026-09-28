#!/bin/bash
# Build only. Launch through the native UI tool; this script never launches or touches the user's app.
set -euo pipefail
cd "$(dirname "$0")/.."
app_dir="$PWD/.build/AdSkipUINativeQA.app"
module_dir="$PWD/.build/ad-skip-ui-build"
if [[ ! -f .build/ad-skip-fixture.mp4 || ! -f .build/ad-skip-fixture.srt ]]; then
  echo 'Missing .build/ad-skip-fixture.mp4/.srt; generate them with scripts/validate-ad-scan.sh first.' >&2
  exit 1
fi
mkdir -p "$module_dir" "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
swiftc -emit-module -emit-library -static -module-name CinemaCore -swift-version 5 -target arm64-apple-macos15.0 Sources/CinemaCore/*.swift -o "$module_dir/libCinemaCore.a" -emit-module-path "$module_dir/CinemaCore.swiftmodule"
app_sources=()
for source in Sources/CinemaApp/*.swift; do
  case "$source" in Sources/CinemaApp/CinemaApp.swift|Sources/CinemaApp/PlaybackValidation.swift) continue ;; esac
  app_sources+=("$source")
done
swiftc -parse-as-library -swift-version 5 -target arm64-apple-macos15.0 -I "$module_dir" -L "$module_dir" -lCinemaCore "${app_sources[@]}" scripts/validation/ad-scan-ui/main.swift -o "$app_dir/Contents/MacOS/AdSkipUINativeQA"
cp .build/ad-skip-fixture.mp4 .build/ad-skip-fixture.srt "$app_dir/Contents/Resources/"
python3 - "$app_dir" "$PWD/.build/ad-skip-ui-profile" <<'PYPLIST'
from pathlib import Path
import plistlib
import sys
app = Path(sys.argv[1])
metadata = {
    'CFBundleName': 'AdSkip Native QA',
    'CFBundleDisplayName': '映川 · 广告跳过隔离验收',
    'CFBundleIdentifier': 'local.yingchuan.adskipnativeqa',
    'CFBundleExecutable': 'AdSkipUINativeQA',
    'CFBundlePackageType': 'APPL',
    'CFBundleShortVersionString': '0.3.0',
    'CFBundleVersion': '12',
    'LSMinimumSystemVersion': '15.0',
    'NSHighResolutionCapable': True,
    'NSPrincipalClass': 'NSApplication',
    'LSEnvironment': {'YINGCHUAN_PROFILE_DIRECTORY': sys.argv[2]},
}
(app / 'Contents/Info.plist').write_bytes(plistlib.dumps(metadata))
PYPLIST
codesign --force --sign - "$app_dir/Contents/MacOS/AdSkipUINativeQA"
codesign --force --sign - "$app_dir"
codesign --verify --strict --deep "$app_dir"
printf '%s\n' "$app_dir"
