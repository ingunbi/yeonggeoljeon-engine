#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Extract caller-owned native battle-map sprites to a local-only data directory.

The original executable is read statically, never run. HEXZCHR's eight planar
16x16 tiles are two 32x32 frames. Original images/JSON must remain untracked.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import sys

from prepare_resources import EXAMINED_MAIN, inventory, paint, palette_at
from resource_formats import Archive, IndexedImage, ResourceError, planar_image, png_bytes

PALETTE_OFFSET = 0x38DF0 + 3 * 48
MEMBER_COUNT = 47
FRAME_SIZE = 32


def tiled_frame(payload: bytes, columns: int, rows: int) -> IndexedImage:
    if not 1 <= columns <= 128 or not 1 <= rows <= 128 or len(payload) != columns * rows * 128:
        raise ResourceError("native sprite tile grid does not match its planar payload")
    width, height = columns * 16, rows * 16
    pixels = bytearray(width * height)
    for tile in range(columns * rows):
        image = planar_image(payload[tile * 128:(tile + 1) * 128], 16, 16)
        paint(pixels, width, height, image, (tile % columns) * 16, (tile // columns) * 16)
    return IndexedImage(width, height, bytes(pixels))


def unit_frames(payload: bytes) -> tuple[IndexedImage, IndexedImage]:
    """MAIN2B877 reads128-byte tiles; native tile index low2 owns quadrant."""
    if len(payload) != 1024:
        raise ResourceError("HEXZCHR member must contain eight128-byte source tiles")
    return tiled_frame(payload[:512],2,2),tiled_frame(payload[512:],2,2)


def flip_frame(image: IndexedImage) -> IndexedImage:
    """MAIN2C2D4 reverses pixels and swaps tile columns within each frame."""
    pixels = b"".join(image.pixels[y * image.width:(y + 1) * image.width][::-1]
                      for y in range(image.height))
    return IndexedImage(image.width, image.height, pixels)


def prepare(game: Path, output: Path) -> dict:
    game, output = game.resolve(), output.resolve()
    if output == game or game in output.parents:
        raise ResourceError("battle sprite output must remain outside the original directory")
    before = inventory(game)
    main = (game / "MAIN.EXE").read_bytes()
    if hashlib.sha256(main).hexdigest() != EXAMINED_MAIN:
        raise ResourceError("MAIN does not match the examined original battle sprite producer")
    carrier = (game / "HEXZCHR.R3").read_bytes()
    archive = Archive(carrier, "HEXZCHR.R3")
    if len(archive) != MEMBER_COUNT:
        raise ResourceError("HEXZCHR member count differs from the examined47-entry sprite loader")
    colors = palette_at(main, PALETTE_OFFSET)
    frames = []
    images = output / "images" / "battle-sprites"
    images.mkdir(parents=True, exist_ok=True)
    for member_id in range(len(archive)):
        member = archive.decode(member_id)
        for frame_id, image in enumerate(unit_frames(member.data)):
            relative = f"images/battle-sprites/unit-{member_id:02}-{frame_id}.png"
            flipped = f"images/battle-sprites/unit-{member_id:02}-{frame_id}-flipped.png"
            # Source mask builder0:C632 computes ~(plane0|plane1|plane2|plane3).
            # Therefore exactly color index0 is transparent, including inside art.
            (output / relative).write_bytes(png_bytes(image, colors, transparent_zero=True))
            (output / flipped).write_bytes(png_bytes(flip_frame(image), colors, transparent_zero=True))
            frames.append({"member": member_id, "frame": frame_id, "image": relative,
                           "flippedImage": flipped, "indexedPixelSha256": hashlib.sha256(image.pixels).hexdigest(),
                           "source": member.provenance()})
    duel_carrier = (game / "HEXICHR.R3").read_bytes()
    duel_archive = Archive(duel_carrier, "HEXICHR.R3")
    if len(duel_archive) != 78:
        raise ResourceError("HEXICHR member count differs from the examined78-entry duel loader")
    duel_frames = []
    (output / "images" / "duel-sprites").mkdir(parents=True,exist_ok=True)
    for member_id in range(len(duel_archive)):
        member = duel_archive.decode(member_id)
        image = tiled_frame(member.data,6,6)
        relative = f"images/duel-sprites/duel-{member_id:02}.png"
        flipped = f"images/duel-sprites/duel-{member_id:02}-flipped.png"
        (output / relative).write_bytes(png_bytes(image,colors,transparent_zero=True))
        (output / flipped).write_bytes(png_bytes(flip_frame(image),colors,transparent_zero=True))
        duel_frames.append({"member":member_id,"image":relative,"flippedImage":flipped,
                            "indexedPixelSha256":hashlib.sha256(image.pixels).hexdigest(),"source":member.provenance()})
    if before != inventory(game):
        raise ResourceError("original files changed during battle sprite extraction")
    result = {"format": 1, "width": FRAME_SIZE, "height": FRAME_SIZE, "memberCount": MEMBER_COUNT,
              "paletteSlot": 3, "frames": frames,
              "duel": {"width":96,"height":96,"memberCount":78,"frames":duel_frames,
                       "specialPersonBanks":list(main[0x37DA0+0x5048:0x37DA0+0x5048+5]),
                       "source":{"resource":"HEXICHR.R3","resourceSha256":hashlib.sha256(duel_carrier).hexdigest(),
                                 "specialPersonBanks":{"resource":"MAIN.EXE","offset":0x37DA0+0x5048,"bytes":5},
                                 "loaderCode":"MAIN.EXE:0x3431C..0x34538","tileGridCode":"MAIN.EXE:0x34216..0x34318"}},
              "source": {"mainSha256": EXAMINED_MAIN, "resource": "HEXZCHR.R3",
                         "resourceSha256": hashlib.sha256(carrier).hexdigest(),
                         "palette": {"resource": "MAIN.EXE", "offset": PALETTE_OFFSET, "bytes": 48, "slot": 3},
                         "loaderCode": "MAIN.EXE:0x2B7C4..0x2B8D8",
                         "maskCode": "MAIN.EXE:0xC632..0xC662",
                         "flipCode": "MAIN.EXE:0x2C2D4..0x2C3DF",
                         "standingFrameCode": "MAIN.EXE:0x2A0D0..0x2A105",
                         "movementFrameCode": "MAIN.EXE:0x2CCD5..0x2CCE4;0x2CEB4..0x2CEC3",
                         "originalHashesPreserved": True, "originalExecution": False},
              "limitations": ["Static pixel reconstruction; no original DOS framebuffer comparison was performed.",
                              "Native movement frame and facing selectors are recovered; original wall-clock animation timing is unverified.",
                              "HEXBCHR enlarged combat-animation producer is outside this map/duel sprite catalog.",
                              "Duel graphics load mode is explicit; native stage composition and timing remain renderer responsibilities.",
                              "Dynamic palette transformations, fog/hidden-unit gates and native special draw effects remain separate renderer responsibilities."]}
    pending = output / ".battle-sprites.json.tmp"
    pending.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    pending.replace(output / "battle-sprites.json")
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--game-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        value = prepare(args.game_dir, args.output)
    except (OSError, ResourceError) as error:
        print(f"battle sprite preparation failed: {error}", file=sys.stderr)
        return 1
    print(json.dumps({"members": value["memberCount"], "frames": len(value["frames"]),
                      "duelMembers":value["duel"]["memberCount"],
                      "pngFiles": (len(value["frames"])+len(value["duel"]["frames"]))*2, "paletteSlot": value["paletteSlot"],
                      "originalHashesPreserved": value["source"]["originalHashesPreserved"]}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
