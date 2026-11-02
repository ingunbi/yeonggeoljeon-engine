# SPDX-License-Identifier: GPL-3.0-only
from pathlib import Path
import json
import os
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import prepare_citizens
from prepare_citizens import group_table, people
from resource_formats import ResourceError


def block() -> bytes:
    """One populated city in a two-city table: 2 rows, then 2 message words."""
    rows = bytes([0x7D, 2]) + struct.pack("<HH", 0, 1) + bytes([3, 1]) + struct.pack("<H", 1)
    table = struct.pack("<B", 2) + struct.pack("<HH", 10, 0) + struct.pack("<H", 0)
    messages = struct.pack("<HH", 0, 0xFFFF)
    return table + messages + bytes([2]) + rows


class CitizenFormatTests(unittest.TestCase):
    def test_people_keep_name_and_sprite_bytes(self):
        row = "가".encode("cp949") + bytes(6) + bytes([9]) + bytes(4)
        self.assertEqual(people(row * 256)[3], {"name": "가", "sprite": 9})

    def test_group_table_reads_rows_and_skips_absent_lines(self):
        text = b"\0" * 4 + "안녕".encode("cp949") + b"\0"
        result = group_table(block(), text, 4)
        self.assertEqual(result["cityCount"], 2)
        self.assertEqual(result["cities"], {"0": [{"key": 0x7D, "ids": [0, 1]}, {"key": 3, "ids": [1]}]})
        self.assertEqual(result["lines"], {"0": "안녕"})

    def test_line_outside_the_text_is_rejected(self):
        with self.assertRaises(ResourceError):
            group_table(block(), b"\0", 4)

    def test_examined_profile_is_required(self):
        with self.assertRaises(ResourceError):
            prepare_citizens.extract(b"", b"", b"", b"")

    @unittest.skipUnless(os.environ.get("ORIGINAL_GAME_DIR"), "needs a caller-selected original directory")
    def test_original_citizens_when_requested(self):
        game = Path(os.environ["ORIGINAL_GAME_DIR"])
        with tempfile.TemporaryDirectory() as folder:
            result = prepare_citizens.prepare(game, Path(folder))
            self.assertEqual(json.loads((Path(folder) / "citizens.json").read_text(encoding="utf-8"))["format"], 1)
        self.assertEqual(len(result["people"]), 256)
        self.assertEqual(len(result["groups"]), 4)
        self.assertEqual(sum(len(group["cities"]) for group in result["groups"]), 33)
        self.assertEqual(sum(len(group["lines"]) for group in result["groups"]), 653)


if __name__ == "__main__":
    unittest.main()
