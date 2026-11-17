#!/usr/bin/env python3
"""Convert Choubey's Ronaldo portrait art (80x100) into the shipped level
pair: data/levels/level_04_ronaldo.png + .json.

v3 (16 Nov 2026, Choubey's instruction): the game is now 80x100 BRICKS and
the artwork is used EXACTLY as it is — one art pixel becomes one brick, no
downscale, no reinterpretation. The playfield stays 480x600 px (cell 6.0),
so the portrait is twice as detailed as the 40x50 v2.

Two defects Choubey called out in the v2 videos are fixed here, and only
these two — the portrait, the corridor route and every colour are the art's
own:
  * BROKEN CORRIDOR: the art's grey walls have 1-px black gaps and the right
    vertical channel is only ~62% black (the rest is portrait colour), so the
    channel was not clean. The channel is carved empty here (left vertical
    cols 10-11, top horizontal rows 23-24, right vertical cols 66-67, hook
    row 40) and the grey wall columns are filled solid where the art leaves
    a black gap, so the walls are continuous and the ball cannot slip out.
  * LEFT EMPTY CAVITY: cols 2-5 are a 4-column vertical strip of empty black
    (59-80% black) between the red border and the corridor. The ball got in
    there and bounced in empty space, wasting time. It is NOT needed, so the
    black pixels there are filled with solid unbreakable red (the border
    colour) — the cavity is gone, the frame is solid.

Structural cells (the only places the art is touched):
  * the black channel  -> EMPTY   (the ball's path; carved, not painted)
  * the grey walls     -> SOLID grey (listed in unbreakable_cells)
  * the red border ring -> SOLID red (listed in unbreakable_cells, like level_02)
  * the left cavity (cols 2-5, black pixels) -> SOLID red (unbreakable)

Everything else is the art's own colour, breakable, so the portrait is never
cut by the corridor: no cell of the face is turned into channel.

Run from the project root:  python3 tools/make_level_04_ronaldo.py
"""
import json
import os

from PIL import Image

COLS, ROWS = 80, 100
CELL = 6.0
ORIGIN = (30, 64)
DESIGN = "research/ronaldo_portrait_80x100.png"
OUT_PNG = "data/levels/level_04_ronaldo.png"
OUT_JSON = "data/levels/level_04_ronaldo.json"

# --- corridor, measured off the art (80x100) -------------------------------
# left vertical channel: cols 10-11, 71/71 black in rows 25-95.
# top horizontal channel: rows 23-24, 54/54 black in cols 12-65.
# right vertical channel: cols 66-67, rows 24-40 (only ~62% black in the art
#   — the rest is portrait colour, so it is carved empty here).
# hook: row 40, cols 62-70 (turning left, like the 40x50 design).
CHANNEL = set()
for r in range(23, 100):
    CHANNEL.add((10, r))
    CHANNEL.add((11, r))
for c in range(10, 68):
    CHANNEL.add((c, 23))
    CHANNEL.add((c, 24))
for r in range(24, 41):
    CHANNEL.add((66, r))
    CHANNEL.add((67, r))
for c in range(62, 71):
    CHANNEL.add((c, 40))

# Grey wall columns (measured: col 9 is 77/100 grey, col 12 is 76/100 grey).
# They run the corridor's vertical span; the top channel crosses them at
# rows 23-24, where the wall is interrupted by the channel (correct).
WALL_COLS = (9, 12)
WALL_TOP = 23
WALL_BOTTOM = 99

# The left empty cavity: cols 2-5, 49-58/71 black in rows 25-95. Filled red.
CAVITY_COLS = range(2, 6)

BORDER = set()
for c in range(COLS):
    BORDER.add((c, 0))
    BORDER.add((c, ROWS - 1))
for r in range(ROWS):
    BORDER.add((0, r))
    BORDER.add((COLS - 1, r))

RED_OUTER = (198, 20, 34)
GREY_LIGHT = (134, 129, 136)
GREY_DARK = (96, 92, 99)


def is_black(p):
    return max(p) < 46


def is_grey(p):
    r, g, b = p
    return abs(r - g) < 30 and abs(g - b) < 30 and 70 < r < 190


def main():
    im = Image.open(DESIGN).convert("RGB")
    px = im.load()
    assert im.size == (COLS, ROWS), im.size

    grid = [[None] * COLS for _ in range(ROWS)]
    solid = 0
    art_cells = 0
    cavity_filled = 0
    wall_gap_filled = 0
    unbreakable = set(BORDER)
    for r in range(ROWS):
        for c in range(COLS):
            cell = (c, r)
            col = px[c, r]
            if cell in CHANNEL:
                grid[r][c] = (0, 0, 0, 0)
                continue
            if cell in BORDER:
                grid[r][c] = RED_OUTER + (255,)
                solid += 1
                continue
            # Left cavity: black pixels become solid red (unbreakable).
            if c in CAVITY_COLS and is_black(col):
                grid[r][c] = RED_OUTER + (255,)
                unbreakable.add(cell)
                solid += 1
                cavity_filled += 1
                continue
            # Grey walls: the art's grey is unbreakable; a black gap inside a
            # wall column is filled grey so the wall is continuous.
            if c in WALL_COLS and WALL_TOP <= r <= WALL_BOTTOM:
                if is_grey(col):
                    g = GREY_LIGHT if c == 9 else GREY_DARK
                    grid[r][c] = (g[0], g[1], g[2], 255)
                    unbreakable.add(cell)
                    solid += 1
                    continue
                if is_black(col):
                    g = GREY_LIGHT if c == 9 else GREY_DARK
                    grid[r][c] = (g[0], g[1], g[2], 255)
                    unbreakable.add(cell)
                    solid += 1
                    wall_gap_filled += 1
                    continue
            if is_grey(col):
                grid[r][c] = (GREY_DARK[0], GREY_DARK[1], GREY_DARK[2], 255)
                unbreakable.add(cell)
                solid += 1
                continue
            if is_black(col):
                grid[r][c] = (0, 0, 0, 0)
                continue
            grid[r][c] = (col[0], col[1], col[2], 255)
            solid += 1
            art_cells += 1

    out = Image.new("RGBA", (COLS, ROWS), (0, 0, 0, 0))
    op = out.load()
    for r in range(ROWS):
        for c in range(COLS):
            op[c, r] = grid[r][c]
    os.makedirs(os.path.dirname(OUT_PNG), exist_ok=True)
    out.save(OUT_PNG)

    ub = sorted(unbreakable)
    body = {
        "id": "level_04_ronaldo",
        "display_name": "CRISTIANO RONALDO",
        "topic": "Portugal / Cristiano Ronaldo — the corridor level (Choubey's design)",
        "image": "level_04_ronaldo.png",
        "cols": COLS,
        "rows": ROWS,
        "cell": CELL,
        "origin": list(ORIGIN),
        "pattern": (
            "Choubey's 80x100 portrait art used exactly as drawn, one pixel "
            "per brick: the portrait is framed by a rectangular corridor "
            "(red-edged, grey solid walls, black 2-cell channel) whose turns "
            "run up the left edge, right along the top, down the right edge "
            "and into the small top-right hook. The grey walls are "
            "unbreakable so the ball has to be AIMED along them; the channel "
            "is the ball's path and never cuts the face. The empty cavity on "
            "the left is filled solid red so the ball cannot waste time there."
        ),
        "channel": {
            "fork": [10, 23],
            "stem_cols": [10, 11],
            "stem_bottom": 99,
            "arm_width": 2,
            "arms": [[67, 23], [10, 95]],
        },
        "powerup_tips": [[14, 90], [60, 38]],
        "unbreakable_cells": [[c, r] for c, r in ub],
    }
    with open(OUT_JSON, "w") as f:
        json.dump(body, f, indent=1)
        f.write("\n")

    print("solid=%d art=%d cavity_filled=%d wall_gap_filled=%d unbreakable=%d channel=%d" % (
        solid, art_cells, cavity_filled, wall_gap_filled, len(ub), len(CHANNEL)))
    for r in range(0, ROWS, 2):
        line = ""
        for c in range(COLS):
            if grid[r][c][3] == 0:
                line += "."
            elif (c, r) in CHANNEL:
                line += "."
            elif (c, r) in unbreakable and grid[r][c][:3] in (GREY_LIGHT, GREY_DARK):
                line += "#"
            elif (c, r) in unbreakable:
                line += "R"
            else:
                line += "o"
        print("%3d %s" % (r, line))


if __name__ == "__main__":
    main()
