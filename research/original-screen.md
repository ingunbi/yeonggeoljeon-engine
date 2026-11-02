# Field and battle screens, HUD and in-canvas prompts

Static derivations from the pinned Korean DOS/V MAIN profile; no original
program was run. Offsets are MAIN.EXE file offsets. The story producer
(`tools/prepare_story.py`) reads these facts from MAIN bytes and refuses a
build whose instruction shapes differ from the examined profile.

## Original screen routines

The field screen routine `CF5:C456` (`0x1FDA6..0x1FE2C`) loads AX with zero
and calls `CF5:520E`, which blits PACKGRP member 0 (a 640×400 picture) at the
origin. The map is then drawn into the frame's black window, the source
viewport `(16,16,512,320)` that the scene and map producers already record.
The battle routine (`0x1FE2E..0x1FE69`) calls the same blitter with AX one, so
member 1 is the battle frame. See [Battle screen](#battle-screen).

`CF5:51B2` draws portrait 0 into the upper-right slot. The call at
`0x1FE15` passes its x and y in AX and DX; the slot is 64×80.

Four HUD writers share one instruction shape: push height and clear colour,
load x, y and width into AX, DX and BX, call the rectangle clear `CF5:52EE`,
then push a text column (in 8-pixel cells), the same y and DS:`6390`, and call
the text cursor `CF5:091E`. The producer accepts a writer only when its text
row equals its cleared row.

| Field | Writer | Value | Format |
|---|---|---|---|
| caption | `0x1FC5E..0x1FC8E` | DS:`DB4C`, written by source `0B` through `CF5:C340` | `%s` |
| money | `0x1FCB2..0x1FCE8` | player object `7A80+0` through `CF5:220A` | `%5u` |
| level | `0x1FCEA..0x1FD22` | person 0 (DS:`7A94`) `+21` through `CF5:7572` | `%4u` |
| territory | `0x1FD24..0x1FD62` | city of player `7A80+10` through `CF5:210E`/`2118` | `%6s` |

Local `story.json` keeps each writer's rectangle, clear colour, text origin,
format and source offsets under `screens`. Public tests use synthetic MAIN
bytes; the optional real-file test checks that every HUD rectangle lies
outside the viewport and inside the 640×400 frame.

## Native mapping

Outside the title, ending and battle palette, the campaign view draws the
member 0 frame, clears the viewport, draws the stage inside it, and fills the
HUD from native state: portrait 0, player money, person 0's level and the
name of the current city in the current chapter. Captions go to the caption
box instead of the old top-left text. `--verify-play` and `--verify-campaign`
frames use the same path.

Prompts that the original draws with its selector and window primitives are
shown by a native overlay inside the viewport:

- the 3D save question, its decline check and the retry prompt, with Yes
  first, as in `0x164A9..0x165C4`;
- scenario choices and record menus;
- MAIN's title menu and the right-click field menu, with unrestored items
  disabled;
- party selection, which toggles rows through the source selection rules
  (fixed prefix, capacity) and confirms on its last row;
- field and battle dialogue and retirement lines, which wait for one input;
- the item shop ([original-shop.md](original-shop.md)).

All of these share `CanvasTheme`, an engine design with no original basis: one
surface color, rounded cards, a gold accent and the system font. The MARK Yes
and No pictures are no longer drawn by these windows. The canvas now fills the
window and centres. The old status bar under it is gone: script progress stays
in `--verify-play` reports, and the window shows only an error, a notice or a
state the player must know. In battle the turn, the selected unit and hints float
over the map window, and a finished hint fades after four seconds. Replay frames
keep the older dialogue drawing in `Renderer`.

Arrow keys move the selection, Return or Space chooses, and Escape or a right
click cancels where the menu allows it. Long lists scroll inside the
viewport. Scene dialogue is drawn in the same panel position by the renderer.

## Battle screen

The battle setup (`0x2895E`, object DS:`E1BC`) receives its map window from
`0x270B4`: `(16,32,416,352)`, thirteen by eleven 32-pixel cells. Larger maps
scroll. The scroll position is kept in half cells at `+8` and `+0A`, and every
writer clears its low bit, so the window aligns to whole cells.

Two routines move it. `0x2927E` centres on a half-cell position and clamps to
the map. `0x2997E` runs for unit moves: it does nothing while the unit is within
six half cells of the centred position, then recentres under the same clamps
with two further edge rules. The original animates two half cells per step; the
native view jumps to the target.

| Element | Source | Native use |
|---|---|---|
| Frame | PACKGRP member 1, `0x1FE39` | Drawn behind the map window |
| 기능 button | `(16,8,64,16)`, pressed art at `0x27CB5` | Opens the menu below |
| Title box | Text at column 28, width 22, `0x28A52` | Map name line |
| Force box | Column 56, width 10, y 40, `0x294C6` | Force of the list's side |
| 아군 / 적군 | `(528,32)` and `(560,32)`, 32×32, `0x287B0` | Switch the list |
| Unit list | `(448,72)`, ten 20-pixel rows, `0x29386..0x2968E` | Rows below |
| Minimap | Base `(456,280)`, 4 pixels per cell, `0x2898C` | Rows below |

Map names come from HEXZMAP member 58, one line per map. `0x282DC..0x28364`
copies double-byte characters only, so digits and spaces end a name, then
appends the DS:`3DFF` suffix. Force names are the fifteen DS:`0F1E` entries plus
the DS:`3EB0` suffix. Force fourteen borrows the side leader's force.

The list has a friendly side of slots 0 to 14 and an enemy side of slots 15 to
44. Rows are built at `0x29500..0x295D0`: on the friendly side, live units of
force zero come first. Other live units follow on both sides, and retired units
come last with the DS:`3EB6` text. The enemy side skips the first pass, so a live
enemy of force zero is not listed. Name colours come from `0x2C668..0x2C6DF`.

A live row shows a gauge from `0x28806`. The bar is 88 pixels wide and is black
under a repeated 8×10 MARK tile. The tile depends on tenths of current over
maximum troops: seven or more, three or more, or below three. The text is
`%4u/%4u`.

The minimap needs no separate art. `0xD86E..0xD9BF` ranks the four most frequent
colours of each 16×16 map tile, with ties going to the higher colour index, so
an absent colour resolves to fifteen. Each tile then becomes two by two pixels
through `0xD5FC`. The producer applies the same rule to the map tiles. Units are
4×4 marks in colour 2 for slots below 15 and colour 1 for the others
(`0x2988A`). The visible cells are outlined in colour 6 (`0x291CC`).

The 기능 button lists nine DS:`3AA0` items. The native menu shows all nine and
enables 턴 종료, 총퇴각, 승리조건 and 게임종료, whose handlers are restored; the others
stay disabled.

### Victory conditions

`0x27876` draws a 320×192 window at `(64,96)` with two inner boxes. The header
joins the chapter label, from DS:`3C78`, and the battle name through DS:`3C82`, and
the right side prints DS:`3C8F`. The text box shows the interpreter's objective
buffer at `D4DC+0x3C8`, which source opcode `30` fills. The drawer at `0x16110`
fills a line up to 34 half-width columns, never splits a double-byte character and
stops at a line feed. The window calls it from row 152 in steps of 32 while the row
stays above 216, so two lines fit.

The routine has one flag. The menu passes zero, and the turn box then shows the
current turn over the limit through DS:`3C98`. The first friendly phase passes one,
and it shows only the limit through DS:`3CB0`. Both wait on the button, which is the
third MARK member 0 picture at `0x19F0`.

The friendly phase routine at `0x27A3E` opens the window while the round is zero,
then shows the DS:`3D20` side notice every friendly phase. Replays skip this opening
because it changes no game state.

The formatter at `0x172D8` sends `%u` and `%w` to the same branch.

### Terrain window

A left click reaches `0x27C7A`. With a unit under the pointer it starts the
command routine; otherwise it calls `0x2A5F4` with the pointer's cell. A hidden
enemy (mask `0x20` clear) does not count as a unit here (`0x27BB2..0x27BC7`).

The routine works in sixteen-pixel units. Column `2x-scrollX+1` and row
`2(y+1)-scrollY` give the cell's corner. The 128×80 window opens two units right
of the cell, or eight units left from column 14, and three units higher from row
12. It copies the 32×32 cell from the screen to its own `(8,16)`, prints the
terrain name below that, and prints the DS:`3F62` heading to the right.

The value below the heading comes from DS:`405E`, the table the damage producer
already uses. An entry of 255 prints DS:`3F6B`, and both forms then get DS:`3F6D`,
so a cell a unit cannot enter reads `-%`. Terrains 8, 13 and 14 add the DS:`3F75`
text on the bottom row. Those are the same three terrains the turn order treats
as recovery cells. The window stays until any input.

The routine also watches clicks on a block of cells at the top left and compares
their bit pattern with DS:`3F56`. A match sets mask 2 of DS:`3A3C`, which enables
a unit diagnostic text at `0x2D3C7`. This hidden switch is not restored.

### Message modes

The message routine at `0x175AE` takes a mode. Modes 0 and 3 wait a fixed number of
timer units and close early on input. Mode 1 waits for the button and mode 2 asks
yes or no. The native view gives mode 0 messages a two-second timeout. The real
duration depends on a timer rate that was not established.

Eighty-four call sites reach this routine. A static sweep compared each text offset
with the producers. Battle lines now play as native notices over the map:

| Line | Site | When |
|---|---|---|
| Ambush, by side | `0x31926` | A hidden attacker or damage caster shows itself. |
| Level and learned | `0x1A92F`, `0x1A9A0` | One per level, then mode 1 for that level's strategies. Only the first thirty strategy rows teach. |
| Strategy used | `0x2E8B8` | A computer caster, before its effect. |
| Intent lines | `0x2E922`, `0x2EA68`, `0x2EBA4`, `0x2ECFA` | A player's caster. The native view shows them on the status line while choosing. |
| Confused, worse, missed | `0x2D596`, `0x2D5BF`, `0x2D8E3` | The outcome of a confusion or morale strategy. |
| Morale down, healed, still confused | `0x2EC92`, `0x2ED61`, `0x2EF7E` | Outcome lines. |
| Recovered | `0x2B6F7` | The upkeep or morale roll clears confusion. |
| Failed strategy | `0x31E6B` | A zero-damage strategy with the enlarged view off. |
| Turn and weather | `0x28139` | Here before the player's phase line, not before round events. |
| Delay retreat | `0x281AA` | The round reaches the turn limit. |
| Closing bonus | `0x27FB1` | Over the field after a win with a bonus byte. |

Texts left out are the hidden command mode (`0x23E13`, `0x274B4`..`0x27720`), the
disk prompts replaced by native slot windows, and a leftover Shift-JIS string at
`0x33F01`. A counter's ambush line draws over the old scene in the source, and over
the map here.

### Unit commands

A click on a unit starts `0x2D9D4`, which owns one unit's whole turn.

The move step (`0x30ED2`) refuses a unit in source order: not friendly, not under
player control (mask 4 or order mode other than 7), confused (mask 2), finished
(mask `0x80`). Each refusal has its own text, and the unit's move range stays
visible behind it. A ready unit shows its range and waits for a cell. Its own
cell skips the move. A cell outside the range shows the DS:`4D3C` text.

The command window then opens beside the unit. `0x2AA26` places it one cell to
the right. Past x 224 it moves left by 160, and below y 272 it stops there. Each
nested window steps sixteen pixels from its parent, in the direction it was
pushed.

The DS:`430C` table has eight entries, but the routine only uses four of them
plus a fifth from `E5AA+0`. That byte is set to `FF` at `0x335A8`, and a static
search found no other writer, so the native window omits 개문, 결괴 and 방화.

| Entry | Handler | Native behaviour |
|---|---|---|
| 공격 | `0x30DC2`, picker `0x29ADE` | Red cells; a click on an enemy attacks |
| 책략 | `0x2DB5C` | List, then the existing target selection |
| 도구 | `0x2DE42` | 사용한다, 준다, 버린다, 본다, then an item list |
| 대기 | `0x2DDA2` | Sets mask `0x80` through the existing wait |

The picker has its own refusals: nobody in range, the wrong side, and a cell
outside the range. It returns to the window when cancelled.

The strategy list shows every ability the level allows, in id order, with its
cost. An ability the unit cannot pay for stays listed but disabled, and so do the
five fire abilities in rain. Class 17 has no list.

The item menu needs at least one held item. 사용한다 runs the
[item use routine](original-items.md). 본다 shows the name and the DS:`21C8`
description. 버린다 clears the first matching slot and does not end the turn.
준다 picks a friendly unit in range code 1. It fills the receiver's first empty
slot, clears the giver's first match and ends the unit's action, and it refuses
when the receiver is full. Item records keep twelve name bytes, and the
constructor at `0x1B162` stores the record's own index, which selects the
description.

A hidden unit (mask `0x20` clear) keeps its cell and gets the two DS:`4866`
entries instead. 기습 uses the attack handler. 해제 asks the DS:`48AA` question and
sets the mask, after which the normal window opens.

Cancelling the window clears mask `0x40` and returns the unit to its origin
(`0x2DE08`).

### Native input

- Arrow keys and the wheel scroll the map or the list under the pointer.
- A click on the minimap centres there.
- A click on a list row centres on that unit and shows its details.
- A right click or Escape steps back one level. With nothing selected it opens
  the 기능 menu.
- Return ends the turn when no unit is selected. During strategy targeting it
  confirms the target.

The list and scroll positions are view state. They are not part of a save and
do not change replays.

## Modern layout

The app starts on an engine layout, and 보기 → 원작 화면 틀 (⌘⇧F) switches to the
original frames at any time, including during a battle. The choice is kept
between runs. Replays and `--battle` always use the original frames. This layout
is engine presentation and has no original basis. Game rules, routes, text and art
are unchanged.

- The window opens at 1024×640 and keeps the 8:5 shape.
- In the field the 512×320 map window fills the canvas, at exactly twice its
  pixels at that size. Clicks map back through `CanvasFieldMap`. A card shows the
  leader's portrait, the current territory, money and level; a chip shows the
  source caption; a button opens the field menu, which a secondary click also
  opens. The card hides while a shop window is open, because that window shows
  the money. Pictures such as illustrations and the title keep the 640×400 canvas.
- A battle uses `OriginalBattleLayout.modern()`: a slim bar with the function
  button, title and turn over a map of fifteen by twelve cells instead of the
  source's thirteen by eleven, and a sidebar with the force, list tabs, unit list
  and small map. Command and terrain windows open right next to their cell. The
  same scroll and follow rules run on the larger window, so what is on screen at a
  given moment differs from the source, and the source's window placement rules
  apply only to the original frames.

## Field icons

The original frame has four icon cells at x 544 and 584, y 240 and 288, 40 wide and
48 high (DS:`3514`). The handlers at DS:`3636` run in that order. The modern layout
shows them as buttons at the top right, and the original frames accept clicks on
the cells.

| Cell | Handler | Action |
|---|---|---|
| 0 | `0x23A88` | 스토리 정보 shows the scenario's objective text, set by source opcode text. |
| 1 | `0x23982` | A two-item menu for the person screen and item exchange. |
| 2 | `0x23AF8` | The whole map on a world map, and a refusal anywhere else (`0x23D7D`). |
| 3 | `0x22CD2` | The field menu. |

The person screen (`0x23230`) lists the joined people of the first person's force,
in person order (`0x23289..0x232BC`). Its detail (`0x22DB8`) has the name, class,
level, troops, attack and defense at morale 100, three rated scalars and the items.
The native window shows the scalars it can name, and it shows the detail beside the
list instead of after a choice. Its 경험치, 지력 and 소지품 labels are engine words.

Item exchange (`0x23560`) shows two people and moves a clicked item across. A full
receiver refuses with sound two (`0x2386F..0x238AC`). Otherwise the receiver takes
its first empty slot and the giver loses its first match (`0x238CB..0x238F3`). The
native window takes the same transfer in three steps: who gives, which item, and
who receives.

The whole map (`0x23B60..0x23D5A`) lists cities with both low flag bits and a
placed position, in city order, beside a small map. Choosing one starts the same
walk as clicking it. The source small map is a separate picture; the native window
scales the world picture instead.

## Limits

- The original font, text colours and the window frames drawn by the
  dialogue and selector primitives are not restored. The overlay panels are
  engine presentation, not original pixels.
- Panel positions are engine choices that keep the frame visible; they are
  not source coordinates.
- The command windows use the native panel, not the `0x3310` window pixels.
  Unit walks and attack effects play as described in
  [original-battle-sprites.md](original-battle-sprites.md).
- A discarded item leaves the native list at once. The source list is built once
  per entry, so it keeps showing the discarded item until the menu closes.
- The third button beside 아군 and 적군 has no restored handler.
- The native view opens the friendly list at battle start. The list object
  starts closed at `0x289CD`; when the original first opens it was not traced.
- `0x2C52C` forces force zero under a condition on a segment byte that is not
  traced, so that branch is not restored. Hover highlighting is replaced by the
  inspected row.
- Scroll animation, the original scroll input at `0x28F9C..0x29067` and the
  text font metrics are not reproduced. Follow runs once per finished action,
  not per step.
- Frames are offscreen captures. They do not verify macOS input delivery or
  original-runtime pixel parity.
