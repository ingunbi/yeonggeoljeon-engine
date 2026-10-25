# Script battle orders and inventory gifts

These are static source derivations for the examined DOS/V profile. Original
instructions, item values/names and resource payloads are not embedded here.
The campaign format owner parses operands once; `OriginalScriptBattle.swift`
consumes its typed instruction arguments.

Opcode `0x1C` (`MAIN0x1C946..0x1C9E5`) changes native AI orders and goals. It
does not set combat stats. The common method (`0x3385A..0x338A5`) finds the first
matching person among all45 runtime slots, including reserves/retired slots.
When the person's affiliation low bits are nonzero it clears unit condition
mask4 and passes the imported mode lookup into the source mode setter.

Selectors0/1/2 then consume and discard a word. Selectors3/5 resolve a target
person to its first runtime slot and set the preferred-target byte. Selectors4/6
consume typed x/y bytes and store a goal only when the class can traverse its
terrain; that method also clears the preferred-target byte. These later setters
are independent of the common affiliation gate. The target setter requires
both person lookups; the coordinate setter clears mask4 before its passability
test. Source goal coordinates remain stored when setting a preferred target.
An out-of-board source lookup remains unsupported because adjacent raw memory
is not interpreted as part of the map.

Opcode `0x1B` (`0x1C902..0x1C943`) grants its byte item ID. Its recipient is
person0 outside a battle map, or the explicit battle-context+7 person for map
kind3. That current-person field belongs to the campaign/battle host and must
not be inferred from the last actor or from similarly numbered script fields.

The inventory method (`0x1A6EC..0x1A88F`) first inserts into the first empty one
of eight slots. Full inventory invokes player replacement input. Cancellation
retains the previous inventory. After choosing an old item, the source searches
its first matching item-ID slot; selecting a duplicate therefore replaces the
first match. `grantScriptItem` preserves those rules. Missing replacement input
stops explicitly rather than silently discarding or overwriting an item.

Synthetic integration tests cover mode/affiliation separation, retired-slot and
first-match lookup, blocked-goal partial effects, retained coordinates, unused
word operands, item insertion/duplicates and full-inventory replacement. They
do not establish original GUI presentation, a completed campaign or live DOS
execution parity.
