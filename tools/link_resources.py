#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Link independently decoded image catalogs through their source identities."""
import argparse
import json
from pathlib import Path, PurePosixPath


def link(resources: dict, story: dict) -> dict:
    if resources.get("format") != 1 or story.get("format") != 1:
        raise ValueError("unsupported resource/story catalog format")
    assets = story.get("portraitAssets", [])
    pictures = {asset["id"]: asset for asset in assets}
    if len(pictures) != len(assets):
        raise ValueError("portrait asset identity is ambiguous")
    portraits = {}
    for person, actor in resources["actors"].items():
        identity = actor.get("portraitIndex")
        if identity is None:
            continue
        if identity not in pictures:
            raise ValueError("source actor portrait identity is unavailable")
        asset = pictures[identity]
        if (asset["width"], asset["height"]) != (64, 80):
            raise ValueError("source portrait geometry disagrees with its renderer")
        images = asset["imagesByPalette"]
        if set(images) != {"0", "1", "2", "3"}:
            raise ValueError("portrait palette coverage is incomplete")
        for image in images.values():
            path = PurePosixPath(image)
            if path.is_absolute() or ".." in path.parts or ":" in image:
                raise ValueError("portrait image is not a contained catalog path")
        portraits[person] = {"imagesByPalette": images, "width": 64, "height": 80,
                             "source": {"portraitID": identity, "owner": "story.json/portraitAssets"}}
    return {**resources, "portraits": portraits}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data", type=Path, required=True)
    args = parser.parse_args()
    resources = args.data / "resources.json"
    value = link(json.loads(resources.read_text()), json.loads((args.data / "story.json").read_text()))
    temporary = args.data / ".resources.linked.tmp"
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(resources)
    print(json.dumps({"linkedPortraitPeople": len(value["portraits"])}))


if __name__ == "__main__":
    main()
