# SPDX-License-Identifier: GPL-3.0-only
"""Exercise the original-archive boundary without any copyrighted fixtures."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
import zipfile

MODULE = Path(__file__).resolve().parents[1] / "tools" / "build.py"
SPEC = importlib.util.spec_from_file_location("engine_build", MODULE)
build = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(build)


class OriginalArchiveBoundary(unittest.TestCase):
    def archive(self, folder, extras=()):
        target = Path(folder) / "input.zip"
        with zipfile.ZipFile(target, "w") as archive:
            for name in build.REQUIRED:
                archive.writestr("GAME/" + name, b"synthetic-format-fixture")
            for name, value in extras:
                archive.writestr(name, value)
        return target

    def test_extracts_only_inside_new_folder_and_preserves_input(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = self.archive(temporary)
            before = source.read_bytes()
            output = Path(temporary) / "output"
            build.stage_zip(source, output)
            self.assertEqual(source.read_bytes(), before)
            self.assertEqual({p.name for p in output.iterdir()}, set(build.REQUIRED))

    def test_traversal_is_rejected_before_any_files_are_written(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = self.archive(temporary, [("GAME/../../outside", b"bad")])
            output = Path(temporary) / "output"
            with self.assertRaisesRegex(ValueError, "unsafe"):
                build.stage_zip(source, output)
            self.assertFalse(output.exists())
            self.assertFalse((Path(temporary) / "outside").exists())

    def test_case_colliding_names_are_not_merged(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = self.archive(temporary, [("GAME/main.exe", b"different")])
            output = Path(temporary) / "output"
            with self.assertRaisesRegex(ValueError, "duplicate"):
                build.stage_zip(source, output)
            self.assertFalse(output.exists())

    def test_missing_required_member_is_explicit(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "input.zip"
            with zipfile.ZipFile(source, "w") as archive:
                archive.writestr("GAME/MAIN.EXE", b"synthetic")
            with self.assertRaisesRegex(ValueError, "missing original"):
                build.stage_zip(source, Path(temporary) / "output")


if __name__ == "__main__":
    unittest.main()
