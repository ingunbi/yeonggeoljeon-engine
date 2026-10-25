# SPDX-License-Identifier: GPL-3.0-only
from pathlib import Path
import os
import sys
import tempfile
import unittest

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/"tools"))
from prepare_combat import extract_tables, prepare
from resource_formats import ResourceError


class CombatBoundaryTests(unittest.TestCase):
    def test_unexamined_code_is_not_interpreted_as_original_rules(self):
        with self.assertRaisesRegex(ResourceError,"examined"):
            extract_tables(bytes(254255),bytes(19328))

    def test_output_cannot_modify_original_input(self):
        with tempfile.TemporaryDirectory() as directory:
            game=Path(directory)
            with self.assertRaisesRegex(ResourceError,"outside"):
                prepare(game,game/"nested")


@unittest.skipUnless(os.environ.get("ORIGINAL_GAME_DIR"),"requires explicitly selected ORIGINAL_GAME_DIR")
class OriginalCombatTableTests(unittest.TestCase):
    def test_original_tables_and_item_effect_offsets_are_retained_locally(self):
        game=Path(os.environ["ORIGINAL_GAME_DIR"])
        with tempfile.TemporaryDirectory() as directory:
            value=prepare(game,Path(directory))
            self.assertEqual(value["format"],1)
            self.assertEqual(len(value["attackBase"]),19)
            self.assertEqual(len(value["defenseBase"]),19)
            self.assertEqual(len(value["physicalSubtypeByClass"]),19)
            self.assertEqual(len(value["terrainDefensePercent"]),256)
            self.assertEqual(len(value["strategyEnvironmentLookup"]),256)
            self.assertEqual(len(value["items"]),64)
            self.assertTrue(value["source"]["originalFilesPreserved"])
            bak=(game/"BAKDATA.R3").read_bytes()
            for item in value["items"]:
                at=0xD00+item["id"]*16
                self.assertEqual(item["value"],bak[at+14])
                self.assertEqual(item["category"],min(15,bak[at+15]))
            self.assertTrue((Path(directory)/"combat.json").is_file())


if __name__=="__main__":unittest.main()
