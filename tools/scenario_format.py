# SPDX-License-Identifier: GPL-3.0-only
"""Own original scenario directories and instruction framing, not execution.

Frame sizes come from the examined MAIN bytecode skip table and the explicitly
handled variable formats in MAIN's skip/dispatch code. Unsupported semantics
remain unsupported even when their byte ranges can be read.
"""
from __future__ import annotations

from dataclasses import dataclass
import struct

from prepare_scene import SceneError, offset_sections, source_span, span, word

LENGTH_TABLE_OFFSET = 0x3A2C2
LAST_OPCODE = 0x3D
UNIMPLEMENTED_OPCODES = {0x19}


@dataclass(frozen=True)
class Instruction:
    opcode: int
    offset: int
    end: int
    operands: bytes

    def source(self, resource: str, data: bytes, member: int) -> dict:
        result = source_span(resource, data, self.offset, self.end - self.offset, member=member)
        result["opcode"] = self.opcode
        return result


def source_operand_lengths(main: bytes) -> bytes:
    table = span(main, LENGTH_TABLE_OFFSET, LAST_OPCODE + 1, "MAIN instruction skip table")
    # Distinct established fixed instructions anchor the selected table, avoiding
    # interpreting a neighbouring text block or a different executable edition.
    if [table[n] for n in (0, 1, 3, 9, 10, 0x22, 0x2E)] != [2, 5, 25, 2, 5, 135, 5]:
        raise SceneError("MAIN instruction skip table does not match the examined profile")
    return table


def read_instruction(data: bytes, offset: int, end: int, operand_lengths: bytes) -> Instruction:
    if not 0 <= offset < end <= len(data):
        raise SceneError("instruction offset lies outside its source body")
    opcode = data[offset]
    if opcode == 0xFF:
        return Instruction(opcode, offset, offset + 1, b"")
    if opcode > LAST_OPCODE or opcode in UNIMPLEMENTED_OPCODES or len(operand_lengths) <= opcode:
        raise SceneError(f"unsupported source opcode 0x{opcode:02X} at {offset:#x}")
    size = 1 + operand_lengths[opcode]
    if opcode in (0x03, 0x22):
        # MAIN 0x1C190 and 0x1C1BF use 16-bit counts; the byte table stores only
        # the low byte, so treating these as ordinary table entries is incorrect.
        size = 282 if opcode == 0x03 else 392
    elif opcode == 0x1D:
        # The actual handler reads one word and two bytes (MAIN 1C9E8..1CA14).
        # Its skip-table byte is only two; execution framing must not inherit
        # that separate skip implementation's narrower count.
        size = 5
    elif opcode in (0x20, 0x32):
        count = span(data, offset + 1, 1, "variable instruction count")[0]
        size = 2 + (count & 0x7F if opcode == 0x20 else count)
    elif opcode == 0x21:
        prefix = span(data, offset + 1, 2, "conditional skip header")
        positive = prefix[1]
        negative_at = offset + 3 + positive
        if negative_at >= end:
            raise SceneError("conditional positive flag list crosses the record boundary")
        negative = data[negative_at]
        size = negative_at + 1 + negative - offset
    elif opcode == 0x1C:
        attr = span(data, offset + 3, 1, "battle attribute selector")[0]
        # Every established selector 0..6 consumes two extra bytes; other
        # selectors branch directly out of MAIN's attribute handler.
        size = 6 if attr <= 6 else 4
    if offset + size > end:
        raise SceneError(f"opcode 0x{opcode:02X} operands cross the record boundary at {offset:#x}")
    return Instruction(opcode, offset, offset + size, data[offset + 1:offset + size])


def instructions(data: bytes, start: int, end: int, operand_lengths: bytes):
    cursor = start
    while cursor < end:
        instruction = read_instruction(data, cursor, end, operand_lengths)
        yield instruction
        cursor = instruction.end
        if instruction.opcode == 0xFF:
            return
    raise SceneError("record body reached its bound without a source FF terminator")


def record_directory(data: bytes, start: int, end: int, resource: str, member: int) -> list[dict]:
    """Read ten-byte condition descriptors and retain body alias identities."""
    if not 0 <= start < end <= len(data):
        raise SceneError("record directory has invalid source bounds")
    cursor, records = start, []
    while cursor + 10 <= end:
        header = data[cursor:cursor + 10]
        if header == b"\xff" * 10:
            cursor += 10
            break
        body_relative = word(header, 8, "record body pointer")
        records.append({"ordinal": len(records), "headerOffset": cursor,
                        "conditionBytes": list(header[:8]), "bodyRelative": body_relative,
                        "source": source_span(resource, data, cursor, 10, member=member)})
        cursor += 10
    else:
        raise SceneError("record directory has no complete ten-byte sentinel")
    if not records:
        raise SceneError("record directory has no records")
    body_starts = sorted({start + r["bodyRelative"] for r in records})
    if body_starts[0] < cursor or body_starts[-1] >= end:
        raise SceneError("record body pointer overlaps its directory or exceeds its block")
    next_entries = dict(zip(body_starts, body_starts[1:] + [end]))
    for record in records:
        record["bodyStart"] = start + record["bodyRelative"]
        # A descriptor is an entry point into the block stream, not ownership
        # of bytes until the next descriptor. Source MAIN keeps reading until
        # FF and can fall through another record's entry point.
        record["nextEntryPoint"] = next_entries[record["bodyStart"]]
        record["bodyEnd"] = end
    return records


def text_sections(data: bytes, expected_count: int, resource: str) -> tuple[list[tuple[int, int]], dict]:
    """Own the examined MAIN1B480 reader's explicit 16-bit base exceptions.

    MAIN1B4B4..1B4D1 adds one 64KiB epoch for either of its two immediate
    base values. Other values are zero-extended. This is source-derived static
    execution meaning, not a general guess that every descending value wraps.
    """
    first = word(data, 0, resource)
    if first != expected_count * 2 or first > len(data):
        raise SceneError(f"{resource}: text group count differs from script member count")
    raw = [word(data, at, resource) for at in range(0, first, 2)]
    starts, wrapped = [], 0
    for value in raw:
        candidate = value + (0x10000 if value in (0x1029, 0x59D0) else 0)
        if candidate >= 0x10000:
            wrapped += 1
        if candidate < first or candidate >= len(data) or (starts and candidate <= starts[-1]):
            raise SceneError(f"{resource}: unwrapped text group start exceeds the file")
        starts.append(candidate)
    bounds = list(zip(starts, starts[1:] + [len(data)]))
    if any(not 0 < end - start < 0x10000 for start, end in bounds):
        raise SceneError(f"{resource}: text group span has ambiguous 16-bit wrap ownership")
    return bounds, {"rawDirectory": raw, "fileStarts": starts, "rollovers": int(wrapped > 0),
                    "wrappedMembers": wrapped, "source": "MAIN.EXE:0x1B480..0x1B4F8",
                    "status": "static original reader: explicit base exceptions and 32-bit relative addition; no original execution"}
