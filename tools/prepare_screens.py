#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Compile the opening and ending programs into local data; do not distribute the output."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

from prepare_resources import inventory
from resource_formats import ResourceError
from screen_programs import OPCODES, compile_all


def prepare(game: Path, output: Path, opgrp: Path | None = None) -> dict:
    game, output = game.resolve(), output.resolve()
    if output == game or game in output.parents:
        raise ResourceError("screen output must be outside the original directory")
    before = inventory(game)
    programs, assets = compile_all(game, opgrp.read_bytes() if opgrp else None)
    if inventory(game) != before:
        raise ResourceError("original files changed during screen compilation")
    output.mkdir(parents=True, exist_ok=True)
    ranges, position = [], 0
    with (output / ".screens.bin.tmp").open("wb") as stream:
        for asset in assets:
            stream.write(asset)
            ranges.append([position, len(asset)])
            position += len(asset)
    (output / ".screens.bin.tmp").replace(output / "screens.bin")
    result = {"format": 1, "opcodes": OPCODES, "assets": ranges, "programs": programs,
              "source": {"programs": ["END.EXE:0x4B9A..0x998B", "OPEN.EXE:0x4310..0x89A6"], "originalFilesPreserved": True,
                         "originalProgramsExecuted": False, "method": "static transcription; no original program was run"},
              "limitations": ["Deadlines and tick floors come from the source; blit and load durations of period hardware are unknown.",
                              "Nothing was compared with a running original."]}
    temporary = output / ".screens.json.tmp"
    temporary.write_text(json.dumps(result, ensure_ascii=False, separators=(",", ":")) + "\n", encoding="utf-8")
    temporary.replace(output / "screens.json")
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--game-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--title-opgrp", type=Path)
    args = parser.parse_args()
    try:
        result = prepare(args.game_dir, args.output, args.title_opgrp)
    except (OSError, ValueError, ResourceError) as error:
        print(f"screen compilation failed: {error}", file=sys.stderr)
        return 1
    print(json.dumps({name: len(ops) for name, ops in result["programs"].items()}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
