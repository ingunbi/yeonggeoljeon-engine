# Battle-resource and placement observations

Examined `MAIN.EXE` SHA-256:
`731c8d26a39fcd4e9fa41b142db9bd5913a496a2da5eaa1db798b7867850815f`.
Offsets below are file offsets. These are read-only static derivations; original
DOS execution and framebuffer comparison have not been performed.

## Map geometry and pictures

`HEXZMAP.R3` has 59 LS11 members in the examined edition. Members0..57 are maps;
member58 is text and is not treated as a map. Each map begins with two even
picture-grid dimensions, followed by one byte per16×16 picture cell, followed by
one terrain byte per32×32 battle cell. The battle grid is half the picture grid
on both axes. MAIN `0x26DF1..0x26E72` reads each dimension, shifts it right once,
copies four times the battle-cell count for picture IDs, then copies exactly the
battle-cell count for terrain. Terrain bytes are retained literally, including
uninterpreted values; terrain IDs do not establish movement costs.

MAIN `0x26C9C..0x26CEF` loads `HEXZCHP` member0 at the start of the tile bank and
the selected member at byte`0x2800`. Member0 contains80 planar16×16 tiles;
members1/2 contain174/175. The selector at `0x2827A..0x282AA` tests the map index
against19 words at DS`0x3DCC` and chooses member2 for a match, member1 otherwise.
The exporter reads this source table rather than hardcoding its map list.

The default color palette is source slot3. MAIN `0x20183..0x20194` sets game
field5 to3 through `0x1E628..0x1E635`; `0x15B3A..0x15B44` reads that field.
Palette helpers `0x18346..0x18372` use its low nibble and `0x182CE..0x18345`
selects48 bytes at DS`0x1050 + 48*slot`. Monochrome settings and original
framebuffer parity are separate unverified behavior.

## Placement programs

Opcode03 (`0x1C3F2..0x1C539`) clears the45-placement table, consumes11 header
bytes and30 records of9 bytes. Opcode22 (`0x1CB0D..0x1CC8E`) consumes a side
replacement selector and30 records of13 bytes. Each record retains its literal
person, x/y, side, conditional-flag and visibility operands. Source side operand
zero is inverted into placement flag bit0=1; a nonzero operand yields bit0=0.
The native display side uses0 for source flag0 and1 for source flag1.

MAIN `0x26E8C..0x27010` constructs the live roster from that table. Placement flag
bit1 suppresses initial activation; its producers are the final9-byte-record
operand or13-byte-record byte7. Campaign-conditional eligibility remains unknown
until the campaign state executes the corresponding source conditions.

The exported unit `id` is a stable identity local to a placement producer. It is
not a person ID or a recovered DOS runtime slot. Original insertion selects the
first available45-table entry, so unresolved conditions can change slot allocation.
The source ordinal, producer and unresolved runtime slot are preserved separately.

## Catalog limits

The current local catalog contains60 distinct source kind3 map-load sites and58
map pictures. This is not a claim that the original game has exactly60 battles or
that all60 definitions are playable. IDs use chapter/member/block, with a suffix
for later distinct map-load sites in the same block; shared instruction tails
retain a single identity through the exporter-owned identity helper.

Placement producer inheritance is a lexical projection, not an executed campaign
path. Only unconditional placement records populate `units`; `conditionalUnits`
preserves the unresolved records without declaring them inactive. Every exported
definition has `originalRosterComplete:false`. Unknown HP, damage, class movement
and objectives remain null. The native original-rules policy must reject these
definitions; an explicitly selected experimental policy may test engine mechanics
with the documented partial roster without claiming original combat behavior.

All pictures, original strings, placements and verification records are generated
only in caller-selected local output. They are not part of the public source tree.
