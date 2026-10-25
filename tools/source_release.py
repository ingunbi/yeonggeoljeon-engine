#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Create a verified source-only release archive; original game data is excluded."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import tempfile
import zipfile

from audit_source import ROOT, audit, candidate_files


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "build/yeonggeoljeon-engine-source.zip")
    args = parser.parse_args()
    result = audit(candidate_files())
    if not result["passed"]:
        raise SystemExit("Source audit failed: " + "; ".join(result["errors"]))
    required = {"LICENSE", "README.md", "tools/build.py"}
    paths = {entry["path"] for entry in result["files"]}
    if not required <= paths or not any(p.endswith(".swift") for p in paths):
        raise SystemExit("The reviewed source list is incomplete")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="source-release-", dir=args.output.parent) as tmp:
        staged = Path(tmp) / "release.zip"
        with zipfile.ZipFile(staged, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for entry in result["files"]:
                value = (ROOT / entry["path"]).read_bytes()
                if hashlib.sha256(value).hexdigest() != entry["sha256"]:
                    raise SystemExit("Source changed during archive creation: " + entry["path"])
                name = "yeonggeoljeon-engine/" + entry["path"]
                archive.writestr(name, value)
        with zipfile.ZipFile(staged) as archive:
            if archive.testzip() is not None:
                raise SystemExit("Source archive CRC verification failed")
            for entry in result["files"]:
                value = archive.read("yeonggeoljeon-engine/" + entry["path"])
                if hashlib.sha256(value).hexdigest() != entry["sha256"]:
                    raise SystemExit("Source archive differs from reviewed inputs")
        staged.replace(args.output)
    report = {"format": 1, "archive": str(args.output.resolve()),
              "archiveSha256": hashlib.sha256(args.output.read_bytes()).hexdigest(),
              "sourceFiles": result["files"], "originalGameFilesIncluded": False,
              "verifiedReadback": True}
    args.output.with_suffix(".json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"archive": str(args.output), "sourceFiles": len(result["files"]),
                      "sha256": report["archiveSha256"]}))


if __name__ == "__main__":
    main()
