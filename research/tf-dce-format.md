# Original TF-DCE pictures

`tf_dce.py` independently interprets the source graphics bytecode from the
original `TFDED.COM` driver. The examined driver SHA-256 is
`57db61a49d4a1ca525d14aca210457c57ec2c2caf04d58b99f4a51e053762371`.
The original driver is never executed, copied into the engine, or published.
Its COM load addresses are file offsets plus `100` hex.

The driver header reader at load `018C..0215` supplies picture width in planar
bytes, height, four plane-codec nibbles, plane mapping, flags, an optional
palette and an optional word dictionary. Packed pictures use a 02/T header.
The per-plane dispatcher at `0298..02BA` supports preserved planes, fill,
copy from a mapped plane, and compressed instructions. Source compressed
output traverses one vertical column downward, then the next upward, switching
direction at each column boundary (`0326`, `0660..0686`). This is distinct
from ordinary row-major planar data.

The compressed instruction families encode literal runs, repeated bytes and
pairs, repeated nibbles, overlapping traversal-history copies, horizontal
VGA-address copies, and mapped-plane transformations. Plane transforms include
inversion, rotation, and masks with a small changing mask history. Dictionary
words select their own source dispatcher, rather than being prepended to the
ordinary byte stream (`0344..0362`). Each plane terminates at its exact output
extent; extraction requires exact complete consumption of each source payload.

`prepare_story.py` owns the two packed resource directories: PACKGRP has
38 six-byte descriptors and FACEDAT has 240. A descriptor is a 32-bit relative
offset and a 16-bit payload length, relative to the directory end. MAIN loaders
`0x18B5E..0x18C21` and `0x18A3C..0x18B00` establish their header lengths.
Public tests use synthetic payloads; real-file tests require an explicitly
selected original directory. Local exports include payload hashes, consumed
lengths, decoded-pixel hashes and original file identities.

Opcode07 mode zero clears `[16,16,512,320]` and then uses the mode-one common
figure-panel path. The common panel is `[152,32,240,160]`; its 224×144 picture
is at `[160,40]`. Source draws an offscreen window at `[152,472]`, decodes the
picture at `[160,480]`, captures that completed panel and transitions it into
the visible destination (`MAIN0x206A8..0x207C7`). Original PACKGRP picture zero
is not selected by this opcode. Its window border belongs to separate original
window primitives, still a stated native-rendering limitation.

The interpreter preserves that panel for consecutive opcode08 text and restores
the saved underlying pixels before the first other instruction
(`0x1C1CF..0x1C1DF`, `0x207C8`). Initial new-game palette zero is an explicit
store at `0x1E49A..0x1E4A3`, through the byte setter `0x1E628..0x1E635`,
before context construction and the new-game menu. It is not inferred from a
map name. Four source palette variants are exported for later contexts.

The native VM owns that lifetime explicitly. It emits `close-story` before any
non08 instruction, including invisible flag writes and `FF`, and leaves the
source cursor unchanged until its next advance. The renderer restores the saved
underlay when it receives this command; it does not infer lifetime from the last
visible dialogue.

The current standalone decoder explicitly requires a zero-plane drawing base.
Preserved-plane identities remain in output metadata. Exact window border
primitives, original transition timing, grayscale and dynamic palette changes
remain separate work. Structural completion and visual inspection of decoded
source images are not an original DOS framebuffer parity recording.
