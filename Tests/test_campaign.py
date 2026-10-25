# SPDX-License-Identifier: GPL-3.0-only
"""Synthetic campaign/framing regressions and explicitly selected real inputs."""
from pathlib import Path
import json
import os
import struct
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from prepare_scene import SceneError, extract_record
from prepare_campaign import prepare_campaign, preview_scene, record_id, transition
from scenario_format import (Instruction, instructions, read_instruction,
                             record_directory, source_operand_lengths, text_sections)


def table_fixture():
    result = bytearray(62)
    for opcode, length in [(0, 2), (1, 5), (3, 25), (9, 2), (10, 5), (0x1D, 2),
                           (0x22, 135), (0x2E, 5)]:
        result[opcode] = length
    return bytes(result)


class ScenarioFramingTests(unittest.TestCase):
    def test_fixed_source_frame_is_not_truncated_to_skip_low_byte(self):
        lengths = table_fixture()
        for opcode, size in [(3, 282), (0x22, 392), (0x1D, 5)]:
            payload = bytes([opcode]) + bytes(size - 1) + b"\xff"
            decoded = list(instructions(payload, 0, len(payload), lengths))
            self.assertEqual([(item.opcode, item.end) for item in decoded], [(opcode, size), (255, size + 1)])

    def test_variable_lists_keep_embedded_opcode_bytes_as_operands(self):
        lengths = table_fixture()
        data = b"\x20\x82\xff\x09\x32\x03\x00\x01\xff\x21\x02\x02\xff\x09\x01\x03\xff"
        decoded = list(instructions(data, 0, len(data), lengths))
        self.assertEqual([item.opcode for item in decoded], [0x20, 0x32, 0x21, 0xFF])
        self.assertEqual([item.end - item.offset for item in decoded], [4, 5, 7, 1])

    def test_truncated_variable_list_does_not_scan_a_later_fake_boundary(self):
        for data in [b"\x20\x04\xff", b"\x32\x05\xff", b"\x21\x01\x05\xff"]:
            with self.assertRaises(SceneError):
                list(instructions(data, 0, len(data), table_fixture()))

    def test_unknown_opcode_and_missing_ff_remain_distinct_failures(self):
        with self.assertRaisesRegex(SceneError, "opcode"):
            list(instructions(b"\x7f\xff", 0, 2, table_fixture()))
        with self.assertRaisesRegex(SceneError, "without.*FF"):
            list(instructions(b"\x05", 0, 1, table_fixture()))

    def test_record_entry_points_can_share_tail_without_owning_next_entry(self):
        # Record zero begins at30 and falls through record one's entry at31.
        # The descriptor boundary must not turn that legal shared tail into EOF.
        first = bytes(8) + struct.pack("<H", 30)
        second = bytes([3, 1]) + bytes(6) + struct.pack("<H", 31)
        data = first + second + b"\xff" * 10 + b"\x05\x05\xff"
        records = record_directory(data, 0, len(data), "synthetic", 2)
        self.assertEqual(records[0]["nextEntryPoint"], 31)
        self.assertEqual(records[0]["bodyEnd"], len(data))
        self.assertEqual([i.opcode for i in instructions(data, records[0]["bodyStart"], records[0]["bodyEnd"], table_fixture())], [5, 5, 255])
        self.assertEqual(records[1]["source"]["member"], 2)

    def test_invalid_record_directory_is_not_a_foreign_or_empty_block(self):
        for data in [bytes(10), bytes(8) + struct.pack("<H", 2) + b"\xff" * 10 + b"\xff",
                     b"\xff" * 10]:
            with self.assertRaises(SceneError):
                record_directory(data, 0, len(data), "synthetic", 0)

    def test_text_wrap_preserves_raw_directory_and_derived_file_span(self):
        data = bytearray(70010)
        struct.pack_into("<3H", data, 0, 6, 60000, 0x1029)
        bounds, fact = text_sections(bytes(data), 3, "synthetic")
        self.assertEqual(bounds, [(6, 60000), (60000, 0x11029), (0x11029, 70010)])
        self.assertEqual(fact["rawDirectory"], [6, 60000, 0x1029])
        self.assertEqual(fact["rollovers"], 1)
        self.assertIn("explicit base exceptions", fact["status"])

    def test_ambiguous_or_outside_text_wrap_is_rejected(self):
        for data, count in [(b"\x06\x00x", 3), (struct.pack("<2H", 4, 2) + bytes(12), 2),
                            (struct.pack("<H", 2) + bytes(65540), 1)]:
            with self.assertRaises(SceneError):
                text_sections(data, count, "synthetic")

    def test_source_resource_identity_is_not_replaced_by_default_chapter_zero(self):
        code = b"\x09\x01\x20\x05\xff"
        commands, _, boundary = extract_record(code, 0, len(code), b"x", (0, 1), b"",
            allowed_maps={0x2001}, script_resource="SNR4D.R3", script_member=2, text_resource="SNR4M.R3")
        self.assertEqual(boundary["status"], "bounded-record-complete")
        self.assertEqual(commands[0]["source"]["resource"], "SNR4D.R3")
        self.assertEqual(commands[0]["source"]["member"], 2)

    def test_unsupported_map_is_not_given_a_native_palace_preview(self):
        code = b"\x09\x00\x30\xff"
        scene, boundary = preview_scene(code, {"bodyStart": 0, "bodyEnd": len(code)}, b"x", (0, 1), b"",
                                        "synthetic", "SNR2D.R3", "SNR2M.R3", 1)
        self.assertIsNone(scene)
        self.assertEqual(boundary["status"], "unsupported-boundary")

    def test_battle_selection_and_resume_are_not_conflated(self):
        selected = transition(Instruction(9, 10, 13, b"\x04\x30"), 1, 2, 3)
        resumed = transition(Instruction(0x11, 20, 23, b"\x00\x10"), 1, 2, 3)
        self.assertEqual(selected["battleID"], "1:2:3")
        self.assertEqual(selected["kind"], "battle-map-selection")
        self.assertEqual(resumed["kind"], "map-resume")
        self.assertNotIn("battleID", resumed)
        self.assertEqual(record_id(1, 2, 3, 4), "c1:m2:b3:r4")

    def test_battle_variant_identity_comes_from_the_shared_battle_owner(self):
        selected = transition(Instruction(9, 99, 102, b"\x04\x30"), 1, 2, 3,
                              {88: "1:2:3", 99: "1:2:3:1"})
        self.assertEqual(selected["battleID"], "1:2:3:1")


@unittest.skipUnless(os.environ.get("ORIGINAL_GAME_DIR"), "requires explicitly selected ORIGINAL_GAME_DIR")
class OriginalCampaignTests(unittest.TestCase):
    def test_all_source_directories_are_catalogued_without_equating_preview_with_full_campaign(self):
        result = prepare_campaign(Path(os.environ["ORIGINAL_GAME_DIR"]))
        coverage = result["coverage"]
        self.assertEqual((coverage["chapters"], coverage["members"], coverage["blocks"], coverage["records"]), (5, 18, 225, 2144))
        self.assertEqual(coverage["framedCompleteRecords"], 2144)
        self.assertEqual(coverage["framingFailures"], 0)
        self.assertTrue(result["provenance"]["originalHashesPreserved"])
        self.assertLess(coverage["supportedPreviewRecords"], coverage["records"])
        self.assertEqual(len({record["id"] for record in result["records"]}), 2144)
        selected = next(record for record in result["records"] if record["id"] == "c0:m0:b1:r0")
        self.assertEqual(selected["executionStatus"], "supported-record")
        self.assertEqual(len(selected["scene"]["commands"]), 40)
        self.assertEqual(result["chapters"][3]["textDirectory"]["rollovers"], 1)
        self.assertIn("not a playable full campaign", " ".join(result["limitations"]))


if __name__ == "__main__":
    unittest.main()
