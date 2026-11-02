#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Read original save slots into local typed data; the slot files stay untouched."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import struct
import sys

from resource_formats import ResourceError

SLOT_COUNT = 5
MSAVE_SIZE, ESAVE_SIZE = 0x2255, 0x559
ACTOR_COUNT, ACTOR_SIZE = 62, 26
PERSON_COUNT, PERSON_SIZE = 384, 18
CITY_COUNT, CITY_SIZE = 32, 6
CACHE_SIZE, SETUP_COUNT, SETUP_SIZE = 6, 45, 11
# MAIN1E7E8..1E968 writes the slot body, MAIN1B6AE the script context.
MSAVE_LAYOUT = {"date": 0x0, "title": 0x5, "player": 0x23, "game": 0x37, "return": 0x40,
                "actors": 0x49, "people": 0x695, "cities": 0x2195}
ESAVE_LAYOUT = {"chapter": 0x0, "member": 0x2, "block": 0x4, "groupBase": 0x6, "cacheCity": 0xC, "cacheMap": 0xE,
                "cache": 0x10, "cursor": 0x190, "busy": 0x192, "cacheDirty": 0x196, "music": 0x19A, "setup": 0x1A6,
                "flags": 0x395, "sourceList": 0x3B5, "objective": 0x3D6, "turnLimit": 0x557, "sourceByte2": 0x558}


def word(data: bytes, offset: int) -> int:
    return struct.unpack_from("<H", data, offset)[0]


def bcd(value: int) -> int:
    return (value >> 4) * 10 + (value & 15)


def text(data: bytes) -> str:
    return data.split(b"\0", 1)[0].decode("cp949", "replace")


def read_date(data: bytes) -> dict:
    """MAIN1F08B..1F133: BCD fields, with the month binary in the high nibble."""
    return {"year": bcd(data[0]), "month": data[1] >> 4, "day": bcd(data[2]),
            "hour": bcd(data[3]), "minute": bcd(data[4])}


def read_place(data: bytes, offset: int) -> dict:
    return {"x": data[offset], "y": data[offset + 1], "city": data[offset + 4],
            "kind": data[offset + 5], "index": data[offset + 6]}


def read_actors(data: bytes) -> list[dict]:
    """A load keeps only slots holding a shown bit (MAIN20E5E, MAIN24AA4)."""
    actors = []
    for index in range(ACTOR_COUNT):
        at = MSAVE_LAYOUT["actors"] + index * ACTOR_SIZE
        if data[at + 0xF] & 0x84:
            actors.append({"index": index, "word": word(data, at + 6), "x": data[at + 8], "y": data[at + 9],
                           "flags": data[at + 0xF], "facing": data[at + 0x15]})
    return actors


def read_people(data: bytes) -> list[dict]:
    people = []
    for index in range(PERSON_COUNT):
        row = data[MSAVE_LAYOUT["people"] + index * PERSON_SIZE:][:PERSON_SIZE]
        people.append({"flags": row[0], "role": row[1], "context2": row[2], "context3": row[3], "personal": row[4],
                       "troops": word(row, 5), "classID": row[7], "level": row[8], "experience": row[9],
                       "itemIDs": list(row[10:18])})
    return people


def read_script(data: bytes) -> dict:
    layout = ESAVE_LAYOUT
    cache = []
    for index in range(ACTOR_COUNT):
        row = data[layout["cache"] + index * CACHE_SIZE:][:CACHE_SIZE]
        cache.append({"person": word(row, 0), "x": row[2], "y": row[3], "flags": row[4], "sourceFacing": row[5]})
    setup = []
    for index in range(SETUP_COUNT):
        row = data[layout["setup"] + index * SETUP_SIZE:][:SETUP_SIZE]
        setup.append({"person": word(row, 0), "x": row[2], "y": row[3], "flags": word(row, 4), "rawMode": row[6],
                      "parameter": word(row, 7), "classID": row[9], "level": row[10]})
    count = data[layout["sourceList"]]
    if count > 32:
        raise ResourceError("ESAVE source list exceeds its 32 bytes")
    objective = text(data[layout["objective"]:layout["turnLimit"]])
    return {"chapter": word(data, layout["chapter"]), "member": word(data, layout["member"]),
            "block": word(data, layout["block"]), "groupBase": word(data, layout["groupBase"]),
            "cacheCity": word(data, layout["cacheCity"]), "cacheMap": word(data, layout["cacheMap"]),
            "cache": cache, "cursor": word(data, layout["cursor"]), "busy": word(data, layout["busy"]),
            "cacheDirty": word(data, layout["cacheDirty"]), "music": word(data, layout["music"]), "setup": setup,
            "flags": list(data[layout["flags"]:layout["flags"] + 32]),
            "sourceList": list(data[layout["sourceList"] + 1:layout["sourceList"] + 1 + count]),
            "objective": objective or None, "turnLimit": data[layout["turnLimit"]],
            "sourceByte2": data[layout["sourceByte2"]]}


def read_slot(msave: bytes, esave: bytes) -> dict:
    if len(msave) != MSAVE_SIZE:
        raise ResourceError("MSAVE differs from the examined 8789 bytes")
    if len(esave) != ESAVE_SIZE:
        raise ResourceError("ESAVE differs from the examined 1369 bytes")
    layout = MSAVE_LAYOUT
    player = layout["player"]
    cities = layout["cities"]
    return {"date": read_date(msave), "title": text(msave[layout["title"]:player]),
            "player": {"money": word(msave, player), "inputEnable": word(msave, player + 0xC),
                       "music": word(msave, player + 0xE), "city": msave[player + 0x10],
                       "chapter": msave[player + 0x12]},
            "game": read_place(msave, layout["game"]), "returnPlace": read_place(msave, layout["return"]),
            "actors": read_actors(msave), "people": read_people(msave),
            "cityFlags": [msave[cities + index * CITY_SIZE + 5] for index in range(CITY_COUNT)],
            "script": read_script(esave)}


def source(path: Path, data: bytes) -> dict:
    return {"file": path.name, "sha256": hashlib.sha256(data).hexdigest(), "size": len(data)}


def prepare(game: Path, output: Path) -> dict:
    slots, refused = [], []
    for slot in range(SLOT_COUNT):
        main_path, script_path = game / f"MSAVE{slot}.R3S", game / f"ESAVE{slot}.R3S"
        if not main_path.is_file():
            continue
        msave = main_path.read_bytes()
        # MAIN1EEC6 shows a slot with five zero date bytes as unused.
        if len(msave) >= 5 and not any(msave[:5]):
            continue
        try:
            if not script_path.is_file():
                raise ResourceError("ESAVE is missing")
            esave = script_path.read_bytes()
            row = read_slot(msave, esave)
        except ResourceError as error:
            refused.append({"slot": slot, "reason": str(error)})
            continue
        slots.append({"slot": slot, **row, "source": {"msave": source(main_path, msave),
                                                      "esave": source(script_path, esave)}})
    result = {"format": 1, "slots": slots, "refused": refused,
              "source": {"msaveLayout": MSAVE_LAYOUT, "esaveLayout": ESAVE_LAYOUT,
                         "reader": "MAIN1EC9E..1EE84, MAIN1B5C2", "originalFilesPreserved": True},
              "limitations": ["Static derivation from MAIN readers and five local slots.",
                              "RNG, live units, the retry buffer and the preserve byte have no slot storage."]}
    output.mkdir(parents=True, exist_ok=True)
    temporary = output / "saves.json.tmp"
    temporary.write_text(json.dumps(result, ensure_ascii=False) + "\n", encoding="utf-8")
    temporary.replace(output / "saves.json")
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--game-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        result = prepare(args.game_dir, args.output)
    except (OSError, ValueError, ResourceError) as error:
        print(f"save extraction failed: {error}", file=sys.stderr)
        return 1
    print(json.dumps({"slots": [row["slot"] for row in result["slots"]], "refused": len(result["refused"]),
                      "originalFilesPreserved": result["source"]["originalFilesPreserved"]}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
