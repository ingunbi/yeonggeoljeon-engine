#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Extract the enlarged combat view into local data; do not distribute the output."""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
from pathlib import Path
import re
import struct
import sys

from prepare_resources import EXAMINED_MAIN, inventory, palette_at
from prepare_scene import read_resource
from resource_formats import Archive, ResourceError, planar_image

DATA_SEGMENT, DATA_PARAGRAPH = 0x37DA0, 0x313A
PALETTE_OFFSET = 0x38DF0 + 3 * 48
CLASS_COUNT, TERRAIN_COUNT = 19, 20
TILE_BYTES, TILE_SIZE = 128, 16
CLASS_TABLES = {"prep": 0x4DBC, "run": 0x4DCF, "swing": 0x4DE2, "attack": 0x4DF5, "total": 0x4E08, "shot": 0x4E1B}
SLOT_TABLES, TERRAIN_BACK, TERRAIN_GROUND, STRATEGY_SOUNDS = (0x4E2E, 0x4E38), 0x4E42, 0x4E56, 0x4FE2
CLASS_NAMES = 0x0FD8
BACK_MEMBERS, GROUND_MEMBERS = range(0, 5), range(5, 9)
WEATHER_NAMES, WEATHER_COUNT = 0x3A4C, 3
TEXTS = {"ambushFriendly": 0x4E6B, "ambushEnemy": 0x4E80, "strategyFailed": 0x4F45, "levelUp": 0x1305, "learned": 0x1326,
         "strategyUsed": 0x4B9E, "strategyCry": 0x4BF3, "attackIntent": 0x4BDA, "confuseIntent": 0x4BF9, "moraleIntent": 0x4C0C,
         "healIntent": 0x4C3A, "moraleDown": 0x4C22, "healed": 0x4C64, "healVerb": 0x4C4E, "raiseVerb": 0x4C5A,
         "stillConfused": 0x4C75, "confused": 0x4287, "moreConfused": 0x429D, "strategyMissed": 0x481A, "recovered": 0x4155,
         "turn": 0x3DC1, "closingBonus": 0x3D66, "delayRetreat": 0x3DA3,
         "troopsFull": 0x40E2, "troopsUp": 0x4104, "moraleFull": 0x411C, "moraleUp": 0x4138,
         "failed": 0x4EB7, "noLoss": 0x4ECD, "loss": 0x4EEA, "moraleLoss": 0x4F06, "experience": 0x4F23,
         "counterFriendly": 0x4F5B, "counterEnemy": 0x4F66, "level": 0x4FAA, "attack": 0x4FB3, "defense": 0x4FB8,
         "troops": 0x4FC2, "morale": 0x4FC7, "exp": 0x4FCC, "terrain": 0x4FD1, "percent": 0x4FD6}


def word(main: bytes, offset: int) -> int:
    return struct.unpack_from("<H", main, DATA_SEGMENT + offset)[0]


def indexed_tiles(payload: bytes) -> bytes:
    """Sequential-plane 16x16 tiles (MAIN323C3, 325B2) as one index byte per pixel."""
    if not payload or len(payload) % TILE_BYTES:
        raise ResourceError("combat view tiles do not fill their member")
    return b"".join(planar_image(payload[at:at + TILE_BYTES], TILE_SIZE, TILE_SIZE).pixels
                    for at in range(0, len(payload), TILE_BYTES))


def text(main: bytes, offset: int) -> str:
    """The message window's colour escapes and line feeds do not reach the native notice."""
    start = DATA_SEGMENT + offset
    return re.sub(r"\x1bC.", "", main[start:main.index(0, start)].decode("cp949")).replace("\n", " ").strip()


def extract(main: bytes, chr_data: bytes, chp_data: bytes, map_data: bytes) -> dict:
    if hashlib.sha256(main).hexdigest() != EXAMINED_MAIN:
        raise ResourceError("MAIN does not match the examined combat view")
    frames, maps = Archive(chr_data, "HEXBCHR.R3"), Archive(map_data, "HEXBMAP.R3")
    backgrounds = Archive(chp_data, "HEXBCHP.R3")
    if len(frames) != 181 or len(maps) != 9 or len(backgrounds) != 1:
        raise ResourceError("combat view archives differ from the examined loaders")
    background = backgrounds.decode(0).data
    if len(background) != 224 * TILE_BYTES:
        raise ResourceError("HEXBCHP differs from the examined 224 tiles")
    tiles, counts = [], []
    for member in range(len(frames)):
        data = frames.decode(member).data
        if len(data) not in (16 * TILE_BYTES, 9 * TILE_BYTES):
            raise ResourceError("HEXBCHR frame is neither 4x4 nor 3x3 tiles")
        tiles.append(indexed_tiles(data))
        counts.append(len(data) // TILE_BYTES)
    backs = [maps.decode(member).data for member in BACK_MEMBERS]
    grounds = [maps.decode(member).data for member in GROUND_MEMBERS]
    if any(len(value) != 46 * 5 for value in backs) or any(len(value) != 66 * 8 for value in grounds):
        raise ResourceError("HEXBMAP grids differ from the examined bands")
    table = lambda offset, count: list(main[DATA_SEGMENT + offset:DATA_SEGMENT + offset + count])
    terrain_back, terrain_ground = table(TERRAIN_BACK, TERRAIN_COUNT), table(TERRAIN_GROUND, TERRAIN_COUNT)
    if any(value not in BACK_MEMBERS for value in terrain_back) or any(value not in GROUND_MEMBERS for value in terrain_ground):
        raise ResourceError("combat terrain tables leave their bands")
    slots = []
    for offset in SLOT_TABLES:
        values = table(offset, 10)
        slots.append([values[index:index + 2] for index in range(0, 10, 2)])
    class_names = [text(main, word) for word in struct.unpack_from(f"<{CLASS_COUNT}H", main, DATA_SEGMENT + CLASS_NAMES)]
    encode = lambda value: base64.b64encode(value).decode("ascii")
    return {"format": 1, "palette": [list(color) for color in palette_at(main, PALETTE_OFFSET)],
            "background": encode(indexed_tiles(background)), "tiles": encode(b"".join(tiles)), "frameTiles": counts,
            "backs": [encode(value) for value in backs], "grounds": [encode(value) for value in grounds],
            "classes": {key: table(offset, CLASS_COUNT) for key, offset in CLASS_TABLES.items()},
            "classNames": class_names, "slots": slots, "terrainBack": terrain_back, "terrainGround": terrain_ground,
            "strategySounds": table(STRATEGY_SOUNDS, 3), "weathers": [text(main, word(main, WEATHER_NAMES + index * 2)) for index in range(WEATHER_COUNT)],
            "texts": {key: text(main, offset) for key, offset in TEXTS.items()},
            "source": {"methods": ["MAIN.EXE:0x32318..0x3350B", "MAIN.EXE:0x31A06..0x31CF0", "MAIN.EXE:0x2A294"],
                       "method": "static original byte interpretation; DOS program not executed"},
            "limitations": ["Step lengths are source tick floors; no original framebuffer or timing was compared.",
                            "Notices are native chips over the map, not the source message window."]}


def prepare(game: Path, output: Path) -> dict:
    game, output = game.resolve(), output.resolve()
    if output == game or game in output.parents:
        raise ResourceError("combat view output must be outside the original directory")
    before = inventory(game)
    sources = {name: read_resource(game, name) for name in ("MAIN.EXE", "HEXBCHR.R3", "HEXBCHP.R3", "HEXBMAP.R3")}
    result = extract(*(sources[name][0] for name in ("MAIN.EXE", "HEXBCHR.R3", "HEXBCHP.R3", "HEXBMAP.R3")))
    if inventory(game) != before:
        raise ResourceError("original files changed during combat view extraction")
    result["source"].update({"inputs": [item[1] for item in sources.values()], "originalFilesPreserved": True,
                             "originalProgramsExecuted": False})
    output.mkdir(parents=True, exist_ok=True)
    temporary = output / ".combat-view.json.tmp"
    temporary.write_text(json.dumps(result, ensure_ascii=False) + "\n", encoding="utf-8")
    temporary.replace(output / "combat-view.json")
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--game-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        result = prepare(args.game_dir, args.output)
    except (OSError, ValueError, ResourceError) as error:
        print(f"combat view extraction failed: {error}", file=sys.stderr)
        return 1
    print(json.dumps({"frames": len(result["frameTiles"]), "classes": len(result["classNames"]),
                      "originalFilesPreserved": result["source"]["originalFilesPreserved"]}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
