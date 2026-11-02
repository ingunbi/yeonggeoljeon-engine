#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Copy original music members and driver tables into local data; do not distribute the output."""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
from pathlib import Path
import struct
import sys

from prepare_resources import EXAMINED_MAIN, inventory
from prepare_scene import read_resource
from resource_formats import ResourceError

EXAMINED_DRIVER = "41143882e1a229ec4bd72902e00267056e9af601f966b347196ecd7e04f3a530"
LOAD_ADDRESS = 0x100
# Offsets are driver addresses in memory; the .COM file loads at 0x100.
FNUMBERS, FNUMBER_COUNT = 0x76A, 12
BENDS, BEND_COUNT = 0x730, 13
DEPTHS, DEPTH_COUNT = 0x74A, 16
RANDOM_SEED = 0x71C
TRACKS = 7
SONG_FILES = {"songs": "MUSIC.R3", "opening": "OPMUSIC.R3", "ending": "EDMUSIC.R3"}
# CF5:5EC2 installs the bank at 3021:0004 inside MAIN (0x19830); the data segment follows.
EFFECT_BANK, EFFECT_END = 0x36C14, 0x37DA0
EFFECT_COUNT, EFFECT_CHANNELS = 43, 2


def directory(data: bytes, name: str) -> list[dict]:
    """A count word, then a 32-bit offset and 16-bit size per member, then the data."""
    if len(data) < 2:
        raise ResourceError(f"{name} has no member count")
    count = struct.unpack_from("<H", data, 0)[0]
    base = 2 + 6 * count
    if count == 0 or base > len(data):
        raise ResourceError(f"{name} directory exceeds the file")
    members, expected = [], 0
    for index in range(count):
        offset, size = struct.unpack_from("<IH", data, 2 + 6 * index)
        if offset != expected or base + offset + size > len(data):
            raise ResourceError(f"{name} member {index} does not follow the examined directory")
        expected = offset + size
        member = data[base + offset:base + offset + size]
        tracks = struct.unpack_from(f"<{TRACKS}H", member, 0)
        if any(track >= size for track in tracks):
            raise ResourceError(f"{name} member {index} has a track outside the member")
        members.append({"member": index, "offset": base + offset, "size": size,
                        "sha256": hashlib.sha256(member).hexdigest(), "data": base64.b64encode(member).decode("ascii")})
    if base + expected != len(data):
        raise ResourceError(f"{name} has bytes after its last member")
    return members


def words(driver: bytes, address: int, count: int) -> list[int]:
    return list(struct.unpack_from(f"<{count}H", driver, address - LOAD_ADDRESS))


def driver_tables(driver: bytes) -> dict:
    if hashlib.sha256(driver).hexdigest() != EXAMINED_DRIVER:
        raise ResourceError("SBOPL2.COM does not match the examined driver")
    return {"fnumbers": words(driver, FNUMBERS, FNUMBER_COUNT), "bends": words(driver, BENDS, BEND_COUNT),
            "depths": words(driver, DEPTHS, DEPTH_COUNT), "randomSeed": words(driver, RANDOM_SEED, 1)[0]}


def effect_bank(main: bytes) -> dict:
    """Two track words per id, each relative to its own table entry (driver 0x491)."""
    if hashlib.sha256(main).hexdigest() != EXAMINED_MAIN:
        raise ResourceError("MAIN does not match the examined effect bank")
    bank = main[EFFECT_BANK:EFFECT_END]
    tracks = struct.unpack_from(f"<{EFFECT_COUNT * EFFECT_CHANNELS}H", bank, 0)
    for index, word in enumerate(tracks):
        if word and word + index // EFFECT_CHANNELS * 4 >= len(bank):
            raise ResourceError("sound effect track lies outside the bank")
    return {"count": EFFECT_COUNT, "size": len(bank), "sha256": hashlib.sha256(bank).hexdigest(),
            "data": base64.b64encode(bank).decode("ascii"),
            "source": {"resource": "MAIN.EXE", "offset": EFFECT_BANK, "bytes": len(bank), "install": "MAIN.EXE:0x19812..0x19845"}}


def prepare(game: Path, output: Path) -> dict:
    game, output = game.resolve(), output.resolve()
    if output == game or game in output.parents:
        raise ResourceError("music output must be outside the original directory")
    before = inventory(game)
    driver, driver_source = read_resource(game, "SBOPL2.COM")
    main, main_source = read_resource(game, "MAIN.EXE")
    result = {"format": 1, "tables": driver_tables(driver), "effects": effect_bank(main)}
    inputs = [driver_source, main_source]
    for key, name in SONG_FILES.items():
        data, source = read_resource(game, name)
        result[key] = directory(data, name)
        inputs.append(source)
    if inventory(game) != before:
        raise ResourceError("original files changed during music extraction")
    result["source"] = {"inputs": inputs, "driver": "SBOPL2.COM:0x30E..0x113F", "originalFilesPreserved": True,
                        "originalProgramsExecuted": False,
                        "method": "static original byte interpretation; DOS program not executed"}
    result["limitations"] = ["The native synthesizer is written from chip documentation and was not compared with real OPL2 output."]
    output.mkdir(parents=True, exist_ok=True)
    temporary = output / ".music.json.tmp"
    temporary.write_text(json.dumps(result, ensure_ascii=False) + "\n", encoding="utf-8")
    temporary.replace(output / "music.json")
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--game-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        result = prepare(args.game_dir, args.output)
    except (OSError, ValueError, ResourceError) as error:
        print(f"music extraction failed: {error}", file=sys.stderr)
        return 1
    print(json.dumps({"songs": len(result["songs"]), "opening": len(result["opening"]), "ending": len(result["ending"]),
                      "effects": result["effects"]["count"],
                      "originalFilesPreserved": result["source"]["originalFilesPreserved"]}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
