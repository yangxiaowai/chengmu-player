#!/usr/bin/env python3
"""Install a verified bundle without replacing a running copy or changing user data."""
from __future__ import annotations

import argparse
import fcntl
import os
from pathlib import Path
import plistlib
import re
import shlex
import subprocess
import sys
from collections.abc import Callable

BUNDLE_ID = "local.yingchuan.cinema"
APP_NAME = "映川.app"
LEGACY_NAME = "映川-v0.3.0.app"


class AppIsRunning(RuntimeError):
    pass


def running_copies(bundles: list[Path]) -> list[str]:
    """Use executable paths, not display names, so QA apps never block an upgrade."""
    prefixes = tuple(str(path.resolve()) + "/Contents/MacOS/" for path in bundles)
    snapshot = subprocess.run(
        ["/bin/ps", "-axo", "pid=,comm="], check=True, capture_output=True, text=True
    ).stdout
    return [line.strip() for line in snapshot.splitlines()
            if len(parts := line.strip().split(None, 1)) == 2
            and str(Path(parts[1]).resolve()).startswith(prefixes)]


def verify_bundle(bundle: Path) -> None:
    with (bundle / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if info.get("CFBundleIdentifier") != BUNDLE_ID:
        raise ValueError("暂存应用标识不匹配，未安装。")
    if info.get("CFBundleShortVersionString") != "0.3.3" or info.get("CFBundleVersion") != "15":
        raise ValueError("暂存应用版本不是 0.3.3 / build 15，未安装。")
    executable = bundle / "Contents/MacOS/Cinema"
    if not executable.is_file() or not os.access(executable, os.X_OK):
        raise ValueError("暂存应用缺少可执行程序，未安装。")
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", "--deep", str(bundle)], check=True)


def archive_destination(bundle: Path, archive: Path) -> Path:
    try:
        with (bundle / "Contents/Info.plist").open("rb") as stream:
            info = plistlib.load(stream)
        version = str(info.get("CFBundleShortVersionString", "unknown"))
        build = str(info.get("CFBundleVersion", "unknown"))
    except (OSError, ValueError, plistlib.InvalidFileException):
        version, build = "unknown", "unknown"
    # Version strings are data, never paths.
    version, build = [re.sub(r"[^A-Za-z0-9._-]", "_", value) or "unknown"
                      for value in (version, build)]
    base = f"映川-v{version}-build{build}"
    destination = archive / f"{base}.app"
    index = 2
    while destination.exists() or destination.is_symlink():
        destination = archive / f"{base}-{index}.app"
        index += 1
    return destination


def install_bundle(
    staged: Path,
    distribution: Path,
    probe: Callable[[list[Path]], list[str]] = running_copies,
    verify: Callable[[Path], None] = verify_bundle,
) -> tuple[Path, list[Path]]:
    staged, distribution = staged.resolve(), distribution.resolve()
    target = distribution / APP_NAME
    legacy = distribution / LEGACY_NAME
    known_bundles = [target, legacy]
    if staged in known_bundles or staged.parent == distribution:
        raise ValueError("请从 .build 暂存目录安装，不能把发行入口作为暂存应用。")
    verify(staged)
    distribution.mkdir(parents=True, exist_ok=True)
    # Serialize installers. The lock file stays inert after the handle is closed.
    with (distribution / ".yingchuan-install.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise RuntimeError("另一个安装过程正在进行，暂存应用已保留。") from error

        def ensure_stopped() -> None:
            active = probe(known_bundles)
            if active:
                raise AppIsRunning("映川仍在运行，未替换应用。请正常退出后重新安装。\n" + "\n".join(active))

        ensure_stopped()
        archive = distribution / "历史版本"
        moved: list[tuple[Path, Path]] = []
        installed = False
        try:
            for bundle in (target, legacy):
                if not bundle.exists() and not bundle.is_symlink():
                    continue
                ensure_stopped()
                archive.mkdir(parents=True, exist_ok=True)
                destination = archive_destination(bundle, archive)
                bundle.rename(destination)
                moved.append((bundle, destination))
                known_bundles.append(destination)
            # Also inspect moved paths to catch a launch racing the first check.
            ensure_stopped()
            staged.rename(target)
            installed = True
            verify(target)
        except BaseException:
            if installed:
                target.rename(staged)
            for original, backup in reversed(moved):
                backup.rename(original)
            raise
        return target, [backup for _, backup in moved]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("staged", type=Path)
    parser.add_argument("distribution", type=Path)
    args = parser.parse_args()
    try:
        target, backups = install_bundle(args.staged, args.distribution)
    except Exception as error:
        print(str(error), file=sys.stderr)
        print(f"暂存应用保留于：{args.staged.resolve()}", file=sys.stderr)
        retry = [sys.executable, str(Path(__file__).resolve()), str(args.staged.resolve()), str(args.distribution.resolve())]
        print("重新安装：" + shlex.join(retry), file=sys.stderr)
        return 3 if isinstance(error, AppIsRunning) else 1
    for backup in backups:
        print(f"旧版已备份：{backup}", file=sys.stderr)
    print(target)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
