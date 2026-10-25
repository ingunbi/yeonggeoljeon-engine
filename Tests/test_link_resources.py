# SPDX-License-Identifier: GPL-3.0-only
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from link_resources import link


class LinkedResourceTests(unittest.TestCase):
    def fixture(self):
        resource = {"format": 1, "actors": {"3": {"portraitIndex": 4}}, "portraits": {}}
        story = {"format": 1, "portraitAssets": [{"id": 4, "width": 64, "height": 80,
                  "imagesByPalette": {str(p): f"images/face-{p}.png" for p in range(4)}}]}
        return resource, story

    def test_link_uses_owned_portrait_id_and_palette_variants(self):
        resource, story = self.fixture()
        value = link(resource, story)
        self.assertEqual(value["portraits"]["3"]["source"]["portraitID"], 4)
        self.assertEqual(value["portraits"]["3"]["imagesByPalette"]["2"], "images/face-2.png")
        self.assertEqual(resource["portraits"], {})

    def test_absent_or_ambiguous_source_identity_cannot_be_replaced(self):
        resource, story = self.fixture()
        story["portraitAssets"] *= 2
        with self.assertRaises(ValueError):
            link(resource, story)
        with self.assertRaises(ValueError):
            link(resource, {"format": 1, "portraitAssets": []})

    def test_geometry_and_relative_paths_are_validated_before_write(self):
        resource, story = self.fixture()
        story["portraitAssets"][0]["imagesByPalette"]["2"] = "../escape.png"
        with self.assertRaises(ValueError):
            link(resource, story)
        resource, story = self.fixture()
        story["portraitAssets"][0]["width"] = 80
        with self.assertRaises(ValueError):
            link(resource, story)
