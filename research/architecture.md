# Initial engine architecture

```text
caller-owned original files
  ├─ resource_formats.py        bounded LS11 / pixel codecs
  ├─ prepare_resources.py       source graphics, geometry and identities
  ├─ prepare_scene.py           source instructions and dialogue references
  ├─ prepare_campaign.py        source record directory and transitions
  └─ prepare_battles.py         source battle maps and placement facts
          ↓ local-only JSON + PNG
  DataSet                      typed, contained native data
          ↓
  Runtime                      command cursor, actor state, movement batches
  BattleSession                explicitly selected experimental policy
  CampaignSession              research previews, identities and result origin
          ↓
  Renderer                     640×400 source-coordinate canvas
          ↓
  AppKit host                  window, elapsed time and confirmation input
```

The parser owns source formats. Consumers do not reinterpret raw byte ranges or
display identities. Actor/person IDs, object pattern IDs, and object instance
IDs retain distinct meanings. Source locations survive translation into commands
and the runtime trace.

Runtime time is explicit integer microseconds. Confirmation advances one title
or dialogue boundary; movement owns time until all members of its source batch
finish. Diagnostics use the same runtime and renderer with deterministic inputs.
The host supplies actual elapsed time and macOS input during interactive use.

Unknown operations and malformed operands are explicit outcomes. Reaching an
unsupported source boundary is different from consuming a supported scene, and
both differ from a runtime failure. Diagnostics must not infer success merely
because the command loop stopped.

The source campaign catalog and native battle research policy extend the first
bounded palace implementation. Complete campaign dispatch, original combat
rules/AI, player-controlled town exploration, source font rendering, sound and
progress saves require further implementation and original-runtime comparison.
Experimental battle mechanics do not fill those gaps as original behavior.
Existing code or saves from another game engine are not silently used.
