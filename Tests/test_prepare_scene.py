# SPDX-License-Identifier: GPL-3.0-only
"""Synthetic-only scene format regressions; no original text or image fixtures."""
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import prepare_scene as scene


def people_fixture():
    data = bytearray(scene.PERSON_BASE + scene.PERSON_COUNT * scene.PERSON_STRIDE)
    for person, name in [(0, "가"), (1, "나")]:
        offset = scene.PERSON_BASE + person * scene.PERSON_STRIDE
        raw = name.encode("cp949")
        data[offset:offset + len(raw)] = raw
    return bytes(data)


def text_fixture(lines):
    data = bytearray(struct.pack("<H", 2))
    for person, text in lines:
        data.extend(struct.pack("<H", person))
        data.extend(text.encode("cp949") + b"\0")
    data.extend(b"\xff\xff")
    return bytes(data)


def record_fixture(code, conditional=False):
    # Two synthetic blocks, the second with one unconditional ten-byte record
    # descriptor and a ten-byte sentinel. Its offsets are not original data.
    header = bytes([1 if conditional else 0]) + bytes(7) + struct.pack("<H", 20)
    return struct.pack("<3H", 6, 7, 0xFFFF) + b"x" + header + b"\xff" * 10 + code


class SceneExtractionTests(unittest.TestCase):
    def extract(self, code, text=None):
        text = text if text is not None else text_fixture([(0, "합성 대사")])
        return scene.extract_record(code, 0, len(code), text, (2, len(text)), people_fixture())

    def test_record_directory_and_conditional_boundary(self):
        data = record_fixture(b"\xff")
        start, end, source = scene.first_palace_record(data)
        self.assertEqual((start, end), (27, 28))
        self.assertEqual(source["offsetSpace"], "decoded-member")
        self.assertEqual(source["offset"], 7)
        with self.assertRaisesRegex(scene.SceneError, "conditional"):
            scene.first_palace_record(record_fixture(b"\xff", conditional=True))

    def test_directory_rejects_bad_bounds_and_order(self):
        for data in (b"\0\0", struct.pack("<3H", 6, 6, 0xFFFF) + b"xx",
                     struct.pack("<3H", 6, 999, 0xFFFF) + b"xx"):
            with self.assertRaises(scene.SceneError):
                scene.offset_sections(data, "synthetic", sentinel=True)

    def test_actual_command_boundary_preserves_literal_actor_operands(self):
        code = (b"\x09\x00\x20" + b"\x0a\x00\x00\x02\x03\x01" + b"\x05"
                + b"\x00\x00\x00" + b"\x01\x00\x00\x04\x05\x02"
                + b"\x18\x00\x00" + b"\x2c\xff")
        commands, effects, boundary = self.extract(code)
        self.assertEqual([c["op"] for c in commands],
                         ["map", "place", "show", "say", "move", "remove", "redraw", "end"])
        self.assertEqual(commands[1]["person"], 0)
        self.assertEqual([commands[1][key] for key in ("x", "y", "facing")], [2, 3, 1])
        self.assertEqual(commands[4]["source"]["bytes"], "010000040502")
        self.assertEqual(effects, [])
        self.assertEqual(boundary["status"], "bounded-record-complete")

    def test_dialogue_list_keeps_original_line_breaks_and_offsets(self):
        text = text_fixture([(0, "합성\r\n줄"), (1, "다음\n말")])
        commands, _, _ = self.extract(b"\x00\x00\x00\xff", text)
        self.assertEqual([c["person"] for c in commands[:-1]], [0, 1])
        self.assertEqual(commands[0]["text"], "합성\r\n줄")
        self.assertEqual(commands[0]["textSource"]["offset"], 2)
        self.assertEqual(commands[0]["speakerSource"]["offset"], scene.PERSON_BASE)
        self.assertEqual(commands[0]["textSource"]["offsetSpace"], "file")
        first_size = commands[0]["textSource"]["length"]
        self.assertEqual(commands[1]["textSource"]["offset"], 2 + first_size)

    def test_city_is_explicit_nonvisual_state_not_an_actor_reset(self):
        commands, effects, boundary = self.extract(b"\x2e\x05\x01\x0a\x0b\xff\xff")
        self.assertEqual([c["op"] for c in commands], ["end"])
        self.assertEqual(effects[0]["city"], 5)
        self.assertEqual(effects[0]["ignoredSourceOperands"], {"x": 10, "y": 11, "facing": 255})
        self.assertEqual(effects[0]["source"]["offset"], 0)
        self.assertEqual(boundary["status"], "bounded-record-complete")

    def test_unknown_opcode_stops_before_later_commands(self):
        commands, _, boundary = self.extract(b"\x05\x70\x18\x00\x00\xff")
        self.assertEqual([c["op"] for c in commands], ["show", "end"])
        self.assertEqual(commands[-1]["boundary"], "unsupported")
        self.assertEqual(commands[-1]["source"]["offset"], 1)
        self.assertEqual(boundary["opcode"], 0x70)

    def test_truncated_known_operands_do_not_advance_to_a_fake_boundary(self):
        commands, _, boundary = self.extract(b"\x05\x01\x00")
        self.assertEqual([c["op"] for c in commands], ["show", "end"])
        self.assertEqual(boundary["offset"], 1)
        self.assertIn("operands cross", boundary["reason"])
        self.assertEqual(commands[-1]["boundary"], "unsupported")

    def test_dialogue_failures_are_explicit_and_do_not_replace_text(self):
        for text in (b"\x02\x00\x00\x00\x80\x00\xff\xff",
                     b"\x02\x00\x00\x00x\x00", b"\x02\x00\x84\x01x\x00\xff\xff"):
            commands, _, boundary = self.extract(b"\x00\x00\x00\xff", text)
            self.assertEqual([c["op"] for c in commands], ["end"])
            self.assertEqual(boundary["status"], "unsupported-boundary")
            self.assertTrue(commands[-1]["unsupported"])

    def test_missing_ff_is_not_reported_as_complete(self):
        commands, _, boundary = self.extract(b"\x05")
        self.assertEqual(boundary["status"], "unsupported-boundary")
        self.assertEqual(commands[-1]["source"]["offset"], 1)
        self.assertEqual(commands[-1]["boundary"], "unsupported")

    def test_casefold_resource_lookup_preserves_source_identity(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "sample.r3").write_bytes(b"a")
            data, source = scene.read_resource(root, "SAMPLE.R3")
            self.assertEqual(data, b"a")
            self.assertEqual(source["size"], 1)
            self.assertEqual(source["resource"], "SAMPLE.R3")

    def test_ambiguous_source_inventory_is_rejected(self):
        # Supply the inventory directly so this check also works on case-insensitive disks.
        candidates = [Path("SAMPLE.R3"), Path("sample.r3")]
        with patch.object(Path, "iterdir", return_value=iter(candidates)):
            with self.assertRaisesRegex(scene.SceneError, "unambiguous"):
                scene.read_resource(Path("synthetic"), "SAMPLE.R3")


if __name__ == "__main__":
    unittest.main()
