# SPDX-License-Identifier: GPL-3.0-only
"""MAIN's button menus (CF5:2C92) drawn from MARK member 0, without labels.

Static derivation from MAIN.EXE; no original program was run. Offsets are MAIN
file offsets. The window primitive CF5:151A fills the interior with a 16x16
pattern (CF5:53BE) and frames it with 8x8 three-plane tiles named by DS:0B6E.
Each button (CF5:1AC8, style 0) repeats the 8x20 face tile MARK+0x1F90 and
adds a bevel. Labels stay with the native window, which owns the font.
"""
from __future__ import annotations

import struct

from resource_formats import IndexedImage, ResourceError

MAIN_DATA = 0x37DA0
DATA_PARAGRAPH = 0x313A
MENU_CALL = bytes.fromhex("9a922cf50c")  # far call CF5:2C92
# 0x16743..0x16748: outside battle the frame uses tile set 2 and pattern 2.
FRAME_STYLE_AT, FRAME_STYLE = 0x16743, bytes.fromhex("ba02008bc29ac61ff50c")
FRAME_TILES = 0xB6E
FACE_TILE, FACE_SIZE = 0x1F90, 80
PATTERN_BASE = 0x6F0
PITCH = 24
# push rows; push flags; push 0 (disabled); push 0 (width); push 0 (scroll);
# mov ax,x; mov dx,y; lea bx,[list]; call CF5:2C92.
PLAIN_CALLS = {"title": 0x1F9C5, "settings": 0x1F93A}
# The option sub-menus pass a disabled-byte array: push 2; push 0; lea ax,[bp-n];
# push ax; push 0; push 0; mov ax,x; mov dx,y; lea bx,[list]; call CF5:2C92.
CHOICE_CALLS = {"monitor": 0x229DA, "switch": 0x22908}


def far_strings(main: bytes, table: int, limit: int = 16) -> list[bytes]:
    """The far string list a menu reads, up to its null pointer."""
    result = []
    for index in range(limit):
        at = MAIN_DATA + table + index * 4
        offset, segment = struct.unpack_from("<HH", main, at)
        if offset == 0 and segment == 0:
            return result
        if segment != DATA_PARAGRAPH:
            raise ResourceError(f"MAIN.EXE menu list DS:{table:04X} leaves the data segment")
        end = main.find(b"\0", MAIN_DATA + offset)
        if end < 0:
            raise ResourceError(f"MAIN.EXE menu list DS:{table:04X} has an unterminated item")
        result.append(main[MAIN_DATA + offset:end])
    raise ResourceError(f"MAIN.EXE menu list DS:{table:04X} has no null pointer")


def menu_call(main: bytes, at: int, choice: bool) -> dict:
    """Checked operands of one examined CF5:2C92 call."""
    if choice:
        code, prefix = main[at:at + 27], 12
        shaped = (len(code) == 27 and code[0] == 0x6A and code[2:4] == b"\x6a\x00" and code[4:6] == b"\x8d\x46"
                  and code[7:12] == b"\x50\x6a\x00\x6a\x00")
        rows, flags = code[1], 0
    else:
        code, prefix = main[at:at + 25], 10
        shaped = len(code) == 25 and code[0] == 0x6A and code[2] == 0x6A and code[4:10] == b"\x6a\x00" * 3
        rows, flags = code[1], code[3]
    tail = code[prefix:]
    if not shaped or tail[0] != 0xB8 or tail[3] != 0xBA or tail[6:8] != b"\x8d\x1e" or tail[10:] != MENU_CALL:
        raise ResourceError(f"MAIN.EXE menu call at {at:#x} does not match the examined profile")
    x, y, table = (struct.unpack_from("<H", tail, at)[0] for at in (1, 4, 8))
    return {"rows": rows, "flags": flags, "x": x, "y": y, "table": table}


def geometry(x: int, y: int, rows: int, columns: int) -> dict:
    """CF5:2C92 without a scroll bar (0x165FA..0x16727, 0x167DB..0x167EA)."""
    width_columns = max(columns, 8)
    height = (rows * PITCH + 31) & ~15
    if y < 16:
        y = 0
    if y + height >= 384:
        y -= (y + height - 0x171) & ~15
    pad = (height - rows * PITCH - 16) // 2 + 8
    text_y = y + pad + (PITCH - 16) // 2
    buttons = [[x + 8, text_y + PITCH * row, width_columns * 8, 16] for row in range(rows)]
    return {"window": [x, y, (width_columns + 2) * 8, height], "buttons": buttons}


class Canvas:
    def __init__(self, width: int, height: int):
        self.width, self.height, self.pixels = width, height, bytearray(width * height)

    def put(self, x: int, y: int, color: int) -> None:
        if 0 <= x < self.width and 0 <= y < self.height:
            self.pixels[y * self.width + x] = color

    def planes(self, rows: list[list[int]], x: int, y: int) -> None:
        """Rows of per-8-pixel plane bytes, bit seven leftmost."""
        for row, groups in enumerate(rows):
            for group, planes in enumerate(groups):
                for bit in range(8):
                    color = sum(((plane >> (7 - bit)) & 1) << index for index, plane in enumerate(planes))
                    self.put(x + group * 8 + bit, y + row, color)

    def fill(self, x: int, y: int, width: int, height: int, color: int) -> None:
        for row in range(y, y + height):
            for column in range(x, x + width):
                self.put(column, row, color)


def three_plane_tile(mark: bytes, offset: int) -> list[list[list[int]]]:
    """An 8x8 frame tile: three bytes a row, plane three written zero (0xED71)."""
    return [[list(mark[offset + row * 3:offset + row * 3 + 3])] for row in range(8)]


def pattern_quarter(mark: bytes, tile: int, quarter: int) -> list[list[list[int]]]:
    """One 8x8 quarter of a 16x16 interleaved tile with an eight-byte row (0:7E4A)."""
    rows = []
    for row in range(8):
        at = tile + (row + (quarter >> 1) * 8) * 8 + (quarter & 1) * 4
        rows.append([list(mark[at:at + 4])])
    return rows


def draw_window(canvas: Canvas, main: bytes, mark: bytes, x: int, y: int, width: int, height: int,
                tile_set: int = 2, pattern: int = 2) -> None:
    """CF5:151A at (x, y) in a canvas whose origin is the window's."""
    tiles = [struct.unpack_from("<H", main, MAIN_DATA + FRAME_TILES + 2 * (tile_set * 8 + k))[0] for k in range(8)]
    base = PATTERN_BASE + pattern * 0x200
    inner_x, inner_y, inner_w, inner_h = x + 8, y + 8, width - 16, height - 16
    # Whole tiles use all quarters; an eight-pixel remainder uses the left or top half.
    for row_index, top in enumerate(range(inner_y, inner_y + inner_h, 16)):
        for column_index, left in enumerate(range(inner_x, inner_x + inner_w, 16)):
            tile = base + (column_index & 1) * 0x80 + (row_index & 1) * 0x100
            wide, tall = left + 16 <= inner_x + inner_w, top + 16 <= inner_y + inner_h
            for quarter in range(4):
                if (quarter & 1 and not wide) or (quarter >> 1 and not tall):
                    continue
                canvas.planes(pattern_quarter(mark, tile, quarter), left + (quarter & 1) * 8, top + (quarter >> 1) * 8)

    def strip(top: int, left: int, middle: int | None, right: int) -> None:
        canvas.planes(three_plane_tile(mark, tiles[left]), x, top)
        if middle is not None:
            for column in range(x + 8, x + width - 8, 8):
                canvas.planes(three_plane_tile(mark, tiles[middle]), column, top)
        canvas.planes(three_plane_tile(mark, tiles[right]), x + width - 8, top)

    strip(y, 0, 4, 1)
    for top in range(y + 8, y + height - 8, 8):
        strip(top, 5, None, 7)
    strip(y + height - 8, 2, 6, 3)


def draw_button(canvas: Canvas, mark: bytes, x: int, y: int, width: int, height: int = 16) -> None:
    """CF5:1AC8 style 0: the face from y-2, then the bevel (0x155A2..0x15673)."""
    face = mark[FACE_TILE:FACE_TILE + FACE_SIZE]
    rows = [[list(face[row * 4:row * 4 + 4])] for row in range(20)]
    for column in range(x, x + width, 8):
        canvas.planes(rows, column, y - 2)
    canvas.fill(x - 2, y - 4, width + 5, 1, 0)
    canvas.fill(x - 2, y - 3, width + 5, 1, 7)
    canvas.fill(x - 2, y - 3, 1, height + 7, 7)
    canvas.fill(x - 1, y - 2, 1, height + 5, 7)
    canvas.fill(x - 2, y + height + 2, width + 2, 2, 0)
    canvas.fill(x + width, y - 4, 2, height + 6, 0)


def menu_windows(main: bytes, mark: bytes) -> dict[str, tuple[dict, IndexedImage]]:
    """The title menu, the title options and their two-choice sub-menus."""
    if main[FRAME_STYLE_AT:FRAME_STYLE_AT + len(FRAME_STYLE)] != FRAME_STYLE:
        raise ResourceError("MAIN.EXE menu frame style does not match the examined profile")
    if len(mark) < FACE_TILE + FACE_SIZE:
        raise ResourceError("MARK.R3 member 0 is shorter than the menu tiles")
    result = {}
    calls = [(name, at, False) for name, at in PLAIN_CALLS.items()] + [(name, at, True) for name, at in CHOICE_CALLS.items()]
    for name, at, choice in calls:
        call = menu_call(main, at, choice)
        items = far_strings(main, call["table"])
        if len(items) < call["rows"]:
            raise ResourceError(f"MAIN.EXE menu at {at:#x} lists fewer items than it shows")
        # The width counts every listed item, shown or not (0x16636..0x166A0).
        facts = geometry(call["x"], call["y"], call["rows"], max(len(item) for item in items))
        x, y, width, height = facts["window"]
        canvas = Canvas(width, height)
        draw_window(canvas, main, mark, 0, 0, width, height)
        for bx, by, bw, bh in facts["buttons"]:
            draw_button(canvas, mark, bx - x, by - y, bw, bh)
        facts.update({"backgroundSaved": call["flags"] & 0x40 == 0, "currentChoiceDisabled": choice,
                      "source": {"call": f"MAIN.EXE:{at:#x}", "list": f"DS:{call['table']:04X}",
                                 "window": "MAIN.EXE:0x14E6A..0x14EFE", "button": "MAIN.EXE:0x15418..0x15673"}})
        result[name] = (facts, IndexedImage(width, height, bytes(canvas.pixels)))
    return result
