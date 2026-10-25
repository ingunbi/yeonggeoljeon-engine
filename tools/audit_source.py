#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Audit the exact tracked (or prospective) source list before publication."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
ALLOWED_SUFFIXES = {".swift", ".py", ".md", ".toml", ".yml", ".yaml"}
ALLOWED_NAMES = {".gitignore", ".gitattributes", "LICENSE"}
EXCLUDED_ROOTS = {".git", "build", ".local", ".build", ".swiftpm", "__pycache__"}


def candidate_files() -> list[Path]:
    if (ROOT / ".git").is_dir():
        output = subprocess.check_output(["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd=ROOT)
        return sorted(ROOT / p.decode("utf-8") for p in output.split(b"\0") if p)
    return sorted(path for path in ROOT.rglob("*") if path.is_file()
                  and not any(part in EXCLUDED_ROOTS for part in path.relative_to(ROOT).parts)
                  and not str(path.relative_to(ROOT)).startswith("research/local/"))


def audit(paths: list[Path]) -> dict:
    errors = []
    files = []
    for path in paths:
        relative = path.relative_to(ROOT)
        if path.is_symlink():
            errors.append(f"source symlink requires review: {relative}")
            continue
        if path.suffix not in ALLOWED_SUFFIXES and path.name not in ALLOWED_NAMES:
            errors.append(f"file type is outside the public source allowlist: {relative}")
            continue
        data = path.read_bytes()
        try:
            contents = data.decode("utf-8")
        except UnicodeDecodeError:
            errors.append(f"source is not UTF-8 text: {relative}")
            continue
        # Keep machine-specific workspace paths in local evidence, not public sources.
        if (str(Path.home()) + "/") in contents:
            errors.append(f"local workspace path must be moved to an ignored local report: {relative}")
        if len(data) > 512 * 1024:
            errors.append(f"source file exceeds the review bound: {relative}")
        files.append({"path": relative.as_posix(), "bytes": len(data),
                      "sha256": hashlib.sha256(data).hexdigest()})
    return {"format": 1, "scope": "exact tracked and non-ignored source candidates",
            "passed": not errors, "files": files, "errors": errors,
            "limitations": ["A text/file-type audit cannot establish copyright provenance.",
                            "Code-review and recorded analysis references are separate evidence."]}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    result = audit(candidate_files())
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"passed": result["passed"], "files": len(result["files"]),
                      "errors": result["errors"]}, ensure_ascii=False))
    raise SystemExit(0 if result["passed"] else 1)


if __name__ == "__main__":
    main()
