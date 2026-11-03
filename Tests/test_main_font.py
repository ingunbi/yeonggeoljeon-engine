# SPDX-License-Identifier: GPL-3.0-only
"""MAIN's glyph export; synthetic bytes only."""
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))

from prepare_story import FONT_NAMES, HANGUL_RECORD, HANGUL_RECORDS, main_font
from resource_formats import ResourceError


def synthetic_inputs():
    main = bytearray(0x37DA0 + 0x1000)
    for offset, name in FONT_NAMES.items():
        main[0x37DA0 + offset:0x37DA0 + offset + len(name)] = name
    hangul = bytearray(HANGUL_RECORD * HANGUL_RECORDS)
    for index in range(HANGUL_RECORDS):
        row = index // 94
        hangul[index * HANGUL_RECORD:index * HANGUL_RECORD + 2] = bytes([0xA1 + index % 94, row + (0xA1 if row < 12 else 0xA4)])
    selected = {"ALL_FONT.16P": (bytes(hangul), {}), "HANKAKU.FNT": (bytes(96 * 16), {})}
    palettes = {slot: [(slot, slot, slot)] * 16 for slot in range(4)}
    return bytes(main), selected, palettes


class MainFontTests(unittest.TestCase):
    def test_font_files_are_copied_with_their_record_shape(self):
        main, selected, palettes = synthetic_inputs()
        with tempfile.TemporaryDirectory() as directory:
            facts = main_font(main, selected, palettes, Path(directory))
            self.assertEqual((Path(directory) / facts["hangul"]["path"]).read_bytes(), selected["ALL_FONT.16P"][0])
            self.assertEqual((facts["hangulRows"], facts["asciiRows"], facts["leads"]), (14, 16, [0xA1, 0xC8]))
            self.assertEqual(facts["colour7"]["2"], [2, 2, 2])

    def test_a_font_whose_records_are_out_of_order_is_refused(self):
        main, selected, palettes = synthetic_inputs()
        shuffled = bytearray(selected["ALL_FONT.16P"][0])
        shuffled[1128 * HANGUL_RECORD + 1] = 0xAD  # the first Hangul row must be B0, not AD
        selected["ALL_FONT.16P"] = (bytes(shuffled), {})
        with tempfile.TemporaryDirectory() as directory, self.assertRaises(ResourceError):
            main_font(main, selected, palettes, Path(directory))


if __name__ == "__main__":
    unittest.main()
