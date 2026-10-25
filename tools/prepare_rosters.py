#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Export typed original placement producers, without choosing campaign paths."""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import struct
import sys

from prepare_resources import EXAMINED_MAIN, inventory
from prepare_scene import SceneError, offset_sections, read_resource
from resource_formats import Archive
from scenario_format import instructions, record_directory, source_operand_lengths


def decode_setup(data: bytes, opcode: int) -> dict:
    header, stride = (11, 9) if opcode == 3 else (1, 13)
    if opcode not in (3, 0x22) or len(data) != header + 30 * stride:
        raise SceneError("original placement producer has invalid opcode/extent")
    rows = []
    for index in range(30):
        raw = data[header + index * stride:header + (index + 1) * stride]
        if opcode == 3:
            side, selector, flag, flip, hidden = raw[4:9]
            mode, parameter, cls, level = 255, 65535, 255, 255
        else:
            selector, flag, flip, hidden, mode = raw[4:9]
            side = data[0]
            parameter = struct.unpack_from("<H", raw, 9)[0]
            cls, level = raw[11:13]
        rows.append({"ordinal": index, "person": struct.unpack_from("<H", raw)[0],
                     "x": raw[2], "y": raw[3], "selector": selector, "flag": flag,
                     "flags": (int(side == 0) | (4 if flip == 1 else 0) | (2 if hidden >= 1 else 0)),
                     "rawMode": mode, "parameter": parameter, "classID": cls, "level": level})
    result = {"opcode": opcode, "rows": rows, "replaceSide": None if opcode == 3 else int(data[0] == 0)}
    if opcode == 3:
        # MAIN1C40B..1C481 consumes all eleven bytes; two discarded bytes
        # remain explicitly separate from objective enable/person pairs.
        result["header"] = {"preserveFriendlySlots": data[0] != 0, "turnLimit": data[1],
                            "sourceByte2": data[2], "discardedBytes": [data[3], data[7]],
                            "objectives": [{"eventKind": 7, "enabled": data[4] != 0,
                                            "person": struct.unpack_from("<H", data, 5)[0]},
                                           {"eventKind": 8, "enabled": data[8] != 0,
                                            "person": struct.unpack_from("<H", data, 9)[0]}]}
    else:
        result["header"] = None
    return result


def prepare(game: Path, output: Path) -> dict:
    game, output = game.resolve(), output.resolve()
    if output == game or game in output.parents:
        raise SceneError("roster output must be outside the original directory")
    before = inventory(game)
    main, main_source = read_resource(game, "MAIN.EXE")
    if hashlib.sha256(main).hexdigest() != EXAMINED_MAIN:
        raise SceneError("MAIN does not match the examined placement profile")
    lengths = source_operand_lengths(main)
    programs = []
    for chapter in range(5):
        name = f"SNR{chapter}D.R3"
        carrier, _ = read_resource(game, name)
        archive = Archive(carrier, name)
        for member_id in range(len(archive)):
            member = archive.decode(member_id)
            seen = set()
            for block, (start, end) in enumerate(offset_sections(member.data, name, sentinel=True)):
                for record in record_directory(member.data, start, end, name, member_id):
                    for frame in instructions(member.data, record["bodyStart"], record["bodyEnd"], lengths):
                        if frame.opcode not in (3, 0x22) or frame.offset in seen:
                            continue
                        seen.add(frame.offset)
                        result = decode_setup(frame.operands, frame.opcode)
                        result.update({"chapter": chapter, "member": member_id, "block": block,
                                       "offset": frame.offset, "source": frame.source(name, member.data, member_id)})
                        programs.append(result)
    if inventory(game) != before:
        raise SceneError("original files changed during placement extraction")
    result = {"format": 1, "programs": programs,
              "source": {"main": main_source, "originalHashesPreserved": True,
                         "producer": "MAIN1C3F2..1C539/1CB0D..1CC8E", "originalProgramsExecuted": False}}
    output.mkdir(parents=True, exist_ok=True)
    (output / "rosters.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--game-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        result = prepare(args.game_dir, args.output)
    except (OSError, ValueError) as error:
        print(f"roster preparation failed: {error}", file=sys.stderr)
        return 1
    print(json.dumps({"placementPrograms": len(result["programs"]), "originalHashesPreserved": True}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
