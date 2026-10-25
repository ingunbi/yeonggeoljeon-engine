#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Extract source combat tables into local data; do not distribute the output."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import sys

from prepare_resources import EXAMINED_MAIN, inventory
from prepare_scene import read_resource
from resource_formats import ResourceError

DGROUP = 0x37DA0
CLASS_COUNT = 19
ITEM_COUNT = 64
ITEM_BASE = 0xD00
ITEM_STRIDE = 16
TABLES = {
    "attackBase": (0x0FFE, CLASS_COUNT),
    "defenseBase": (0x1012, CLASS_COUNT),
    "troopBase": (0x1338, CLASS_COUNT),
    "troopGrowth": (0x134C, CLASS_COUNT),
    "physicalSubtypeByClass": (0x3FD2, CLASS_COUNT),
    # Source uses a raw byte index without a nominal-terrain bound check.
    # Preserve that entire 256-byte view, including reads past the20-name table.
    "terrainDefensePercent": (0x405E, 256),
    # MAIN28368 indexes this view with raw battle-object byte4.
    "strategyEnvironmentLookup": (0x3B7C, 256),
}


def extract_tables(main: bytes, bak: bytes) -> dict:
    if hashlib.sha256(main).hexdigest() != EXAMINED_MAIN:
        raise ResourceError("MAIN does not match the examined original combat profile")
    if len(bak) != 19328 or ITEM_BASE + ITEM_COUNT * ITEM_STRIDE > len(bak):
        raise ResourceError("BAKDATA does not match the examined item/people layout")
    result = {"format": 1}
    source_tables = {}
    for name, (relative, count) in TABLES.items():
        offset = DGROUP + relative
        values = main[offset:offset + count]
        if len(values) != count:
            raise ResourceError(f"{name} table exceeds MAIN")
        result[name] = list(values)
        source_tables[name] = {"resource": "MAIN.EXE", "offset": offset,
                               "dataSegmentOffset": relative, "bytes": count,
                               "sha256": hashlib.sha256(values).hexdigest()}
        if name == "terrainDefensePercent":
            source_tables[name].update({"nominalTerrainCount":20,"rawIndexDomain":256,
                                       "selection":"DS405E plus the source raw terrain byte; no table clamp"})
        if name == "strategyEnvironmentLookup":
            source_tables[name].update({"nominalStateCount":6,"rawIndexDomain":256,
                                       "selection":"DS3B7C plus battle-object byte4; enum labels unproven"})
        if name == "physicalSubtypeByClass":
            source_tables[name]["selection"] = "normal player/AI attack subtype; zero also permits counter roll"
    # MAIN 1E774..1E78C reads these 64 sixteen-byte records. The constructor
    # 1B162..1B1BA copies raw14 to value and clamps raw15 into category0..15.
    result["items"] = [
        {"id": i, "category": min(15, bak[ITEM_BASE + i * ITEM_STRIDE + 15]),
         "value": bak[ITEM_BASE + i * ITEM_STRIDE + 14],
         "source": {"resource": "BAKDATA.R3", "offset": ITEM_BASE + i * ITEM_STRIDE,
                    "bytes": ITEM_STRIDE, "valueByteOffset": 14, "categoryByteOffset": 15,
                    "rawCategory": bak[ITEM_BASE + i * ITEM_STRIDE + 15]}}
        for i in range(ITEM_COUNT)
    ]
    result["source"] = {
        "mainSha256": EXAMINED_MAIN,
        "bakSha256": hashlib.sha256(bak).hexdigest(), "tables": source_tables,
        "methods": ["MAIN.EXE:0x1A43E..0x1A53D", "MAIN.EXE:0x1A56C..0x1A66B",
                    "MAIN.EXE:0x1AD08..0x1AD31", "MAIN.EXE:0x31474..0x317CB",
                    "MAIN.EXE:0x317CC..0x31853", "MAIN.EXE:0x3198E..0x31A04",
                    "MAIN.EXE:0x321E2..0x32317", "MAIN.EXE:0x181D4..0x18227",
                    "MAIN.EXE:0x31854..0x31925", "MAIN.EXE:0x1A8B4..0x1A9C8",
                    "MAIN.EXE:0x2D60A..0x2D62C", "MAIN.EXE:0x28368..0x28378",
                    "MAIN.EXE:0x2B228..0x2B43B", "MAIN.EXE:0x2B690..0x2B708",
                    "MAIN.EXE:0x2C6E4..0x2C727", "MAIN.EXE:0x2D5DA..0x2D606",
                    "MAIN.EXE:0x31FDB..0x3216F", "MAIN.EXE:0x2BEEC..0x2BF51",
                    "MAIN.EXE:0x2D630..0x2D67E", "MAIN.EXE:0x2D80A..0x2D8F0",
                    "MAIN.EXE:0x2D760..0x2D808", "MAIN.EXE:0x2EE20..0x2F052",
                    "MAIN.EXE:0x2E836..0x2EE1C"],
        "method": "static original byte interpretation; DOS program not executed",
    }
    result["limitations"] = [
        "Physical strike arithmetic and derived stats are separate from full battle-state execution.",
        "Original live combat/framebuffer parity is not established by table extraction.",
        "Strategy command eligibility/cost/range, battle victory triggers and animation remain separate owners.",
    ]
    return result


def prepare(game: Path, output: Path) -> dict:
    game, output = game.resolve(), output.resolve()
    if output == game or game in output.parents:
        raise ResourceError("combat output must be outside the original directory")
    before = inventory(game)
    main, _ = read_resource(game, "MAIN.EXE")
    bak, _ = read_resource(game, "BAKDATA.R3")
    result = extract_tables(main, bak)
    if inventory(game) != before:
        raise ResourceError("original files changed during combat table extraction")
    result["source"]["originalFilesPreserved"] = True
    output.mkdir(parents=True, exist_ok=True)
    temporary = output / ".combat.json.tmp"
    temporary.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(output / "combat.json")
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--game-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        result = prepare(args.game_dir, args.output)
    except (OSError, ResourceError) as error:
        print(f"combat extraction failed: {error}", file=sys.stderr)
        return 1
    print(json.dumps({"classes": len(result["attackBase"]), "items": len(result["items"]),
                      "terrainDefenseEntries": len(result["terrainDefensePercent"]),
                      "originalFilesPreserved": result["source"]["originalFilesPreserved"]}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
