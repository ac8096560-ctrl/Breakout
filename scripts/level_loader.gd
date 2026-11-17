class_name BreakoutLevel extends RefCounted
## LEVEL FORMAT — one small pixel-art PNG + one JSON sidecar.
##
## PNG  : W x H pixels, ONE PIXEL PER BRICK CELL. The pixel colour IS the brick
##        colour; a fully transparent pixel is an empty cell (no brick).
## JSON : id, display name, topic, image file name, grid geometry (columns,
##        rows, cell pitch, screen origin), the CARVED CHANNEL (stem + fork +
##        two arms — every level must give the ball a path and a choice point),
##        the power-up tip cells, and the optional UNBREAKABLE CELLS — a
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

	# --- the required channel: stem + fork + two arms, carved AFTER the art so
	# no level can ship without a path.
	var channel: Dictionary = d.get("channel", {})
	var channel_cells: Array[Vector2i] = carve_channel(grid, cols, rows, channel)

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

	# --- unbreakable cells: the solid border ring (walls, not bricks). They
	# are listed explicitly in the JSON (never a magic colour) and are only
	# kept when they are still bricks after the channel carve — a carved-out
	# cell (the stem gap) is an entry, not a wall.
	var unbreakable: Array[Vector2i] = []
	for u in d.get("unbreakable_cells", []):
		if not (u is Array) or (u as Array).size() != 2:
			continue
		var cellp := Vector2i(int(u[0]), int(u[1]))
		if _is_brick(grid, cols, rows, cellp) and not unbreakable.has(cellp):
			unbreakable.append(cellp)

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
		"bricks": bricks,
		"unbreakable_cells": unbreakable,
		"unbreakable": unbreakable.size(),
		"breakable": bricks - unbreakable.size(),
	}


## Decode a PNG from ANY readable path — res:// inside an exported APK, an
## absolute path, or user:// where the editor writes. FileAccess is the only
## reader that works for res:// in a packaged Android build, so no caller may
## fall back to Image.load_from_file(ProjectSettings.globalize_path(...)).
## Returns null when the file cannot be read or cannot be decoded. PNG is the
## level format; JPEG is accepted because the editor's IMPORT can take any
## portrait art (the editor re-saves it as a PNG).
static func load_png_image(path: String) -> Image:
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
