# Initial engine architecture

```text
caller-owned original files
  ├─ resource_formats.py        bounded LS11 / pixel codecs
  ├─ prepare_resources.py       source graphics, geometry and identities
  └─ prepare_scene.py           source instructions and dialogue references
          ↓ local-only JSON + PNG
  DataSet                      typed, contained native data
          ↓
  Runtime                      command cursor, actor state, movement batches
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

The first implementation is deliberately a bounded original palace record.
Full campaign dispatch, player-controlled town exploration, battle rules/AI,
source font rendering, sound synthesis, and progress saves require subsequent
implementation and original-runtime comparison. Existing code or saves from
another game engine are not silently used to fill these gaps.
