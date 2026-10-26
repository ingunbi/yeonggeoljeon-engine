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
MAIN_DATA_PARAGRAPH = 0x313A  # (0x37DA0 - 0x6A00) / 16
SELECTOR = (0x0CF5, 0x3C5E)
# main 1E5DD..1E5E7: push ds; push 2A2E; push 2; far call CF5:3C5E.
RETRY_PROMPT_CALL = 0x1E5DD
RETRY_PROMPT_CALL_LENGTH = 11
RETRY_PROMPT_POINTER = 0x2A2E
RETRY_PROMPT_SELECTOR = SELECTOR
# Source 3D handler 22A62..22AA1: save question, then the decline check.
SAVE_PROMPT_CALL, SAVE_PROMPT_POINTER = 0x22A63, 0x305A
SAVE_DECLINE_CALL, SAVE_DECLINE_POINTER = 0x22A8C, 0x3073
# Title menu CF5:C050 (1F9A0): push 4 items, lea bx,[2D38], handlers DS:2CEC.
TITLE_MENU_COUNT_AT, TITLE_MENU_TABLE_AT = 0x1F9C5, 0x1F9D5
TITLE_MENU_TABLE = 0x2D38
TITLE_MENU_ACTIONS = ["new-game", "resume", "settings", "opening"]


def selector_text(main: bytes, call_at: int, pointer: int) -> dict:
    """Checked `push ds; push pointer; push 2; call CF5:3C5E` text."""
    call = span(main, call_at, RETRY_PROMPT_CALL_LENGTH, "MAIN.EXE")
    if (call[0], call[1], call[4], call[5], call[6]) != (0x1E, 0x68, 0x6A, 2, 0x9A) or \
            struct.unpack_from("<H", call, 2)[0] != pointer or \
            struct.unpack_from("<HH", call, 7) != SELECTOR[::-1]:
        raise SceneError(f"MAIN.EXE selector call at {call_at:#x} does not match the examined profile")
    at = MAIN_DATA_SEGMENT + pointer
    value, after = text_at(main, at, len(main), "MAIN.EXE")
    if not value:
        raise SceneError(f"MAIN.EXE selector text at DS:{pointer:04X} is empty")
    return {"text": value, "textSource": source_span("MAIN.EXE", main, at, after - at),
            "callSource": source_span("MAIN.EXE", main, call_at, RETRY_PROMPT_CALL_LENGTH),
            "selectorMode": 2, "yesResult": 1, "noResult": 0, "presentationOrder": [1, 0]}


def title_menu(main: bytes) -> list[dict]:
    """MAIN CF5:C050 item texts in source order; handlers 0..3 are fixed."""
    count = span(main, TITLE_MENU_COUNT_AT, 2, "MAIN.EXE")
    lea = span(main, TITLE_MENU_TABLE_AT, 4, "MAIN.EXE")
    if count != bytes([0x6A, len(TITLE_MENU_ACTIONS)]) or lea[:2] != bytes([0x8D, 0x1E]) or \
            struct.unpack_from("<H", lea, 2)[0] != TITLE_MENU_TABLE:
        raise SceneError("MAIN.EXE title menu call does not match the examined profile")
    items = []
    for index, action in enumerate(TITLE_MENU_ACTIONS):
        entry = MAIN_DATA_SEGMENT + TITLE_MENU_TABLE + index * 4
        offset, paragraph = struct.unpack_from("<HH", span(main, entry, 4, "MAIN.EXE"))
        if paragraph != MAIN_DATA_PARAGRAPH:
            raise SceneError("MAIN.EXE title menu item is outside the data segment")
        value, after = text_at(main, MAIN_DATA_SEGMENT + offset, len(main), "MAIN.EXE")
        if not value:
            raise SceneError("MAIN.EXE title menu item is empty")
        items.append({"index": index, "action": action, "text": value,
                      "textSource": source_span("MAIN.EXE", main, MAIN_DATA_SEGMENT + offset,
                                                after - (MAIN_DATA_SEGMENT + offset)),
                      "pointerSource": source_span("MAIN.EXE", main, entry, 4)})
    return items


# Battle system menu (MAIN 27D12..27EA3): nine DS:3AA0 items.
BATTLE_MENU_COUNT_AT, BATTLE_MENU_TABLE_AT, BATTLE_MENU_TABLE = 0x27D12, 0x27D21, 0x3AA0
BATTLE_RETREAT_ITEM, BATTLE_QUIT_ITEM = 1, 8
RETREAT_CONFIRM_CALL, RETREAT_CONFIRM_POINTER_VAR = 0x27D83, 0x3D1E
RETREAT_REFUSED_CALL, RETREAT_REFUSED_POINTER = 0x27DA6, 0x3D2E
QUIT_CONFIRM_CALL, QUIT_CONFIRM_POINTER = 0x27E87, 0x3D4F
RETREAT_RESULT_AT, QUIT_RESULT_AT = 0x27D9C, 0x27E9C


def checked_text(main: bytes, pointer: int, label: str) -> tuple[str, dict]:
    at = MAIN_DATA_SEGMENT + pointer
    value, after = text_at(main, at, len(main), "MAIN.EXE")
    if not value:
        raise SceneError(f"MAIN.EXE {label} text is empty")
    return value, source_span("MAIN.EXE", main, at, after - at)


def battle_menu(main: bytes) -> dict:
    """Retreat and quit entries of the battle system menu.

    Retreat asks the DS:[3D1E] question and writes raw battle result one,
    unless script context+1CB forbids it (DS:3D2E notice). Quit asks DS:3D4F
    and writes raw result four. Labels come from the DS:3AA0 item table.
    """
    count = span(main, BATTLE_MENU_COUNT_AT, 2, "MAIN.EXE")
    lea = span(main, BATTLE_MENU_TABLE_AT, 4, "MAIN.EXE")
    if count != bytes([0x6A, 9]) or lea[:2] != bytes([0x8D, 0x1E]) or \
            struct.unpack_from("<H", lea, 2)[0] != BATTLE_MENU_TABLE:
        raise SceneError("MAIN.EXE battle menu call does not match the examined profile")
    labels = {}
    for item in (BATTLE_RETREAT_ITEM, BATTLE_QUIT_ITEM):
        offset, paragraph = struct.unpack_from("<HH", span(main, MAIN_DATA_SEGMENT + BATTLE_MENU_TABLE + item * 4, 4, "MAIN.EXE"))
        if paragraph != MAIN_DATA_PARAGRAPH:
            raise SceneError("MAIN.EXE battle menu item is outside the data segment")
        labels[item] = checked_text(main, offset, "battle menu item")
    # push ds; push word [3D1E]; push 2; far call CF5:3C5E
    call = span(main, RETREAT_CONFIRM_CALL, 12, "MAIN.EXE")
    if (call[0], call[1], call[2], call[5], call[6], call[7]) != (0x1E, 0xFF, 0x36, 0x6A, 2, 0x9A) or \
            struct.unpack_from("<H", call, 3)[0] != RETREAT_CONFIRM_POINTER_VAR or \
            struct.unpack_from("<HH", call, 8) != SELECTOR[::-1]:
        raise SceneError("MAIN.EXE retreat confirmation call does not match the examined profile")
    pointer = struct.unpack_from("<H", span(main, MAIN_DATA_SEGMENT + RETREAT_CONFIRM_POINTER_VAR, 2, "MAIN.EXE"))[0]
    retreat_text, retreat_source = checked_text(main, pointer, "retreat confirmation")
    refused = span(main, RETREAT_REFUSED_CALL, 11, "MAIN.EXE")
    if (refused[0], refused[1], refused[4], refused[5], refused[6]) != (0x1E, 0x68, 0x6A, 1, 0x9A) or \
            struct.unpack_from("<H", refused, 2)[0] != RETREAT_REFUSED_POINTER:
        raise SceneError("MAIN.EXE retreat refusal call does not match the examined profile")
    refused_text, refused_source = checked_text(main, RETREAT_REFUSED_POINTER, "retreat refusal")
    for at, value in ((RETREAT_RESULT_AT, 1), (QUIT_RESULT_AT, 4)):
        # mov bx,[bp+6]; mov byte [bx+1],value
        if span(main, at, 7, "MAIN.EXE") != bytes([0x8B, 0x5E, 0x06, 0xC6, 0x47, 0x01, value]):
            raise SceneError("MAIN.EXE battle menu result write does not match the examined profile")
    return {"retreat": {"label": labels[BATTLE_RETREAT_ITEM][0], "labelSource": labels[BATTLE_RETREAT_ITEM][1],
                        "confirm": {"text": retreat_text, "textSource": retreat_source,
                                    "callSource": source_span("MAIN.EXE", main, RETREAT_CONFIRM_CALL, 12),
                                    "selectorMode": 2, "yesResult": 1, "noResult": 0, "presentationOrder": [1, 0]},
                        "refused": {"text": refused_text, "textSource": refused_source,
                                    "callSource": source_span("MAIN.EXE", main, RETREAT_REFUSED_CALL, 11), "selectorMode": 1},
                        "rawResult": 1, "resultSource": source_span("MAIN.EXE", main, RETREAT_RESULT_AT, 7)},
            "quit": {"label": labels[BATTLE_QUIT_ITEM][0], "labelSource": labels[BATTLE_QUIT_ITEM][1],
                     "confirm": selector_text(main, QUIT_CONFIRM_CALL, QUIT_CONFIRM_POINTER),
                     "rawResult": 4, "resultSource": source_span("MAIN.EXE", main, QUIT_RESULT_AT, 7)}}


# Field system menu (MAIN 22CD2..22DB6): DS:34E8 items, DS:3478 handlers.
FIELD_MENU_TABLE_AT, FIELD_MENU_TABLE, FIELD_MENU_HANDLERS_AT = 0x22D50, 0x34E8, 0x22D64
FIELD_MENU_HANDLERS = 0x3478
FIELD_MENU_ACTIONS = ["quit", "scroll", "speed", "load", "save", "monitor", "bgm", "sound", "volume", "music-time"]
FIELD_QUIT_CALL, FIELD_QUIT_POINTER = 0x22994, 0x3018


def field_menu(main: bytes) -> dict:
    """Field menu labels and the quit question (handler CF5:F044).

    Quit sets framework flag 40, load and save use CF5:F152 and the shared
    slot routine CF5:F0CE. Only these three have a native counterpart.
    """
    lea = span(main, FIELD_MENU_TABLE_AT, 4, "MAIN.EXE")
    call = span(main, FIELD_MENU_HANDLERS_AT, 4, "MAIN.EXE")
    if lea[:2] != bytes([0x8D, 0x1E]) or struct.unpack_from("<H", lea, 2)[0] != FIELD_MENU_TABLE or \
            call[:2] != bytes([0xFF, 0x9F]) or struct.unpack_from("<H", call, 2)[0] != FIELD_MENU_HANDLERS:
        raise SceneError("MAIN.EXE field menu call does not match the examined profile")
    items = []
    for index, action in enumerate(FIELD_MENU_ACTIONS):
        entry = MAIN_DATA_SEGMENT + FIELD_MENU_TABLE + index * 4
        offset, paragraph = struct.unpack_from("<HH", span(main, entry, 4, "MAIN.EXE"))
        if paragraph != MAIN_DATA_PARAGRAPH:
            raise SceneError("MAIN.EXE field menu item is outside the data segment")
        text, source = checked_text(main, offset, "field menu item")
        items.append({"index": index, "action": action, "text": text, "textSource": source,
                      "pointerSource": source_span("MAIN.EXE", main, entry, 4)})
    return {"items": items, "quitConfirm": selector_text(main, FIELD_QUIT_CALL, FIELD_QUIT_POINTER), "quitMask": 0x40}


def framework_prompts(main: bytes) -> dict:
    """Text owned by MAIN's outer framework rather than a scenario member.

    After the framework map loop returns mask 20/40, main shows the retry text
    in the two-button selector (Yes returns one, No returns zero). The 3D
    handler asks the save question and, after a cancelled slot dialog, the
    decline check. Each producer checks the examined call sequence instead of
    trusting a bare offset.
    """
    return {"retryPrompt": selector_text(main, RETRY_PROMPT_CALL, RETRY_PROMPT_POINTER),
            "savePrompt": selector_text(main, SAVE_PROMPT_CALL, SAVE_PROMPT_POINTER),
            "saveDeclinePrompt": selector_text(main, SAVE_DECLINE_CALL, SAVE_DECLINE_POINTER),
            "titleMenu": title_menu(main),
            "battleMenu": battle_menu(main),
            "fieldMenu": field_menu(main)}


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
