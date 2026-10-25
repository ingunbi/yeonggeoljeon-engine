#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Source END transition codec and common-credit event schedule.

The schedule retains audio/input/timer gates. Its final event is a source
return, not permission to treat an exhausted frame list as completion.
"""
from __future__ import annotations

from dataclasses import asdict, dataclass
import struct
from typing import Callable

from resource_formats import ResourceError


@dataclass(frozen=True)
class InterleavedPlanarGeometry:
    width: int
    height: int
    planes: int = 4
    layout: str = "raster-byte-interleaved"

    def validate(self) -> None:
        if (not 0 < self.width <= 2048 or self.width % 8 or not 0 < self.height <= 2048
                or self.planes != 4 or self.layout != "raster-byte-interleaved"):
            raise ResourceError("END transition requires bounded four-plane byte-interleaved geometry")

    @property
    def row_bytes(self) -> int:
        return self.width // 8 * self.planes

    @property
    def byte_length(self) -> int:
        return self.row_bytes * self.height


def transition_step(destination: bytes, source: bytes, geometry: InterleavedPlanarGeometry,
                    step: int, mask_words: tuple[int, ...]) -> bytes:
    """END0:8642/file9C42, positive-domain form of its 16-pattern selector.

    The four LE word masks are caller-supplied source facts. Their low/high
    bytes apply separately to planes0/1 and2/3; do not collapse them into an
    assumed transparent color or a single pixel-opacity mask.
    """
    geometry.validate()
    if (len(source) != geometry.byte_length or len(destination) != geometry.byte_length
            or not 0 <= step < 16 or len(mask_words) != 4
            or any(not 0 <= value <= 65535 for value in mask_words)):
        raise ResourceError("END transition source/destination span or pattern masks are invalid")
    residue = step * 7 % 16
    row_start = residue // 4
    mask = mask_words[residue % 4]
    copied = bytearray(destination)
    # Source truncates height/4; the last partial four-row block is untouched.
    for block in range(geometry.height // 4):
        row = block * 4 + row_start
        start = row * geometry.row_bytes
        for offset in range(start, start + geometry.row_bytes, 2):
            prior = int.from_bytes(copied[offset:offset + 2], "little")
            incoming = int.from_bytes(source[offset:offset + 2], "little")
            copied[offset:offset + 2] = ((prior & mask) | (incoming & (~mask & 65535))).to_bytes(2, "little")
    return bytes(copied)


def common_credit_schedule(page_count: int = 20, picture_count: int = 9) -> dict:
    """END9570..998B ordering, with source clock domains kept distinct.

    Counts parameterize synthetic tests; the examined producer's actual loop
    constants are20 pages and9 pending pictures. Text dimensions/pointers and
    palette bytes are resolved by their caller-owned source parser.
    """
    if not 0 <= picture_count <= 9 or page_count != 2 * (picture_count + 1):
        raise ResourceError("END common credits require paired pages and a final black-picture pair")
    events: list[dict] = []
    def emit(kind: str, start: int, end: int, **facts) -> None:
        events.append({"kind": kind, **facts,
                       "source": {"resource": "END.EXE", "start": start, "endExclusive": end}})
    def wait(deadline: int, start: int, end: int) -> None:
        emit("wait-until", start, end, clock="dos-centiseconds", deadline=deadline)
    geometry = asdict(InterleavedPlanarGeometry(288, 240))
    emit("palette-fade", 0x95A6, 0x95B9, clock="source-driver-timer", target="black", timerArgument=1)
    emit("clear-screen", 0x95B9, 0x95BE)
    emit("reset-clock", 0x95BE, 0x95CB, clock="dos-centiseconds")
    emit("palette-select", 0x95D9, 0x95E2, dataOffset=0xCF8)
    emit("clear-buffer", 0x95E2, 0x960E, buffer="picture-current", geometry=geometry, byteLength=0x8700)
    emit("clear-buffer", 0x95F8, 0x960E, buffer="text-current", byteLength=65535)
    deadline = 200
    wait(deadline, 0x960E, 0x962C)
    emit("await-audio-idle", 0x962C, 0x9639, clock="audio-driver", callee="END0:987E", untilReturn=0)
    emit("select-music", 0x9639, 0x9646, selection=2)
    picture = 0
    for page in range(page_count):
        emit("render-credit-bitmap", 0x9650, 0x9673, page=page, pointerTableDataOffset=0x240C + page * 2,
             color=7, leadingRows=0, lineHeight=20, fontRenderer="END0:90A6")
        for phase in range(50):
            rows = [row for row in range(17) if phase >= row * 2]
            emit("credit-text-pattern", 0x9678, 0x96C7, page=page, pattern=phase & 15,
                 lineIndices=rows, lineOffsetExpression="lineIndex*bitmapWidthBytes*80", stripHeight=20)
            emit("blit-credit-bitmap", 0x96C7, 0x96F4, page=page, origin=[384, 32], dimensions="rendered-credit-bitmap")
            deadline += 10
            wait(deadline, 0x96F4, 0x971D)
        deadline += 100
        wait(deadline, 0x971D, 0x9739)
        morph = page > 0 and page & 1 != 0
        if morph:
            for pattern in range(16):
                emit("picture-pattern", 0x9753, 0x979C, page=page, pattern=pattern,
                     geometry=geometry, sourceBuffer="picture-pending", destinationBuffer="picture-current", origin=[0, 0])
                deadline += 15
                wait(deadline, 0x979C, 0x97B9)
                if page < 2 * picture_count:
                    emit("palette-step", 0x97B9, 0x97E3, clock="source-driver-timer", timerArgument=1,
                         palettePointerDataOffset=0x602 + (page // 2) * 2)
            picture += 1
        elif picture < picture_count:
            emit("load-pending-picture", 0x97F4, 0x9819, archive="END1GRP.R3", member=56 + picture,
                 geometry=geometry, buffer="picture-pending")
        else:
            emit("clear-buffer", 0x9819, 0x982F, buffer="picture-pending", byteLength=0x8700, geometry=geometry)
        deadline += 500 - (240 if morph else 0)
        wait(deadline, 0x982F, 0x9851)
    emit("palette-fade", 0x9862, 0x9875, clock="source-driver-timer", target="black", timerArgument=1)
    emit("clear-screen", 0x9875, 0x987A)
    emit("load-npk-picture", 0x987A, 0x98BB, archive="END1GRP.R3", member=68, rect=[216, 80, 208, 112])
    emit("load-npk-picture", 0x98BB, 0x98FB, archive="END1GRP.R3", member=0, rect=[184, 200, 272, 40])
    deadline += 200
    wait(deadline, 0x98FB, 0x9916)
    emit("palette-fade", 0x9916, 0x9926, clock="source-driver-timer", dataOffset=0x818, timerArgument=1)
    deadline += 400
    wait(deadline, 0x9926, 0x9940)
    emit("await-final-input", 0x9940, 0x9956, clock="input", input="pointer-button",
         acceptedButtonMask=3, until="any accepted button held",
         sourcePredicates={"END0:A564": "constant1", "END0:7F42": "INT33 function3 buttons low2bits nonzero"})
    emit("stop-music", 0x9956, 0x9962, argument=8)
    emit("palette-fade", 0x9962, 0x996D, clock="source-driver-timer", target="black", timerArgument=0)
    emit("clear-screen", 0x996D, 0x9972)
    emit("close-archive", 0x9972, 0x9986, archive="END1GRP.R3")
    emit("source-return", 0x9986, 0x998C, status="normal-common-flow-return")
    return {"events": events, "complete": False, "pageCount": page_count, "pictureCount": picture_count,
            "finalCentisecondDeadline": deadline,
            "clockDomains": ["dos-centiseconds", "source-driver-timer", "audio-driver", "input"],
            "limitations": ["DOS deadlines are absolute after the common-flow reset; audio and driver-timer waits can make later deadlines overdue.",
                            "Driver-timer units are not substituted with centiseconds.",
                            "The final source return is reachable only after audio and input gates; frame EOF is not program completion."]}


def inspect_credit_source(ending: bytes, parse_lines: Callable[[bytes, int], list[dict]]) -> dict:
    """Read the pinned END profile's pointer facts using its existing text owner.

    The caller pins executable identity before calling. Returned strings,
    masks and palette-pointer payloads belong only in local extracted data.
    """
    data_base = 0xCE40
    if len(ending) < data_base + 0x2434:
        raise ResourceError("END credit data segment is truncated")
    masks = list(struct.unpack_from("<4H", ending, data_base + 0x728))
    palettes = list(struct.unpack_from("<9H", ending, data_base + 0x602))
    pages = []
    for index in range(20):
        table_offset = data_base + 0x240C + index * 2
        word_list = struct.unpack_from("<H", ending, table_offset)[0]
        lines = parse_lines(ending, word_list)
        if len(lines) != 17:
            raise ResourceError("END credits no longer match the examined seventeen-line transition geometry")
        width_bytes = max(line["sourceByteLength"] for line in lines) + 2
        if width_bytes * 8 + 384 > 640:
            raise ResourceError("END credit bitmap exceeds its source display rectangle")
        pages.append({"index": index, "lines": lines, "width": width_bytes * 8, "height": 340,
                      "origin": [384, 32], "textColor": 7,
                      "source": {"resource": "END.EXE", "pointerOffset": table_offset,
                                 "wordListDataSegmentOffset": word_list,
                                 "renderer": "END.EXE:0xA6A6..0xAB64"}})
    return {"pages": pages, "transitionMasks": masks,
            "transitionMaskSource": {"resource": "END.EXE", "offset": data_base + 0x728, "length": 8},
            "picturePalettes": [{"index": index, "dataSegmentOffset": offset, "fileOffset": data_base + offset}
                                for index, offset in enumerate(palettes)],
            "pictures": [{"archive": "END1GRP.R3", "member": 56 + index,
                          "geometry": asdict(InterleavedPlanarGeometry(288, 240)), "origin": [0, 0],
                          "paletteIndex": index} for index in range(9)],
            "schedule": common_credit_schedule()}


def inspect_ending2_opening(ending: bytes, parse_lines: Callable[[bytes, int], list[dict]]) -> dict:
    """Confirmed first END2 producer spans; later branch remains a frontier."""
    data_base = 0xCE40
    if len(ending) < data_base + 0x374:
        raise ResourceError("END2 opening pointer list is truncated")
    portraits = []
    for index in range(6):
        pointer = data_base + 0x368 + index * 2
        word_list = struct.unpack_from("<H", ending, pointer)[0]
        lines = parse_lines(ending, word_list)
        if len(lines) != 5:
            raise ResourceError("END2 opening no longer has its examined five-line captions")
        portraits.append({"index": index, "archive": "END2GRP.R3", "member": index + 2,
                          "geometry": asdict(InterleavedPlanarGeometry(224, 144)), "origin": [376, 84],
                          "stripGeometry": asdict(InterleavedPlanarGeometry(224, 16)), "stripCount": 9,
                          "caption": {"lines": lines, "origin": [16, 240], "lineHeight": 20,
                                      "outlineOffsets": [[-1, 0], [1, 0], [0, -1], [0, 1]],
                                      "source": {"resource": "END.EXE", "pointerOffset": pointer,
                                                 "wordListDataSegmentOffset": word_list}},
                          "source": {"resource": "END.EXE", "start": 0x7917, "endExclusive": 0x7C22}})
    return {"backgrounds": [{"archive": "END2GRP.R3", "member": index,
                              "encoding": "NPK016", "rect": [index * 320, 36, 320, 328]}
                             for index in range(2)],
            "paletteDataSegmentOffsets": [0xF68, 0xF38], "portraits": portraits,
            "frontier": {"resource": "END.EXE", "offset": 0x7C22,
                         "reason": "next END2 scene and later randomized effects have not been restored"},
            "limitations": ["Palette steps and the caption-buffer transition have distinct source timer waits.",
                            "This metadata is not a flattened or complete END2 playback timeline."]}
