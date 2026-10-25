# END2 and the common final credits

This work uses static inspection of the selected END executable with SHA-256
`6a961179ee3b34d869ed3031523d616d79f1d863d61f4f4f6af8cebd1fe8dc77`.
Its load-header size is `1600`, and its DGROUP file base is `CE40`. No original
program is executed or modified. Text, palette payloads and extracted pixels
remain only in ignored local output.

The selection-three END2 branch is file `0x77BE..0x9541`. It is a separate
narrative sequence, not the shared final credits. END's main calls the common
final flow at `0x9570` after either END1 or END2 returns (`0x46CA..0x46E4`).
The entire END2 narrative has not been restored by this change.

The first END2 producer draws two NPK halves from END2 members zero and one,
320×328 at `(0,36)` and `(320,36)` (`0x7803..0x7880`). It cycles six raw
224×144 pictures, members two through seven, at `(376,84)`. Each raw picture
is nine consecutive 224×16 interleaved-planar strips. Its six five-line
captions are separate source word lists, displayed from `(16,240)` with the
source outline offsets. Two original palette references and the text pointer
facts are retained by the local reader. The next scene starts at `0x7C22`;
later palette, buffer-transition and randomized effects remain a distinct
restoration frontier.

The source `0:8642`, file `0x9C42..0x9D4F`, is a 16-pattern planar transition.
It calculates `(step*7)%16`, selects one of four row residues and a caller-owned
16-bit mask. At those rows it writes `old & mask | new & ~mask` to each pair
of plane bytes. The mask is not a transparent color: its low and high bytes
retain distinct plane identities. The source truncates height to complete
four-row blocks. The four actual masks are read from original data, never
embedded as a new public table. The independent helper takes explicit raw
buffer geometry and the supplied mask words.

The common flow at `0x9570..0x998B` displays twenty source credit pages. Each
contains seventeen 20-pixel lines and is 160×340 at `(384,32)` in the examined
profile. It uses the same source Korean/ASCII glyph mapping and bold expansion
as the restored ending text, with color index seven. Nine raw END1 pictures,
members 56 through 64, are 288×240 at `(0,0)`. The source preloads each picture
on an even page, transitions it on the following odd page, then uses a final
black pending picture. Palette-pointer payloads remain local.

Each page performs fifty text-pattern phases. Line transitions start two phases
apart; all fifty phases use ten-centisecond absolute deadline increments.
The source then adds 100 centiseconds. Odd-page picture transitions have
sixteen 15-centisecond increments and separate palette steps; the remaining
page wait is 260 centiseconds. Other pages wait 500 centiseconds after their
preload. The event schedule preserves this exact order.

Clock domains remain distinct. The common flow resets its DOS-centisecond
clock, waits for deadline 200, then polls the audio driver until idle before
selecting its next music (`0x962C..0x9646`). Palette steps use a source driver
timer, not DOS centiseconds. Such waits may make a later absolute deadline
already overdue. The source's final centisecond deadline is therefore a
schedule fact, not a measured total wall-clock duration.

After the pages, the source draws NPK member 68 at `(216,80)` and NPK member
zero at `(184,200)`, selects its final palette and waits again. The final input
loop is now identified: `0:A564`, file `0xBB64..0xBB7B`, always returns one;
`0:7F42`, file `0x9542..0x956F`, uses INT33 function three and accepts either
of the low two mouse-button bits. A native acknowledgement may model that
button gate. It is not an automatic timeout or a keyboard-only gate.

After this input the source stops music, fades to black, clears the display,
closes the archive and returns normally at `0x998B`. The helper exports an
explicit source-return event after those gates. It does not label a frame-list
EOF as completed ending playback. Audio-driver timing, palette-timer execution
and the remaining END2 narrative need their own restored owners before native
whole-ending completion can be asserted.

`tools/ending_credits.py` contains only the new geometry-aware transition codec,
source-order event schedule and pointer-fact readers. Synthetic tests distinguish
row/plane ownership, partial geometry and gated completion. Optional original
checks pin the source profile and verify its pointer population and masks.
Local PNG inspection confirms the examined raw picture geometry and original
credit bitmap rendering; it is not original DOS framebuffer comparison.
