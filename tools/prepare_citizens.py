#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Extract the original citizens into local data; do not distribute the output."""
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

DATA_SEGMENT = 0x37DA0
GROUP_COUNT = 4
GROUP_SIZES, GROUP_OFFSETS, TEXT_BASES = 0x393A, 0x3942, 0x2DD0
PERSON_COUNT, PERSON_STRIDE, NAME_BYTES, SPRITE_BYTE = 256, 13, 8, 8
NO_LINE = 0xFFFF


def people(bak: bytes) -> list[dict]:
    """MAIN1AD46 keeps eight name bytes and the sprite from each 13-byte record."""
    result = []
    for index in range(PERSON_COUNT):
        row = bak[index * PERSON_STRIDE:(index + 1) * PERSON_STRIDE]
        result.append({"name": row[:NAME_BYTES].split(b"\0")[0].decode("cp949"), "sprite": row[SPRITE_BYTE]})
    return result


def group_table(block: bytes, text: bytes, base: int) -> dict:
    """City words, a word, then one message offset per citizen (MAIN1FE97..1FEFF, 26301..26370)."""
    cities = block[0]
    words = struct.unpack_from(f"<{cities}H", block, 1)
    placements = {}
    for city, offset in enumerate(words):
        if offset == 0:
            continue
        at = 1 + offset
        count = block[at]
        at += 1
        rows = []
        for _ in range(count):
            key, members = block[at], block[at + 1]
            at += 2
            rows.append({"key": key, "ids": list(struct.unpack_from(f"<{members}H", block, at))})
            at += members * 2
        placements[str(city)] = rows
    lines = {}
    table = 1 + cities * 2 + 2
    # Message words stop where the first placement block begins.
    first = min((1 + offset for offset in words if offset), default=len(block))
    for citizen in range((first - table) // 2):
        offset = struct.unpack_from("<H", block, table + citizen * 2)[0]
        if offset == NO_LINE:
            continue
        start = base + offset
        if start >= len(text):
            raise ResourceError("citizen line starts outside IPPAN0M.R3")
        lines[str(citizen)] = text[start:text.index(0, start)].decode("cp949")
    return {"cityCount": cities, "cities": placements, "lines": lines}


def extract(main: bytes, bak: bytes, table: bytes, text: bytes) -> dict:
    if hashlib.sha256(main).hexdigest() != EXAMINED_MAIN:
        raise ResourceError("MAIN does not match the examined citizen profile")
    if len(bak) != 19328:
        raise ResourceError("BAKDATA does not match the examined citizen layout")
    sizes = struct.unpack_from(f"<{GROUP_COUNT}H", main, DATA_SEGMENT + GROUP_SIZES)
    offsets = struct.unpack_from(f"<{GROUP_COUNT}I", main, DATA_SEGMENT + GROUP_OFFSETS)
    bases = struct.unpack_from(f"<{GROUP_COUNT}I", main, DATA_SEGMENT + TEXT_BASES)
    if offsets[-1] + sizes[-1] != len(table):
        raise ResourceError("IPPAN0.R3 does not match the MAIN group table")
    groups = [group_table(table[offsets[g]:offsets[g] + sizes[g]], text, bases[g]) for g in range(GROUP_COUNT)]
    return {"format": 1, "people": people(bak), "groups": groups,
            "source": {"people": {"resource": "BAKDATA.R3", "offset": 0, "stride": PERSON_STRIDE},
                       "groups": {"resource": "IPPAN0.R3", "offsets": list(offsets), "sizes": list(sizes)},
                       "lines": {"resource": "IPPAN0M.R3", "bases": list(bases)},
                       "methods": ["MAIN.EXE:0x26238..0x2640C", "MAIN.EXE:0x1FE6A..0x1FF30", "MAIN.EXE:0x1AD46..0x1ADAD"],
                       "method": "static original byte interpretation; DOS program not executed"},
            "limitations": ["Citizens stand where they are placed; their wandering is not restored."]}


def prepare(game: Path, output: Path) -> dict:
    game, output = game.resolve(), output.resolve()
    if output == game or game in output.parents:
        raise ResourceError("citizen output must be outside the original directory")
    before = inventory(game)
    sources = {name: read_resource(game, name) for name in ("MAIN.EXE", "BAKDATA.R3", "IPPAN0.R3", "IPPAN0M.R3")}
    result = extract(*(sources[name][0] for name in ("MAIN.EXE", "BAKDATA.R3", "IPPAN0.R3", "IPPAN0M.R3")))
    if inventory(game) != before:
        raise ResourceError("original files changed during citizen extraction")
    result["source"].update({"inputs": [item[1] for item in sources.values()], "originalFilesPreserved": True,
                             "originalProgramsExecuted": False})
    output.mkdir(parents=True, exist_ok=True)
    temporary = output / ".citizens.json.tmp"
    temporary.write_text(json.dumps(result, ensure_ascii=False) + "\n", encoding="utf-8")
    temporary.replace(output / "citizens.json")
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--game-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        result = prepare(args.game_dir, args.output)
    except (OSError, ValueError, ResourceError) as error:
        print(f"citizen extraction failed: {error}", file=sys.stderr)
        return 1
    print(json.dumps({"people": len(result["people"]), "cities": sum(len(g["cities"]) for g in result["groups"]),
                      "lines": sum(len(g["lines"]) for g in result["groups"]),
                      "originalFilesPreserved": result["source"]["originalFilesPreserved"]}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
