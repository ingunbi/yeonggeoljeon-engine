# SPDX-License-Identifier: GPL-3.0-only
from pathlib import Path
import base64
import json
import os
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from prepare_music import EFFECT_COUNT, TRACKS, directory, driver_tables, effect_bank, prepare
from resource_formats import ResourceError


def member(track: int = 0x10, size: int = 0x20) -> bytes:
    return struct.pack(f"<{TRACKS}H", track, *([0] * (TRACKS - 1))) + bytes(size - TRACKS * 2)


def archive(*members: bytes) -> bytes:
    head, offset = struct.pack("<H", len(members)), 0
    for value in members:
        head += struct.pack("<IH", offset, len(value))
        offset += len(value)
    return head + b"".join(members)


class MusicDirectoryTests(unittest.TestCase):
    def test_members_follow_one_another_and_keep_their_bytes(self):
        first, second = member(), member(size=0x30)
        rows = directory(archive(first, second), "TEST")
        self.assertEqual([row["size"] for row in rows], [0x20, 0x30])
        self.assertEqual(rows[1]["offset"], 14 + 0x20)
        self.assertEqual(base64.b64decode(rows[1]["data"]), second)

    def test_gaps_tails_and_stray_tracks_are_refused(self):
        data = bytearray(archive(member(), member()))
        data[8] += 1
        with self.assertRaises(ResourceError):
            directory(bytes(data), "TEST")
        with self.assertRaises(ResourceError):
            directory(archive(member()) + b"\0", "TEST")
        with self.assertRaises(ResourceError):
            directory(archive(member(track=0x40)), "TEST")
        with self.assertRaises(ResourceError):
            directory(b"", "TEST")

    def test_a_different_driver_is_refused(self):
        with self.assertRaises(ResourceError):
            driver_tables(b"other")


@unittest.skipUnless(os.environ.get("ORIGINAL_GAME_DIR"), "requires explicitly selected ORIGINAL_GAME_DIR")
class OriginalMusicConformanceTests(unittest.TestCase):
    def test_every_track_of_every_song_reaches_its_end_command(self):
        with tempfile.TemporaryDirectory() as directory_name:
            result = prepare(Path(os.environ["ORIGINAL_GAME_DIR"]), Path(directory_name))
            self.assertEqual((len(result["songs"]), len(result["opening"]), len(result["ending"])), (20, 2, 3))
            self.assertEqual(len(result["tables"]["fnumbers"]), 12)
            self.assertTrue(result["source"]["originalFilesPreserved"])
            self.assertFalse(result["source"]["originalProgramsExecuted"])
            self.assertEqual(json.loads((Path(directory_name) / "music.json").read_text(encoding="utf-8"))["format"], 1)
            for song in result["songs"] + result["opening"] + result["ending"]:
                data = base64.b64decode(song["data"])
                for track in struct.unpack_from(f"<{TRACKS}H", data, 0):
                    if track:
                        self.assertEqual(walk(data, track), 0xFF)
            bank = base64.b64decode(result["effects"]["data"])
            self.assertEqual(result["effects"]["count"], EFFECT_COUNT)
            for index, track in enumerate(struct.unpack_from(f"<{EFFECT_COUNT * 2}H", bank, 0)):
                if track:
                    self.assertEqual(walk(bank, track + index // 2 * 4), 0xFF)


def walk(data: bytes, position: int) -> int:
    """Steps over the track's byte shapes until FF; returns the last code."""
    while position < len(data):
        code = data[position]
        if code <= 0x5F or code in (0xF4, 0xF5, 0xF6, 0xF7):
            position += 3
        elif code <= 0xDF or code in (0xF8, 0xF9, 0xFA, 0xFB, 0xFC, 0xFD, 0xFE):
            position += 1
        elif code == 0xFF:
            return code
        else:
            position += 2
    return -1


class EffectBankTests(unittest.TestCase):
    def test_tracks_must_stay_inside_the_bank(self):
        with self.assertRaises(ResourceError):
            effect_bank(b"not main")


if __name__ == "__main__":
    unittest.main()
