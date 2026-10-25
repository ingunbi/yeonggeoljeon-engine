# Contributing

This project reconstructs a native engine for the Korean DOS/V edition of
삼국지 영걸전. It is an early implementation, not an official KOEI product.

Contributions should start with one observable behavior or one file-format
question. Keep the original artifact digest, byte range, interpretation, and
remaining uncertainty in a local report. Public documentation may describe
formats and offsets; do not upload game files, extracted artwork, dialogue dumps,
or original executables.

Use synthetic data for ordinary automated tests. Real-file checks take an
explicit game directory and do not download or execute original programs. For
playback changes, compare the rendered frame and runtime state at a known script
boundary. A screenshot of the new engine alone does not prove parity with the
original game.

Keep data preparation, game state, rendering, and platform integration separate.
Preserve raw source references when translating bytecodes. Unknown commands must
produce a visible unsupported boundary; silently skipping them can change all
later behavior.

Run `python3 -m unittest discover -s Tests -v`, build the native app, and run its
bounded verification mode for relevant changes. Describe which checks actually
ran and what they do not cover. The source audit must pass before publication.
