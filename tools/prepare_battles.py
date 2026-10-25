#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Read source battle maps and placement programs into a local-only catalog.

This is static extraction, not original campaign execution. Conditional roster
eligibility is retained as unknown. Lexical setup inheritance is labelled rather
than presented as proof of a particular campaign branch.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import struct
import sys

from prepare_resources import EXAMINED_MAIN, inventory, paint, palette_at
from prepare_scene import SceneError, offset_sections, person_name, read_resource, source_span
from resource_formats import Archive, IndexedImage, ResourceError, planar_image, png_bytes
from scenario_format import instructions, record_directory, source_operand_lengths


def battle_identity(chapter: int, member: int, block: int, site_ordinal: int = 0) -> str:
    """Own stable IDs for sorted, distinct kind3 load-map sites in one block."""
    if any(not isinstance(value, int) or value < 0 for value in (chapter, member, block, site_ordinal)):
        raise SceneError("battle identity components must be nonnegative source ordinals")
    base = f"{chapter}:{member}:{block}"
    return base + (f":{site_ordinal}" if site_ordinal else "")


def battle_identity_map(chapter: int, member: int, block: int, offsets) -> dict[int, str]:
    return {offset: battle_identity(chapter, member, block, ordinal)
            for ordinal, offset in enumerate(sorted(set(offsets)))}


def map_record(payload: bytes, index: int, source: dict) -> dict:
    if len(payload) < 2:
        raise ResourceError("battle map lacks its two-byte picture dimensions")
    columns, rows = payload[:2]
    if not columns or not rows or columns % 2 or rows % 2:
        raise ResourceError("battle map picture dimensions must be positive and even")
    width, height = columns // 2, rows // 2
    pictures, cells = columns * rows, width * height
    if len(payload) != 2 + pictures + cells:
        raise ResourceError("battle map tile and terrain spans do not cover its member")
    terrain = list(payload[2 + pictures:])
    return {"id": index, "width": width, "height": height,
            "coordinateSystem": "orthogonal", "tiles": terrain,
            "pictureColumns": columns, "pictureRows": rows,
            "pictureTiles": list(payload[2:2 + pictures]),
            "image": None,
            "source": {**source, "pictureDecodedOffset": 2,
                       "terrainDecodedOffset": 2 + pictures,
                       "geometryCode": "MAIN.EXE:0x26DF1..0x26E72",
                       "neighborCode": "MAIN.EXE:0x2FCD2..0x2FF19; DS:4D1C"}}


def placement_units(operands: bytes, opcode: int, source: dict, people: bytes) -> tuple[list, list, dict]:
    """Read source records without resolving campaign eligibility flags.

    IDs are export-local placement identities. Original insertion into the
    runtime's 45-entry table is conditional and is not reconstructed here.
    """
    if opcode not in (3, 0x22):
        raise SceneError("not a battle placement producer")
    header, stride = (11, 9) if opcode == 3 else (1, 13)
    if len(operands) != header + 30 * stride:
        raise SceneError("placement producer has an incomplete header or thirty-record table")
    known, conditional = [], []
    for ordinal in range(30):
        at = header + ordinal * stride
        raw = operands[at:at + stride]
        person = struct.unpack_from("<H", raw)[0]
        if person == 0xFFFF:
            continue
        if not 0 <= person < 384:
            # Dynamic roster placeholders are source facts, not resolved people.
            conditional.append({"id": ordinal + (30 if opcode == 0x22 else 0),
                                "person": None, "side": None, "x": raw[2], "y": raw[3],
                                "initiallyActive": None,
                                "source": {**source, "slot": ordinal, "recordBytes": raw.hex(),
                                           "rawPerson": person, "runtimeSlot": None,
                                           "eligibility": "unresolved dynamic roster placeholder"}})
            continue
        name, name_source = person_name(people, person)
        eligible_selector = raw[5] if opcode == 3 else raw[4]
        flag_id = raw[6] if opcode == 3 else raw[5]
        side_bit = raw[4] if opcode == 3 else operands[0]
        hidden = raw[8] if opcode == 3 else raw[7]
        unit_source = {**source, "slot": ordinal, "recordBytes": raw.hex(),
                       "decodedRecordOffset": source["offset"] + 1 + at,
                       "sourceSideOperand": side_bit, "sourcePlacementSideBit": 0 if side_bit else 1,
                       "runtimeSlot": None,
                       "eligibility": {"status": "unconditional" if not eligible_selector else "campaign flag unresolved",
                                       "selector": eligible_selector, "flag": flag_id},
                       "sourceHiddenOperand": hidden, "nameSource": name_source,
                       "placementCode": "MAIN.EXE:0x1C3F2..0x1C539" if opcode == 3 else "MAIN.EXE:0x1CB0D..0x1CC8E",
                       "activationCode": "MAIN.EXE:0x26E8C..0x27010"}
        # Source compares the literal side operand with1, then SBB/NEG inverts
        # its zero/nonzero meaning into placement flag bit0. Native display
        # side0 is that source flag0 roster; retain operand and flag separately.
        unit = {"id": ordinal + (30 if opcode == 0x22 else 0), "person": person,
                "name": name, "side": 0 if side_bit else 1,
                "x": raw[2], "y": raw[3],
                "initiallyActive": None if eligible_selector else hidden == 0,
                "hp": None, "maxHP": None, "attack": None, "defense": None,
                "movement": None, "range": None, "source": unit_source}
        (conditional if eligible_selector else known).append(unit)
    metadata = {"source": source, "headerBytes": operands[:header].hex(),
                "recordCount": 30, "recordStride": stride,
                "sideReplacementBit": None if opcode == 3 else int(bool(operands[0]))}
    return known, conditional, metadata


def export_maps(game: Path, output: Path, main: bytes) -> tuple[list, list]:
    carrier, _ = read_resource(game, "HEXZMAP.R3")
    archive = Archive(carrier, "HEXZMAP.R3")
    if len(archive) != 59:
        raise ResourceError("examined HEXZMAP profile requires 58 maps and one text member")
    chips_bytes, _ = read_resource(game, "HEXZCHP.R3")
    chips = Archive(chips_bytes, "HEXZCHP.R3")
    if len(chips) != 3:
        raise ResourceError("examined HEXZCHP profile requires three tile banks")
    banks = [chips.decode(i) for i in range(3)]
    if [len(bank.data) for bank in banks] != [10240, 22272, 22400]:
        raise ResourceError("source tile bank sizes differ from the examined graphics loader")
    alternate = set(struct.unpack_from("<19H", main, 0x37DA0 + 0x3DCC))
    colors = palette_at(main, 0x38DF0 + 3 * 48)
    maps = []
    for index in range(58):
        member = archive.decode(index)
        record = map_record(member.data, index, member.provenance())
        bank_id = 2 if index in alternate else 1
        data = banks[0].data + banks[bank_id].data
        tile_images = [planar_image(data[offset:offset + 128], 16, 16)
                       for offset in range(0, len(data), 128)]
        canvas_width, canvas_height = record["pictureColumns"] * 16, record["pictureRows"] * 16
        pixels = bytearray(canvas_width * canvas_height)
        for ordinal, tile in enumerate(record["pictureTiles"]):
            if tile >= len(tile_images):
                raise ResourceError(f"map {index} references absent source tile {tile}")
            paint(pixels, canvas_width, canvas_height, tile_images[tile],
                  ordinal % record["pictureColumns"] * 16, ordinal // record["pictureColumns"] * 16)
        relative = f"images/battle-map-{index:02}.png"
        (output / "images").mkdir(exist_ok=True)
        (output / relative).write_bytes(png_bytes(IndexedImage(canvas_width, canvas_height, bytes(pixels)), colors))
        record["image"] = relative
        record["source"]["graphics"] = {"commonBank": banks[0].provenance(), "selectedBank": banks[bank_id].provenance(),
                                           "selectorTableOffset": 0x37DA0 + 0x3DCC,
                                           "selectorCode": "MAIN.EXE:0x2827A..0x282AA",
                                           "loaderCode": "MAIN.EXE:0x26C9C..0x26E82",
                                           "palette": {"resource": "MAIN.EXE", "offset": 0x38DF0 + 3 * 48, "bytes": 48,
                                                       "selectorCode": "MAIN.EXE:0x20183..0x20194;0x1E628..0x1E635;0x15B3A..0x15B44;0x182CE..0x18372"},
                                           "pixelParity": "not compared with an original DOS framebuffer"}
        maps.append(record)
    return maps, ["Original terrain movement costs, damage, AI and objectives are not exported as verified rules.",
                  "Map pictures use source tiles and source palette selection; original DOS framebuffer parity is unverified."]


def prepare(game: Path, output: Path) -> dict:
    game, output = game.resolve(), output.resolve()
    if output == game or game in output.parents:
        raise ResourceError("battle output must be outside the original directory")
    before = inventory(game)
    main, _ = read_resource(game, "MAIN.EXE")
    if hashlib.sha256(main).hexdigest() != EXAMINED_MAIN:
        raise ResourceError("MAIN does not match the examined battle profile")
    lengths = source_operand_lengths(main)
    people, _ = read_resource(game, "BAKDATA.R3")
    output.mkdir(parents=True, exist_ok=True)
    maps, limitations = export_maps(game, output, main)
    definitions, failures, sources = [], [], []
    for chapter in range(5):
        resource = f"SNR{chapter}D.R3"
        carrier, identity = read_resource(game, resource)
        sources.append(identity)
        archive = Archive(carrier, resource)
        for member_id in range(len(archive)):
            member = archive.decode(member_id)
            previous_setup = None
            previous_enemies = None
            for block_id, (start, end) in enumerate(offset_sections(member.data, resource, sentinel=True)):
                records = record_directory(member.data, start, end, resource, member_id)
                found = {}
                for record in records:
                    try:
                        for instruction in instructions(member.data, record["bodyStart"], record["bodyEnd"], lengths):
                            found.setdefault(instruction.offset, (instruction, record))
                    except SceneError as error:
                        failures.append({"chapter": chapter, "member": member_id, "block": block_id,
                                         "record": record["ordinal"], "reason": str(error)})
                battle_maps = []
                for _, (instruction, record) in sorted(found.items()):
                    source = instruction.source(resource, member.data, member_id)
                    source.update({"chapter": chapter, "block": block_id, "record": record["ordinal"],
                                   "recordConditionBytes": record["conditionBytes"]})
                    if instruction.opcode in (3, 0x22):
                        value = placement_units(instruction.operands, instruction.opcode, source, people)
                        if instruction.opcode == 3:
                            previous_setup = value
                            previous_enemies = None
                        else:
                            previous_enemies = value
                    elif instruction.opcode == 9:
                        packed = struct.unpack("<H", instruction.operands)[0]
                        if packed >> 12 == 3:
                            battle_maps.append((packed & 0xFFF, source, previous_setup, previous_enemies))
                for variant, (map_id, source, setup, enemies) in enumerate(battle_maps):
                    identity = battle_identity(chapter, member_id, block_id, variant)
                    known, conditional, producer_sources = [], [], []
                    for producer in (setup, enemies):
                        if producer is not None:
                            a, b, meta = producer
                            known.extend(a); conditional.extend(b); producer_sources.append(meta)
                    # Repeated source commands can replace a side. A projection
                    # with duplicate people/coordinates is retained but unplayable.
                    selected = maps[map_id] if 0 <= map_id < len(maps) else None
                    result = {"id": identity, "name": None,
                              "width": selected["width"] if selected else None,
                              "height": selected["height"] if selected else None,
                              "coordinateSystem": "orthogonal" if selected else None,
                              "tiles": selected["tiles"] if selected else None,
                              "image": selected["image"] if selected else None,
                              "units": known, "conditionalUnits": conditional,
                              "rosterScope": "unconditional-placement-records-only",
                              "originalRosterComplete": False,
                              "source": {**source, "packedMap": 0x3000 | map_id, "mapIndex": map_id,
                                         "map": selected["source"] if selected else None,
                                         "placementProducers": producer_sources,
                                         "inheritance": "lexical source-order projection; campaign trigger/branch eligibility not executed"},
                              "rules": {"status": "unsupported-original-rules", "damage": None, "movementCosts": None,
                                        "AI": None, "objectives": None},
                              "limitations": ["Only unconditional placement records are projected; conditional units remain unresolved.",
                                              "Lexical producer inheritance does not prove a reachable campaign state."]}
                    definitions.append(result)
    if before != inventory(game):
        raise ResourceError("original files changed during battle extraction")
    result = {"format": 1, "battles": definitions,
              "maps": maps,
              "provenance": {"originalFiles": before, "originalHashesPreserved": True,
                             "sources": sources, "mainSha256": EXAMINED_MAIN,
                             "method": "read-only resource decoding and MAIN static derivation; original programs never executed",
                             "framingFailures": failures},
              "limitations": limitations}
    (output / "battles.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--game-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        result = prepare(args.game_dir, args.output)
    except (OSError, ResourceError, SceneError) as error:
        print(f"battle preparation failed: {error}", file=sys.stderr)
        return 1
    print(json.dumps({"battles": len(result["battles"]), "maps": len(result["maps"]),
                      "framingFailures": len(result["provenance"]["framingFailures"]),
                      "originalHashesPreserved": result["provenance"]["originalHashesPreserved"]}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
