# Source graphics ownership and scope

The resource reader supports the examined Korean DOS/V executable digest in
`research/README.md`. It does not assume the same offsets apply to other builds.

## Palace maps

PMAP LS11 members contain 640 background-cell bytes, 620 walk-cell bytes, then
an object count and three-byte object records. The native room is 512×320, with
32×20 background cells and a separate 31×20 staggered walk grid. The extractor
retains both representations; a background cell is not a walk-cell identity.

All 23 members are exported. The background comes from SMAPBGPL member 1.
MAIN file0x245FE..0x24628 selects that member for palace map kind2.

Prop-bank selection is two-stage: MAIN0x246BB..0x246C7 reads DS:3838 using the
local palace index, then DS:37FA using that result. The extractor reads the
actual original table values and records both offsets. A prop instance keeps
its original ordinal separately from the bank/pattern identity. It is not
reconstructed by parsing a display string.

## Palette selection

The default color palace initializer MAIN0x261F6..0x26237 passes2 at0x26207
to CF5:ACD8. MAIN0x1E628..0x1E635 stores that argument at game-state+5.
The palette caller at0x18346/0x18360 reads it through CF5:21EA
(MAIN0x15B3A..0x15B44), masks the low nibble, and the helper
MAIN0x182CE..0x18372 reads DS:1050 plus48 times that index. This establishes
palace slot2 on the examined default color path. Grayscale configuration and
dynamic palette changes are separate, unsupported behaviors.

This is static source derivation, not an original DOS framebuffer comparison.
Local output reports preserve actual palette byte offsets and input digests.

## Battle backgrounds

The battle extractor owns its original tile-bank and palette selection, decoded
image references and the logical battle-cell dimensions. Native loading verifies
the exported 32px logical-cell geometry before displaying a background. The
experimental board's unit circles, movement costs and combat rules do not imply
original battle-sprite or rule parity.

Original pixels, maps, object records and palette values are local output data;
none are part of the public source distribution.
