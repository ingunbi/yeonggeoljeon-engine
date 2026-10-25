#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Read original movement/range lookup windows into local-only JSON.

Original tables are inputs, not engine source constants. The class table has
nineteen entries; nominal terrain rows have a twenty-byte stride, but the source
indexes a raw terrain byte without a special255 guard. Preserve those raw lookup
windows instead of repairing the source's index semantics downstream.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import struct
import sys

from prepare_resources import EXAMINED_MAIN, inventory
from resource_formats import ResourceError

DATA_BASE = 0x37DA0
CLASS_COUNT = 19
TERRAIN_STRIDE = 20
RAW_TERRAIN_COUNT = 256
MOVEMENT_TYPES = 4


def read_window(data: bytes, offset: int, count: int, name: str) -> bytes:
    if offset < 0 or count < 0 or offset + count > len(data):
        raise ResourceError(f"{name}: original lookup window lies outside MAIN")
    return data[offset:offset + count]


def extract_profile(main: bytes) -> dict:
    digest = hashlib.sha256(main).hexdigest()
    if digest != EXAMINED_MAIN:
        raise ResourceError("MAIN does not match the examined original movement profile")
    windows = []

    def table(ds: int, size: int, name: str) -> list[int]:
        offset = DATA_BASE + ds
        data = read_window(main, offset, size, name)
        windows.append({"name": name, "resource": "MAIN.EXE", "offset": offset,
                        "dataSegmentOffset": ds, "bytes": size,
                        "sha256": hashlib.sha256(data).hexdigest()})
        return list(data)

    def offsets(ds: int, name: str) -> list[dict]:
        raw = bytes(table(ds, 16, name))
        return [{"dx": x, "dy": y} for x, y in struct.iter_unpack("<hh", raw)]

    result = {"format": 1,
              "classMovementTypes": table(0x3FFA, CLASS_COUNT, "class movement type"),
              "classMovementBudgets": table(0x3F8E, CLASS_COUNT, "class movement budget"),
              "attackRangeCodes": table(0x3FE6, CLASS_COUNT, "class attack-range code"),
              "setupOrderModes": table(0x4FE6, 512, "raw setup order mode window")[::2],
              "strategyLevelRequirements": [table(0x4510 + CLASS_COUNT * ability, CLASS_COUNT,
                                                    f"strategy {ability} class level requirements")
                                            for ability in range(36)],
              "strategyMPCosts": table(0x44EC, 36, "strategy MP costs"),
              "strategyCategories": table(0x44C8, 36, "strategy categories"),
              "strategyTerrainEligibility": [table(0x47BC+4*family,4,f"strategy terrain family {family}")
                                             for family in range(3)],
              "movementCosts": [table(0x400E + TERRAIN_STRIDE * row, RAW_TERRAIN_COUNT,
                                       f"raw terrain cost lookup movement type {row}")
                                for row in range(MOVEMENT_TYPES)],
              "cardinalOffsets": offsets(0x4D1C, "cardinal neighbor order"),
              "diagonalOffsets": offsets(0x4CFC, "diagonal range order"),
              "extendedOffsets": offsets(0x4D0C, "extended range order"),
              "scriptEnvironment": {
                  "markerTerrain": table(0x4FF4,256,"raw environment marker terrain lookup"),
                  "toggleTerrain": table(0x4FF6,256,"raw environment toggle terrain lookup"),
                  "pictureDeltas": [list(struct.unpack("<128h",bytes(table(0x4FFA+8*variant,256,
                                      f"environment picture signed delta window {variant}")))) for variant in range(2)],
                  "remapFrom": table(0x500C,9,"environment sequential picture match bytes"),
                  "remapTo": table(0x5015,9,"environment sequential picture replacement bytes"),
                  "specialMapIndices": list(struct.unpack("<19H",bytes(table(0x3DCC,38,"environment picture map variant indices"))))},
              "source": {"mainSha256": digest, "windows": windows,
                         "classCount": CLASS_COUNT, "nominalTerrainCount": TERRAIN_STRIDE,
                         "rawTerrainIndexCount": RAW_TERRAIN_COUNT,
                         "movementTypeCount": MOVEMENT_TYPES,
                         "movementClassCode": "MAIN.EXE:0x2B70C..0x2B723",
                         "budgetCode": "MAIN.EXE:0x2B17E..0x2B1F0",
                         "distanceCode": "MAIN.EXE:0x2FF1C..0x302A9",
                         "routeCode": "MAIN.EXE:0x2FCD2..0x2FF1C",
                         "rangeCode": "MAIN.EXE:0x2F578..0x2F7E0",
                         "targetScoreCode": "MAIN.EXE:0x2FAEE..0x2FCD2",
                         "orderProducerCode": "MAIN.EXE:0x3385A..0x338A8;0x2BFB8..0x2BFCE",
                         "strategyAvailabilityCode": "MAIN.EXE:0x2FFE9..0x30058",
                         "method": "read-only static derivation; original executable never run"},
              "limitations": ["This profile does not implement the complete source AI order/strategy controller.",
                               "Terrain defense lookup is owned by the combat exporter, not duplicated here.",
                               "Raw terrain255 is preserved as an original byte-index lookup, not normalized to impassable."]}
    if any(value >= MOVEMENT_TYPES for value in result["classMovementTypes"]):
        raise ResourceError("source class movement type is outside its examined row domain")
    return result


def prepare(game: Path, output: Path) -> dict:
    game, output = game.resolve(), output.resolve()
    if output == game or game in output.parents:
        raise ResourceError("movement output must remain outside the selected original directory")
    before = inventory(game)
    result = extract_profile((game / "MAIN.EXE").read_bytes())
    if before != inventory(game):
        raise ResourceError("original inputs changed during movement extraction")
    result["source"]["originalHashesPreserved"] = True
    output.mkdir(parents=True, exist_ok=True)
    pending = output / ".movement.json.tmp"
    pending.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    pending.replace(output / "movement.json")
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--game-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        result = prepare(args.game_dir, args.output)
    except (OSError, ResourceError) as error:
        print(f"movement preparation failed: {error}", file=sys.stderr)
        return 1
    print(json.dumps({"classes": len(result["classMovementTypes"]),
                      "movementTypes": len(result["movementCosts"]),
                      "rawTerrainIndices": RAW_TERRAIN_COUNT,
                      "originalHashesPreserved": result["source"]["originalHashesPreserved"]}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
