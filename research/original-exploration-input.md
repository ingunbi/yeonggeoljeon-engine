# Original exploration input and arrival

These are static derivations from the pinned MAIN profile. No original DOS
executable was run. Original maps, direction tables, city values and decoded
art stay in ignored local output; public regressions use synthetic geometry.

`OriginalExplorationInput` owns selection plans and arrival validation.
`Runtime` owns the existing route producer and movement clock; a plan retains
that exact route rather than asking another consumer to find a second path.
`CampaignVM` owns current city, cache identity, source flags and invocation
continuation. The host alone dispatches the event after movement settles.

## World entry and direction domains

MAIN `20B46..20B7E` places player0 at the current city's source world position,
using generic facing4, only when native entry byte7 is one (`20EF5..20F29`).
Source-script entry through map selection clears that byte in `201BC..2022E`.
`worldBootstrap` therefore requires an explicit entry mode: script entry adds
no player, cache replay or RNG; native-city entry supplies one default player.
The source world place producer `21EE6..21FCB` doubles
logical x/y into its native halfstep coordinates. Runtime performs that
conversion once. Saved return context at `7A76` remains distinct
from this visible default placement; this model does not overwrite one with
the other.

MAIN `1C058..1C0DC` has one direct callsite at `24C6A`, in the settlement
controller. World entry does not call it. `CampaignVM.replaySettlementCache` accepts only
town/palace kinds0/2 and replays cached actors only when cached city/map
identity matches the current script context and its dirty field is set. It clears that
field, visits cache slots in order, skips FFFF and player0, and places every
remaining entry with its stored generic facing. A context mismatch marks the
cache dirty without replay. VM applies those cache effects and returns parsed
actor rows, music and restoration status. The input helper consumes those
rows into commands and placement draws without repeating the cache selector.

Opcode01/0A's script-facing byte is doubled at `1C3B0`/`1C5F1` before generic
move/place. Generic cached/default facing therefore has its own typed command
field, `sourcePlacementFacing`; it cannot be reconstructed by treating an odd
raw8 value as a script byte. The world converter `20FA4` indexes eight words at
DS:`2EE6`, exported locally as `worldPlacementDirections`. Settlement converter
`24ECC` pairs generic raw values by clearing bit0 before its word lookup. The
existing settlement route/canonical-direction conversion is the inverse of
that four-word table, so the native canonical result is generic raw divided
by two. Neither consumer embeds the original table values.

Successful world place consumes one RNG16 call (`21F70`) and sets the even
standing period from that draw. Successful settlement place does the same
(`26075`), followed by RNG3 for actors other than resolved player0
(`260BA..260C8`). `placementEffects` owns this order for both bootstrap and
script placement. Scripted world move `21FCE..22082` and settlement move
`25F2A..25FDE` contain no RNG calls. The periods are retained facts; autonomous
NPC behavior is not established merely by preserving its initial draw.

## Destination and interaction plans

World city selection requires the constructed city flags' low two bits to be
set, and a non-sentinel source position. Initial city flags3 come from the city
constructor (`1B03C..1B051`), not BBK's five state bytes. The VM owns subsequent
opcode20 updates. A selected world destination uses Runtime's native two-
halfstep route. Arrival (`23F3C..23F83`) writes current city before the
kind2/kind5 `[255,newCity]` probe. That producer does not write the saved `7A76` return
context; only the live actor owns its arrival position. No event is emitted
when a plan is created.

`currentCity` belongs to player object+10, `gameCity` to native game field4,
and `city` to the script map context. The source2E and world-arrival producers
write both current/game city. World/battle script map selection writes only
game field4's low selector byte. Default world player placement reads the
player field; the settlement marker kind2 probe reads game field4. Their values can
differ and are not substituted for one another.

Town and palace share the settlement controller: `244FA..24790` selects their
different map resources, while the input and talk producers are shared.
Native walk bytes come from the active Runtime map, including PMAP resources.
Town ground7F emits no destination event. A selected marker is rechecked at
arrival, then the kind2 probe receives `[marker,gameCity]` (`25255..25288`). Source
bit80 blocks input. Marker identities are retained separately from the
unrestored built-in behavior that may follow an unmatched event.
For ordinary room markers and marker124, native fallback tests query return4
or FFFF; marker125 accepts return0 as well (`252B8..253AF`). Source query
wrappers produce0 for a match/busy continuation and FFFF for no match; a
record directory ordinal must not be substituted for that return. The4 branch
is retained as a source predicate without an established reachable producer.
Marker126 has
no built-in transition. The planner does not infer a room/map transition from
marker text or graphics; the fallback is selected only by the source switch.

The fallbacks rewrite game object `7A6C` (+0/+1 position, +5 kind, +6 index,
+7 entry byte, +9 default facing flag). Arrival first clears +9
(`25228..25230`). An ordinary key enters room map `2000|key` at (8,15): it
saves game map and the player's position into `7A76` (`1CB6:1924`, which ends
at `24EB7..24EC6`) before writing the room (`252C5..25310`). Marker7C enters
the world map indexed by player field `12` (`25320..25358`). Source `12`
stores the new chapter there (`1C7D8..1C7DA`, `1EBA2..1EBA7`), and
`CF5:777A` maps that chapter through DS:`0EBC` to its city group
(`1B0CA..1B0DC`). Scripts select world index zero in every chapter; the
built-in exit keeps the chapter index, and the world picture still follows
the chapter mapping. Marker7D copies kind, index and position from
`7A76` and sets +9 (`25368..253B4`). Every fallback sets entry byte one.

The framework loop then enters the game-object map. Settlement entry with
byte one places player `0200` at the game position with raw facing four when
+9 is one, otherwise zero (`2464A..24691`), then replays the actor cache
(`24C6A`). World entry uses the existing current-city default spawn. Palace
seven's special actor `0376` and entry music (`24BD6..24C1A`) are not restored
and palace seven stops explicitly. The native host also follows the
settlement wrapper's status-two rule (`264B2..264B7`): a script map selection
from a town or palace event saves `7A76` before C86C. If no player actor is
displayed then, the saved position is unknown and a later marker7D exit stops.
A matched marker7D script followed by the built-in exit is not restored.

Actor approach (`25D9E..25E67`) builds the route to the actor's target tile and
removes its final step through the shared route producer. It does not find a
new path to a separately chosen adjacent cell. The planner preserves that
prefix. At arrival, `25B60..25C04` requires adjacency (or the same tile), and
`26A48..26A85` faces both participants toward one another before kind3's
person probe. The special person374 shop/controller branch remains explicit.
`26AA1..26AAD` restores the target's saved facing after that invocation while
the player keeps the new facing; the arrival returns that separate after-call
effect. An actor that moved away cannot receive the stale interaction event.

## Invocation boundary

World wrapper `221EE..2228B` and settlement wrapper `2643C..264CF` query their
selected kind0/3/2 event once (wrapper selectors 0/1/2) and execute at most one matching invocation.
Neither wrapper repeats on returned status5/6 or supplies automatic0 as a
query fallback. The settlement wrapper returns the source query result;
the world wrapper returns the interpreter status. Source query return is0/FFFF,
and is separate from the matched record's directory ordinal. These values are different
domains and must not be substituted for one another.

The outer controller owns subsequent automatic probes. The settlement loop
`247F8..24939` runs input/mode callbacks, checks its source control mask, then
calls automatic0 once at `248A1..248A6`, checks the mask again, and advances its
render/tick. The world loop `20CD2..20DF8` has the same order at
`20D69..20D8C`. World entry also has an initial automatic0 call at `20F35`.
This is a controller frame loop, not an unbounded VM dispatch chain. Source
status2/7/8 and map transitions can end the caller before another tick.

Synthetic tests cover city-flag gates, exact path retention, delayed arrival,
stale actor rejection, palace input, marker behavior, separate direction
domains, cache ownership and RNG order. They establish native boundary
semantics, not original framebuffer/input timing or complete campaign parity.
