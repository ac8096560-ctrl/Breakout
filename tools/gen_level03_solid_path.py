#!/usr/bin/env python3
"""Generate data/levels/level_03_solid_path.{png,json} (Stage C, Brief 20 item 4).

PATTERN — "solid guide channel on one side -> funnels the ball to the portrait
-> portrait revealed in a controlled sequence":

  * A black (empty) CHANNEL runs up from the bottom edge to the portrait's
    chin, so the serve's first trip climbs it and bursts into the face.
  * ZERO unbreakable cells. A solid guide wall was built, measured and
    REJECTED: an unbreakable brick has a horizontal bottom face, the auto-play
    paddle returns the ball nearly vertically, and the strip of black play
    floor under that face becomes a permanent ping-pong. Muse's recorded take
    stalled under the left margin (old build); after the walls were extended to
    row 49 a --breakout-sim run at time_scale 1 still stalled on seed 7 under
    the col-7 wall (1 brick in 150 s, ball_x frozen in 102..129). With no
    unbreakable cells every contact is progress, so the field cannot stall.
  * Portrait pixels are level_01's, byte for byte — the channel is carved out
    of empty art cells, so no portrait pixel changes.

Why the channel is short and vertical: the serve is vertical (SERVE_ANGLE_DEG
untouched) and a ball in a brick-free corridor only ever bounces axis-aligned,
so a corridor that TURNS cannot deliver a vertical ball — that is measured by
the ref_winding_track fixture (tools/gen_winding_track.py), not asserted.

Usage: python3 tools/gen_level03_solid_path.py [project_root]
"""
from __future__ import annotations

import json
import pathlib
import sys

try:
    from PIL import Image
except ImportError:  # pragma: no cover - only needed to REGENERATE the level
    sys.exit("Pillow is required only to REGENERATE this level (pip install pillow)")

COLS, ROWS = 40, 50
CELL = 12.0
ORIGIN = [30, 64]
# The still-standing grey of the reference walls (also Themes "guide").
WALL = (117, 122, 133, 255)

# The channel mouth (the doorway the served ball enters through).
GAP = (5, 6)

CHANNEL = {
    "fork": [5, 16],
    "stem_cols": [5, 6],
    "stem_bottom": 44,
    "arm_width": 1,
    # Both arms stay inside the carved channel: the loader requires a fork and
    # two arms, and a carve may only touch cells that are already empty.
    "arms": [[5, 40], [6, 40]],
}
TIPS = [[6, 14], [6, 45]]


def main() -> int:
    root = pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else \
        pathlib.Path(__file__).resolve().parent.parent
    src = root / "data" / "levels" / "level_01_portrait.png"
    out_png = root / "data" / "levels" / "level_03_solid_path.png"
    out_json = root / "data" / "levels" / "level_03_solid_path.json"

    img = Image.open(src).convert("RGBA")
    if img.size != (COLS, ROWS):
        raise SystemExit(f"source portrait is {img.size}, expected {(COLS, ROWS)}")

    px = [[img.getpixel((x, y)) for x in range(COLS)] for y in range(ROWS)]
    portrait = {(x, y) for y in range(ROWS) for x in range(COLS) if px[y][x][3] >= 128}

    # NO UNBREAKABLE CELLS AT ALL. This is a measurement, not a style choice:
    # an unbreakable brick has a horizontal bottom face, the auto-play paddle
    # returns the ball nearly vertically, and any column of play-floor under
    # that face becomes a permanent ping-pong once the ball is below it. With
    # `--breakout-sim` (real time, time_scale 1) the walls-down-to-row-49 build
    # of this level won on seeds 1 and 3 but stalled on seed 7 for the whole
    # take (45 s and 150 s runs: 1 brick broken, ball_x frozen in 102..129,
    # i.e. under the col-7 wall). The left-block build stalled the same way
    # under the left margin, which is the failure Muse recorded. Since a ball
    # that can only ever touch BREAKABLE cells always makes progress, the level
    # ships with zero unbreakable cells and the guide is the carved channel.
    walls: set[tuple[int, int]] = set()

    # ---- invariants -------------------------------------------------------
    painted = walls - portrait
    if walls:
        raise SystemExit("this build may not ship unbreakable cells")

    # 1) the carved channel is empty and the entry column is open all the way
    #    down, so the served ball can climb the channel on its first trip.
    carve = set()
    for y in range(CHANNEL["fork"][1], CHANNEL["stem_bottom"] + 1):
        for x in range(CHANNEL["stem_cols"][0], CHANNEL["stem_cols"][1] + 1):
            carve.add((x, y))
    bad = sorted(carve & portrait)
    if bad:
        raise SystemExit(f"the channel carve would eat portrait bricks: {bad[:8]}")
    for y in range(ROWS - 1, CHANNEL["stem_bottom"] - 1, -1):
        for x in range(GAP[0], GAP[1] + 1):
            if (x, y) in walls:
                raise SystemExit(f"the entry column is walled at {(x, y)}")
    mouth = [(x, CHANNEL["fork"][1] - 1) for x in range(GAP[0], GAP[1] + 1)]
    if not any(c in portrait for c in mouth):
        raise SystemExit("no portrait brick above the channel mouth")
    # 2) every cell the ball can touch is breakable, so no contact can stall.
    if len(walls) != 0 or len(portrait) < 900:
        raise SystemExit(f"bad field: {len(walls)} walls, {len(portrait)} bricks")

    # ---- paint the PNG: exactly level_01's portrait pixels ----------------
    out = Image.new("RGBA", (COLS, ROWS), (0, 0, 0, 0))
    for y in range(ROWS):
        for x in range(COLS):
            out.putpixel((x, y), px[y][x])

    out.save(out_png)

    data = {
        "id": "level_03_solid_path",
        "display_name": "SOLID PATH",
        "topic": "guide-channel levels (solid unbreakable walls steer the ball)",
        "image": out_png.name,
        "cols": COLS,
        "rows": ROWS,
        "cell": CELL,
        "origin": ORIGIN,
        "pattern": (
            "solid guide channel on one side -> funnels the ball to the portrait "
            "-> portrait revealed in a controlled sequence. The channel is a "
            "narrow carved corridor (cols 5..6, rows 16..44) that runs from the "
            "bottom edge straight up to the portrait's chin and ends directly "
            "under it, and no portrait pixel is changed. The level has ZERO "
            "unbreakable_cells: an unbreakable brick's horizontal bottom face "
            "plus the near-vertical auto-play return make any column of black "
            "play floor under it a permanent ping-pong channel (measured with "
            "--breakout-sim at time_scale 1 - see the report). Every cell the "
            "ball can touch is breakable, so every contact is progress."
        ),
        "channel": CHANNEL,
        "powerup_tips": TIPS,
        "unbreakable_cells": sorted([list(c) for c in walls], key=lambda c: (c[1], c[0])),
    }
    out_json.write_text(json.dumps(data, indent=1) + "\n")

    breakable = len(portrait) - len([c for c in walls if c in portrait])
    print(f"wrote {out_png.name} and {out_json.name}")
    print(f"  portrait bricks : {len(portrait)}")
    print(f"  wall cells      : {len(walls)} (painted grey: {len(painted)}, "
          f"frame-on-art: {len(walls & portrait)})")
    print(f"  unbreakable     : {len(walls)}   breakable: {breakable}")
    print(f"  entry columns   : {list(GAP)} (bottom row left open on purpose)")
    print(f"  channel cells   : {len(carve)}  mouth above: {mouth}")
    print(f"  unbreakable     : 0 (every cell the ball can touch is breakable)")
    print(f"  win threshold   : {int(len(portrait) * 0.985)} bricks broken")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
