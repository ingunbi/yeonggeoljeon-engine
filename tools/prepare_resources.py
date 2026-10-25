#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Prepare a bounded first-scene resource set from caller-selected original bytes.

No DOS executable is run. No external engine, previous script implementation, or
generated content pack is imported. All artwork is written only to local output.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import struct
import sys

from resource_formats import Archive, IndexedImage, ResourceError, npk_picture, planar_image, png_bytes

EXAMINED_MAIN = "731c8d26a39fcd4e9fa41b142db9bd5913a496a2da5eaa1db798b7867850815f"
EXAMINED_OPEN = "97f5f00fee2b340243bda76166e3d989740d8723a20f72a6b38545f848c18a01"
KNOWN_BAD_OPENING = "eed970e71f4dd7abbcf910aacf232ea37c94af935900c870b8e991fd6f0f6f2b"


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def inventory(directory: Path) -> dict[str, dict]:
    result = {}
    for file in sorted(directory.rglob("*")):
        if file.is_symlink():
            raise ResourceError("source directory contains a symbolic link; identity is ambiguous")
        if file.is_file():
            data = file.read_bytes()
            result[file.relative_to(directory).as_posix()] = {"bytes": len(data), "sha256": digest(data)}
    if not result:
        raise ResourceError("source directory has no files")
    return result


def palette_at(executable: bytes, offset: int) -> list[tuple[int, int, int]]:
    values = executable[offset:offset + 48]
    if len(values) != 48 or any(v > 15 for v in values):
        raise ResourceError("source palette is missing or contains non-4-bit channels")
    def channel(n: int) -> int:
        dac = n * 4 + n // 4
        return dac * 4 + dac // 16
    return [(channel(values[n + 1]), channel(values[n + 2]), channel(values[n]))
            for n in range(0, 48, 3)]


def paint(destination: bytearray, width: int, height: int, image: IndexedImage,
          x: int, y: int, transparent: bool = False) -> None:
    if not (0 <= x and 0 <= y and x + image.width <= width and y + image.height <= height):
        raise ResourceError("source composition lies outside its canvas")
    for row in range(image.height):
        target = (y + row) * width + x
        source = row * image.width
        for column in range(image.width):
            color = image.pixels[source + column]
            if not transparent or color:
                destination[target + column] = color


def title_picture(opgrp: bytes, opening: bytes) -> tuple[IndexedImage, list, dict]:
    if digest(opening) != EXAMINED_OPEN:
        raise ResourceError("OPEN.EXE does not match the examined title layout/palette build")
    if digest(opgrp) == KNOWN_BAD_OPENING:
        raise ResourceError("supplied OPGRP.R3 has known damaged title background members 55..58; no substitute pixels created")
    archive = Archive(opgrp, "OPGRP.R3")
    canvas = bytearray(640 * 400)
    provenance = []
    for index, top in zip(range(55, 59), (16, 108, 200, 292)):
        member = archive.decode(index)
        picture = npk_picture(member.data)
        if (picture.width, picture.height) != (640, 92):
            raise ResourceError(f"title background member {index} is not 640x92")
        paint(canvas, 640, 400, picture, 0, top)
        provenance.append(member.provenance())
    for index, width, height, x, y, alpha in [(7, 504, 116, 68, 140, True),
                                            (6, 504, 116, 68, 140, True),
                                            (1, 264, 16, 368, 384, False)]:
        member = archive.decode(index)
        picture = planar_image(member.data, width, height, interleaved=True)
        paint(canvas, 640, 400, picture, x, y, alpha)
        provenance.append(member.provenance())
    return (IndexedImage(640, 400, bytes(canvas)), palette_at(opening, 0xC158),
            {"members": provenance, "palette": {"resource": "OPEN.EXE", "offset": 0xC158, "bytes": 48},
             "code": ["OPEN.EXE:0x1CE4..0x1E63", "OPEN.EXE:0x5C52..0x6401", "GRPDRV.EXE:0x417F..0x41E7"]})


def object_bank(payload: bytes) -> tuple[list[IndexedImage], list[dict]]:
    """SSCCHR1 pattern dimensions, cell references and independent planar cells."""
    if not payload:
        raise ResourceError("empty object bank")
    count, cursor, patterns = payload[0], 1, []
    for index in range(count):
        origin = cursor
        if cursor + 2 > len(payload):
            raise ResourceError("object pattern geometry is truncated")
        columns, rows = payload[cursor:cursor + 2]
        cursor += 2
        length = columns * rows
        if not 0 < columns <= 32 or not 0 < rows <= 20 or cursor + length > len(payload):
            raise ResourceError("object pattern geometry/cells are invalid")
        patterns.append((columns, rows, payload[cursor:cursor + length], origin))
        cursor += length
    if cursor >= len(payload):
        raise ResourceError("object bank cell count is absent")
    cells = payload[cursor]
    cursor += 1
    if cursor + cells * 128 != len(payload):
        raise ResourceError("object bank cell bytes do not cover its payload")
    tiles = [planar_image(payload[cursor + i * 128:cursor + (i + 1) * 128], 16, 16)
             for i in range(cells)]
    images, origins = [], []
    for columns, rows, ids, origin in patterns:
        canvas = bytearray(columns * 16 * rows * 16)
        for at, tile in enumerate(ids):
            if tile == 255:
                continue
            if tile >= len(tiles):
                raise ResourceError("object pattern references an absent cell")
            paint(canvas, columns * 16, rows * 16, tiles[tile], at % columns * 16, at // columns * 16)
        images.append(IndexedImage(columns * 16, rows * 16, bytes(canvas)))
        origins.append({"decodedOffset": origin, "bytes": 2 + columns * rows})
    return images, origins


def prepare(game_dir: Path, output: Path, title_opgrp: Path | None = None) -> dict:
    game_dir, output = game_dir.resolve(), output.resolve()
    if output == game_dir or game_dir in output.parents:
        raise ResourceError("output must be outside the selected original directory")
    before = inventory(game_dir)
    main = (game_dir / "MAIN.EXE").read_bytes()
    if digest(main) != EXAMINED_MAIN:
        raise ResourceError("MAIN.EXE does not match the examined first-scene resource build")
    colors = palette_at(main, 0x38DF0 + 2 * 48)
    output.mkdir(parents=True, exist_ok=True)
    def write_image(name: str, picture: IndexedImage, alpha: bool = False) -> str:
        relative = Path("images") / name
        path = output / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(png_bytes(picture, colors, transparent_zero=alpha))
        return relative.as_posix()

    # PMAP source is 640 literal tile IDs, 620 walk cells, count + object triples.
    palace_member = Archive((game_dir / "PMAP.R3").read_bytes(), "PMAP.R3").decode(0)
    palace = palace_member.data
    if len(palace) < 1261 or len(palace) != 1261 + palace[1260] * 3:
        raise ResourceError("PMAP0 does not have the verified tile/walk/object structure")
    tile_member = Archive((game_dir / "SMAPBGPL.R3").read_bytes(), "SMAPBGPL.R3").decode(1)
    if len(tile_member.data) % 128:
        raise ResourceError("palace planar tile bank is not a whole number of 16x16 cells")
    tiles = [planar_image(tile_member.data[i:i + 128], 16, 16)
             for i in range(0, len(tile_member.data), 128)]
    background = bytearray(512 * 320)
    for offset, tile in enumerate(palace[:640]):
        if tile >= len(tiles):
            raise ResourceError("PMAP0 references an absent palace background cell")
        paint(background, 512, 320, tiles[tile], offset % 32 * 16, offset // 32 * 16)
    walk = list(palace[640:1260])
    room = {"image": write_image("palace-0.png", IndexedImage(512, 320, bytes(background))),
            "width": 512, "height": 320, "viewport": [16, 16, 512, 320],
            "walkWidth": 31, "walkHeight": 20, "walkBytes": walk,
            "walkGrid": ["".join("#" if cell & 128 else "." for cell in walk[y * 31:(y + 1) * 31]) for y in range(20)],
            "neighborsEven": [{"dx": -1, "dy": 0, "direction": 2}, {"dx": -1, "dy": -1, "direction": 3},
                              {"dx": 1, "dy": 0, "direction": 1}, {"dx": 1, "dy": -1, "direction": 0}],
            "neighborsOdd": [{"dx": -1, "dy": 1, "direction": 2}, {"dx": -1, "dy": 0, "direction": 3},
                             {"dx": 1, "dy": 1, "direction": 1}, {"dx": 1, "dy": 0, "direction": 0}],
            "source": {"tiles": palace_member.provenance(), "tileBank": tile_member.provenance(),
                       "walkDecodedOffset": 640, "objectsDecodedOffset": 1260}}
    # MAIN palace bank lookup for local map 0 selects original SSCCHR1 bank 8.
    prop_member = Archive((game_dir / "SSCCHR1.R3").read_bytes(), "SSCCHR1.R3").decode(8)
    props, pattern_origins = object_bank(prop_member.data)
    object_images, room_objects = {}, []
    for ordinal in range(palace[1260]):
        at = 1261 + ordinal * 3
        pattern, x, y = palace[at:at + 3]
        if pattern >= len(props):
            raise ResourceError("PMAP0 object references an absent pattern")
        picture = props[pattern]
        if pattern not in object_images:
            object_images[pattern] = write_image(f"prop-8-{pattern}.png", picture, True)
        room_objects.append({"id": f"pmap0-object-{ordinal}", "image": object_images[pattern],
                             "x": x, "y": y, "width": picture.width, "height": picture.height,
                             "anchorX": 0, "anchorY": picture.height - 16,
                             "source": {"resource": "PMAP.R3", "member": 0, "decodedOffset": at,
                                        "ordinal": ordinal, "bank": 8,
                                        "sprite": prop_member.provenance(), "pattern": pattern,
                                        "patternSource": pattern_origins[pattern]}})
    room["objects"] = room_objects

    actor_archive = Archive((game_dir / "SSCCHR2.R3").read_bytes(), "SSCCHR2.R3")
    if len(actor_archive) != 29:
        raise ResourceError("SSCCHR2 does not contain the examined 29 source sprite entries")
    sheets = []
    for sprite in range(len(actor_archive)):
        member = actor_archive.decode(sprite)
        if len(member.data) != 2560:
            raise ResourceError("town sprite member does not hold four 32x40 planar frames")
        sheet = bytearray(128 * 40)
        for frame in range(4):
            picture = planar_image(member.data[frame * 640:(frame + 1) * 640], 32, 40)
            paint(sheet, 128, 40, picture, frame * 32, 0)
        sheets.append((write_image(f"town-{sprite:02}.png", IndexedImage(128, 40, bytes(sheet)), True), member.provenance()))
    people = (game_dir / "BAKDATA.R3").read_bytes()
    if len(people) != 19328:
        raise ResourceError("BAKDATA size is not the examined 384-person layout")
    actors = {}
    for person in range(384):
        offset = 4352 + person * 21
        record = people[offset:offset + 21]
        sprite = record[16]
        if sprite >= len(sheets):
            raise ResourceError(f"person {person} references absent town sprite {sprite}")
        image, source = sheets[sprite]
        try:
            name = record[:6].split(b"\0", 1)[0].decode("cp949")
        except UnicodeDecodeError:
            name = None
        actors[str(person)] = {"image": image, "name": name, "frameWidth": 32, "frameHeight": 40,
                               "frames": 4, "anchorX": 0, "anchorY": 24, "columnStaggerY": 8,
                               "directions": [{"frame": 2, "flip": True}, {"frame": 0, "flip": True},
                                              {"frame": 0, "flip": False}, {"frame": 2, "flip": False}],
                               "portraitIndex": struct.unpack_from("<H", record, 14)[0],
                               "source": {"resource": "BAKDATA.R3", "offset": offset, "bytes": 21,
                                          "spriteByteOffset": offset + 16, "sprite": source}}
    limitations = ["Only the first palace map is exported; other map kinds are unavailable.",
                   "Palace palette slot 2 follows prior research; its exact runtime selection instruction has not been re-established in this implementation.",
                   "Portrait TF-DCE decoding is not implemented in this bounded resource slice; portraits are unavailable."]
    selected_title = title_opgrp if title_opgrp is not None else game_dir / "OPGRP.R3"
    title_data = selected_title.read_bytes()
    title_metadata = {"input": "explicit --title-opgrp" if title_opgrp else "original OPGRP.R3",
                      "bytes": len(title_data), "sha256": digest(title_data)}
    try:
        picture, title_palette, title_source = title_picture(title_data, (game_dir / "OPEN.EXE").read_bytes())
        relative = "images/title.png"
        (output / relative).write_bytes(png_bytes(picture, title_palette))
        title_metadata.update({"available": True, "source": title_source, "indexedPixelSha256": digest(picture.pixels)})
    except ResourceError as error:
        relative = None
        title_metadata.update({"available": False, "reason": str(error)})
        limitations.append("Original title unavailable: " + str(error))
    after = inventory(game_dir)
    if before != after:
        raise ResourceError("original source file inventory/hash changed during extraction")
    result = {"format": 1, "title": relative, "maps": {"8192": room}, "actors": actors, "portraits": {},
              "titleStatus": title_metadata, "limitations": limitations,
              "provenance": {"originalFiles": before, "originalFileCount": len(before),
                             "originalHashesPreserved": True, "originalExecution": False,
                             "implementation": "Independent Python standard-library format readers; no external engine code or converted packs used.",
                             "researchReferences": ["town-motion/evidence.json", "town-motion/static_findings.json",
                                                    "title-screen/source-layout.json", "MAIN.EXE:0x244FA..0x24648", "MAIN.EXE:0x1A9CA..0x1AA61"],
                             "palette": {"resource": "MAIN.EXE", "offset": 0x38DF0 + 2 * 48, "bytes": 48,
                                         "slot": 2, "selectionStatus": "prior-research inference; exact runtime selector not re-established"},
                             "coordinateSystem": {"townTopLeft": "16*x, 16*y-24+8*(x&1)",
                                                  "propTopLeft": "16*x,16*y-height+16", "viewport": [16, 16, 512, 320]}}}
    destination = output / "resources.json"
    temporary = output / ".resources.json.tmp"
    temporary.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(destination)
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--game-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--title-opgrp", type=Path)
    args = parser.parse_args()
    try:
        result = prepare(args.game_dir, args.output, args.title_opgrp)
    except (OSError, ResourceError) as error:
        print(f"resource preparation failed: {error}", file=sys.stderr)
        return 1
    print(json.dumps({"maps": len(result["maps"]), "actors": len(result["actors"]),
                      "mapObjects": len(result["maps"]["8192"]["objects"]),
                      "titleAvailable": result["title"] is not None,
                      "originalFiles": result["provenance"]["originalFileCount"],
                      "originalHashesPreserved": result["provenance"]["originalHashesPreserved"]}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
