# Title menu

Static derivation from `MAIN.EXE`, with `GRPDRV.EXE` for the fade. A subagent wrote
the first reading with the same disassembly tools; the engine's checks are synthetic,
with one optional real-file check. No original program was run, and nothing was
compared with a DOS framebuffer, real audio or real timing. Offsets are MAIN file
offsets unless written `seg:off` or `DS:off`.

## What MAIN shows

`main` (`0x1E43A`) calls `CF5:A7E8`, which sets palette DS:`1050` slot 0 at once and
clears the canvas twice (`0x1E179`, `0x1E183`, `0x1E19C`), and then `CF5:C050`
(`0x1F9A0`). MAIN draws no picture before its menu: OPEN.EXE has already cleared its
title and faded to black. The title menu is one window on a black canvas. No song
starts, so the title is silent (`CF5:600A` is not reached on this path).

`CF5:A3E4` is a code-entry prompt shown on the first run in a HERO session. Its result
is ignored (`0x1E453` jumps unconditionally). The engine leaves it out.

## The menu routine

`CF5:2C92` (`0x165E2..0x16C5C`) takes the window x and y in AX and DX and a far
string list in BX. On the stack it takes the visible rows, flags, a disabled-byte
array, a minimum width in columns and a scroll pointer. Without a scroll bar:

- width columns `W` = max(minimum, longest item of the whole list, 8); the window is
  `(W+2)·8` wide;
- rows `R` = min(items, visible), pitch 24, height `(24R+31) & ~15`; a window that
  would reach row 384 moves up in sixteen-pixel steps;
- buttons sit at `x+8`, `W·8` wide and 16 high, the first at
  `y + (H−24R−16)/2 + 8 + 4`.

`CF5:151A` frames the window with 8×8 three-plane tiles (DS:`0B6E`, tile set 2) and
fills it with a 16×16 pattern (`CF5:53BE`, pattern 2); `0x16743` picks set 2 and
pattern 2 outside battle. Each button (`CF5:1AC8`, style 0) repeats the 8×20 face
tile at MARK member 0 `+0x1F90` and adds a bevel. Labels are centred in colour 7, or
colour 2 when disabled. Flag `40` draws without saving the background.

Input is the mouse only. A left press on a button shows a pressed look and plays
effect 0 (`0x157D9`); release on it chooses. Holding the right button cancels. There
is no keyboard path and no hover highlight.

| Menu | Call | Window | Buttons |
|---|---|---|---|
| Title, DS:`2D38` | `0x1F9C5` | (216,128) 136×112 | (224, 140+24i) 120×16 |
| Options, DS:`34FC` | `0x1F93A` | (288,160) 80×96 | (296, 176+24i) 64×16 |
| Monitor, DS:`303A` | `0x229DA` | (320,144) 80×64 | (328, 156+24i) 64×16 |
| On/off, DS:`3008` | `0x22908` | (320,144) 80×64 | (328, 156+24i) 64×16 |

## Items

- New game (`CF5:B536`) reads the new-game template and tables and returns. No
  question, name or difficulty.
- Resume opens the slot dialog (`CF5:B938`); a cancel returns to the title.
- Options shows three rows, the field menu's items five to seven: monitor, BGM and
  effects. Each opens a two-row window over it with the current choice disabled.
  BGM on stays silent at the title, where no song is stored.
- Opening exits with code 0, so HERO runs OPEN and then MAIN again.
- A cancel shows the exit screen (`0x1E3A8`): PACKGRP 34 and 36, a click, exit code 3.

## From new game to the first map

`CF5:C456` fades to black (`0x1FDB8`), draws the base screen under black, and
`CF5:4A10` fades in. Each fade is GRPDRV function 16h: sixteen steps that wait two
vertical retraces each, about 0.53 s at 59.94 Hz. The rate is the standard VGA figure,
not a measurement. Chapter 0's records then run until a script selects a map. MAIN
itself shows no prologue. A load reaches the map through the same `C456`.

## Engine

`tools/menu_windows.py` checks the four calls and the frame style, computes each window
with the rules above and draws frame, pattern, buttons and bevels from MARK into local
pictures with palette slot 0. The labels stay with the window, which draws them in the
system font: MAIN's font is not restored.

- After the opening, or at once without an intact opening, the menu opens.
- In the original frames the title is black with MAIN's windows. Options and their
  two-row windows open over the title's, and the current choice is disabled.
- The engine layout keeps the opening's title picture and sets the rows under its
  logo; the options and their choices replace the rows there.
- A choice plays effect 0. Escape or a right click shows the exit screen, and the next
  click closes the window.
- New game and every load fade out and in over 0.53 s each, and the host waits
  meanwhile.
- Arrow keys, Return and the outline around the keyboard row are engine additions.

## Not restored or not checked

- MAIN's font, the pressed look and the mouse cursor shape.
- The palace loader's own present and fade after the first map is chosen.
- The 59.94 Hz retrace rate, and how long the disk reads took.
- The engine plays effect 1 on a cancel; MAIN plays none.
