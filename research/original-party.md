# Original party selection and preserved deployment

These are static derivations from the examined original `MAIN.EXE`, not an
original-runtime comparison. The new code is in `OriginalParty.swift` and uses
typed people, roster, movement and combat facts. Original table bytes and
disassembly remain local ignored research outputs.

The battle-header first byte is normalized to a boolean by
`0x1C427..0x1C42D`. Its native name is `preserveFriendlySlots`: it controls live
unit carryover, rather than requesting the separate party-selection UI.
Original setup state contains 45 dense eleven-byte rows. A cleared person word
does not erase that row's coordinates or other fields.

Opcode23 enters the party UI at `0x36122..0x36243`. Selection uses fifteen word
slots, a fixed prefix and a capacity derived from friendly named/manual people
plus dynamic setup placeholders. Eligible candidates share person0's
affiliation and have person-flag128. The ascending person scan stops after 66
appends; it refills eligible people's troops even when they are not selected.
Named setup rows also refill troops, including enemy rows. Candidate ordering
fixes index0, swapping person0 into it when present, then performs the original
nested swaps by imported class rank and descending level
(`0x34EB6..0x34FAE`).

Toggling retains holes and fills the first empty selection slot; the fixed
prefix cannot be removed (`0x356D4..0x35843`). Confirmation compacts selection
slots in their source order. It changes only placeholder person words, retaining
coordinates and flags (`0x3500A..0x350A1`). Signed and unsigned placeholder tests
differ in the original producers: confirmation's signed comparison excludes
FFFF, while preserved deployment's unsigned comparison includes it. The native
code retains these differences, the literal person0-default-word behavior and
the source cleanup bound instead of replacing them with a generic party list.
The optional inventory-management phase preceding deployment selection remains
a separate operation; this kernel prepares the deployment phase.

For preserved entry (`0x27016..0x2726B`), friendly runtime slots retain identity,
HP, MP and morale. Enemies are rebuilt by the normal enemy initializer. The
header's third byte can reset the round index, while weather remains preserved.
Inactive friendly slots clear the original condition/action mask and consume
matching named rows or an unsigned placeholder from the first fifteen setup
slots. All matching named rows run, so a later row can relocate the same unit.
An all-FF fallback row is consumed even though its coordinate255 makes the
activation return without placing the unit.

Activation (`0x2B982..0x2BA60`) applies sprite flip only when changing status1
to status2. Flip is flag16 in the live flags byte; live byte8 remains AI
priority. The spawn-marker search (`0x2B068..0x2B0ED`) is depth-first in imported
cardinal order with depth5 and no visited set. Occupied and blocked nodes still
recurse. It is not replaced with a breadth-first nearest-free search. A source
marker that remains FF has unresolved raw-coordinate behavior and produces an
explicit unsupported result in the native kernel.

On victory result2, `0x27F90..0x28019` awards the battle's byte24 EXP bonus to
active friendly slots, then changes every active slot to status1. It does not
refill HP, MP or morale. Other result values skip this operation. The returned
carryover snapshot retains all original live slot identities, round and
weather; it is not a compact list of surviving people. Preserved entry keeps
old enemy identities until each is overwritten by a new enemy or cleared by
the initializer's final unused-slot reset. Enemy target setters run at their
source point during this sequence, so they can reference an old slot that is
cleared later.

The native battle constructor uses the same activation kernel for fresh and
preserved deployment. Hidden/reserve units retain FF coordinates until a
successful activation. Fresh enemy class/level assignment precedes MP/HP
production; friendly MP/HP resets follow their activation. The caller owns one
canonical setup table and receives its fallback mutations through an inout
argument. Shared-person updates use a transaction: any unsupported producer or
failed board validation restores person values and leaves the caller's roster
unchanged. The session stores no second roster copy.

A preserved friendly status2 slot would outlive the source occupancy-grid clear
without a reactivation. That path needs occupancy state independent of live
status/position and remains explicitly unsupported by this constructor.
Ordinary victory carryover converts active slots to status1 before entry.

`prepare_party.py` imports the class-rank byte lookup window and person0 default
word into local `party.json`, with examined-source identity and preservation
checks. Public tests contain synthetic people, tables and setup rows. They
cover eligibility/order, selection holes and bounds, row preservation, source
comparison quirks, DFS placement, flags/priority aliasing, carryover and victory
EXP. An opt-in original-file importer check verifies local bytes and source
preservation; it does not establish original GUI behavior or a full campaign
playthrough.
