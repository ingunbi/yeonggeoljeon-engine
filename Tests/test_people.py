# SPDX-License-Identifier: GPL-3.0-only
import os
from pathlib import Path
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from prepare_people import decode_person, prepare, PERSON_COUNT, STATE_BASE
from prepare_scene import SceneError


class PersonStateTests(unittest.TestCase):
    def test_constant_and_mutable_fields_have_distinct_ownership(self):
        constant = bytearray(21)
        constant[:6] = b"sample"
        constant[17:21] = bytes([250, 72, 31, 5])
        state = bytearray([128, 3, 7, 11, 255, 0, 0, 4, 6, 12] + [255]*8)
        struct.pack_into("<H", state, 5, 0x1234)
        result = decode_person(bytes(constant), bytes(state), 2)
        self.assertEqual(result["defenseScalar"],100)
        self.assertEqual(result["attackScalar"],72)
        self.assertEqual(result["rawTroops"],0x1234)
        self.assertEqual((result["classID"],result["level"]),(4,6))
        self.assertEqual(result["personalScalar"],100)
        self.assertEqual(result["source"]["stateRaw"],state.hex())
        self.assertEqual(result["sourceFlags"],128)
        self.assertNotIn("side",result)
        self.assertNotIn("runtimeSlot",result)

    def test_malformed_records_are_not_given_default_stats(self):
        for constant,state,person in [(bytes(20),bytes(18),0),(bytes(21),bytes(17),0),(bytes(21),bytes(18),384)]:
            with self.assertRaises(SceneError): decode_person(constant,state,person)

    def test_initial_state_directory_is_not_the_townsfolk_directory(self):
        self.assertEqual(STATE_BASE,0x3080)
        self.assertEqual(STATE_BASE+PERSON_COUNT*18,19328)


@unittest.skipUnless(os.environ.get("ORIGINAL_GAME_DIR"),"requires selected ORIGINAL_GAME_DIR")
class OriginalPersonStateTests(unittest.TestCase):
    def test_all_original_records_preserve_source_bytes_without_faction_guesses(self):
        game = Path(os.environ["ORIGINAL_GAME_DIR"])
        original = (game/"BAKDATA.R3").read_bytes()
        with tempfile.TemporaryDirectory() as tmp:
            result = prepare(game,Path(tmp))
            self.assertEqual(len(result["people"]),384)
            for person in result["people"]:
                start = person["source"]["stateOffset"]
                self.assertEqual(bytes.fromhex(person["source"]["stateRaw"]),original[start:start+18])
                self.assertEqual(person["rawTroops"],int.from_bytes(original[start+5:start+7],"little"))
                self.assertEqual(len(person["itemIDs"]),8)
            self.assertTrue(result["source"]["originalHashesPreserved"])
