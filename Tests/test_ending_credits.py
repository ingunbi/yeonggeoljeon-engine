# SPDX-License-Identifier: GPL-3.0-only
from pathlib import Path
import hashlib
import os
import sys
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from ending_credits import (InterleavedPlanarGeometry, common_credit_schedule, inspect_credit_source,
                            inspect_ending2_opening, transition_step)
from resource_formats import ResourceError


class EndingCreditCodecTests(unittest.TestCase):
    def test_pattern_selects_one_source_row_residue_and_preserves_other_rows(self):
        geometry = InterleavedPlanarGeometry(8, 4)
        before = bytes([0xA5] * 16)
        after = transition_step(before, bytes(16), geometry, 1, (0, 0, 0, 0))
        self.assertEqual(after, before[:4] + bytes(4) + before[8:])

    def test_word_mask_keeps_plane_identity_and_opaque_zero(self):
        geometry = InterleavedPlanarGeometry(8, 4)
        after = transition_step(bytes([0xFF] * 16), bytes(16), geometry, 0, (0x00FF, 0, 0, 0))
        self.assertEqual(after[:4], bytes([255, 0, 255, 0]))
        self.assertEqual(after[4:], bytes([255] * 12))

    def test_sixteen_patterns_cover_complete_four_row_blocks_only(self):
        geometry = InterleavedPlanarGeometry(16, 5)
        source = bytes(range(40)); image = bytes([255] * 40)
        synthetic_masks = (0x3F3F, 0xCFCF, 0xF3F3, 0xFCFC)
        for step in range(16):
            image = transition_step(image, source, geometry, step, synthetic_masks)
        self.assertEqual(image[:32], source[:32])
        self.assertEqual(image[32:], bytes([255] * 8))

    def test_geometry_span_and_pattern_are_checked_before_copying(self):
        with self.assertRaises(ResourceError):
            transition_step(bytes(16), bytes(15), InterleavedPlanarGeometry(8, 4), 0, (0, 0, 0, 0))
        with self.assertRaises(ResourceError):
            transition_step(bytes(16), bytes(16), InterleavedPlanarGeometry(8, 4), 16, (0, 0, 0, 0))
        with self.assertRaises(ResourceError):
            transition_step(bytes(16), bytes(16), InterleavedPlanarGeometry(9, 4), 0, (0, 0, 0, 0))

    def test_common_schedule_preserves_preload_morph_black_and_distinct_gates(self):
        result = common_credit_schedule(page_count=4, picture_count=1)
        events = result["events"]
        loads = [v for v in events if v["kind"] == "load-pending-picture"]
        self.assertEqual([v["member"] for v in loads], [56])
        patterns = [v for v in events if v["kind"] == "picture-pattern"]
        self.assertEqual([v["page"] for v in patterns], [1] * 16 + [3] * 16)
        self.assertEqual(result["finalCentisecondDeadline"], 5200)
        self.assertFalse(result["complete"])
        self.assertIn("await-audio-idle", [v["kind"] for v in events])
        self.assertEqual(events[-5]["kind"], "stop-music")
        self.assertEqual(events[-1]["kind"], "source-return")
        self.assertIn("await-final-input", [v["kind"] for v in events])

    def test_actual_loop_constants_keep_twenty_pages_and_nine_pictures(self):
        result = common_credit_schedule()
        self.assertEqual(result["pageCount"], 20)
        self.assertEqual(result["pictureCount"], 9)
        self.assertEqual(result["finalCentisecondDeadline"], 22800)
        self.assertEqual(len([v for v in result["events"] if v["kind"] == "load-pending-picture"]), 9)
        with self.assertRaises(ResourceError):
            common_credit_schedule(3, 1)


@unittest.skipUnless(os.environ.get("ORIGINAL_GAME_DIR"), "requires explicitly selected ORIGINAL_GAME_DIR")
class OriginalCreditSourceTests(unittest.TestCase):
    def test_profile_pointers_and_real_mask_payload_are_read_without_executing_or_mutating_original(self):
        from prepare_ending import EXAMINED_END, source_lines
        path = Path(os.environ["ORIGINAL_GAME_DIR"]) / "END.EXE"
        data = path.read_bytes()
        self.assertEqual(hashlib.sha256(data).hexdigest(), EXAMINED_END)
        credit = inspect_credit_source(data, source_lines)
        self.assertEqual(len(credit["pages"]), 20)
        self.assertEqual(len(credit["picturePalettes"]), 9)
        self.assertTrue(all(len(page["lines"]) == 17 for page in credit["pages"]))
        self.assertTrue(all((page["width"], page["height"]) == (160, 340) for page in credit["pages"]))
        geometry = InterleavedPlanarGeometry(8, 4)
        source = bytes(range(16)); destination = bytes([255] * 16)
        for step in range(16):
            destination = transition_step(destination, source, geometry, step, tuple(credit["transitionMasks"]))
        self.assertEqual(destination, source)
        opening = inspect_ending2_opening(data, source_lines)
        self.assertEqual([item["member"] for item in opening["portraits"]], list(range(2, 8)))
        self.assertEqual(opening["frontier"]["offset"], 0x7C22)
        self.assertEqual(path.read_bytes(), data)


if __name__ == "__main__":
    unittest.main()
