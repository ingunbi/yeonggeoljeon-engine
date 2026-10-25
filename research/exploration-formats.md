# Original exploration resources

`prepare_world.py` writes a separate local `exploration.json`. Original pixels,
maps, city records, table values and initial actor references remain ignored
local output. Its shared settlement-map reader also serves palace extraction;
neither consumer reparses a different representation of the same source layout.

SMAP has twelve LS11 members. Like PMAP, each has 640 picture-cell references,
620 separate staggered walk cells, and a count followed by three-byte prop
instances. Town background uses SMAPBGPL member zero, props use SSCCHR1 bank
zero, and default town colors use MAIN palette slot zero. Town logical geometry
remains 31×20 with 16px steps and an 8px odd-column stagger; the background is
32×20 tiles. The script/current-city loader is `0x244FA..0x24790`.

MMAP has four LS11 members. MMAPBGPL has one LS11 member holding 255 planar
16px tiles. MAIN DS:`2F06` has five chapter-indexed **byte** width/height pairs;
DS:`2F9C` has five 16-bit member selectors. The world loader is
`0x21D6C..0x21E30`, and the dimension getter is `0x21072..0x210A1`.

Each world member begins with width×height picture bytes, followed by one
MSB-first walk bit per logical cell. Logical width and height are half the
picture dimensions. A zero bit is passable. Original packed bits are retained
alongside decoded walk bytes; the latter use the native blocked mask `80`.
Source movement makes two 16px halfsteps per 32px logical step. Neighbor order
comes from signed-word tables DS:`2F1C` and DS:`2F2C`.

City constructors read chapter group DS:`0EBC`, group count DS:`1360`, group
base DS:`1366`, global position pairs DS:`136C`, and town member DS:`1408`
(`0x1AF7A..0x1B039`). BBKSDAT1 has four uncompressed `380`-byte groups of
32×23 constant bytes and 32×5 initial-state bytes. City names copy eight bytes.
An original `(FF,FF)` position remains an unplaced sentinel, with nullable
coordinates and separately preserved raw values; it is not clamped onto a map.

Town actors use SSCCHR2's four 32×40 frames under palette slot zero. World
actors use eight SSCCHR1 patterns in source role+2 banks under palette slot
one, with no horizontal flip and anchor `height-32`. Direction base frames
come from DS:`2FA6`; walking phase is added to that base. The initial role
reference is BAKDATA state byte one, separate from a person's town sprite
reference in constant byte sixteen. Native person state owns later changes.

These are static source and format observations for the pinned MAIN digest,
not a DOS framebuffer comparison. Default palettes are supported; grayscale,
dynamic palette changes, citizens and interactive exploration have additional
execution requirements. PNG rendering and complete file export do not establish
full campaign playability.
