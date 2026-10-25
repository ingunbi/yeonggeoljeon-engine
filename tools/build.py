#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Build the new engine using caller-owned data and installed Apple tools only."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import plistlib
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import uuid
import zipfile


ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build"
APP_NAME = "Yeonggeoljeon Engine.app"
EXECUTABLE = "yeonggeoljeon-engine"
REQUIRED = ("MAIN.EXE", "OPEN.EXE", "BAKDATA.R3", "PMAP.R3", "SMAPBGPL.R3",
            "SSCCHR1.R3", "SSCCHR2.R3", "SNR0M.R3", "SNR0D.R3", "OPGRP.R3")


def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def inventory(folder: Path) -> dict:
    return {str(p.relative_to(folder)): {"bytes": p.stat().st_size, "sha256": digest(p)}
            for p in sorted(folder.rglob("*")) if p.is_file()}


def stage_zip(source: Path, destination: Path) -> Path:
    """Extract a bounded original ZIP into a new private build directory."""
    selected = []
    seen = set()
    total = 0
    with zipfile.ZipFile(source) as archive:
        for entry in archive.infolist():
            if entry.is_dir():
                continue
            path = PurePosixPath(entry.filename)
            if path.is_absolute() or ".." in path.parts or "\\" in entry.filename:
                raise ValueError(f"unsafe ZIP member: {entry.filename!r}")
            if len(path.parts) != 2 or path.parts[0].upper() != "GAME":
                raise ValueError(f"unsupported original ZIP layout: {entry.filename!r}")
            name = path.parts[1].upper()
            mode = entry.external_attr >> 16
            if stat.S_ISLNK(mode):
                raise ValueError(f"symbolic link in original ZIP: {entry.filename!r}")
            if name in seen:
                raise ValueError(f"duplicate original filename: {name}")
            if entry.file_size > 16 * 1024 * 1024:
                raise ValueError(f"original member exceeds supported file limit: {name}")
            total += entry.file_size
            if total > 128 * 1024 * 1024 or len(selected) >= 256:
                raise ValueError("original ZIP exceeds supported total input bounds")
            seen.add(name)
            selected.append((entry, name))
        missing = set(REQUIRED) - seen
        if missing:
            raise ValueError(f"missing original files: {', '.join(sorted(missing))}")
        destination.mkdir(parents=True, exist_ok=False)
        for entry, name in selected:
            # ZIP CRC is verified by read(). Never execute an extracted program.
            (destination / name).write_bytes(archive.read(entry))
    return destination


def run(*args: str) -> None:
    subprocess.run(list(args), cwd=ROOT, check=True)


def install_copy(app: Path, parent: Path) -> Path:
    """Install only this research app; never touch the previous game/fork."""
    parent.mkdir(parents=True, exist_ok=True)
    target = parent / APP_NAME
    temp = Path(tempfile.mkdtemp(prefix=".yeonggeoljeon-install-", dir=parent))
    preserve_temp = False
    try:
        staged = temp / APP_NAME
        shutil.copytree(app, staged)
        if target.exists():
            info = plistlib.loads((target / "Contents/Info.plist").read_bytes())
            if info.get("CFBundleIdentifier") != "org.yeonggeoljeon.engine.research":
                raise ValueError("refusing to replace a different app with the same name")
            stamp = time.strftime("%Y%m%d-%H%M%S")
            backup = BUILD / "backups" / (stamp + "-" + uuid.uuid4().hex + ".zip")
            backup.parent.mkdir(parents=True, exist_ok=True)
            # A ZIP backup cannot register another executable .app with macOS.
            run("/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent",
                str(target), str(backup))
            with zipfile.ZipFile(backup, metadata_encoding="utf-8") as archive:
                if archive.testzip() is not None:
                    raise ValueError("previous app backup failed ZIP verification")
            rollback = temp / "previous-bundle"
            target.rename(rollback)
            try:
                staged.rename(target)
            except BaseException:
                try:
                    rollback.rename(target)
                except BaseException:
                    preserve_temp = True
                    print(f"Previous app retained for recovery: {rollback}", file=sys.stderr)
                raise
        else:
            staged.rename(target)
    finally:
        if not preserve_temp:
            shutil.rmtree(temp)
    return target


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--game", type=Path, required=True, help="original GAME folder or its ZIP")
    parser.add_argument("--title-opgrp", type=Path, help="optional caller-selected intact OPGRP.R3")
    parser.add_argument("--verify", action="store_true")
    parser.add_argument("--install", action="store_true", help="copy this research app to ~/Applications")
    args = parser.parse_args()
    BUILD.mkdir(exist_ok=True)
    source = args.game.expanduser().resolve(strict=True)
    external_title = args.title_opgrp.expanduser().resolve(strict=True) if args.title_opgrp else None
    started = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="engine-build-", dir=BUILD) as work:
        stage = Path(work)
        game = source if source.is_dir() else stage_zip(source, stage / "GAME")
        if not all((game / name).is_file() for name in REQUIRED):
            raise ValueError("game folder lacks required original files")
        before = inventory(game)
        title_before = digest(external_title) if external_title else None
        app = stage / APP_NAME
        resources = app / "Contents" / "Resources"
        data = resources / "GameData"
        executable = app / "Contents" / "MacOS" / EXECUTABLE
        data.mkdir(parents=True)
        executable.parent.mkdir(parents=True)
        resource_args = [sys.executable, "tools/prepare_resources.py", "--game-dir", str(game),
                         "--output", str(data)]
        if external_title:
            resource_args.extend(["--title-opgrp", str(external_title)])
        run(*resource_args)
        run(sys.executable, "tools/prepare_scene.py", "--game-dir", str(game), "--output", str(data))
        sources = sorted((ROOT / "Sources" / "YeonggeoljeonEngine").glob("*.swift"))
        if not sources:
            raise ValueError("native source is not present")
        run("xcrun", "swiftc", "-swift-version", "5", "-target", "arm64-apple-macos13.0", "-O", *map(str, sources),
            "-framework", "AppKit", "-o", str(executable))
        info = {"CFBundleIdentifier": "org.yeonggeoljeon.engine.research",
                "CFBundleName": "Yeonggeoljeon Engine",
                "CFBundleDisplayName": "영걸전 자체 엔진 연구",
                "CFBundleExecutable": EXECUTABLE, "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1",
                "LSMinimumSystemVersion": "13.0", "NSHighResolutionCapable": True,
                "NSPrincipalClass": "NSApplication"}
        (app / "Contents" / "Info.plist").write_bytes(plistlib.dumps(info))
        (resources / "ENGINE-NOTICE.txt").write_text(
            "Yeonggeoljeon Engine: new native engine research prototype.\n"
            "Engine source code: GPL-3.0-only.\n"
            "Original artwork and dialogue were exported locally from caller-owned inputs.\n"
            "They are not part of the engine source distribution.\n", encoding="utf-8")
        shutil.copyfile(ROOT / "LICENSE", resources / "LICENSE")
        run("/usr/bin/codesign", "--force", "--sign", "-", str(app))
        run("/usr/bin/codesign", "--verify", "--strict", str(app))
        if before != inventory(game) or (external_title and title_before != digest(external_title)):
            raise ValueError("original source changed during the build")
        target = BUILD / APP_NAME
        if target.exists():
            archive = BUILD / "backups" / (time.strftime("%Y%m%d-%H%M%S") + "-build.zip")
            archive.parent.mkdir(parents=True, exist_ok=True)
            run("/usr/bin/ditto", "-c", "-k", "--keepParent", str(target), str(archive))
            shutil.rmtree(target)
        app.rename(target)
        evidence = {"format": 1, "kind": "native-build", "version": "0.1.0",
                    "sourceInput": str(source), "sourceFiles": before,
                    "optionalTitleInput": str(external_title) if external_title else None,
                    "optionalTitleSha256": title_before, "originalFilesPreserved": True,
                    "application": str(target), "executableSha256": digest(target / "Contents/MacOS" / EXECUTABLE),
                    "elapsedSeconds": round(time.monotonic() - started, 3)}
        def save_evidence() -> None:
            pending = BUILD / "build-evidence.pending.json"
            pending.write_text(json.dumps(evidence, ensure_ascii=False, indent=2) + "\n")
            pending.replace(BUILD / "build-evidence.json")
        evidence["verificationStatus"] = "pending" if args.verify else "not-requested"
        save_evidence()
        if args.verify:
            verify = BUILD / ("verification-" + time.strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:8])
            evidence["verification"] = str(verify)
            try:
                run(str(target / "Contents/MacOS" / EXECUTABLE), "--verify", "--data",
                    str(target / "Contents/Resources/GameData"), "--output", str(verify))
            except subprocess.CalledProcessError as error:
                evidence["verificationStatus"] = "failed"
                evidence["verificationExitCode"] = error.returncode
                save_evidence()
                raise
            evidence["verificationStatus"] = "passed"
        if args.install:
            evidence["installedApplication"] = str(install_copy(target, Path.home() / "Applications"))
        save_evidence()
        print(json.dumps({"application": str(target), "sourceFilesPreserved": True,
                          "elapsedSeconds": evidence["elapsedSeconds"]}, ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError, zipfile.BadZipFile) as error:
        print(f"Build failed: {error}", file=sys.stderr)
        raise SystemExit(1)
