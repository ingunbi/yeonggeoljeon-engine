# SPDX-License-Identifier: GPL-3.0-only
"""Synthetic project-generation checks; no original game or signing service."""
import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("build_ipad", Path(__file__).resolve().parents[1] / "tools/build_ipad.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class IPadProjectTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        self.old = MODULE.ROOT
        MODULE.ROOT = self.root
        (self.root / "iOS").mkdir()
        (self.root / "Sources").mkdir()
        (self.root / "Sources/Core.swift").write_text("import Foundation\n")
        (self.root / "iOS/IPadApp.swift").write_text("import SwiftUI\n")
        self.manifest = self.root / "iOS/SharedSources.json"
        self.manifest.write_text(json.dumps(["Sources/Core.swift"]))
        self.data = self.root / "synthetic"
        self.data.mkdir()
        for name in ("resources.json", "campaign.json", "combat.json", "people.json"):
            (self.data / name).write_text("{}")

    def tearDown(self):
        MODULE.ROOT = self.old
        self.temp.cleanup()

    def test_local_project_has_ipad_family_and_exact_sources(self):
        target = self.root / "build/ipad"
        project = MODULE.generate(self.data, target)
        info = plistlib.loads((target / "Info.plist").read_bytes())
        self.assertEqual(info["UIDeviceFamily"], [2])
        evidence = json.loads((target / "ipad-build-inputs.json").read_text())
        self.assertEqual(set(evidence["sourceFiles"]), {"Sources/Core.swift", "iOS/IPadApp.swift"})
        self.assertEqual(len(evidence["dataFiles"]), 4)
        self.assertIn("PBXNativeTarget", (project / "project.pbxproj").read_text())
        self.assertEqual((self.data / "people.json").read_text(), "{}")

    def test_source_directory_cannot_be_output(self):
        with self.assertRaises(ValueError):
            MODULE.generate(self.data, self.data)

    def test_prepared_bundle_can_be_regenerated_without_nested_copy(self):
        target = self.root / "build/ipad"
        MODULE.generate(self.data, target)
        MODULE.generate(target / "GameData", target)
        self.assertFalse((target / "GameData/GameData").exists())

    def test_output_cannot_be_nested_in_input(self):
        data = self.root / "build/prepared"
        data.mkdir(parents=True)
        with self.assertRaises(ValueError):
            MODULE.generate(data, data / "nested")

    def test_external_source_and_desktop_entry_are_rejected(self):
        for sources in [["../outside.swift"], ["Sources/main.swift"], ["Sources/Core.swift", "Sources/Core.swift"]]:
            (self.root / "Sources/main.swift").write_text("print(0)")
            self.manifest.write_text(json.dumps(sources))
            with self.assertRaises(ValueError):
                MODULE.generate(self.data, self.root / "build/ipad")

    def test_missing_prepared_data_is_explicit(self):
        (self.data / "campaign.json").unlink()
        with self.assertRaisesRegex(ValueError, "campaign.json"):
            MODULE.generate(self.data, self.root / "build/ipad")


if __name__ == "__main__":
    unittest.main()
