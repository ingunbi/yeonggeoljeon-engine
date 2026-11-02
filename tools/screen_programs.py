# SPDX-License-Identifier: GPL-3.0-only
"""END.EXE and OPEN.EXE scene programs as flat display operations.

These are transcriptions of the source's scene routines, read statically. Each
call mirrors one library routine; the native player executes the same list on a
640x400 indexed canvas and six 64 KB work buffers. Original bytes are only read
here, through offsets, and every result goes to local data.
"""
from __future__ import annotations

from pathlib import Path
import re
import struct

from opening_script import OPENING
from resource_formats import Archive, ResourceError, npk_picture

END_DATA = 0xCE40
OPEN_DATA = 0xBF00
OPCODES = {name: index for index, name in enumerate(
    ("clear", "mode", "mono", "load", "copy", "fill", "put", "get", "stamp", "picture", "dissolve", "bufmask", "bufput", "cell",
     "palette", "fade", "fadestep", "wait", "tick", "clock", "music", "musicwait", "musicstop", "cycle", "inputwait"))}
END_BUFFERS = {0x2882: 0, 0x2888: 1, 0x288E: 2, 0x2894: 3, 0x289A: 4, 0x28A0: 5}


def text_rows(lines: list[bytes], font: bytes, ascii_font: bytes, top: int = 0) -> tuple[int, int, bytearray]:
    """0x9310 and END 0x8C96: mono rows, one byte of padding, 20-pixel lines."""
    width = max((len(line) for line in lines), default=0) + 2
    height = 20 * len(lines) + top
    rows = bytearray(width * height)
    def mark(row: int, column: int, value: int) -> None:
        if column < width:
            rows[row * width + column] |= value & 255
    for index, line in enumerate(lines):
        base, cursor, column = top + 20 * index, 0, 1
        while cursor < len(line) and cursor < width:
            code = line[cursor]
            if code >= 0xA1:
                low = line[cursor + 1] if cursor + 1 < len(line) else 0
                value = code << 8 | low
                glyph = [(0, 0)] * 16
                if 0xA1A1 <= value <= 0xFDFE:
                    number = ((code - (0xA4 if code >= 0xB0 else 0xA1)) * 0x5E + low - 0xA1) & 0xFFFF
                    record = font[30 * number + 2:30 * number + 30]
                    glyph = [(record[2 * row], record[2 * row + 1]) for row in range(len(record) // 2)] + [(0, 0)] * 2
                for row, (left, right) in enumerate(glyph[:16]):
                    mark(base + row, column, left >> 1 | left)
                    mark(base + row, column + 1, right >> 1 | left << 7 | right)
                    mark(base + row, column + 2, right << 7)
                cursor, column = cursor + 2, column + 2
            else:
                record = ascii_font[(code - 0x20 if 0x20 <= code <= 0x7F else 0) * 16:][:16]
                for row, bits in enumerate(record):
                    mark(base + row, column, bits >> 1 | bits)
                    mark(base + row, column + 1, bits << 7)
                cursor, column = cursor + 1, column + 1
    return width, height, rows


class Recorder:
    def __init__(self, archive: Archive, exe: bytes, data: int, font: bytes, ascii_font: bytes, assets: dict, buffers: dict):
        self.archive, self.exe, self.data, self.font, self.ascii = archive, exe, data, font, ascii_font
        self.assets, self.buffers, self.ops, self.loaded = assets, buffers, [], {}
        self._mode, self._mono = 0, (0, 0, 0)

    def emit(self, name: str, *values: int) -> None:
        self.ops.append([OPCODES[name], *values])

    def asset(self, data: bytes) -> int:
        return self.assets.setdefault(bytes(data), len(self.assets))

    def word(self, offset: int) -> int:
        return struct.unpack_from("<H", self.exe, self.data + offset)[0]

    def sword(self, offset: int) -> int:
        return struct.unpack_from("<h", self.exe, self.data + offset)[0]

    def palette(self, offset: int) -> list[int]:
        return list(self.exe[self.data + offset:self.data + offset + 48])

    def lines(self, offset: int) -> list[bytes]:
        result = []
        while self.word(offset):
            start = self.data + self.word(offset)
            result.append(self.exe[start:self.exe.index(0, start)])
            offset += 2
        return result

    @property
    def mode(self) -> int:
        return self._mode

    @mode.setter
    def mode(self, value: int) -> None:
        self._mode = value
        self.emit("mode", value)

    @property
    def mono(self) -> tuple:
        return self._mono

    @mono.setter
    def mono(self, value: tuple) -> None:
        self._mono = value
        self.emit("mono", *value)

    def clear(self) -> None:
        self._mode = 0
        self.emit("clear")

    def load(self, member: int, buffer: int, offset: int = 0) -> None:
        data = self.archive.decode(member).data
        self.loaded[buffer, offset] = data
        self.emit("load", self.asset(data), self.buffers[buffer], offset)

    def memcpy(self, target: int, target_offset: int, source: int, source_offset: int, count: int) -> None:
        self.emit("copy", self.buffers[target], target_offset, self.buffers[source], source_offset, count)

    def memset(self, target: int, target_offset: int, count: int, value: int = 0) -> None:
        self.emit("fill", self.buffers[target], target_offset, count, value)

    def blit(self, x: int, y: int, w: int, h: int, buffer: int, offset: int = 0) -> None:
        self.emit("put", x, y, w, h, self.buffers[buffer], offset)

    def get(self, x: int, y: int, w: int, h: int, buffer: int, offset: int = 0) -> None:
        self.emit("get", x, y, w, h, self.buffers[buffer], offset)

    def put1(self, x: int, y: int, w: int, h: int, buffer: int, offset: int = 0) -> None:
        self.emit("stamp", x, y, w, h, self.buffers[buffer], offset)

    def fast(self, column: int, y: int, columns: int, h: int, buffer: int, offset: int) -> None:
        saved = self._mode
        self.mode = 0
        self.blit(column * 8, y, columns * 8, h, buffer, offset)
        self.mode = saved

    def npk(self, x: int, y: int, w: int, h: int, buffer: int, offset: int) -> None:
        picture = npk_picture(self.loaded[buffer, offset - 0x30])
        if (picture.width, picture.height) != (w, h):
            raise ResourceError("scene picture size differs from its source call")
        self.emit("picture", x, y, w, h, self.asset(picture.pixels))

    def npk_to_buffer(self, source: int, source_offset: int, target: int, target_offset: int) -> None:
        picture = npk_picture(self.loaded[source, source_offset])
        groups = bytearray()
        for row in range(picture.height):
            line = picture.pixels[row * picture.width:(row + 1) * picture.width]
            for start in range(0, picture.width, 8):
                for plane in range(4):
                    groups.append(sum(128 >> bit for bit in range(8) if line[start + bit] >> plane & 1))
        self.loaded[target, target_offset] = bytes(groups)
        self.emit("load", self.asset(bytes(groups)), self.buffers[target], target_offset)

    def xfade(self, w: int, h: int, step: int, target: int, target_offset: int, source: int, source_offset: int, block: int = 4) -> None:
        self.emit("dissolve", w, h, step, self.buffers[target], target_offset, self.buffers[source], source_offset, block)

    def xfade16(self, x: int, y: int, w: int, h: int, palette, target: int, target_offset: int, source: int, source_offset: int) -> None:
        saved = self._mode
        for step in range(16):
            self.xfade(w, h, step, target, target_offset, source, source_offset)
            if palette is None:
                self.tick(1)
            else:
                self.fade_step(palette)
            self.mode = 0
            self.blit(x, y, w, h, target, target_offset)
        self.mode = saved

    def comp_mask(self, target: int, width: int, x: int, y: int, w: int, h: int, source: int, offset: int) -> None:
        self.emit("bufmask", self.buffers[target], width, x, y, w, h, self.buffers[source], offset)

    def comp_color(self, target: int, width: int, x: int, y: int, w: int, h: int, source: int, offset: int, mode: int = 4, target_offset: int = 0) -> None:
        self.emit("bufput", self.buffers[target], target_offset, width, x, y, w, h, mode, self.buffers[source], offset)

    def cell(self, target: int, target_offset: int, mask: int, mask_offset: int, color: int, color_offset: int) -> None:
        self.emit("cell", self.buffers[target], target_offset, self.buffers[mask], mask_offset, self.buffers[color], color_offset)

    def text1(self, offset: int, buffer: int, position: int = 0, extra: int = 0) -> tuple[int, int]:
        width, height, rows = text_rows(self.lines(offset), self.font, self.ascii, extra)
        self.emit("load", self.asset(bytes(rows)), self.buffers[buffer], position)
        return width, height

    def text4(self, offset: int, buffer: int, position: int, colour: int, top: int = 0) -> tuple[int, int]:
        width, height, rows = text_rows(self.lines(offset), self.font, self.ascii, top)
        groups = bytearray(len(rows) * 4)
        for index, value in enumerate(rows):
            for plane in range(4):
                if colour >> plane & 1:
                    groups[index * 4 + plane] = value
        self.emit("load", self.asset(bytes(groups)), self.buffers[buffer], position)
        return width, height

    def setpal(self, palette: list[int]) -> None:
        self.emit("palette", *palette)

    def fade_to(self, palette: list[int]) -> None:
        self.emit("fade", *palette)

    def fade_step(self, palette: list[int]) -> None:
        self.emit("fadestep", *palette)

    def wait(self, delta: int) -> None:
        self.emit("wait", delta)

    def tick(self, count: int) -> None:
        self.emit("tick", count)

    def reset(self, start: int = 0) -> None:
        self.emit("clock", start)


def outlined(v: Recorder, x: int, y: int, w: int, h: int, buffer: int) -> None:
    v.mono = (4, 0, 0)
    for dx, dy in ((-1, 0), (1, 0), (0, -1), (0, 1)):
        v.put1(x + dx, y + dy, w, h, buffer)
    v.mono = (4, 7, 0)
    v.put1(x, y, w, h, buffer)


def centred(width: int) -> int:
    return int((0x50 - width) * 8 / 2) & -8


def end1(v: Recorder, selection: int) -> None:
    """0x4B9A..0x7757. The first scene plays as frames; its fade leaves black."""
    pal, BLACK = v.palette, v.palette(0x6B8)
    v.reset(4300)
    v.setpal(BLACK)
    v.mode = 0
    v.load(0x15, 0x2882)
    v.clear()
    v.load(0x17, 0x2888)
    v.memcpy(0x288E, 0, 0x2882, 0, 0x3000)
    v.load(0x16, 0x2882, 0x3000)
    v.blit(0x138, 0xB8, 0x100, 0x60, 0x2882)
    v.get(0x168, 0xB8, 0xA0, 0x48, 0x2882, 0x7380)
    v.memcpy(0x2894, 0, 0x2888, 0, 0x3000)
    v.blit(0x48, 0x38, 0x100, 0x60, 0x2888)
    v.get(0x78, 0x38, 0xA0, 0x48, 0x2888, 0x7380)
    v.wait(300)
    v.fade_to(pal(0x968))
    v.load(0x18, 0x2888, 0x3000)
    right, left = (0x168, 0xB8, 0xA0, 0x48, 0x2882), (0x78, 0x38, 0xA0, 0x48, 0x2888)
    def pair(delay: int, offset: int) -> None:
        v.wait(delay); v.blit(*right, offset); v.wait(10); v.blit(*left, offset)
    for _ in range(2):
        pair(230, 0x4680); pair(20, 0x3000); pair(20, 0x7380)
    pair(170, 0x3000)
    v.wait(180)
    for palette in (0x878, 0x8A8, 0x8D8, 0x908, 0x938, 0x968):
        v.setpal(pal(palette))
        if palette != 0x968:
            v.wait(10)
    v.wait(170)
    v.blit(*right, 0x7380); v.wait(10); v.blit(*left, 0x7380)
    pair(200, 0x4680); pair(20, 0x3000); pair(20, 0x7380)
    v.wait(200)
    v.wait(130)
    for palette in (0x878, 0x8A8, 0x8D8, 0x908, 0x938):
        v.setpal(pal(palette))
        v.wait(10)
    v.blit(0x138, 0xB8, 0x100, 0x60, 0x2882)
    v.get(0x118, 0xB8, 0x120, 0x60, 0x2882)
    v.blit(0x48, 0x38, 0x100, 0x60, 0x2888)
    v.get(0x68, 0x38, 0x120, 0x60, 0x2888)
    v.wait(100)
    west, east = 0x68, 0x118
    while True:
        v.blit(east, 0xB8, 0x120, 0x60, 0x2882)
        v.blit(west, 0x38, 0x120, 0x60, 0x2888)
        v.wait(15)
        west, east = west - 0x10, east + 0x10
        if east >= 0x278:
            break
    v.setpal(BLACK)
    # E1-3
    v.load(0x19, 0x2882)
    for target in (0x2888, 0x288E, 0x2894):
        v.memcpy(target, 0, 0x2882, 0, 0xDAC0)
    v.load(0x42, 0x289A)
    for buffer, offset in ((0x2882, 0), (0x2888, 0x2700), (0x288E, 0x4E00), (0x2894, 0x7500)):
        v.blit(0xD0, 0x30, 0xE0, 0x68, buffer)
        v.blit(0xE8, 0x30, 0xC0, 0x68, 0x289A, offset)
        v.get(0xD0, 0x30, 0xE0, 0x68, buffer)
    v.blit(0xD0, 0x30, 0xE0, 0x130, 0x2882)
    v.wait(500)
    v.fade_to(pal(0x998))
    v.wait(150)
    tower, row = (0x2882, 0x2888, 0x288E, 0x2894), 0
    while True:
        v.wait(15)
        v.fast(0x1A, 0x30, 0x1C, 0x130, tower[(row // 2) % 4], row * 0x70)
        if row % 8 == 0:
            if row * 0x70 >= 0x55C0:
                break
        elif row >= 0xC4:
            break
        row += 2
    v.get(0xD0, 0xFC, 0xE0, 0x64, 0x2888)
    v.wait(150)
    for index in range(5):
        v.load(0x1A + index, 0x2882)
        v.wait(110)
        v.xfade16(0xD0, 0xFC, 0xE0, 0x64, None, 0x2888, 0, 0x2882, 0)
    v.get(0x110, 0x110, 0x60, 0x50, 0x2882)
    v.load(0x1F, 0x2888)
    v.load(2, 0x2888, 0x1E00)
    v.wait(200)
    v.mono = (2, 0xF, 0)
    frame, top = 0, 0x15E
    while True:
        v.memcpy(0x288E, 0, 0x2882, 0, 0xF00)
        y, h = top - 0x110, 0x160 - top
        v.comp_mask(0x288E, 0x60, 0, y, 0x60, h, 0x2888, (frame + 8) * 0x3C0)
        v.comp_color(0x288E, 0x60, 0, y, 0x60, h, 0x2888, frame * 0xF00)
        v.wait(30)
        v.blit(0x110, 0x110, 0x60, 0x50, 0x288E)
        frame, top = 1 - frame, top - 2
        if top < 0x110:
            break
    v.fade_to(BLACK)
    v.clear()
    # E1-4
    v.load(0x20, 0x2882)
    v.wait(600)
    v.blit(0xB8, 0x40, 0x110, 0xE0, 0x2882, 0x7700)
    v.fade_to(pal(0x9F8))
    v.wait(200)
    for index in range(16):
        v.wait(50)
        v.blit(0xB8, 0x40, 0x110, 0xE0, 0x2882, (index % 2) * 0x7700)
    v.wait(300)
    v.fade_to(BLACK)
    v.clear()
    # E1-5
    v.load(0x22, 0x2882)
    v.mono = (3, 1, 0)
    v.put1(0x88, 0, 0x198, 0x190, 0x2882)
    v.get(0x88, 0, 0x198, 0xC8, 0x2882)
    v.get(0x88, 0xC8, 0x198, 0xC8, 0x288E)
    v.clear()
    v.load(0x21, 0x2888)
    v.npk(0x88, 0, 0x198, 0x190, 0x2888, 0x30)
    v.get(0x88, 0, 0x198, 0xC8, 0x2888)
    v.get(0x88, 0xC8, 0x198, 0xC8, 0x2894)
    v.wait(300)
    v.fade_to(pal(0x9F8))
    v.wait(300)
    v.wait(100)
    for palette, delay in ((0xA28, 10), (0xA58, 10), (0xA88, 10), (0xAB8, 30), (0x9F8, 200)):
        v.setpal(pal(palette))
        v.wait(delay)
    for step in range(16):
        v.xfade(0x198, 0xC8, step, 0x2888, 0, 0x2882, 0)
        v.xfade(0x198, 0xC8, step, 0x2894, 0, 0x288E, 0)
        v.blit(0x88, 0, 0x198, 0xC8, 0x2888)
        v.blit(0x88, 0xC8, 0x198, 0xC8, 0x2894)
        v.fade_step(pal(0x330))
    v.load(0x23, 0x2882)
    v.mono = (3, 2, 0)
    v.put1(0xB0, 0x28, 0x140, 0x138, 0x2882)
    v.load(0x24, 0x2882)
    v.mono = (3, 4, 0)
    v.put1(0xE8, 0x58, 0xC8, 0xC8, 0x2882)
    v.load(0x25, 0x2882)
    v.mono = (3, 8, 0)
    v.put1(0x130, 0x90, 0x40, 0x38, 0x2882)
    v.wait(800)
    data = v.data
    base, level, rising = list(v.exe[data + 0x32C:data + 0x32F]), list(v.exe[data + 0x360:data + 0x364]), list(v.exe[data + 0x364:data + 0x368])
    previous = v.exe[data + 0x35F]
    while True:
        wave = []
        for colour in range(16):
            for channel in range(3):
                total = sum(base[channel] * level[plane] for plane in range(4) if colour >> plane & 1)
                wave.append(min(total // 16, base[channel]))
        v.wait(10)
        v.setpal(wave)
        for index in range(4):
            if rising[index]:
                if index != 3:
                    level[index] -= 1 if level[index] else 0
            else:
                before = level[index - 1] if index else previous
                if (rising[index - 1] if index else level[3]) != 0 or before > 10:
                    level[index] += 1
                    if level[index] == 16:
                        rising[index] = 1
        if rising[2] and level[2] == 0:
            break
    v.setpal(wave)
    v.wait(200)
    v.fade_to(BLACK)
    v.clear()
    # E1-6
    v.load(0x45, 0x2882)
    v.load(0x46, 0x288E)
    v.load(0x47, 0x2894)
    v.mono = (2, 0xF, 0)
    v.put1(0x130, 0x90, 0x40, 0x38, 0x288E)
    v.mode = 3
    v.blit(0x130, 0x90, 0x40, 0x38, 0x2882, 0)
    v.wait(200)
    v.setpal(pal(0xB78))
    v.mode = 0
    for offset in range(0, 0x1C00, 0x700):
        v.wait(15)
        v.blit(0x130, 0x90, 0x40, 0x38, 0x2882, offset)
    v.load(0x28, 0x2888)
    v.load(3, 0x288E)
    v.mode = 3
    v.wait(280)
    v.setpal(pal(0xAE8))
    v.put1(0x110, 0xD8, 0x78, 0x70, 0x288E)
    v.blit(0x110, 0xD8, 0x78, 0x70, 0x2888)
    v.wait(20)
    v.fade_to(pal(0xB78))
    v.load(0x29, 0x2888)
    v.load(0x2A, 0x2894)
    v.load(0x2B, 0x28A0)
    v.load(5, 0x288E)
    v.load(7, 0x289A)
    v.mono = (2, 0xF, 0)
    v.mode = 3
    v.wait(610)
    v.setpal(pal(0xAE8))
    v.put1(0xB8, 0xA0, 0x80, 0xA8, 0x288E)
    v.blit(0xB8, 0xA0, 0x80, 0xA8, 0x2888)
    v.put1(0x170, 0x90, 0x68, 0xB8, 0x289A)
    v.blit(0x170, 0x90, 0x68, 0xB8, 0x2894)
    v.wait(20)
    v.fade_to(pal(0xB78))
    v.mode = 0
    v.load(9, 0x288E)
    v.load(0x2C, 0x2894)
    v.mono = (2, 0xF, 0)
    v.mode = 3
    v.wait(600)
    if selection == 0:
        v.setpal(pal(0xAE8))
        v.put1(0, 0x28, 0xD8, 0x120, 0x288E)
        v.blit(0, 0x28, 0xD8, 0x120, 0x28A0)
        v.load(0xB, 0x288E)
        v.put1(0x1B8, 0x28, 0xC8, 0x120, 0x288E)
        v.blit(0x1B8, 0x28, 0xC8, 0x120, 0x2894)
        v.wait(20)
        v.fade_to(pal(0xB78))
        v.load(0x26, 0x289A)
        v.wait(500)
        v.get(0, 0x28, 0x140, 0x120, 0x2888)
        v.get(0x140, 0x28, 0x140, 0x120, 0x288E)
        v.setpal(pal(0xB18))
        v.npk(0, 0x28, 0x280, 0x120, 0x289A, 0x30)
    else:
        v.load(0x27, 0x289A)
        v.wait(520)
        v.get(0xB0, 0x28, 0x138, 0x120, 0x2888)
        v.setpal(pal(0xB18))
        v.npk(0xB0, 0x28, 0x138, 0x120, 0x289A, 0x30)
    v.mode = 4
    if selection == 0:
        v.blit(0, 0x28, 0x140, 0x120, 0x2888)
        v.blit(0x140, 0x28, 0x140, 0x120, 0x288E)
    else:
        v.blit(0xB0, 0x28, 0x138, 0x120, 0x2888)
    v.wait(60)
    v.fade_to(pal(0xBA8))
    v.load(0x2D, 0x2882)
    v.wait(1000)
    v.fade_to(BLACK)
    v.clear()
    # E1-7
    v.load(0x2E, 0x2888)
    v.blit(0, 0x28, 0x140, 0x120, 0x2882)
    v.blit(0x140, 0x28, 0x140, 0x120, 0x2888)
    v.wait(600)
    v.fade_to(pal(0xBD8 if selection == 0 else 0xC08))
    v.wait(600)
    v.fade_to(BLACK)
    v.clear()
    # E1-8
    v.load(0x2F, 0x2882)
    v.npk(0xB8, 0x40, 0x110, 0xE0, 0x2882, 0x30)
    if selection == 0:
        width, height = v.text4(0x1254, 0x2882, 0, 7)
        v.blit(centred(width), 0x130, width * 8, height, 0x2882)
    v.wait(400)
    figure = 0xC38 if selection == 0 else 0xC68
    v.fade_to(pal(figure))
    v.load(0x30, 0x289A)
    v.load(0x31, 0x2888)
    v.load(0xD, 0x288E)
    v.wait(700)
    v.fade_to(BLACK)
    v.clear()
    # E1-9
    v.mode = 3
    v.mono = (2, 0xF, 0)
    v.npk(0xB8, 0x40, 0x110, 0xE0, 0x289A, 0x30)
    v.put1(0xB8, 0x98, 0x68, 0x90, 0x288E)
    v.blit(0xB8, 0x98, 0x68, 0x90, 0x2888)
    v.load(0x33, 0x2888)
    v.load(0xF, 0x288E)
    v.put1(0x128, 0x98, 0x40, 0x90, 0x288E)
    v.blit(0x128, 0x98, 0x40, 0x90, 0x2888)
    v.load(0x35, 0x2888)
    v.load(0x11, 0x288E)
    v.put1(0x160, 0x98, 0x68, 0x90, 0x288E)
    v.blit(0x160, 0x98, 0x68, 0x90, 0x2888)
    v.get(0xB8, 0x40, 0x110, 0xE8, 0x2894)
    v.clear()
    v.mode = 3
    v.mono = (2, 0xF, 0)
    v.npk(0xB8, 0x40, 0x110, 0xE0, 0x289A, 0x30)
    for column, member, mask, width in ((0xB8, 0x32, 0xE, 0x68), (0x128, 0x34, 0x10, 0x40), (0x160, 0x36, 0x12, 0x68)):
        v.load(member, 0x2888)
        v.load(mask, 0x288E)
        v.put1(column, 0x98, width, 0x90, 0x288E)
        v.blit(column, 0x98, width, 0x90, 0x2888)
    v.wait(400)
    v.fade_to(pal(figure))
    v.mode = 0
    v.get(0xB8, 0x40, 0x110, 0xE8, 0x2882)
    v.wait(400)
    v.xfade16(0xB8, 0x40, 0x110, 0xE8, None, 0x2882, 0, 0x2894, 0)
    v.wait(600)
    v.fade_to(BLACK)
    v.clear()
    # E1-10
    v.mode = 0
    v.load(0x37, 0x2882)
    v.npk(0, 0x28, 0x280, 0x120, 0x2882, 0x30)
    w1, h1 = v.text1(0x150E if selection else 0x1392, 0x289A)
    x1 = centred(w1)
    w2, h2 = v.text1(0x158A, 0x2894)
    outlined(v, centred(w2), 0xA0, w2 * 8, h2, 0x2894)
    v.get(x1, 0x68, w1 * 8, h1, 0x2894)
    v.npk(0, 0x28, 0x280, 0x120, 0x2882, 0x30)
    outlined(v, x1, 0x68, w1 * 8, h1, 0x289A)
    v.get(x1, 0x68, w1 * 8, h1, 0x289A)
    v.load(0x41, 0x2882)
    v.load(0x43, 0x2888)
    table = lambda column, row: v.sword(0xC8 + 2 * (column * 0x12 + row))
    sprites = []
    for index in range(16):
        column, row = index % 0x11, index % 0x12
        x = table(column, row)
        sprites.append({"x": [x, x], "y": [row * 16 + 0x28] * 2, "c": column, "t": index % 6, "r": row})
        if x < 640:
            v.get(x, row * 16 + 0x28, 16, 16, 0x28A0, index << 7)
            v.get(x, row * 16 + 0x28, 16, 16, 0x28A0, (index + 16) << 7)
    v.wait(600)
    v.fade_to(pal(0xC98 if selection == 0 else 0xCC8))
    v.wait(200)
    page = 0
    for step in range(0x46):
        page ^= 1
        for index, sprite in enumerate(sprites):
            if sprite["x"][page] < 640:
                v.blit(sprite["x"][page], sprite["y"][page], 16, 16, 0x28A0, ((page << 4) + index) << 7)
        if 0x17 <= step and step - 0x17 < 0x10:
            v.xfade(w1 * 8, h1, step - 0x14, 0x289A, 0, 0x2894, 0)
        v.blit(x1, 0x68, w1 * 8, h1, 0x289A)
        for index, sprite in enumerate(sprites):
            sprite["r"] += 1
            if sprite["r"] == 0x12:
                sprite["c"], sprite["t"], sprite["r"] = step % 0x11, step % 6, 0
            x, y = table(sprite["c"], sprite["r"]), sprite["r"] * 16 + 0x28
            sprite["x"][page], sprite["y"][page] = x, y
            if x >= 640:
                continue
            v.get(x, y, 16, 16, 0x288E, index << 7)
            cell = sprite["r"] % 3 + sprite["t"] * 3
            v.cell(0x288E, index << 7, 0x2888, cell * 0x20, 0x2882, cell << 7)
            v.get(x, y, 16, 16, 0x28A0, ((page << 4) + index) << 7)
        for index, sprite in enumerate(sprites):
            if sprite["x"][page] < 640:
                v.blit(sprite["x"][page], sprite["y"][page], 16, 16, 0x288E, index << 7)
        v.wait(25)
    v.fade_to(BLACK)
    v.clear()


def end2(v: Recorder) -> None:
    """0x77BE..0x9541."""
    pal, BLACK = v.palette, v.palette(0x6B8)
    v.setpal(BLACK)
    v.clear()
    v.load(0, 0x2882)
    v.npk(0, 0x24, 0x140, 0x148, 0x2882, 0x30)
    v.load(1, 0x2882)
    v.npk(0x140, 0x24, 0x140, 0x148, 0x2882, 0x30)
    v.reset()
    v.emit("music", 2, 1, 0)
    v.fade_to(pal(0xF68))
    v.load(2, 0x2882)
    v.get(0x10, 0xF0, 0x260, 0x64, 0x288E)
    v.wait(400)
    for index in range(6):
        v.get(0x178, 0x54, 0xE0, 0x90, 0x2894)
        v.wait(150)
        for phase in range(25):
            for strip in range(9):
                if phase >= strip:
                    v.xfade(0xE0, 0x10, phase & 15, 0x2894, strip * 0x700, 0x2882, strip * 0x700)
            v.wait(20)
            v.blit(0x178, 0x54, 0xE0, 0x90, 0x2894)
            if phase > 5:
                v.fade_step(pal(0xF38))
        width, height = v.text1(v.word(0x368 + index * 2), 0x289A)
        v.get(0x10, 0xF0, 0x260, 0x64, 0x2894)
        v.xfade16(0x10, 0xF0, 0x260, 0x64, None, 0x2894, 0, 0x288E, 0)
        v.get(0x10, 0xF0, 0x260, 0x64, 0x288E)
        outlined(v, 0x10, 0xF0, width * 8, height, 0x289A)
        v.wait(110)
        if index != 5:
            v.load(3 + index, 0x2882)
        v.wait(910)
        v.fade_to(pal(0xF68))
        v.wait(150)
    v.load(0x15, 0x289A)
    v.load(0x18, 0x289A, 0x300)
    v.load(8, 0x288E)
    v.wait(400)
    v.fade_to(BLACK)
    v.clear()
    v.load(9, 0x2882)
    v.npk(0, 0, 0x280, 0x190, 0x2882, 0x30)
    v.get(0, 0, 0x280, 0xC8, 0x2882)
    v.get(0, 0xC8, 0x280, 0xC8, 0x2888)
    v.npk(0, 0, 0x280, 0x190, 0x288E, 0x30)
    v.get(0, 0, 0x280, 0xC8, 0x288E)
    v.get(0, 0xC8, 0x280, 0xC8, 0x2894)
    small_x = lambda column, row: v.sword(0x40E + 2 * (25 * column + row))
    big_x = lambda path, index: v.sword(0x59E + 2 * (25 * path + index))
    v.mode = 4
    small = []
    for index in range(25):
        sprite = {"c": index % 8, "t": index % 2, "r": index % 25, "f": index % 3}
        small.append(sprite)
        v.blit(small_x(sprite["c"], sprite["r"]), sprite["r"] * 16, 16, 16, 0x289A, (sprite["t"] * 3 + sprite["f"]) << 7)
    # The second ripple's index 0xFC reads past its table, so it never appears.
    big = [{"p": 0, "f": 0, "i": 0}, {"p": 1, "f": 1, "i": 0xFC}]
    for sprite in big:
        v.blit(big_x(sprite["p"], sprite["i"]), sprite["i"] * 16, 16, 16, 0x289A, (sprite["f"] * 3 + 25 % 3) << 7)
    v.mode = 0
    v.wait(500)
    v.fade_to(pal(0xF98))
    v.wait(200)
    step, delay = 4, 25

    def smalls(frame: int) -> None:
        increment = 2 if frame & 1 == 0 else 1
        for index, sprite in enumerate(small):
            v.blit(small_x(sprite["c"], sprite["r"]), sprite["r"] * 16, 16, 16, 0x289A, (sprite["t"] * 3 + sprite["f"]) << 7)
            sprite["r"] += 1
            if sprite["r"] == 25:
                sprite["c"], sprite["t"], sprite["r"] = index % 8, index % 2, 0
            sprite["f"] = (sprite["f"] + increment) % 3

    shift, first = 0, True
    while True:
        if not first:
            v.blit(0, 0, 0x280, shift, 0x2888, (0xC8 - shift) * 0x140)
            v.blit(0, shift, 0x280, 0xC8, 0x288E)
            v.blit(0, shift + 0xC8, 0x280, 0xC8 - shift, 0x2894)
        v.mode = 4
        for sprite in big:
            index = big_x(sprite["p"], sprite["i"])
            if index < 0:
                if sprite["f"] % 5 != 4:
                    sprite["f"] += 1
                v.mode = 0
                v.blit(-index, big_x(sprite["p"], sprite["i"] + 1) + shift, 0x60, 0x40, 0x289A, (sprite["f"] * 0xC00 + 0x300) & 0xFFFF)
                v.mode = 4
            else:
                v.blit(index, sprite["i"] * 16 + shift, 16, 16, 0x289A, (sprite["f"] * 3 + shift % 3) << 7)
            if big_x(sprite["p"], sprite["i"]) >= 0:
                sprite["i"] += 1
                if big_x(sprite["p"], sprite["i"]) < 0:
                    sprite["f"] = 5 * sprite["p"]
        smalls(shift)
        v.mode = 0
        v.wait(delay)
        first = False
        shift += step
        if shift >= 0xC8:
            break
    shift = 0
    while True:
        v.blit(0, 0, 0x280, shift, 0x2882, (0xC8 - shift) * 0x140)
        v.blit(0, shift, 0x280, 0xC8, 0x2888)
        v.blit(0, shift + 0xC8, 0x280, 0xC8 - shift, 0x288E)
        for sprite in big:
            index = big_x(sprite["p"], sprite["i"])
            v.blit(-index, big_x(sprite["p"], sprite["i"] + 1) + shift + 0xC8, 0x60, 0x40, 0x289A, (sprite["f"] * 0xC00 + 0x300) & 0xFFFF)
        v.mode = 4
        smalls(shift)
        v.mode = 0
        v.wait(delay)
        shift += step
        if shift > 0xC8:
            break
    shift = 0
    while True:
        v.blit(0, 0, 0x280, 0xC8, 0x2882)
        v.blit(0, 0xC8, 0x280, 0xC8, 0x2888)
        v.mode = 4
        smalls(shift)
        v.mode = 0
        v.wait(delay)
        shift += step
        if shift > 0x78:
            break
    v.load(0xB, 0x2882)
    v.load(0x11, 0x2882, 0x3C80)
    v.load(0xD, 0x2888)
    v.load(0x12, 0x2888, 0x3C80)
    v.load(0xA, 0x2894)
    v.wait(200)
    v.fade_to(BLACK)
    v.clear()
    v.npk(0x70, 0x70, 0x1A0, 0xB0, 0x2894, 0x30)
    v.get(0x70, 0x70, 0x1A0, 0xB0, 0x2882, 0x4BA0)
    v.load(0x16, 0x2888, 0x4BA0)
    petals = [{"c": index % 7, "t": index % 3, "r": index % 0xB} for index in range(12)]
    v.mono = (2, 0xF, 0)
    v.mode = 3
    v.put1(0xE0, 0x70, 0xB0, 0xB0, 0x2882, 0x3C80)
    v.blit(0xE0, 0x70, 0xB0, 0xB0, 0x2882)
    v.load(0xC, 0x288E)
    v.mode = 0
    v.blit(0xF8, 0xB8, 0x30, 0x10, 0x288E)
    v.get(0x70, 0x70, 0x1A0, 0xB0, 0x28A0)
    v.blit(0x70, 0x70, 0x1A0, 0xB0, 0x2882, 0x4BA0)
    v.mode = 3
    v.put1(0x70, 0x70, 0xB0, 0xB0, 0x2888, 0x3C80)
    v.blit(0x70, 0x70, 0xB0, 0xB0, 0x2888)
    v.put1(0xE0, 0x70, 0xB0, 0xB0, 0x2882, 0x3C80)
    v.blit(0xE0, 0x70, 0xB0, 0xB0, 0x2882)
    v.mode = 0
    v.get(0xF8, 0xB8, 0x30, 0x10, 0x289A)
    v.blit(0xF8, 0xB8, 0x30, 0x10, 0x288E)
    v.load(0xE, 0x288E)
    v.get(0x88, 0xC0, 0x30, 0x10, 0x289A, 0x280)
    v.blit(0x88, 0xC0, 0x30, 0x10, 0x288E)
    v.get(0x70, 0x70, 0xB0, 0xB0, 0x28A0, 0x8F00)
    v.blit(0xF8, 0xB8, 0x30, 0x10, 0x289A)
    v.blit(0x88, 0xC0, 0x30, 0x10, 0x289A, 0x280)
    v.load(0xF, 0x288E)
    v.load(0x13, 0x288E, 0x3C80)
    v.mode = 3
    v.put1(0x160, 0x70, 0xB0, 0xB0, 0x288E, 0x3C80)
    v.blit(0x160, 0x70, 0xB0, 0xB0, 0x288E)
    v.mode = 0
    v.get(0x70, 0x70, 0x1A0, 0xB0, 0x2894)
    v.fade_to(pal(0xFC8))
    v.wait(550)
    petal_x = lambda column, row: v.sword(0x374 + 2 * (11 * column + row))

    def fall(frame: int) -> None:
        v.mode = 4
        for sprite in petals:
            v.blit(petal_x(sprite["c"], sprite["r"]), (sprite["r"] + 7) * 16, 16, 16, 0x2888,
                   (((sprite["t"] * 4 + frame % 4) << 7) + 0x4BA0) & 0xFFFF)
            sprite["r"] += 1
            if sprite["r"] == 0xB:
                sprite["c"], sprite["t"], sprite["r"] = frame % 7, frame % 3, 0
        v.mode = 0

    for frame in range(0x11):
        v.blit(0x70, 0x70, 0x1A0, 0xB0, 0x2894)
        fall(frame)
        v.wait(50)
    v.blit(0x70, 0x70, 0x1A0, 0xB0, 0x2894)
    v.load(0xC, 0x288E)
    v.blit(0xF8, 0xB8, 0x30, 0x10, 0x288E)
    v.load(0xE, 0x288E, 0x400)
    v.blit(0x88, 0xC0, 0x30, 0x10, 0x288E, 0x400)
    v.load(0x10, 0x288E, 0x800)
    v.blit(0x170, 0xB0, 0x38, 0x18, 0x288E, 0x800)
    v.get(0x70, 0x70, 0x1A0, 0xB0, 0x289A)
    for frame in range(0x28):
        if frame < 16:
            v.xfade(0x1A0, 0xB0, frame, 0x2894, 0, 0x289A, 0)
        v.blit(0x70, 0x70, 0x1A0, 0xB0, 0x2894)
        fall(frame)
        v.wait(50)
        if frame < 16:
            v.fade_step(pal(0xFF8))
    v.get(0x70, 0x70, 0x1A0, 0xB0, 0x289A)
    for row in range(0xB0):
        offset = 0x58 + row * 0xD0
        v.memcpy(0x2894, offset - 0x58, 0x28A0, 0x8F00 + row * 0x58, 0x58)
        v.memcpy(0x2894, offset, 0x28A0, offset, 0x78)
    for frame in range(16):
        v.xfade(0x1A0, 0xB0, frame, 0x289A, 0, 0x2894, 0)
        v.blit(0x70, 0x70, 0x1A0, 0xB0, 0x289A)
        fall(frame)
        v.wait(50)
    v.get(0x70, 0x70, 0x1A0, 0xB0, 0x289A)
    for frame in range(16):
        v.xfade(0x1A0, 0xB0, frame, 0x289A, 0, 0x28A0, 0)
        v.blit(0x70, 0x70, 0x1A0, 0xB0, 0x289A)
        fall(frame)
        v.wait(50)
    v.get(0x70, 0x70, 0x1A0, 0xB0, 0x2894)
    v.memcpy(0x289A, 0, 0x2882, 0x4BA0, 0x8F00)
    for frame in range(16):
        v.xfade(0x1A0, 0xB0, frame, 0x2894, 0, 0x289A, 0)
        v.blit(0x70, 0x70, 0x1A0, 0xB0, 0x2894)
        fall(frame)
        v.wait(50)
    width, height = v.text1(0x1B7A, 0x289A)
    v.get(0x70, 0x70, 0x1A0, 0xB0, 0x288E)
    outlined(v, centred(width), 0xC0, width * 8, height, 0x289A)
    v.mode = 0
    v.get(0x70, 0x70, 0x1A0, 0xB0, 0x289A)
    v.wait(450)
    for frame in range(16):
        v.xfade(0x1A0, 0xB0, frame, 0x289A, 0, 0x288E, 0)
        v.blit(0x70, 0x70, 0x1A0, 0xB0, 0x289A)
        fall(frame)
        v.wait(50)
    for frame in range(0x1E):
        v.blit(0x70, 0x70, 0x1A0, 0xB0, 0x2894)
        fall(frame)
        v.wait(50)
        if frame >= 0xE:
            v.fade_step(BLACK)
    v.fade_to(BLACK)
    v.clear()


def credits(v: Recorder) -> None:
    """0x9570..0x998B. Two buffers show, two prepare (text b2882, b288E; pictures b2894, b2888)."""
    pal, BLACK = v.palette, v.palette(0x6B8)
    v.fade_to(BLACK)
    v.clear()
    v.reset()
    v.setpal(pal(0xCF8))
    v.memset(0x2888, 0, 0x8700)
    v.memset(0x288E, 0, 0xFFFF)
    v.wait(200)
    v.emit("musicwait")
    v.emit("music", 2, 2, 1)
    picture = 0
    for page in range(20):
        width, height = v.text4(v.word(0x240C + page * 2), 0x2882, 0, 7)
        for phase in range(50):
            for row in range(17):
                if phase >= row * 2:
                    offset = row * width * 80
                    v.xfade(width * 8, 20, phase & 15, 0x288E, offset, 0x2882, offset)
            v.blit(384, 32, width * 8, height, 0x288E)
            v.wait(10)
        v.wait(100)
        morph = page & 1 != 0
        if morph:
            for pattern in range(16):
                v.xfade(288, 240, pattern, 0x2888, 0, 0x2894, 0)
                v.blit(0, 0, 288, 240, 0x2888)
                v.wait(15)
                if page < 18:
                    v.fade_step(pal(v.word(0x602 + (page // 2) * 2)))
            picture += 1
        elif picture < 9:
            v.load(56 + picture, 0x2894)
        else:
            v.memset(0x2894, 0, 0x8700)
        v.wait(500 - (240 if morph else 0))
    v.fade_to(BLACK)
    v.clear()
    v.load(0x44, 0x2882)
    v.npk(216, 80, 208, 112, 0x2882, 0x30)
    v.load(0, 0x2882)
    v.npk(184, 200, 272, 40, 0x2882, 0x30)
    v.wait(200)
    v.fade_to(pal(0x818))
    v.wait(400)
    v.emit("inputwait")
    v.emit("musicstop", 8)
    v.fade_to(BLACK)
    v.clear()


def opening(v: Recorder, script: list[dict]) -> None:
    """OPEN.EXE 0x4310..0x89A6, flattened from its operation list; loops R1..R5 expand here."""
    def buffer(text) -> tuple[int, int]:
        match = re.fullmatch(r"B(\d)\+?(0x[0-9a-f]+|x[0-9a-f]+|\d+)?", str(text))
        if match is None:
            raise ResourceError(f"opening script buffer {text} is not understood")
        offset = match.group(2)
        if offset is None:
            return int(match.group(1)), 0
        return int(match.group(1)), int("0" + offset, 16) if offset.startswith("x") else int(offset, 0)
    def palette(value):
        if isinstance(value, int):
            return v.palette(value)
        text = str(value)
        if text.startswith("["):
            return v.palette(v.word(int(text[1:].split("]")[0], 16)))
        return None

    state = {"new": None, "x": None, "y": None, "pal": None}

    def wipe(o: dict, outward: bool) -> None:
        x, y, w, h = o["x"], o["y"], o["w"], o["h"]
        old, new = buffer(o["old"]), buffer(o["new"])
        pitch = w // 8 * 4
        def rows(n: int) -> None:
            for row in (n, h - 1 - n):
                v.memcpy(old[0], old[1] + row * pitch, new[0], new[1] + row * pitch, pitch)
        for n in (range(h // 2 - 2, -1, -2) if outward else range(0, h // 2, 2)):
            for row in ((n + 1, n) if outward else (n, n + 1)):
                rows(row)
            v.tick(1)
            v.blit(x, y + n, w, 2, old[0], old[1] + n * pitch)
            v.blit(x, y + h - n - 2, w, 2, old[0], old[1] + (h - n - 2) * pitch)

    def run(segment: list[dict]) -> None:
        for o in segment:
            kind = o["kind"]
            if kind == "LOAD":
                if not isinstance(o["member"], str):
                    v.load(o["member"], *buffer(o["dst"]))
            elif kind == "NPK":
                v.npk(o["x"], o["y"], o["w"], o["h"], *buffer(o["src"]))
            elif kind == "NPK2BUF":
                v.npk_to_buffer(*buffer(o["src"]), *buffer(o["dst"]))
            elif kind == "CLS":
                v.clear()
            elif kind == "ROP":
                v.mode = o["mode"] or 0
            elif kind == "INK":
                v.mono = (o["mode"], o["fg"], o["bg"])
            elif kind == "SETPAL":
                value = state["pal"] if state["pal"] is not None else 0x288 if "bx" in str(o["pal"]) else o["pal"]
                v.setpal(palette(value))
            elif kind == "FADE":
                v.fade_to(palette(o["pal"]))
            elif kind == "PALSTART":
                v.emit("cycle", o["period"], *(item for address in pointer_list(o["list"]) for item in v.palette(address)))
            elif kind == "PALSTOP":
                v.emit("cycle", 0)
            elif kind == "BLIT":
                v.blit(o["x"], o["y"], o["w"], o["h"], *buffer(state["new"] if "None" in str(o["src"]) else o["src"]))
            elif kind == "GETIMG":
                v.get(o["x"], o["y"], o["w"], o["h"], *buffer(o["dst"]))
            elif kind == "STAMP":
                v.put1(o["x"], o["y"], o["w"], o["h"], *buffer(o["src"]))
            elif kind == "TEXT1BPP":
                v.text1(o["list"], *buffer(o["dst"]), extra=o["a2"])
            elif kind == "TEXT4P":
                v.text4(o["list"], *buffer(o["dst"]), 7, top=o["a1"])
            elif kind == "MEMSET":
                target = buffer(o["dst"]) if "None" not in str(o["dst"]) else (4, 0)
                v.memset(target[0], target[1], o["count"] if o["count"] is not None else 0x780)
            elif kind == "MEMCPY":
                target, source = buffer(o["dst"]), buffer(o["src"])
                v.memcpy(target[0], target[1], source[0], source[1], o["count"])
            elif kind == "BUFBLIT":
                source = buffer(state["new"] if state["new"] is not None else o["src"])
                target = buffer(o["dst"])
                x = o["x"] if not isinstance(o["x"], str) else state["x"]
                y = o["y"] if not isinstance(o["y"], str) else state["y"]
                v.comp_color(target[0], o["dw"], x, y, o["w"], o["h"], source[0], source[1], o["mode"], target[1])
            elif kind in ("DISSOLVE16", "DISSOLVE64"):
                count, block = (16, 4) if kind == "DISSOLVE16" else (64, 8)
                old, new = buffer(o["old"]), buffer(state["new"] if state["new"] is not None else o["new"])
                target = palette(o["pal"]) if o["pal"] not in (0, "0") else None
                for step in range(count):
                    v.xfade(o["w"], o["h"], step, old[0], old[1], new[0], new[1], block)
                    if target is None:
                        v.tick(1)
                    else:
                        v.fade_step(target)
                    v.blit(o["x"], o["y"], o["w"], o["h"], old[0], old[1])
            elif kind == "WIPE_7A5A":
                wipe(o, False)
            elif kind == "WIPE_7B92":
                wipe(o, True)
            elif kind == "DEADLINE":
                pending.append(o["add"])
            elif kind == "WAIT":
                v.wait(pending.pop(0) if pending else 0)
            elif kind == "CLOCK":
                v.reset()
            elif kind == "MUSIC":
                v.emit("music", 1, o["member"], loop[0])
            elif kind == "MUSLOOP":
                loop[0] = o["value"]
            elif kind == "MUSSTOP":
                v.emit("musicstop", o["value"])

    def pointer_list(offset: int) -> list[int]:
        result = []
        while v.word(offset):
            result.append(v.word(offset))
            offset += 2
        return result

    pending, loop = [], [0]
    between = lambda start, stop: [o for o in script if start <= o["addr"] < stop]
    run(between(0, 0x4709))
    for index in range(8):
        state["new"], state["pal"] = f"B0+{index * 0xC0}", v.word(0x708 + 2 * ((index + 1) % 3))
        run(between(0x4709, 0x4773))
    state["new"], state["pal"] = None, None
    run(between(0x4775, 0x4E25))
    for index in range(1, 14):
        state["new"], state["x"], state["y"] = f"B0+{(index % 4) * 0x6C0}", (13 - index) * 8, (0x40 * index) // 13
        run(between(0x4E25, 0x4EEC))
    state["new"] = None
    for frame in (0x1B00, 0x21C0, 0x2880):
        state["new"] = f"B0+{frame}"
        run(between(0x4EF2, 0x4F9E))
    state["new"] = None
    run(between(0x4F9F, 0x53F9))
    for step in range(1, 6):
        for o in between(0x53F9, 0x547B):
            if o["kind"] == "LOAD":
                if step == 2:
                    run([o])
            elif o["kind"] == "DISSOLVE16":
                state["new"] = f"B3+{63 * step * 0xA0}"
                run([o])
                state["new"] = None
            else:
                run([o])
    run(between(0x547C, 0x5774))
    for step in range(1, 4):
        for o in between(0x5774, 0x57D5):
            if o["kind"] == "DISSOLVE16":
                state["new"] = f"B3+{72 * step * 0xA0}"
                run([o])
                state["new"] = None
            else:
                run([o])
    run(between(0x57D6, 0x83D7))
    for step in range(3):
        v.load(0x2E + step, 0, step << 12)
    run(between(0x83FC, 0x8970))


def compile_all(game: Path, opgrp: bytes | None) -> tuple[dict, list[bytes]]:
    read = lambda name: (game / name).read_bytes()
    end, font, ascii_font = read("END.EXE"), read("ALL_FONT.16P"), read("HANKAKU.FNT")
    first, second = Archive(read("END1GRP.R3"), "END1GRP.R3"), Archive(read("END2GRP.R3"), "END2GRP.R3")
    assets: dict = {}
    programs = {}
    for name, build in (("end1-0", lambda v: end1(v, 0)), ("end1-1", lambda v: end1(v, 1)), ("end2", end2)):
        v = Recorder(second if name == "end2" else first, end, END_DATA, font, ascii_font, assets, END_BUFFERS)
        build(v)
        v.archive = first
        credits(v)
        programs[name] = v.ops
    if opgrp is not None:
        buffers = {index: index for index in range(6)}
        v = Recorder(Archive(opgrp, "OPGRP.R3"), read("OPEN.EXE"), OPEN_DATA, font, ascii_font, assets, buffers)
        opening(v, OPENING)
        programs["opening"] = v.ops
    return programs, list(assets)
