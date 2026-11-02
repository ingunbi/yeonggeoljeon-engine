# SPDX-License-Identifier: GPL-3.0-only
from pathlib import Path
import json
import os
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))

from prepare_saves import ESAVE_SIZE, MSAVE_SIZE, prepare, read_date, read_slot
from resource_formats import ResourceError


def msave() -> bytearray:
    data = bytearray(MSAVE_SIZE)
    data[:5] = bytes([0x99, 0x70, 0x25, 0x13, 0x08])
    data[5:10] = "서장".encode("cp949") + b"\0"
    struct.pack_into("<H", data, 0x23, 1234)
    struct.pack_into("<H", data, 0x23 + 0xE, 0xFFFF)
    data[0x23 + 0x10], data[0x23 + 0x12] = 5, 2
    data[0x37:0x40] = bytes([11, 13, 0, 0, 7, 2, 4, 1, 0])
    data[0x40:0x49] = bytes([8, 15, 0, 0, 3, 0, 9, 1, 0])
    actor = 0x49 + 3 * 26
    struct.pack_into("<H", data, actor + 6, 0x205)
    data[actor + 8], data[actor + 9], data[actor + 0xF], data[actor + 0x15] = 12, 9, 0x15, 2
    person = 0x695 + 7 * 18
    data[person:person + 18] = bytes([0x81, 4, 1, 2, 90, 0x10, 0x27, 6, 12, 33, 1, 2, 3, 4, 5, 6, 7, 8])
    data[0x2195 + 2 * 6 + 5] = 3
    return data


def esave() -> bytearray:
    data = bytearray(ESAVE_SIZE)
    struct.pack_into("<4H", data, 0, 2, 1, 6, 20)
    struct.pack_into("<2H", data, 0xC, 7, 0x2004)
    struct.pack_into("<H", data, 0x10 + 6, 9)
    data[0x10 + 6 + 2:0x10 + 6 + 6] = bytes([3, 4, 1, 6])
    struct.pack_into("<H", data, 0x190, 4282)
    struct.pack_into("<H", data, 0x192, 1)
    struct.pack_into("<H", data, 0x19A, 11)
    struct.pack_into("<H", data, 0x1A6, 0x123)
    data[0x1A8:0x1B1] = bytes([4, 5, 1, 0, 2, 0x34, 0x12, 6, 8])
    data[0x395 + 3] = 0x80
    data[0x3B5:0x3B8] = bytes([2, 40, 41])
    data[0x3D6:0x3DC] = "목표".encode("cp949") + b"\0x"
    data[0x557], data[0x558] = 30, 1
    return data


class SaveFormatTests(unittest.TestCase):
    def test_date_is_bcd_with_the_month_in_the_high_nibble(self):
        self.assertEqual(read_date(bytes([0x99, 0x70, 0x25, 0x13, 0x08])),
                         {"year": 99, "month": 7, "day": 25, "hour": 13, "minute": 8})

    def test_slot_body_fields(self):
        slot = read_slot(bytes(msave()), bytes(esave()))
        self.assertEqual(slot["title"], "서장")
        self.assertEqual(slot["player"], {"money": 1234, "inputEnable": 0, "music": 0xFFFF, "city": 5, "chapter": 2})
        self.assertEqual(slot["game"], {"x": 11, "y": 13, "city": 7, "kind": 2, "index": 4})
        self.assertEqual(slot["returnPlace"], {"x": 8, "y": 15, "city": 3, "kind": 0, "index": 9})
        self.assertEqual(slot["actors"], [{"index": 3, "word": 0x205, "x": 12, "y": 9, "flags": 0x15, "facing": 2}])
        self.assertEqual(len(slot["people"]), 384)
        self.assertEqual(slot["people"][7], {"flags": 0x81, "role": 4, "context2": 1, "context3": 2, "personal": 90,
                                             "troops": 10000, "classID": 6, "level": 12, "experience": 33,
                                             "itemIDs": [1, 2, 3, 4, 5, 6, 7, 8]})
        self.assertEqual(slot["cityFlags"][2], 3)

    def test_script_context_fields(self):
        script = read_slot(bytes(msave()), bytes(esave()))["script"]
        self.assertEqual([script[key] for key in ("chapter", "member", "block", "groupBase")], [2, 1, 6, 20])
        self.assertEqual((script["cacheCity"], script["cacheMap"]), (7, 0x2004))
        self.assertEqual(script["cache"][1], {"person": 9, "x": 3, "y": 4, "flags": 1, "sourceFacing": 6})
        self.assertEqual((script["cursor"], script["busy"], script["music"]), (4282, 1, 11))
        self.assertEqual(script["setup"][0], {"person": 0x123, "x": 4, "y": 5, "flags": 1, "rawMode": 2,
                                              "parameter": 0x1234, "classID": 6, "level": 8})
        self.assertEqual(script["flags"][3], 0x80)
        self.assertEqual(script["sourceList"], [40, 41])
        self.assertEqual(script["objective"], "목표")
        self.assertEqual((script["turnLimit"], script["sourceByte2"]), (30, 1))

    def test_empty_objective_is_absent(self):
        data = esave()
        data[0x3D6] = 0
        self.assertIsNone(read_slot(bytes(msave()), bytes(data))["script"]["objective"])

    def test_sizes_are_checked(self):
        with self.assertRaises(ResourceError):
            read_slot(bytes(100), bytes(esave()))
        with self.assertRaises(ResourceError):
            read_slot(bytes(msave()), bytes(100))
        data = esave()
        data[0x3B5] = 33
        with self.assertRaises(ResourceError):
            read_slot(bytes(msave()), bytes(data))

    def test_folder_reports_used_refused_and_skips_unused_slots(self):
        with tempfile.TemporaryDirectory() as folder:
            game, output = Path(folder) / "game", Path(folder) / "out"
            game.mkdir()
            (game / "MSAVE0.R3S").write_bytes(bytes(msave()))
            (game / "ESAVE0.R3S").write_bytes(bytes(esave()))
            (game / "MSAVE1.R3S").write_bytes(bytes(MSAVE_SIZE))
            (game / "MSAVE2.R3S").write_bytes(bytes(msave()))
            before = sorted((path.name, path.read_bytes()) for path in game.iterdir())
            result = prepare(game, output)
            after = sorted((path.name, path.read_bytes()) for path in game.iterdir())
            stored = json.loads((output / "saves.json").read_text(encoding="utf-8"))
        self.assertEqual(before, after)
        self.assertEqual([row["slot"] for row in result["slots"]], [0])
        self.assertEqual(result["refused"], [{"slot": 2, "reason": "ESAVE is missing"}])
        self.assertEqual(stored["slots"][0]["source"]["msave"]["size"], MSAVE_SIZE)
        self.assertEqual(len(stored["slots"][0]["source"]["esave"]["sha256"]), 64)

    @unittest.skipUnless(os.environ.get("ORIGINAL_GAME_DIR"), "needs a caller-selected original directory")
    def test_original_slots_when_requested(self):
        with tempfile.TemporaryDirectory() as folder:
            result = prepare(Path(os.environ["ORIGINAL_GAME_DIR"]), Path(folder))
        for slot in result["slots"]:
            self.assertEqual(slot["player"]["chapter"], slot["script"]["chapter"])
            self.assertLessEqual(slot["player"]["money"], 10000)
            self.assertNotEqual(slot["game"]["kind"], 3)


if __name__ == "__main__":
    unittest.main()
