# Enlarged combat view

Static derivation from `MAIN.EXE`, `HEXBCHR.R3`, `HEXBCHP.R3` and `HEXBMAP.R3`. No
original program was run, and nothing was compared with a DOS framebuffer. File
offsets are MAIN unless noted. Output: local `combat-view.json`.

## When it runs

`DEFE` (`0x3145E`) is true while the option word's high nibble is clear, so the view
is on by default (부대전투 = 본다). It belongs to the strike body of context `E91A`:
damage, morale, EXP and the counter roll run first, then `0x3218E` opens the scene,
then results, then the writeback.

The view draws no random numbers and writes no game state. A call-graph walk from
its routines finds no path to the generator. So `OriginalAttackOperation` and the
strategy and item operations commit their result, then yield it with a snapshot of
the values from before the blow. The flow holds there and the window plays the
scene. Verification and `--battle` skip it and run the same steps in the same order.

Callers are the player and AI attacks, the counter (subtype 7), strategies 0 to 14
on each target, and items `22` to `2A`. A miss and a zero hit get the full scene.

## Art

`HEXBCHP` holds 224 opaque 16 by 16 tiles. `HEXBMAP` members 0 to 4 are 46 by 5 sky
bands and 5 to 8 are 66 by 8 ground bands, chosen by terrain through DS:`4E42` and
DS:`4E56`. `HEXBCHR` holds 181 frames: 169 of 4 by 4 tiles and 12 of 3 by 3 shots. The first 154 are class art.
Class frames sit at the running sum of DS:`4E08`. Frames face right and side one
mirrors them. Index zero is transparent.

The scene is a 26 by 13 tile grid of four layers. A stamp replaces the tile in its
layer and cell, and a sprite's top row goes to layer three and its bottom row to
layer zero. So a sprite lower on the screen covers one above it, and erasing or
overlapping needs no other rule (`2A294`). Sky scrolls at a third of ground speed.

## Scene

`OriginalCombatScene` builds the whole scene as a list of held frames.

| Step | Source | Notes |
|---|---|---|
| Begin | `32318` | Sixty ticks, a mouse button ends it. A counter opens with a notice first. |
| Prep | `32F86` | Physical only. Three poses, with the shot's sound. |
| Run | `3308E` | 41 steps. The attacker runs in place while the target and ground slide in. |
| Swing | `3319A` | Melee classes, two poses of twelve ticks. |
| Pan | `3321A` | Shots and strategies, 21 steps. The overlay stays fixed while the world slides. |
| Hit | `3341C` | The target is shoved one cell per hundred troops, thirteen on a kill. |
| Results | `31A06` | Pages of sixty ticks, a mouse button ends each. |

Soldiers are `min(5, troops/600+1)`, fixed for the scene. Nobody leaves as they die.
Damage shows only as the shove and the numbers.

Held quirks of the source: the background snaps back after a pan, because the pan
does not store its scroll; tigers, carts and flames stay on screen through the hit;
and the hit sound follows the attacker's class even for a strategy.

## Differences

- The stat panels and the result window use the native panel and native text, not
  the MARK tiles and the source font. Positions and values follow the source.
- Steps of one tick are floors. On period hardware a full redraw took longer, so
  Run and Pan were likely slower than 41 and 21 ticks.
- A right click or Escape ends the scene at once, which the source cannot do. It
  has no effect on results.
- The ambush notice and the level notices over the scene are not restored.
- A terrain byte past the source's twenty entries opens no scene.
