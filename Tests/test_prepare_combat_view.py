# SPDX-License-Identifier: GPL-3.0-only
from pathlib import Path
import base64
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))

from prepare_combat_view import extract, indexed_tiles, prepare
from resource_formats import ResourceError


class CombatViewFormatTests(unittest.TestCase):
    def test_tiles_become_one_index_per_pixel(self):
        # Sequential planes: colour five is planes zero and two.
        tile = b"\x80" + bytes(31) + bytes(32) + b"\x80" + bytes(31) + bytes(32)
        pixels = indexed_tiles(tile)
        self.assertEqual(len(pixels), 256)
        self.assertEqual(pixels[0], 5)
        self.assertEqual(pixels[1], 0)

    def test_tiles_must_fill_their_member(self):
        with self.assertRaises(ResourceError):
            indexed_tiles(bytes(127))
        with self.assertRaises(ResourceError):
            indexed_tiles(b"")

    def test_examined_main_is_required(self):
        with self.assertRaises(ResourceError):
            extract(b"other", b"", b"", b"")

    @unittest.skipUnless(os.environ.get("ORIGINAL_GAME_DIR"), "needs a caller-selected original directory")
    def test_original_view_when_requested(self):
        with tempfile.TemporaryDirectory() as folder:
            result = prepare(Path(os.environ["ORIGINAL_GAME_DIR"]), Path(folder))
            self.assertEqual(json.loads((Path(folder) / "combat-view.json").read_text(encoding="utf-8"))["format"], 1)
        self.assertEqual(len(result["frameTiles"]), 181)
        self.assertEqual(sum(result["frameTiles"]) * 256, len(base64.b64decode(result["tiles"])))
        self.assertEqual(len(base64.b64decode(result["background"])), 224 * 256)
        self.assertEqual(len(result["classNames"]), 19)
        self.assertEqual(sum(result["classes"]["total"]), 154)


if __name__ == "__main__":
    unittest.main()
