# Original combat stat investigation

This is a small read-only static investigation, not an implementation of the
original combat rules or a recording of the DOS game. The examined `MAIN.EXE`
SHA-256 is `731c8d26a39fcd4e9fa41b142db9bd5913a496a2da5eaa1db798b7867850815f`.
All addresses are file offsets. Original bytes and disassembly remain in ignored
local research outputs rather than the public repository.

The source status and combat displays select a person object through the battle
unit's person identity. That object has stride 44 at DS:7A94. Its current troop
quantity is the u16 at offset +0x1E, returned by the getter at 0x209DA. The paired
maximum getter at 0x1AD08 depends on class byte +0x20, level byte +0x21 and two
source class tables at DS:1338 / DS:134C. The display consumers are 0x2D2CC..2D2F4
and 0x32E54..32E85; the ratio-bar consumer is 0x28806..2895D.

Displayed attack and defense are derived quantities. The status card calls the
wrappers at 0x2B1F0 and 0x2B20C, which pass the person object and battle-unit
byte +0x0C to the stat producers at 0x1A43E and 0x1A56C. Those producers depend on
person scalar fields +0x19 / +0x18 respectively, class, level, source class
tables and item slots. This investigation has not resolved all arithmetic-helper
and item effects, so the engine does not present these quantities as decoded raw
attack/defense fields or implement an inferred replacement formula.

A two-party combat context at 0x31E7A consumes the current quantity and selected
attack/defense producers. The actual final damage entry point, rounding, random
branches, counterattacks and quantity writeback still require tracing. Original
AI and victory-condition semantics also remain outside the implemented policy.
`BattlePolicy.original` therefore continues to return an unsupported outcome.
