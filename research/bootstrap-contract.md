# First playable research slice

This is a new implementation, separate from the previous public-engine fork.
Do not copy or adapt that engine's implementation or generated content pack.
Use original game bytes and the source-bound disassembly/research records to
implement supported behavior. Record every reused research reference. This is
not a claim that a legally isolated clean-room process was performed.

## Resource export

`tools/prepare_resources.py --game-dir PATH --output PATH [--title-opgrp PATH]`
reads the caller-selected game directory without changing it, writing PNGs and
`resources.json` beneath the output folder. Each image path is relative to the
output folder and must remain contained there.

JSON shape:

```json
{"format":1,"title":"images/title.png","maps":{"8192":{"image":"images/palace-0.png","width":512,"height":320}},"actors":{"319":{"image":"images/person-319.png","frameWidth":32,"frameHeight":40,"frames":4,"anchorX":0,"anchorY":24}},"portraits":{},"provenance":{}}
```

Map JSON keys are decimal packed map IDs. Actor keys are literal BAKDATA person
IDs. Actor sheets have four source frames horizontally; source-bound direction
selection is provided in the actor record as optional `directions` array of four
objects `{ "frame":0,"flip":false }`. Original town coordinates transform to
pixel coordinates using the source rules; document these and expose them in
scene metadata. Image paths and optional fields can be extended additively.
Source images are local build outputs, never repository content.

## Original first-scene extraction

`tools/prepare_scene.py --game-dir PATH --output PATH` writes `scene.json`:

```json
{"format":1,"id":"original-opening-palace","name":"낙양 궁전","width":640,"height":400,"coordinateSystem":"town","commands":[{"op":"map","map":8192,"source":{}},{"op":"place","person":319,"x":26,"y":8,"facing":0,"source":{}},{"op":"move","person":319,"x":26,"y":12,"source":{}},{"op":"say","person":319,"speaker":"동탁","text":"...","source":{}},{"op":"remove","person":319,"source":{}},{"op":"end","reason":"bounded first-scene extraction","source":{}}],"provenance":{}}
```

Implement commands actually established by source records. Do not invent drama
or silently skip unknown bytecodes. End with an explicit unsupported boundary if
necessary. Supported extra commands: `wait` with seconds, `fade` with seconds and
`to` (`black` or `visible`), `camera` with x/y source coordinates. Sequential
`move` commands are one simultaneous batch, and the runtime waits for the batch.
All commands preserve the originating resource/member and byte offset.

## Native runtime

Swift/AppKit/CoreGraphics with no external game engine dependency. Source files
live in `Sources/YeonggeoljeonEngine`. Load `resources.json` and `scene.json` from
an explicit `--data` directory or the app's `Resources/GameData`. Title -> original
scene, actors, movement, source dialogue. Nearest-neighbor 640x400 canvas.
No public-engine saves or app files are modified.

Provide `--verify --data PATH --output PATH` for bounded deterministic runtime
verification with screenshots and JSON evidence. A verification mode must exit
and not mutate user progress. App bundle/build integration is owned by root.
