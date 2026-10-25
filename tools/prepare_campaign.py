#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Read every source campaign record; preserve unsupported execution boundaries.

The output is local original-game data and must not be published with engine
source. Complete structural coverage is not a claim of full campaign playback.
"""
from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import struct
import sys

from prepare_resources import inventory
from prepare_battles import battle_identity, battle_identity_map
from prepare_scene import (MAIN_SHA256, SceneError, extract_record, offset_sections,
                           read_resource, source_span)
from resource_formats import decode_archive
from scenario_format import (instructions, record_directory, source_operand_lengths,
                             text_sections)
from campaign_vm_format import compile_instructions, phase_groups


def record_id(chapter: int, member: int, block: int, record: int) -> str:
    return f"c{chapter}:m{member}:b{block}:r{record}"


def transition(instruction, chapter: int, member: int, block: int,
               battle_ids: dict[int, str] | None = None) -> dict | None:
    opcode, data = instruction.opcode, instruction.operands
    location = {"offset": instruction.offset, "opcode": opcode}
    if opcode == 0x09:
        packed = struct.unpack("<H", data)[0]
        is_battle = packed & 0xF000 == 0x3000
        return {"kind": "battle-map-selection" if is_battle else "map-selection",
                "target": f"map:{packed}",
                "battleID": (battle_identity(chapter, member, block) if battle_ids is None else battle_ids.get(instruction.offset)) if is_battle else None,
                "reason": "literal source selection; does not prove that the battle runner is reached",
                "source": location}
    if opcode == 0x06:
        return {"kind": "enter-current-map", "reason": "source dispatcher is map-context dependent; no map is inferred",
                "source": location}
    if opcode == 0x11:
        return {"kind": "map-resume", "target": f"map:{struct.unpack('<H', data)[0]}",
                "reason": "source context resume; not treated as an independent battle-start opcode", "source": location}
    if opcode in (0x0F, 0x15, 0x21, 0x25):
        return {"kind": "source-control-flow", "reason": "condition/choice routing is retained but not automatically evaluated",
                "source": location, "operands": data.hex()}
    return None


def preview_scene(script: bytes, descriptor: dict, text: bytes,
                  bounds: tuple[int, int], people: bytes, identity: str,
                  script_name: str, text_name: str, member: int) -> tuple[dict | None, dict]:
    # The existing town command owner remains the only interpreter of native
    # scene effects. The wider framing catalog does not grant those operations
    # executable semantics.
    commands, effects, boundary = extract_record(script, descriptor["bodyStart"],
                                                  descriptor["bodyEnd"], text, bounds, people,
                                                  allowed_maps=set(range(0x2000, 0x2017)),
                                                  script_resource=script_name, script_member=member,
                                                  text_resource=text_name)
    meaningful = any(command["op"] != "end" for command in commands)
    if not meaningful:
        return None, boundary
    placed, has_map = set(), False
    for command in commands:
        if command["op"] == "map":
            has_map, placed = True, set()
        elif command["op"] == "place":
            if not has_map:
                return None, {**boundary, "previewReason": "requires inherited map state"}
            placed.add(command["person"])
        elif command["op"] == "move":
            if not has_map or command["person"] not in placed:
                return None, {**boundary, "previewReason": "requires inherited map or actor state"}
        elif command["op"] == "remove":
            placed.discard(command["person"])
    if not has_map:
        return None, {**boundary, "previewReason": "no self-contained map state; previous source context is not fabricated"}
    caption = next((command["text"] for command in commands if command["op"] == "caption"), "")
    scene = {"format": 1, "id": identity, "name": caption or identity,
             "width": 640, "height": 400, "coordinateSystem": "town",
             "viewport": [16, 16, 512, 320],
             "coordinates": {"grid": [16, 16], "columnStaggerY": 8, "actorAnchor": [0, 24]},
             "timing": {"stepMicroseconds": 99488, "terminalMicroseconds": 99488},
             "commands": commands, "sourceEffects": effects, "boundary": boundary,
             "provenance": {"record": identity, "selection": "explicit record preview, not source trigger dispatch",
                            "limits": ["Previous actor/map state is not fabricated.",
                                       "A partial preview ends at its first unsupported instruction."]}}
    return scene, boundary


def prepare_campaign(game: Path) -> dict:
    before = inventory(game)
    main, main_source = read_resource(game, "MAIN.EXE")
    if hashlib.sha256(main).hexdigest() != MAIN_SHA256:
        raise SceneError("MAIN.EXE does not match the examined scenario framing profile")
    lengths = source_operand_lengths(main)
    people, people_source = read_resource(game, "BAKDATA.R3")
    inputs = [main_source, people_source]
    records, chapters, vm_records = [], [], []
    opcode_counts, status_counts = Counter(), Counter()
    coverage = {"chapters": 0, "members": 0, "blocks": 0, "records": 0,
                "framedCompleteRecords": 0, "framingFailures": 0,
                "supportedPreviewRecords": 0, "partialPreviewRecords": 0,
                "dataOnlyRecords": 0, "unconditionalRecords": 0}
    for chapter in range(5):
        script_name, text_name = f"SNR{chapter}D.R3", f"SNR{chapter}M.R3"
        source, script_source = read_resource(game, script_name)
        text, text_source = read_resource(game, text_name)
        inputs.extend([script_source, text_source])
        members = decode_archive(source, script_name)
        text_bounds, text_directory = text_sections(text, len(members), text_name)
        chapter_info = {"id": chapter, "members": len(members), "records": 0,
                        "textDirectory": text_directory, "source": script_source}
        coverage["chapters"] += 1
        for member in members:
            coverage["members"] += 1
            for block, (start, end) in enumerate(offset_sections(member.data, script_name, sentinel=True)):
                coverage["blocks"] += 1
                descriptors = record_directory(member.data, start, end, script_name, member.index)
                groups = phase_groups(descriptors)
                framed_records = []
                for descriptor in descriptors:
                    frames, framing_error = [], None
                    try:
                        for instruction in instructions(member.data, descriptor["bodyStart"], descriptor["bodyEnd"], lengths):
                            frames.append(instruction)
                    except SceneError as error:
                        framing_error = str(error)
                    framed_records.append((descriptor, frames, framing_error))
                selection_offsets = [instruction.offset for _, frames, _ in framed_records
                                     for instruction in frames if instruction.opcode == 0x09
                                     and struct.unpack("<H", instruction.operands)[0] & 0xF000 == 0x3000]
                battle_ids = battle_identity_map(chapter, member.index, block, selection_offsets)
                for descriptor, frames, framing_error in framed_records:
                    ordinal = descriptor["ordinal"]
                    identity = record_id(chapter, member.index, block, ordinal)
                    transitions = []
                    for instruction in frames:
                        opcode_counts[f"{instruction.opcode:02X}"] += 1
                        fact = transition(instruction, chapter, member.index, block, battle_ids)
                        if fact is not None:
                            transitions.append(fact)
                    scene, boundary = preview_scene(member.data, descriptor, text, text_bounds[member.index], people, identity,
                                                    script_name, text_name, member.index)
                    if scene is None:
                        execution = "data-only"
                        coverage["dataOnlyRecords"] += 1
                    elif boundary["status"] == "bounded-record-complete":
                        execution = "supported-record"
                        coverage["supportedPreviewRecords"] += 1
                    else:
                        execution = "partial-record"
                        coverage["partialPreviewRecords"] += 1
                    conditional = descriptor["conditionBytes"] != [0] * 8
                    if not conditional:
                        coverage["unconditionalRecords"] += 1
                    if framing_error is None:
                        coverage["framedCompleteRecords"] += 1
                    else:
                        coverage["framingFailures"] += 1
                    status_counts[execution] += 1
                    label = scene["name"] if scene is not None else identity
                    condition = descriptor["conditionBytes"]
                    vm_records.append({"id": identity, "chapter": chapter, "member": member.index,
                                       "block": block, "ordinal": ordinal,
                                       "kind": condition[0] & 0x7F,
                                       "inverted": bool(condition[0] & 0x80),
                                       "rawKind": condition[0],
                                       "words": list(struct.unpack("<3H", bytes(condition[2:8]))),
                                       "group": groups[ordinal],
                                       "instructions": compile_instructions(member.data, frames, text,
                                           text_bounds[member.index], people, main, lengths,
                                           resource=script_name, text_resource=text_name,
                                           member=member.index, battle_ids=battle_ids),
                                       "framingFailure": framing_error,
                                       "source": descriptor["source"]})
                    records.append({"id": identity, "label": label, "chapter": chapter,
                                    "member": member.index, "block": block, "record": ordinal,
                                    "conditionUnconditional": not conditional,
                                    "conditionStatus": "source event kind, inversion and phase group decoded; VM retains event arguments",
                                    "conditions": {"raw": condition, "kind": condition[0], "groupByte": condition[1],
                                                   "words": list(struct.unpack("<3H", bytes(condition[2:8])))},
                                    "executionStatus": execution, "scene": scene, "boundary": boundary,
                                    "transitions": transitions,
                                    "source": {"resource": script_name, "member": member.index,
                                               "blockStart": start, "blockEnd": end,
                                               "descriptor": descriptor["source"],
                                               "bodyStart": descriptor["bodyStart"],
                                               "nextEntryPoint": descriptor["nextEntryPoint"],
                                               "bodyBound": descriptor["bodyEnd"],
                                               "decodedMemberSha256": hashlib.sha256(member.data).hexdigest()},
                                    "framing": {"status": "complete" if framing_error is None else "unsupported",
                                                "failure": framing_error,
                                                "instructions": [{"opcode": instruction.opcode,
                                                                  "operands": instruction.operands.hex(),
                                                                  "source": instruction.source(script_name, member.data, member.index)}
                                                                 for instruction in frames]}})
                    coverage["records"] += 1
                    chapter_info["records"] += 1
        chapters.append(chapter_info)
    if before != inventory(game):
        raise SceneError("original game files changed during campaign extraction")
    return {"format": 1, "chapters": chapters, "records": records, "coverage": coverage,
            "vmProgram": {"format": 1, "records": vm_records,
                          "sourceDigest": hashlib.sha256(json.dumps(
                              [{"resource": item["resource"], "sha256": item["sha256"]} for item in inputs],
                              sort_keys=True, separators=(",", ":")).encode("utf-8")).hexdigest(),
                          "initialState": {"chapter": 0, "member": 0, "block": 0, "groupBase": 0,
                                           "packedMap": 0, "city": 0, "flags": [0] * 32},
                          "profile": "MAIN:731c8d26; source event predicates and phase dispatcher",
                          "limitations": ["Unsupported host effects stop at the literal source instruction.",
                                          "A complete record catalog does not establish full campaign playability.",
                                          "Raw text expansion requires further restoration; original yes/no selector values and order are established."]},
            "opcodeCounts": dict(sorted(opcode_counts.items())),
            "limitations": ["The complete source record catalog is not a playable full campaign.",
                            "The separate native VM evaluates source phase groups, flags and known event predicates; unsupported host effects remain boundaries.",
                            "Only supported palace commands have a native preview; other commands retain explicit boundaries.",
                            "Text offset rollover follows MAIN's two explicit base exceptions; original DOS execution is not used.",
                            "Experimental battle outcomes must not be committed as verified original campaign progress."],
            "provenance": {"method": "independent source-file parsing; no original executable execution",
                           "inputs": inputs, "originalFileCount": len(before), "originalHashesPreserved": True,
                           "mainSourceRanges": {"dispatch": "0x1C1EA..0x1C35D",
                                                "skip": "0x1C169..0x1C1C5",
                                                "records": "0x1BACC..0x1BB4A",
                                                "actualOpcode1D": "0x1C9E8..0x1CA14"},
                           "opcodeCountsScope": "record-entry traversals; shared instruction tails are counted per record",
                           "lengthTable": {"offset": 0x3A2C2, "bytes": len(lengths),
                                           "status": "framing fact, not execution semantics"}}}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--game-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    game, output = args.game_dir.resolve(), args.output.resolve()
    if output == game or game in output.parents:
        parser.error("output must be outside the original game directory")
    try:
        result = prepare_campaign(game)
        output.mkdir(parents=True, exist_ok=True)
        temporary = output / ".campaign.json.tmp"
        temporary.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
        temporary.replace(output / "campaign.json")
        print(json.dumps({"campaign": str(output / "campaign.json"), "coverage": result["coverage"]}))
        return 0 if result["coverage"]["framingFailures"] == 0 else 2
    except (SceneError, OSError, ValueError) as error:
        print(f"prepare_campaign: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
