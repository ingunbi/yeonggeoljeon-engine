# SPDX-License-Identifier: GPL-3.0-only
"""Typed campaign producer tests use only synthetic source bytes."""
from pathlib import Path
import os
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import struct

from campaign_vm_format import (MAIN_DATA_SEGMENT, RETRY_PROMPT_CALL, RETRY_PROMPT_POINTER, compile_instructions,
                                framework_prompts, phase_groups, source_skip_target, stock_caption_index)
from prepare_campaign import prepare_campaign
from prepare_scene import SceneError
from scenario_format import Instruction, instructions


def lengths():
    result = bytearray(62)
    for opcode, count in [(0, 2), (0x0F, 1), (0x14, 2), (0x15, 2), (0x1A, 2), (0x1D, 2), (0x25, 2), (0x38, 1)]:
        result[opcode] = count
    return bytes(result)


def compile_synthetic(code, text=b"", bounds=None):
    frames = list(instructions(code, 0, len(code), lengths()))
    return compile_instructions(code, frames, text, bounds or (0, len(text)), b"", b"", lengths(),
                                resource="synthetic", text_resource="synthetic-text", member=0,
                                battle_ids={})


def synthetic_main(text: bytes, pointer: int = RETRY_PROMPT_POINTER, mode: int = 2) -> bytes:
    data = bytearray(MAIN_DATA_SEGMENT + 0x3000)
    # push ds; push pointer; push mode; far call CF5:3C5E
    call = bytes([0x1E, 0x68]) + struct.pack("<H", pointer) + bytes([0x6A, mode, 0x9A]) + struct.pack("<HH", 0x3C5E, 0x0CF5)
    data[RETRY_PROMPT_CALL:RETRY_PROMPT_CALL + len(call)] = call
    at = MAIN_DATA_SEGMENT + RETRY_PROMPT_POINTER
    data[at:at + len(text) + 1] = text + b"\0"
    return bytes(data)


class CampaignVMFormatTests(unittest.TestCase):
    def test_retry_prompt_comes_from_the_checked_main_selector_call(self):
        prompt = framework_prompts(synthetic_main("합성 재시작?".encode("cp949")))["retryPrompt"]
        self.assertEqual(prompt["text"], "합성 재시작?")
        self.assertEqual((prompt["yesResult"], prompt["noResult"], prompt["presentationOrder"]), (1, 0, [1, 0]))
        self.assertEqual(prompt["textSource"]["offset"], MAIN_DATA_SEGMENT + RETRY_PROMPT_POINTER)
        self.assertEqual(prompt["callSource"]["offset"], RETRY_PROMPT_CALL)

    def test_retry_prompt_rejects_an_unexamined_call_or_empty_text(self):
        with self.assertRaisesRegex(SceneError, "retry selector call"):
            framework_prompts(synthetic_main(b"x", pointer=RETRY_PROMPT_POINTER + 2))
        with self.assertRaisesRegex(SceneError, "retry selector call"):
            framework_prompts(synthetic_main(b"x", mode=1))
        with self.assertRaisesRegex(SceneError, "empty"):
            framework_prompts(synthetic_main(b""))

    def test_stock_caption_selector_is_last_source_character_not_decimal_number(self):
        self.assertEqual(stock_caption_index("11"), 1)
        self.assertEqual(stock_caption_index("::"), 10)
        self.assertEqual(stock_caption_index("AA"), 17)
        self.assertEqual(stock_caption_index("x2y8z"), 8)
        self.assertEqual(stock_caption_index("unmatched"), 0)

    def test_group_high_bit_applies_to_first_descriptor_only(self):
        descriptors = [{"conditionBytes": [0, marker, 0, 0, 0, 0, 0, 0]}
                       for marker in [0x83, 3, 3, 0x83, 3, 4]]
        groups = phase_groups(descriptors)
        self.assertEqual(groups[0], {"base": 0, "count": 3, "repeating": True})
        self.assertEqual(groups[3], {"base": 3, "count": 2, "repeating": True})
        self.assertEqual(groups[5], {"base": 5, "count": 1, "repeating": False})

    def test_flag_effect_retains_independent_selector_bytes(self):
        effect = compile_synthetic(bytes([0x14, 7, 1, 0xFF]))[0]
        self.assertEqual(effect["kind"], "flag")
        self.assertEqual(effect["arguments"], [7, 1])
        self.assertEqual(effect["source"]["offset"], 0)

    def test_opcode20_is_city_flag_operation_not_item_inventory(self):
        effect = compile_synthetic(bytes([0x20, 0x82, 2, 4, 0xFF]))[0]
        self.assertEqual(effect["kind"], "city-availability")
        self.assertEqual(effect["arguments"], [1, 2, 4])

    def test_opcode1d_produces_return_context_without_placing_player(self):
        effect = compile_synthetic(bytes([0x1D, 4, 0x10, 7, 9, 0xFF]))[0]
        self.assertEqual(effect["kind"], "return-context")
        self.assertEqual(effect["arguments"], [0x1004, 7, 9])
        self.assertEqual(effect["commands"], [])

    def test_opcode1a_normalizes_literal_zero_placement_without_inventing_an_entry_lookup(self):
        effects = compile_synthetic(bytes([0x1A, 0x34, 1, 0xFF]))
        effect = effects[0]
        self.assertEqual(effect["kind"], "commands")
        self.assertEqual(effect["arguments"], [0x134])
        self.assertEqual(len(effect["commands"]), 1)
        command = effect["commands"][0]
        self.assertEqual({key: command[key] for key in ("op", "person", "x", "y", "sourcePlacementFacing")},
                         {"op": "place", "person": 0x134, "x": 0, "y": 0, "sourcePlacementFacing": 0})
        self.assertNotIn("facing", command)
        self.assertEqual(command["source"], effect["source"])
        self.assertEqual(effects[1]["offset"], 3)
        self.assertEqual(effects[1]["kind"], "end-record")

    def test_resume_mode_comes_from_immediate_source_lookahead_and_exit_status_is_explicit(self):
        table = bytearray(lengths())
        table[0x11] = 2
        code = b"\x11\x00\x10\x29\xff"
        effects = compile_instructions(code, list(instructions(code, 0, len(code), bytes(table))),
            b"", (0, 0), b"", b"", bytes(table), resource="synthetic", text_resource="synthetic", member=0, battle_ids={})
        self.assertEqual(effects[0]["arguments"], [4096, 1])
        self.assertEqual(effects[1]["arguments"], [3])
        self.assertEqual(effects[1]["interpreterStatus"], 7)
        code = b"\x11\x00\x10\xff"
        effect = compile_instructions(code, list(instructions(code, 0, len(code), bytes(table))),
            b"", (0, 0), b"", b"", bytes(table), resource="synthetic", text_resource="synthetic", member=0, battle_ids={})[0]
        self.assertEqual(effect["arguments"], [4096, 0])

    def test_execution_framing_does_not_replace_original_skip_walker(self):
        data = bytes([0x1D, 1, 0, 4, 5, 0xFF])
        self.assertEqual(list(instructions(data, 0, len(data), lengths()))[0].end, 5)
        self.assertEqual(source_skip_target(data, 0, 1, len(data), lengths()), 3)

    def test_skipped_conditional_uses_source_skip_count_not_execution_count(self):
        # Execution shape: skipCount1, positiveCount1, flag9, negativeCount0.
        # Original skip path instead consumes skipCount1 byte, skips one byte,
        # reads the flag9 as its second length, and skips nine further bytes.
        data = bytes([0x21, 1, 1, 9, 0]) + bytes(9) + b"\xff"
        self.assertEqual(source_skip_target(data, 0, 1, len(data), lengths()), 13)

    def test_skip_target_inside_execution_operand_is_explicit_unsupported(self):
        # The condition would skip a camera instruction through the original
        # narrower 1D skip-table length, landing inside camera operands.
        code = bytes([0x21, 1, 0, 0, 0x1D, 1, 0, 4, 5, 0xFF])
        effects = compile_synthetic(code)
        self.assertIn("does not coincide", effects[0]["skipFailure"])
        self.assertNotIn("skipTarget", effects[0])

    def test_source_menu_options_are_decoded_once_with_crlf_pairing(self):
        code = bytes([0x25, 0, 0, 0xFF])
        menu = compile_synthetic(code, b"A\r\nB\n\0")[0]
        self.assertEqual(menu["kind"], "choice-record")
        self.assertEqual(menu["options"], ["A", "B"])
        self.assertEqual(menu["textSource"]["resource"], "synthetic-text")

    def test_choice_prompt_dialogue_is_deferred_without_duplicate_speech(self):
        from prepare_scene import PERSON_BASE
        people = bytes(PERSON_BASE) + b"Test\0\0"
        code = bytes([0, 0, 0, 0x15, 0, 0, 0xFF])
        text = b"\0\0Prompt?\0\xff\xff"
        effects = compile_instructions(code, list(instructions(code, 0, len(code), lengths())),
            text, (0, len(text)), people, b"", lengths(), resource="synthetic",
            text_resource="synthetic-text", member=0, battle_ids={})
        self.assertEqual(effects[0]["kind"], "deferred-dialogue")
        self.assertEqual(effects[1]["kind"], "choice-skip")
        self.assertEqual(effects[1]["commands"][0]["text"], "Prompt?")
        self.assertEqual(effects[1]["options"], ["No", "Yes"])
        self.assertEqual(effects[1]["presentationOrder"], [1, 0])

    def test_unimplemented_host_handler_is_not_a_fabricated_state_effect(self):
        effect = compile_synthetic(bytes([0x1F, 0xFF]))[0]
        self.assertEqual(effect["kind"], "town-interaction")
        self.assertEqual(effect["opcode"], 0x1F)
        self.assertEqual(effect["commands"], [])

    def test_source_skip_bounds_do_not_accept_truncated_variable_tables(self):
        with self.assertRaises(SceneError):
            source_skip_target(b"\x32\x08x", 0, 1, 3, lengths())


@unittest.skipUnless(os.environ.get("ORIGINAL_GAME_DIR"), "requires explicitly selected ORIGINAL_GAME_DIR")
class OriginalTypedProgramTests(unittest.TestCase):
    def test_complete_source_population_has_typed_phase_and_instruction_ownership(self):
        result = prepare_campaign(Path(os.environ["ORIGINAL_GAME_DIR"]))
        vm = result["vmProgram"]
        self.assertEqual(len(vm["records"]), result["coverage"]["records"])
        self.assertEqual(vm["initialState"]["flags"], [0] * 32)
        self.assertEqual(vm["records"][0]["group"], {"base": 0, "count": 1, "repeating": False})
        self.assertTrue(all(record["instructions"][-1]["kind"] == "end-record" for record in vm["records"]))
        self.assertTrue(any(instruction["kind"] == "battle-action" for record in vm["records"] for instruction in record["instructions"]))
        self.assertTrue(result["provenance"]["originalHashesPreserved"])


if __name__ == "__main__":
    unittest.main()
