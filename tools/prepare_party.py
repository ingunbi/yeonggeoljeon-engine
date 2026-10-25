#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Import original party UI ordering data into local-only native resources."""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import struct
import sys

from prepare_resources import EXAMINED_MAIN, inventory
from prepare_scene import read_resource
from resource_formats import ResourceError

DGROUP = 0x37DA0
CLASS_RANKS = 0x50C2
PERSON_ZERO_DEFAULT = 0x529A


def extract(main: bytes) -> dict:
    if hashlib.sha256(main).hexdigest() != EXAMINED_MAIN:
        raise ResourceError("MAIN does not match the examined party profile")
    ranks = main[DGROUP + CLASS_RANKS:DGROUP + CLASS_RANKS + 256]
    if len(ranks) != 256 or DGROUP + PERSON_ZERO_DEFAULT + 2 > len(main):
        raise ResourceError("original party lookup exceeds MAIN")
    return {"format": 1, "classSortRanks": list(ranks),
            "personZeroDefaultWord": struct.unpack_from("<H", main, DGROUP + PERSON_ZERO_DEFAULT)[0],
            "source": {"mainSha256": EXAMINED_MAIN,
                       "classSortRanks": {"dataSegmentOffset": CLASS_RANKS, "bytes": 256,
                                          "nominalClassCount": 19, "rawIndexDomain": 256,
                                          "sha256": hashlib.sha256(ranks).hexdigest()},
                       "personZeroDefaultWord": {"dataSegmentOffset": PERSON_ZERO_DEFAULT, "bytes": 2},
                       "methods": ["MAIN.EXE:0x34EB6..0x34FAE", "MAIN.EXE:0x350EC..0x35191",
                                   "MAIN.EXE:0x356D4..0x35843", "MAIN.EXE:0x35F1C..0x3602F",
                                   "MAIN.EXE:0x36068..0x360E6", "MAIN.EXE:0x3500A..0x350A1",
                                   "MAIN.EXE:0x27016..0x2726E", "MAIN.EXE:0x2B068..0x2B0ED"],
                       "method": "static source interpretation; original DOS program not executed"}}


def prepare(game: Path, output: Path) -> dict:
    game, output = game.resolve(), output.resolve()
    if output == game or game in output.parents:
        raise ResourceError("party output must be outside the original directory")
    before = inventory(game)
    main, _ = read_resource(game, "MAIN.EXE")
    result = extract(main)
    if inventory(game) != before:
        raise ResourceError("original files changed during party import")
    result["source"]["originalFilesPreserved"] = True
    output.mkdir(parents=True, exist_ok=True)
    temp = output / ".party.json.tmp"
    temp.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temp.replace(output / "party.json")
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--game-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        result = prepare(args.game_dir, args.output)
    except (OSError, ResourceError) as error:
        print(f"party import failed: {error}", file=sys.stderr)
        return 1
    print(json.dumps({"classRanks": len(result["classSortRanks"]), "originalFilesPreserved": True}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
