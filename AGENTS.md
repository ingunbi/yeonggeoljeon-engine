# Yeonggeoljeon Engine

Develop the engine from original-game observations and source-bound format
research. Keep the former Eiketsuden Reloaded fork separate. Do not import its
code, generated content packs, saves, or substitute art into this repository.
Record analysis references and distinguish static derivation from runtime
comparison. Do not claim an isolated clean-room process.

Keep original game files, extracted art, dialogue exports, and local reports in
ignored local/build directories. Public tests use synthetic inputs; optional
real-file checks require a caller-selected original game directory. Never run or
modify original DOS executables. Preserve source file hashes and current saves.

Use system Python 3 and the installed Xcode Swift tools. Do not install global
packages. Python extraction owns original formats; typed runtime data owns native
state; AppKit owns the window/input surface. Fail explicitly at unsupported
commands instead of inventing game behavior. Keep source byte offsets in local
outputs. Use deterministic fixed-step verification for the implemented slice
and report its limits separately from real OS input or original-runtime parity.

The project owner selected GPL-3.0-only for the new code. Before publishing,
audit the exact source file list. A local build is not a public repository or a
complete game engine.
