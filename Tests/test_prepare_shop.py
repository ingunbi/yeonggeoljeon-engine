# SPDX-License-Identifier: GPL-3.0-only
from pathlib import Path
import json
import os
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import prepare_shop
from prepare_shop import (CODE_SEGMENT, DATA_PARAGRAPH, DATA_SEGMENT, PARTICLES, STOCK_BASE, STOCK_ROWS, STOCK_WIDTH,
                          SWITCH_COUNT, SWITCH_FIRST, TEXTS, checked_menu, checked_texts, particle_table, prepare, stock_rows, text_at)
from resource_formats import ResourceError


def synthetic_main() -> bytearray:
    main = bytearray(DATA_SEGMENT + 0x6000)

    def put(pointer: int, text: bytes) -> None:
        main[DATA_SEGMENT + pointer:DATA_SEGMENT + pointer + len(text) + 1] = text + b"\0"

    for index, (name, (site, pointer)) in enumerate(TEXTS.items()):
        main[site:site + 3] = b"\x68" + struct.pack("<H", pointer)
        put(pointer, b"t%d" % index)
    for facts in PARTICLES.values():
        final_target, final_site, final_pointer = facts["final"]
        open_target, open_site, open_pointer = facts["open"]
        main[final_site:final_site + 3] = b"\x68" + struct.pack("<H", final_pointer)
        main[open_site:open_site + 3] = b"\x68" + struct.pack("<H", open_pointer)
        put(final_pointer, b"F")
        put(open_pointer, b"O")
        main[facts["switch"]:facts["switch"] + 5] = b"\x2e\xff\xa7" + struct.pack("<H", facts["table"] - CODE_SEGMENT)
        cases = [(open_target if index % 2 else final_target) - CODE_SEGMENT for index in range(SWITCH_COUNT)]
        struct.pack_into(f"<{SWITCH_COUNT}H", main, facts["table"], *cases)
    return main


class ShopProducerTests(unittest.TestCase):
    def test_every_text_is_read_from_its_checked_site_and_color_codes_are_dropped(self):
        main = synthetic_main()
        struct.pack_into("<H", main, DATA_SEGMENT + 0x527E, 0x5223)
        struct.pack_into("<H", main, DATA_SEGMENT + 0x54EE, 0x54DB)
        main[0x36459:0x3645D] = b"\xff\x36\x7e\x52"
        main[0x367A7:0x367AB] = b"\xff\x36\xee\x54"
        main[DATA_SEGMENT + 0x5223:DATA_SEGMENT + 0x5226] = b"ok\0"
        main[DATA_SEGMENT + 0x54DB:DATA_SEGMENT + 0x54E3] = b"\x1bC6\xb0\xa1\x1bC7\0"[:8]
        texts, sources = checked_texts(bytes(main))
        self.assertEqual(texts["greeting"], "t0")
        self.assertEqual(texts["thanks"], "가")
        self.assertEqual(sources["confirm"]["pointer"], 0x5223)
        main[TEXTS["farewell"][0]] = 0
        with self.assertRaises(ResourceError):
            checked_texts(bytes(main))

    def test_particles_follow_the_switch_and_ids_outside_it_use_the_open_word(self):
        main = synthetic_main()
        words, source = particle_table(bytes(main), "price")
        self.assertEqual(words[:SWITCH_FIRST], ["O"] * SWITCH_FIRST)
        self.assertEqual(words[SWITCH_FIRST:SWITCH_FIRST + 2], ["F", "O"])
        self.assertEqual(words[63], "O")
        self.assertEqual(source["cases"], SWITCH_COUNT)
        struct.pack_into("<H", main, PARTICLES["price"]["table"], 0x1234)
        with self.assertRaises(ResourceError):
            particle_table(bytes(main), "price")

    def test_stock_row_stops_at_its_first_empty_byte_and_keeps_full_rows(self):
        main = bytearray(DATA_SEGMENT + STOCK_BASE + STOCK_ROWS * STOCK_WIDTH)
        for row in range(STOCK_ROWS):
            main[DATA_SEGMENT + STOCK_BASE + row * STOCK_WIDTH:DATA_SEGMENT + STOCK_BASE + (row + 1) * STOCK_WIDTH] = b"\xff" * STOCK_WIDTH
        main[DATA_SEGMENT + STOCK_BASE:DATA_SEGMENT + STOCK_BASE + STOCK_WIDTH] = bytes([1, 2, 0xFF, 9, 9, 9, 9, 9])
        main[DATA_SEGMENT + STOCK_BASE + STOCK_WIDTH:DATA_SEGMENT + STOCK_BASE + 2 * STOCK_WIDTH] = bytes(range(10, 18))
        rows = stock_rows(bytes(main))
        self.assertEqual(rows[0], [1, 2])
        self.assertEqual(rows[1], list(range(10, 18)))
        self.assertEqual(rows[2], [])

    def test_menu_table_is_far_pointers_ending_in_null(self):
        main = bytearray(DATA_SEGMENT + 0x6000)
        struct.pack_into("<6H", main, DATA_SEGMENT + 0x591C, 0x5912, DATA_PARAGRAPH, 0x5917, DATA_PARAGRAPH, 0, 0)
        main[DATA_SEGMENT + 0x5912:DATA_SEGMENT + 0x5914] = b"a\0"
        main[DATA_SEGMENT + 0x5917:DATA_SEGMENT + 0x5919] = b"b\0"
        self.assertEqual(checked_menu(bytes(main))[0], ["a", "b"])
        struct.pack_into("<H", main, DATA_SEGMENT + 0x591C + 2, 0)
        with self.assertRaises(ResourceError):
            checked_menu(bytes(main))

    def test_a_different_main_is_refused(self):
        with self.assertRaises(ResourceError):
            prepare_shop.extract(b"other", bytes(19328))


@unittest.skipUnless(os.environ.get("ORIGINAL_GAME_DIR"), "requires explicitly selected ORIGINAL_GAME_DIR")
class OriginalShopConformanceTests(unittest.TestCase):
    def test_original_producer_exports_every_city_row_without_mutating_inputs(self):
        with tempfile.TemporaryDirectory() as directory:
            result = prepare(Path(os.environ["ORIGINAL_GAME_DIR"]), Path(directory))
            self.assertEqual(len(result["stock"]), STOCK_ROWS)
            self.assertEqual(len(result["prices"]), 64)
            self.assertEqual(result["merchant"]["person"], 374)
            self.assertEqual({len(words) for words in result["particles"].values()}, {64})
            self.assertTrue(all(item not in (0xFF,) for row in result["stock"] for item in row))
            self.assertTrue(result["source"]["originalFilesPreserved"])
            self.assertFalse(result["source"]["originalProgramsExecuted"])
            self.assertEqual(json.loads((Path(directory) / "shop.json").read_text(encoding="utf-8"))["format"], 1)


if __name__ == "__main__":
    unittest.main()
