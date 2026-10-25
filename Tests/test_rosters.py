# SPDX-License-Identifier: GPL-3.0-only
import os
from pathlib import Path
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from prepare_rosters import decode_setup, prepare


class RosterTests(unittest.TestCase):
    def test_setup_header_and_flags(self):
        data = bytearray(281)
        data[:11] = bytes([1, 17, 4, 8, 1, 3, 0, 9, 0, 6, 0])
        data[11:20] = struct.pack("<H7B", 7, 2, 3, 0, 1, 8, 1, 2)
        value = decode_setup(bytes(data), 3)
        self.assertTrue(value["header"]["preserveFriendlySlots"])
        self.assertEqual(value["header"]["turnLimit"], 17)
        self.assertEqual(value["header"]["objectives"][0], {"eventKind": 7, "enabled": True, "person": 3})
        self.assertEqual(value["rows"][0]["flags"], 7)
        self.assertEqual(value["rows"][0]["classID"], 255)

    def test_replacement_retains_identity_and_source_widths(self):
        data = bytearray(391)
        data[0] = 1
        data[1:14] = struct.pack("<H7BH2B", 0x400, 5, 6, 0, 19, 2, 0, 6, 0xFF01, 4, 9)
        value = decode_setup(bytes(data), 0x22)
        self.assertEqual(value["replaceSide"], 0)
        self.assertEqual(value["rows"][0]["flags"], 0)
        self.assertEqual(value["rows"][0]["parameter"], 0xFF01)
        self.assertEqual(value["rows"][0]["person"], 0x400)

    def test_truncation_is_not_partial_success(self):
        with self.assertRaises(ValueError):
            decode_setup(bytes(280), 3)

    @unittest.skipUnless(os.environ.get("ORIGINAL_GAME_DIR"), "caller-selected original data required")
    def test_real_producer_identity_and_population(self):
        with tempfile.TemporaryDirectory() as folder:
            result = prepare(Path(os.environ["ORIGINAL_GAME_DIR"]), Path(folder))
            self.assertTrue(result["programs"])
            self.assertEqual(len({(p["chapter"], p["member"], p["offset"]) for p in result["programs"]}), len(result["programs"]))
            self.assertTrue(all(len(p["rows"]) == 30 for p in result["programs"]))
