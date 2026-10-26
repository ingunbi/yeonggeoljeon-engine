# SPDX-License-Identifier: GPL-3.0-only
"""Typed campaign producer tests use only synthetic source bytes."""
from pathlib import Path
import os
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import struct

from campaign_vm_format import (MAIN_DATA_PARAGRAPH, MAIN_DATA_SEGMENT, RETRY_PROMPT_CALL, RETRY_PROMPT_POINTER,
                                SAVE_DECLINE_CALL, SAVE_DECLINE_POINTER, SAVE_PROMPT_CALL, SAVE_PROMPT_POINTER,
                                TITLE_MENU_COUNT_AT, TITLE_MENU_TABLE, TITLE_MENU_TABLE_AT, BATTLE_MENU_COUNT_AT,
                                BATTLE_MENU_TABLE, BATTLE_MENU_TABLE_AT, RETREAT_CONFIRM_CALL, RETREAT_CONFIRM_POINTER_VAR,
                                RETREAT_REFUSED_CALL, RETREAT_REFUSED_POINTER, QUIT_CONFIRM_CALL, QUIT_CONFIRM_POINTER,
                                RETREAT_RESULT_AT, QUIT_RESULT_AT, battle_menu, compile_instructions,
                                framework_prompts, phase_groups, selector_text, source_skip_target, stock_caption_index,
                                title_menu)
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


def put_selector(data: bytearray, call_at: int, pointer: int, text: bytes, mode: int = 2) -> None:
    # push ds; push pointer; push mode; far call CF5:3C5E
    call = bytes([0x1E, 0x68]) + struct.pack("<H", pointer) + bytes([0x6A, mode, 0x9A]) + struct.pack("<HH", 0x3C5E, 0x0CF5)
    data[call_at:call_at + len(call)] = call
    at = MAIN_DATA_SEGMENT + pointer
    data[at:at + len(text) + 1] = text + b"\0"


def synthetic_main(text: bytes, pointer: int = RETRY_PROMPT_POINTER, mode: int = 2) -> bytes:
    data = bytearray(MAIN_DATA_SEGMENT + 0x4000)
    put_selector(data, RETRY_PROMPT_CALL, pointer, text, mode)
    put_selector(data, SAVE_PROMPT_CALL, SAVE_PROMPT_POINTER, "합성 저장?".encode("cp949"))
    put_selector(data, SAVE_DECLINE_CALL, SAVE_DECLINE_POINTER, "합성 취소?".encode("cp949"))
    data[TITLE_MENU_COUNT_AT:TITLE_MENU_COUNT_AT + 2] = bytes([0x6A, 4])
    data[TITLE_MENU_TABLE_AT:TITLE_MENU_TABLE_AT + 4] = bytes([0x8D, 0x1E]) + struct.pack("<H", TITLE_MENU_TABLE)
    for index in range(4):
        offset = 0x2C00 + index * 0x10
        struct.pack_into("<HH", data, MAIN_DATA_SEGMENT + TITLE_MENU_TABLE + index * 4, offset, MAIN_DATA_PARAGRAPH)
        label = f"item{index}".encode("ascii")
        data[MAIN_DATA_SEGMENT + offset:MAIN_DATA_SEGMENT + offset + len(label) + 1] = label + b"\0"
    data[BATTLE_MENU_COUNT_AT:BATTLE_MENU_COUNT_AT + 2] = bytes([0x6A, 9])
    data[BATTLE_MENU_TABLE_AT:BATTLE_MENU_TABLE_AT + 4] = bytes([0x8D, 0x1E]) + struct.pack("<H", BATTLE_MENU_TABLE)
    for item, label in ((1, b"retreat"), (8, b"quit")):
        offset = 0x2C80 + item * 0x10
        struct.pack_into("<HH", data, MAIN_DATA_SEGMENT + BATTLE_MENU_TABLE + item * 4, offset, MAIN_DATA_PARAGRAPH)
        data[MAIN_DATA_SEGMENT + offset:MAIN_DATA_SEGMENT + offset + len(label) + 1] = label + b"\0"
    call = bytes([0x1E, 0xFF, 0x36]) + struct.pack("<H", RETREAT_CONFIRM_POINTER_VAR) + bytes([0x6A, 2, 0x9A]) + struct.pack("<HH", 0x3C5E, 0x0CF5)
    data[RETREAT_CONFIRM_CALL:RETREAT_CONFIRM_CALL + 12] = call
    struct.pack_into("<H", data, MAIN_DATA_SEGMENT + RETREAT_CONFIRM_POINTER_VAR, 0x2D80)
    data[MAIN_DATA_SEGMENT + 0x2D80:MAIN_DATA_SEGMENT + 0x2D88] = b"confirm\0"
    put_selector(data, RETREAT_REFUSED_CALL, RETREAT_REFUSED_POINTER, b"refused", mode=1)
    put_selector(data, QUIT_CONFIRM_CALL, QUIT_CONFIRM_POINTER, b"quit?")
    for at, value in ((RETREAT_RESULT_AT, 1), (QUIT_RESULT_AT, 4)):
        data[at:at + 7] = bytes([0x8B, 0x5E, 0x06, 0xC6, 0x47, 0x01, value])
    return bytes(data)


class CampaignVMFormatTests(unittest.TestCase):
    def test_framework_texts_come_from_checked_main_call_sites(self):
        prompts = framework_prompts(synthetic_main("합성 재시작?".encode("cp949")))
        prompt = prompts["retryPrompt"]
        self.assertEqual(prompt["text"], "합성 재시작?")
        self.assertEqual((prompt["yesResult"], prompt["noResult"], prompt["presentationOrder"]), (1, 0, [1, 0]))
        self.assertEqual(prompt["textSource"]["offset"], MAIN_DATA_SEGMENT + RETRY_PROMPT_POINTER)
        self.assertEqual(prompt["callSource"]["offset"], RETRY_PROMPT_CALL)
        self.assertEqual(prompts["savePrompt"]["text"], "합성 저장?")
        self.assertEqual(prompts["saveDeclinePrompt"]["callSource"]["offset"], SAVE_DECLINE_CALL)
        self.assertEqual([(i["index"], i["action"], i["text"]) for i in prompts["titleMenu"]],
                         [(0, "new-game", "item0"), (1, "resume", "item1"), (2, "settings", "item2"), (3, "opening", "item3")])

    def test_battle_menu_retreat_and_quit_texts_and_results_are_checked(self):
        menu = framework_prompts(synthetic_main(b"x"))["battleMenu"]
        self.assertEqual((menu["retreat"]["label"], menu["retreat"]["confirm"]["text"], menu["retreat"]["refused"]["text"]),
                         ("retreat", "confirm", "refused"))
        self.assertEqual((menu["retreat"]["rawResult"], menu["quit"]["rawResult"], menu["quit"]["confirm"]["text"]), (1, 4, "quit?"))
        bad = bytearray(synthetic_main(b"x"))
        bad[RETREAT_RESULT_AT + 6] = 2
        with self.assertRaisesRegex(SceneError, "result write"):
            battle_menu(bytes(bad))
        bad = bytearray(synthetic_main(b"x"))
        bad[RETREAT_REFUSED_CALL + 5] = 2
        with self.assertRaisesRegex(SceneError, "refusal call"):
            battle_menu(bytes(bad))

    def test_framework_texts_reject_an_unexamined_call_or_empty_text(self):
        with self.assertRaisesRegex(SceneError, "selector call"):
            framework_prompts(synthetic_main(b"x", pointer=RETRY_PROMPT_POINTER + 2))
        with self.assertRaisesRegex(SceneError, "selector call"):
            framework_prompts(synthetic_main(b"x", mode=1))
        with self.assertRaisesRegex(SceneError, "empty"):
            framework_prompts(synthetic_main(b""))
        bad = bytearray(synthetic_main(b"x"))
        bad[TITLE_MENU_COUNT_AT + 1] = 5
        with self.assertRaisesRegex(SceneError, "title menu call"):
            title_menu(bytes(bad))
        bad = bytearray(synthetic_main(b"x"))
        struct.pack_into("<H", bad, MAIN_DATA_SEGMENT + TITLE_MENU_TABLE + 2, 0x1234)
        with self.assertRaisesRegex(SceneError, "outside the data segment"):
            title_menu(bytes(bad))
        self.assertEqual(selector_text(synthetic_main(b"x"), SAVE_PROMPT_CALL, SAVE_PROMPT_POINTER)["text"], "합성 저장?")

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
