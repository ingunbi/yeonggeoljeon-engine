#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Read original constant and initial person state into local-only engine data."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import struct
import sys

from prepare_resources import EXAMINED_MAIN, inventory
from prepare_scene import read_resource, SceneError

PERSON_COUNT = 384
CONSTANT_BASE = 0x1100
CONSTANT_STRIDE = 21
STATE_BASE = CONSTANT_BASE + PERSON_COUNT * CONSTANT_STRIDE
STATE_STRIDE = 18


def scalar(value: int) -> int:
    # MAIN1AE18..1AE34 is the original scalar constructor's signed clamp.
    return min(100, max(0, value))


def decode_person(constant: bytes, state: bytes, person: int) -> dict:
    if len(constant) != CONSTANT_STRIDE or len(state) != STATE_STRIDE:
        raise SceneError("person constant/state record is truncated")
    if not 0 <= person < PERSON_COUNT:
        raise SceneError("person identity is outside the examined source population")
    try:
        name = constant[:6].split(b"\0", 1)[0].decode("cp949", errors="strict")
    except UnicodeDecodeError as error:
        raise SceneError("person display name is not valid Korean source text") from error
    return {"id": person, "name": name,
            "classID": state[7], "level": state[8], "experience": state[9],
            "rawTroops": struct.unpack_from("<H", state, 5)[0],
            "defenseScalar": scalar(constant[17]), "attackScalar": scalar(constant[18]),
            "intellectScalar": scalar(constant[19]), "personality": constant[20],
            "personalScalar": scalar(state[4]), "itemIDs": list(state[10:18]),
            "sourceFlags": state[0], "sourceRole": state[1],
            "sourceContext2": state[2], "sourceContext3": state[3],
            "source": {"resource": "BAKDATA.R3",
                       "constantOffset": CONSTANT_BASE + person * CONSTANT_STRIDE,
                       "constantLength": CONSTANT_STRIDE,
                       "stateOffset": STATE_BASE + person * STATE_STRIDE,
                       "stateLength": STATE_STRIDE,
                       "constantRaw": constant.hex(), "stateRaw": state.hex(),
                       "constructor": "MAIN.EXE:0x1A9CA..0x1AB99",
                       "loader": "MAIN.EXE:0x1EAC9..0x1EAEE",
                       "troopInitialization": "source constructor clamps raw troops to source max; battle initialization may reset it"}}


def prepare(game: Path, output: Path) -> dict:
    game, output = game.resolve(), output.resolve()
    if output == game or game in output.parents:
        raise SceneError("person output must be outside the selected original directory")
    before = inventory(game)
    main, main_source = read_resource(game, "MAIN.EXE")
    if hashlib.sha256(main).hexdigest() != EXAMINED_MAIN:
        raise SceneError("MAIN does not match the examined original person constructor")
    data, source = read_resource(game, "BAKDATA.R3")
    if len(data) != STATE_BASE + PERSON_COUNT * STATE_STRIDE:
        raise SceneError("BAKDATA does not match the source constant/state extent")
    people = []
    for person in range(PERSON_COUNT):
        a = CONSTANT_BASE + person * CONSTANT_STRIDE
        b = STATE_BASE + person * STATE_STRIDE
        people.append(decode_person(data[a:a + CONSTANT_STRIDE], data[b:b + STATE_STRIDE], person))
    if inventory(game) != before:
        raise SceneError("original files changed while reading initial person data")
    result = {"format": 1, "people": people,
              "source": {"inputs": [main_source, source], "originalHashesPreserved": True,
                         "originalProgramsExecuted": False},
              "limitations": ["These are original initial values, not a selected campaign save.",
                              "Current troop clamping, class changes and battle initialization are runtime-owned.",
                              "Source role and context bytes are preserved separately from native faction/slot identity."]}
    output.mkdir(parents=True, exist_ok=True)
    temporary = output / ".people.json.tmp"
    temporary.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(output / "people.json")
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--game-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        result = prepare(args.game_dir, args.output)
    except (OSError, ValueError) as error:
        print(f"person preparation failed: {error}", file=sys.stderr)
        return 1
    print(json.dumps({"people": len(result["people"]), "originalHashesPreserved": True}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
