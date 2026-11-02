# SPDX-License-Identifier: GPL-3.0-only
"""MAIN's button menu windows; synthetic bytes, real files only when selected."""
from pathlib import Path
import os
import struct
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))

from menu_windows import (CHOICE_CALLS, DATA_PARAGRAPH, FACE_TILE, FRAME_STYLE, FRAME_STYLE_AT, FRAME_TILES, MAIN_DATA,
                          PLAIN_CALLS, Canvas, draw_button, geometry, menu_call, menu_windows)
from resource_formats import Archive, ResourceError


def plain_call(rows: int, flags: int, x: int, y: int, table: int) -> bytes:
    return (bytes([0x6A, rows, 0x6A, flags]) + b"\x6a\x00" * 3 + b"\xb8" + struct.pack("<H", x) + b"\xba" +
            struct.pack("<H", y) + b"\x8d\x1e" + struct.pack("<H", table) + b"\x9a\x92\x2c\xf5\x0c")


def choice_call(rows: int, x: int, y: int, table: int) -> bytes:
    return (bytes([0x6A, rows, 0x6A, 0, 0x8D, 0x46, 0xFE, 0x50]) + b"\x6a\x00" * 2 + b"\xb8" + struct.pack("<H", x) +
            b"\xba" + struct.pack("<H", y) + b"\x8d\x1e" + struct.pack("<H", table) + b"\x9a\x92\x2c\xf5\x0c")


def synthetic_main() -> bytes:
    data = bytearray(MAIN_DATA + 0x4000)
    data[FRAME_STYLE_AT:FRAME_STYLE_AT + len(FRAME_STYLE)] = FRAME_STYLE
    lists = {"title": (0x1000, [b"A" * 15, b"B" * 15, b"C" * 8, b"D" * 13]), "settings": (0x1100, [b"E" * 6] * 5),
             "monitor": (0x1200, [b"F" * 4] * 2), "switch": (0x1300, [b"G" * 2] * 2)}
    text = 0x2000
    for name, (table, items) in lists.items():
        for index, item in enumerate(items):
            struct.pack_into("<HH", data, MAIN_DATA + table + index * 4, text, DATA_PARAGRAPH)
            data[MAIN_DATA + text:MAIN_DATA + text + len(item) + 1] = item + b"\0"
            text += len(item) + 1
    for name, (x, y, rows, flags) in {"title": (0xD8, 0x80, 4, 0x40), "settings": (0x120, 0xA0, 3, 0x40)}.items():
        data[PLAIN_CALLS[name]:PLAIN_CALLS[name] + 25] = plain_call(rows, flags, x, y, lists[name][0])
    for name in CHOICE_CALLS:
        data[CHOICE_CALLS[name]:CHOICE_CALLS[name] + 27] = choice_call(2, 0x140, 0x90, lists[name][0])
    for k in range(8):
        struct.pack_into("<H", data, MAIN_DATA + FRAME_TILES + 2 * (16 + k), 0x10)
    return bytes(data)


class MenuWindowTests(unittest.TestCase):
    def test_title_and_option_windows_follow_the_menu_size_rules(self):
        self.assertEqual(geometry(216, 128, 4, 15),
                         {"window": [216, 128, 136, 112], "buttons": [[224, 140 + 24 * i, 120, 16] for i in range(4)]})
        self.assertEqual(geometry(288, 160, 3, 6)["window"], [288, 160, 80, 96])
        self.assertEqual(geometry(288, 160, 3, 6)["buttons"][0], [296, 176, 64, 16])
        self.assertEqual(geometry(320, 144, 2, 3)["buttons"], [[328, 156, 64, 16], [328, 180, 64, 16]])
        # A window that would reach row 384 moves up in sixteen-pixel steps.
        self.assertEqual(geometry(216, 300, 4, 15)["window"][1], 268)
        self.assertEqual(geometry(216, 8, 1, 8)["window"][1], 0)

    def test_menu_calls_are_checked_before_their_operands_are_used(self):
        main = synthetic_main()
        self.assertEqual(menu_call(main, PLAIN_CALLS["title"], False), {"rows": 4, "flags": 0x40, "x": 216, "y": 128, "table": 0x1000})
        self.assertEqual(menu_call(main, CHOICE_CALLS["monitor"], True)["rows"], 2)
        broken = bytearray(main)
        broken[PLAIN_CALLS["title"] + 21] = 0x93
        with self.assertRaises(ResourceError):
            menu_call(bytes(broken), PLAIN_CALLS["title"], False)
        styled = bytearray(main)
        styled[FRAME_STYLE_AT + 1] = 5
        with self.assertRaises(ResourceError):
            menu_windows(bytes(styled), bytes(FACE_TILE + 80))

    def test_windows_count_every_listed_item_for_their_width(self):
        windows = menu_windows(synthetic_main(), bytes(FACE_TILE + 80))
        self.assertEqual(windows["title"][0]["window"], [216, 128, 136, 112])
        self.assertEqual(windows["settings"][0]["window"], [288, 160, 80, 96])
        self.assertEqual(windows["monitor"][0]["window"], [320, 144, 80, 64])
        self.assertTrue(windows["switch"][0]["backgroundSaved"])
        self.assertFalse(windows["title"][0]["backgroundSaved"])
        self.assertEqual((windows["title"][1].width, windows["title"][1].height), (136, 112))

    def test_button_bevel_is_drawn_after_its_face(self):
        mark = bytearray(FACE_TILE + 80)
        mark[FACE_TILE:FACE_TILE + 80] = bytes([0xFF, 0, 0, 0]) * 20  # colour 1 face
        canvas = Canvas(40, 40)
        draw_button(canvas, bytes(mark), 8, 10, 16)
        pixel = lambda x, y: canvas.pixels[y * 40 + x]
        self.assertEqual(pixel(10, 12), 1)
        self.assertEqual(pixel(6, 7), 7)    # light line above, light left edge
        self.assertEqual(pixel(7, 20), 7)
        self.assertEqual(pixel(6, 6), 0)    # dark line on top
        self.assertEqual(pixel(24, 15), 0)  # dark right shadow
        self.assertEqual(pixel(12, 29), 0)  # dark bottom shadow


@unittest.skipUnless(os.environ.get("ORIGINAL_GAME_DIR"), "requires explicitly selected ORIGINAL_GAME_DIR")
class OriginalMenuWindowTests(unittest.TestCase):
    def test_original_title_menu_matches_the_examined_geometry(self):
        game = Path(os.environ["ORIGINAL_GAME_DIR"])
        main = (game / "MAIN.EXE").read_bytes()
        mark = Archive((game / "MARK.R3").read_bytes(), "MARK.R3").decode(0).data
        windows = menu_windows(main, mark)
        self.assertEqual(windows["title"][0]["buttons"], [[224, 140 + 24 * i, 120, 16] for i in range(4)])
        self.assertEqual(windows["settings"][0]["window"], [288, 160, 80, 96])
        self.assertEqual(windows["monitor"][0]["window"], [320, 144, 80, 64])


if __name__ == "__main__":
    unittest.main()
