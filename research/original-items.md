# Battle item use

Static derivations from the pinned Korean DOS/V MAIN profile; no original
program was run. Offsets are MAIN.EXE file offsets. Item names, descriptions,
refusals and labels stay in local GameData. The command window that reaches this
code is described in [original-screen.md](original-screen.md).

`0x2E0E6..0x2E833` runs when a unit chooses 사용한다 for a held item. It receives
the unit and the item id. A use ends by clearing the first matching inventory
slot and setting mask `0x80` (`0x2E807..0x2E82B`). Every refusal, every cancelled
pick and a declined question skip both, so the item stays held and the unit keeps
its action. Items cost no MP.

## Effect groups

The routine tests id ranges in this order.

| Item ids | Group | Picker |
|---|---|---|
| `0..2`, `0x10..0x12` | Class change | None; yes/no question |
| `0x13..0x1A` | Promotion | None; yes/no question |
| `0x22..0x2A` | Attack | Enemy, range code `tier` with bit 7 |
| `0x2B..0x2D` | Confusion | Enemy, range code `0`, `1`, `0` with bit 7 |
| `0x1B..0x20`, `0x34..0x36` | Recovery | Friendly including the user, range code `tier` with bit 7 |
| `0x2E..0x33` | Area recovery | None; yes/no question over the whole list |
| `0x21` | Bomb | Enemy, range code `0x81` |

Any other id, which includes all equipment, shows the DS:`4B64` refusal.

## Class change and promotion

Class changes read a six-entry table: ids `0..2` select the first three entries
and ids `0x10..0x12` the last three. Refusals are checked in this order:

1. Person zero cannot change class.
2. The target must differ from the current class.
3. The target must not be the base of the current class's family (`class/3*3`).
4. The target class's movement type must be able to stand on the unit's terrain.

After the question the routine writes the class, then rewrites the troop count
through the capped setter `0x1A892`, so troops fall to the new maximum.

Promotions read paired tables: eight required classes, with required levels of 15
and 30 alternating. The unit must hold the required class and reach the level.
The new class is the required class plus one. A promotion does not rewrite troops.

## Attack items

`family = (0x22-id)/3+2` with truncating division gives 0 for fire, 1 for water
and 2 for earth; `tier = (id-0x22)%3`.

The routine refuses fire when the environment lookup says rain, before any
pick. It then checks the target's terrain through the same four-entry table as
strategies. A refusal joins the family's terrain names between two fixed texts
(`0x2D90E..0x2D9CA`).

The effect calls the context dispatcher at `0x31E7A` with kind 3 and subtype
`family<<4|tier`. Kind 3 is the existing strategy damage producer without its
chance gate and without an attack contribution. Troop, morale, experience and
retirement writeback are the same as for a strategy.

## Confusion

There is no success roll. The target must not already be confused. Item `0x2D`
then visits the four neighbours of the target's starting cell in cardinal order
and confuses each unit on the opposite side from the user. Each target gets the
same retirement check as other effects, which retires a confused unit at zero
morale.

## Recovery

Kind 1 is troops, kind 2 is morale and kind 3 is both. Tier is `id%3` for
`0x1B..0x20` and `id-0x34` for `0x34..0x36`. The routine refuses a unit with
nothing to recover, then calls the healing routine at `0x2EE20` with subtype
`tier<<4|kind` and caster slot `FF`, the path that omits caster bonuses.

Area recovery uses tier `(id-0x2E)%3`, troops for `0x2E..0x30` and morale for
`0x31..0x33`. The routine snapshots the target list once, with the user first,
and asks one question.

The line after a single recovery tests the tier against 3, which never matches
because the tier is at most 2. The first text is therefore unreachable, and the
native line always uses the second.

## Bomb

The bomb draws `random(21)`, computes `(draw+90)*15` and removes the smaller of
that amount and the target's troops. If troops remain it draws `random(10)`, adds
30, and lowers morale by the smaller of that amount and the current morale through
the normal setter. A wiped-out target consumes no second draw. The bomb grants no
experience.

## Native mapping

`OriginalItemOperation` retains its continuation across retirement dialogue, as
`OriginalStrategyOperation` does, and `OriginalBattleFlow.manualItem` drives it.
`begin` performs every check without drawing RNG or changing state, so the view can
show a refusal before any effect. Replays use a `battle-item` input with `slot`,
`item` and an optional `target`.

Public tests use synthetic tables and people. They check the id table, refusal
order, RNG order and consumption. A local harness drove each group through the
menus against real data; that exercises view event methods, not macOS input
delivery.

## Limits

- Effect animations are not played. The routine at `0x2AB40` and its helpers make
  no random calls, so skipping them leaves the RNG timeline unchanged.
- Original item effects have not been compared with a running DOS game.
