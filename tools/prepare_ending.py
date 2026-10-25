#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Export the statically restored opening of the original ending, locally only.

The remaining END program is an explicit frontier, not a guessed slideshow.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import struct
import sys

from prepare_resources import EXAMINED_MAIN, inventory, palette_at
from prepare_scene import read_resource, text_at
from resource_formats import Archive, IndexedImage, ResourceError, planar_image, png_bytes, npk_picture

EXAMINED_END = "6a961179ee3b34d869ed3031523d616d79f1d863d61f4f4f6af8cebd1fe8dc77"
END_DGROUP = 0xCE40


def mask_opacity(data: bytes, width: int, height: int) -> bytes:
    """END's one-bit AND mask preserves destination for a set bit."""
    if width <= 0 or width % 8 or height <= 0 or len(data) != width * height // 8:
        raise ResourceError("ending mask dimensions do not own exactly its source bytes")
    return bytes(0 if value & (128 >> bit) else 255 for value in data for bit in range(8))


def source_lines(data: bytes, table: int, maximum: int = 256) -> list[dict]:
    result = []
    for index in range(maximum):
        where = END_DGROUP + table + index * 2
        if where + 2 > len(data):
            raise ResourceError("ending text pointer list is truncated")
        pointer = struct.unpack_from("<H", data, where)[0]
        if pointer == 0:
            if not result:
                raise ResourceError("ending text pointer list is empty")
            return result
        offset = END_DGROUP + pointer
        value, end = text_at(data, offset, len(data), "END.EXE")
        result.append({"text": value, "sourceByteLength": end - offset - 1,
                       "source": {"resource": "END.EXE", "pointerOffset": where,
                                  "offset": offset, "length": end - offset}})
    raise ResourceError("ending text pointer list has no bounded terminator")


def opening_frames(lines: list[dict]) -> list[dict]:
    # END 49BB initializes counter=-1, frame=1, x=364. Each iteration
    # increments counter, advances two-line text every six iterations, x-=4,
    # and toggles the frame. It exits only after the frame at x236.
    if len(lines) != 12:
        raise ResourceError("examined ending opening requires twelve source text lines")
    width_bytes = max(line["sourceByteLength"] for line in lines) + 2
    text_x = (((80 - width_bytes) * 8) // 2) & ~7
    if not 0 < width_bytes <= 256 or text_x + width_bytes * 8 <= 0 or text_x >= 640:
        raise ResourceError("ending caption has no bounded visible source span")
    def frame(x: int, pose: int, ticks: int, chunk: int | None, start: int, end: int) -> dict:
        return {"sourceTicks": ticks, "layers": [
                    {"asset": "end1-19", "x": 48, "y": 104},
                    {"asset": f"end1-20-frame-{pose}", "x": x, "y": 120}],
                "caption": None if chunk is None else {
                    "asset": f"end1-caption-{chunk}",
                    "lines": [line["text"] for line in lines[chunk * 2:chunk * 2 + 2]],
                    "x": text_x, "y": 288, "width": width_bytes * 8, "height": 40,
                    "lineHeight": 20, "sourceChunk": chunk},
                "source": {"resource": "END.EXE", "start": start, "endExclusive": end}}
    # Source waits happen BEFORE the newly prepared frame is copied to VRAM.
    # The first motion therefore commits at deadline200+125, not at200.
    frames = [frame(368, 0, 325, None, 0x47D4, 0x49AD)]
    frames += [frame(360 - iteration * 4, iteration % 2, 125 if iteration < 31 else 100,
                     iteration // 6, 0x49BB, 0x4B7D if iteration < 31 else 0x4B9A)
               for iteration in range(32)]
    return frames


def caption_picture(lines: list[bytes], width_bytes: int, korean: bytes, ascii_font: bytes) -> tuple[IndexedImage, bytes]:
    """END 8C96 builds a 20px-line mono bitmap, with one-byte left padding.

    Hangul records contain a two-byte identity and fourteen two-byte rows.
    ASCII uses sixteen one-byte rows. Both gain one right-hand bold pixel.
    """
    if not lines or not 0 < width_bytes <= 256 or len(korean) % 30 or len(ascii_font) != 96 * 16:
        raise ResourceError("ending font/bitmap bounds are invalid")
    rows = bytearray(width_bytes * len(lines) * 20)
    for line_index, line in enumerate(lines):
        cursor, column = 0, 1
        while cursor < len(line):
            high = line[cursor]
            if high >= 0xA1:
                if cursor + 1 >= len(line):
                    raise ResourceError("ending Korean text ends inside a source code pair")
                low = line[cursor + 1]
                value = (high << 8) | low
                if not 0xA1A1 <= value <= 0xFDFE:
                    raise ResourceError("ending Korean source code has no restored glyph")
                glyph_index = (high - (0xA4 if high >= 0xB0 else 0xA1)) * 94 + low - 0xA1
                offset = glyph_index * 30 + 2
                if offset < 2 or offset + 28 > len(korean):
                    raise ResourceError("ending Korean glyph seek is outside the caller's font")
                glyph = korean[offset:offset + 28] + bytes(4)
                cell_width, cursor = 2, cursor + 2
            else:
                glyph_index = high - 0x20 if 0x20 <= high <= 0x7F else 0
                glyph = ascii_font[glyph_index * 16:(glyph_index + 1) * 16]
                cell_width, cursor = 1, cursor + 1
            if column + cell_width >= width_bytes:
                raise ResourceError("ending glyph would exceed its source bitmap row")
            for y in range(16):
                bits = int.from_bytes(glyph[y * cell_width:(y + 1) * cell_width], "big") << 8
                expanded = (bits | (bits >> 1)).to_bytes(cell_width + 1, "big")
                for x, value in enumerate(expanded):
                    rows[(line_index * 20 + y) * width_bytes + column + x] |= value
            column += cell_width
    opacity = bytes(255 if value & (128 >> bit) else 0 for value in rows for bit in range(8))
    return IndexedImage(width_bytes * 8, len(lines) * 20, bytes(7 if alpha else 0 for alpha in opacity)), opacity


def prepare(game: Path, output: Path) -> dict:
    game, output = game.resolve(), output.resolve()
    if output == game or game in output.parents:
        raise ResourceError("ending output must be outside the selected original directory")
    before = inventory(game)
    selected = {name: read_resource(game, name) for name in ("MAIN.EXE", "END.EXE", "END1GRP.R3", "END2GRP.R3", "ALL_FONT.16P", "HANKAKU.FNT")}
    main, ending = selected["MAIN.EXE"][0], selected["END.EXE"][0]
    if hashlib.sha256(main).hexdigest() != EXAMINED_MAIN or hashlib.sha256(ending).hexdigest() != EXAMINED_END:
        raise ResourceError("ending executable profile differs from the statically examined source")
    archive = Archive(selected["END1GRP.R3"][0], "END1GRP.R3")
    if len(archive) != 72 or len(Archive(selected["END2GRP.R3"][0], "END2GRP.R3")) != 25:
        raise ResourceError("ending archive counts differ from the examined source")
    colors = palette_at(ending, END_DGROUP + 0x848)
    background, poses, masks = archive.decode(19), archive.decode(20), archive.decode(1)
    picture = npk_picture(background.data)
    if (picture.width, picture.height) != (544, 176) or len(poses.data) != 35840 or len(masks.data) != 8960:
        raise ResourceError("ending opening resource dimensions differ from the source blit operands")
    assets = []
    def save(identifier, image, provenance, opacity=None):
        relative = f"images/ending/{identifier}.png"
        target = output / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(png_bytes(image, colors, opacity=opacity))
        assets.append({"id": identifier, "image": relative, "width": image.width, "height": image.height,
                       "source": provenance})
    save("end1-19", picture, background.provenance())
    for index in range(2):
        pose = planar_image(poses.data[index * 17920:(index + 1) * 17920], 224, 160, interleaved=True)
        mask = masks.data[index * 4480:(index + 1) * 4480]
        save(f"end1-20-frame-{index}", pose,
             {"color": {**poses.provenance(), "decodedOffset": index * 17920, "decodedLength": 17920},
              "mask": {**masks.provenance(), "decodedOffset": index * 4480, "decodedLength": 4480},
              "blitSource": "END.EXE:0x4832..0x4895;0x4A20..0x4AAB"}, mask_opacity(mask, 224, 160))
    lines = source_lines(ending, 0x11B6)
    frames = opening_frames(lines)
    width_bytes = max(line["sourceByteLength"] for line in lines) + 2
    for chunk in range(6):
        source = lines[chunk * 2:chunk * 2 + 2]
        raw_lines = [ending[line["source"]["offset"]:line["source"]["offset"] + line["sourceByteLength"]] for line in source]
        image, opacity = caption_picture(raw_lines, width_bytes, selected["ALL_FONT.16P"][0], selected["HANKAKU.FNT"][0])
        save(f"end1-caption-{chunk}", image, {"lines": source, "bitmapProducer": "END.EXE:0xA24C..0xA52B"}, opacity)
    digest_input = [(name, selected[name][1]["sha256"]) for name in sorted(selected)]
    digest = hashlib.sha256(json.dumps(digest_input, separators=(",", ":")).encode()).hexdigest()
    result = {"format": 1, "sourceDigest": digest, "canvas": [640, 400], "sourceTicksPerSecond": 100, "assets": assets,
              "selections": [{"value": value, "program": "end1-opening", "complete": False} for value in (0, 1)],
              "programs": [{"id": "end1-opening", "frames": frames, "complete": False,
                            "frontier": {"resource": "END.EXE", "offset": 0x4B9A,
                                         "reason": "next source scene, including fade and members22/23, has not been restored"}}],
              "textLines": lines,
              "source": {"inputs": [item[1] for item in selected.values()], "originalHashesPreserved": True,
                         "originalProgramsExecuted": False, "selectionProducer": "MAIN.EXE:0x1D176..0x1D196",
                         "selectionTransport": "framework INT65 AX0400/0401, not a direct graphics loader",
                         "endingDispatch": "END.EXE:0x4667..0x4709; value3 selects END2GRP, values0/1 select END1GRP",
                         "palette": {"resource": "END.EXE", "offset": END_DGROUP + 0x848, "length": 48},
                         "clock": {"sourceTicksPerSecond": 100,
                                   "read": "END.EXE:0x27A2..0x27BA INT21 AH2C returns centiseconds",
                                   "elapsed": "END.EXE:0xBE92..0xBFFA;0xBFFA..0xC033"}},
              "limitations": ["This is the first source ending scene, not a complete ending or full campaign verification.",
                              "The initial center-out reveal and fades are not restored.",
                              "Caption bitmaps use the original font lookup and bold expansion; original DOS framebuffer parity has not been measured.",
                              "Selections0/1 diverge later in END; the common opening does not establish parity of those later branches.",
                              "Framework display flag8 substitutes palette6E8; this output retains the normal palette848 variant."]}
    if inventory(game) != before:
        raise ResourceError("original files changed during ending extraction")
    output.mkdir(parents=True, exist_ok=True)
    temporary = output / ".ending.json.tmp"
    temporary.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(output / "ending.json")
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--game-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        result = prepare(args.game_dir, args.output)
    except (OSError, ValueError) as error:
        print(f"ending preparation failed: {error}", file=sys.stderr)
        return 1
    print(json.dumps({"assets": len(result["assets"]), "frames": len(result["programs"][0]["frames"]),
                      "complete": False, "originalHashesPreserved": True}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
