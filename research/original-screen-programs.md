# Opening and ending programs

`OPEN.EXE` and `END.EXE` are built from the same library: scene routines drive a
graphics driver, a clock and six 64 KB work buffers. They were read statically; no
original program was run, and nothing was compared with a running original.

`tools/screen_programs.py` transcribes the scene routines call by call, and
`tools/opening_script.py` holds OPEN's operation list with addresses, coordinates
and text pointers. `tools/prepare_screens.py` flattens them into local `screens.json`
and `screens.bin`. `OriginalScreenPlayer` replays that list on the same model the
source used: a 640 by 400 indexed canvas, a palette and the six buffers.

## Model

| Operation | Source | Meaning |
| --- | --- | --- |
| put | driver function 0F | Interleaved pixels to the canvas. Mode 0 replaces, 3 ORs, 4 keys index 0. Clipped. |
| get | driver function 10 | The canvas back to interleaved pixels in a buffer. |
| stamp | driver function 13 | One-bit bitmap with the mono state. Mask plus sprite is a stamp with mode 2, then a put with mode 3. |
| picture | driver function 19 | An NPK picture, decoded by the producer. |
| dissolve | END `0:8642`, OPEN `0x8EDE`, `0x8F66` | One step of a 16 or 64 pattern transition between two buffers. |
| bufmask, bufput, cell | END `0:0AC7`, `0:0288` | Compositing inside buffers. |
| fade, fadestep | END `0:84C4`, OPEN `0x8B3E` | Each channel moves one step toward the target, four driver ticks a step. |
| wait, tick, clock | END `0:A9FA`, `0:83B0` | Deadlines in centiseconds, absolute within a program. Later waits absorb overruns. |
| cycle | OPEN `0x42C8` | Palette list on the 18.2 Hz tick. |

Text becomes bitmaps in the producer, with the source font mapping, so the player
never sees a string. Random numbers do not appear: every sprite path in both
programs comes from tables and modulo arithmetic.

## Exit screen

MAIN `0x1E3A8` fades to black, clears, draws PACKGRP members 34 and 36 at (216,80)
and (184,200), fades to palette 4 of DS:`1050` and waits for one input (`CF5:2556`),
after which main exits with code 3. The compiled program is `quit`. MAIN's fade goes
through the graphics driver, two vertical retraces a step
([title menu](original-title-menu.md)); this program still uses the four-tick step.

## Opening

The demo has sixteen scenes and two songs. The title picture is the tenth scene,
and the demo restarts from its first scene after a full run. Only a mouse button
leaves it. The window plays one pass, and any click leaves; MAIN's menu then opens at
once ([title menu](original-title-menu.md)). The source then fades its music out over
about five seconds; here the music stops at once.

The GAME copy of `OPGRP.R3` has damaged members, so the demo is compiled only when
the caller selects an intact copy with `--title-opgrp`. Without one, the window
starts at the title menu.

## Ending

Selection three runs END2, every other value END1, and all of them then run the
common credits. END1 has nine more scenes after the first, with colour palettes for
selection zero and grey ones otherwise. Selection zero also adds a text and a flash.
Nothing is skippable in the source. Here Escape leaves, and a click answers the final
button loop. END then exits to DOS through `HERO.COM`; the window returns to the title.

The first END1 scene still plays from its frames. A one-second fade to black joins
it to the program, which starts where the source's own fade would have ended.

## Not known

- Real blit, decode and disk time, which sets the length of the unpaced dissolve
  steps. Deadlines absorb most of it.
- One field of an END1 sprite record is never assigned (`0x7380`). It affects at
  most one 16 by 16 patch on the first frame.
- Whether framework flag bit 8 is set in normal play. The programs assume it is, so
  the requested palettes apply.
