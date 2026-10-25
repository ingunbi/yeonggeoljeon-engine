# SPDX-License-Identifier: GPL-3.0-only
"""Independent TF-DCE 5.11 bytecode decoder from the original TFDED driver.

The original driver writes VGA planes through a vertical snake traversal.
This reader models those planes without executing the driver or touching VGA.
An explicit zero base is required for preserved source planes/background reads.
"""
from __future__ import annotations

from resource_formats import IndexedImage, ResourceError


class DCEReader:
    def __init__(self, data: bytes):
        self.data, self.cursor = data, 0

    def byte(self) -> int:
        if self.cursor >= len(self.data):
            raise ResourceError("TF-DCE stream ended inside a source command")
        value = self.data[self.cursor]
        self.cursor += 1
        return value

    def word(self) -> int:
        return self.byte() | self.byte() << 8


def dce_picture(payload: bytes, *, zero_base: bool) -> tuple[IndexedImage, dict]:
    if not zero_base:
        raise ResourceError("TF-DCE preserved planes require an explicit original drawing base")
    source = DCEReader(payload)
    header_size = source.byte()
    if header_size != 2 or source.byte() != 0x54:
        raise ResourceError("TF-DCE picture does not match the examined 02/T header")
    columns, height = source.byte(), source.word()
    if not 1 <= columns <= 80 or not 1 <= height <= 400:
        raise ResourceError("TF-DCE dimensions exceed the original VGA picture geometry")
    codecs, plane_bits, flags = source.word(), source.byte(), source.byte()
    if flags & 0x40:
        for _ in range(16):
            source.word()  # Optional source palette; caller owns palette selection.
    dictionary = [source.word() for _ in range(source.byte())] if flags & 0x20 else []
    plane_map = [(plane_bits >> (2 * n)) & 3 for n in range(4)]
    planes = [bytearray(columns * height) for _ in range(4)]
    history = [0, 255, 85, 170]
    operations, preserved = 0, []

    def point(index: int) -> tuple[int, int]:
        x, vertical = divmod(index, height)
        return x, vertical if x % 2 == 0 else height - 1 - vertical

    def dense(index: int) -> int:
        x, y = point(index)
        return y * columns + x

    for channel in range(4):
        physical = plane_map[channel]
        mode = codecs >> (4 * channel) & 15
        output = planes[physical]
        total, written = columns * height, 0

        def emit(value: int) -> bool:
            nonlocal written
            if written >= total:
                return True
            output[dense(written)] = value & 255
            written += 1
            return written == total

        def read_at(plane: int, address: int) -> int:
            y, x = divmod(address, 80)
            if not 0 <= x < columns or not 0 <= y < height:
                raise ResourceError("TF-DCE source copy depends on pixels outside its selected drawing base")
            return planes[plane][y * columns + x]

        if mode in (0, 4):
            preserved.append(physical)
            continue
        if mode == 1:
            output[:] = bytes([source.byte()]) * total
            continue
        if mode == 2:
            reference = source.byte()
            if reference >= 4:
                raise ResourceError("TF-DCE plane-copy selector is outside its source table")
            output[:] = planes[plane_map[reference]]
            continue
        if mode != 3:
            raise ResourceError("TF-DCE plane codec is outside its examined source dispatcher")

        while written < total:
            operations += 1
            token = source.byte()
            value = None
            if token < 32:
                if token >= len(dictionary):
                    raise ResourceError("TF-DCE dictionary token references an absent word")
                entry = dictionary[token]
                token, value = entry & 255, entry >> 8
                if token >> 4 in (0, 1, 6):
                    raise ResourceError("TF-DCE dictionary selects a source return/reserved handler")
            family, low = token >> 4, token & 15
            if family >= 10:
                fill = source.byte() if value is None else value
                for _ in range(token - 0x9E):
                    if emit(fill):
                        break
            elif family == 7:
                if value is not None:
                    emit(value)
                else:
                    for _ in range(low + 1):
                        if emit(source.byte()):
                            break
            elif family in (6, 8):
                if family == 6:
                    first, second = source.byte(), source.byte()
                else:
                    packed = source.byte() if value is None else value
                    first, second = (packed & 15) * 17, (packed >> 4) * 17
                for _ in range(low + 1):
                    if emit(first) or emit(second):
                        break
            elif family == 2:
                distance = source.byte() if value is None else value
                if distance <= 0 or written < distance:
                    raise ResourceError("TF-DCE vertical copy has no initialized source history")
                for _ in range(low + 3):
                    if emit(output[dense(written - distance)]):
                        break
            elif family == 4:
                length = (source.byte() if value is None else value) + 2
                for _ in range(length):
                    x, y = point(written)
                    if emit(read_at(physical, y * 80 + x - low - 1)):
                        break
            elif family == 3:
                length = (source.byte() if value is None else value) + 2
                reference = plane_map[(token >> 2) & 3]
                for _ in range(length):
                    current = planes[reference][dense(written)]
                    if token & 3 == 1:
                        current ^= 255
                    elif token & 3 == 2:
                        current = (current >> 1 | current << 7) & 255
                    elif token & 3 == 3:
                        current = (current << 1 | current >> 7) & 255
                    if emit(current):
                        break
            elif family in (5, 9):
                selector = (token >> 2) & 3
                if value is None and selector == 3:
                    mask = source.byte()
                    history[3], history[2] = history[2], mask
                    selector = token & 3
                else:
                    slot = token & 3
                    mask = history[slot]
                    if slot:
                        history[slot], history[slot - 1] = history[slot - 1], history[slot]
                length = (source.byte() if value is None else value) + 2
                reference = plane_map[selector]
                for _ in range(length):
                    current = planes[reference][dense(written)] & mask
                    if family == 9:
                        rotations = 1 if mask in (85, 170) else 2
                        current = (current >> rotations | current << (8 - rotations)) & 255
                    if emit(current):
                        break
            else:
                raise ResourceError(f"TF-DCE opcode family {family} has no examined execution meaning")
    if source.cursor != len(payload):
        raise ResourceError("TF-DCE picture has unconsumed source bytes")
    pixels = bytearray(columns * 8 * height)
    for y in range(height):
        for x in range(columns):
            at = y * columns + x
            for bit in range(8):
                pixels[y * columns * 8 + x * 8 + bit] = sum(
                    ((planes[channel][at] >> (7 - bit)) & 1) << channel for channel in range(4))
    return IndexedImage(columns * 8, height, bytes(pixels)), {
        "sourceBytesConsumed": source.cursor, "dictionaryWords": len(dictionary),
        "planeCodecs": [(codecs >> (4 * n)) & 15 for n in range(4)], "planeMap": plane_map,
        "preservedPlanes": preserved, "drawingBase": "explicit zero planes", "operations": operations}
