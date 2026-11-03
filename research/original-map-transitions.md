# Map transitions

Static derivation from `MAIN.EXE`, `GRPDRV.EXE` and `SBOPL2.COM`. A subagent wrote the
first reading with the same disassembly tools. No original program was run, and
nothing was compared with a running original. Offsets are MAIN file offsets unless
written `seg:off` or `DS:off`.

## Fades

Every fade is GRPDRV function 16h: sixteen steps that each wait two vertical
retraces, about 0.53 s at 59.94 Hz, with no early exit (GRPDRV file `0x2B24..0x2C19`).
`CF5:4A22` fades to black, `CF5:4A10` fades in to the map's palette slot. The program
waits meanwhile; only the music keeps playing.

`CF5:CAD8` (`0x20428`) hides or shows the map and tracks it in DS:`DB6A`. Hide fades
to black if the map is shown. Show redraws the map and fades in if it is hidden.
Source `05` is show (`CF5:987C`); `2C` only redraws.

## Changing maps

Leaving a map draws nothing: the old picture stays while the next map loads
offscreen. The presents (`E4E4` at `0x21E34`, `1CB6:1210` at `0x24770`) then fade it
to black and draw the new map under black. `C86C` marks every script-selected map
(`09`, `11`, a battle's end) as a script entry (`0x20221`). A script entry stays black
until its `05`; a default entry or a load fades in at once.

When a script leaves a battle, `C456` fades the battle screen out first (`0x1E36A`).
Entering a battle fades out, holds black, draws, fades in and holds again, about
2.1 s from the last field frame (`0x1E297`, `0x1FE2E`, `0x272A7`).

## World camera

A world load sets the camera to (0,0) (`0x20C02`). The first actor that a script
places afterwards (slot 0, `CF5:E596` at `0x21FB4`) centres the camera through
`E818(0)` if it lies outside the 33×21 tile window. With 16-pixel tiles, x = 2·cellX and
y = 2·cellY:

- camX = 0 if x < 15, W−32 if x > W−17, else x−15;
- camY = 0 if y < 10, H−20 if y > H−10, else y−10.

`05` never recentres.

## Story pictures

`07` opens a picture window with a 32-step pattern dissolve, three SBOPL2 ticks a
step, about 1.6 s (`0x206A8..0x207C7`). A mode-0 panel is closed by `CF5:CE78`
(`0x207C8`) without restoring anything, so it stays until a redraw or a map present.

## Engine

The host-driven stage now does the following:

- **Map change:** the new map's state applies at once, so host logic reads the new map. The stage then fades the old screen out for 0.53 s before its next command, and the window keeps the last picture of the old map meanwhile.
- **`05`:** fades a black screen in over 0.53 s.
- **Leaving a battle:** a map selected from a battle starts black.
- **World maps:** the first placement centres the camera by the rule above.
- **Story pictures:** a closed mode-0 panel stays until the next map or `2C`.

Replays reach the same states and draw the same random numbers. Their simulated time
grows, and the final world camera follows the new rule. Each replay observation now
records the random state.

## Not restored

- The story-picture dissolve, the battle entry and exit fades, the black-to-black holds
  after loads and battles, and the default-entry music table (song 5 on the world,
  1 or 5 in towns, 15 in two palaces). Town and the merchant room already set theirs.
- A script palace shown by `05` fades to palette slot 2, while a default entry uses
  DS:`382A`; whether scripts correct this was not checked.
- The 59.94 Hz rate and real draw times.
