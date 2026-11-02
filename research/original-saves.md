# Original save slots

Static derivation from the MAIN loader and saver, checked against five local
slots. The import was exercised natively. It was never compared with a running
original.

`tools/prepare_saves.py` reads `MSAVEn.R3S` and `ESAVEn.R3S` into a local
`saves.json`. `OriginalSaveImport.swift` turns one row into an
`OriginalCampaignResume`, which `OriginalCampaignHost.importOriginal` loads
through the native resume path. Nothing writes to an original file, and the
engine never opens one at run time.

## Files

| File | Size | Role |
|---|---|---|
| `MSAVEn.R3S` | `0x2255` | Slot body. A slot whose first five bytes are zero is unused (`0x1EEC6`). |
| `ESAVEn.R3S` | `0x559` | Script context. MAIN does not check that it opened (`0x1ED77..0x1ED83`); the producer refuses a slot without it. |
| `MSAVE.R3` | `0x49` | New-game template only. |

The saver is `CF5:AE98` (`0x1E7E8..0x1E968`) and the loader is `CF5:B34E`
(`0x1EC9E..0x1EE84`). Both route through `CF5:F0CE`, so a field-menu save and a
`3D` save have the same layout.

The load reads `0x2235` bytes (`0x1ECFE`), 32 short of the file, so city rows from
26 up hold person constants left in the work buffer. No chapter has more than 26
cities. The importer reads only `cityCount` rows.

## MSAVE

| Offset | Size | Contents |
|---|---|---|
| `0x0000` | 5 | Date: BCD year, month in the high nibble in binary, BCD day, hour and minute (`0x1F08B..0x1F133`). |
| `0x0005` | 30 | Title, CP949: the HUD caption DS:`DB4C` (`0x1E80B`, read back at `0x1ED38`). |
| `0x0023` | 20 | Player: `+0` money, `+4` battle options, `+A` sound word, `+C` input enable, `+E` current music (FFFF none), `+10` current city, `+11` scroll, `+12` map chapter, `+13` speed. |
| `0x0037` | 9 | Game: `+0,+1` x and y, `+4` city selector, `+5` map kind, `+6` map index, `+7` entry mode. |
| `0x0040` | 9 | Return block, same layout, with the real return cell. |
| `0x0049` | 62 x 26 | Actors: `+6` word, `+8,+9` x and y, `+F` flags, `+15` facing. The word's `& 0xE00` is `0x200` for a person and `0x400` for a citizen; `& 0x1FF` is the identity. |
| `0x0695` | 384 x 18 | Person state: flags, role raw (field `+2B` less two), context 2 and 3, personal scalar, troop word, class, level, experience, eight items. Constants come from BAKDATA. |
| `0x2195` | 32 x 6 | City state; `+5` is the city flag byte. |

The packed map is `game+5 << 12 | game+6`, written at `0x1E22D..0x1E242`. It
overrides the saved context word: the world loader stores the chapter in `game+6`.

## ESAVE

| Offset | Size | Contents |
|---|---|---|
| `0x000` | 8 | Chapter, member, block, group base, as words. |
| `0x008` | 4 | Context city and packed map, both replaced on load. |
| `0x00C` | 4 | Actor cache owner city and map. |
| `0x010` | `0x174` | Actor cache, 62 x 6: person word, x, y, flags, facing. |
| `0x190` | 2 | Cursor, in the same domain as `instruction.offset`. |
| `0x192` | 2 | Busy: 0 none, 1 resume at cursor, 2 movement wait. |
| `0x196` | 2 | Cache dirty. |
| `0x19A` | 2 | Script music. |
| `0x1A6` | `0x1EF` | Setup, 45 x 11: person word, x, y, flags word, mode, parameter word, class, level. |
| `0x395` | 32 | Flags, MSB first. |
| `0x3B5` | 33 | Source list: count, then bytes. |
| `0x3D6` | `0x181` | Objective text, NUL terminated. Bytes past the NUL are stale. |
| `0x557` | 2 | Header bytes: turn limit and the second byte. |

## Load order

The title path runs `CF5:B34E`, reloads the script member at `CF5:7A86`, and
enters `CF5:A88C(1)`. Town and palace entry (`0x24A44`) re-read actors above the
prop count; world entry (`0x20E28`) re-reads all 62 and skips the entry automatic
wrapper at `0x20F3A`. Default spawn and default music are skipped.

A town or palace then runs the cache rule at `CF5:8708`: an owner mismatch sets
dirty; a match with dirty set clears it, re-places cached actors and selects the
script music. The importer calls the same native rule. All five slots are clean,
so that branch is covered only by a synthetic check.

Actors restore in slot order, which closes slot gaps. A person whose flag `0x80`
is clear does not spawn (`0x21F08..0x21F1A`). Town and palace facings pass through
DS:`38D8`. World positions are the raw doubled pair and the facing is direct. The
world camera centres on the first actor, which is also the follow target
(`0x20F61`, `0x21E71`).

## Busy word

`3D` has one operand byte. `3D 01` sets busy to 1 before the prompt (`0x1D1B9`), so a
load continues after the `3D`. `3D 00` leaves busy 0, so a load rejoins the idle
field: the record tail does not run, and the phase can ask again. This is the same
as a field-menu save. The importer decides only by the busy word.

Busy 1 restores as a pending `3D` with the record resolved from the cursor. Busy 2
is refused because opcode `01` turns input off for that wait. A busy 1 cursor that
does not follow a `3D` is refused; reaching one is not established.

Battle slots cannot exist. The writer is reached only from `CF5:F0CE`, whose callers
are `3D` and the field menu, and the battle menu has no save item. The script
walk behind that claim is not a proof over every conditional skip, so the importer
still refuses map kind 3.

## What a slot does not hold

| State | Consequence |
|---|---|
| RNG | The running stream continues, as MAIN's boot-seeded stream does. Later rolls differ. |
| Live units, round, weather | A preserved-slot battle after a load has no units. No save point sits between one in the static walk. Native throws if reached. |
| Retry buffer | Nil. The `36` records sampled run first after battle entry. |
| `+1CB` and objective pairs | Zero on the title path, so the restored header preserves nothing and enables no objective. One idle phase, `c4:m0:b6` group 20, falls between `03` and its battle. |
| Citizen wander timers | Native defaults. |
| Options in the slot | Kept out of the native settings. |

## Local result

All five slots loaded. Two continued past a `3D 01`, and three rejoined the idle
field. The explorer then played each to the ending with its boosted test policy,
which is not a measure of balance. The load sheet opened a slot through real
window events below the app-activation gate. Unknown fields remain `player+2`,
`+6`, `+8` and `ctx+1B9`. No slot here was taken in a town.
