# SPDX-License-Identifier: GPL-3.0-only
from pathlib import Path
import os
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from prepare_retirement import prepare, quote_bank
from resource_formats import ResourceError


class RetirementTextTests(unittest.TestCase):
    def test_source_punctuation_conversion_and_reader_end_are_explicit(self):
        entries, trailer = quote_bank(b"\x05\xa1\xa4\xa1\xa1\xa1\xa5\xa1\xaa\x0a\xff\x0a")
        self.assertEqual(entries[0]["text"], ", .!")
        self.assertEqual(entries[0]["person"], 5)
        self.assertEqual(entries[0]["source"]["delimiter"], 10)
        self.assertEqual(trailer["sourceReaderEnd"], 11)
        self.assertEqual(trailer["ignoredTrailerLength"], 1)

    def test_duplicate_identity_order_and_empty_quote_remain_owned(self):
        entries, _ = quote_bank(b"\x01\x0a\x01\xa1\xa1\x0a\xff")
        self.assertEqual([(entry["person"], entry["text"]) for entry in entries], [(1, ""), (1, " ")])

    def test_truncated_pair_delimiter_and_missing_sentinel_are_failures(self):
        for data in (b"\0\xa1", b"\0\xa1\xa1", b"\0\x0a", b""):
            with self.assertRaises(ResourceError):
                quote_bank(data)


@unittest.skipUnless(os.environ.get("ORIGINAL_GAME_DIR"), "requires explicitly selected ORIGINAL_GAME_DIR")
class OriginalRetirementTextConformanceTests(unittest.TestCase):
    def test_original_producers_export_two_quote_banks_and_three_messages_without_mutating_inputs(self):
        with tempfile.TemporaryDirectory() as directory:
            result = prepare(Path(os.environ["ORIGINAL_GAME_DIR"]), Path(directory))
            self.assertEqual([bank["bank"] for bank in result["quoteBanks"]], [0, 1])
            self.assertEqual(sum(len(bank["entries"]) for bank in result["quoteBanks"]), 91)
            self.assertEqual(set(result["messages"]), {"leaderDefeat", "retreated", "died"})
            self.assertTrue(result["source"]["originalHashesPreserved"])
            self.assertFalse(result["source"]["originalProgramsExecuted"])
            self.assertTrue((Path(directory) / "retirement.json").is_file())


if __name__ == "__main__":
    unittest.main()
