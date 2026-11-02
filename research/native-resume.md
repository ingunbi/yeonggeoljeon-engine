# Save prompt, title menu and native resume

Static derivations from the pinned Korean DOS/V MAIN profile; no original
program was run. Offsets are MAIN.EXE file offsets.

## Original flow

Source opcode `3D` runs `0x22A62..0x22AA1`. It asks the DS:`305A` question
with the two-button selector (`CF5:3C5E`, mode two). Yes loops on `CF5:F0CE`,
which opens the slot dialog `CF5:B58C` in save mode `0x100` through
`CF5:BDBA` (`0x1F70A..0x1F781`). A cancelled or failed save asks the DS:`3073`
decline check; its No returns to the slot dialog. The handler then returns
zero, so the source cursor continues after `3D`.

MAIN's menu `CF5:C050` (`0x1F9A0..0x1FA17`) shows four DS:`2D38` items and
dispatches their DS:`2CEC` handlers: new game (`CF5:B536`), resume
(`CF5:BDAE`, which calls `CF5:BD1E` with one and `0x100`), settings
(`CF5:BFDE`) and opening (`CF5:C012`). main passes the chosen index to the
framework loop; a nonzero index sets its first-entry flag and calls
`CF5:C456` (`0x1E1E2..0x1E284`). Item three returns exit code zero, so
HERO.COM runs OPEN before MAIN again. The original slots are `MSAVE0..4.R3S`.

The field system menu (`0x22CD2..0x22DB6`) lists ten DS:`34E8` items and
dispatches DS:`3478` handlers. The world and settlement input tables
(DS:`3636`, DS:`36E2`) send input code `23` to it. Quit (`CF5:F044`) asks
DS:`3018` and sets map-loop flag `40`; load is `CF5:F152`; save calls the
same slot routine `CF5:F0CE` as `3D`. The other items configure scrolling,
speed, monitor, music and sound.

## Native mapping

The producer exports the four menu texts and both save questions into local
GameData after checking their push/call sequences. The campaign window shows
the menu after the title picture. New game starts the source program,
resume opens the slot list, settings opens the option list, and opening
returns to the title.

A secondary click on an idle town, palace or world map opens the field menu
with the exported labels. Quit reaches the retry selector through mask
`40`. Load and save open a list of five native slots. A list row can still
load a resume file from anywhere. Options are described below. The original
physical binding of input code `23` is not established.

At a source `3D` prompt the window asks the original question and writes an
`OriginalCampaignResume` JSON file into a slot under the user's Application
Support folder. It is native engine state, not an MSAVE slot. Original slots
are never written; the load list also imports them read-only, as described in
[the save note](original-saves.md). The native slot keeps its own title and date. A resume point is produced only when the stage
is idle outside the battle palette and no other source operation owns the
host: either at a pending `3D`, or at an idle field controller with no
running script (the field-menu save, recorded without a save offset). It retains the VM state with its pending `3D`, shared person objects,
roster, RNG, money, stage snapshot, party carryover, the source `36`
checkpoint, the uncertain-return marker and the controller continuation
flags. Resume restores those values, configures the saved map, restores the
idle stage, and completes a pending `3D` as a performed save; a field save
resumes the idle field controller.

MAIN's own load path (slot dialog, `CF5:C456`, first-entry spawn) is not
replicated. A native resume therefore restores the saved native stage rather
than re-entering the map through the original load path.

## Verification

`--verify-play` accepts a `save-native` input and a `--resume FILE` option.
Locally, three save points in a 138-input replay (before the first battle,
after it on the world map, and on the chapter-one world map) were saved and
resumed, and one field-menu save was taken in the chapter-one town after the
palace exit. Each resumed run's final checkpoint equals the uninterrupted run's,
apart from the stage command cursor. The first resumed frame matched the
uninterrupted frame at the same point. Synthetic tests cover idle stage
restore, rejected non-idle or inconsistent snapshots, all-or-nothing person
replacement and typed file reading. The AppKit menu and panels were not driven
with real macOS input.

## Options

Object DS:`7A80` holds the player's options, built at `1A406` (speed 2, scroll 1,
word `+4` zero). `OriginalSettings` keeps them per user, so replays and tests
always run the source defaults.

| Item | Source | Native effect |
| --- | --- | --- |
| 스크롤 단위 | `22832`, byte `+11` | Disabled. The labels at DS:`2FEC` pick 1, 2, 4 or 8. The field loop passes the value to `0:4F68` (`24212`), which writes byte `+11` of input device 0's 18-byte record at CS:`14FE`: the step of the keyboard-driven pointer while input is enabled. The engine has no keyboard pointer. |
| 속도설정 | `22BFE`, byte `+13` | The field loop waits speed x 3 ticks (`24818`), so normal is the known six ticks. Field time scales by 2/speed. 노웨이트 has no wait, and the engine uses six times normal. |
| 모니터 | `229AE`, word `+A` bit 8 | A grey filter on the whole canvas. A captured view does not show this filter, so it has not been looked at. |
| BGM, 효과음 | `228C6`, word `+A` bits 2 and 1 | The audio switches. |
| 음량 | `22BCE` | Handler index 8 opens the DS:`343C` list of music and sound tests, under a label that says volume. The engine maps by meaning: this row sets one output level, an engine addition. |
| 음악시간 | handler index 9 | The DS:`343C` list. Songs from DS:`312E` and effects from DS:`3364`, whose names also document every sound id. |
| 부대전투 | `27DC4`, word `+4` high nibble | Zero plays the enlarged view ([original-combat-view.md](original-combat-view.md)). Nonzero skips it and doubles the map effects and the prelude draws, as in the source. |
| 이동속도 | `27E2C`, low nibble | The walk step of the battle animator. |
| 적의 이동 | `27774`, bit `1000` | The camera follows enemy walks (`2C4D6`). With it off the engine skips a walk that has no visible cell, where the source still takes the time. |

## Engine additions

These have no source counterpart and never change game state.

- The field writes `Saves/slots/auto.json` whenever the idle field's scene or map
  differs from the last autosave. F5 and F9 (or the 게임 menu) write and read
  `quick.json`. Both use the same resume format as the five slots and appear in the
  load list.
- Holding Control multiplies the frame step by four for the field, the battle
  animator and the combat view. Plain lines close after six frames. Questions,
  lists and choices still wait.
- The dialogue log keeps the last 300 lines shown in the window.
- In attack targeting each enemy in reach shows the damage of the blow and the
  counter chance. The blow draws no random number (`0x31474`). The counter compares
  the defender's attack scalar with a draw below 150, so the chance is that scalar
  over 150 when the source would allow a counter.
