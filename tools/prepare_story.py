#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Export original PACKGRP pictures and source story-panel layout facts locally."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import struct
import sys

from prepare_resources import EXAMINED_MAIN, inventory, palette_at
from prepare_scene import read_resource
from resource_formats import Archive, ResourceError, planar_image, png_bytes
from tf_dce import dce_picture

EXAMINED_TFDED = "57db61a49d4a1ca525d14aca210457c57ec2c2caf04d58b99f4a51e053762371"


def picture_directory(data: bytes, count: int) -> list[tuple[int, int]]:
    if count <= 0 or len(data) < count * 6:
        raise ResourceError("packed picture directory is truncated")
    header = count * 6
    result, expected = [], header
    for index in range(count):
        relative, size = struct.unpack_from("<IH", data, index * 6)
        start = header + relative
        if not size or start != expected or start + size > len(data):
            raise ResourceError("packed picture spans do not cover an ordered, bounded source stream")
        result.append((start, start + size))
        expected = start + size
    if expected != len(data):
        raise ResourceError("packed picture resource has unowned trailing bytes")
    return result


# Field screen routine CF5:C456 (MAIN 1FDA6..1FE2C) and battle screen routine
# (1FE2E..1FE69). HUD writers share one shape: clear rect, then text cursor.
FIELD_FRAME_CALL, BATTLE_FRAME_CALL, PORTRAIT_CALL = 0x1FDB1, 0x1FE39, 0x1FE15
HUD_FIELDS = {"caption": 0x1FC5E, "money": 0x1FCB2, "level": 0x1FCEA, "territory": 0x1FD24}
HUD_SOURCES = {"caption": "MAIN.EXE:0x1FC5E..0x1FC8E; DS:DB4C via CF5:C340 (source0B)",
               "money": "MAIN.EXE:0x1FCB2..0x1FCE8; player7A80+0 via CF5:220A",
               "level": "MAIN.EXE:0x1FCEA..0x1FD22; person0 (DS:7A94) +21 via CF5:7572",
               "territory": "MAIN.EXE:0x1FD24..0x1FD62; city player7A80+10 via CF5:210E/2118"}
HUD_FORMATS = {"caption": "%s", "money": "%5u", "level": "%4u", "territory": "%6s"}


def hud_field(main: bytes, at: int) -> dict:
    """push h; push color; mov ax,x; mov dx,y; mov bx,w; call CF5:52EE;
    push column; push y; push 6390; call CF5:091E (MAIN text cursor)."""
    code = main[at:at + 31]
    if len(code) != 31 or (code[0], code[2], code[4], code[7], code[10], code[13], code[18], code[20], code[23]) != \
            (0x6A, 0x6A, 0xB8, 0xBA, 0xBB, 0x9A, 0x6A, 0x68, 0x68) or \
            struct.unpack_from("<HH", code, 14) != (0x52EE, 0x0CF5) or struct.unpack_from("<H", code, 24)[0] != 0x6390 or \
            code[26] != 0x9A or struct.unpack_from("<HH", code, 27) != (0x091E, 0x0CF5):
        raise ResourceError(f"MAIN HUD writer at {at:#x} does not match the examined profile")
    x, y, width = (struct.unpack_from("<H", code, offset)[0] for offset in (5, 8, 11))
    column, text_y = code[19], struct.unpack_from("<H", code, 21)[0]
    if text_y != y:
        raise ResourceError(f"MAIN HUD writer at {at:#x} prints outside its cleared row")
    return {"rect": [x, y, width, code[1]], "clearColor": code[3], "text": [column * 8, text_y]}


def screen_facts(main: bytes) -> dict:
    if main[FIELD_FRAME_CALL:FIELD_FRAME_CALL + 7] != bytes([0x33, 0xC0, 0x9A]) + struct.pack("<HH", 0x520E, 0x0CF5) or \
            main[BATTLE_FRAME_CALL:BATTLE_FRAME_CALL + 8] != bytes([0xB8, 1, 0, 0x9A]) + struct.pack("<HH", 0x520E, 0x0CF5):
        raise ResourceError("MAIN screen frame selectors do not match the examined profile")
    portrait = main[PORTRAIT_CALL:PORTRAIT_CALL + 13]
    if (portrait[0], portrait[3], portrait[6], portrait[7], portrait[8]) != (0xB8, 0xBA, 0x33, 0xDB, 0x9A) or \
            struct.unpack_from("<HH", portrait, 9) != (0x51B2, 0x0CF5):
        raise ResourceError("MAIN field portrait call does not match the examined profile")
    hud = {}
    for name, at in HUD_FIELDS.items():
        hud[name] = {**hud_field(main, at), "format": HUD_FORMATS[name], "textColor": 7, "source": HUD_SOURCES[name]}
    hud["portrait"] = {"rect": [struct.unpack_from("<H", portrait, 1)[0], struct.unpack_from("<H", portrait, 4)[0], 64, 80],
                       "portraitID": 0, "source": "MAIN.EXE:0x1FE15..0x1FE21, CF5:51B2 (0x18B02..)"}
    return {"field": {"frameAsset": 0, "viewport": [16, 16, 512, 320], "hud": hud,
                      "source": "MAIN.EXE:0x1FDA6..0x1FE2C (CF5:C456), PACKGRP member0 via CF5:520E"},
            "battle": {"frameAsset": 1, "source": "MAIN.EXE:0x1FE2E..0x1FE69, PACKGRP member1 via CF5:520E"},
            "limitations": ["Layout coordinates come from MAIN immediates; the original font and text colors are not restored.",
                            "Window frames for dialogue and selectors are drawn by other primitives and are not part of these facts."]}


def prepare(game: Path, output: Path) -> dict:
    game, output = game.resolve(), output.resolve()
    if output == game or game in output.parents:
        raise ResourceError("story output must be outside the selected original directory")
    before = inventory(game)
    selected = {name: read_resource(game, name) for name in ("MAIN.EXE", "TFDED.COM", "PACKGRP.R3", "FACEDAT.R3", "MARK.R3")}
    main = selected["MAIN.EXE"][0]
    if hashlib.sha256(main).hexdigest() != EXAMINED_MAIN:
        raise ResourceError("MAIN does not match the examined original story layout")
    if hashlib.sha256(selected["TFDED.COM"][0]).hexdigest() != EXAMINED_TFDED:
        raise ResourceError("TFDED does not match the statically examined TF-DCE decoder")
    palettes = {index: palette_at(main, 0x38DF0 + index * 48) for index in range(4)}

    def export_pictures(resource: str, count: int, prefix: str) -> list[dict]:
        data = selected[resource][0]
        result = []
        for index, (start, end) in enumerate(picture_directory(data, count)):
            picture, metadata = dce_picture(data[start:end], zero_base=True)
            images = {}
            for palette, colors in palettes.items():
                relative = f"images/story/{prefix}-{index}-palette-{palette}.png"
                target = output / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(png_bytes(picture, colors))
                images[str(palette)] = relative
            result.append({"id": index, "image": images["0"], "width": picture.width,
                           "height": picture.height, "palette": 0, "imagesByPalette": images,
                           "source": {"resource": resource, "directoryOffset": index * 6,
                                      "offset": start, "length": end - start,
                                      "sha256": hashlib.sha256(data[start:end]).hexdigest(),
                                      "indexedPixelSha256": hashlib.sha256(picture.pixels).hexdigest(),
                                      "decoder": metadata}})
        return result

    assets = export_pictures("PACKGRP.R3", 38, "pack")
    portraits = export_pictures("FACEDAT.R3", 240, "portrait")
    mark = Archive(selected["MARK.R3"][0], "MARK.R3").decode(0)
    buttons = []
    for value, label, offset in [(1, "Yes", 0x1BD0), (0, "No", 0x1DB0)]:
        picture = planar_image(mark.data[offset:offset + 480], 48, 20, interleaved=True)
        images = {}
        for palette, colors in palettes.items():
            relative = f"images/story/choice-{value}-palette-{palette}.png"
            target = output / relative
            target.write_bytes(png_bytes(picture, colors))
            images[str(palette)] = relative
        buttons.append({"value": value, "label": label, "image": images["0"],
                        "width": 48, "height": 20, "palette": 0, "imagesByPalette": images,
                        "source": {**mark.provenance(), "decodedOffset": offset, "length": 480,
                                   "selector": "MAIN.EXE:0x164A9..0x165C4",
                                   "buttonPattern": "MAIN.EXE:0x15546..0x15579"}})
    layouts = []
    for mode in (0, 1):
        layouts.append({"mode": mode, "clearRect": [16, 16, 512, 320] if mode == 0 else None,
                        "panelRect": [152, 32, 240, 160], "pictureRect": [160, 40, 224, 144],
                        "offscreenPanelRect": [152, 472, 240, 160], "offscreenPictureOrigin": [160, 480],
                        "savedUnderlayRects": [[152, 32, 240, 76], [152, 108, 240, 76], [152, 184, 240, 8]],
                        "frameAsset": None,
                        "frameStatus": "source window650C primitives; PACKGRP0 is not selected by opcode07",
                        "lifetime": "keep across consecutive opcode08; restore saved underlay before first non08",
                        "transition": {"patterns": 32, "timingRestored": False},
                        "source": {"resource": "MAIN.EXE", "start": 0x206A8, "endExclusive": 0x207C8,
                                   "closeStart": 0x207C8, "interpreterLifetime": "0x1C1CF..0x1C1DF"}})
    if inventory(game) != before:
        raise ResourceError("original files changed during story extraction")
    screens = screen_facts(main)
    result = {"format": 1, "assets": assets, "portraitAssets": portraits, "choiceButtons": buttons, "layouts": layouts,
              "screens": screens,
              "source": {"inputs": [item[1] for item in selected.values()], "originalHashesPreserved": True,
                         "originalProgramsExecuted": False, "loader": "MAIN.EXE:0x18B5E..0x18C21",
                         "portraitLoader": "MAIN.EXE:0x18A3C..0x18B00",
                         "decoder": "TFDED.COM load addresses0x018C..0x0686; file offsets are load minus0x100",
                         "palettes": [{"resource": "MAIN.EXE", "offset": 0x38DF0 + index * 48,
                                       "length": 48, "slot": index} for index in palettes]},
              "limitations": ["All decoded images use an explicit zero-plane drawing base; source preserved-plane metadata is retained.",
                              "The opcode07 window-frame primitive pixels and original transition timing are not restored by this exporter.",
                              "Palette variants are retained separately; the native source context chooses its current palette.",
                              "Static full payload consumption is not a DOS framebuffer parity measurement."]}
    output.mkdir(parents=True, exist_ok=True)
    temporary = output / ".story.json.tmp"
    temporary.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(output / "story.json")
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--game-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        result = prepare(args.game_dir, args.output)
    except (OSError, ValueError) as error:
        print(f"story preparation failed: {error}", file=sys.stderr)
        return 1
    print(json.dumps({"pictures": len(result["assets"]), "portraits": len(result["portraitAssets"]), "layouts": len(result["layouts"]),
                      "paletteVariants": 4, "originalHashesPreserved": True}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
