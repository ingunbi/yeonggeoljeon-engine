# SPDX-License-Identifier: GPL-3.0-only
"""Synthetic TF-DCE instruction tests, with opt-in original packed pictures."""
from pathlib import Path
import os
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from prepare_story import picture_directory, prepare
from resource_formats import ResourceError
from tf_dce import dce_picture


def source_picture(body, columns=1, height=2, codecs=3, dictionary=()):
    return (b"\x02T" + bytes([columns]) + struct.pack("<HH", height, codecs) + b"\xe4" +
            (b"\x20" + bytes([len(dictionary)]) + b"".join(struct.pack("<H", n) for n in dictionary)
             if dictionary else b"\0") + body)


def plane_values(picture, plane):
    result = []
    for y in range(picture.height):
        for byte in range(picture.width // 8):
            value = sum(((picture.pixels[y * picture.width + byte * 8 + bit] >> plane) & 1) << (7 - bit)
                        for bit in range(8))
            result.append(value)
    return result


class DCEFormatTests(unittest.TestCase):
    def test_source_fill_and_preserved_planes_have_explicit_zero_base(self):
        picture, fact = dce_picture(source_picture(b"\xaa", codecs=1), zero_base=True)
        self.assertEqual(plane_values(picture, 0), [170, 170])
        self.assertEqual(plane_values(picture, 1), [0, 0])
        self.assertEqual(fact["preservedPlanes"], [1, 2, 3])
        with self.assertRaisesRegex(ResourceError, "explicit"):
            dce_picture(source_picture(b"\xaa", codecs=1), zero_base=False)

    def test_literal_stream_uses_vertical_snake_instead_of_raster_order(self):
        picture, _ = dce_picture(source_picture(bytes([0x73, 128, 64, 32, 16]), columns=2), zero_base=True)
        self.assertEqual(plane_values(picture, 0), [128, 16, 64, 32])

    def test_run_dictionary_and_nibble_pair_are_distinct_source_instructions(self):
        picture, _ = dce_picture(source_picture(bytes([0xA0, 0x55])), zero_base=True)
        self.assertEqual(plane_values(picture, 0), [85, 85])
        dictionary, _ = dce_picture(source_picture(bytes([0, 0]), dictionary=[0xAA7F]), zero_base=True)
        self.assertEqual(plane_values(dictionary, 0), [170, 170])
        pair, _ = dce_picture(source_picture(bytes([0x80, 0x12])), zero_base=True)
        self.assertEqual(plane_values(pair, 0), [0x22, 0x11])

    def test_source_sequence_copy_supports_overlap(self):
        picture, _ = dce_picture(source_picture(bytes([0x70, 128, 0x20, 1]), columns=2), zero_base=True)
        self.assertEqual(plane_values(picture, 0), [128] * 4)

    def test_horizontal_copy_keeps_vga_position_as_source_identity(self):
        picture, _ = dce_picture(source_picture(bytes([0x71, 128, 64, 0x40, 0]), columns=2), zero_base=True)
        self.assertEqual(plane_values(picture, 0), [128, 128, 64, 64])

    def test_other_plane_copy_inversion_and_mask_rotation(self):
        inverted, _ = dce_picture(source_picture(bytes([0x71, 128, 64, 0x31, 0]), codecs=0x33), zero_base=True)
        self.assertEqual(plane_values(inverted, 1), [127, 191])
        mask, _ = dce_picture(source_picture(bytes([0x71, 128, 64, 0x51, 0]), codecs=0x33), zero_base=True)
        self.assertEqual(plane_values(mask, 1), [128, 64])
        rotated, _ = dce_picture(source_picture(bytes([0x71, 128, 64, 0x91, 0]), codecs=0x33), zero_base=True)
        self.assertEqual(plane_values(rotated, 1), [32, 16])

    def test_truncation_foreign_dictionary_and_unowned_tail_fail_explicitly(self):
        for data in [source_picture(b"\x71x"), source_picture(b"\0"), source_picture(b"\xa0xextra")]:
            with self.assertRaises(ResourceError):
                dce_picture(data, zero_base=True)
        with self.assertRaisesRegex(ResourceError, "outside"):
            dce_picture(source_picture(bytes([0x40, 0])), zero_base=True)

    def test_packed_resource_directory_has_complete_nonoverlapping_ownership(self):
        data = struct.pack("<IH", 0, 3) + struct.pack("<IH", 3, 2) + b"abcde"
        self.assertEqual(picture_directory(data, 2), [(12, 15), (15, 17)])
        with self.assertRaises(ResourceError):
            picture_directory(data + b"tail", 2)
        with self.assertRaises(ResourceError):
            picture_directory(struct.pack("<IH", 0, 6) + b"abc", 1)


@unittest.skipUnless(os.environ.get("ORIGINAL_GAME_DIR"), "requires explicitly selected ORIGINAL_GAME_DIR")
class OriginalDCEConformanceTests(unittest.TestCase):
    def test_all_source_story_pictures_consume_their_payload_and_export_both_panel_modes(self):
        with tempfile.TemporaryDirectory() as directory:
            result = prepare(Path(os.environ["ORIGINAL_GAME_DIR"]), Path(directory))
            self.assertEqual(len(result["assets"]), 38)
            self.assertEqual(len(result["portraitAssets"]), 240)
            self.assertEqual(len(result["layouts"]), 2)
            self.assertEqual((result["assets"][3]["width"], result["assets"][3]["height"]), (224, 144))
            self.assertTrue(result["source"]["originalHashesPreserved"])
            for asset in result["assets"] + result["portraitAssets"]:
                self.assertEqual(asset["source"]["decoder"]["sourceBytesConsumed"], asset["source"]["length"])
                self.assertEqual(set(asset["imagesByPalette"]), {"0", "1", "2", "3"})
                self.assertTrue((Path(directory) / asset["image"]).is_file())
            self.assertIsNone(result["layouts"][0]["frameAsset"])
            self.assertEqual(result["layouts"][0]["pictureRect"], [160, 40, 224, 144])
            self.assertEqual([button["value"] for button in result["choiceButtons"]], [1, 0])
            self.assertEqual([button["label"] for button in result["choiceButtons"]], ["Yes", "No"])


if __name__ == "__main__":
    unittest.main()
