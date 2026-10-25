# Battle engine: source facts and prototype policy

The battle catalog and runtime have different responsibilities. Original file
readers retain source placement, faction, terrain and unresolved statistics.
The native battle model validates an executable grid and acts on **export-local
placement identities**. A person identifier, source record ordinal, and actual
DOS runtime slot retain separate meanings. Original placement allocation can
depend on unresolved campaign conditions; its runtime slot remains unknown.
A person identifier never substitutes for a placement identity. An unknown source value is not
automatically a zero or an engine default.

## Original-rule support

The examined Korean DOS/V `MAIN.EXE` has SHA-256
`731c8d26a39fcd4e9fa41b142db9bd5913a496a2da5eaa1db798b7867850815f`.
Earlier source-bound static notes establish N/E/S/W neighbor order at file
`0x2FCD2..0x2FF19` (direction table DS:4D1C), class-dependent terrain costs and
hostile occupancy checks at `0x2FF1C..0x302A3`, and synchronous scripted movement
at `0x2F954..0x2FA4F`. These observations do not establish normal player turn
rules, combat damage, enemy AI or battle victory conditions.
The reference is the previous local investigation's
`research/town-motion/battle-cinematic.md`, source-observations section; its
separate engine-integration discussion is not an implementation input here.

`BattlePolicy.original` therefore reports an unsupported result. It never
silently substitutes the prototype policy. No claim of original combat parity
is made by a successful prototype battle.

## Explicit experimentalV1 policy

This is a small deterministic engine policy for exercising selection, routing,
movement, attack, wait, turn changes, AI and outcomes while source rules are
still under investigation. Callers must select it explicitly and display that
it is an experimental policy, not the original game's combat.

- The board is an established orthogonal grid. All cells have prototype cost 1.
  Original terrain IDs remain source data and do not imply prototype passability.
- All living occupied cells block movement. One unit may move once, then attack
  or wait. Attacking consumes both remaining movement and the action.
- Every unit has separate effective prototype values: max HP 100, attack 25,
  defense 5, movement 4, Manhattan attack range 1. Original statistics are kept
  unchanged in the definition and are not overwritten with these values.
- Damage is `max(1, attack - defense)`, without randomness or counterattacks.
- Controlled side 0 and enemy side 1 alternate. Unknown factions are unsupported.
- Enemy decisions use ascending slot order, attack the lowest-HP adjacent enemy
  (tie: lower slot), or move to minimize opponent distance (ties: lower movement
  cost, then y, then x), attack, or wait. This is not original enemy AI.
- Victory or defeat means elimination of the currently active opposing or
  controlled roster respectively. Hidden reinforcement definitions are not
  automatically activated and original script objectives are not implemented.

If a source battle has unresolved campaign-dependent placement conditions, the
exporter may retain those records in `conditionalUnits` with unknown activation
and mark `rosterScope` as `unconditional-placement-records-only` and
`originalRosterComplete` as false. The prototype can exercise the established
unconditional subset, but does not evaluate the conditions as false. The native
definition and snapshot retain this coverage distinction and unresolved count.

Snapshots and event traces retain the policy and effective-stat origin.
Synthetic regression tests contain no original game text, graphics or battle
data. Real-file checks are separate local opt-in evidence.
