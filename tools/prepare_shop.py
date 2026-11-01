#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Extract the original item shop facts into local data; do not distribute the output."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import sys

from prepare_resources import EXAMINED_MAIN, inventory
from prepare_scene import read_resource
from resource_formats import ResourceError

DATA_SEGMENT, DATA_PARAGRAPH = 0x37DA0, 0x313A
CODE_SEGMENT = 0x33540
ITEM_COUNT, ITEM_BASE, ITEM_STRIDE, PRICE_BYTE = 64, 0xD00, 16, 13
STOCK_BASE, STOCK_ROWS, STOCK_WIDTH = 0x56A2, 78, 8
EMPTY = 0xFF
# Every text carries the MAIN offset of the push that selects it.
TEXTS = {
    "greeting": (0x36B7C, 0x5928), "question": (0x36BB9, 0x593B), "farewell": (0x36BE6, 0x594A),
    "buyPrompt": (0x362E1, 0x54FA), "priceTail": (0x3644B, 0x5521), "shortMoney": (0x364CD, 0x5530),
    "receiverFull": (0x3666C, 0x5589), "noItems": (0x36704, 0x55CD), "giveConfirm": (0x36739, 0x55D9),
    "buyAgain": (0x367B9, 0x55EF), "sellPrompt": (0x367E3, 0x5603), "sellEmpty": (0x368B4, 0x561D),
    "sellItemPrompt": (0x368CA, 0x5646), "saleTail": (0x36A5F, 0x566F), "sellAgain": (0x36B19, 0x5687),
}
# Words read through a pointer variable instead of a direct push.
INDIRECT_TEXTS = {"confirm": (0x36459, 0x527E), "thanks": (0x367A7, 0x54EE)}
# MAIN switches on item id minus six over 57 cases to pick the word after a
# name by its final consonant; ids outside the range use the open word.
PARTICLES = {
    "price": {"switch": 0x363A9, "table": 0x363AE, "final": (0x3642B, 0x36431, 0x550F), "open": (0x36420, 0x36426, 0x5518)},
    "receiver": {"switch": 0x36507, "table": 0x3650C, "final": (0x36589, 0x3658F, 0x5559), "open": (0x3657E, 0x36584, 0x5571)},
    "sale": {"switch": 0x369BD, "table": 0x369C2, "final": (0x36A3F, 0x36A45, 0x565D), "open": (0x36A34, 0x36A3A, 0x5666)},
}
SWITCH_FIRST, SWITCH_COUNT = 6, 57
CODE_CHECKS = {
    "stock base": (0x36B5D, b"\x81\xc6\xa2\x56"),
    "merchant placement": (0x24BE6, b"\x6a\x04\xb8\x76\x03\xb2\x0f\xb3\x0b"),
    "shop music": (0x24BDC, b"\x6a\x0f\x68\xee\x66"),
    "room key": (0x24BD6, b"\x80\x7e\xff\x07"),
    "town chapter": (0x24BFE, b"\x3c\x03"),
    "town city": (0x24C0A, b"\x3c\x0b"),
    "special town music": (0x24C0E, b"\xb9\x01\x00"),
    "town music": (0x24C13, b"\xb9\x05\x00"),
    "top menu": (0x36BCF, b"\xb8\xe8\x00\xba\x80\x00\x8d\x1e\x1c\x59"),
    "item menu": (0x36337, b"\x6a\x08\x50\x50\x50\x50\xb8\xa0\x01\xba\x60\x00"),
    "description window": (0x362BB, b"\x68\x80\x00"),
    "description position": (0x362C9, b"\xb8\x70\x00\xba\xa0\x00\xbb\x40\x01"),
    "inventory window": (0x3668E, b"\x68\xd8\x00\x68\xa0\x00\x6a\x70\x68\x90\x00"),
    "inventory first row": (0x366AA, b"\xbf\xa8\x00"),
    "inventory column": (0x366BD, b"\x6a\x1c"),
    "inventory step": (0x366E5, b"\x83\xc7\x10"),
}


def text_at(main: bytes, pointer: int) -> str:
    """The source colors its amounts with ESC C digit; those codes are dropped."""
    start = DATA_SEGMENT + pointer
    end = main.index(0, start)
    return re.sub(r"\x1bC[0-9]", "", main[start:end].decode("cp949"))


def checked_texts(main: bytes) -> tuple[dict, dict]:
    texts, sources = {}, {}
    for name, (site, pointer) in TEXTS.items():
        if main[site:site + 3] != b"\x68" + struct.pack("<H", pointer):
            raise ResourceError(f"shop text site differs from the examined source: {name}")
        texts[name], sources[name] = text_at(main, pointer), {"site": site, "pointer": pointer}
    for name, (site, variable) in INDIRECT_TEXTS.items():
        if main[site:site + 4] != b"\xff\x36" + struct.pack("<H", variable):
            raise ResourceError(f"shop text site differs from the examined source: {name}")
        pointer = struct.unpack_from("<H", main, DATA_SEGMENT + variable)[0]
        texts[name], sources[name] = text_at(main, pointer), {"site": site, "variable": variable, "pointer": pointer}
    return texts, sources


def checked_menu(main: bytes) -> tuple[list[str], int]:
    table = DATA_SEGMENT + 0x591C
    first, first_segment, second, second_segment, end, end_segment = struct.unpack_from("<6H", main, table)
    if (first_segment, second_segment, end, end_segment) != (DATA_PARAGRAPH, DATA_PARAGRAPH, 0, 0):
        raise ResourceError("shop menu table differs from the examined source")
    return [text_at(main, first), text_at(main, second)], table


def particle_table(main: bytes, name: str) -> tuple[list[str], dict]:
    facts = PARTICLES[name]
    words = {}
    for key in ("final", "open"):
        target, site, pointer = facts[key]
        if main[site:site + 3] != b"\x68" + struct.pack("<H", pointer):
            raise ResourceError(f"shop particle site differs from the examined source: {name}")
        words[target - CODE_SEGMENT] = text_at(main, pointer)
    if main[facts["switch"]:facts["switch"] + 3] != b"\x2e\xff\xa7":
        raise ResourceError(f"shop particle switch differs from the examined source: {name}")
    if struct.unpack_from("<H", main, facts["switch"] + 3)[0] != facts["table"] - CODE_SEGMENT:
        raise ResourceError(f"shop particle table differs from the examined source: {name}")
    open_word = words[facts["open"][0] - CODE_SEGMENT]
    result = [open_word] * ITEM_COUNT
    for index, target in enumerate(struct.unpack_from(f"<{SWITCH_COUNT}H", main, facts["table"])):
        if target not in words:
            raise ResourceError(f"shop particle case differs from the examined source: {name}")
        result[SWITCH_FIRST + index] = words[target]
    return result, {"resource": "MAIN.EXE", "offset": facts["table"], "cases": SWITCH_COUNT, "firstItem": SWITCH_FIRST}


def stock_rows(main: bytes) -> list[list[int]]:
    """MAIN36B6A counts a row up to its first 0xFF, at most eight items."""
    rows = []
    for row in range(STOCK_ROWS):
        start = DATA_SEGMENT + STOCK_BASE + row * STOCK_WIDTH
        values = main[start:start + STOCK_WIDTH]
        count = values.index(EMPTY) if EMPTY in values else STOCK_WIDTH
        rows.append(list(values[:count]))
    return rows


def extract(main: bytes, bak: bytes) -> dict:
    if hashlib.sha256(main).hexdigest() != EXAMINED_MAIN:
        raise ResourceError("MAIN does not match the examined shop profile")
    if len(bak) != 19328:
        raise ResourceError("BAKDATA does not match the examined item layout")
    for name, (offset, expected) in CODE_CHECKS.items():
        if main[offset:offset + len(expected)] != expected:
            raise ResourceError(f"shop code differs from the examined source: {name}")
    texts, text_sources = checked_texts(main)
    menu, menu_source = checked_menu(main)
    particles, particle_sources = {}, {}
    for name in PARTICLES:
        particles[name], particle_sources[name] = particle_table(main, name)
    return {
        "format": 1,
        "stock": stock_rows(main),
        "prices": [bak[ITEM_BASE + i * ITEM_STRIDE + PRICE_BYTE] for i in range(ITEM_COUNT)],
        "merchant": {"person": 374, "x": 0x0F, "y": 0x0B, "sourceFacing": 4, "music": 0x0F},
        "townMusic": {"normal": 5, "special": 1, "chapter": 3, "city": 0x0B},
        "menu": menu,
        "texts": texts,
        "particles": particles,
        "windows": {
            "top": {"x": 0xE8, "y": 0x80},
            "list": {"x": 0x1A0, "y": 0x60, "rows": 8},
            "description": {"x": 0x70, "y": 0xA0, "width": 0x140, "height": 0x80},
            "inventory": {"x": 0xD8, "y": 0xA0, "width": 0x70, "height": 0x90,
                          "textColumn": 0x1C, "firstRow": 0xA8, "rowStep": 0x10},
        },
        "source": {
            "stock": {"resource": "MAIN.EXE", "offset": DATA_SEGMENT + STOCK_BASE, "rows": STOCK_ROWS, "width": STOCK_WIDTH},
            "prices": {"resource": "BAKDATA.R3", "offset": ITEM_BASE, "stride": ITEM_STRIDE, "priceByteOffset": PRICE_BYTE},
            "texts": text_sources, "menu": {"resource": "MAIN.EXE", "offset": menu_source}, "particles": particle_sources,
            "methods": ["MAIN.EXE:0x24BD6..0x24C1A", "MAIN.EXE:0x25FE0..0x26114", "MAIN.EXE:0x26A66..0x26A77",
                        "MAIN.EXE:0x36244..0x36BF6", "MAIN.EXE:0x15B02..0x15BB3"],
            "method": "static original byte interpretation; DOS program not executed",
        },
        "limitations": [
            "The buy, refuse and sale sound effects are not played by the native host.",
            "The description height is read from the window call; the runtime window has not been compared.",
            "Native windows use the engine font and frame, not the original primitives.",
        ],
    }


def prepare(game: Path, output: Path) -> dict:
    game, output = game.resolve(), output.resolve()
    if output == game or game in output.parents:
        raise ResourceError("shop output must be outside the original directory")
    before = inventory(game)
    main, main_source = read_resource(game, "MAIN.EXE")
    bak, bak_source = read_resource(game, "BAKDATA.R3")
    result = extract(main, bak)
    if inventory(game) != before:
        raise ResourceError("original files changed during shop extraction")
    result["source"].update({"inputs": [main_source, bak_source], "originalFilesPreserved": True, "originalProgramsExecuted": False})
    output.mkdir(parents=True, exist_ok=True)
    temporary = output / ".shop.json.tmp"
    temporary.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(output / "shop.json")
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--game-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        result = prepare(args.game_dir, args.output)
    except (OSError, ValueError, ResourceError) as error:
        print(f"shop extraction failed: {error}", file=sys.stderr)
        return 1
    print(json.dumps({"rows": len(result["stock"]), "stockedCities": sum(1 for row in result["stock"] if row),
                      "originalFilesPreserved": result["source"]["originalFilesPreserved"]}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
