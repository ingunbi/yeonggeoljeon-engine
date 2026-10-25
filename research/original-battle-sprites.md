<!-- SPDX-License-Identifier: GPL-3.0-only -->
# Native battle-map sprites

The new reader reconstructs caller-owned HEXZCHR data without running the
original program or importing an external engine. All original tables, pixels,
PNG files, contact sheets and converted catalogs stay in ignored local build
paths. The public repository contains only new readers, typed selection rules,
synthetic tests and these source-derived format facts.

HEXZCHR has47 archive members. Each member decodes to1024 bytes: eight independent
16 by16 four-plane tiles. Four consecutive tiles form a32 by32 frame in row-major
quadrant order; the remaining four form its second frame. The source loader
reads each128-byte tile separately and expands it with a32-byte mask. A mask bit
is the complement of the OR of all four planes, so precisely palette index0 is
transparent. The local converter reuses the resource-format owner's LS11 and
planar readers and the palette owner's battle slot3 conversion.

The native member selector first handles condition flag2 using the side-specific
condition sprite. Otherwise person0 uses a class-relative special bank, persons4
and8 use fixed special members, and ordinary units use twice their class plus
native enemy-side identity. Faction is the live runtime slot, independent of a
shared person's affiliation byte. A source reference outside the available
archive remains unsupported; it does not fall back to another unit's art.

Facing is a whole-frame horizontal flip under live script flag10. The source
reverses pixels and swaps tile columns, preserving frame and tile-row identities.
It supplies no separate north/south artwork. East movement clears the flip, west
movement sets it, and vertical movement retains the preceding facing. Byte8
remains the independent AI priority and is never interpreted as a facing field.

For a standing unit, native battle-object byte5 selects the alternate frame;
acted flag80 also forces that second frame. The selector requires this phase
explicitly. Movement chooses frame0 below eight within each sixteen-pixel span
and frame1 for the next eight. The engine owns presentation time and movement
state; this catalog does not invent a wall-clock phase or change live flags as a
side effect of drawing. A movement-flags helper exposes the exact facing update
for the live-state owner.

`prepare_battle_sprites.py` writes `battle-sprites.json` with188 local map PNG
files:47 members by two frames by two orientations. `OriginalBattleSprites` validates
all frame identities, dimensions, palette slot and contained relative paths.
Its returned selection supplies one already oriented PNG path plus explicit
member, frame and flipped facts. The AppKit owner scales these32-pixel images
with nearest-neighbor sampling at the unit's32-pixel map cell. Native viewport
clipping, hidden-unit gates, special draw effects and palette transformations
remain renderer responsibilities.

Source investigation covers the unit loader, tile-mask builder, sprite-flip
producer, standing frame selection and both movement frame branches. The local
manifest retains their precise file offsets, original hashes and archive-member
bounds. All47 original members decode and synthetic tests check tile ordering,
transparency, pixel mirroring, selection precedence, source direction changes,
frame boundaries and malformed catalog identities/paths. This is static source
reconstruction; no original DOS framebuffer or timing comparison was performed.

The optional duel catalog adds156 local PNG files from HEXICHR:78 original
members by two orientations. Each member contains36 consecutive planar tiles,
composed into one96 by96 frame using six columns and six rows. Its loader mode
owns picture identity: modes0/1 load the first ten frames of a participant's
fifteen-frame bank; mode2 replaces participant1's buffer with the last five
mirrored death frames; mode3 replaces it with three shifted, unmirrored flee
frames. The bank comes from source special-person selectors, two exceptional
person identities, or generic participant side. Special-person table bytes stay
in the local converted catalog; public tests supply different synthetic values.
`OriginalDuelSprites.select(person:loadMode:frame:)` requires that load mode
explicitly, since the same pose index refers to different pixels after a reload.
The separate HEXBCHR enlarged-combat producer remains outside this catalog.

`OriginalScriptDuel` owns the current load modes alongside poses and positions.
New duel setup initializes modes0/1; source motion3 reloads participant1 with
mode2 before its death pose, and motion4 reloads participant1 with mode3 before
its fleeing movement. The renderer consumes those state facts and never infers
the buffer contents from the last opcode.

Native duel composition uses a416 by208 viewport at DOS pixel(16,32). A
participant's96 by96 graphic starts at(16+16*x,32+16*y), using its signed native
tile position. The default row3 therefore anchors at y80. The camera producer
already shifts the participant positions; subtracting the camera byte again
would move the actor twice. Native signed out-of-view coordinates remain valid
and are clipped to the viewport. The tile compositor draws participant1 first
and participant0 above it. `OriginalDuelSprites.sourceRect`, `sourceViewport`
and `sourceDrawOrder` own these conversions for the AppKit consumer.
