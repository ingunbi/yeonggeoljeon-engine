#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Export original PACKGRP pictures and source story-panel layout facts locally."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import struct
import sys

from prepare_resources import EXAMINED_MAIN, inventory, palette_at
from prepare_scene import read_resource
from resource_formats import Archive, ResourceError, planar_image, png_bytes
from tf_dce import dce_picture

EXAMINED_TFDED = "57db61a49d4a1ca525d14aca210457c57ec2c2caf04d58b99f4a51e053762371"


def picture_directory(data: bytes, count: int) -> list[tuple[int, int]]:
    if count <= 0 or len(data) < count * 6:
        raise ResourceError("packed picture directory is truncated")
    header = count * 6
    result, expected = [], header
    for index in range(count):
        relative, size = struct.unpack_from("<IH", data, index * 6)
        start = header + relative
        if not size or start != expected or start + size > len(data):
            raise ResourceError("packed picture spans do not cover an ordered, bounded source stream")
        result.append((start, start + size))
        expected = start + size
    if expected != len(data):
        raise ResourceError("packed picture resource has unowned trailing bytes")
    return result


# Field screen routine CF5:C456 (MAIN 1FDA6..1FE2C) and battle screen routine
# (1FE2E..1FE69). HUD writers share one shape: clear rect, then text cursor.
FIELD_FRAME_CALL, BATTLE_FRAME_CALL, PORTRAIT_CALL = 0x1FDB1, 0x1FE39, 0x1FE15
HUD_FIELDS = {"caption": 0x1FC5E, "money": 0x1FCB2, "level": 0x1FCEA, "territory": 0x1FD24}
HUD_SOURCES = {"caption": "MAIN.EXE:0x1FC5E..0x1FC8E; DS:DB4C via CF5:C340 (source0D)",
               "money": "MAIN.EXE:0x1FCB2..0x1FCE8; player7A80+0 via CF5:220A",
               "level": "MAIN.EXE:0x1FCEA..0x1FD22; person0 (DS:7A94) +21 via CF5:7572",
               "territory": "MAIN.EXE:0x1FD24..0x1FD62; city player7A80+10 via CF5:210E/2118"}
HUD_FORMATS = {"caption": "%s", "money": "%5u", "level": "%4u", "territory": "%6s"}


def hud_field(main: bytes, at: int) -> dict:
    """push h; push color; mov ax,x; mov dx,y; mov bx,w; call CF5:52EE;
    push column; push y; push 6390; call CF5:091E (MAIN text cursor)."""
    code = main[at:at + 31]
    if len(code) != 31 or (code[0], code[2], code[4], code[7], code[10], code[13], code[18], code[20], code[23]) != \
            (0x6A, 0x6A, 0xB8, 0xBA, 0xBB, 0x9A, 0x6A, 0x68, 0x68) or \
            struct.unpack_from("<HH", code, 14) != (0x52EE, 0x0CF5) or struct.unpack_from("<H", code, 24)[0] != 0x6390 or \
            code[26] != 0x9A or struct.unpack_from("<HH", code, 27) != (0x091E, 0x0CF5):
        raise ResourceError(f"MAIN HUD writer at {at:#x} does not match the examined profile")
    x, y, width = (struct.unpack_from("<H", code, offset)[0] for offset in (5, 8, 11))
    column, text_y = code[19], struct.unpack_from("<H", code, 21)[0]
    if text_y != y:
        raise ResourceError(f"MAIN HUD writer at {at:#x} prints outside its cleared row")
    return {"rect": [x, y, width, code[1]], "clearColor": code[3], "text": [column * 8, text_y]}


def screen_facts(main: bytes, battle: dict | None = None) -> dict:
    if main[FIELD_FRAME_CALL:FIELD_FRAME_CALL + 7] != bytes([0x33, 0xC0, 0x9A]) + struct.pack("<HH", 0x520E, 0x0CF5) or \
            main[BATTLE_FRAME_CALL:BATTLE_FRAME_CALL + 8] != bytes([0xB8, 1, 0, 0x9A]) + struct.pack("<HH", 0x520E, 0x0CF5):
        raise ResourceError("MAIN screen frame selectors do not match the examined profile")
    portrait = main[PORTRAIT_CALL:PORTRAIT_CALL + 13]
    if (portrait[0], portrait[3], portrait[6], portrait[7], portrait[8]) != (0xB8, 0xBA, 0x33, 0xDB, 0x9A) or \
            struct.unpack_from("<HH", portrait, 9) != (0x51B2, 0x0CF5):
        raise ResourceError("MAIN field portrait call does not match the examined profile")
    hud = {}
    for name, at in HUD_FIELDS.items():
        hud[name] = {**hud_field(main, at), "format": HUD_FORMATS[name], "textColor": 7, "source": HUD_SOURCES[name]}
    hud["portrait"] = {"rect": [struct.unpack_from("<H", portrait, 1)[0], struct.unpack_from("<H", portrait, 4)[0], 64, 80],
                       "portraitID": 0, "source": "MAIN.EXE:0x1FE15..0x1FE21, CF5:51B2 (0x18B02..)"}
    return {"field": {"frameAsset": 0, "viewport": [16, 16, 512, 320], "hud": hud,
                      "source": "MAIN.EXE:0x1FDA6..0x1FE2C (CF5:C456), PACKGRP member0 via CF5:520E"},
            "battle": {"frameAsset": 1, **(battle or {}), "source": "MAIN.EXE:0x1FE2E..0x1FE69, PACKGRP member1 via CF5:520E"},
            "limitations": ["Layout coordinates come from MAIN immediates; the original font and text colors are not restored.",
                            "Window frames for dialogue and selectors are drawn by other primitives and are not part of these facts."]}


# Field icon routines (MAIN 0x22C56..0x23DBA). Each text carries the offset of
# the push that selects it.
FIELD_TEXTS = {"personInfo": (0x23259, 0x356F), "itemExchange": (0x23589, 0x35A2), "exchangePrompt": (0x2359F, 0x35AB),
               "personOne": (0x2372F, 0x35C8), "personTwo": (0x2374B, 0x35CE), "people": (0x239AE, 0x35FA),
               "storyInfo": (0x23AB0, 0x35FF), "wholeMap": (0x23B39, 0x360B), "notHere": (0x23DA5, 0x3614),
               "noItems": (0x2313B, 0x3560), "level": (0x22FD9, 0x354D)}
FIELD_STATS_SITE, FIELD_STATS = 0x22ED5, 0x3544
FIELD_ICON_SITE, FIELD_ICON_SIZE_SITE, FIELD_ICONS = 0x22C62, 0x22C77, 0x3514


def field_facts(main: bytes) -> dict:
    """Texts and icon cells of the four field buttons, from checked sites."""
    texts = {}
    for name, (site, pointer) in FIELD_TEXTS.items():
        if main[site:site + 3] != b"\x68" + struct.pack("<H", pointer):
            raise ResourceError(f"MAIN field text site {name} at {site:#x} does not match the examined profile")
        texts[name] = data_text(main, pointer)
    if main[FIELD_STATS_SITE:FIELD_STATS_SITE + 3] != b"\xbe" + struct.pack("<H", FIELD_STATS):
        raise ResourceError("MAIN person stat labels do not match the examined profile")
    if main[FIELD_ICON_SITE:FIELD_ICON_SITE + 4] != b"\x8b\xb7" + struct.pack("<H", FIELD_ICONS) or \
            main[FIELD_ICON_SIZE_SITE:FIELD_ICON_SIZE_SITE + 4] != b"\x6a\x28\x6a\x30":
        raise ResourceError("MAIN field icon table does not match the examined profile")
    positions = struct.unpack_from("<8H", main, DATA_SEGMENT + FIELD_ICONS)
    return {"texts": {**texts, "stats": near_texts(main, FIELD_STATS, 3)},
            "icons": [[positions[index * 2], positions[index * 2 + 1], 40, 48] for index in range(4)],
            "iconSource": "MAIN.EXE:0x22C56..0x22CD1, DS:3514; handlers at DS:3636"}


# Battle screen writers. Each entry is a file offset and the exact bytes that
# carry the coordinates exported in `battle_layout`.
BATTLE_SHAPES = {
    "viewport": (0x270B4, "6a10 6a20 68a001 686001 68bce1 9afe53b61c"),
    "functionButton": (0x27CB5, "6a10 6a08 6a40 6a10"),
    "title": (0x28A52, "2d1600 f7d8 d1e8 051c00 50 6a08 689063"),
    "force": (0x294C6, "2d0a00 f7d8 d1e8 053800 50 6a28 689063"),
    "sideButtons": (0x287B5, "251000 3d0100 1bc9 80e1e0 81c13002 51 6a20 6a20 6a20"),
    "listRow": (0x296B3, "68c001 6bc714 054800 50 68a000 6a14"),
    "listRows": (0x29680, "807eff0a"),
    "listName": (0x29612, "6a39 6b46e614 8946e2 054a00"),
    "listStatus": (0x29630, "6a41"),
    "listGauge": (0x2966C, "8b56e2 83c24e b80002 bb5800"),
    "listTrack": (0x29704, "81ff7002"),
    "listHover": (0x29814, "68c601 56 689400 6a14 6a01 6a07"),
    "listThumb": (0x2973D, "81ff6002"),
    "minimapX": (0x2898C, "b82800"),
    "minimapBaseX": (0x289A2, "053900 c1e003"),
    "minimapY": (0x289AB, "b81800"),
    "minimapBaseY": (0x289BF, "052300 c1e003"),
    "minimapUnit": (0x298C4, "6a04 6a04"),
    "minimapPanel": (0x27096, "b82500 9a0e52f50c"),
    "minimapPanelAt": (0x270A9, "b8c001 ba1001"),
    "follow": (0x299CB, "83f906 7d12 83fe06"),
    "forceTable": (0x294A2, "ffb71e0f"),
    "forceSuffix": (0x294B3, "1e 68b03e"),
    "retired": (0x29643, "68b63e"),
}
FORCE_TABLE, FORCE_COUNT, FORCE_SUFFIX, RETIRED_TEXT = 0xF1E, 15, 0x3EB0, 0x3EB6
# Unit command routine (MAIN 0x2D9D4..0x2DE42) and its helpers. Each entry is
# the checked instruction that names a table or message.
COMMAND_SHAPES = {
    "commandTable": (0x2DA75, "8b870c43"), "ambushTable": (0x2DAE5, "b86648"),
    "itemActionTable": (0x2DEE9, "684643"), "strategyNameTable": (0x2DB88, "81c33844"),
    "windowRow": (0x2AA89, "c1ef04 83ef11 780e c1e704 297c29"),
    "windowColumn": (0x2AAA8, "c1e804 48 3d0d00 720d 816c27a000"),
}
COMMAND_MESSAGES = {
    "outOfMoveRange": (0x30FF8, 0x4D3C), "notOurs": (0x3103F, 0x4D51), "cannotControl": (0x3104D, 0x4D66),
    "confused": (0x31067, 0x4D80), "finished": (0x31075, 0x4DA2), "noStrategy": (0x2DD80, 0x488A),
    "releaseAmbush": (0x2DDAD, 0x48AA), "noItems": (0x2DEC9, 0x48BD), "gave": (0x2E009, 0x48D8),
    "inventoryFull": (0x2E025, 0x48F0), "discarded": (0x2E06D, 0x4916), "noAllyInRange": (0x29B74, 0x3EC1),
    "noEnemyInRange": (0x29B7A, 0x3EDB), "enemyUnit": (0x29C11, 0x3EF7), "cannotAttackAlly": (0x29C51, 0x3F07),
    "outOfItemRange": (0x29C67, 0x3F21), "outOfAttackRange": (0x29C6D, 0x3F33),
}
COMMAND_LABELS, AMBUSH_ACTIONS, ITEM_ACTIONS, STRATEGY_COUNT = 4, 2, 4, 36
# Texts of the item use routine (MAIN 0x2E0E6..0x2E833) and its helpers.
ITEM_MESSAGES = {
    "rainFire": (0x2E260, 0x4A80), "attackWith": (0x2E272, 0x4AA2), "usedItem": (0x2E2F8, 0x4ABF),
    "confuseEnemy": (0x2E33D, 0x4AD2), "alreadyConfused": (0x2E468, 0x4AE5), "recoverKind": (0x2E4C9, 0x4B01),
    "recoveryLine": (0x2E52B, 0x4B2B), "bombAttack": (0x2E592, 0x4B3C), "bombThrow": (0x2E5BE, 0x4B55),
    "unusable": (0x2E6D6, 0x4B64), "noRecovery": (0x2D7EF, 0x4800), "classPrompt": (0x2E781, 0x492A),
    "classDone": (0x2E7E0, 0x4947), "classTerrain": (0x2E7E7, 0x4961), "sameFamily": (0x2E7ED, 0x49A7),
    "sameClass": (0x2E7F3, 0x49C9), "playerClass": (0x2E7F9, 0x49ED), "promotePrompt": (0x2E1A7, 0x4A11),
    "promoteDone": (0x2E1FB, 0x4A31), "lowLevel": (0x2E211, 0x4A4B), "wrongClass": (0x2E218, 0x4A5E),
    "areaPrompt": (0x2F0E3, 0x4C93), "areaDone": (0x2F1B7, 0x4CC2), "noAllyNearby": (0x2F1D7, 0x4CDE),
    "becameConfused": (0x2D590, 0x4287), "lostWill": (0x2D66A, 0x42BB),
}
ITEM_WORDS = {"raised": (0x2E51B, 0x4B21), "friendlySide": (0x2F1AE, 0x4CBC), "enemySide": (0x2F1B3, 0x4CBF)}
TERRAIN_SHAPES = {
    "prefix": (0x2D91F, "1e682a48"), "separator": (0x2D95E, "1e683048"), "suffix": (0x2D9AF, "1e683348"),
    "names": (0x2D97A, "ffb7743e"), "table": (0x2D93F, "8a81bc47"),
    "kindLabels": (0x2E4C0, "81c3e247"), "familyLabels": (0x2E26E, "ffb7fa47"), "classNames": (0x2E778, "81c3d80f"),
}
TERRAIN_TABLE, TERRAIN_NAMES, KIND_LABELS, FAMILY_LABELS, CLASS_NAMES = 0x47BC, 0x3E74, 0x47E2, 0x47FA, 0xFD8
# Victory conditions window (MAIN 0x27876..0x27A3A) and the friendly phase notice.
CONDITION_SHAPES = {
    "window": (0x2788B, "6a40 6a60 684001 68c000"), "textBox": (0x2792F, "6a48 688800 683001 6a60"),
    "turnBox": (0x27945, "6a48 68e800 68f000 6a30"), "title": (0x278ED, "6a0a 6a70"), "heading": (0x2790A, "6a26 6a70"),
    "textStart": (0x27968, "bf9800"), "textStep": (0x27986, "83c720 81ffd800"), "textLine": (0x27978, "b80c00 8bd7 b322"),
    "turn": (0x2798F, "6a0b 68f800"), "button": (0x279E4, "6a28 68f800 6a06 6a10"), "chapters": (0x278DD, "ffb7783c"),
    "headingText": (0x27916, "688f3c"), "objective": (0x2795B, "68dcd4 9ada0eb61c"),
}
CONDITION_TEXTS = {"titleFormat": (0x278E1, 0x3C82), "currentTurn": (0x279B0, 0x3C98), "turnLimit": (0x279C7, 0x3CB0),
                   "playerPhase": (0x27ADD, 0x3D20)}
OK_BUTTON = 0x19F0
# Terrain window (MAIN 0x2A5F4..0x2A8C6), opened by a click on an empty cell.
TERRAIN_WINDOW_SHAPES = {
    "column": (0x2A6FA, "83ff0e 7d05 b80200 eb03 b8f8ff"), "row": (0x2A730, "83fe0c 7d04 33c0 eb03 b8fdff"),
    "size": (0x2A752, "6a50 8bc7 c1e004 8bd6 c1e204 8956ee bb8000"), "tile": (0x2A76E, "050800"),
    "percentRow": (0x2A84E, "052400"), "nameRow": (0x2A810, "053800"), "names": (0x2A824, "ffb7743e"),
    "defenseHeading": (0x2A7BA, "68623f"), "none": (0x2A7F0, "1e686b3f"), "percent": (0x2A7FE, "1e686d3f"),
    "recoveryHeading": (0x2A88C, "68753f"), "recoveryTerrains": (0x2A87A, "807eff08 740c 807eff0d 7406 807eff0e"),
}
TERRAIN_COUNT = 20
DATA_SEGMENT, DATA_PARAGRAPH = 0x37DA0, 0x313A
FUNCTION_PICTURE, SIDE_PICTURES = 0x800, {(0, 0): 0xA00, (0, 1): 0xC00, (1, 0): 0xE00, (1, 1): 0x1000}
GAUGE_TILES = {"high": 0x2230, "middle": 0x21E0, "low": 0x2208}


def checked_shapes(main: bytes) -> None:
    for name, (at, shape) in BATTLE_SHAPES.items():
        expected = bytes.fromhex(shape.replace(" ", ""))
        if main[at:at + len(expected)] != expected:
            raise ResourceError(f"MAIN battle screen writer {name} at {at:#x} does not match the examined profile")


def data_text(main: bytes, pointer: int) -> str:
    start = DATA_SEGMENT + pointer
    end = main.index(0, start)
    return main[start:end].decode("cp949")


def battle_texts(main: bytes) -> dict:
    forces = []
    for index in range(FORCE_COUNT):
        pointer = struct.unpack_from("<H", main, DATA_SEGMENT + FORCE_TABLE + index * 2)[0]
        forces.append(data_text(main, pointer))
    if not all(forces):
        raise ResourceError("MAIN force name table does not match the examined profile")
    return {"forces": forces, "forceSuffix": data_text(main, FORCE_SUFFIX), "retired": data_text(main, RETIRED_TEXT),
            "source": {"forces": f"DS:{FORCE_TABLE:04X}", "forceSuffix": f"DS:{FORCE_SUFFIX:04X}",
                       "retired": f"DS:{RETIRED_TEXT:04X}", "resource": "MAIN.EXE"}}


def far_texts(main: bytes, table: int, count: int) -> list[str]:
    result = []
    for index in range(count):
        offset, paragraph = struct.unpack_from("<HH", main, DATA_SEGMENT + table + index * 4)
        if paragraph != DATA_PARAGRAPH:
            raise ResourceError(f"MAIN text table DS:{table:04X} leaves the data segment")
        result.append(data_text(main, offset).strip())
    return result


def near_texts(main: bytes, table: int, count: int) -> list[str]:
    return [data_text(main, struct.unpack_from("<H", main, DATA_SEGMENT + table + index * 2)[0]) for index in range(count)]


def terrain_refusal(main: bytes, family: int) -> str:
    """MAIN 0x2D90E..0x2D9CA joins the family's terrain names between its two texts."""
    names = [main[DATA_SEGMENT + TERRAIN_TABLE + family * 4 + index] for index in range(4)]
    listed = [data_text(main, struct.unpack_from("<H", main, DATA_SEGMENT + TERRAIN_NAMES + value * 2)[0])
              for value in names if value != 0xFF]
    return data_text(main, 0x482A) + data_text(main, 0x4830).join(listed) + data_text(main, 0x4833)


def item_texts(main: bytes) -> dict:
    """Refusals, prompts and labels of the item use routine, from checked sites."""
    for name, (at, shape) in TERRAIN_SHAPES.items():
        expected = bytes.fromhex(shape)
        if main[at:at + len(expected)] != expected:
            raise ResourceError(f"MAIN item site {name} at {at:#x} does not match the examined profile")
    messages = {}
    for name, (at, pointer) in ITEM_MESSAGES.items():
        if main[at:at + 4] != b"\x1e\x68" + struct.pack("<H", pointer):
            raise ResourceError(f"MAIN item message {name} at {at:#x} does not match the examined profile")
        messages[name] = data_text(main, pointer)
    for name, (at, pointer) in ITEM_WORDS.items():
        if main[at:at + 3] != b"\xb8" + struct.pack("<H", pointer):
            raise ResourceError(f"MAIN item word {name} at {at:#x} does not match the examined profile")
        messages[name] = data_text(main, pointer)
    return {"itemMessages": messages, "kindLabels": near_texts(main, KIND_LABELS, 4),
            "familyLabels": near_texts(main, FAMILY_LABELS, 3), "classNames": near_texts(main, CLASS_NAMES, 19),
            "terrainRefusals": [terrain_refusal(main, family) for family in range(3)]}


def battle_conditions(main: bytes) -> dict:
    """Texts of the victory conditions window, from checked sites."""
    for name, (at, shape) in CONDITION_SHAPES.items():
        expected = bytes.fromhex(shape.replace(" ", ""))
        if main[at:at + len(expected)] != expected:
            raise ResourceError(f"MAIN conditions site {name} at {at:#x} does not match the examined profile")
    texts = {}
    for name, (at, pointer) in CONDITION_TEXTS.items():
        if main[at:at + 4] != b"\x1e\x68" + struct.pack("<H", pointer):
            raise ResourceError(f"MAIN conditions text {name} at {at:#x} does not match the examined profile")
        texts[name] = data_text(main, pointer)
    return {**texts, "heading": data_text(main, 0x3C8F), "chapterLabels": near_texts(main, 0x3C78, 5),
            "source": {"window": "MAIN.EXE:0x27876..0x27A3A", "phaseNotice": "MAIN.EXE:0x27AC6..0x27AE8"}}


def battle_terrain(main: bytes) -> dict:
    """Texts of the terrain window, from checked sites."""
    for name, (at, shape) in TERRAIN_WINDOW_SHAPES.items():
        expected = bytes.fromhex(shape.replace(" ", ""))
        if main[at:at + len(expected)] != expected:
            raise ResourceError(f"MAIN terrain site {name} at {at:#x} does not match the examined profile")
    return {"names": [name.strip() for name in near_texts(main, TERRAIN_NAMES, TERRAIN_COUNT)], "defense": data_text(main, 0x3F62),
            "none": data_text(main, 0x3F6B), "percent": data_text(main, 0x3F6D), "recovery": data_text(main, 0x3F75),
            "source": {"window": "MAIN.EXE:0x2A5F4..0x2A8C6", "trigger": "MAIN.EXE:0x27C7A..0x27C87"}}


def battle_commands(main: bytes) -> dict:
    """Labels and refusals of the unit command routine, from checked sites."""
    for name, (at, shape) in COMMAND_SHAPES.items():
        expected = bytes.fromhex(shape.replace(" ", ""))
        if main[at:at + len(expected)] != expected:
            raise ResourceError(f"MAIN command site {name} at {at:#x} does not match the examined profile")
    messages = {}
    for name, (at, pointer) in COMMAND_MESSAGES.items():
        if main[at:at + 4] != b"\x1e\x68" + struct.pack("<H", pointer):
            raise ResourceError(f"MAIN command message {name} at {at:#x} does not match the examined profile")
        messages[name] = data_text(main, pointer)
    # Entry zero of DS:430C is the unused empty string before the four commands.
    labels = far_texts(main, 0x430C, COMMAND_LABELS + 1)[1:]
    return {"labels": labels, "ambush": far_texts(main, 0x4866, AMBUSH_ACTIONS),
            "itemActions": far_texts(main, 0x4346, ITEM_ACTIONS),
            "strategyNames": far_texts(main, 0x4438, STRATEGY_COUNT), "messages": messages, **item_texts(main),
            "conditions": battle_conditions(main), "terrain": battle_terrain(main),
            "source": {"routine": "MAIN.EXE:0x2D9D4..0x2DE42", "window": "MAIN.EXE:0x2AA26..0x2AAC4",
                       "picker": "MAIN.EXE:0x29ADE..0x29CAF", "moveDenials": "MAIN.EXE:0x30ED2..0x31083"}}


def battle_layout(panel_size: tuple[int, int]) -> dict:
    """Coordinates of the checked writers; `checked_shapes` proves their bytes."""
    return {"viewport": [0x10, 0x20, 0x1A0, 0x160], "cell": 32, "functionButton": [0x10, 0x08, 0x40, 0x10],
            "title": {"column": 0x1C, "width": 0x16, "y": 0x08}, "force": {"column": 0x38, "width": 0x0A, "y": 0x28},
            "sideButtons": [[0x210, 0x20, 0x20, 0x20], [0x230, 0x20, 0x20, 0x20]],
            "list": {"rect": [0x1C0, 0x48, 0xA0, 0x14 * 10], "rowHeight": 0x14, "rows": 10, "nameColumn": 0x39,
                     "statusColumn": 0x41, "textY": 0x4A, "gauge": [0x200, 0x4D, 0x58, 10], "track": [0x260, 0x48, 0x10, 0xC8],
                     "hover": [0x1C6, 0x94]},
            "minimap": {"panel": [0x1C0, 0x110, panel_size[0], panel_size[1]], "base": [0x39 * 8, 0x23 * 8], "span": [0x28, 0x18],
                        "cellPixels": 4},
            "conditions": {"window": [0x40, 0x60, 0x140, 0xC0], "textBox": [0x48, 0x88, 0x130, 0x60], "turnBox": [0x48, 0xE8, 0xF0, 0x30],
                           "button": [0x28 * 8, 0xF8 - 2, 0x30, 0x14], "titleColumn": 0x0A, "headingColumn": 0x26, "headerY": 0x70,
                           "textColumn": 0x0C, "textY": 0x98, "lineStep": 0x20, "lineWidth": 0x22, "lineEnd": 0xD8,
                           "turnColumn": 0x0B, "turnY": 0xF8},
            "terrain": {"size": [0x80, 0x50], "tile": [8, 0x10, 0x20, 0x20], "textX": 0x30, "headingY": 0x10, "percentY": 0x24,
                        "nameY": 0x38, "percentWidth": 0x40},
            "followMargin": 6}


def battle_parts(selected: dict, palette: list, output: Path) -> dict:
    hexgrp = Archive(selected["HEXGRP.R3"][0], "HEXGRP.R3").decode(0)
    mark = Archive(selected["MARK.R3"][0], "MARK.R3").decode(0)

    def export(name: str, data: bytes, offset: int, width: int, height: int, member) -> dict:
        size = (width + 7) // 8 * height * 4
        relative = f"images/story/battle-{name}.png"
        target = output / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(png_bytes(planar_image(data[offset:offset + size], width, height, interleaved=True), palette))
        return {"image": relative, "width": width, "height": height,
                "source": {**member.provenance(), "decodedOffset": offset, "length": size}}

    return {"function": export("function", hexgrp.data, FUNCTION_PICTURE, 64, 16, hexgrp),
            "side": [[export(f"side-{side}-{state}", hexgrp.data, SIDE_PICTURES[side, state], 32, 32, hexgrp) for state in (0, 1)]
                     for side in (0, 1)],
            "gauge": {name: export(f"gauge-{name}", mark.data, offset, 8, 10, mark) for name, offset in GAUGE_TILES.items()},
            "ok": export("ok", mark.data, OK_BUTTON, 48, 20, mark)}


def prepare(game: Path, output: Path) -> dict:
    game, output = game.resolve(), output.resolve()
    if output == game or game in output.parents:
        raise ResourceError("story output must be outside the selected original directory")
    before = inventory(game)
    selected = {name: read_resource(game, name) for name in ("MAIN.EXE", "TFDED.COM", "PACKGRP.R3", "FACEDAT.R3", "MARK.R3", "HEXGRP.R3")}
    main = selected["MAIN.EXE"][0]
    if hashlib.sha256(main).hexdigest() != EXAMINED_MAIN:
        raise ResourceError("MAIN does not match the examined original story layout")
    if hashlib.sha256(selected["TFDED.COM"][0]).hexdigest() != EXAMINED_TFDED:
        raise ResourceError("TFDED does not match the statically examined TF-DCE decoder")
    palettes = {index: palette_at(main, 0x38DF0 + index * 48) for index in range(4)}

    def export_pictures(resource: str, count: int, prefix: str) -> list[dict]:
        data = selected[resource][0]
        result = []
        for index, (start, end) in enumerate(picture_directory(data, count)):
            picture, metadata = dce_picture(data[start:end], zero_base=True)
            images = {}
            for palette, colors in palettes.items():
                relative = f"images/story/{prefix}-{index}-palette-{palette}.png"
                target = output / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(png_bytes(picture, colors))
                images[str(palette)] = relative
            result.append({"id": index, "image": images["0"], "width": picture.width,
                           "height": picture.height, "palette": 0, "imagesByPalette": images,
                           "source": {"resource": resource, "directoryOffset": index * 6,
                                      "offset": start, "length": end - start,
                                      "sha256": hashlib.sha256(data[start:end]).hexdigest(),
                                      "indexedPixelSha256": hashlib.sha256(picture.pixels).hexdigest(),
                                      "decoder": metadata}})
        return result

    assets = export_pictures("PACKGRP.R3", 38, "pack")
    portraits = export_pictures("FACEDAT.R3", 240, "portrait")
    mark = Archive(selected["MARK.R3"][0], "MARK.R3").decode(0)
    buttons = []
    for value, label, offset in [(1, "Yes", 0x1BD0), (0, "No", 0x1DB0)]:
        picture = planar_image(mark.data[offset:offset + 480], 48, 20, interleaved=True)
        images = {}
        for palette, colors in palettes.items():
            relative = f"images/story/choice-{value}-palette-{palette}.png"
            target = output / relative
            target.write_bytes(png_bytes(picture, colors))
            images[str(palette)] = relative
        buttons.append({"value": value, "label": label, "image": images["0"],
                        "width": 48, "height": 20, "palette": 0, "imagesByPalette": images,
                        "source": {**mark.provenance(), "decodedOffset": offset, "length": 480,
                                   "selector": "MAIN.EXE:0x164A9..0x165C4",
                                   "buttonPattern": "MAIN.EXE:0x15546..0x15579"}})
    layouts = []
    for mode in (0, 1):
        layouts.append({"mode": mode, "clearRect": [16, 16, 512, 320] if mode == 0 else None,
                        "panelRect": [152, 32, 240, 160], "pictureRect": [160, 40, 224, 144],
                        "offscreenPanelRect": [152, 472, 240, 160], "offscreenPictureOrigin": [160, 480],
                        "savedUnderlayRects": [[152, 32, 240, 76], [152, 108, 240, 76], [152, 184, 240, 8]],
                        "frameAsset": None,
                        "frameStatus": "source window650C primitives; PACKGRP0 is not selected by opcode07",
                        "lifetime": "keep across consecutive opcode08; restore saved underlay before first non08",
                        "transition": {"patterns": 32, "timingRestored": False},
                        "source": {"resource": "MAIN.EXE", "start": 0x206A8, "endExclusive": 0x207C8,
                                   "closeStart": 0x207C8, "interpreterLifetime": "0x1C1CF..0x1C1DF"}})
    if inventory(game) != before:
        raise ResourceError("original files changed during story extraction")
    checked_shapes(main)
    panel = next(asset for asset in assets if asset["id"] == 0x25)
    screens = screen_facts(main, {"layout": battle_layout((panel["width"], panel["height"])),
                                  "colors": [list(color) for color in palettes[3]], "texts": battle_texts(main),
                                  "commands": battle_commands(main),
                                  "parts": battle_parts(selected, palettes[3], output)})
    screens["field"].update(field_facts(main))
    result = {"format": 1, "assets": assets, "portraitAssets": portraits, "choiceButtons": buttons, "layouts": layouts,
              "screens": screens,
              "source": {"inputs": [item[1] for item in selected.values()], "originalHashesPreserved": True,
                         "originalProgramsExecuted": False, "loader": "MAIN.EXE:0x18B5E..0x18C21",
                         "portraitLoader": "MAIN.EXE:0x18A3C..0x18B00",
                         "decoder": "TFDED.COM load addresses0x018C..0x0686; file offsets are load minus0x100",
                         "palettes": [{"resource": "MAIN.EXE", "offset": 0x38DF0 + index * 48,
                                       "length": 48, "slot": index} for index in palettes]},
              "limitations": ["All decoded images use an explicit zero-plane drawing base; source preserved-plane metadata is retained.",
                              "The opcode07 window-frame primitive pixels and original transition timing are not restored by this exporter.",
                              "Palette variants are retained separately; the native source context chooses its current palette.",
                              "Static full payload consumption is not a DOS framebuffer parity measurement."]}
    output.mkdir(parents=True, exist_ok=True)
    temporary = output / ".story.json.tmp"
    temporary.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(output / "story.json")
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--game-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        result = prepare(args.game_dir, args.output)
    except (OSError, ValueError) as error:
        print(f"story preparation failed: {error}", file=sys.stderr)
        return 1
    print(json.dumps({"pictures": len(result["assets"]), "portraits": len(result["portraitAssets"]), "layouts": len(result["layouts"]),
                      "paletteVariants": 4, "originalHashesPreserved": True}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
