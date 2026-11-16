#!/usr/bin/env python3
"""Generate data/levels/ref_winding_track.{png,json} — a MEASUREMENT FIXTURE,
not a shipped level (it is deliberately NOT in Game.LEVELS).

Purpose: answer "can a winding corridor work?" with a number instead of an
argument. The fixture is the reference clips' marble-run shape — a vertical
channel that TURNS right, runs along, and TURNS up into a chamber of breakable
bricks — with solid unbreakable walls on both sides of the whole track.

The serve is vertical and untouched (SERVE_ANGLE_DEG), and a ball in a
brick-free corridor only ever bounces axis-aligned, so the ball cannot follow a
turn. Run it with the real-time simulator:

    godot --headless --path . -- --breakout-sim level=ref_winding_track seconds=120

and the report's numbers (bricks broken / longest stall) come from that run.

Usage: python3 tools/gen_winding_track.py [project_root]
"""
from __future__ import annotations

import json
import pathlib
import sys

try:
    from PIL import Image
except ImportError:  # pragma: no cover
    sys.exit("Pillow is required only to REGENERATE this level (pip install pillow)")

COLS, ROWS = 40, 50
CELL = 12.0
ORIGIN = [30, 64]
WALL = (117, 122, 133, 255)
BRICK = (165, 70, 70, 255)
EMPTY = (0, 0, 0, 0)

# --- the winding track, as filled cell rectangles -----------------------
TRACK = [
    # entry column up from the bottom edge
    (5, 6, 30, 49),
    # TURN 1: right along the bottom of the loop
    (5, 20, 30, 31),
    # TURN 2: up the right-hand side of the loop
    (19, 20, 8, 31),
]
# the chamber at the far end (breakable bricks the ball must reach)
CHAMBER = (18, 22, 4, 7)


def main() -> int:
    root = pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else \
        pathlib.Path(__file__).resolve().parent.parent
    out_png = root / "data" / "levels" / "ref_winding_track.png"
    out_json = root / "data" / "levels" / "ref_winding_track.json"

    track: set[tuple[int, int]] = set()
    for (x0, x1, y0, y1) in TRACK:
        for y in range(y0, y1 + 1):
            for x in range(x0, x1 + 1):
                track.add((x, y))
    chamber: set[tuple[int, int]] = set()
    for y in range(CHAMBER[2], CHAMBER[3] + 1):
        for x in range(CHAMBER[0], CHAMBER[1] + 1):
            chamber.add((x, y))

    # solid walls: everything touching the track or the chamber (1 cell thick)
    walls: set[tuple[int, int]] = set()
    for (x, y) in track | chamber:
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                c = (x + dx, y + dy)
                if c in track or c in chamber:
                    continue
                if 0 <= c[0] < COLS and 0 <= c[1] < ROWS:
                    walls.add(c)
    # the top frame so the chamber is closed
    for x in range(COLS):
        walls.add((x, 0))
    # the entry column must stay open all the way to the bottom edge
    for x in range(5, 7):
        walls.discard((x, ROWS - 1))

    img = Image.new("RGBA", (COLS, ROWS), EMPTY)
    for (x, y) in walls:
        img.putpixel((x, y), WALL)
    for (x, y) in chamber:
        img.putpixel((x, y), BRICK)
    img.save(out_png)

    data = {
        "id": "ref_winding_track",
        "display_name": "WINDING TRACK (measurement fixture)",
        "topic": "fixture: does a turning corridor work?",
        "image": out_png.name,
        "cols": COLS, "rows": ROWS, "cell": CELL, "origin": ORIGIN,
        "channel": {
            "fork": [5, 40],
            "stem_cols": [5, 6],
            "stem_bottom": 44,
            "arm_width": 1,
            "arms": [[5, 33], [6, 33]],
        },
        "powerup_tips": [[19, 6], [20, 6]],
        "unbreakable_cells": sorted([list(c) for c in walls], key=lambda c: (c[1], c[0])),
    }
    out_json.write_text(json.dumps(data, indent=1) + "\n")
    print(f"wrote {out_png.name} and {out_json.name}")
    print(f"  track cells {len(track)}  chamber bricks {len(chamber)}  walls {len(walls)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
