# Music

Static derivations from the pinned files; no original program was run. Addresses
are `SBOPL2.COM` memory addresses (the file loads at 0x100). Song data stays in
local GameData (`music.json`).

`HERO.COM` starts `SBOPL2.COM`, "Sound Blaster BGM Driver 1.01", which stays
resident on interrupt 66h and drives an OPL2 at port 388h. `CF5:600A` takes a
selection below 20 and asks the driver to play that member of `MUSIC.R3`, unless it
is already the current selection. The VM's `currentMusic` is this selection.
`OPMUSIC.R3` and `EDMUSIC.R3` belong to the opening and ending programs.

## Files

A music file holds a count word, then a 32-bit offset and a 16-bit size per member,
then the data. A member starts with seven words, the track offsets from the member
start; zero means no track. Instrument records and tracks follow, and a track
refers to its instrument by a word relative to the command byte. All 150 tracks of
the 25 members parse to an end command.

## Instruments

22 bytes (0x846, 0xB18): 0x20 and 0x23, 0xC0, 0xE0 and 0xE3, 0x40 and 0x43, 0x60 and
0x63, 0x80 and 0x83 values, then transpose, modulation speed (word), wave, pitch
depth, depth index, level depth, two operator shares, delay and an enable byte.

## Tracks

| Byte | Meaning |
|---|---|
| 00..5F | Note with its own step and gate bytes. Gate zero is a rest. A gate past the step ties into the next note. |
| 60..BF | Note 0..5F with the current step and gate. |
| D0 | Repeat start. |
| D1..DF | Repeat end with that many extra passes. |
| EE, EF | Deep tremolo and deep vibrato bits of register BD. |
| F0 | Volume. It is an attenuation: half of it is added to the carrier's level. |
| F1, F2 | Tempo, as a timer value or as a number. F2 sets 0x464E×tempo/100 per interrupt. |
| F4 | Instrument. |
| F6, F7 | Pitch glide: interval and length, tempo-scaled for F6. |
| F8, F9 | Modulation on and off. |
| FD | Leave the repeat on its last pass. |
| FE | Loop point. |
| FF | End. With looping on, every track returns to its own loop point. |

C0..CF, E0..ED, F3, F5, FA..FC do nothing for this driver; the middle ranges skip
their operands.

## Timing

The driver sets the PIT divisor to 0x1000, about 291.3 interrupts per second. Each
interrupt adds the tempo word to a 16-bit fraction, and a carry is one music tick.
At tempo 120 that is 96 ticks per second, so a quarter note of 48 ticks takes half
a second. A second fraction of 0x36/256 runs modulation and glides at about 61 Hz.

## Native playback

`OriginalMusicDriver` ports the interpreter from 0x30E to 0x113F and writes OPL
registers through a closure. `OPL2Chip` is written from the chip's documented
behavior: phase, envelope, key scaling, vibrato, tremolo, feedback and the four
waveforms. It omits rhythm mode and timers, which the driver does not use, and it
was not compared with real hardware output. `OriginalAudio` runs both at 49716 Hz
behind an `AVAudioSourceNode`. `--render-music N --output FILE` writes twenty seconds
to a WAV. Music starts with the first selection, so tests and replays never open
audio. The BGM entries of the field and battle menus switch it on and off.

## Not restored

- Sound effects. The driver has a two-track effect player (0x491, 0xE13), but the
  table it reads was not found.
- Volume, the opening and the ending music.
- The 20-to-1 fade the source uses when it leaves a scene (`CF5:5F56`).

## Sound effects

`CF5:5EC2` (`19812`) installs a bank at `3021:0004` through interrupt 66h function
10. That address is inside `MAIN.EXE`, at file offset `0x36C14`, up to the data
segment: 4492 bytes. The bank holds 43 entries of two words. Each word is a track
offset from its own entry, and a track reads instruments and notes as a song does.

Function 11 (`0x4FE`) stops any effect and starts the two tracks on OPL channels 7
and 8, with volume 15. The caller passes the source id plus one (`19AEA`), and ids
stop at `2B` (`19B66`). The tracks advance on the same 61 Hz clock as modulation
(`0xE13`), not on the tempo clock, and they never loop. Music uses seven tracks, so
the two never share a channel.

All 43 effects render to 0.1 to 3 seconds of sound. Nobody has compared them by ear
with the original.

Heard ids: 0 accept, 1 cancel, 2 refusal, 3 purchase, 4 sale, 7 level, 8 item,
9 retirement, 10 cursor, 19 arrow, 37 thrown item, 41 clash. Battle effects read
DS:`3F7E`. The ids 17, 21, 38 and 40 belong to duel motions, and 11, 13, 22 and
others to the enlarged combat view; those are not played yet.

## Opening and ending programs

`OPEN.EXE` and `END.EXE` carry the same library and load their own files. Their
play routine takes a member number: `OPEN.EXE` asks for 0 at `0x468A` and 1 at
`0x64BE`, and `END.EXE` for 0, 1 and 2 at `0x48F3`, `0x7895` and `0x9641`.
