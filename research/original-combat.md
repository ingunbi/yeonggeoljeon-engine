# Original combat arithmetic

This note records static derivations from the caller-supplied Korean DOS/V
`MAIN.EXE` profile examined by the local importer. The original executable was
not run. Original resource tables, item records, disassembly and verification
outputs remain outside the public source tree, under ignored local build paths.

`OriginalCombat.swift` owns the arithmetic interpretation. Consumers supply
original person state, original runtime slot identities, terrain bytes, the
shared RNG state and locally imported tables. Placement IDs, person IDs and
runtime slots are distinct identities.

## Confirmed paths

| Behavior | MAIN file range |
| --- | --- |
| Derived attack | `0x1A43E..0x1A53D` |
| Derived defense | `0x1A56C..0x1A66B` |
| Class/level maximum troops | `0x1AD08..0x1AD31` |
| Physical and strategy damage producer | `0x31474..0x317CB` |
| Morale loss | `0x317CC..0x31853` |
| Hit and defeated-target EXP | `0x31854..0x31925` |
| Counter eligibility | `0x3198E..0x31A04` |
| Quantity, morale and EXP writeback, recursive counter | `0x321E2..0x32317` |
| EXP/level mutation | `0x1A8B4..0x1A9C8` |
| Shared random generator | `0x181D4..0x18227` |
| Troop/morale recovery and adjacent MP aura | `0x2B228..0x2B43B` |
| Condition-mask2 recovery | `0x2B690..0x2B708` |
| Maximum MP and MP gain mutation | `0x2C6E4..0x2C727`, `0x2D5DA..0x2D606` |
| Morale setter and condition side effects | `0x2BEEC..0x2BF51` |
| Retirement predicate | `0x2D630..0x2D67E` |

The local importer records source hashes and table spans. Public tests use
invented tables and people, never copied original stat tables or item values.

## Derived stats and physical strikes

For each attack/defense query, the source combines the corresponding class base,
current morale, `4000/(140-scalar)` and the level multiplier `(level+10)/10`.
Equipment contributes the largest applicable percentage bonus among the eight
item slots; it does not sum those bonuses. The source uses category immediates
0 for attack and 5 for defense. Signed long division truncates toward zero;
long multiplication/addition and final word return widths are retained.

Class group is integer division of class ID by 3. The three participating
groups form the cycle 0 over 1, 1 over 2, and 2 over 0. An advantage decreases
the target defense by a quarter; a disadvantage increases it by a quarter.
Physical damage then uses attack minus half adjusted defense, terrain reduction,
the subtype-7 counter half, a minimum of one, and the target's current troop cap.
The source terrain lookup uses the complete raw terrain byte. The importer
preserves a 256-byte window rather than clamping to the nominal 20-entry table.

Nonlethal physical morale loss divides damage by `(targetLevel+5)` and then by
3, with minimum one for nonzero damage. Strategy morale loss divides damage by
100. Lethal damage computes full previous morale loss for presentation, but the
writeback skips the morale setter and retains the dead unit's previous morale.

The normal player attack (`0x2DB49..0x2DB54`, then `0x30E53..0x30E5C`) and AI
attack (`0x3038F..0x3039C`) obtain subtype from the class table at DS`0x3FD2`.
`physicalSubtypeByClass` owns that table; it is not a boolean counter flag.
Counter-class eligibility tests that subtype value for zero, while the success threshold uses target
attack scalar against `random(150)`. The draw precedes subtype, lethal-damage and
condition suppression. A subtype-7 hit can therefore consume a counter draw
even though it cannot cause another counter.

The physical context prelude at `0x31FDB..0x3216F` consumes eight `random(16)`
draws for attacker class IDs 3 through 5, or sixteen when the source global
options word has a nonzero low-byte high nibble. It skips this prelude for
subtype 7. These presentation draws precede the damage producer and therefore
affect later counter/strategy draws. `physicalPrelude` takes that options word
explicitly and returns the draws for a caller-owned presentation.
The source static wrapper `0x1A37C` calls `0x19D26`, whose `0x19D4D` call
constructs global object DS`0x7A80`. Constructor `0x1A406..0x1A436` sets its
options word at offset4 to zero (`0x1A423`). That is an established initial
state, not an assumed user-option value after a load or settings change.

## Strategy damage contexts

Source context kinds 2 and 3 use encoded subtype nibbles, intellect and level.
The first chance roll is truncated to one byte. The source then applies its
class resistance, terrain/environment quarter bonus and a second random jitter
before testing failure for kind 2. Kind 3 omits that chance gate and its attack
contribution. Intermediate subtraction wraps as a word before promotion to the
long damage quantity. A zero random bound consumes no RNG state.

This establishes the damage context only. The separate source-derived command
controller owns availability, MP cost, legal targets/range, status and healing;
see [original-strategies.md](original-strategies.md).
Battle-object byte 4 indexes an imported 256-byte environment lookup window;
the nominal six state labels are not assumed.

## Experience and mutation order

Only source runtime slots below 15 receive the common hit and defeated-target
EXP. The first enemy runtime slot has a separate defeated-target bonus. The
EXP setter excludes its masked NPC identity range, and an initially level-99
person retains prior EXP. Its level-up loop does not recheck that cap, so an
initial level below 99 can cross it when a single accumulated EXP word permits
multiple increments. New levels affect later derived-stat queries; the setter
does not refill current troops.

The source writes target troops, updates nonlethal target morale, and mutates
attacker EXP/level before entering a recursive subtype-7 counter. The counter
must query the updated shared person objects and the original attacker's terrain.
The pure strike function intentionally does not duplicate those mutable objects.
The morale setter can set condition2 after low-morale decline, so the caller
must recheck the updated target condition flags before entering that counter.
The final retirement predicate also accepts condition2 with zero morale even
when troops remain. Its stateful retirement/campaign-hook producer is separate
from this pure predicate.

## Resumable physical context and recursive aliasing

`OriginalAttackOperation` owns a Codable program counter, completed context
effects, retirement checks and pending acknowledgement. The synchronous
`attack` convenience drives this same operation. Each primary/subtype7 context
uses one mutable producer for presentation draws, damage, target HP/morale and
attacker EXP. Waiting for a canonical session retirement notice does not repeat
these quantities or execute the caller's remaining tail.

The original recursive call at `0x322B9` passes the same context pointer to
`0x31E7A` (`E91A`). That method writes context attacker/target indices at
`0x31E83..0x31EFD`. No caller restore follows the recursive return. The target
read at `0x322F2..0x3230D` therefore uses the context's current target, which can
still be the counter's target. It must not be replaced with a saved logical
outer target. This corrects the former native loop that preselected two
different retirement slots.

A retirement script executes synchronously inside its source call stack. The
operation yields that notice and requires explicit acknowledgement before
querying the current target again. The next check reads that slot's current
person, HP, morale and status, rather than retaining an earlier retirement
decision. The session's status4/cache/notice producer remains the single owner;
suppression flag4 changes status without creating a campaign wait. Local check
indices and global retirement sequence numbers remain distinct.

The player caller at `0x30E21..0x30E41` and AI caller at
`0x3034F..0x30373` turn the attacker horizontally before creating the context;
equal x preserves the prior sprite-flip bit. The acted flag128 is set at
`0x30E61` or `0x303A1`, after the entire context call returns. It is not set
while a nested retirement script is waiting. Repeated finished advances return
the retained result without repeating damage, RNG, EXP or that completion.

Synthetic tests cover serialization before/after recursive damage and while a
retirement is pending, source prelude/counter draw ordering, updated-level
counter defense, post-morale condition suppression, shared person aliases,
current-target re-query after script mutation, source context index aliasing,
suppressed notices and one-time completion. Synthetic slot replacement at a
retirement boundary tests continuation semantics, not campaign reachability.
These checks do not establish original animation timing or all presentation RNG.
The examined retirement-script opcode producers do not establish a second
re-entry into the global E52E context. Unresolved scripted actor-action paths
remain separate unsupported boundaries rather than a guessed nested context.

## Phase recovery

The recovery method consumes `random(11)` and `random(5)` before checking source
unit status for value2. Its troop gain is `(firstRoll+15)*10`; morale gain is
`defenseScalar/10+secondRoll+1`. A remaining gap smaller than ten after the
candidate recovery is filled before applying the maximum clamp. Terrain IDs
8 and 13 enable troop and morale recovery; terrain14 enables troops. The
method's literal item-ID tests add the corresponding recovery flags.

Active class12 grants `level/10+1` MP to occupied cardinal neighbors. The combat
kernel returns this amount; the turn owner enumerates neighbors and applies
the source order against shared state. Maximum MP uses the source low-word
multiplication and byte caller behavior, including its quotient-256 edge.

Condition-mask2 recovery is a separate method. It draws `random(100)` only when
that condition is set and unit status is2, and clears the bit when the draw is
less than `(defenseScalar+currentMorale)/3`. The current morale must include any
preceding recovery. Inactive source slots retain absent person/terrain facts;
their unconditional recovery draws still occur. Phase traversal and invocation
order are owned by `OriginalTurns.swift`.

The morale setter itself attempts that condition recovery when morale increases,
and even when the requested and previous morale both equal100. A morale decline
to a requested word below30 instead consumes `random(5)` and sets condition2 on
a roll below3. Its clamp uses signed comparison, while that below30 test is
unsigned. `recover` owns this setter's side effects whenever its morale-recovery
flag is enabled; later phase condition checks remain separate calls.

## Verification limits

The source seed initializer `0x181FA..0x18212` packs raw bytes 2 through 5 of the
runtime clock structure. Runtime `0xCA8A..0xCAE7` fills them from the RTC day,
hour, minute and second bytes without converting BCD to decimal. `clockSeed`
accepts those raw bytes explicitly. The two observed static call sites are
`0x1E197` and `0x1E317`; no original runtime clock sample was captured.

Synthetic tests establish arithmetic branches, widths, RNG draw ordering and
mutation edge cases. Local importer tests establish selected-byte provenance,
cardinality and unchanged original inputs. These checks do not establish live
DOS execution, framebuffer/animation parity, the original initial RNG seed,
noncombat RNG consumption, every strategy command, or a complete campaign.
