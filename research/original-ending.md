# Original ending producer and first scene

This work statically reads the caller-selected Korean DOS build. It never runs
or modifies the original programs. The examined END executable SHA-256 is
`6a961179ee3b34d869ed3031523d616d79f1d863d61f4f4f6af8cebd1fe8dc77`.
END has a `1600`-byte MZ header and DGROUP file base `CE40`.

MAIN opcode `2A` submits the selected byte through the framework INT65 call
with subfunction `0400` and immediately returns interpreter status eight
(`0x1D176..0x1D196`). This wrapper is not a direct graphics loader. END reads
that selection using subfunction `0401` (`0x4667..0x4709`). Values zero and one
both select the END1 program; value three selects the separate END2 branch.
The two END1 variants diverge later. Resource file names alone do not establish
which ending was selected. Exhausting a script member never selects an ending.

The restored common opening uses END1 archive member 19 as a 544×176 NPK
background at `(48,104)`. Member 20 supplies two 224×160 interleaved planar
color frames. Member one supplies the corresponding one-bit masks: a set mask
bit preserves the old background, so color index zero cannot be treated as
transparent. These extents and frame offsets are source blit operands
(`0x4769..0x4895`, `0x4A20..0x4AAB`). The exporter owns mask-to-alpha conversion
and retains opaque black pixels.

The source initially positions the figure at `(368,120)`. Its movement loop
subtracts four before each presentation, producing 32 positions from x360
through x236, while alternating the two frames. Every six iterations advances
to the next pair of source text lines (`0x49BB..0x4B7D`). The waits occur before
the prepared frame is copied into VRAM. The first movement commits at deadline
325, the next 31 at intervals of 125, followed by a 100-unit final hold. The
source reads DOS time with INT21 AH2C (`0x27A2..0x27BA`) and calculates elapsed
centiseconds (`0xBE92..0xC033`), establishing 100 source ticks per second.
The restored interval ends at deadline 4300.

Text uses the original pointer list and fonts, exported locally only. The source
font mapping uses 30-byte Korean records, fourteen 16-pixel rows after a
two-byte identity; ASCII uses sixteen 8-pixel rows. Both receive the original
one-pixel rightward bold expansion, one-byte horizontal padding and 20-pixel
line pitch (`0xA24C..0xA52B`). The normal source palette is selected from END's
DGROUP. Framework display flag eight substitutes a separate palette; that
alternate display mode remains outside this first export.

`tools/prepare_ending.py` emits only local PNG/JSON data. `Ending.swift` owns
asset validation, exact frame ordering, source clock units and source-bound
checkpoints. It returns an explicit unrestored frontier at END file `0x4B9A`;
it never turns the end of the exported frame array into a complete ending.
The center-out initial reveal, fades, subsequent scenes, selection-specific
branches, common final flow and END2 branch are not yet restored. Synthetic
mask/font/clock tests and optional source conformance checks do not establish
original DOS framebuffer parity or full campaign playability.
