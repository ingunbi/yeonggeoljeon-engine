# SPDX-License-Identifier: GPL-3.0-only
from pathlib import Path
import os
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from opening_script import OPENING
from prepare_screens import prepare
from screen_programs import END_BUFFERS, OPCODES, Recorder, centred, outlined, text_rows


class FakeArchive:
    def decode(self, member):
        return type("Member", (), {"data": bytes([member]) * 4})()


def recorder(exe=bytes(64)):
    return Recorder(FakeArchive(), exe, 0, bytes(30), bytes(96 * 16), {}, END_BUFFERS)


class ScreenProgramTests(unittest.TestCase):
    def test_text_rows_pad_and_bold_ascii(self):
        font = bytearray(96 * 16)
        font[(0x41 - 0x20) * 16] = 0x80
        width, height, rows = text_rows([b"A"], bytes(30), bytes(font))
        self.assertEqual((width, height), (3, 20))
        self.assertEqual(rows[1], 0xC0)

    def test_text_rows_leave_a_top_margin(self):
        self.assertEqual(text_rows([b"A", b""], bytes(30), bytes(96 * 16), top=4)[1], 44)

    def test_loads_share_one_asset(self):
        v = recorder()
        v.load(1, 0x2882)
        v.load(1, 0x2888, 16)
        self.assertEqual(v.ops, [[OPCODES["load"], 0, 0, 0], [OPCODES["load"], 0, 1, 16]])

    def test_a_fast_put_restores_the_mode(self):
        v = recorder()
        v.mode = 4
        v.fast(2, 8, 3, 16, 0x2882, 32)
        self.assertEqual(v.ops[-3:], [[OPCODES["mode"], 0], [OPCODES["put"], 16, 8, 24, 16, 0, 32], [OPCODES["mode"], 4]])

    def test_a_dissolve_blits_opaque_after_each_step(self):
        v = recorder()
        v.xfade16(0, 0, 8, 4, None, 0x2882, 0, 0x2888, 0)
        self.assertEqual(sum(op[0] == OPCODES["dissolve"] for op in v.ops), 16)
        self.assertEqual(sum(op[0] == OPCODES["tick"] for op in v.ops), 16)

    def test_outline_stamps_four_times_then_the_ink(self):
        v = recorder()
        outlined(v, 8, 8, 16, 20, 0x2882)
        self.assertEqual(sum(op[0] == OPCODES["stamp"] for op in v.ops), 5)
        self.assertEqual(v.mono, (4, 7, 0))

    def test_centred_rounds_to_whole_bytes(self):
        self.assertEqual(centred(40), 160)
        self.assertEqual(centred(84), -16)

    def test_the_opening_script_holds_no_text(self):
        self.assertTrue(all(isinstance(entry["addr"], int) for entry in OPENING))
        self.assertFalse([value for entry in OPENING for value in entry.values()
                          if isinstance(value, str) and any(ord(character) > 127 for character in value)])

    @unittest.skipUnless(os.environ.get("ORIGINAL_GAME_DIR"), "needs a caller-selected original directory")
    def test_original_programs_when_requested(self):
        opening = os.environ.get("TITLE_OPGRP_FILE")
        with tempfile.TemporaryDirectory() as folder:
            result = prepare(Path(os.environ["ORIGINAL_GAME_DIR"]), Path(folder), Path(opening) if opening else None)
            self.assertTrue((Path(folder) / "screens.bin").is_file())
        self.assertLessEqual({"end1-0", "end1-1", "end2"}, set(result["programs"]))
        self.assertEqual(OPCODES, result["opcodes"])
        if opening:
            self.assertIn("opening", result["programs"])


if __name__ == "__main__":
    unittest.main()
