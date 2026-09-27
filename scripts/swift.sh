#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Some CLT installations retain Swift 5 private interfaces beside Swift 6 dylibs.
# Use the matching public interfaces in a project-local copy, without changing CLT.
python3 - <<'PY'
from pathlib import Path
import shutil, subprocess
toolchain = Path(subprocess.check_output(['xcode-select', '-p'], text=True).strip())
source = toolchain / 'usr/lib/swift/pm/ManifestAPI'
target = Path('.build/swiftpm-libs/ManifestAPI')
for p in source.rglob('*'):
    if p.is_file() and 'private.swiftinterface' not in p.name:
        dest = target / p.relative_to(source)
        dest.parent.mkdir(parents=True, exist_ok=True)
        if not dest.exists() or dest.stat().st_mtime != p.stat().st_mtime:
            shutil.copy2(p, dest)
PY
export SWIFTPM_CUSTOM_LIBS_DIR="$PWD/.build/swiftpm-libs"
exec swift "$@" -Xswiftc -plugin-path -Xswiftc "$(xcode-select -p)/usr/lib/swift/host/plugins/testing"
