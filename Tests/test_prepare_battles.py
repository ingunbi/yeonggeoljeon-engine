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
from prepare_battles import battle_identity_map, map_names, map_record, minimap_image, placement_units, prepare, tile_colors, tile_atlas, prepare_atlases
from prepare_scene import SceneError
from resource_formats import IndexedImage, ResourceError


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
    def test_atlas_preserves_tile_rows_and_last_partial_row(self):
        tiles = [IndexedImage(16, 16, bytes([i]) * 256) for i in range(3)]
        atlas = tile_atlas(tiles, columns=2)
        self.assertEqual((atlas.width, atlas.height), (32, 32))
        self.assertEqual(atlas.pixels[0:32], bytes(16) + bytes([1]) * 16)
        self.assertEqual(atlas.pixels[16*32:17*32], bytes([2]) * 16 + bytes(16))
        self.assertEqual(atlas.pixels[31*32:32*32], bytes([2]) * 16 + bytes(16))

    def test_atlas_rejects_incomplete_or_unbounded_source_tiles(self):
        for tiles, columns in [([], 16), ([IndexedImage(8, 32, bytes(256))], 16),
                                ([IndexedImage(16, 16, bytes(256))] * 257, 16),
                                ([IndexedImage(16, 16, bytes(256))], 0)]:
            with self.assertRaises(ResourceError):
                tile_atlas(tiles, columns)
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(ResourceError):
                prepare_atlases(Path(directory), Path(directory) / "output")

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

    def test_map_names_keep_double_byte_characters_of_their_line(self):
        one, two = "\uac00\ub098".encode("cp949"), "\ub2e4".encode("cp949")
        text = one + b"\n" + two + b"1\r\n" + one + b" \r\n"
        suffix = " \uc804".encode("cp949")
        self.assertEqual(map_names(text, 3, suffix), ["\uac00\ub098 \uc804", "\ub2e4 \uc804", "\uac00\ub098 \uc804"])
        with self.assertRaises(ResourceError):
            map_names(one + b"\n", 3, suffix)
        with self.assertRaises(ResourceError):
            map_names(b"1\n", 1, suffix)

    def test_minimap_tile_keeps_four_most_frequent_colours_and_source_ties(self):
        pixels = bytes([1] * 100 + [2] * 80 + [3] * 60 + [4] * 16)
        self.assertEqual(tile_colors(IndexedImage(16, 16, pixels)), [1, 2, 3, 4])
        # The source scan compares with >=, so a tie keeps the higher colour
        # and absent colours resolve to fifteen.
        self.assertEqual(tile_colors(IndexedImage(16, 16, bytes([1] * 128 + [2] * 128))), [2, 1, 15, 15])

    def test_minimap_places_each_tile_as_two_by_two_pixels(self):
        record = {"pictureColumns": 2, "pictureRows": 1, "pictureTiles": [0, 1]}
        image = minimap_image(record, [[1, 2, 3, 4], [5, 6, 7, 8]])
        self.assertEqual((image.width, image.height), (4, 2))
        self.assertEqual(list(image.pixels), [1, 2, 5, 6, 3, 4, 7, 8])

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
            self.assertEqual(len(result["battles"]), 64)
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
            self.assertTrue((output / battle["minimap"]).is_file())
            self.assertTrue(battle["name"].endswith("\uc804\ud22c"))
            self.assertTrue(all(m["name"] and m["width"] <= 40 and m["height"] <= 24 for m in result["maps"]))
            self.assertTrue(all(u["hp"] is None for b in result["battles"] for u in b["units"]))
            self.assertEqual(json.loads((output / "battles.json").read_text())["format"], 1)


if __name__ == "__main__":
    unittest.main()
