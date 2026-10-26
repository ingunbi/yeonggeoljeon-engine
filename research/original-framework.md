# Outer framework, battle exit and retry selector

These are static derivations from the pinned Korean DOS/V MAIN profile and
the examined HERO.COM launcher. No original program was run or modified.
Offsets are MAIN.EXE file offsets (load image plus header `0x6A00`).

## Battle-loop dispatcher

The framework map loop `0x1E1DC..0x1E3A7` enters the map kind held by the
game object and, for kind three, runs the battle loop at `0x1E31C`. Its raw
result is interpreted at `0x1E324..0x1E344`:

| Raw result | Effect |
|---|---|
| 1 | Restore the battle checkpoint and rerun the battle loop (`0x1E347..0x1E368`). |
| 3 | Add framework mask `20`. |
| 4 | Add framework mask `40`. |
| other | Call `CF5:C86C` (`0x201BC..0x2022E`), which enters script context `+0A`. |

Raw result one comes from the battle system menu (`0x27D12..0x27EA3`,
nine DS:`3AA0` items). Retreat asks the DS:`[3D1E]` question and writes
result one (`0x27D77..0x27DA3`) unless script context `+1CB` is set; that
field is the setup header's preserved-slot byte (`0x1C427..0x1C42D`), and
the refusal shows DS:`3D2E`. Quit asks DS:`3D4F` and writes result four
(`0x27E87..0x27EA3`). Source `36` saves the script context with its setup
rows (`CF5:7E4A`), the persons those rows name and the player object
(`CF5:AD5A`). Result one restores the same three (`CF5:7FE0`, `CF5:ADB4`)
and reruns the battle loop. RNG, cities, the game object and `7A76` are not
restored.

Opcodes `09` and `11` both write context `+0A`. A source `11` inside a
battle sets the raw result through `336FA` and selects the next map without
an interpreter return. The native host therefore records both producers and
enters the map only after the battle loop ends. The latest producer that
agrees with the VM's context map supplies provenance. A context map of kind
three would re-enter a battle through C86C; that path is not restored and
stops explicitly.

The native host records continuation owners when source `36` runs inside a
battle. On result one it restores the script context (keeping game field 4,
city objects, `7A76` and the device music), the setup-named persons, the
roster and money, then rebuilds the battle session with the continuing RNG.
The battle view shows retreat and quit with the exported labels and
questions. Locally, retreating after three rounds of chapter one's first
battle returned the units, person values, money and script position to the
battle start; quitting produced mask `40` and the retry selector.

After the dispatcher, `0x1E399..0x1E39D` leaves the framework loop when the
mask contains `04`, `08`, `20` or `40`. World and town loops translate
interpreter status seven to mask `20` and status eight to mask `04`
(`0x22250..0x22285`, `0x26491..0x264CA`). A source `29` inside a battle
writes raw result three as well, so both routes reach mask `20`.

## main and the launcher

`main` is `0x1E43A` (C runtime call at `0x127A4`). After the framework loop
returns (`0x1E546..0x1E551`) it tests the mask:

- `04` takes the ending branch first and returns exit code one.
- `20` or `40` calls the two-button selector `CF5:3C5E` with mode two and
  the DS:`2A2E` text (`0x1E5DD..0x1E5E8`). The selector creates its Yes
  button before No; their results are one and zero (`0x17736..0x1796B`).
- Yes returns exit code four. No calls `0x1E3A8`, which draws two pictures,
  waits for one input (`0x15EA6..0x15EBF`) and lets main exit with code three.

HERO.COM runs `B:MAIN.EXE` in a loop and dispatches its exit code through a
five-word table. Code zero runs `A:OPEN.EXE` and then MAIN again, one runs
`A:END.EXE` and stops, two prints a memory message and stops, three stops,
and four runs MAIN again without OPEN. A Yes answer therefore returns to
MAIN's own title menu, not to the opening program.

## Native mapping

`OriginalBattleExit` owns the dispatcher table and `OriginalFrameworkReturn`
owns the mask, the selector answer and the restart/exit outcome. The campaign
producer exports the DS:`2A2E` text into local GameData after checking the
examined push sequence; public source contains no original string.

The campaign window shows the selector over the current screen. Yes replaces
the campaign host with a new one, which shows MAIN's title menu as described in
[the resume note](native-resume.md). Original save slots and the `0x1E3A8`
pictures are not restored. No leaves a native
status line and closes the window on the next input. The replay driver accepts
`{kind:"retry-choice",index}` and stops after recording the outcome.

These rules are tested with synthetic results and masks. They do not
establish original timing, the in-battle restart producer for result one, or
complete campaign parity.
