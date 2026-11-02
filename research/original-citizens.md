# Original citizens

Local inputs: `BAKDATA.R3`, `IPPAN0.R3`, `IPPAN0M.R3` and `MAIN.EXE`. Output:
`citizens.json`. All of this is static derivation; nothing was compared with a
running original.

## Data

- `BAKDATA.R3` holds 256 citizen rows of 13 bytes. Bytes 0..7 are the name and
  byte 8 is the town sprite (`1AD46..1ADAD`).
- `IPPAN0.R3` holds four group tables. Sizes come from DS:`393A`, offsets from
  DS:`3942`. Each table starts with a city count, one word per city, a word, then
  one message word per citizen. A city word points at rows of key, member count
  and citizen ids (`1FE97..1FEFF`).
- `IPPAN0M.R3` holds the lines. DS:`2DD0` gives each group's base, and `FFFF`
  means the citizen has no line.

Citizens use actor class `0x400`, object DS:`BC96`, stride `0x10`.

## Placement

Script opcode `1F` and native settlement entry both reach `26298`
(`1CB6:2D38`). `18E8` returns the first class-`0x400` slot, so placement runs only
when no citizen stands on the map. The key is the room index, or `7D` for the
city itself. The draw order per citizen is x from RNG `1F`, y from RNG `13`, one
added to an odd coordinate, a retry unless the cell byte is `7F`, then facing
from RNG 4, then RNG 16 and RNG 3.

These draws consume the shared generator, so entering a town changes every later
battle's dice. Replay inputs recorded before this restoration do not carry over.

## Talking

Citizen arrival runs `26AB9..26B24`, which shows the line and does not restore
facing. Lines come from the word at block offset `3+2n+2id`.

## Wandering

`257AC..2591F` runs each loop frame. A citizen alternates standing and walking. A
walk draws a direction from RNG 4 and a length from RNG 16 plus one, and standing
draws RNG 2; a counter that comes out even or zero gains one, so it is odd. Each
walking frame tries the neighbor cell. The cell byte must be `7F` and the cell must
stay within three of the citizen's placed home, or the walk ends.

The source draws from the shared generator, so its battle dice depend on how long
a player stands in town. The engine draws from a generator of its own and only in
the window, so verification and replays keep citizens still. Wandering pauses
while a script or the player's own walk runs; the source does not pause.

## Not restored

- Settlement status one with kind two (`264A6`), which places citizens after a
  destination script on a map that has none.
