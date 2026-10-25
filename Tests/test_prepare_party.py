# SPDX-License-Identifier: GPL-3.0-only
from pathlib import Path
import os
import sys
import tempfile
import unittest

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/"tools"))
from prepare_party import extract, prepare, DGROUP, CLASS_RANKS, PERSON_ZERO_DEFAULT
from resource_formats import ResourceError


class PartyImportBoundaryTests(unittest.TestCase):
    def test_unexamined_main_is_rejected(self):
        with self.assertRaisesRegex(ResourceError,"examined"):
            extract(bytes(254255))

    def test_original_directory_cannot_be_an_output(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(ResourceError,"outside"):
                prepare(Path(directory),Path(directory)/"derived")


@unittest.skipUnless(os.environ.get("ORIGINAL_GAME_DIR"),"requires explicitly selected ORIGINAL_GAME_DIR")
class OriginalPartyImportTests(unittest.TestCase):
    def test_original_table_windows_are_retained_only_in_local_output(self):
        game=Path(os.environ["ORIGINAL_GAME_DIR"])
        with tempfile.TemporaryDirectory() as directory:
            value=prepare(game,Path(directory))
            main=(game/"MAIN.EXE").read_bytes()
            self.assertEqual(value["classSortRanks"],list(main[DGROUP+CLASS_RANKS:DGROUP+CLASS_RANKS+256]))
            self.assertEqual(value["personZeroDefaultWord"],int.from_bytes(main[DGROUP+PERSON_ZERO_DEFAULT:DGROUP+PERSON_ZERO_DEFAULT+2],"little"))
            self.assertTrue(value["source"]["originalFilesPreserved"])
            self.assertTrue((Path(directory)/"party.json").is_file())


if __name__=="__main__":unittest.main()
