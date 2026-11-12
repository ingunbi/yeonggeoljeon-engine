# SPDX-License-Identifier: GPL-3.0-only
import importlib.util
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location("build_android", Path(__file__).resolve().parents[1] / "tools/build_android.py")
build_android = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(build_android)


class AndroidBuildTests(unittest.TestCase):
    def test_package_lists_shared_sources_and_android_files_without_repeats(self):
        files = build_android.package_sources()
        names = [f.name for f in files]
        self.assertEqual(len(names), len(set(names)))
        self.assertIn("AndroidBridge.swift", names)
        self.assertIn("IPadGameStore.swift", names)
        self.assertNotIn("main.swift", names)

    def test_code_page_table_encodes_hangul_as_two_bytes(self):
        source = build_android.cp949_table_source()
        self.assertIn("enum CP949", source)
        self.assertGreater(len(source), 20000)


if __name__ == "__main__":
    unittest.main()
