# Original strategy execution and AI estimates

The examined source dispatcher is `MAIN0x2E836..0x2EE1C`. The new native
`OriginalStrategies.swift` controller consumes the movement/profile owner's
availability, category, MP-cost, range and terrain-eligibility facts. Those
original tables remain local imports. Target choice and area confirmation are
explicit controller inputs.

| Original ID range | Source operation |
| --- | --- |
| 0..14 | Damage context kind2; family is ID/5. The last two IDs of each family also visit enemy cardinal neighbors. |
| 15..17 | Condition-mask2 success test with denominator2. ID17 also visits enemy cardinal neighbors. |
| 18..20 | Success test with denominator4, then a word-width morale reduction and the ordinary morale setter. |
| 21..29 | Single-target morale, troop, or combined healing in three groups. |
| 30..35 | Area morale or troop healing, with radius/strength selected by the source ID remainder. |

Damage uses the separate source damage producer, target HP/morale writeback,
context EXP and retirement. It never uses a physical-damage replacement for an
unimplemented strategy. Damage splash copies its center after the primary
context; condition splash copies its center before the primary effect. Both
visit cardinal offsets in imported source order and read current occupancy.
Area healing retains its target-list order, beginning with the caster's cell.

Actual healing (`0x2EE20..0x2F052`) adds caster-derived troop/morale bonuses,
draws jitter, caps to the missing quantity and applies the original setters.
The source caster-slot255 path omits those caster bonuses. Full morale with
condition2 is a valid actual healing target even though the AI utility gate
differs. Healing the same maximum morale can consume a condition-recovery draw.

Completed damage commands use context EXP. Other completed commands award eight
flat EXP, with twelve for single-target healing by class12 or18. Completion
then subtracts the imported MP cost and sets acted-mask128. Invalid terrain,
weather rejection, cancelled selection and rejected full single-target healing
skip completion costs. The source checks MP before effects; the final byte
subtraction retains wrapping if an intervening campaign effect changed MP.

`OriginalStrategyOperation` owns a Codable program counter, retained target
slots/center, completed target effects and pending retirement acknowledgement.
`begin` performs availability and target/confirmation checks without gameplay
RNG or effect mutation. Each `advance` commits one target context and yields its
effect. A newly enqueued session retirement notice blocks the next advance until
the host explicitly acknowledges that exact notice after source dialogue or
choices finish. Repeated advances while waiting return the same notice without
repeating damage, RNG, context EXP or final MP/flat-EXP/acted costs.

The pending operation's local effect index and the session's global retirement
sequence are separate identities. A status retirement under suppression flag4
does not create a campaign notice. Notice person identity records the original
producer's evidence; later effects still read current runtime-slot state.
Damage splash captures its center after the primary retirement script resumes;
condition splash retains the center captured before the primary context. Each
splash neighbor reads current terrain/occupancy, whereas area healing resumes
the retained slot list. Host script RNG consumption and byte-MP changes remain
visible to subsequent effects and final completion.

The existing synchronous `castStrategy` convenience drives this same operation
to completion and acknowledges retirement after its callback returns. An async
host instead retains the operation across waits. A repeated finished advance
returns the retained result without charging completion twice. These source
dispatch semantics do not establish original GUI/animation parity or a full
campaign playthrough.

The AI estimates (`0x30824..0x30C57`) are implemented independently in
`OriginalStrategyAI.swift`. They include utility thresholds/bonuses absent from
actual healing, random morale weighting absent from actual morale damage, and
word/byte truncation. The shared success producer (`0x2D80A..0x2D8F0`) retains
the AI raw denominator byte130 rather than masking it to2. The status AI branch
then draws `random(300)` even on estimated failure. These source behaviors are
preserved rather than replaced with a corrected or generic AI rule.

Public tests use synthetic profiles and persons. They verify actual command
branching, primary/splash order, callback interleaving, shared writeback, action
costs, full-target rejection, caster inclusion, source RNG ordering, serialized
retirement suspension/resumption and the separation between AI utility and
actual effects. No original tables, assets,
text or disassembly are required by those tests or included in public sources.
