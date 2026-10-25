# SPDX-License-Identifier: GPL-3.0-only
import os
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/"tools"))
from prepare_movement import DATA_BASE, extract_profile, prepare, read_window
from resource_formats import ResourceError


class MovementWindowTests(unittest.TestCase):
    def test_source_window_bounds_preserve_literal_zero(self):
        self.assertEqual(read_window(b"\x00\x11",0,1,"synthetic"),b"\x00")
        with self.assertRaisesRegex(ResourceError,"outside"):
            read_window(b"\x00",1,1,"synthetic")

    def test_foreign_executable_does_not_produce_a_source_profile(self):
        with self.assertRaisesRegex(ResourceError,"examined"):
            extract_profile(b"synthetic")

    def test_output_cannot_overlap_original_directory(self):
        with tempfile.TemporaryDirectory() as temp:
            game=Path(temp)/"GAME";game.mkdir()
            with self.assertRaisesRegex(ResourceError,"outside"):
                prepare(game,game/"generated")


@unittest.skipUnless(os.environ.get("ORIGINAL_GAME_DIR"),"requires explicitly selected ORIGINAL_GAME_DIR")
class OriginalMovementTests(unittest.TestCase):
    def test_original_lookup_windows_and_raw255_are_preserved(self):
        game=Path(os.environ["ORIGINAL_GAME_DIR"])
        main=(game/"MAIN.EXE").read_bytes()
        result=extract_profile(main)
        self.assertEqual(len(result["classMovementTypes"]),19)
        self.assertEqual([len(row) for row in result["movementCosts"]],[256]*4)
        self.assertEqual(result["setupOrderModes"],list(main[DATA_BASE+0x4FE6:DATA_BASE+0x4FE6+512:2]))
        self.assertEqual([len(row) for row in result["strategyLevelRequirements"]],[19]*36)
        self.assertEqual(result["strategyMPCosts"],list(main[DATA_BASE+0x44EC:DATA_BASE+0x44EC+36]))
        self.assertEqual(result["strategyTerrainEligibility"],[list(main[DATA_BASE+0x47BC+4*i:DATA_BASE+0x47BC+4*i+4]) for i in range(3)])
        self.assertEqual(result["classMovementTypes"],list(main[DATA_BASE+0x3FFA:DATA_BASE+0x3FFA+19]))
        environment=result["scriptEnvironment"]
        self.assertEqual(environment["markerTerrain"],list(main[DATA_BASE+0x4FF4:DATA_BASE+0x4FF4+256]))
        self.assertEqual(environment["toggleTerrain"],list(main[DATA_BASE+0x4FF6:DATA_BASE+0x4FF6+256]))
        self.assertEqual(environment["remapFrom"],list(main[DATA_BASE+0x500C:DATA_BASE+0x500C+9]))
        self.assertEqual(environment["remapTo"],list(main[DATA_BASE+0x5015:DATA_BASE+0x5015+9]))
        self.assertEqual([len(row) for row in environment["pictureDeltas"]],[128,128])
        for row in range(4):
            self.assertEqual(result["movementCosts"][row][255],main[DATA_BASE+0x400E+20*row+255])
        with tempfile.TemporaryDirectory() as temp:
            exported=prepare(game,Path(temp))
            self.assertTrue(exported["source"]["originalHashesPreserved"])
            self.assertTrue((Path(temp)/"movement.json").is_file())


if __name__=="__main__":
    unittest.main()
