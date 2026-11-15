#!/usr/bin/env python3
"""Generate data/levels/level_01_portrait.png — the Stage A test portrait.

ORIGINAL pixel art, drawn from code (no photo, no logo). 40 x 50 pixels: one
pixel per brick cell, pixel colour = brick colour, transparent = empty cell.
The carved Y channel is NOT baked in here: the level loader carves it from the
level JSON so every level provably has its stem + fork + two arms.

Stage B supplies real portraits; this placeholder only has to read as a face
at brick size (skin oval + hair mass + two eyes + mouth + shirt).
"""
import os
import struct
import zlib

W, H = 40, 50

SKIN = (198, 138, 92, 255)
SKIN_SHADE = (166, 111, 71, 255)
HAIR = (36, 26, 23, 255)
HAIR_HI = (66, 48, 40, 255)
BROW = (30, 21, 18, 255)
EYE_W = (244, 240, 232, 255)
EYE = (27, 22, 19, 255)
MOUTH = (46, 30, 24, 255)
BEARD = (58, 38, 30, 255)
SHIRT = (43, 87, 184, 255)
SHIRT_DARK = (31, 63, 136, 255)
COLLAR = (238, 242, 248, 255)
BLUSH = (208, 116, 92, 255)

grid = [[None] * W for _ in range(H)]


def put(x, y, c):
    if 0 <= x < W and 0 <= y < H and c is not None:
        grid[y][x] = c


def rect(x0, y0, x1, y1, c):
    for y in range(y0, y1 + 1):
        for x in range(x0, x1 + 1):
            put(x, y, c)


def ellipse(cx, cy, rx, ry, c, keep=None):
    for y in range(H):
        for x in range(W):
            if ((x - cx) / rx) ** 2 + ((y - cy) / ry) ** 2 <= 1.0:
                if keep is None or keep(x, y):
                    put(x, y, c)


# --- shoulders / shirt (bottom of the portrait)
ellipse(20, 54, 18, 15, SHIRT, keep=lambda x, y: y >= 37)
ellipse(20, 57, 13, 10, SHIRT_DARK, keep=lambda x, y: y >= 45)
# --- neck
rect(17, 32, 22, 38, SKIN_SHADE)
# --- hair mass behind the face
ellipse(20, 12, 14.5, 12.5, HAIR)
# --- ears
ellipse(9, 22, 2, 3, SKIN_SHADE)
ellipse(30, 22, 2, 3, SKIN_SHADE)
# --- face
ellipse(20, 21, 10.6, 12.4, SKIN)
# --- fringe over the forehead
rect(11, 9, 28, 11, HAIR)
rect(10, 10, 12, 20, HAIR)
rect(27, 10, 29, 20, HAIR)
# --- hair highlight
rect(14, 5, 19, 6, HAIR_HI)
rect(13, 7, 15, 8, HAIR_HI)
# --- eyebrows
rect(12, 17, 17, 18, BROW)
rect(22, 17, 27, 18, BROW)
# --- eyes
rect(13, 19, 17, 22, EYE_W)
rect(22, 19, 26, 22, EYE_W)
rect(15, 20, 16, 21, EYE)
rect(23, 20, 24, 21, EYE)
# --- nose
rect(19, 22, 21, 26, SKIN_SHADE)
put(19, 27, BEARD)
put(21, 27, BEARD)
# --- cheeks
put(12, 24, BLUSH)
put(27, 24, BLUSH)
# --- moustache + mouth
rect(16, 28, 23, 28, BROW)
rect(17, 29, 22, 30, MOUTH)
# --- jaw / beard line
rect(11, 27, 12, 31, BEARD)
rect(27, 27, 28, 31, BEARD)
rect(14, 31, 25, 31, BEARD)
rect(16, 32, 23, 33, BEARD)
# --- collar
rect(15, 37, 24, 38, COLLAR)
put(19, 39, SHIRT)
put(20, 39, SHIRT)
put(18, 40, SHIRT)
put(21, 40, SHIRT)

# --- write PNG (RGBA8, no external deps)
raw = bytearray()
for y in range(H):
    raw.append(0)
    for x in range(W):
        px = grid[y][x]
        raw.extend(bytes(px) if px else b"\x00\x00\x00\x00")


def chunk(tag, data):
    return (struct.pack(">I", len(data)) + tag + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))


png = b"\x89PNG\r\n\x1a\n"
png += chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 6, 0, 0, 0))
png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
png += chunk(b"IEND", b"")

out = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                   "data", "levels", "level_01_portrait.png")
with open(out, "wb") as f:
    f.write(png)
print("wrote %s (%dx%d)" % (out, W, H))
