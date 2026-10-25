# SPDX-License-Identifier: GPL-3.0-only
"""Independent, bounded readers for the original DOS game resource formats.

Implemented from the resource bytes and recorded static observations. This module
does not import an external game engine or an earlier extraction implementation.
"""
from __future__ import annotations

from dataclasses import dataclass
import struct
import zlib


class ResourceError(ValueError):
    """A malformed or unsupported input, with the selected resource's identity."""


@dataclass(frozen=True)
class SettlementMap:
    background_tiles: bytes
    walk_cells: bytes
    objects: tuple[tuple[int, int, int], ...]
    walk_markers: tuple[tuple[int, int, int], ...]


def settlement_map(payload: bytes) -> SettlementMap:
    """Own the shared original SMAP/PMAP tile, staggered-walk and prop layout."""
    if len(payload) < 1261 or len(payload) != 1261 + payload[1260] * 3:
        raise ResourceError("settlement map does not match its source tile/walk/object extent")
    walk = payload[640:1260]
    return SettlementMap(payload[:640], walk,
                         tuple(tuple(payload[at:at + 3]) for at in range(1261, len(payload), 3)),
                         tuple((value, at % 31, at // 31) for at, value in enumerate(walk) if value < 0x7F))


@dataclass(frozen=True)
class ArchiveMember:
    data: bytes
    index: int
    offset: int
    stored_size: int
    decoded_size: int
    resource: str

    def provenance(self) -> dict:
        return {"resource": self.resource, "member": self.index,
                "offset": self.offset, "storedSize": self.stored_size,
                "decodedSize": self.decoded_size}


class _Codes:
    def __init__(self, payload: bytes):
        self.payload = payload
        self.position = 0

    def take(self, count: int) -> int:
        if self.position + count > 8 * len(self.payload):
            raise ResourceError("compressed code ends outside its payload")
        result = 0
        for _ in range(count):
            byte, shift = divmod(self.position, 8)
            result = (result << 1) | ((self.payload[byte] >> (7 - shift)) & 1)
            self.position += 1
        return result

    def number(self) -> int:
        size = 1
        while self.take(1):
            size += 1
            if size > 24:
                raise ResourceError("compressed code exceeds the bounded prefix width")
        return (1 << size) - 2 + self.take(size)


class Archive:
    """LS11 directory facts are owned here; callers select decoded members."""

    def __init__(self, data: bytes, resource: str):
        self.data, self.resource = data, resource
        if len(data) < 276 or data[:4] not in (b"LS11", b"Ls11"):
            raise ResourceError(f"{resource}: unsupported LS11 container")
        if any(data[4:16]):
            raise ResourceError(f"{resource}: nonzero LS11 header padding")
        self.dictionary = data[16:272]
        endian = ">" if data[:4] == b"LS11" else "<"
        self.records = []
        cursor, first_payload, previous_end = 272, len(data), None
        declared_total = 0
        while cursor < first_payload:
            if cursor + 4 > len(data):
                raise ResourceError(f"{resource}: missing directory terminator")
            stored = struct.unpack_from(endian + "I", data, cursor)[0]
            if stored == 0:
                if not 0 < first_payload - cursor <= 15 or any(data[cursor:first_payload]):
                    raise ResourceError(f"{resource}: invalid directory terminator/padding")
                break
            if cursor + 12 > len(data):
                raise ResourceError(f"{resource}: truncated directory entry")
            stored, decoded, offset = struct.unpack_from(endian + "III", data, cursor)
            if not 0 < decoded <= 16 * 1024 * 1024 or not 0 < stored <= len(data):
                raise ResourceError(f"{resource}: invalid member sizes")
            declared_total += decoded
            if declared_total > 64 * 1024 * 1024:
                raise ResourceError(f"{resource}: decoded resource exceeds the 64 MiB budget")
            if offset < cursor + 12 or offset + stored > len(data):
                raise ResourceError(f"{resource}: member lies outside container")
            if previous_end is None:
                first_payload = offset
            elif offset != previous_end:
                raise ResourceError(f"{resource}: discontinuous/overlapping member chain")
            self.records.append((offset, stored, decoded))
            previous_end = offset + stored
            cursor += 12
        else:
            raise ResourceError(f"{resource}: directory has no zero terminator")
        if not self.records or previous_end != len(data):
            raise ResourceError(f"{resource}: trailing or missing container data")

    def __len__(self) -> int:
        return len(self.records)

    def decode(self, index: int) -> ArchiveMember:
        if not 0 <= index < len(self.records):
            raise ResourceError(f"{self.resource}: member {index} does not exist")
        offset, stored, decoded = self.records[index]
        payload = self.data[offset:offset + stored]
        if stored == decoded:
            output = payload
        else:
            reader, result = _Codes(payload), bytearray()
            try:
                while len(result) < decoded:
                    item = reader.number()
                    if item <= 255:
                        result.append(self.dictionary[item])
                        continue
                    back = item - 256
                    count = reader.number() + 3
                    if back == 0 or back > len(result):
                        raise ResourceError("backreference has no preceding decoded bytes")
                    if len(result) + count > decoded:
                        raise ResourceError("backreference exceeds declared decoded size")
                    for _ in range(count):
                        result.append(result[len(result) - back])
                if (reader.position + 7) // 8 != stored:
                    raise ResourceError("compressed payload was not exactly consumed")
            except ResourceError as error:
                raise ResourceError(f"{self.resource} member {index}: {error}") from error
            output = bytes(result)
        return ArchiveMember(output, index, offset, stored, decoded, self.resource)


def decode_archive(data: bytes, member: str) -> list[ArchiveMember]:
    archive = Archive(data, member)
    return [archive.decode(i) for i in range(len(archive))]


@dataclass(frozen=True)
class IndexedImage:
    width: int
    height: int
    pixels: bytes

    def __post_init__(self):
        if not 0 < self.width <= 2048 or not 0 < self.height <= 2048:
            raise ResourceError("unsupported image dimensions")
        if len(self.pixels) != self.width * self.height or any(p > 15 for p in self.pixels):
            raise ResourceError("invalid indexed image pixels")


def planar_image(data: bytes, width: int, height: int, *, interleaved: bool = False) -> IndexedImage:
    if width % 8 or width <= 0 or height <= 0 or len(data) != width * height // 2:
        raise ResourceError("planar image dimensions do not match its payload")
    output = bytearray(width * height)
    plane_size = width // 8 * height
    for group in range(plane_size):
        planes = [data[group * 4 + p] if interleaved else data[p * plane_size + group]
                  for p in range(4)]
        for bit in range(8):
            output[group * 8 + bit] = sum((1 << p) for p in range(4)
                                               if planes[p] & (128 >> bit))
    return IndexedImage(width, height, bytes(output))


def png_bytes(image: IndexedImage, colors: list[tuple[int, int, int]], *, transparent_zero: bool = False) -> bytes:
    if len(colors) != 16 or any(len(c) != 3 or any(not 0 <= v <= 255 for v in c) for c in colors):
        raise ResourceError("PNG requires sixteen RGB colors")
    rgba = [bytes((*rgb, 0 if transparent_zero and i == 0 else 255)) for i, rgb in enumerate(colors)]
    rows = bytearray()
    for y in range(image.height):
        rows.append(0)  # PNG filter None, with explicit RGBA rather than a hidden palette.
        for color in image.pixels[y * image.width:(y + 1) * image.width]:
            rows.extend(rgba[color])
    def chunk(kind: bytes, payload: bytes) -> bytes:
        return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload))
    header = struct.pack(">IIBBBBB", image.width, image.height, 8, 6, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(rows, 9)) + chunk(b"IEND", b"")


def npk_picture(payload: bytes) -> IndexedImage:
    """NPK016 word history format, derived from OPEN file 0x1CE4..0x1E63.

    The embedded palette is not used here: OPEN selects a separate final palette.
    Width is deliberately bounded to the 640-pixel source canvas.
    """
    if len(payload) < 48 or payload[:6] != b"NPK016":
        raise ResourceError("NPK016 picture header is absent")
    mode, canvas_width, canvas_height, width, height = struct.unpack_from("<5H", payload, 6)
    if (mode, canvas_width, canvas_height) != (4, 640, 400):
        raise ResourceError("NPK016 canvas/mode is unsupported")
    if not 0 < width <= 640 or width % 8 or not 0 < height <= 400:
        raise ResourceError("NPK016 picture size is unsupported")
    cursor, word_flags, flag_count = 48, 0, 0
    # Five rows of source words. None marks a history byte never produced.
    history: list[int | None] = [None] * 1600
    rearranged = bytearray()
    for row in range(height):
        start = (row % 5) * 320
        destination, words_left = start, width // 4
        while words_left:
            if flag_count == 0:
                if cursor >= len(payload):
                    raise ResourceError("NPK016 flags end outside the picture")
                word_flags, flag_count = payload[cursor], 8
                cursor += 1
            repeated = word_flags & 1
            word_flags >>= 1
            flag_count -= 1
            if repeated:
                if cursor >= len(payload):
                    raise ResourceError("NPK016 copy token is missing")
                token = payload[cursor]
                cursor += 1
                words = 1 + (token & 31)
                distance = 2 * (1 + ((token >> 5) & 3))
                if token & 128:
                    distance *= 160
                origin = destination - distance
                if origin < 0:
                    origin += 1600
                if words > words_left:
                    raise ResourceError("NPK016 copy exceeds its row")
                for _ in range(words * 2):
                    if not 0 <= origin < 1600 or history[origin] is None or destination >= 1600:
                        raise ResourceError("NPK016 copy has no initialized history")
                    history[destination] = history[origin]
                    destination += 1
                    origin += 1
            else:
                if cursor + 2 > len(payload):
                    raise ResourceError("NPK016 literal word is missing")
                history[destination:destination + 2] = payload[cursor:cursor + 2]
                destination += 2
                cursor += 2
                words = 1
            words_left -= words
        for group in range(start, start + width // 2, 4):
            a, b, c, d = history[group:group + 4]
            # The source's byte exchanges/rotations reduce to this nibble permutation.
            rearranged.extend((((b & 15) << 4) | (d & 15),
                               (b & 240) | (d >> 4),
                               ((a & 15) << 4) | (c & 15),
                               (a & 240) | (c >> 4)))
    if cursor != len(payload):
        raise ResourceError("NPK016 picture has unconsumed data")
    return planar_image(bytes(rearranged), width, height, interleaved=True)
