# SPDX-License-Identifier: GPL-3.0-only
"""Format boundary regressions and explicit opt-in original-data conformance."""
import hashlib
import json
import os
from pathlib import Path
import struct
import sys
import tempfile
import unittest
import zlib

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from resource_formats import Archive, IndexedImage, ResourceError, decode_archive, npk_picture, planar_image, png_bytes
from prepare_resources import prepare, title_picture


def container(payload, decoded_size=None, little=False):
    """Synthetic container, not bytes from any original game resource."""
    order = "<" if little else ">"
    return ((b"Ls11" if little else b"LS11") + bytes(12) + bytes(range(256))
            + struct.pack(order + "III", len(payload), len(payload) if decoded_size is None else decoded_size, 288)
            + bytes(4) + payload)


def png_scanlines(data):
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise AssertionError("not PNG")
    offset, compressed, header = 8, bytearray(), None
    while offset < len(data):
        length = struct.unpack_from(">I", data, offset)[0]
        kind = data[offset + 4:offset + 8]
        payload = data[offset + 8:offset + 8 + length]
        crc = struct.unpack_from(">I", data, offset + 8 + length)[0]
        assert crc == zlib.crc32(kind + payload)
        if kind == b"IHDR":
            header = struct.unpack(">IIBBBBB", payload)
        if kind == b"IDAT":
            compressed.extend(payload)
        offset += 12 + length
        if kind == b"IEND":
            assert offset == len(data)
            break
    return header, zlib.decompress(compressed)


class ResourceFormatTests(unittest.TestCase):
    def test_ls11_both_orders_and_explicit_source_offsets(self):
        for little in (False, True):
            member = decode_archive(container(b"abc", little=little), "synthetic.R3")[0]
            self.assertEqual((member.data, member.offset, member.index), (b"abc", 288, 0))
            self.assertEqual(member.provenance()["resource"], "synthetic.R3")
        # Literal codes 0,1,2 are bit strings 00,01,1000 -> 0x18.
        self.assertEqual(Archive(container(b"\x18", 3), "synthetic").decode(0).data, b"\0\1\2")

    def test_ls11_does_not_relax_invalid_history_or_trailing_bytes(self):
        for payload in (container(b"\xfe\x02", 3), container(b"\xff", 2)):
            with self.assertRaises(ResourceError):
                Archive(payload, "malformed").decode(0)
        with self.assertRaises(ResourceError):
            Archive(container(b"abc") + b"extra", "malformed")

    def test_planar_bit_significance_and_geometry(self):
        result = planar_image(bytes((0xaa, 0xcc, 0xf0, 0)), 8, 1)
        self.assertEqual(result.pixels, bytes((7, 6, 5, 4, 3, 2, 1, 0)))
        with self.assertRaises(ResourceError):
            planar_image(bytes(4), 7, 1)

    def test_png_crc_rgba_and_only_index_zero_is_transparent(self):
        colors = [(n, n + 1, n + 2) for n in range(16)]
        encoded = png_bytes(IndexedImage(2, 1, bytes((0, 4))), colors, transparent_zero=True)
        header, rows = png_scanlines(encoded)
        self.assertEqual(header[:4], (2, 1, 8, 6))
        self.assertEqual(rows, bytes((0, 0, 1, 2, 0, 4, 5, 6, 255)))

    def test_npk_words_are_permuted_and_malformed_history_is_rejected(self):
        data = b"NPK016" + struct.pack("<5H", 4, 640, 400, 8, 1) + bytes(32)
        good = data + bytes((0, 0x12, 0x34, 0x56, 0x78))
        self.assertEqual(npk_picture(good).pixels, bytes((0, 1, 6, 10, 1, 14, 6, 10)))
        for bad in (good[:-1], good + b"x", data + bytes((1, 0)), data + bytes((1, 31))):
            with self.assertRaises(ResourceError):
                npk_picture(bad)

    def test_output_cannot_be_written_inside_the_selected_original(self):
        with tempfile.TemporaryDirectory() as temp:
            original = Path(temp)
            with self.assertRaisesRegex(ResourceError, "outside"):
                prepare(original, original / "output")


@unittest.skipUnless(os.environ.get("ORIGINAL_GAME_DIR"), "requires explicitly selected ORIGINAL_GAME_DIR")
class OriginalResourceTests(unittest.TestCase):
    def test_original_files_first_palace_people_and_damage_are_preserved(self):
        game = Path(os.environ["ORIGINAL_GAME_DIR"])
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp)
            result = prepare(game, output)
            self.assertEqual(result["provenance"]["originalFileCount"], 69)
            self.assertTrue(result["provenance"]["originalHashesPreserved"])
            self.assertEqual(set(result["maps"]), {str(0x2000+i) for i in range(23)})
            for index in range(23):
                exported = result["maps"][str(0x2000+index)]
                self.assertEqual(len(exported["walkBytes"]),620)
                self.assertEqual(exported["source"]["tiles"]["member"],index)
                self.assertEqual([o["source"]["ordinal"] for o in exported["objects"]],list(range(len(exported["objects"]))))
                self.assertTrue(all(o["source"]["member"] == index for o in exported["objects"]))
                header,_ = png_scanlines((output/exported["image"]).read_bytes())
                self.assertEqual(header[:2],(512,320))
            self.assertIsNone(result["title"])
            self.assertIn("damaged", result["titleStatus"]["reason"])
            self.assertEqual(len(result["maps"]["8192"]["walkBytes"]), 620)
            self.assertEqual(len(result["maps"]["8192"]["objects"]), 12)
            objects = result["maps"]["8192"]["objects"]
            self.assertEqual([obj["source"]["ordinal"] for obj in objects], list(range(12)))
            self.assertTrue(all(isinstance(obj["id"], str) for obj in objects))
            self.assertTrue(all(obj["source"]["bank"] == 8 for obj in objects))
            self.assertEqual([obj["source"]["decodedOffset"] for obj in objects],
                             [1261 + ordinal * 3 for ordinal in range(12)])
            self.assertEqual(len(result["actors"]), 384)
            for person, name, sprite in [(3, "동탁", 8), (6, "이유", 12), (382, "헌제", 16)]:
                record = result["actors"][str(person)]
                self.assertEqual(record["name"], name)
                self.assertEqual(record["source"]["sprite"]["member"], sprite)
            for actor in result["actors"].values():
                image = Path(actor["image"])
                self.assertFalse(image.is_absolute())
                header, pixels = png_scanlines((output / image).read_bytes())
                self.assertEqual(header[:2], (128, 40))
                self.assertEqual(len(pixels), 40 * (1 + 128 * 4))
            manifest = json.loads((output / "resources.json").read_text())
            self.assertNotIn(str(game.resolve()), json.dumps(manifest))

    @unittest.skipUnless(os.environ.get("TITLE_OPGRP_FILE"), "requires explicit TITLE_OPGRP_FILE for the intact background")
    def test_explicit_title_source_reconstructs_the_statically_verified_complete_pixels(self):
        game = Path(os.environ["ORIGINAL_GAME_DIR"])
        opening = (game / "OPEN.EXE").read_bytes()
        source = Path(os.environ["TITLE_OPGRP_FILE"])
        picture, colors, facts = title_picture(source.read_bytes(), opening)
        self.assertEqual((picture.width, picture.height), (640, 400))
        self.assertEqual(hashlib.sha256(picture.pixels).hexdigest(),
                         "e3d7ee93a140ba4e4f9fb53c0390acf8c24ae1bcf38d5c9c5e5806d22ae116e0")
        self.assertEqual([m["member"] for m in facts["members"]], [55, 56, 57, 58, 7, 6, 1])
        self.assertEqual(len(colors), 16)
        with tempfile.TemporaryDirectory() as temp:
            result = prepare(game, Path(temp), source)
            self.assertEqual(result["title"], "images/title.png")
            self.assertTrue(result["titleStatus"]["available"])
            self.assertTrue(result["provenance"]["originalHashesPreserved"])


if __name__ == "__main__":
    unittest.main()
