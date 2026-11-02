# Duel scene

Static derivation from `MAIN.EXE`, with `SBOPL2.COM` for the tick rate. A
subagent wrote the first reading with the same disassembly tools; the engine's
checks below are synthetic. The original was never run, and nothing was compared
with a DOS framebuffer, real audio or real timing.

Offsets are MAIN file offsets unless written `seg:off` or `DS:off`. 2CB4 offset
plus `0x33540` is the file offset.

## Dispatch

The script interpreter `CF5:8794` sends each opcode through one wrapper to one
handler. The duel context is `DS:E5B4`.

| Op | Case | Handler |
|---|---|---|
| `10` | `0x1C722` | setup `2CB4:125E` (`0x3479E..0x34A0E`) |
| `33` | `0x1CFDD` | end `2CB4:1824` (`0x34D64..0x34DD9`) |
| `34` | `0x1CFE8` | clash `2CB4:1736` (`0x34C76..0x34D62`) |
| `35` | `0x1CFF3` | motion `2CB4:14D0` (`0x34A10..0x34C74`) |

A person without a unit record makes the wrapper return before the handler.

## Timing and drawing

`CF5:2502(u)` only starts a countdown of `6u` ticks, and `CF5:24C4` waits for it. A
tick is 16.58 ms (`SBOPL2.COM` sets the PIT divisor to `0x1000` and counts 53 of every
256 interrupts). Every hold starts its countdown before it draws, so a step lasts at
least its ticks.

`2CB4:0CD6` stamps a frame's 6×6 tiles into one grid layer, and `2CB4:0C16` is the
only present. Participant 1 sits in layer 0 and participant 0 in layer 1, so
participant 0 covers participant 1. A rider at cell `x` is a 96×96 picture at
`(16+16x, 80)` inside the scene at `(16,32,416,208)`. The camera scrolls only the
background: the combat view's back and ground members, chosen by the terrain under
participant 1 at setup (`0x34877..0x348E6`).

Setup also draws two lower windows (`2CB4:0C3C`, then `1CB6:F752` with sides 2 and
3): portrait, name, level and class, then strength (person `+19` over 100), troops
over the maximum, and experience over 100. The labels are `DS:4FAA`, `4FBD`, `4FC2`
and `4FDD`. They are drawn once and not updated.

## Steps

Run poses repeat 1, 2, 3. `start` is `CF5:6280`, which ends any effect playing;
`stop` is `CF5:629E`; `wait` is `CF5:631A`, an untimed wait for the effect to end.

- Setup: song 18; each rider runs alone at cell 7 or 13 while the ground scrolls
  under it (sound 17, one 24-tick hold and eleven 4-tick holds each); then both ride
  in from −6 and 26 to 4 and 16; then a 12-tick hold. At least 188 ticks.
- Adjust (`115E`): both riders step toward each other, or apart with bit 7, 4 ticks a
  step on sound 17. Gap 4 starts 38; overlap starts 40, waits, and restarts 17.
- Approach (`0FFC`): one rider runs until four cells short, or through and on for
  code 10. Crossing the other starts 40 and waits.
- Clash: adjust 4, five rounds, adjust apart 4. Each round draws `rng(3)` for each
  rider (0 frames 4 and 5, 1 frames 6 and 7, 2 stands), then shows two 4-tick poses.
  Unless both stand, each pose draws `rng(2)` for sound 40 or 41. A 12-tick pause ends
  the round. At least 132 ticks. Nothing else in the scene draws random numbers.
- Motion codes, by `DS:5082` sound: 0 approach, frames 4 and 5, sound 40; 1 approach,
  6 and 7, 41; 2 frames 8 and 9, 23; 3 loads death art into bank 1 and shows frames
  0 to 4, then 21; 5 stands, 13; 6 and 7 as 0 and 1 with 38 and 39; 8 adjust 10; 9
  pans the camera; 10 runs through. Codes 0 to 3, 6 and 7 hold 6 ticks a frame and
  then wait for the sound. Code 4 makes participant 1 flee for fourteen 4-tick steps
  and leaves it erased.
- End: the map view returns and the song from before setup plays again.

Death and flee art always load into participant 1's bank, whichever rider the script
names, and a load replaces only some frames.

## Engine

`OriginalScriptDuel` in the battle session still owns positions, frames, the camera
and the RNG. `OriginalDuelStage` replays the same steps for the window from the
state before the opcode; the clash replays the session's draws from the RNG state
the session started from. A self-check runs setup, the clash, every motion code and
a flee against the session and compares positions, frames, camera and RNG. The
campaign holds the script while the steps play, as the source's handlers do. The
input replays and `--battle` apply a duel at once and show its end state.

## Not restored or not checked

- Effect lengths, so the length of every wait, were not compared with the original.
- A rider already past its mark walks away until a word wraps in the source; the
  engine jumps to the mark, as the session does.
- The panels' pattern fill and window frames; the engine draws its own panels.
- The disk loads at setup and death take real time that is not modelled.
- Camera values past 40 read outside the ground rows in the source; the engine
  clamps.
