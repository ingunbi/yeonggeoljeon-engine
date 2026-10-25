<!-- SPDX-License-Identifier: GPL-3.0-only -->
# Source movement, AI and turn restoration

This is a static reconstruction of the examined Korean DOS/V executable. The
original program has not been run or modified. Synthetic tests establish the
new implementation's boundary semantics; they do not establish original-runtime
parity or whole-campaign playability. Original tables and real-file reports stay
in ignored local build directories.

The executable's class domain has nineteen entries. Movement type, movement
budget, attack pattern, setup order, strategy level/MP and direction ordering
remain caller-owned input data exported by `prepare_movement.py`. Terrain defense
has one owner in `prepare_combat.py`. Raw terrain bytes retain their original
indexing, including byte255; nominal table row spacing does not justify replacing
that value with an impassable default. The native scratch grids hold960 cells.

Source movement uses distance-layer scans in row-major order, with the source
cardinal direction order and first assignment to a cell. Hostile occupancy blocks
expansion, friendly occupancy permits transit, and hostile-adjacent cells stop
further expansion except at the seed or under the original script flag. Route
tracing selects the first strictly lower neighbor, applies original terrain
costs, and preserves source tie order. The partial trace is also used by AI goal
selection; player routes require a complete trace and a free destination.

Physical AI predictions are distinct from actual damage. The score preserves
class-family defense adjustment, terrain integer reduction, the moving unit's
troop component, preferred-target bonus, word wrapping, and byte weight
conversion. Attack patterns are the executable's ordered patterns rather than a
Manhattan radius. Target execution first checks the selected ID and otherwise
falls through to the last current range candidate, as the source does.

Native orders0 through4 share one position-score producer. Coordinate and person
goals, recursive goal bonuses, influence-triggered defense, extended influence
search, reverse fields, partial-route endpoint bonuses, occupied cells, terrain
bonuses, staying bonuses and strict ties retain source order. A disappeared cache
target changes the native order to1. Reaching a coordinate goal changes orders0
or4 to3 before the final attack gate. Order4 bypasses attack/strategy scoring.
Strategy availability preserves all36 IDs and the original class, level and MP
checks. Strategy prediction preserves per-target RNG, damage/status/support
utility, aggregate support, strict ties and the original word comparison followed
by byte storage. The caller supplies an explicit native context; planning returns
RNG writeback rather than silently consuming preview state. These utility scores
do not execute strategy effects. Unsupported command producers must still fail
without substituting a physical attack. Script-flag4 retains its direct goal controller for orders0/4 and its separate
100-point movement budget and baseline-only evaluator for other native orders.
Overlapping scripted friendly destinations require an original occupancy-grid
owner and fail explicitly while that representation remains unresolved.

The source round consumes a weather draw before its numbered-turn event9. It
then clears action bits, visits all fifteen friendly slots for upkeep (including
absent slots), checks global event0, processes friendly condition recovery and
manual input, runs friendly automatic orders, visits all thirty enemy slots for
upkeep and condition recovery, and runs enemy automatic orders. Automatic order
priority is recovery terrain, recovery need, then the remaining units, each in
runtime-slot order. Native priority numbers for absent source objects remain
unresolved; active action order is preserved without inventing those values.

Hooks preserve campaign ownership: numbered rounds are event9, global checks are
event0, and unit checks query event6 (person/coordinate), event11 (person/region),
then event4 for cardinal neighbors. Failed friendly-person lookups try the
source wildcard identity. Each probe must be requested after the preceding
script completes so changed positions and roster are read anew. Exhausting the
source round limit yields result3. No generic elimination rule supplies victory.

Manual order7 permits moving before acting. Attacks and waiting set bit80;
movement sets bit40. An attack prevents a later move. Cancelling the source
command menu restores its saved origin and clears bit40. Waiting changes no
morale. Combat-owned upkeep and morale setters retain their own RNG consumption,
condition changes, integer widths and class-specific MP effects.

Battle script actions have a separate native action-manager byte, duel context,
ordered environment backups and marker overlays. Duel setup, clash, motion and
completion preserve their coordinates, frame selectors and conditional sound RNG;
they do not invent troop loss or retirement. Native bitmap timing remains
unrestored. Affiliation transfer retains shared person identity and copies the
first matching runtime slot into the first inactive slot of the opposite side.
Side-wide troop effects visit live slots without deduplicating aliased people.
Environment effects preserve sequential picture remaps, byte wrapping, raw type
indices and the first matching backup rather than normalizing them downstream.

Generic campaign place, move and remove commands dispatch to different producers
on battle maps. Place activates a reserved runtime slot from its matching setup
row, rather than copying the VM actor cache's coordinates. Activation's flip is
unit flag10; it is independent of the byte8 AI priority. Scripted movement uses
the native flag4 goal controller and then clears C4. Scripted removal sets native
status4 while suppressing death/objective effects and clears references only from
order0 followers. Native person lookup remains the first matching slot, including
inactive aliases. The VM owns its actor cache and typed operand interpretation;
these battle adapters own live-unit mutations. Party activation and spawn search
have one owner in `OriginalParty`.
