# Campaign directories, framing and explicit routing

The currently examined Korean DOS/V `MAIN.EXE` has SHA-256
`731c8d26a39fcd4e9fa41b142db9bd5913a496a2da5eaa1db798b7867850815f`.
The engine reads it as data, never executes or modifies it. Original resources,
dialogue, command operands and real-file reports are local build outputs only.

## Source facts and derivations

The five `SNR?D.R3` carriers contain 18 LS11 members. Each member begins with
16-bit block offsets and an `FFFF` directory sentinel. Each block begins with
ten-byte descriptors: eight condition bytes and a block-relative 16-bit script
entry pointer, followed by a ten-byte all-`FF` sentinel. The importer preserves
conditions without inventing their evaluation. The examined files contain 225
blocks and 2,144 record identities.

A descriptor points into a shared block instruction stream. It does not own
bytes only until the next descriptor's entry pointer. Source MAIN's cursor can
fall through another record entry and continues until the source `FF`. The new
reader retains `nextEntryPoint` as a fact while bounding execution by the block
end; aliases remain separate condition/record identities. MAIN's directory and
record producers are at file ranges `0x1D80A..0x1D825` and `0x1BACC..0x1BB4A`.

Instruction framing is owned by `tools/scenario_format.py`. The source operand
skip table begins at MAIN file offset `0x3A2C2`, but it is not a complete execution
format by itself. The source skip code uses 16-bit special sizes for opcodes
`03` and `22`, and variable lists for `20`, `21` and `32`. The actual `1D` handler
at `0x1C9E8..0x1CA14` reads a word and two bytes, although the skip-table count is
only two. Using that narrower skip count to parse execution would shift all
following instruction boundaries. Attribute opcode `1C` also branches by its
selector. The dispatcher is at `0x1C1EA..0x1C35D`; the separate skip path is at
`0x1C169..0x1C1C5`.

All 2,144 source record entry traversals reach an `FF` through the implemented
framing rules. This establishes frame coverage for this examined artifact; it
does not establish the semantics, reachability or successful playback of those
records. Opcode visit counts include repeated visits to shared instruction tails.

The `SNR?M.R3` files have matching group offset directories. One directory's
16-bit offsets roll over at 65,536 bytes. The exporter records the raw values
and derives the minimum strictly ascending file positions, rejecting spans that
would be ambiguous or exceed the file. This is a structural derivation; the
original seek implementation has not been verified in this project.

## Implemented native preview and router

The existing palace-command interpreter is reused with explicit source resource,
member and allowed-map parameters. It does not interpret the wider framing catalog
as an executable campaign. A preview retains an explicit unsupported boundary
when a command is not implemented. Records requiring an inherited map or actor
state remain data-only; an imagined initial state is not supplied.

The current extraction exposes three completely supported record previews and
47 partial previews. Most records are data-only. Source trigger conditions are
not automatically selected. A manually requested conditional preview has a
different selection origin from an unconditional preview.

The native router retains selected record identity, preview boundaries, pending
battle identity and result provenance. It does not choose a successor merely
because a record ended. Experimental combat outcomes are recorded as research
results and never become original campaign flags, including when a development
override is requested. Even a claimed verified combat result cannot supply an
unimplemented source result-to-flag mapping.

## Verification

Public synthetic tests cover shared tails, low-byte framing errors, variable
lists, malformed directories, missing terminators, resource identity and rollover
bounds. The opt-in real-file campaign test checks all examined directories and
that full framing coverage is distinct from preview support. Repeated real-file
exports produce identical JSON values and preserve hashes of all 69 input files.

Native self-tests exercise condition refusal, explicit conditional preview,
no automatic successor, pending battle identity, isolated experimental outcomes,
duplicate identities and snapshot round trips. Native record rendering is an
additional integration check; a catalog alone does not establish a playable full
campaign.
