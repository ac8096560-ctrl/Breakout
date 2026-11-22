class_name BreakoutLevel extends RefCounted
## LEVEL FORMAT — one small pixel-art PNG + one JSON sidecar.
##
## PNG  : W x H pixels, ONE PIXEL PER BRICK CELL. The pixel colour IS the brick
##        colour; a fully transparent pixel is an empty cell (no brick).
## JSON : id, display name, topic, image file name, grid geometry (columns,
##        rows, cell pitch, screen origin), the CARVED CHANNEL (stem + fork +
##        two arms — every level must give the ball a path and a choice point),
##        the power-up tip cells, the optional win_leftover fraction (the win
##        rule: see win_leftover_frac()), and the optional UNBREAKABLE CELLS — a
##        solid border ring listed explicitly as [col,row] pairs (never a
##        magic colour). Unbreakable cells are walls, not bricks: the ball
##        bounces off them, they are never broken, and they do not count
##        toward the win. A listed cell the channel carved out (the stem gap)
##        is an entry, not a wall, and is dropped at load.
##
## Stage B's level editor is meant to write EXACTLY these two files: a painted
## grid becomes the PNG, the geometry/channel block becomes the JSON. Nothing
## in the runtime reads level data from anywhere else, so an editor-authored
## level is an ordinary level.
##
## Nothing here touches the scene tree: load_level() returns plain data.

const DEFAULT_COLS := 40
const DEFAULT_ROWS := 50
const DEFAULT_CELL := 12.0
const DEFAULT_ORIGIN := Vector2(30, 74)

## --- BRIEF 29: the optional per-level WIN RULE -------------------------
## `win_leftover` is the fraction of the level's BREAKABLE bricks that may
## still stand when the win fires, so 0.0 means the picture must be completely
## clear. It is validated HERE, once, at load, so a bad value in a level file
## can never crash the game or quietly change the rule: a numeric value is
## clamped to [WIN_LEFTOVER_MIN, WIN_LEFTOVER_MAX], and a non-numeric or
## non-finite one falls back to WIN_LEFTOVER_UNSET. A level without the field
## reports WIN_LEFTOVER_UNSET, which leaves the engine's own default (1.5%, see
## WIN_LEFTOVER in breakout_game.gd) exactly as it was.
const WIN_LEFTOVER_MIN := 0.0
const WIN_LEFTOVER_MAX := 0.10
const WIN_LEFTOVER_UNSET := -1.0

## --- AUTO-SOLID GREY (no more manual marking) ---------------------------
## Level art draws its walls and frame in GREY. Choubey paints levels as pixel
## art, so a grey brick is SOLID without being listed in the JSON: neutral
## colour (the three channels nearly equal) at mid brightness.
##
## Colour alone is not enough, and the shipped art proves it: level_04_ronaldo
## has 302 neutral, mid-bright bricks that are the PORTRAIT's own skin and hair
## shading ((151,140,138), (100,83,76) ...), which must stay breakable. What
## separates a FRAME from picture content is POSITION, not colour: a frame is the
## outermost ring of the picture, shading and backgrounds are inside it. So the
## rule is "neutral + mid-bright + inside the picture's frame band" — see
## grey_frame_cells() for why the band is measured per cell instead of by grey
## region connectivity, and why it is only GREY_FRAME_BAND cells deep.
##
## The explicit `unbreakable_cells` list keeps working; the final solid set is
## the UNION of that list and this rule.
const GREY_CHROMA := 25.0          # max(R,G,B) - min(R,G,B) in 0..255 steps
const GREY_MIN_BRIGHTNESS := 60.0  # (R+G+B)/3, 0..255: below this is black art
const GREY_MAX_BRIGHTNESS := 200.0 # above this is a highlight, not a wall
## How deep the frame band is, in cells, measured from the picture's outer edge.
## 2 covers a 1-cell frame and one cell of resize ringing around it.
const GREY_FRAME_BAND := 2

## --- BRIEF 30: THE INNER GREY FRAME -------------------------------------
## Some art draws its frame as a grey RECTANGLE INSIDE an opaque border: the
## Messi portrait's grey ring sits 3..21 cells in from the picture's edge, so
## the 2-cell band above never sees it (a fresh import walled in 4 of its 294
## frame cells, 1.4%), and such a level still had to be marked by hand.
##
## What separates a frame from portrait shading is SHAPE, not colour:
##   * a frame side is a LONG straight grey line — at least half the picture's
##     width or height — because it spans the picture;
##   * it is THIN: a wall is 1..3 cells across, while a grey background or a
##     shading block is many cells thick in the perpendicular direction;
##   * it is FRAGMENTED, not continuous: a resize leaves single-cell gaps, so
##     a side may skip up to GREY_RING_MAX_GAP non-grey cells;
##   * it TURNS: a ring is a rectangle, so a side must meet a perpendicular
##     side at a corner. A lone long grey line is a shadow, not a frame.
## That is why level_04_ronaldo's neutral shading (302 grey cells, some in
## 15..20-cell slivers inside the portrait) stays breakable, and why
## level_02_jensen's 670-cell grey BACKGROUND (one thick block) is not a ring.
##
## The last guard is not colour at all: the ring is made solid only when it
## does not cut a single breakable brick off from the level's channel — the
## same stranded_breakable() rule a level must never break. A ring that walls
## the portrait in is not a frame, and is dropped.
const GREY_RING_LINE_FRAC := 0.5    # a side spans this share of the picture
const GREY_RING_MAX_GAP := 2        # cells a fragmented side may skip
const GREY_RING_MAX_THICKNESS := 3  # perpendicular grey run: wall, not block


## Load a level. Returns
##   {ok, err, id, name, topic, cols, rows, cell, origin, image,
##    grid: Array[Color] (index = row * cols + col, a == 0 -> empty),
##    powerup_cells: Array[Vector2i], channel_cells: Array[Vector2i],
##    stem_cols: Array[int] (the two stem columns, for aiming the serve),
##    unbreakable_cells: Array[Vector2i] (validated, still bricks),
##    bricks: int (all solid cells), breakable: int, unbreakable: int}
static func load_level(json_path: String) -> Dictionary:
	if not FileAccess.file_exists(json_path):
		return {"ok": false, "err": "level not found: %s" % json_path}
	var f := FileAccess.open(json_path, FileAccess.READ)
	if f == null:
		return {"ok": false, "err": "cannot read %s" % json_path}
	var text := f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(text)
	if not parsed is Dictionary:
		return {"ok": false, "err": "level json is not an object: %s" % json_path}
	var d: Dictionary = parsed

	var cols := int(d.get("cols", DEFAULT_COLS))
	var rows := int(d.get("rows", DEFAULT_ROWS))
	if cols < 4 or rows < 4 or cols > 128 or rows > 128:
		return {"ok": false, "err": "absurd grid %dx%d" % [cols, rows]}

	var base := json_path.get_base_dir()
	var image_name := str(d.get("image", ""))
	if image_name == "":
		return {"ok": false, "err": "level json has no image"}
	var img_path := base.path_join(image_name)
	if not FileAccess.file_exists(img_path):
		return {"ok": false, "err": "portrait png not found: %s" % img_path}

	# Read the PNG bytes through FileAccess (NOT Image.load_from_file +
	# globalize_path): on Android every res:// file is packed INSIDE the APK, so
	# globalize_path returns a path that is not a real file and load_from_file
	# returns null — every shipped level failed with "cannot decode png" in the
	# APK. FileAccess reads res:// from inside the APK and user:// straight off
	# disk, so this is the one path for both, and it still needs no import step:
	# a level the editor just wrote loads in the same run it was created.
	var img := load_png_image(img_path)
	if img == null:
		return {"ok": false, "err": "cannot decode png: %s" % img_path}
	# A PNG that is not exactly cols x rows is stretched onto the level's grid
	# instead of being rejected: hand-made or older art still loads and plays.
	# The editor's import writes an exact-size PNG, so this is the safety net.
	if img.get_width() != cols or img.get_height() != rows:
		img.resize(cols, rows, Image.INTERPOLATE_NEAREST)
	img.convert(Image.FORMAT_RGBA8)

	var grid: Array = []
	grid.resize(cols * rows)
	for r in rows:
		for c in cols:
			var px := img.get_pixel(c, r)
			# alpha below 0.5 = empty cell. Fully opaque pixel = brick.
			grid[r * cols + c] = px if px.a >= 0.5 else Color(0, 0, 0, 0)

	# --- the channel: stem + fork + two arms, carved AFTER the art so no level
	# can ship without a path.
	#
	# BRIEF 24 — an imported level may deliberately carry NO channel: its JSON
	# holds an EMPTY channel block, and then nothing is carved (the art is the
	# level, exactly as drawn). Only an ABSENT channel key falls back to the
	# default Y, which is the pre-existing behaviour for a bare level.
	var channel: Dictionary = d.get("channel", {})
	var channel_cells: Array[Vector2i] = []
	if not (d.has("channel") and channel.is_empty()):
		channel_cells = carve_channel(grid, cols, rows, channel)

	# The stem columns, for the serve: the ball is aimed at the stem gap
	# (the solid border leaves no other entry), so the game reads them from
	# the level instead of assuming a centre channel. Same fallback as
	# carve_channel (fork.x, fork.x + 1) when a level carries no spec.
	var stem_cols := [cols / 2, cols / 2 + 1]
	if channel.has("stem_cols") and channel["stem_cols"] is Array and (channel["stem_cols"] as Array).size() == 2:
		stem_cols = [int(channel["stem_cols"][0]), int(channel["stem_cols"][1])]

	# The power-up tips must be BRICKS at the end of each arm (the reference
	# breaks a coloured cluster there first). The art can change under a level,
	# so a tip that the carve turned into empty space snaps outward to the first
	# brick cell of its arm — the design rule cannot silently disappear.
	var fork := Vector2i(cols / 2, int(round(rows * 0.68)))
	if channel.has("fork") and channel["fork"] is Array and (channel["fork"] as Array).size() == 2:
		fork = Vector2i(int(channel["fork"][0]), int(channel["fork"][1]))
	var tips: Array[Vector2i] = []
	for t in d.get("powerup_tips", []):
		if not (t is Array) or (t as Array).size() != 2:
			continue
		var cellp := Vector2i(int(t[0]), int(t[1]))
		var dirx := signi(cellp.x - fork.x)
		var diry := signi(cellp.y - fork.y)
		for _step in 5:
			if _is_brick(grid, cols, rows, cellp):
				break
			cellp += Vector2i(dirx, diry)
		if _is_brick(grid, cols, rows, cellp) and not tips.has(cellp):
			tips.append(cellp)

	var bricks := 0
	for cell_col in grid:
		if (cell_col as Color).a >= 0.5:
			bricks += 1

	# --- unbreakable cells: walls, not bricks. Two sources, ONE final set:
	#   * the explicit `unbreakable_cells` list (still honoured exactly as
	#     before), and
	#   * the AUTO-SOLID GREY rule — every grey frame/wall brick (see the
	#     constants above for why the colour test is paired with the
	#     "reaches the outer edge" test).
	# A listed cell the channel carved out (the stem gap) is an entry, not a
	# wall, so it is still dropped here.
	var listed: Array[Vector2i] = []
	for u in d.get("unbreakable_cells", []):
		if not (u is Array) or (u as Array).size() != 2:
			continue
		var cellp := Vector2i(int(u[0]), int(u[1]))
		if _is_brick(grid, cols, rows, cellp) and not listed.has(cellp):
			listed.append(cellp)
	var unbreakable := solid_cells(grid, cols, rows, listed, channel_cells)
	# "How many came from the grey rule": every solid cell the JSON did not
	# list. The solid set is the UNION of the list and the two grey rules, so
	# the difference is exactly the rule's doing (no duplicates).
	var from_grey := unbreakable.size() - listed.size()
	var stranded := stranded_breakable(grid, cols, rows, unbreakable, channel_cells)

	var origin := DEFAULT_ORIGIN
	if d.has("origin") and d["origin"] is Array and (d["origin"] as Array).size() == 2:
		origin = Vector2(float(d["origin"][0]), float(d["origin"][1]))

	return {
		"ok": true, "err": "",
		"id": str(d.get("id", json_path.get_file().get_basename())),
		"name": str(d.get("display_name", "PORTRAIT")),
		"topic": str(d.get("topic", "")),
		"image": img_path,
		"cols": cols, "rows": rows,
		"cell": float(d.get("cell", DEFAULT_CELL)),
		"origin": origin,
		"grid": grid,
		"powerup_cells": tips,
		"channel_cells": channel_cells,
		"stem_cols": stem_cols,
		"win_leftover": win_leftover_frac(d),
		"bricks": bricks,
		"unbreakable_cells": unbreakable,
		"unbreakable": unbreakable.size(),
		"unbreakable_from_list": listed.size(),
		"unbreakable_from_grey": from_grey,
		"stranded_breakable": stranded,
		"breakable": bricks - unbreakable.size(),
	}


## The level's `win_leftover` fraction (a share of its breakable bricks),
## clamped to [WIN_LEFTOVER_MIN, WIN_LEFTOVER_MAX], or WIN_LEFTOVER_UNSET when
## the level asks for the engine default. Never returns NaN/inf and never
## fails: the win rule must exist for every level, even a hand-edited one.
static func win_leftover_frac(d: Dictionary) -> float:
	if not d.has("win_leftover"):
		return WIN_LEFTOVER_UNSET
	var raw: Variant = d["win_leftover"]
	var v := 0.0
	if raw is float or raw is int:
		v = float(raw)
	elif raw is String and (raw as String).is_valid_float():
		v = float(raw)
	else:
		return WIN_LEFTOVER_UNSET
	if not is_finite(v):
		return WIN_LEFTOVER_UNSET
	return clampf(v, WIN_LEFTOVER_MIN, WIN_LEFTOVER_MAX)


## Decode a PNG from ANY readable path — res:// inside an exported APK, an
## absolute path, or user:// where the editor writes. Returns null when the
## file cannot be read or cannot be decoded. PNG is the level format; JPEG is
## accepted because the editor's IMPORT can take any portrait art (the editor
## re-saves it as a PNG).
##
## Two readers, because the two locations are different things:
## - res:// (shipped levels): the raw .png is NOT exported into the APK — the
##   exporter packs only the imported texture (.ctex) plus the .import remap.
##   So a shipped level MUST be read through ResourceLoader, which follows the
##   remap to the .ctex that IS in the APK. The level PNGs are imported with
##   vram_texture=false, so get_image() returns the exact pixel values (one
##   pixel = one brick, colours intact). FileAccess CANNOT read a res:// .png
##   in a packaged build — the file is not there.
## - user:// / absolute paths (editor-saved levels, user-picked import files):
##   real files on disk, so FileAccess + a buffer decode is the right reader.
## No caller may use Image.load_from_file(ProjectSettings.globalize_path(...)):
## globalize_path returns a path that is not a real file inside an APK.
static func load_png_image(path: String) -> Image:
	if path.begins_with("res://"):
		var tex := load(path) as Texture2D
		if tex == null:
			return null
		var img := tex.get_image()
		if img == null:
			return null
		return img
	if not FileAccess.file_exists(path):
		return null
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		return null
	var img := Image.new()
	var lower := path.to_lower()
	var err: int
	if lower.ends_with(".jpg") or lower.ends_with(".jpeg"):
		err = img.load_jpg_from_buffer(bytes)
	else:
		err = img.load_png_from_buffer(bytes)
	if err != OK:
		# A jpg saved with a .png name (or the reverse): try the other decoder
		# once instead of refusing art the user clearly picked.
		err = img.load_jpg_from_buffer(bytes) if lower.ends_with(".png") else img.load_png_from_buffer(bytes)
		if err != OK:
			return null
	return img


## Carve the Y channel into `grid` in place and return the carved cells.
## spec: {"fork": [col,row], "stem_cols": [c0,c1], "stem_bottom": row,
##        "arms": [[col,row],[col,row]]}
## A missing spec falls back to a sane centre channel so a bare level still
## has its two paths (the design rule: every level has a fork).
static func carve_channel(grid: Array, cols: int, rows: int, spec: Dictionary) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var fork := Vector2i(cols / 2, int(round(rows * 0.68)))
	if spec.has("fork") and spec["fork"] is Array and (spec["fork"] as Array).size() == 2:
		fork = Vector2i(int(spec["fork"][0]), int(spec["fork"][1]))
	fork.x = clampi(fork.x, 1, cols - 2)
	fork.y = clampi(fork.y, 1, rows - 1)

	var stem_cols := [fork.x, fork.x + 1]
	if spec.has("stem_cols") and spec["stem_cols"] is Array and (spec["stem_cols"] as Array).size() == 2:
		stem_cols = [int(spec["stem_cols"][0]), int(spec["stem_cols"][1])]
	var stem_bottom := rows - 1
	if spec.has("stem_bottom"):
		stem_bottom = clampi(int(spec["stem_bottom"]), fork.y, rows - 1)

	# stem: from the fork straight down to the bottom of the grid
	for r in range(fork.y, stem_bottom + 1):
		for c in range(int(stem_cols[0]), int(stem_cols[1]) + 1):
			_clear(grid, cols, rows, Vector2i(c, r), out)

	# arms: two diagonals from the fork, up-left and up-right. `arm_width` is a
	# square brush (in CELLS): a 1-cell diagonal is a staircase an axis-aligned
	# bounce cannot follow, so the playable channel is 3 cells wide and an
	# actual ball can travel it to the tip cluster.
	var arm_w := maxi(1, int(spec.get("arm_width", 1)))
	var arms: Array = spec.get("arms", [])
	if arms.size() != 2:
		arms = [[maxi(1, fork.x - 6), maxi(0, fork.y - 10)],
			[mini(cols - 2, fork.x + 6), maxi(0, fork.y - 10)]]
	for a in arms:
		if not (a is Array) or (a as Array).size() != 2:
			continue
		var tip := Vector2i(int(a[0]), int(a[1]))
		_carve_line(grid, cols, rows, fork, tip, out, arm_w)
	return out


## Is this brick colour a WALL grey? Neutral (channels nearly equal) and mid
## bright. Black (empty / channel / dark art) is excluded by the brightness
## floor; a coloured portrait pixel is excluded by the chroma ceiling.
static func is_grey(col: Color) -> bool:
	var hi := maxf(col.r, maxf(col.g, col.b)) * 255.0
	var lo := minf(col.r, minf(col.g, col.b)) * 255.0
	if hi - lo >= GREY_CHROMA:
		return false
	var bright := (col.r + col.g + col.b) / 3.0 * 255.0
	return bright >= GREY_MIN_BRIGHTNESS and bright <= GREY_MAX_BRIGHTNESS


static func _is_grey_brick(grid: Array, cols: int, rows: int, cell: Vector2i) -> bool:
	return _is_brick(grid, cols, rows, cell) and is_grey(grid[cell.y * cols + cell.x])


## Every grey brick in the picture's FRAME BAND: within GREY_FRAME_BAND cells of
## the picture's outer edge (the bounding box of its bricks, so an imported
## portrait with a transparent margin is framed from ITS edge, not the grid's).
##
## Two measured facts shape this, and each one broke a simpler rule:
##
## 1. A FRAME IS OFTEN FRAGMENTED. Frame art redrawn at another size does not stay
##    one connected grey region: a resize leaves it in single-cell pieces (a
##    Messi-style 80x100 frame arrived as 63 separate regions). Asking a grey
##    REGION to connect to the edge therefore found only 85 of that frame's
##    ~292 cells — the rest stayed breakable, so the frame had to be marked by
##    hand, which is exactly what this rule exists to avoid. Distance from the
##    edge does not care about connectivity, so a fragmented frame is covered
##    piece by piece.
##
## 2. NOT EVERY EDGE-REACHING GREY IS A FRAME. level_02_jensen's photo has a grey
##    BACKGROUND: 670 grey bricks in ONE region that does reach the picture's
##    edge. It is picture content, not a wall. Making it solid walled the
##    portrait in and left 44 bricks unreachable — the level could no longer be
##    won. That background starts one cell inside the picture's own border, while
##    a frame IS the border, so a band a couple of cells deep takes the frame and
##    leaves the background (and every photo's interior shading) breakable.
static func grey_frame_cells(grid: Array, cols: int, rows: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var b := _brick_bounds(grid, cols, rows)
	if b.is_empty():
		return out
	var min_c: int = b[0]
	var max_c: int = b[1]
	var min_r: int = b[2]
	var max_r: int = b[3]
	for r in range(min_r, max_r + 1):
		for c in range(min_c, max_c + 1):
			var cell := Vector2i(c, r)
			if not _is_grey_brick(grid, cols, rows, cell):
				continue
			var depth := mini(mini(c - min_c, max_c - c), mini(r - min_r, max_r - r))
			if depth < GREY_FRAME_BAND:
				out.append(cell)
	return out


## The brick bounding box of the picture: [min_col, max_col, min_row, max_row],
## or [] when the grid holds no brick at all.
static func _brick_bounds(grid: Array, cols: int, rows: int) -> Array:
	var min_c := cols
	var max_c := -1
	var min_r := rows
	var max_r := -1
	for r in rows:
		for c in cols:
			if _is_brick(grid, cols, rows, Vector2i(c, r)):
				min_c = mini(min_c, c)
				max_c = maxi(max_c, c)
				min_r = mini(min_r, r)
				max_r = maxi(max_r, r)
	if max_c < 0:
		return []
	return [min_c, max_c, min_r, max_r]


## Every grey cell of the INNER GREY RING (BRIEF 30): the long, thin, fragmented
## straight grey sides that turn corners into a rectangle. See the constants at
## the top of the file for why each test exists; nothing here looks at the
## picture's edge, so a frame 3..21 cells inside an opaque border is found.
static func grey_ring_cells(grid: Array, cols: int, rows: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var hs := _grey_ring_spans(grid, cols, rows, true)
	var vs := _grey_ring_spans(grid, cols, rows, false)
	if hs.is_empty() or vs.is_empty():
		return out
	# A ring is a rectangle: keep only sides that meet a perpendicular side at
	# a corner (a lone long grey line is a shadow or a wall, not a frame).
	var keep_h := {}
	var keep_v := {}
	for i in hs.size():
		var h: Array = hs[i]
		for j in vs.size():
			var side: Array = vs[j]
			if int(side[0]) >= int(h[1]) - GREY_RING_MAX_GAP \
					and int(side[0]) <= int(h[2]) + GREY_RING_MAX_GAP \
					and int(h[0]) >= int(side[1]) - GREY_RING_MAX_GAP \
					and int(h[0]) <= int(side[2]) + GREY_RING_MAX_GAP:
				keep_h[i] = true
				keep_v[j] = true
	for i in hs.size():
		if not keep_h.has(i):
			continue
		var h: Array = hs[i]
		for pos in h[3]:
			var cell := Vector2i(int(pos), int(h[0]))
			if not out.has(cell):
				out.append(cell)
	for j in vs.size():
		if not keep_v.has(j):
			continue
		var side: Array = vs[j]
		for pos in side[3]:
			var cell := Vector2i(int(side[0]), int(pos))
			if not out.has(cell):
				out.append(cell)
	return out


## The long thin straight grey sides of ONE orientation, as
## [line, first, last, cells] — line is a row for horizontal sides and a column
## for vertical ones, first/last bound the span (gaps included), and cells are
## the grey positions inside it. A side may skip up to GREY_RING_MAX_GAP
## non-grey cells; the skipped cells are not part of the side.
static func _grey_ring_spans(grid: Array, cols: int, rows: int, horizontal: bool) -> Array:
	var out: Array = []
	var b := _brick_bounds(grid, cols, rows)
	if b.is_empty():
		return out
	var min_c: int = b[0]
	var max_c: int = b[1]
	var min_r: int = b[2]
	var max_r: int = b[3]
	var line_first := min_r if horizontal else min_c
	var line_last := max_r if horizontal else max_c
	var pos_first := min_c if horizontal else min_r
	var pos_last := max_c if horizontal else max_r
	var min_span := maxi(1, int(ceil(GREY_RING_LINE_FRAC * float(pos_last - pos_first + 1))))
	for line in range(line_first, line_last + 1):
		var pos := pos_first
		while pos <= pos_last:
			if not _is_grey_brick(grid, cols, rows, _ring_cell(line, pos, horizontal)):
				pos += 1
				continue
			var start := pos
			var last_grey := pos
			var gaps := 0
			var cells: Array[int] = [pos]
			pos += 1
			while pos <= pos_last:
				if _is_grey_brick(grid, cols, rows, _ring_cell(line, pos, horizontal)):
					gaps = 0
					last_grey = pos
					cells.append(pos)
					pos += 1
				elif gaps < GREY_RING_MAX_GAP:
					gaps += 1
					pos += 1
				else:
					break
			if last_grey - start + 1 >= min_span and _grey_ring_side_is_thin(
					grid, cols, rows, line, cells, horizontal):
				out.append([line, start, last_grey, cells])
			pos = maxi(pos, last_grey + 1)
	return out


## A side is a WALL, not a block: at most half of its cells are thicker than
## GREY_RING_MAX_THICKNESS across. A frame's sides are 1..3 cells wide even
## where a bar's corner is crossed by another line; a grey background fails
## everywhere.
static func _grey_ring_side_is_thin(grid: Array, cols: int, rows: int, line: int,
		cells: Array[int], horizontal: bool) -> bool:
	var thick := 0
	for pos in cells:
		if _grey_ring_run(grid, cols, rows, line, pos, horizontal) > GREY_RING_MAX_THICKNESS:
			thick += 1
	return thick * 2 <= cells.size()


## How many grey cells thick the picture is ACROSS one side cell, capped at
## GREY_RING_MAX_THICKNESS + 1 (the cap is all the thin test needs).
static func _grey_ring_run(grid: Array, cols: int, rows: int, line: int, pos: int,
		horizontal: bool) -> int:
	var n := 1
	for step in [-1, 1]:
		var across: int = line + step
		while n <= GREY_RING_MAX_THICKNESS:
			var cell := Vector2i(pos, across) if horizontal else Vector2i(across, pos)
			if not _is_grey_brick(grid, cols, rows, cell):
				break
			n += 1
			across += step
	return n


static func _ring_cell(line: int, pos: int, horizontal: bool) -> Vector2i:
	return Vector2i(pos, line) if horizontal else Vector2i(line, pos)


## THE FINAL SOLID SET: the level's explicit list UNION the auto-solid greys.
## `from` are the cells the ball travels from (the carved channel; empty for an
## import taken exactly as drawn). The BRIEF 30 ring is applied only when it
## strands no breakable brick — a ring that walls the portrait in is not a frame.
static func solid_cells(grid: Array, cols: int, rows: int, listed: Array,
		from: Array = []) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for u in listed:
		if not (u is Vector2i):
			continue
		var cell: Vector2i = u
		if _is_brick(grid, cols, rows, cell) and not out.has(cell):
			out.append(cell)
	for g in grey_frame_cells(grid, cols, rows):
		if not out.has(g):
			out.append(g)
	var ring := grey_ring_cells(grid, cols, rows)
	if not ring.is_empty():
		var trial: Array[Vector2i] = out.duplicate()
		for g in ring:
			if not trial.has(g):
				trial.append(g)
		var before := 0
		var after := 0
		if not from.is_empty():
			before = stranded_breakable(grid, cols, rows, out, from)
			after = stranded_breakable(grid, cols, rows, trial, from)
		if after <= before:
			out = trial
	return out


## THE DESIGN RULE A WALL MUST NEVER BREAK: a solid cell is a wall the ball can
## never break, so a breakable brick that no path of empty-or-breakable cells
## reaches from the ball's own channel can never be broken — and a level with
## one can never be cleared. Returns how many such bricks a solid set creates
## (0 for every shipped level; the loader reports it and the tests assert it).
## This is the check that would have caught the grey-background regression by
## itself instead of in a 120-second sim.
static func stranded_breakable(grid: Array, cols: int, rows: int,
		solid: Array[Vector2i], from: Array[Vector2i]) -> int:
	var solid_set := {}
	for s in solid:
		solid_set[s] = true
	var seen := {}
	var stack: Array[Vector2i] = []
	for f in from:
		if not solid_set.has(f) and not seen.has(f):
			seen[f] = true
			stack.append(f)
	while not stack.is_empty():
		var cell: Vector2i = stack.pop_back()
		for step in FOUR_WAY:
			var nxt: Vector2i = cell + (step as Vector2i)
			if nxt.x < 0 or nxt.y < 0 or nxt.x >= cols or nxt.y >= rows:
				continue
			if seen.has(nxt) or solid_set.has(nxt):
				continue
			seen[nxt] = true
			stack.append(nxt)
	var stranded := 0
	for r in rows:
		for c in cols:
			var cell := Vector2i(c, r)
			if _is_brick(grid, cols, rows, cell) and not solid_set.has(cell) and not seen.has(cell):
				stranded += 1
	return stranded


const FOUR_WAY := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]


static func _is_brick(grid: Array, cols: int, rows: int, cell: Vector2i) -> bool:
	if cell.x < 0 or cell.y < 0 or cell.x >= cols or cell.y >= rows:
		return false
	return (grid[cell.y * cols + cell.x] as Color).a >= 0.5


static func _clear(grid: Array, cols: int, rows: int, cell: Vector2i, out: Array[Vector2i]) -> void:
	if cell.x < 0 or cell.y < 0 or cell.x >= cols or cell.y >= rows:
		return
	grid[cell.y * cols + cell.x] = Color(0, 0, 0, 0)
	if not out.has(cell):
		out.append(cell)


## Bresenham: a 1-cell-wide carved line, so a channel is never wider than the
## reference's 1-2 brick stem.
static func _carve_line(grid: Array, cols: int, rows: int, from: Vector2i, to: Vector2i,
		out: Array[Vector2i], brush := 1) -> void:
	var dx := absi(to.x - from.x)
	var dy := -absi(to.y - from.y)
	var sx := 1 if from.x < to.x else -1
	var sy := 1 if from.y < to.y else -1
	var err := dx + dy
	var p := from
	var lo := -(brush - 1) / 2
	while true:
		for oy in brush:
			for ox in brush:
				_clear(grid, cols, rows, p + Vector2i(lo + ox, lo + oy), out)
		if p == to:
			break
		var e2 := 2 * err
		if e2 >= dy:
			err += dy
			p.x += sx
		if e2 <= dx:
			err += dx
			p.y += sy
