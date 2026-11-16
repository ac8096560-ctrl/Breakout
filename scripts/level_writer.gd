class_name BreakoutLevelWriter extends RefCounted
## LEVEL WRITER — the editor's save/load side (Stage B).
##
## It writes EXACTLY the shipped format, and nothing else:
##   PNG  : cols x rows pixels, one pixel per brick cell, pixel colour = brick
##          colour, a fully transparent pixel = empty cell.
##   JSON : id, display_name, topic, image, cols, rows, cell, origin, channel,
##          powerup_tips, unbreakable_cells — the same keys level_02_jensen.json
##          carries.
##
## `BreakoutLevel.load_level()` reads that pair straight off disk (no import
## step), so a level saved here is an ordinary level the moment it is written.
##
## Validation REFUSES and explains; it never silently repairs a level.

const SHIPPED_IDS := ["level_01_portrait", "level_02_jensen"]
const RES_DIR := "res://data/levels"
const USER_DIR := "user://levels"


## Every cell of the outer border ring, row 0 / row rows-1 / col 0 / col cols-1.
static func border_ring(cols: int, rows: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for c in cols:
		out.append(Vector2i(c, 0))
		out.append(Vector2i(c, rows - 1))
	for r in range(1, rows - 1):
		out.append(Vector2i(0, r))
		out.append(Vector2i(cols - 1, r))
	return out


## Carve the channel spec into a COPY of the painted art, using the loader's own
## geometry (BreakoutLevel.carve_channel) — the editor never invents fit math.
static func carve(art: Array, cols: int, rows: int, spec: Dictionary) -> Dictionary:
	var grid := art.duplicate()
	var cells: Array[Vector2i] = BreakoutLevel.carve_channel(grid, cols, rows, spec)
	return {"grid": grid, "cells": cells}


static func count_bricks(grid: Array) -> int:
	var n := 0
	for col in grid:
		if (col as Color).a >= 0.5:
			n += 1
	return n


static func is_brick(grid: Array, cols: int, rows: int, cell: Vector2i) -> bool:
	if cell.x < 0 or cell.y < 0 or cell.x >= cols or cell.y >= rows:
		return false
	return (grid[cell.y * cols + cell.x] as Color).a >= 0.5


## The unbreakable list the level will carry: border-ring cells that are still
## bricks AFTER the carve. A ring cell the channel carved open (the stem gap) is
## an entry, not a wall, so it is simply not listed — the loader drops it too.
static func border_unbreakable(grid: Array, cols: int, rows: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for cell in border_ring(cols, rows):
		if is_brick(grid, cols, rows, cell):
			out.append(cell)
	return out


## The first brick a tip cell snaps outward to, mirroring the loader's rule.
static func resolve_tip(grid: Array, cols: int, rows: int, fork: Vector2i,
		tip: Vector2i) -> Vector2i:
	var cell := tip
	var dirx := signi(cell.x - fork.x)
	var diry := signi(cell.y - fork.y)
	for _step in 5:
		if is_brick(grid, cols, rows, cell):
			return cell
		cell += Vector2i(dirx, diry)
	return cell if is_brick(grid, cols, rows, cell) else Vector2i(-1, -1)


## Validate a level about to be saved. Returns {ok, err}.
## `allow_shipped` is true only when the caller deliberately overwrites a
## shipped level id (the editor asks for confirmation before setting it).
static func validate(id: String, grid: Array, cols: int, rows: int,
		channel: Dictionary, tips: Array, unbreakable: Array,
		allow_shipped := false) -> Dictionary:
	if id.strip_edges() == "":
		return _bad("the level id is empty — give the level a name")
	for i in id.length():
		var ch := id[i]
		if not ((ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9") or ch == "_"):
			return _bad("level id '%s' must be lowercase letters, digits or _ (no spaces)" % id)
	if SHIPPED_IDS.has(id) and not allow_shipped:
		return _bad("'%s' is a shipped level — change the id (or turn OVERWRITE on)" % id)
	if cols < 4 or rows < 4:
		return _bad("the grid is %dx%d — it must be at least 4x4" % [cols, rows])
	if count_bricks(grid) <= 0:
		return _bad("the grid is empty — paint some bricks first")
	if channel.is_empty():
		return _bad("no channel — every level needs a fork (use the CHANNEL tool)")
	var fork := Vector2i(-1, -1)
	if channel.get("fork") is Array and (channel["fork"] as Array).size() == 2:
		fork = Vector2i(int(channel["fork"][0]), int(channel["fork"][1]))
	if fork.x < 0 or fork.y < 0 or fork.x >= cols or fork.y >= rows:
		return _bad("the channel fork cell is missing or outside the grid")
	if is_brick(grid, cols, rows, fork):
		return _bad("the fork cell %s is still a brick — re-carve the channel" % str(fork))
	if channel.get("stem_cols") is not Array or (channel["stem_cols"] as Array).size() != 2:
		return _bad("the channel has no two stem columns")
	var stem_bottom := int(channel.get("stem_bottom", rows - 1))
	if stem_bottom != rows - 1:
		return _bad("the stem stops at row %d — it must reach the bottom row %d" % [
			stem_bottom, rows - 1])
	for sc in channel["stem_cols"]:
		if is_brick(grid, cols, rows, Vector2i(int(sc), rows - 1)):
			return _bad("the stem does not break through the bottom row")
	var arms: Array = channel.get("arms", [])
	if arms.size() != 2:
		return _bad("the channel needs two arms (left and right of the fork)")
	for a in arms:
		if not (a is Array) or (a as Array).size() != 2:
			return _bad("an arm of the channel is malformed")
		var tip := resolve_tip(grid, cols, rows, fork, Vector2i(int(a[0]), int(a[1])))
		if tip.x < 0:
			return _bad("arm %s does not end on a brick tip" % str(a))
	if tips.is_empty():
		return _bad("mark at least one power-up tip (TIP tool) on an arm")
	if tips.size() > 2:
		return _bad("%d power-up tips — a level carries at most 2" % tips.size())
	for t in tips:
		if not is_brick(grid, cols, rows, t as Vector2i):
			return _bad("power-up tip %s is not a brick" % str(t))
	for u in unbreakable:
		if not is_brick(grid, cols, rows, u as Vector2i):
			return _bad("unbreakable cell %s is not a brick or is channel space" % str(u))
	return {"ok": true, "err": ""}


static func build_json(id: String, display_name: String, topic: String, image: String,
		cols: int, rows: int, cell: float, origin: Vector2, channel: Dictionary,
		tips: Array, unbreakable: Array) -> Dictionary:
	var tip_list: Array = []
	for t in tips:
		var tip: Vector2i = t
		tip_list.append([tip.x, tip.y])
	var unb_list: Array = []
	for u in unbreakable:
		var cellp: Vector2i = u
		unb_list.append([cellp.x, cellp.y])
	return {
		"id": id,
		"display_name": display_name,
		"topic": topic,
		"image": image,
		"cols": cols,
		"rows": rows,
		"cell": cell,
		"origin": [origin.x, origin.y],
		"channel": {
			"fork": channel.get("fork", [cols / 2, int(round(rows * 0.68))]),
			"stem_cols": channel.get("stem_cols", [cols / 2, cols / 2 + 1]),
			"stem_bottom": int(channel.get("stem_bottom", rows - 1)),
			"arm_width": int(channel.get("arm_width", 3)),
			"arms": channel.get("arms", []),
		},
		"powerup_tips": tip_list,
		"unbreakable_cells": unb_list,
	}


## Write the PNG + JSON pair into `dir`. Returns
## {ok, err, json, png, dir, bricks, breakable, unbreakable}.
static func write(dir: String, id: String, display_name: String, topic: String,
		grid: Array, cols: int, rows: int, cell: float, origin: Vector2,
		channel: Dictionary, tips: Array, unbreakable: Array) -> Dictionary:
	var abs_dir := ProjectSettings.globalize_path(dir)
	var mk := DirAccess.make_dir_recursive_absolute(abs_dir)
	if mk != OK and mk != ERR_ALREADY_EXISTS:
		return {"ok": false, "err": "cannot create %s (%s)" % [dir, error_string(mk)]}

	var img := Image.create(cols, rows, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	for r in rows:
		for c in cols:
			var col: Color = grid[r * cols + c]
			if col.a >= 0.5:
				img.set_pixel(c, r, Color(col.r, col.g, col.b, 1.0))

	var png_path := dir.path_join("%s.png" % id)
	var json_path := dir.path_join("%s.json" % id)
	var se := img.save_png(ProjectSettings.globalize_path(png_path))
	if se != OK:
		return {"ok": false, "err": "cannot write %s (%s)" % [png_path, error_string(se)]}

	var body := build_json(id, display_name, topic, "%s.png" % id, cols, rows, cell,
		origin, channel, tips, unbreakable)
	var f := FileAccess.open(json_path, FileAccess.WRITE)
	if f == null:
		return {"ok": false, "err": "cannot write %s (%s)" % [
			json_path, error_string(FileAccess.get_open_error())]}
	f.store_string(JSON.stringify(body, "  ") + "\n")
	f.close()

	var bricks := count_bricks(grid)
	return {
		"ok": true, "err": "", "json": json_path, "png": png_path, "dir": dir,
		"bricks": bricks, "unbreakable": unbreakable.size(),
		"breakable": bricks - unbreakable.size(),
	}


## Where a level with this id lives: the shipped folder first, then the user
## folder the editor falls back to when res:// is read-only.
static func find_json(id: String) -> String:
	var res := RES_DIR.path_join("%s.json" % id)
	if FileAccess.file_exists(res):
		return res
	var usr := USER_DIR.path_join("%s.json" % id)
	if FileAccess.file_exists(usr):
		return usr
	return ""


## Level ids the editor can open: the shipped ones plus anything saved to the
## user folder.
static func find_all() -> Array:
	var out: Array = []
	for id in SHIPPED_IDS:
		if FileAccess.file_exists(RES_DIR.path_join("%s.json" % id)):
			out.append(id)
	for dir_path in [USER_DIR]:
		var dir := DirAccess.open(dir_path)
		if dir == null:
			continue
		dir.list_dir_begin()
		var name := dir.get_next()
		while name != "":
			if not dir.current_is_dir() and name.ends_with(".json"):
				var id := name.get_basename()
				if not out.has(id):
					out.append(id)
			name = dir.get_next()
		dir.list_dir_end()
	return out


static func _bad(msg: String) -> Dictionary:
	return {"ok": false, "err": msg}
