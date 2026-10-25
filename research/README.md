# Evidence and implementation provenance

The engine source is newly written for this project. The previous experimental
application used Eiketsuden Reloaded; that fork stays outside this repository.
Its implementation and generated content packs are not build inputs here.

Prior reverse-engineering sessions supplied source-bound notes on the Korean
DOS/V edition's graphics, town movement, and opening title layout. These notes
were produced while that earlier fork was being investigated. Some contributors
have seen that engine's source; this is **not** an assertion of an isolated
clean-room process. Format facts and original executable observations are
distinguished from external implementations.

## Supported original identity

| Input | SHA-256 |
|---|---|
| Korean DOS/V MAIN.EXE | `731c8d26a39fcd4e9fa41b142db9bd5913a496a2da5eaa1db798b7867850815f` |
| Korean DOS/V OPEN.EXE | `97f5f00fee2b340243bda76166e3d989740d8723a20f72a6b38545f848c18a01` |

These identify an examined build; matching one file does not establish the
identity of all other game resources. Export reports hash the actual inputs.
The engine build tools read original executables as data and never execute them.

## Evidence categories

- **Observed bytes:** source file digests, container records, sprite cells,
  scenario operands, message text, palette entries.
- **Static derivation:** interpretation of those bytes supported by the original
  code's input/output behavior at recorded file offsets.
- **Native verification:** the new engine's decoded pixels, state transitions,
  and generated frames.
- **Unverified parity:** original live timing, sound, complete branches and
  campaign behavior until explicitly compared in future work.

Local reports and original-data exports belong in `build/` or `research/local/`,
both ignored. Public documentation describes formats and research conclusions
without redistributing the original game.
