#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Extract a bounded original palace record, without running the DOS program.

Only original game bytes and recorded MAIN format facts are inputs. This tool
has no dependency on a public game engine or its generated content. LS11 has
one owner in this new project's resource_formats module.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import struct
import sys

from resource_formats import decode_archive


MAIN_SHA256 = "731c8d26a39fcd4e9fa41b142db9bd5913a496a2da5eaa1db798b7867850815f"
PERSON_BASE = 0x1100
PERSON_STRIDE = 21
PERSON_COUNT = 384
# Direct MAIN static inspection established these reads: A03C increments one
# byte; A062 reads LE u16 and increments two (file 1D98C and 1D9B2).
INSTRUCTION_LENGTHS = {0x00: 3, 0x01: 6, 0x05: 1, 0x09: 3, 0x0A: 6,
                       0x0B: 3, 0x18: 3, 0x2C: 1, 0x2E: 6, 0xFF: 1}
HANDLERS = {0x00: "0x1C360", 0x01: "0x1C382", 0x05: "0x1D11C",
            0x09: "0x1D125", 0x0A: "0x1C5CC", 0x0B: "0x1C602",
            0x18: "0x1C8BE", 0x2C: "0x1CEBD", 0x2E: "0x1CF13",
            0xFF: "0x1D0C4"}
RESEARCH_REFERENCES = [
    {"project": "YeonggeoljeonMac", "path": "research/town-motion/static_findings.json",
     "used": "town coordinate, viewport, distance-neighbor order and default timing facts only"},
    {"project": "YeonggeoljeonMac", "path": "research/town-motion/disassembly.txt",
     "used": "MAIN source movement, batching and integer-coordinate instruction ranges only"},
    {"project": "YeonggeoljeonMac", "path": "research/town-motion/main-town-disassembly.txt",
     "used": "source person constructor range 0x1A9CA..0x1AAF6; no implementation code reused"},
]


class SceneError(ValueError):
    """An expected source-format failure; never guess a replacement value."""


def span(data: bytes, offset: int, size: int, context: str) -> bytes:
    if offset < 0 or size < 0 or offset + size > len(data):
        raise SceneError(f"{context}: truncated source span at {offset:#x}+{size:#x}")
    return data[offset:offset + size]


def word(data: bytes, offset: int, context: str) -> int:
    return struct.unpack("<H", span(data, offset, 2, context))[0]


def source_span(resource: str, data: bytes, offset: int, size: int,
                *, member: int | None = None) -> dict:
    result = {"resource": resource, "offset": offset, "length": size,
              "offsetSpace": "file" if member is None else "decoded-member",
              "bytes": span(data, offset, size, resource).hex()}
    if member is not None:
        result["member"] = member
    return result


def text_at(data: bytes, offset: int, end: int, resource: str) -> tuple[str, int]:
    if not 0 <= offset < end <= len(data):
        raise SceneError(f"{resource}: text offset {offset:#x} is outside its section")
    stop = data.find(b"\0", offset, end)
    if stop < 0:
        raise SceneError(f"{resource}: unterminated string at {offset:#x}")
    try:
        return data[offset:stop].decode("cp949", errors="strict"), stop + 1
    except UnicodeDecodeError as error:
        raise SceneError(f"{resource}: invalid Korean text at {offset:#x}: {error}") from error


def offset_sections(data: bytes, resource: str, *, sentinel: bool) -> list[tuple[int, int]]:
    """LE offset directory. Its first data offset is also the table's byte size."""
    first = word(data, 0, resource)
    if first < (4 if sentinel else 2) or first % 2 or first > len(data):
        raise SceneError(f"{resource}: invalid first section offset {first:#x}")
    offsets = [word(data, p, resource) for p in range(0, first, 2)]
    if sentinel:
        if offsets[-1] != 0xFFFF:
            raise SceneError(f"{resource}: missing section-directory FFFF terminator")
        offsets.pop()
    if not offsets or offsets[0] != first or any(
        not first <= value < len(data) for value in offsets
    ) or any(a >= b for a, b in zip(offsets, offsets[1:])):
        raise SceneError(f"{resource}: nonascending or out-of-bounds section directory")
    return list(zip(offsets, offsets[1:] + [len(data)]))


def first_palace_record(data: bytes) -> tuple[int, int, dict]:
    sections = offset_sections(data, "SNR0D.R3/member0", sentinel=True)
    if len(sections) <= 1:
        raise SceneError("SNR0D.R3/member0 has no established first-palace block 1")
    start, end = sections[1]
    header = span(data, start, 10, "palace record header")
    body = word(header, 8, "palace body pointer")
    # This slice supports the original unconditional record only. A conditional
    # header or additional record requires a real dispatcher, not flattening.
    if header[:8] != bytes(8):
        raise SceneError("palace record is conditional or has an unsupported trigger header")
    if body != 20 or span(data, start + 10, 10, "palace record terminator") != b"\xff" * 10:
        raise SceneError("palace block has an unsupported record directory")
    if start + body >= end:
        raise SceneError("palace body pointer exceeds the selected block")
    return start + body, end, source_span("SNR0D.R3", data, start, 20, member=0)


def person_name(people: bytes, person: int) -> tuple[str, dict]:
    if not 0 <= person < PERSON_COUNT:
        raise SceneError(f"unsupported source person id {person}")
    offset = PERSON_BASE + person * PERSON_STRIDE
    raw = span(people, offset, 6, "BAKDATA person name")
    try:
        name = raw.split(b"\0", 1)[0].decode("cp949", errors="strict")
    except UnicodeDecodeError as error:
        raise SceneError(f"BAKDATA person {person} name is invalid Korean") from error
    if not name:
        raise SceneError(f"BAKDATA person {person} has no established display name")
    return name, source_span("BAKDATA.R3", people, offset, 6)


def dialogue(text: bytes, bounds: tuple[int, int], relative: int, people: bytes,
             instruction_source: dict) -> list[dict]:
    base, end = bounds
    offset = base + relative
    result = []
    while True:
        if offset + 2 > end:
            raise SceneError(f"dialogue list is truncated at SNR0M.R3 {offset:#x}")
        person = word(text, offset, "dialogue person")
        if person == 0xFFFF:
            return result
        name, name_source = person_name(people, person)
        line, after = text_at(text, offset + 2, end, "SNR0M.R3")
        result.append({"op": "say", "person": person, "speaker": name, "text": line,
                       "source": instruction_source,
                       "textSource": source_span("SNR0M.R3", text, offset, after - offset),
                       "speakerSource": name_source})
        offset = after


def extract_record(script: bytes, start: int, end: int, text: bytes,
                   text_bounds: tuple[int, int], people: bytes) -> tuple[list, list, dict]:
    commands, effects = [], []
    offset = start
    selected_map = None
    while offset < end:
        opcode = script[offset]
        size = INSTRUCTION_LENGTHS.get(opcode)
        instruction_source = source_span("SNR0D.R3", script, offset, 1, member=0)
        if size is None:
            boundary = {"status": "unsupported-boundary", "opcode": opcode,
                        "offset": offset, "reason": f"unsupported opcode 0x{opcode:02X}"}
            commands.append({"op": "end", "reason": boundary["reason"],
                             "unsupported": True, "boundary": "unsupported", "source": instruction_source})
            return commands, effects, boundary
        try:
            if offset + size > end:
                raise SceneError("instruction operands cross the source record boundary")
            raw = span(script, offset, size, "palace instruction")
            instruction_source = source_span("SNR0D.R3", script, offset, size, member=0)
            instruction_source["opcode"] = opcode
            instruction_source["mainHandler"] = HANDLERS[opcode]
            fields = {"source": instruction_source}
            if opcode in (0x01, 0x0A):
                person = word(raw, 1, "actor id")
                if not 0 <= person < PERSON_COUNT or raw[5] > 3:
                    raise SceneError("actor id or facing is outside the source town profile")
                commands.append({"op": "move" if opcode == 1 else "place", "person": person,
                                 "x": raw[3], "y": raw[4], "facing": raw[5], **fields})
            elif opcode == 0x00:
                commands.extend(dialogue(text, text_bounds, word(raw, 1, "dialogue offset"),
                                         people, instruction_source))
            elif opcode == 0x09:
                selected_map = word(raw, 1, "packed map")
                if selected_map != 0x2000:
                    raise SceneError(f"selected record leaves the first palace map: {selected_map}")
                commands.append({"op": "map", "map": selected_map, **fields})
            elif opcode == 0x0B:
                at = text_bounds[0] + word(raw, 1, "caption offset")
                caption, after = text_at(text, at, text_bounds[1], "SNR0M.R3")
                commands.append({"op": "caption", "text": caption, **fields,
                                 "textSource": source_span("SNR0M.R3", text, at, after - at)})
            elif opcode == 0x18:
                person = word(raw, 1, "remove person")
                if not 0 <= person < PERSON_COUNT:
                    raise SceneError("remove person is outside the supported town profile")
                commands.append({"op": "remove", "person": person, **fields})
            elif opcode == 0x2E:
                effects.append({"effect": "set-city", "city": word(raw, 1, "city") & 0xFF,
                                "ignoredSourceOperands": {"x": raw[3], "y": raw[4], "facing": raw[5]},
                                "meaning": "MAIN discards x/y/facing and changes only city context; no actor reset", **fields})
            elif opcode in (0x05, 0x2C):
                commands.append({"op": "show" if opcode == 5 else "redraw", **fields})
            elif opcode == 0xFF:
                commands.append({"op": "end", "reason": "original first palace record ended (FF); later blocks are outside this slice", **fields})
                return commands, effects, {"status": "bounded-record-complete", "offset": offset,
                                           "nextBlockOffset": end, "selectedMap": selected_map}
        except SceneError as error:
            boundary = {"status": "unsupported-boundary", "opcode": opcode,
                        "offset": offset, "reason": str(error)}
            commands.append({"op": "end", "reason": boundary["reason"],
                             "unsupported": True, "boundary": "unsupported", "source": instruction_source})
            return commands, effects, boundary
        offset += size
    boundary = {"status": "unsupported-boundary", "offset": offset,
                "reason": "record boundary reached without a source FF terminator"}
    commands.append({"op": "end", "reason": boundary["reason"], "unsupported": True, "boundary": "unsupported",
                     "source": source_span("SNR0D.R3", script, end, 0, member=0)})
    return commands, effects, boundary


def read_resource(game: Path, name: str) -> tuple[bytes, dict]:
    matches = [path for path in game.iterdir() if path.name.casefold() == name.casefold()]
    if len(matches) != 1 or not matches[0].is_file():
        raise SceneError(f"{name}: expected one unambiguous source file")
    data = matches[0].read_bytes()
    return data, {"resource": name, "path": str(matches[0].resolve()), "size": len(data),
                  "sha256": hashlib.sha256(data).hexdigest()}


def prepare_scene(game: Path) -> dict:
    inputs = {name: read_resource(game, name) for name in
              ("MAIN.EXE", "SNR0D.R3", "SNR0M.R3", "BAKDATA.R3")}
    if inputs["MAIN.EXE"][1]["sha256"] != MAIN_SHA256:
        raise SceneError("MAIN.EXE does not match the source build whose opcode/town facts were examined")
    members = decode_archive(inputs["SNR0D.R3"][0], "SNR0D.R3")
    if not members:
        raise SceneError("SNR0D.R3 contains no first member")
    member = members[0]
    start, end, record_source = first_palace_record(member.data)
    text = inputs["SNR0M.R3"][0]
    text_bounds = offset_sections(text, "SNR0M.R3", sentinel=False)[0]
    commands, effects, boundary = extract_record(member.data, start, end, text,
                                                 text_bounds, inputs["BAKDATA.R3"][0])
    caption = next((c["text"] for c in commands if c["op"] == "caption"), "")
    return {"format": 1, "id": "original-opening-palace", "name": caption,
            "width": 640, "height": 400, "coordinateSystem": "town",
            "viewport": [16, 16, 512, 320],
            "coordinates": {"grid": [16, 16], "columnStaggerY": 8, "actorAnchor": [0, 24]},
            "timing": {"stepMicroseconds": 99488, "terminalMicroseconds": 99488},
            "commands": commands, "sourceEffects": effects, "boundary": boundary,
            "provenance": {"method": "independent original resource parsing and static MAIN instruction facts; no DOS execution",
                "inputs": [value[1] for value in inputs.values()], "scriptMember": member.provenance(),
                "selection": {"member": 0, "block": 1, "record": 0, "recordHeader": record_source,
                              "scriptStart": start, "scriptEndExclusive": end},
                "mainSourceRanges": {"directory": "0x1D80A..0x1D825", "recordHeader": "0x1BACC..0x1BB4A",
                    "byteReader": "0x1D98C..0x1D9AF", "wordReader": "0x1D9B2..0x1D9D4",
                    "dialogue": "0x1D246..0x1D2CB", "dispatch": "0x1C1EA..0x1C360",
                    "redraw": "0x1CEBD..0x1CEEE -> 0x2640E..0x2643A"},
                "reusedResearchReferences": RESEARCH_REFERENCES,
                "limits": ["Only SNR0 member0 block1 record0 is selected; the opening narration and later campaign blocks are not included.",
                           "No clean-room legal isolation is claimed; earlier source-bound research facts were reused, without engine code.",
                           "Integer microsecond cadence approximates source PIT average; original DOS runtime timing was not measured.",
                           "Exact original caption/dialogue pixels, sound and map transition timing are not reconstructed by this data extractor."]}}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--game-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    game, output = args.game_dir.resolve(), args.output.resolve()
    if output == game or output.is_relative_to(game):
        parser.error("output must be outside the original game directory")
    try:
        scene = prepare_scene(game)
        output.mkdir(parents=True, exist_ok=True)
        destination = output / "scene.json"
        temporary = output / ".scene.json.tmp"
        temporary.write_text(json.dumps(scene, ensure_ascii=False, indent=2) + "\n")
        temporary.replace(destination)
        summary = {"scene": str(destination), "commands": len(scene["commands"]),
                   "boundary": scene["boundary"]}
        print(json.dumps(summary, ensure_ascii=False))
        return 0 if scene["boundary"]["status"] == "bounded-record-complete" else 2
    except (SceneError, OSError, ValueError) as error:
        print(f"prepare_scene: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
