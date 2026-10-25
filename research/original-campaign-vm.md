# Original campaign execution

The native `CampaignVM` is separate from the explicit-record research browser.
Its producer is `campaign_vm_format.py`, called by `prepare_campaign.py`.
Only the producer reads original operands, text, condition descriptors and skip
tables. Local `campaign.json` includes its typed `vmProgram`; it is not public
engine content.

Static observations from the examined Korean DOS/V MAIN profile establish:

- A context begins at chapter/member/block/phase zero with 32 zero flag bytes
  (`0x1B56C..0x1B5BE`). Flags are MSB first (`0x1D934..0x1D966`).
- Descriptor byte one starts a phase. Its first high bit marks a repeating
  phase; later descriptors join only when their complete byte equals the first
  byte masked with `0x7F` (`0x1B37A..0x1B3D3`).
- Event wrappers scan only the current phase in source descriptor order.
  Descriptor byte zero's high bit inverts its event predicate. Raw kind one is
  the wrapper fallback (`0x1BB4E..0x1BBB5`).
- A repeated automatic phase can consume its leading conditional instruction
  in predicate-only mode before selecting a record (`0x1D9D8..0x1DA20`).
- `FF` advances a nonrepeating phase and retains a repeating phase. Phase EOF
  advances block then member; it does not invent a next chapter or an ending
  (`0x1D0C4..0x1D0EB`, `0x1D8B8..0x1D8FA`, `0x1DC98..0x1DCC6`).
- `0F` selects a block, `12` advances chapter and resets member/block/phase,
  `13` explicitly advances phase, and `14` sets or clears a flag from two
  separate bytes. Selector zero sets a flag; nonzero clears it.
- `15` compares the source selector result and conditionally skips subsequent
  instructions. `21` requires all positive flags and no negative flags. `25`
  selects descriptor `phaseBase + choiceIndex + 1`, keeping the phase base.
- `00` followed immediately by `15` defers its dialogue to the selector UI;
  it does not first speak the same question. Consecutive `01` movements are
  queued as one actor batch before the source waits for movement completion.
- Execution framing and the original instruction-skip walker are different.
  The narrower skipped `1D` and the skipped `21` length handling are retained.
  A skip landing inside an execution operand is an explicit unsupported
  boundary, only when that path is actually taken.
- `24` writes person byte `1C` as `(old & E0) | (value & 1F)`
  (`0x15AE6..0x15B01`, `0x15B78..0x15B8D`). `2F` writes person byte `2B`
  (`0x204DC..0x20503`, `0x209F6..0x20A03`). The native person-state owner
  applies these effects; the VM does not infer a faction from a display label.
- `3D` invokes the original save confirmation flow (`0x22A62..0x22AA1`).
  `0E` retains the last selector character in ASCII `30..41`, rather than
  parsing a decimal number (`0x18106..0x181D0`).
- `36` captures a retry checkpoint: script context and placements, referenced
  person state, and player state (`0x1D00C..0x1D026`, `0x1B79A..0x1B93A`,
  `0x1E6AA..0x1E700`, `0x1AC60..0x1AD08`). The current source cursor already
  follows opcode `36` when that context is saved. `1E` clears only the script
  actor cache and its dirty marker (`0x1DBDC..0x1DBFF`); that helper does not
  directly remove the currently displayed runtime actors.

Event numbers remain source identities until call sites establish their host
meaning. The town actor dispatcher passes a clicked person as kind-three's
argument (`0x26465..0x26469`). Battle's defeated-person dispatcher compares the
two enabled objective pairs and routes the first match to kind seven, the
second to kind eight (`0x1C008..0x1C03D`, `0x2BB2C..0x2BBB1`). No synthetic
victory flag is inserted by this VM.

Town actor interaction reaches kind three after approaching the actor and
setting the participants' facing (`0x26A79..0x26A85`). A town destination
arrival reads the walk-cell key under the player and dispatches kind four with
`[destinationKey,currentCity]` after matching the selected destination
(`0x25255..0x25288`). World destination arrival first writes the new current
city and then dispatches kind four with `[255,newCurrentCity]`
(`0x23F3C..0x23F83`, `0x2222B..0x2223C`). A click alone does not establish
that arrival. The VM exposes corresponding typed event constructors.

The source `15` chooser displays two MARK bitmap buttons, Yes first and No
second. Their result values are one and zero respectively, independent of
display order (`0x164A9..0x165C4`). Native options are indexed by result value
and include presentation order `[1,0]`; `choose(index:)` consumes that source
result. Original 48×20 button pixels come from MARK member zero offsets
`1BD0` and `1DB0`. These pixels remain local exported assets.

The host preserves one scene runtime across command batches. It completes map
loads with `resumeMap`, presents source choice indices with `choose`, and can
acknowledge a host action only if that opcode was registered with an actual
implementation. Original person state, battle placement, inventory and combat
effects belong to their own parsed models. Program digests bind saved contexts
to the same original source file set.

`cacheActor` is a separate 62-slot source cache operation. Both original place
and move wrappers update this cache using a matching person or the first free
physical slot (`0x1D2D4`, `0x1D3D8`, `0x1DC02`). Move sets cache flag bit two;
the interpreter clears that bit after the actor stops (`0x1C0F7..0x1C14F`).
The host records a completed movement with `completedMovement: true` and the
source facing value, which is the script facing multiplied by two. Removal
invalidates the cached person without compacting slots. Successful native
execution and source cache ownership remain distinct from on-screen lifetime.

Unknown host effects, original text substitutions, native selector input behavior and
several battle event call sites remain explicit limitations. The original last
chapter requests an ending with `2A`; exhausting a member is never considered
campaign completion. Synthetic interpreter tests and complete source framing
do not establish complete original-runtime or full-campaign parity. Original
DOS programs are not executed for these checks.

Message seeks now follow the examined reader directly (`0x1B480..0x1B4F8`).
The two literal base exceptions receive an additional 64KiB epoch, and the
relative word is added with 32-bit carry. A descending directory value alone
does not authorize an inferred wrap. This replaces the earlier monotonic-span
derivation while preserving the same actual source member spans.

Game/player current city and script context city are separate saved fields.
`setCurrentCity` and opcode2E update the former; `resumeMap` establishes the
latter for map/cache ownership. `setPlayerPosition` retains the selected map
and byte-sized route coordinates. `commitWorldArrival` is called after the
native route completes, records current city and player position, and returns
the exact source event; it does not skip the event dispatcher or automatically
enter a destination map.
