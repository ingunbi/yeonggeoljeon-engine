# SPDX-License-Identifier: GPL-3.0-only
"""Normalize original scenario execution facts at the source-format boundary.

This module owns bytecode operands, phase groups and the original skip walker.
The native VM consumes typed effects; it never reparses retained byte strings.
Unknown host operations remain explicit and cannot be acknowledged as no-ops.
"""
from __future__ import annotations

import struct

from prepare_scene import SceneError, dialogue, source_span, span, text_at


MAIN_DATA_SEGMENT = 0x37DA0
# main 1E5DD..1E5E7: push ds; push 2A2E; push 2; far call CF5:3C5E.
RETRY_PROMPT_CALL = 0x1E5DD
RETRY_PROMPT_CALL_LENGTH = 11
RETRY_PROMPT_POINTER = 0x2A2E
RETRY_PROMPT_SELECTOR = (0x0CF5, 0x3C5E)


def framework_prompts(main: bytes) -> dict:
    """Text owned by MAIN's outer framework rather than a scenario member.

    After the framework map loop returns mask 20/40, main shows this text in
    the two-button selector (Yes returns one, No returns zero). The producer
    checks the examined push sequence instead of trusting a bare offset.
    """
    call = span(main, RETRY_PROMPT_CALL, RETRY_PROMPT_CALL_LENGTH, "MAIN.EXE")
    if (call[0], call[1], call[4], call[5], call[6]) != (0x1E, 0x68, 0x6A, 2, 0x9A) or \
            struct.unpack_from("<H", call, 2)[0] != RETRY_PROMPT_POINTER or \
            struct.unpack_from("<HH", call, 7) != RETRY_PROMPT_SELECTOR[::-1]:
        raise SceneError("MAIN.EXE retry selector call does not match the examined profile")
    at = MAIN_DATA_SEGMENT + RETRY_PROMPT_POINTER
    value, after = text_at(main, at, len(main), "MAIN.EXE")
    if not value:
        raise SceneError("MAIN.EXE retry selector text is empty")
    return {"retryPrompt": {"text": value,
                            "textSource": source_span("MAIN.EXE", main, at, after - at),
                            "callSource": source_span("MAIN.EXE", main, RETRY_PROMPT_CALL, RETRY_PROMPT_CALL_LENGTH),
                            "selectorMode": 2, "yesResult": 1, "noResult": 0,
                            "presentationOrder": [1, 0]}}


def stock_caption_index(text: str) -> int:
    """MAIN 18106..181D0 retains the last character in ASCII 30..41.

    It is not decimal conversion: ':', ';', '<', '=', '>', '?', '@', 'A'
    select indices ten through seventeen, and repeated digits select once.
    """
    result = 0
    for character in text:
        value = ord(character) - 0x30
        if 0 <= value <= 0x11:
            result = value
    return result


def phase_groups(descriptors: list[dict]) -> dict[int, dict]:
    """MAIN 1B37A..1B3D3: only the first group byte loses its high bit."""
    result, base = {}, 0
    while base < len(descriptors):
        marker = descriptors[base]["conditionBytes"][1]
        end = base + 1
        while end < len(descriptors) and descriptors[end]["conditionBytes"][1] == marker & 0x7F:
            end += 1
        if end - base > 127:
            raise SceneError("source phase count exceeds the source seven-bit dispatch count")
        group = {"base": base, "count": end - base, "repeating": bool(marker & 0x80)}
        for ordinal in range(base, end):
            result[ordinal] = group
        base = end
    return result


def source_skip_target(data: bytes, start: int, count: int, end: int, lengths: bytes) -> int:
    """Follow MAIN 1C169..1C1C5, including its distinct 1D/21 behavior.

    Execution-frame lengths are deliberately not reused. A caller verifies the
    returned cursor is an execution entry point before offering it to the VM.
    """
    cursor = start
    for _ in range(count):
        opcode = span(data, cursor, 1, "source skipped opcode")[0]
        cursor += 1
        if opcode >= len(lengths):
            raise SceneError("source skip walker indexed beyond the examined opcode table")
        if opcode == 3:
            cursor += 0x119
        elif opcode == 0x22:
            cursor += 0x187
        elif opcode == 0x20:
            cursor += 1 + (span(data, cursor, 1, "source skip list count")[0] & 0x7F)
        elif opcode == 0x21:
            first = span(data, cursor, 1, "source skipped conditional first count")[0]
            cursor += 1 + first
            second = span(data, cursor, 1, "source skipped conditional second count")[0]
            cursor += 1 + second
        elif opcode == 0x32:
            cursor += 1 + span(data, cursor, 1, "source skipped byte-list count")[0]
        else:
            cursor += lengths[opcode]
        if cursor > end:
            raise SceneError("source skip walker crossed the source block bound")
    return cursor


def compile_instructions(script: bytes, frames: list, text: bytes, bounds: tuple[int, int],
                         people: bytes, main: bytes, lengths: bytes, *,
                         resource: str, text_resource: str, member: int,
                         battle_ids: dict[int, str]) -> list[dict]:
    result, last_dialogue = [], []
    known_offsets = {frame.offset for frame in frames}

    def u16(data: bytes, at: int = 0) -> int:
        return struct.unpack_from("<H", data, at)[0]

    for frame in frames:
        opcode, data = frame.opcode, frame.operands
        source = frame.source(resource, script, member)
        effect = {"opcode": opcode, "offset": frame.offset, "kind": "unsupported",
                  "arguments": list(data), "commands": [], "source": source}

        def string(relative: int) -> tuple[str, dict]:
            at = bounds[0] + relative
            value, after = text_at(text, at, bounds[1], text_resource)
            return value, source_span(text_resource, text, at, after - at)

        def command(op: str, **fields):
            effect["commands"].append({"op": op, "source": source, **fields})

        def skip(count: int):
            try:
                target = source_skip_target(script, frame.end, count, len(script), lengths)
                if target not in known_offsets:
                    raise SceneError("source skip target does not coincide with a decoded execution instruction")
                effect["skipTarget"] = target
            except SceneError as error:
                effect["skipFailure"] = str(error)

        if opcode == 0:
            # MAIN 1C369..1C372 defers the text when the next opcode is 15;
            # the choice renderer consumes that dialogue exactly once.
            effect["kind"] = "deferred-dialogue" if frame.end < len(script) and script[frame.end] == 0x15 else "commands"
            effect["arguments"] = [u16(data)]
            effect["commands"] = dialogue(text, bounds, u16(data), people, source, text_resource=text_resource)
            last_dialogue = effect["commands"]
        elif opcode in (1, 0x0A):
            effect["kind"] = "commands"
            effect["arguments"] = [u16(data), *data[2:]]
            command("move" if opcode == 1 else "place", person=u16(data), x=data[2], y=data[3], facing=data[4])
        elif opcode in (4, 0x31):
            # 04 logs only. 31 has no case, zero operand length, and falls
            # through MAIN1C35D to the continuing interpreter loop.
            effect["kind"] = "no-op"
        elif opcode in (5, 0x2C):
            effect["kind"] = "commands"
            command("show" if opcode == 5 else "redraw")
        elif opcode == 6:
            effect["kind"] = "dialogue-mode"  # MAIN 1D20E; does not start a battle.
        elif opcode == 7:
            effect["kind"] = "story-layout"
        elif opcode in (8, 0x0B, 0x0D):
            effect["kind"] = "commands"
            effect["arguments"] = [u16(data)]
            value, text_source = string(u16(data))
            command("caption" if opcode == 0x0B else "say", text=value, speaker="", textSource=text_source)
        elif opcode == 0x0C:
            # Both words are consumed and the second string is expanded into a
            # temporary buffer. The examined handler has no observable use.
            effect["kind"], effect["arguments"] = "no-op", [u16(data), u16(data, 2)]
        elif opcode == 0x0E:
            selector, selector_source = string(u16(data))
            pointer = u16(main, MAIN_DATA_SEGMENT + 0x24FE + stock_caption_index(selector) * 2)
            value, after = text_at(main, MAIN_DATA_SEGMENT + pointer, len(main), "MAIN.EXE")
            effect["kind"] = "commands"
            command("caption", text=value, textSource=source_span("MAIN.EXE", main, MAIN_DATA_SEGMENT + pointer, after - (MAIN_DATA_SEGMENT + pointer)))
            effect["selectorSource"] = selector_source
        elif opcode == 9:
            packed = u16(data)
            effect["kind"], effect["arguments"] = "load-map", [packed]
            effect["battleID"] = battle_ids.get(frame.offset)
        elif opcode == 0x0F:
            effect["kind"] = "jump-block"
        elif opcode in (0x03, 0x22):
            # The battle exporter owns setup/placement interpretation. The VM
            # identifies the exact producer; its host consumes those parsed
            # facts rather than interpreting this retained byte string again.
            effect["kind"] = "battle-setup" if opcode == 3 else "battle-replacements"
            effect["arguments"] = []
        elif opcode in (0x10, 0x16):
            effect["kind"], effect["arguments"] = "battle-action" if opcode == 0x10 else "actor-action", [u16(data), u16(data, 2)]
        elif opcode in (0x02, 0x1B, 0x23, 0x26, 0x27, 0x2D, 0x33, 0x34):
            effect["kind"] = "battle-action"
        elif opcode == 0x36:
            effect["kind"] = "checkpoint-capture"
        elif opcode in (0x24, 0x28, 0x2F):
            effect["kind"], effect["arguments"] = "person-state" if opcode in (0x24, 0x2F) else "battle-action", [u16(data), data[2]]
        elif opcode == 0x35:
            effect["kind"], effect["arguments"] = "battle-action", [u16(data), data[2]]
        elif opcode == 0x1C:
            selector = data[2]
            value = [u16(data, 3)] if selector in (0, 1, 2, 3, 5) else list(data[3:])
            effect["kind"], effect["arguments"] = "battle-attribute", [u16(data), selector, *value]
        elif opcode == 0x11:
            mode = int(frame.end < len(script) and script[frame.end] == 0x29)
            effect["kind"], effect["arguments"] = "resume-map", [u16(data), mode]
        elif opcode == 0x12:
            effect["kind"] = "next-chapter"
        elif opcode == 0x13:
            effect["kind"] = "next-phase"
        elif opcode == 0x14:
            effect["kind"] = "flag"
        elif opcode == 0x15:
            effect["kind"] = "choice-skip"
            effect["commands"] = last_dialogue
            # MAIN164A9..165C4 and MARK member0 button patterns establish
            # return0=No/return1=Yes; the source shows Yes before No.
            effect["options"] = ["No", "Yes"]
            effect["presentationOrder"] = [1, 0]
            skip(data[1])
        elif opcode == 0x17:
            effect["kind"] = "automatic"
        elif opcode == 0x18:
            effect["kind"], effect["arguments"] = "commands", [u16(data)]
            command("remove", person=u16(data))
        elif opcode == 0x1A:
            # MAIN1C8D2..1C8FF calls the same generic placement helper as0A
            # with literal coordinates0 and raw8-direction0. Native settlement
            # and world factories keep zero coordinates; battle placement uses
            # its setup-row owner. There is no default-entry lookup here.
            effect["kind"], effect["arguments"] = "commands", [u16(data)]
            command("place", person=u16(data), x=0, y=0, sourcePlacementFacing=0)
        elif opcode == 0x1E:
            effect["kind"] = "clear-actor-cache"
        elif opcode == 0x1D:
            effect["kind"], effect["arguments"] = "return-context", [u16(data), data[2], data[3]]
        elif opcode == 0x1F:
            effect["kind"] = "town-interaction"
        elif opcode == 0x20:
            effect["kind"], effect["arguments"] = "city-availability", [int(bool(data[0] & 0x80)), *data[1:]]
        elif opcode == 0x21:
            positive_count = data[1]
            negative_at = 2 + positive_count
            effect["kind"] = "conditional-skip"
            effect["positiveFlags"] = list(data[2:negative_at])
            effect["negativeFlags"] = list(data[negative_at + 1:])
            skip(data[0])
        elif opcode == 0x25:
            effect["kind"], effect["arguments"] = "choice-record", [u16(data)]
            value, text_source = string(u16(data))
            # Source splits CR or LF, consuming an immediately paired LF.
            effect["options"] = value.replace("\r\n", "\n").replace("\r", "\n").split("\n")
            if effect["options"][-1:] == [""]:
                effect["options"].pop()
            effect["textSource"] = text_source
        elif opcode == 0x29:
            effect["kind"], effect["arguments"] = "battle-exit", [3]
            effect["interpreterStatus"] = 7
        elif opcode == 0x2A:
            effect["kind"] = "ending-selection"
            effect["interpreterStatus"] = 8
        elif opcode == 0x2B:
            effect["kind"], effect["arguments"] = "campaign-value", [data[0], u16(data, 1)]
        elif opcode == 0x2E:
            effect["kind"], effect["arguments"] = "city", [u16(data) & 0xFF]
        elif opcode == 0x30:
            effect["kind"], effect["arguments"] = "objective-text", [u16(data)]
            effect["text"], effect["textSource"] = string(u16(data))
        elif opcode == 0x32:
            effect["kind"], effect["arguments"] = "source-list", list(data[1:])
        elif opcode == 0x38:
            effect["kind"] = "music"
        elif opcode in (0x37, 0x39, 0x3A):
            effect["kind"], effect["arguments"] = "person-state", [u16(data), data[2]]
        elif opcode == 0x3B:
            # This pans toward an original route-grid coordinate; converting
            # to native pixels needs map dimensions and source camera clamps.
            effect["kind"] = "world-camera"
        elif opcode == 0x3C:
            effect["kind"], effect["arguments"] = "world-follow", [u16(data)]
        elif opcode == 0x3D:
            effect["kind"] = "save-prompt"
        elif opcode == 0xFF:
            effect["kind"] = "end-record"
        # Other handlers need a host that implements their established original
        # effect. Keeping source opcode + literal byte arguments is evidence,
        # not a claim that executing an arbitrary effect is supported.
        result.append(effect)
    return result
