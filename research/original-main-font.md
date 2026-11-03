# MAIN's text

Static derivation from `MAIN.EXE`. A subagent wrote the first reading with the same
disassembly tools; the engine's checks are synthetic. No original program was run,
and nothing was compared with a DOS framebuffer. Offsets are MAIN file offsets
unless written `seg:off` or `DS:off`.

## Glyphs

MAIN keeps no font in memory. For each character `CF5:0D44` (`0x14694`) opens
`ALL_FONT.16P` (DS:`0DD8`) or `hankaku.fnt` (DS:`0AC0`), reads one record and closes.

| Code | File | Record |
|---|---|---|
| `A1A1..FDFE` | ALL_FONT.16P | 30 bytes: the KS code (low byte first), then 14 rows of 2 bytes. Index `(hi − (A4 if hi ≥ B0 else A1))·94 + lo − A1` (`0x14666`), read at `30·idx + 2`. |
| other | HANKAKU.FNT | 16 rows of 1 byte at `16·(c − 20h)` for `20..7F`, else glyph 0 (blank). |

The Hangul index and record are those END uses. MAIN differs from END in three ways:
it draws without the bold pixel, a syllable is 14 rows rather than a 20-pixel line,
and there is no left padding. FONT.R3 holds 87 glyphs that MAIN registers with the
graphics driver and never draws, a leftover of the Japanese version.

## putc and drawing

`CF5:0A2E` (`0x1437E`) takes leads `A1..C8` with a trail `A1..FE`. Any other byte is a
one-byte code; a dropped lead's trail becomes one too. `0A` and `0D` move the cursor.
`1B` starts an escape. Other control bytes do nothing. A cell's top-left is
(8·column, y). A syllable advances two columns, any other code one, and a new line
moves down 18 pixels.

`CF5:0E24` (`0x14774`) draws mode 4 nearly everywhere: set pixels take the foreground
and clear pixels keep the canvas. Mode 0 paints clear pixels in colour 0, and a
background other than 0 paints them in that colour. An optional outline is a 3×3
dilation in the outline colour under the glyph. Labels and the HUD use colour 7;
disabled buttons use colour 2.

`printf` (`CF5:0F18`) pads `%Nu`/`%Ns` on the left to N bytes. HUD cursors:

| Field | Writer | Cursor | Format |
|---|---|---|---|
| caption | `0x1FC5E` | (24, 360) | `%s` of DS:`DB4C` |
| money | `0x1FCB2` | (576, 136) | `%5u` |
| level | `0x1FCEA` | (584, 160) | `%4u` |
| territory | `0x1FD24` | (568, 200) | `%6s` |

Button labels start at column x/8 + (w/8 − bytes)/2 of their button (`CF5:1AC8`).

## Engine

`tools/prepare_story.py` checks MAIN's file names, the record counts and sample
record identities, then copies both files into local GameData under `fonts/`.
`OriginalFont` follows `putc` and the glyph lookup. In the original frames it draws
the HUD values, the caption and the title-menu labels, at MAIN's cursors and in mode 4.

## Not restored

- Dialogue and every engine window (`CanvasTheme`) keep the system font. The battle
  screen's texts in the original frames still use it too.
- Escapes, outlines and modes other than 4 are not used by these callers, so they are
  not implemented.
- After a new line, MAIN drops the next space (DS:`64DE`), including the first pad space
  of `%5u`. A HUD value could then sit 8 pixels further left, depending on what was
  printed last. This was not observed and is not modelled.
