# Caller-selected native input replay

`OriginalPlayVerification.swift` reads a local JSON input file and invokes the
same native host APIs used by exploration and campaign input. The public
source contains no original route, person choice or campaign input sequence.
All actual original-game scripts, exports, replay files and reports stay local.

The input object uses format one, an `inputs` array, and optional explicit RNG
seed, fixed microsecond step and per-input work bound. Supported operations are
`talk`, `choice`, `save-skip`, `save-native`, `battle-retreat`, `battle-quit`, `field-quit`, `world-city`, `town-marker`, `town-cell`, `party-toggle`,
`party-confirm`, `expect-battle`, `battle-move`, `battle-attack`,
`battle-strategy`, `battle-item`, `battle-wait`, `battle-end-turn`, `retry-choice`,
`city-entry`, `shop-answer` and `field-exchange`. `city-entry` answers the arrival question with
index one or zero. `shop-answer` answers the shop's current blocking call: a row
or nothing for cancel at a list, one or zero at a question, anything at a timed
line. See [original-shop.md](original-shop.md). `field-exchange` moves `item` from
`person` to the person in `index`, as the field item exchange does.
`battle-retreat` and `battle-quit` use the battle system menu entries, and
`field-quit` uses the field menu's quit. `save-native` also works at an idle
field, like the field menu's save.
`town-cell` walks to an explicit settlement cell, which selects one cell of a
marker that occupies several cells. `save-native` writes a native resume file at a
pending source save prompt into the output folder and then continues. A
separate run with `--resume FILE` starts from that file without an input seed. Unknown operations,
fields, explicit null operands and invalid operand combinations are rejected.
A town marker that is ambiguous in the source map is rejected by the
host; the driver does not choose an arbitrary matching cell.

The driver acknowledges dialogue and retirement popups and advances movement
using its selected fixed step. Branch choices, save prompts and deployment
choices require corresponding input entries. It connects the original battle
phase/retirement callbacks and records a reached battle. Manual battle input
requires the current host and source flow to accept input; movement also
requires the source manual-unit gate. Attack, strategy, wait and end-turn use
the same phase owner as the native view, including resumable retirement hooks.
The driver chooses no action and provides no win, state-edit or teleport
operation. The seed is explicit test input and
does not establish the original wall-clock RNG timeline.

Reports retain the input path/digest, ordered observations, frames, final native
checkpoint, source failure and trace. Input rejection or an unrestored source
operation stops the replay, writes the available evidence and returns failure.
An input list ending means only that those selected operations were processed;
it is never a complete-campaign or original-runtime-parity claim. AppKit
frames are offscreen captures, not macOS keyboard/mouse-delivery verification.
Field and battle frames include MAIN's screen frames when the local story data
carries them ([screens](original-screen.md)). Battle captures also label unit
slots, because input files address units by slot.

Battle input shapes are `{kind:"battle-move",slot,x,y}`,
`{kind:"battle-attack",slot,target}`, `{kind:"battle-strategy",slot,ability}`
with optional `target`, `{kind:"battle-item",slot,item}` with optional `target`,
`{kind:"battle-wait",slot}` and
`{kind:"battle-end-turn"}`. Slot identities and coordinates remain caller
inputs. Runtime geometry, range, available abilities, costs and original
phase state decide whether each operation is legal.
