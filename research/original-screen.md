# Field screen frame, HUD and in-canvas prompts

Static derivations from the pinned Korean DOS/V MAIN profile; no original
program was run. Offsets are MAIN.EXE file offsets. The story producer
(`tools/prepare_story.py`) reads these facts from MAIN bytes and refuses a
build whose instruction shapes differ from the examined profile.

## Original screen routines

The field screen routine `CF5:C456` (`0x1FDA6..0x1FE2C`) loads AX with zero
and calls `CF5:520E`, which blits PACKGRP member 0 (a 640×400 picture) at the
origin. The map is then drawn into the frame's black window, the source
viewport `(16,16,512,320)` that the scene and map producers already record.
The battle routine (`0x1FE2E..0x1FE69`) calls the same blitter with AX one, so
member 1 is the battle frame.

`CF5:51B2` draws portrait 0 into the upper-right slot. The call at
`0x1FE15` passes its x and y in AX and DX; the slot is 64×80.

Four HUD writers share one instruction shape: push height and clear colour,
load x, y and width into AX, DX and BX, call the rectangle clear `CF5:52EE`,
then push a text column (in 8-pixel cells), the same y and DS:`6390`, and call
the text cursor `CF5:091E`. The producer accepts a writer only when its text
row equals its cleared row.

| Field | Writer | Value | Format |
|---|---|---|---|
| caption | `0x1FC5E..0x1FC8E` | DS:`DB4C`, written by source `0B` through `CF5:C340` | `%s` |
| money | `0x1FCB2..0x1FCE8` | player object `7A80+0` through `CF5:220A` | `%5u` |
| level | `0x1FCEA..0x1FD22` | person 0 (DS:`7A94`) `+21` through `CF5:7572` | `%4u` |
| territory | `0x1FD24..0x1FD62` | city of player `7A80+10` through `CF5:210E`/`2118` | `%6s` |

Local `story.json` keeps each writer's rectangle, clear colour, text origin,
format and source offsets under `screens`. Public tests use synthetic MAIN
bytes; the optional real-file test checks that every HUD rectangle lies
outside the viewport and inside the 640×400 frame.

## Native mapping

Outside the title, ending and battle palette, the campaign view draws the
member 0 frame, clears the viewport, draws the stage inside it, and fills the
HUD from native state: portrait 0, player money, person 0's level and the
name of the current city in the current chapter. Captions go to the caption
box instead of the old top-left text. `--verify-play` and `--verify-campaign`
frames use the same path.

Prompts that the original draws with its selector and window primitives are
shown by a native overlay inside the viewport:

- the 3D save question, its decline check and the retry prompt, with the
  MARK member 0 Yes and No pictures (Yes first, as in `0x164A9..0x165C4`);
- scenario choices and record menus;
- MAIN's title menu and the right-click field menu, with unrestored items
  disabled;
- party selection, which toggles rows through the source selection rules
  (fixed prefix, capacity) and confirms on its last row;
- battle dialogue and retirement lines, which wait for one input.

Arrow keys move the selection, Return or Space chooses, and Escape or a right
click cancels where the menu allows it. Long lists scroll inside the
viewport. Scene dialogue is drawn in the same panel position by the renderer.

## Limits

- The original font, text colours and the window frames drawn by the
  dialogue and selector primitives are not restored. The overlay panels are
  engine presentation, not original pixels.
- The battle view does not draw the member 1 frame yet.
- Panel positions are engine choices that keep the frame visible; they are
  not source coordinates.
- Frames are offscreen captures. They do not verify macOS input delivery or
  original-runtime pixel parity.
