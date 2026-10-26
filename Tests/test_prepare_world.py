# SPDX-License-Identifier: GPL-3.0-only
"""Synthetic exploration format boundaries and explicit original-data checks."""
from pathlib import Path
import os
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from prepare_world import DGROUP, chapter_mappings, prepare, world_layout
from resource_formats import ResourceError, settlement_map


class ExplorationFormatTests(unittest.TestCase):
    def test_world_walk_grid_is_half_picture_extent_and_msb_first(self):
        payload = bytes(8 * 4) + bytes([0x81])
        layout = world_layout(payload, 8, 4)
        self.assertEqual((layout["walkWidth"], layout["walkHeight"]), (4, 2))
        self.assertEqual(layout["walkBits"], [0x81])
        self.assertEqual(layout["walkBytes"], [128, 0, 0, 0, 0, 0, 0, 128])
        self.assertEqual(layout["walkGrid"], ["#...", "...#"])

    def test_world_picture_and_walk_spans_must_cover_the_payload(self):
        for payload, width, height in [(bytes(33), 7, 4), (bytes(32), 8, 4), (bytes(34), 8, 4)]:
            with self.assertRaises(ResourceError):
                world_layout(payload, width, height)

    def test_town_and_palace_share_one_settlement_format_owner(self):
        payload = bytes(640) + bytes([128]) + bytes(619) + bytes([1, 2, 3, 4])
        layout = settlement_map(payload)
        self.assertEqual(len(layout.background_tiles), 640)
        self.assertEqual(len(layout.walk_cells), 620)
        self.assertEqual(layout.walk_cells[0], 128)
        self.assertEqual(layout.objects, ((2, 3, 4),))
        with self.assertRaises(ResourceError):
            settlement_map(payload[:-1])

    def test_city_tables_preserve_unplaced_sentinel_instead_of_clamping_it(self):
        main = bytearray(DGROUP + 0x2FA6)
        main[DGROUP + 0x1360] = 1
        main[DGROUP + 0x2F06:DGROUP + 0x2F06 + 10] = bytes([8, 4] * 5)
        main[DGROUP + 0x136C:DGROUP + 0x136E] = bytes([255, 255])
        cities = bytearray(4 * 0x380)
        cities[:8] = b"Example\0"
        cities[22] = 123
        chapters, records, dimensions = chapter_mappings(bytes(main), bytes(cities))
        self.assertEqual(dimensions, {0: (8, 4)})
        self.assertEqual(len(chapters), 5)
        self.assertEqual(len(records), 5)
        self.assertIsNone(records[0]["worldX"])
        self.assertFalse(records[0]["worldPositionKnown"])
        self.assertEqual(records[0]["rawWorldX"], 255)
        self.assertEqual(records[0]["name"], "Example")
        self.assertEqual(records[0]["sourceCityType"],123)
        self.assertEqual(records[0]["source"]["cityTypeOffset"],22)

    def test_extraction_does_not_write_into_original_directory(self):
        with tempfile.TemporaryDirectory() as folder:
            with self.assertRaisesRegex(ResourceError, "outside"):
                prepare(Path(folder), Path(folder) / "output")


@unittest.skipUnless(os.environ.get("ORIGINAL_GAME_DIR"), "requires explicitly selected ORIGINAL_GAME_DIR")
class OriginalExplorationTests(unittest.TestCase):
    def test_all_towns_worlds_and_palette_actor_banks_export_without_original_mutation(self):
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder)
            result = prepare(Path(os.environ["ORIGINAL_GAME_DIR"]), output)
            self.assertEqual(len(result["maps"]), 16)
            self.assertEqual({m["key"] for m in result["maps"]},
                             {f"town:{i}" for i in range(12)} | {f"world:{i}" for i in range(4)})
            self.assertEqual(len(result["cities"]), 100)
            self.assertEqual(len(result["peopleBanks"]), 384)
            self.assertEqual(set(result["actorBanks"]["world"]), {str(member) for member in range(2, 8)})
            self.assertEqual(result["worldBankKey"], "person-field-2B")
            self.assertTrue(all(row["worldBank"] == row["worldRole"] + 2 for row in result["peopleBanks"]))
            self.assertEqual(len(result["actorBanks"]["town"]), 384)
            self.assertEqual(set(result["worldPlacementDirections"]), set(range(8)))
            original_main = (Path(os.environ["ORIGINAL_GAME_DIR"]) / "MAIN.EXE").read_bytes()
            self.assertEqual(result["worldPlacementDirections"],
                             list(struct.unpack_from("<8H", original_main, DGROUP + 0x2EE6)))
            self.assertTrue(result["source"]["originalHashesPreserved"])
            self.assertFalse((output / "resources.json").exists())
            for record in result["maps"]:
                data = (output / record["image"]).read_bytes()
                self.assertEqual(data[:8], b"\x89PNG\r\n\x1a\n")
                self.assertEqual(struct.unpack_from(">II", data, 16), (record["width"], record["height"]))
                self.assertEqual(len(record["walkBytes"]), record["walkWidth"] * record["walkHeight"])
            world = next(m for m in result["maps"] if m["key"] == "world:0")
            self.assertEqual((world["width"], world["height"], len(world["walkBits"])), (1536, 1536, 288))


if __name__ == "__main__":
    unittest.main()
