# SPDX-License-Identifier: GPL-3.0-only
"""Synthetic masks, fonts and source clock tests, with opt-in original files."""
from pathlib import Path
import os
import struct
import sys
import tempfile
import unittest
import zlib

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from prepare_ending import caption_picture, mask_opacity, opening_frames, prepare
from resource_formats import IndexedImage, ResourceError, png_bytes


def png_rows(data):
    cursor, compressed = 8, bytearray()
    while cursor < len(data):
        size = struct.unpack_from(">I", data, cursor)[0]
        if data[cursor + 4:cursor + 8] == b"IDAT":
            compressed += data[cursor + 8:cursor + 8 + size]
        cursor += size + 12
    return zlib.decompress(compressed)


class EndingFormatTests(unittest.TestCase):
    def test_source_mask_preserves_destination_without_erasing_opaque_black(self):
        opacity = mask_opacity(b"\x80", 8, 1)
        self.assertEqual(opacity, bytes([0] + [255] * 7))
        rows = png_rows(png_bytes(IndexedImage(8, 1, bytes(8)), [(0, 0, 0)] * 16, opacity=opacity))
        self.assertEqual(rows[1:9], bytes([0, 0, 0, 0, 0, 0, 0, 255]))
        with self.assertRaises(ResourceError):
            mask_opacity(bytes(2), 8, 1)
        with self.assertRaises(ResourceError):
            png_bytes(IndexedImage(8, 1, bytes(8)), [(0, 0, 0)] * 16, opacity=bytes(7))

    def test_ascii_bitmap_retains_padding_line_pitch_and_right_bold_pixel(self):
        font = bytearray(96 * 16)
        font[(ord("A") - 32) * 16] = 1
        image, opacity = caption_picture([b"A", b""], 3, bytes(30), bytes(font))
        self.assertEqual((image.width, image.height), (24, 40))
        self.assertEqual([i for i, value in enumerate(opacity) if value], [15, 16])
        self.assertEqual(image.pixels[15:17], bytes([7, 7]))
        self.assertFalse(any(opacity[20 * 24:]))

    def test_korean_font_identity_keeps_14_rows_and_pair_width(self):
        korean = bytearray(30)
        korean[2], korean[3], korean[28], korean[29] = 128, 1, 0, 128
        image, opacity = caption_picture([b"\xa1\xa1"], 4, bytes(korean), bytes(96 * 16))
        self.assertEqual([i for i, value in enumerate(opacity[:32]) if value], [8, 9, 23, 24])
        self.assertEqual([i for i, value in enumerate(opacity[13 * 32:14 * 32]) if value], [16, 17])
        self.assertFalse(any(opacity[14 * 32:]))
        with self.assertRaises(ResourceError):
            caption_picture([b"\xa1"], 4, bytes(korean), bytes(96 * 16))

    def test_source_motion_cycles_text_by_six_iterations_and_keeps_final_hold(self):
        lines = [{"text": f"synthetic-{i}", "sourceByteLength": 12} for i in range(12)]
        frames = opening_frames(lines)
        self.assertEqual(len(frames), 33)
        self.assertEqual(frames[0]["layers"][1]["x"], 368)
        self.assertEqual([frame["layers"][1]["x"] for frame in frames[1:33]], list(range(360, 235, -4)))
        self.assertEqual([frame["caption"]["sourceChunk"] for frame in frames[1:33]], [i // 6 for i in range(32)])
        self.assertEqual([frame["sourceTicks"] for frame in frames], [325] + [125] * 31 + [100])
        self.assertEqual(sum(frame["sourceTicks"] for frame in frames), 4300)
        with self.assertRaises(ResourceError):
            opening_frames(lines[:11])


@unittest.skipUnless(os.environ.get("ORIGINAL_GAME_DIR"), "requires explicitly selected ORIGINAL_GAME_DIR")
class OriginalEndingConformanceTests(unittest.TestCase):
    def test_original_first_scene_has_explicit_frontier_and_exact_source_font_assets(self):
        with tempfile.TemporaryDirectory() as directory:
            result = prepare(Path(os.environ["ORIGINAL_GAME_DIR"]), Path(directory))
            self.assertEqual(len(result["assets"]), 9)
            self.assertEqual([s["value"] for s in result["selections"]], [0, 1])
            self.assertFalse(any(s["complete"] for s in result["selections"]))
            self.assertEqual(result["programs"][0]["frontier"]["offset"], 0x4B9A)
            self.assertEqual(len(result["programs"][0]["frames"]), 33)
            self.assertTrue(result["source"]["originalHashesPreserved"])
            self.assertFalse(result["source"]["originalProgramsExecuted"])
            self.assertTrue(all((Path(directory) / asset["image"]).is_file() for asset in result["assets"]))


if __name__ == "__main__":
    unittest.main()
