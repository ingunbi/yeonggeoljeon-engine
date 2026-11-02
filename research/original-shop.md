# Item shop and city entry

Static derivations from the pinned Korean DOS/V MAIN profile; no original
program was run. Offsets are MAIN.EXE file offsets. Shop lines, item names and
prices stay in local GameData (`shop.json`, `combat.json`, `exploration.json`).

## Reaching a shop

A selected world city walks there first. Arrival (`0x23F3C..0x23F83`) writes the
current city, then probes kind two and five records with `[255,city]`. If no
record answers, `0x23F96..0x2402B` looks at the city type at offset 0x18. Types
three and four show a yes/no question (`0x23FBC..0x23FE7`) built from the city
name, a word from DS:`371E` and the format at DS:`3722`. Yes writes game kind
zero, the city index and entry byte one, and sets the game position to (11,13).
Other city types only pass through. The source also skips the question while
player field 0C, which holds the cursor enable, is zero. A native arrival always
comes from a pointer input, so the host does not model that case.

Walk marker seven in a town enters palace room seven by the usual room entry.
Native entry (`0x24BD6..0x24C1A`) then:

- selects music 0x0F and places actor `0376` at (15,11) with raw facing four in
  room seven;
- selects music five in a town, or music one for city 11 of chapter 3.

Other rooms keep their music. Actor `0376` is person 374. `0x25FE0` drops the
placement when the person's field 1C bit 0x80 is clear. For this actor class it
draws the standing period and no second number (`0x2607D..0x260B8`).

The merchant stands on a blocked walk cell. A talk still reaches them because
the route producer `0x25C06` seeds its flood at the goal without testing it, and
the final step is trimmed as for every actor.

Stock rows exist for some cities whose town map has no marker seven. How those
rows are reached, if at all, was not traced.

## Routine

Talking to actor `0376` runs `2CB4:3602` (`0x36B42`) instead of a kind three
record (`0x26A66..0x26A77`). The merchant's saved facing is restored afterwards
(`0x26AA1`). The native operation `OriginalShopOperation` has one case per
blocking source call, so an input file answers exactly what the routine asks.

The stock row is the player's city plus the chapter's city base
(`0x36B47..0x36B61`), eight bytes per row at DS:`56A2`, ending at the first 0xFF.

| Step | Source | Result |
|---|---|---|
| Greeting, then question and top menu at (0xE8,0x80) | `0x36B7B..0x36BDE` | Buy or sell. Cancel says goodbye and returns. |
| Stock list at (0x1A0,0x60), eight rows | `0x362E0..0x36351` | Cancel returns to the top menu. |
| Offer with the item window | `0x36356..0x364BA` | No returns to the list. |
| Money check | `0x364BD..0x364DA` | Short money refuses and returns to the list. It runs before the receiver is chosen. |
| Receiver list | `0x364E0..0x36643` | Cancel returns to the stock list. |
| Full receiver | `0x36646..0x36680` | Yes returns to the receiver list, No to the stock list. |
| Slots and confirm | `0x36683..0x36775` | No returns to the receiver list. |
| Purchase | `0x36778..0x367D4` | Fills the first empty slot, sets money, asks again. Yes returns to the stock list. |
| Owner list | `0x367E2..0x36892` | Cancel returns to the top menu. |
| Owner with nothing | `0x3689F..0x368C1` | Refuses and returns to the owner list. |
| Held items | `0x368C9..0x36958` | Cancel returns to the top menu. |
| Offer with the item window | `0x3695B..0x36AD9` | No returns to the held items. |
| Sale | `0x36AE5..0x36B3A` | Pays, clears the slot, asks again. Yes returns to the owner list. |

The people lists hold every person, in person order, whose field 1C has low five
bits zero and bit 0x80 set (`0x365B7..0x365D9`).

The buying price is item byte 0x0E (BAKDATA record byte 13) times ten
(`0x36C06`, `0x36372..0x36374`). The selling price is that byte times three,
shifted right twice, times ten (`0x36981..0x36988`). Money writes go through
`CF5:224C`, which caps the word at 10000 (`0x15B9F..0x15BA8`).

Three jump tables at `0x363AE`, `0x3650C` and `0x369C2` pick the word after an
item name for ids 6 to 62. Ids outside that range take the open word. The tables
are exported as they are, including entries that do not match the name's final
consonant. Color codes (ESC C digit) are dropped from exported lines.

## Windows

`CF5:151A` takes y, x, width and height at stack offsets 0x10, 0x12, 0x0E and
0x0C. That places the receiver's slot window at x 216, y 160, 112 wide and 144
high, with text at column 28 from y 168 in 16-pixel rows. The item window is at
x 112, y 160, 320 wide (`0x362C9`), and the value 0x80 is taken as its height.

These are source positions. The native view does not use them: a visit stays in
one engine window with the merchant's line, the list, a detail pane for the
highlighted row, and the answers along the bottom. The steps, their order and
what each answer does are the routine's. The window shows more than the source
does at a given step: prices in the lists, slot counts, the highlighted item's
description and the money after a purchase. A short-money row stays selectable
and draws its price in the warning color, because the source refuses after the
offer. Esc at a question answers No; the source question has no such key.

## Verification

Synthetic self-tests cover prices, the row lookup, every branch above, the money
cap, the blocked goal and the city question. Python tests cover the site checks.
A local replay went from a chapter-one town out to the world map, entered a
stocked city, walked into room seven, bought, refused, sold, and left through the
room and town exits. A native save in the room resumed to the same final state,
apart from the stage command cursor. Older replays kept their final checkpoints.

A local harness drove a real `NSWindow` with real `NSEvent` objects through hit
testing, the first responder chain and live timers, for this shop visit and for
a new game through the first battle's end of turn. The harness process was not
the active app, so AppKit's handling of a first click on an inactive app was not
covered and mouse events entered at the hit-tested view. Nothing here was
compared with the running original.

## Not restored

- The original window frames, positions and font.
- The source's temporary player field 0A change around the confirm questions
  (`CF5:6656`, `CF5:ACF6`), whose purpose was not traced.
