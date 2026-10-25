#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Export source retirement quotes/messages to an ignored local data directory."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import sys

from prepare_resources import EXAMINED_MAIN, inventory
from prepare_scene import read_resource, text_at
from resource_formats import Archive, ResourceError


def quote_bank(data: bytes) -> tuple[list[dict], dict]:
    """MAIN2AF5A selects a byte-person record and normalizes four glyph pairs.

    The original lookup stops at FF; bytes after it are retained as ignored
    trailer evidence, rather than silently treated as more quote records.
    """
    cursor, entries = 0, []
    punctuation = {b"\xa1\xa4": b",", b"\xa1\xa1": b" ", b"\xa1\xa5": b".", b"\xa1\xaa": b"!"}
    while cursor < len(data):
        start, person = cursor, data[cursor]
        cursor += 1
        if person == 255:
            return entries, {"sourceReaderEnd": cursor, "ignoredTrailerLength": len(data) - cursor,
                             "ignoredTrailerSha256": hashlib.sha256(data[cursor:]).hexdigest()}
        body_start = cursor
        while cursor < len(data) and data[cursor] >= 128:
            if cursor + 1 >= len(data):
                raise ResourceError("retirement quote ends inside a source character pair")
            cursor += 2
        if cursor == len(data):
            raise ResourceError("retirement quote has no low-byte record delimiter")
        body_end, delimiter = cursor, data[cursor]
        normalized, position = bytearray(), body_start
        while position < body_end and data[position] >= 0xA1:
            pair = data[position:position + 2]
            normalized.extend(punctuation.get(pair, pair))
            position += 2
        try:
            text = normalized.decode("cp949", errors="strict")
        except UnicodeDecodeError as error:
            raise ResourceError(f"retirement quote has invalid original Korean text: {error}") from error
        cursor += 1
        entries.append({"person": person, "text": text,
                        "source": {"decodedOffset": start, "decodedLength": cursor - start,
                                   "bodyOffset": body_start, "bodyLength": body_end - body_start,
                                   "delimiter": delimiter, "renderedSourceEnd": position}})
    raise ResourceError("retirement quote list has no source FF terminator")


def prepare(game: Path, output: Path) -> dict:
    game, output = game.resolve(), output.resolve()
    if output == game or game in output.parents:
        raise ResourceError("retirement output must be outside the selected original directory")
    before = inventory(game)
    selected = {name: read_resource(game, name) for name in ("MAIN.EXE", "HEXGRP.R3")}
    main = selected["MAIN.EXE"][0]
    if hashlib.sha256(main).hexdigest() != EXAMINED_MAIN:
        raise ResourceError("MAIN does not match the examined retirement producer")
    archive = Archive(selected["HEXGRP.R3"][0], "HEXGRP.R3")
    if len(archive) != 3:
        raise ResourceError("retirement resource directory differs from the examined source")
    banks = []
    for bank in (0, 1):
        member = archive.decode(bank + 1)
        entries, trailer = quote_bank(member.data)
        banks.append({"bank": bank, "entries": entries, "source": {**member.provenance(), **trailer}})
    messages, sources = {}, {}
    for name, offset in [("leaderDefeat", 0x4171), ("retreated", 0x41B9), ("died", 0x41CC)]:
        start = 0x37DA0 + offset
        value, end = text_at(main, start, len(main), "MAIN.EXE")
        if name != "leaderDefeat" and value.count("%s") != 1:
            raise ResourceError("retirement popup no longer has its examined single-name substitution")
        messages[name] = value
        sources[name] = {"resource": "MAIN.EXE", "offset": start, "length": end - start}
    if inventory(game) != before:
        raise ResourceError("original files changed during retirement text extraction")
    result = {"format": 1, "quoteBanks": banks, "messages": messages,
              "source": {"inputs": [item[1] for item in selected.values()], "messages": sources,
                         "quoteProducer": "MAIN.EXE:0x2AF5A..0x2B067",
                         "dispatcher": "MAIN.EXE:0x2BA64..0x2BCA5",
                         "originalHashesPreserved": True, "originalProgramsExecuted": False}}
    output.mkdir(parents=True, exist_ok=True)
    temporary = output / ".retirement.json.tmp"
    temporary.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(output / "retirement.json")
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--game-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        result = prepare(args.game_dir, args.output)
    except (OSError, ValueError) as error:
        print(f"retirement preparation failed: {error}", file=sys.stderr)
        return 1
    print(json.dumps({"banks": len(result["quoteBanks"]), "quotes": sum(len(b["entries"]) for b in result["quoteBanks"]),
                      "messages": len(result["messages"]), "originalHashesPreserved": True}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
