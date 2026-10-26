#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Export original town/world maps, source city mappings and palette actor banks.

Outputs are local original-game data, never engine source or public fixtures.
Only source reads and newly written PNG/JSON files occur; no DOS program runs.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import struct
import sys

from prepare_resources import EXAMINED_MAIN, inventory, object_bank, paint, palette_at, town_neighbors
from prepare_scene import read_resource, span
from resource_formats import Archive, IndexedImage, ResourceError, planar_image, png_bytes, settlement_map

DGROUP = 0x37DA0
# SSCCHR1 members holding eight equal world-actor patterns in the examined
# profile. Person field2B values 2..7 select them directly.
WORLD_BANK_MEMBERS = range(2, 8)


def world_layout(payload: bytes, columns: int, rows: int) -> dict:
    """Original MMAP has 16px pictures and a separate 32px packed walk grid."""
    if columns <= 0 or rows <= 0 or columns % 2 or rows % 2 or columns > 256 or rows > 256:
        raise ResourceError("world dimensions must be positive even source tile counts")
    pictures, cells = columns * rows, columns // 2 * (rows // 2)
    if cells % 8 or len(payload) != pictures + cells // 8:
        raise ResourceError("world tile and MSB walk spans do not cover their source member")
    packed = payload[pictures:]
    walk = [0x80 if packed[n >> 3] & (0x80 >> (n & 7)) else 0 for n in range(cells)]
    return {"tiles": list(payload[:pictures]), "walkBits": list(packed), "walkBytes": walk,
            "walkWidth": columns // 2, "walkHeight": rows // 2,
            "walkGrid": ["".join("#" if value else "." for value in walk[y * (columns // 2):(y + 1) * (columns // 2)])
                         for y in range(rows // 2)]}


def chapter_mappings(main: bytes, cities: bytes) -> tuple[list[dict], list[dict], dict[int, tuple[int, int]]]:
    if len(cities) != 4 * 0x380:
        raise ResourceError("BBKSDAT1 does not have four source city groups")
    chapter_groups = span(main, DGROUP + 0x0EBC, 5, "chapter city-group table")
    counts = span(main, DGROUP + 0x1360, 4, "city group counts")
    bases = span(main, DGROUP + 0x1366, 4, "city group bases")
    entries = struct.unpack("<5H", span(main, DGROUP + 0x2F9C, 10, "chapter world-map entries"))
    dimensions = span(main, DGROUP + 0x2F06, 10, "chapter world dimension byte pairs")
    mapping, city_records, member_dimensions = [], [], {}
    for chapter, group in enumerate(chapter_groups):
        if group >= len(counts) or counts[group] > 32 or entries[chapter] >= 4:
            raise ResourceError("chapter mapping references an absent source city group or world member")
        count, base = counts[group], bases[group]
        width, height = dimensions[chapter * 2:chapter * 2 + 2]
        index = entries[chapter]
        if index in member_dimensions and member_dimensions[index] != (width, height):
            raise ResourceError("chapter aliases disagree about a world member's dimensions")
        member_dimensions[index] = width, height
        mapping.append({"chapter": chapter, "cityGroup": group, "cityCount": count,
                        "cityBase": base, "worldMapKey": f"world:{index}",
                        "worldPictureColumns": width, "worldPictureRows": height,
                        "source": {"resource": "MAIN.EXE", "cityGroupOffset": DGROUP + 0x0EBC + chapter,
                                   "countOffset": DGROUP + 0x1360 + group, "baseOffset": DGROUP + 0x1366 + group,
                                   "worldEntryOffset": DGROUP + 0x2F9C + chapter * 2,
                                   "worldDimensionsOffset": DGROUP + 0x2F06 + chapter * 2}})
        for city in range(count):
            global_index = base + city
            xy_at = DGROUP + 0x136C + global_index * 2
            town_at = DGROUP + 0x1408 + global_index
            x, y = span(main, xy_at, 2, "source city world position")
            town = span(main, town_at, 1, "source city town-map index")[0]
            placed = (x, y) != (255, 255)
            if town >= 12 or (placed and (x >= width // 2 or y >= height // 2)):
                raise ResourceError("city map or world coordinate exceeds its selected source map")
            constant_at = group * 0x380 + city * 23
            state_at = group * 0x380 + 32 * 23 + city * 5
            constant = cities[constant_at:constant_at + 23]
            try:
                name = constant[:8].split(b"\0", 1)[0].decode("cp949", errors="strict")
            except UnicodeDecodeError as error:
                raise ResourceError("city name is not valid source Korean text") from error
            city_records.append({"chapter": chapter, "id": city, "name": name, "cityGroup": group,
                                 "sourceCityType":constant[22],
                                 "worldX": x if placed else None, "worldY": y if placed else None,
                                 "worldPositionKnown": placed, "rawWorldX": x, "rawWorldY": y,
                                 "worldMapKey": f"world:{index}",
                                 "townMapKey": f"town:{town}", "townMapIndex": town,
                                 "source": {"resource": "BBKSDAT1.R3", "constantOffset": constant_at,
                                            "constantBytes": constant.hex(), "stateOffset": state_at,
                                            "cityTypeOffset":constant_at+22,
                                            "stateBytes": cities[state_at:state_at + 5].hex(),
                                            "worldPosition": {"resource": "MAIN.EXE", "offset": xy_at, "length": 2},
                                            "townMapSelector": {"resource": "MAIN.EXE", "offset": town_at, "length": 1},
                                            "constructor": "MAIN.EXE:0x1AF7A..0x1B039"}})
    return mapping, city_records, member_dimensions


def prepare(game: Path, output: Path) -> dict:
    game, output = game.resolve(), output.resolve()
    if output == game or game in output.parents:
        raise ResourceError("exploration output must be outside the original game directory")
    before = inventory(game)
    selected = {name: read_resource(game, name) for name in
                ("MAIN.EXE", "BAKDATA.R3", "BBKSDAT1.R3", "SMAP.R3", "MMAP.R3",
                 "SMAPBGPL.R3", "MMAPBGPL.R3", "SSCCHR1.R3", "SSCCHR2.R3")}
    main, main_source = selected["MAIN.EXE"]
    if hashlib.sha256(main).hexdigest() != EXAMINED_MAIN:
        raise ResourceError("MAIN does not match the examined original exploration profile")
    output.mkdir(parents=True, exist_ok=True)
    palettes = {slot: palette_at(main, 0x38DF0 + slot * 48) for slot in (0, 1)}

    def write(name: str, picture: IndexedImage, slot: int, alpha=False) -> str:
        relative = f"images/exploration/{name}.png"
        destination = output / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(png_bytes(picture, palettes[slot], transparent_zero=alpha))
        return relative

    chapters, cities, dimensions = chapter_mappings(main, selected["BBKSDAT1.R3"][0])
    maps, actors = [], {"town": {}, "world": {}}
    props_archive = Archive(selected["SSCCHR1.R3"][0], "SSCCHR1.R3")
    tile_member = Archive(selected["SMAPBGPL.R3"][0], "SMAPBGPL.R3").decode(0)
    if len(tile_member.data) % 128:
        raise ResourceError("town background bank contains a partial planar cell")
    tiles = [planar_image(tile_member.data[at:at + 128], 16, 16) for at in range(0, len(tile_member.data), 128)]
    town_props = props_archive.decode(0)
    prop_pictures, prop_sources = object_bank(town_props.data)
    prop_images = [write(f"town-prop-{index}", picture, 0, True) for index, picture in enumerate(prop_pictures)]
    towns = Archive(selected["SMAP.R3"][0], "SMAP.R3")
    if len(towns) != 12:
        raise ResourceError("SMAP source does not contain the examined twelve town maps")
    for index in range(len(towns)):
        member = towns.decode(index)
        layout = settlement_map(member.data)
        canvas = bytearray(512 * 320)
        for at, tile in enumerate(layout.background_tiles):
            if tile >= len(tiles):
                raise ResourceError("town map references an absent source background cell")
            paint(canvas, 512, 320, tiles[tile], at % 32 * 16, at // 32 * 16)
        objects = []
        for ordinal, (pattern, x, y) in enumerate(layout.objects):
            if pattern >= len(prop_pictures):
                raise ResourceError("town prop references an absent source pattern")
            picture = prop_pictures[pattern]
            objects.append({"id": f"town{index}-object-{ordinal}", "image": prop_images[pattern],
                            "x": x, "y": y, "width": picture.width, "height": picture.height,
                            "anchorX": 0, "anchorY": picture.height - 16,
                            "source": {**member.provenance(), "decodedOffset": 1261 + ordinal * 3,
                                       "bank": 0, "pattern": pattern, "patternSource": prop_sources[pattern]}})
        walk = list(layout.walk_cells)
        maps.append({"key": f"town:{index}", "kind": "town", "sourceIndex": index,
                     "image": write(f"town-map-{index}", IndexedImage(512, 320, bytes(canvas)), 0),
                     "width": 512, "height": 320, "pictureColumns": 32, "pictureRows": 20,
                     "walkWidth": 31, "walkHeight": 20, "walkBytes": walk,
                     "walkGrid": ["".join("#" if value & 128 else "." for value in walk[y * 31:(y + 1) * 31]) for y in range(20)],
                     **town_neighbors(),
                     "viewport": [16, 16, 512, 320], "paletteSlot": 0, "objects": objects,
                     "destinations": [{"marker": marker, "x": x, "y": y,
                                        "source": {**member.provenance(), "decodedOffset": 640 + y * 31 + x,
                                                   "meaning": "literal source walk marker; built-in destination behavior is separate"}}
                                       for marker, x, y in layout.walk_markers],
                     "geometry": {"coordinateSystem": "staggered", "grid": [16, 16], "columnStaggerY": 8,
                                  "actorAnchor": [0, 24], "walkBlockedMask": 128},
                     "source": {"map": member.provenance(), "tileBank": tile_member.provenance(),
                                "propBank": town_props.provenance(), "walkDecodedOffset": 640,
                                "objectsDecodedOffset": 1260, "loader": "MAIN.EXE:0x244FA..0x24790"}})

    world_tile_archive = Archive(selected["MMAPBGPL.R3"][0], "MMAPBGPL.R3")
    if len(world_tile_archive) != 1:
        raise ResourceError("world background source must have one planar bank")
    world_tile_member = world_tile_archive.decode(0)
    world_tiles_raw = world_tile_member.data
    if len(world_tiles_raw) != 255 * 128:
        raise ResourceError("world background bank is not the examined 255 planar cells")
    world_tiles = [planar_image(world_tiles_raw[at:at + 128], 16, 16) for at in range(0, len(world_tiles_raw), 128)]
    worlds = Archive(selected["MMAP.R3"][0], "MMAP.R3")
    if len(worlds) != 4 or set(dimensions) != set(range(4)):
        raise ResourceError("world member coverage differs from the source chapter mappings")
    for index in range(len(worlds)):
        member = worlds.decode(index)
        columns, rows = dimensions[index]
        layout = world_layout(member.data, columns, rows)
        width, height = columns * 16, rows * 16
        canvas = bytearray(width * height)
        for at, tile in enumerate(layout["tiles"]):
            if tile >= len(world_tiles):
                raise ResourceError("world map references an absent source background cell")
            paint(canvas, width, height, world_tiles[tile], at % columns * 16, at // columns * 16)
        maps.append({"key": f"world:{index}", "kind": "world", "sourceIndex": index,
                     "image": write(f"world-map-{index}", IndexedImage(width, height, bytes(canvas)), 1),
                     "width": width, "height": height, "pictureColumns": columns, "pictureRows": rows,
                     "walkWidth": layout["walkWidth"], "walkHeight": layout["walkHeight"],
                     "walkBytes": layout["walkBytes"], "walkBits": layout["walkBits"], "walkGrid": layout["walkGrid"],
                     "viewport": [16, 16, 512, 320], "paletteSlot": 1, "objects": [],
                     "geometry": {"coordinateSystem": "orthogonal", "grid": [32, 32], "columnStaggerY": 0,
                                  "runtimeGrid": [16, 16], "halfstepsPerGridStep": 2,
                                  "walkBlockedMask": 128, "walkBitOrder": "MSB first; zero is passable"},
                     "source": {"map": member.provenance(), "tileBank": world_tile_member.provenance(),
                                "walkDecodedOffset": columns * rows, "loader": "MAIN.EXE:0x21D6C..0x21E30"}})

    town_sprites = Archive(selected["SSCCHR2.R3"][0], "SSCCHR2.R3")
    if len(town_sprites) != 29:
        raise ResourceError("town sprite source count differs from the examined profile")
    town_images = []
    for index in range(len(town_sprites)):
        member = town_sprites.decode(index)
        if len(member.data) != 4 * 640:
            raise ResourceError("town actor does not contain four original 32x40 frames")
        canvas = bytearray(128 * 40)
        for frame in range(4):
            paint(canvas, 128, 40, planar_image(member.data[frame * 640:(frame + 1) * 640], 32, 40), frame * 32, 0)
        town_images.append((write(f"town-actor-{index}", IndexedImage(128, 40, bytes(canvas)), 0, True), member.provenance()))
    people = selected["BAKDATA.R3"][0]
    if len(people) != 19328:
        raise ResourceError("initial actor references differ from the examined BAKDATA layout")
    people_banks = []
    for person in range(384):
        constant_at, state_at = 0x1100 + person * 21, 0x3080 + person * 18
        sprite, role = people[constant_at + 16], people[state_at + 1]
        # MAIN 1AAEE..1AAF3 constructs person field 2B as state byte one plus
        # two. World actors load SSCCHR1 member field2B (MAIN 1FC24, 189A4,
        # 18448..1847D); script opcode 2F writes the same field directly.
        bank = (role + 2) & 0xFF
        if sprite >= len(town_images) or bank not in WORLD_BANK_MEMBERS:
            raise ResourceError("person references an absent source actor bank")
        image, source = town_images[sprite]
        actors["town"][str(person)] = {"image": image, "frameWidth": 32, "frameHeight": 40, "frames": 4,
                                       "anchorX": 0, "anchorY": 24,
                                       "directions": [{"frame": 2, "flip": True}, {"frame": 0, "flip": True},
                                                      {"frame": 0, "flip": False}, {"frame": 2, "flip": False}],
                                       "source": source}
        people_banks.append({"person": person, "townSprite": sprite, "worldRole": role, "worldBank": bank,
                             "source": {"resource": "BAKDATA.R3", "townSpriteOffset": constant_at + 16,
                                        "worldRoleOffset": state_at + 1,
                                        "worldBankConstructor": "MAIN.EXE:0x1AAEE..0x1AAF3"}})
    for bank in WORLD_BANK_MEMBERS:
        member = props_archive.decode(bank)
        pictures, pattern_sources = object_bank(member.data)
        if len(pictures) != 8 or len({(picture.width, picture.height) for picture in pictures}) != 1:
            raise ResourceError("world actor role does not contain eight equal-geometry source patterns")
        width, height = pictures[0].width, pictures[0].height
        canvas = bytearray(width * 8 * height)
        for frame, picture in enumerate(pictures):
            paint(canvas, width * 8, height, picture, frame * width, 0)
        actors["world"][str(bank)] = {"image": write(f"world-bank-{bank}", IndexedImage(width * 8, height, bytes(canvas)), 1, True),
                                      "frameWidth": width, "frameHeight": height, "frames": 8,
                                      "anchorX": 0, "anchorY": height - 32, "flip": False,
                                      "source": {**member.provenance(), "patterns": pattern_sources,
                                                 "selection": "SSCCHR1 member = person field2B; MAIN.EXE:0x1FC00..0x1FC54, 0x18942..0x189AE, 0x18448..0x1847D",
                                                 "draw": "MAIN.EXE:0x2228C..0x2238C"}}
    dx = struct.unpack("<8h", span(main, DGROUP + 0x2F1C, 16, "world x neighbors"))
    dy = struct.unpack("<8h", span(main, DGROUP + 0x2F2C, 16, "world y neighbors"))
    frames = list(span(main, DGROUP + 0x2FA6, 8, "world direction base patterns"))
    placement_directions = list(struct.unpack("<8H",span(main,DGROUP+0x2EE6,16,"world placement direction conversion")))
    if set(placement_directions) != set(range(8)):
        raise ResourceError("world placement direction conversion is not the examined eight-direction domain")
    if any(abs(x) > 1 or abs(y) > 1 or (x == 0 and y == 0) for x, y in zip(dx, dy)) or any(frame > 6 for frame in frames):
        raise ResourceError("world direction tables exceed the examined geometry")
    if inventory(game) != before:
        raise ResourceError("original file hashes changed during exploration export")
    result = {"format": 2, "worldBankKey": "person-field-2B", "maps": maps, "chapterMappings": chapters, "cities": cities,
              "actorBanks": actors, "peopleBanks": people_banks,
              "worldNeighbors": [{"dx": x, "dy": y, "direction": index} for index, (x, y) in enumerate(zip(dx, dy))],
              "worldDirectionFrames": frames,
              "worldPlacementDirections":placement_directions,
              "source": {"inputs": [item[1] for item in selected.values()], "originalHashesPreserved": True,
                         "originalProgramsExecuted": False,
                         "palettes": [{"resource": "MAIN.EXE", "offset": 0x38DF0 + slot * 48, "bytes": 48, "slot": slot} for slot in (0, 1)],
                         "directionTables": {"resource": "MAIN.EXE", "xOffset": DGROUP + 0x2F1C,
                                             "yOffset": DGROUP + 0x2F2C, "frameOffset": DGROUP + 0x2FA6,
                                             "placementOffset":DGROUP+0x2EE6,"placementWords":8}},
              "limitations": ["Static source extraction does not establish native exploration or full campaign parity.",
                              "Default town/world palettes are exported; grayscale and dynamic palette changes remain unsupported.",
                              "World bank keys are SSCCHR1 members selected by person field2B; peopleBanks keep raw BAKDATA state byte one separately.",
                              "Non-person world actors use SSCCHR1 member three in the source allocator; script placement here covers person actors only.",
                              "City scripts, citizens, interactive destinations and shop flows require their own source execution models."]}
    temporary = output / ".exploration.json.tmp"
    temporary.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(output / "exploration.json")
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--game-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        result = prepare(args.game_dir, args.output)
    except (OSError, ValueError) as error:
        print(f"exploration preparation failed: {error}", file=sys.stderr)
        return 1
    print(json.dumps({"maps": len(result["maps"]), "townMaps": 12, "worldMaps": 4,
                      "chapterMappings": len(result["chapterMappings"]), "cities": len(result["cities"]),
                      "worldActorRoles": len(result["actorBanks"]["world"]), "originalHashesPreserved": True}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
