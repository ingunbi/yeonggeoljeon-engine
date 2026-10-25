# SPDX-License-Identifier: GPL-3.0-only
import os
from pathlib import Path
import struct
import sys
import tempfile
import unittest
import zlib

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/"tools"))
from prepare_battle_sprites import FRAME_SIZE, flip_frame, prepare, tiled_frame, unit_frames
from prepare_resources import palette_at
from resource_formats import Archive, IndexedImage, ResourceError, png_bytes


def solid_tile(color):
    return b"".join(bytes([255 if color&(1<<plane) else 0])*32 for plane in range(4))


class BattleSpriteTests(unittest.TestCase):
    def test_eight_planar_tiles_preserve_frame_and_quadrant_order(self):
        frames=unit_frames(b"".join(solid_tile(color) for color in range(1,9)))
        self.assertEqual([(im.width,im.height) for im in frames],[(32,32),(32,32)])
        self.assertEqual([[im.pixels[y*32+x] for x,y in [(0,0),(31,0),(0,31),(31,31)]] for im in frames],
                         [[1,2,3,4],[5,6,7,8]])

    def test_pixel_flip_swaps_columns_without_swapping_frames_or_rows(self):
        original=IndexedImage(8,2,bytes(range(16)))
        self.assertEqual(flip_frame(original).pixels,bytes([7,6,5,4,3,2,1,0,15,14,13,12,11,10,9,8]))
        self.assertEqual(flip_frame(flip_frame(original)),original)

    def test_mask_transparency_preserves_nonzero_pixel_colors(self):
        image=IndexedImage(8,1,bytes([0,1,2,3,4,5,6,7]))
        colors=[(i,i+16,i+32) for i in range(16)]
        png=png_bytes(image,colors,transparent_zero=True)
        cursor=8;encoded=b""
        while cursor<len(png):
            length=struct.unpack_from(">I",png,cursor)[0]
            if png[cursor+4:cursor+8]==b"IDAT":encoded+=png[cursor+8:cursor+8+length]
            cursor+=length+12
        raw=zlib.decompress(encoded)
        self.assertEqual(raw[1:5],bytes([0,16,32,0]))
        self.assertEqual(raw[5:9],bytes([1,17,33,255]))

    def test_rejects_partial_sprite_and_original_directory_output(self):
        with self.assertRaisesRegex(ResourceError,"eight128"):
            unit_frames(bytes(1023))
        with tempfile.TemporaryDirectory() as temp:
            game=Path(temp)/"GAME";game.mkdir()
            with self.assertRaisesRegex(ResourceError,"outside"):
                prepare(game,game/"generated")

    def test_duel_tile_grid_preserves_six_columns_and_six_rows(self):
        image=tiled_frame(b"".join(solid_tile(color%16) for color in range(36)),6,6)
        self.assertEqual((image.width,image.height),(96,96))
        self.assertEqual([image.pixels[y*96+x] for x,y in [(0,0),(95,0),(0,95),(95,95)]],[0,5,14,3])


@unittest.skipUnless(os.environ.get("ORIGINAL_GAME_DIR"),"requires explicitly selected ORIGINAL_GAME_DIR")
class OriginalBattleSpriteTests(unittest.TestCase):
    def test_real_archive_domain_and_all_frames_decode_from_source_bytes(self):
        game=Path(os.environ["ORIGINAL_GAME_DIR"])
        archive=Archive((game/"HEXZCHR.R3").read_bytes(),"HEXZCHR.R3")
        self.assertEqual(len(archive),47)
        for member in range(len(archive)):
            images=unit_frames(archive.decode(member).data)
            self.assertEqual([len(im.pixels) for im in images],[FRAME_SIZE*FRAME_SIZE]*2)
            self.assertTrue(all(pixel<=15 for im in images for pixel in im.pixels))
        self.assertEqual(len(palette_at((game/"MAIN.EXE").read_bytes(),0x38DF0+3*48)),16)
        duel=Archive((game/"HEXICHR.R3").read_bytes(),"HEXICHR.R3")
        self.assertEqual(len(duel),78)
        for member in range(len(duel)):
            self.assertEqual(len(tiled_frame(duel.decode(member).data,6,6).pixels),96*96)


if __name__=="__main__":unittest.main()
