# SPDX-License-Identifier: GPL-3.0-only
"""Synthetic source-format boundaries; real original resources are opt-in."""
import json
import os
from pathlib import Path
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from prepare_battles import battle_identity_map, map_record, placement_units, prepare
from prepare_scene import SceneError
from resource_formats import ResourceError


def people_fixture():
    data = bytearray(0x1100 + 384 * 21)
    for person in range(384):
        name = ("P" + str(person)).encode("ascii")
        data[0x1100 + person * 21:0x1100 + person * 21 + len(name)] = name
    return bytes(data)


def roster(opcode, records, side=0):
    header, stride = (11, 9) if opcode == 3 else (1, 13)
    payload = bytearray(header + 30 * stride)
    payload[0] = side
    for ordinal in range(30):
        struct.pack_into("<H", payload, header + ordinal * stride, 0xFFFF)
    for ordinal, record in records:
        payload[header + ordinal * stride:header + (ordinal + 1) * stride] = record
    return bytes(payload)


class BattleExtractionTests(unittest.TestCase):
    def test_shared_source_sites_own_one_stable_identity(self):
        self.assertEqual(battle_identity_map(1, 2, 3, [500, 200, 500]),
                         {200: "1:2:3", 500: "1:2:3:1"})
        with self.assertRaises(SceneError):
            battle_identity_map(-1, 0, 0, [10])

    def test_source_picture_grid_and_battle_grid_remain_separate(self):
        payload = bytes([4, 2]) + bytes(range(8)) + bytes([0, 255])
        result = map_record(payload, 7, {"member": 7})
        self.assertEqual((result["width"], result["height"]), (2, 1))
        self.assertEqual(result["pictureTiles"], list(range(8)))
        self.assertEqual(result["tiles"], [0, 255])
        self.assertEqual(result["source"]["terrainDecodedOffset"], 10)

    def test_malformed_dimensions_and_partial_terrain_are_rejected(self):
        for payload in (b"", bytes([3, 2]) + bytes(8), bytes([4, 2]) + bytes(9)):
            with self.assertRaises(ResourceError):
                map_record(payload, 0, {})

    def test_source_eligibility_is_not_coerced_to_inactive(self):
        ordinary = struct.pack("<H7B", 1, 2, 3, 1, 0, 0, 3, 0)
        conditional = struct.pack("<H7B", 2, 4, 3, 1, 1, 7, 3, 0)
        known, unresolved, source = placement_units(roster(3, [(0, ordinary), (1, conditional)]),
                                                    3, {"offset": 100, "opcode": 3}, people_fixture())
        self.assertEqual(len(known), 1)
        self.assertEqual(known[0]["side"], 0)
        self.assertTrue(known[0]["initiallyActive"])
        self.assertIsNone(unresolved[0]["initiallyActive"])
        self.assertEqual(unresolved[0]["source"]["eligibility"]["flag"], 7)
        self.assertEqual(known[0]["source"]["sourcePlacementSideBit"], 0)
        self.assertEqual(source["recordStride"], 9)

    def test_enemy_identity_is_not_person_or_runtime_slot(self):
        record = struct.pack("<H11B", 100, 3, 4, 0, 0, 1, 0, 2, 0, 0, 5, 1)
        known, conditional, _ = placement_units(roster(0x22, [(2, record)]), 0x22,
                                                {"offset": 200, "opcode": 34}, people_fixture())
        self.assertEqual(conditional, [])
        self.assertEqual((known[0]["id"], known[0]["person"], known[0]["side"]), (32, 100, 1))
        self.assertIsNone(known[0]["source"]["runtimeSlot"])
        self.assertEqual(known[0]["source"]["slot"], 2)
        self.assertIsNone(known[0]["attack"])

    def test_withheld_placement_is_not_deleted(self):
        record = struct.pack("<H7B", 3, 2, 2, 1, 0, 0, 0, 1)
        known, _, _ = placement_units(roster(3, [(0, record)]), 3,
                                      {"offset": 100, "opcode": 3}, people_fixture())
        self.assertEqual(len(known), 1)
        self.assertFalse(known[0]["initiallyActive"])

    def test_dynamic_person_placeholder_stays_unknown(self):
        record = struct.pack("<H7B", 0x400, 2, 2, 1, 0, 0, 0, 0)
        known, conditional, _ = placement_units(roster(3, [(0, record)]), 3,
                                                {"offset": 100, "opcode": 3}, people_fixture())
        self.assertEqual(known, [])
        self.assertIsNone(conditional[0]["person"])
        self.assertEqual(conditional[0]["source"]["rawPerson"], 0x400)

    def test_partial_roster_and_output_inside_original_fail(self):
        with self.assertRaises(SceneError):
            placement_units(bytes(15), 3, {"offset": 0}, people_fixture())
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(ResourceError):
                prepare(Path(directory), Path(directory) / "output")


@unittest.skipUnless(os.environ.get("ORIGINAL_GAME_DIR"), "requires explicitly selected ORIGINAL_GAME_DIR")
class OriginalBattleExtractionTests(unittest.TestCase):
    def test_original_maps_roster_identities_and_hash_preservation(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            result = prepare(Path(os.environ["ORIGINAL_GAME_DIR"]), output)
            self.assertEqual(len(result["maps"]), 58)
            self.assertEqual(len(result["battles"]), 60)
            self.assertEqual(result["provenance"]["framingFailures"], [])
            self.assertTrue(result["provenance"]["originalHashesPreserved"])
            battle = next(b for b in result["battles"] if b["id"] == "0:0:5")
            self.assertEqual((battle["width"], battle["height"]), (28, 16))
            self.assertEqual([(u["person"], u["side"]) for u in battle["units"]],
                             [(0, 0), (1, 0), (2, 0), (5, 1), (20, 1), (21, 1), (27, 1), (256, 1), (257, 1), (258, 1)])
            self.assertEqual([u["person"] for u in battle["conditionalUnits"]], [12, 15])
            self.assertFalse(battle["originalRosterComplete"])
            self.assertEqual(len(battle["tiles"]), 28 * 16)
            self.assertTrue((output / battle["image"]).is_file())
            self.assertTrue(all(u["hp"] is None for b in result["battles"] for u in b["units"]))
            self.assertEqual(json.loads((output / "battles.json").read_text())["format"], 1)


if __name__ == "__main__":
    unittest.main()
