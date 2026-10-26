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

## Native mapping

The producer exports the four menu texts and both save questions into local
GameData after checking their push/call sequences. The campaign window shows
the menu after the title picture. New game starts the source program,
resume asks for a native file, settings stays an explicit unrestored notice,
and opening returns to the title.

At a source `3D` prompt the window asks the original question and writes an
`OriginalCampaignResume` JSON file, by default under the user's Application
Support folder. It is native engine state, not an MSAVE slot; original slots
are neither read nor written. A resume point is produced only when the stage
is idle outside the battle palette and no other source operation owns the
host. It retains the VM state with its pending `3D`, shared person objects,
roster, RNG, money, stage snapshot, party carryover, the source `36`
checkpoint, the uncertain-return marker and the controller continuation
flags. Resume restores those values, configures the saved map, restores the
idle stage, and completes the pending `3D` as a performed save.

MAIN's own load path (slot dialog, `CF5:C456`, first-entry spawn) is not
replicated. A native resume therefore restores the saved native stage rather
than re-entering the map through the original load path.

## Verification

`--verify-play` accepts a `save-native` input and a `--resume FILE` option.
Locally, three save points in a 138-input replay (before the first battle,
after it on the world map, and on the chapter-one world map) were saved and
resumed. Each resumed run's final checkpoint equals the uninterrupted run's,
apart from the stage command cursor. The first resumed frame matched the
uninterrupted frame at the same point. Synthetic tests cover idle stage
restore, rejected non-idle or inconsistent snapshots, all-or-nothing person
replacement and typed file reading. The AppKit menu and panels were not driven
with real macOS input.
