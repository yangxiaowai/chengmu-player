#!/usr/bin/env python3
"""Compile a separate smoke binary against existing Core; do not rebuild the app.

Runs three real catalog + AVPlayer cases sequentially with a 210 second runtime
limit. JSON is updated during execution, including failures and timeout evidence.
No media or pixel buffers are saved to disk.
"""
import argparse
import datetime
import json
from pathlib import Path
import platform
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--report", type=Path, default=root / "docs/validation/v0.2/headless-network-playback.json")
args = parser.parse_args()
report = args.report.resolve()
report.parent.mkdir(parents=True, exist_ok=True)
library = root / ".build/out/Products/Release"
if not (library / "libCinemaCore.a").exists():
    library = root / ".build/out/Products/Debug"
if not (library / "libCinemaCore.a").exists():
    sys.exit("Existing CinemaCore build required; this script does not rebuild the product.")
binary = root / ".build/headless-network-playback-smoke"
# The renderer's permission value is the only thing the controller needs from VideoSurface; a
# minimal stand-in keeps this smoke test independent of the Metal surface.
stub = root / ".build/headless-permission-stub.swift"
stub.write_text("import Foundation\nenum VideoProcessingPermission: Equatable { case inspectSDRFrames; case nativeOnly(String) }\n")
command = ["swiftc", "-parse-as-library", "-target", f"{platform.machine()}-apple-macos15.0",
           "-I", str(library), "-L", str(library), "-lCinemaCore",
           "Sources/CinemaApp/PlaybackController.swift", "Sources/CinemaApp/EnhancementPipeline.swift", "Sources/CinemaApp/TemporalRestorer.swift", "Sources/CinemaApp/DetailScaler.swift",
           "Sources/CinemaApp/MediaExperienceInspector.swift", str(stub),
           "Sources/CinemaApp/AdSkipController.swift", "Sources/CinemaApp/AdFrameAnalyzer.swift",
           "Tests/AppModelSmoke/NetworkPlaybackSmoke.swift", "-o", str(binary)]
subprocess.run(command, cwd=root, check=True, timeout=60)
log = report.with_suffix(".log")
with log.open("w") as output:
    try:
        result = subprocess.run([str(binary), "--validate", "--report", str(report)], cwd=root,
                                stdout=output, stderr=subprocess.STDOUT, timeout=210)
    except subprocess.TimeoutExpired:
        data = json.loads(report.read_text()) if report.exists() else {}
        data.update(final=False, passed=False, processTimeout=True,
                    processTimeoutSeconds=210,
                    stoppedAt=datetime.datetime.now(datetime.timezone.utc).isoformat())
        report.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
        print("TIMEOUT: partial JSON preserved", file=output)
        result = None
print(log.read_text(), end="")
print(f"Report: {report}")
sys.exit(result.returncode if result is not None else 124)
