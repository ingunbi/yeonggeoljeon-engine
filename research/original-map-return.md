# Source map selection and battle-loop return

The MAIN executable profile is the same statically examined input recorded in
`original-campaign-vm.md`. Original programs are never run or modified.

Opcode `11` stores the next packed map in script context `+0A`, sets the raw
battle result through helper `2CB4:1BA`, and continues the same interpreter
call (`0x1C768..0x1C7B8`). It does not return from the interpreter there.
Opcode `09` also selects script context `+0A`, sets its busy state one, and
returns raw interpreter status two (`0x1D125..0x1D143`). This selects a future
map; it is not itself a call to the map asset loader. A sequence containing
`11` then `09` must retain that order while deferring the actual battle-stage
replacement until the enclosing battle loop finishes.

The external dispatcher calls the battle loop and interprets its result
(`0x1E31C..0x1E344`). Result one selects checkpoint restoration, three adds
outer flag `20`, four adds flag `40`, and other values invoke `CF5:C86C`
(`0x201BC..0x2022E`). That helper reads the selected map from the script
snapshot and calls a kind-specific game selector:

- Kind zero: town selector `0x261A8`.
- Kind one: world selector `0x220D0`.
- Kind two: palace selector `0x261F6`.
- Kind three: battle selector `0x20172`.

All script-dispatch selectors store the selected low byte as Game map byte six.
Only world and battle also write that low byte to Game selector byte four. Town
and palace retain Game+4. All four preserve player7A80+10 current city. Town/world/battle write the source position-byte
pair; palace does not. The script transition helper then supplies Game+4, rather than player current
city, and the original packed map to context entry `86F0`
(`0x1C040..0x1C055`) and finally sets game entry-mode byte seven to zero.
That final override is relevant even when the selector initially wrote one.

World entry calls its default city/player spawn only when game byte seven is
one (`0x20EF5..0x20F29`). At zero it skips that spawn and evaluates its source
automatic wrapper. Settlement entry has the analogous once-only default-player
spawn gate (`0x24BB9..0x24C3A`). Therefore scripted `09/11` entry must not inject
a default player placement or its RNG draw. Script-selected actors appear when
subsequent original script instructions place them. Native built-in city
navigation has a different entry-mode contract.

Actual world and settlement map initialization clears the displayed actor
slots (`0x20ACA..0x20B45`, `0x2447A..0x244F8`) before their respective entry
paths. Static map props and source script actor cache have separate owners.

Only settlement entry calls cache replay `CF5:8708`, file `0x1C058..0x1C0E3`, at
`0x24C6A`. There is one direct far pointer to that helper in the examined MAIN;
the traced world entry does not call it. The cache operation first writes the
current context city/map. Mismatched cache ownership marks the cache dirty
without clearing identities or changing its owner. Matched clean cache does
nothing. Matched dirty cache clears dirty first, restores nonempty nonplayer
entries in physical order, then selects cached script music. Player zero is
excluded. A later script placement owns cache clearing and owner replacement.

`acknowledgeMapSelection` owns completion of the interpreter selection;
`enterMapContext` owns actual context entry. `replaySettlementCache` owns the
cache's source predicate and returns parsed actors/music for the native
placement owner. Cached script music and the current device selection are
separate state: an external battle stinger does not overwrite context `+1BF`.

The native host now retains a battle's source09 selection until the physical
or strategy operation and its source caller finish. Only then does the outer
battle-loop boundary apply victory carryover and enter the selected map. A
caller-selected local replay reached the first campaign victory, returned to
the following world scene and reached the second battle's manual phase.
This tests that particular native exit path; it does not establish all source
battle exits or original-runtime parity. Original save-mode restoration and
built-in navigation still require their own producing boundaries.
