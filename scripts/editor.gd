class_name BreakoutEditor extends Control
## PIXEL BREAKOUT — the LEVEL EDITOR (Stage B).
##
## A designer mode, code-built like the menu: paint bricks on a grid, pick a
## brick colour, erase, carve the Y channel (stem + fork + two arms), toggle the
## solid unbreakable border, mark power-up tips, save/load and PLAY the level.
##
## The editor never invents geometry: the grid is drawn with the same cell pitch
## / inner-2 px brick math BrickField uses, the channel is carved with
## BreakoutLevel.carve_channel(), and the actual save path is BreakoutLevelWriter,
## which writes exactly the shipped PNG + JSON pair.
##
## A level without a fork is a bug (AGENTS.md §3), so the editor shows the
## channel while editing and REFUSES to save one that has none.

signal status_changed(text: String)

const TOOL_PAINT := "paint"
const TOOL_ERASE := "erase"
const TOOL_CHANNEL := "channel"
const TOOL_BORDER := "border"
const TOOL_TIP := "tip"

const VIEW := Vector2(540, 960)
const FIELD_TOP := 64.0
const DEFAULT_CELL := 12.0

## BRIEF 26 — the blank band Choubey leaves in a portrait for the corridor.
## A band is a horizontal run of empty cells with brick rows directly above and
## below it; it must be at least BAND_MIN_CELLS long and cover BAND_MIN_FRACTION
## of the grid, which is what tells it apart from a portrait's transparent
## margin or its dark shading (both give short runs only).
const BAND_MAX_HEIGHT := 2
const BAND_MIN_CELLS := 8
const BAND_MIN_FRACTION := 0.5
## A grey bar around the band must run at least this share of the band's length
## to count as a wall — see _band_solid_cells().
const BAND_SOLID_MIN_RUN := 0.5

var pal: Dictionary = {}
var cols := 40
var rows := 50
var cell := DEFAULT_CELL
var origin := Vector2(30, 64)

var level_id := "editor_level"
var display_name := "MY LEVEL"
var topic := "EDITOR LEVEL"
var allow_overwrite := false

var _art: Array = []                 # painted bricks, BEFORE the carve
var _channel: Dictionary = {}        # fork / stem_cols / stem_bottom / arms
var _tips: Array = []                # Array[Vector2i]
var _border_solid := true
var _band_solid: Array[Vector2i] = [] # grey frame bars the import made solid
var _palette: Array = []
var _palette_index := 0
var _tool := TOOL_PAINT
var _hover := Vector2i(-1, -1)
var _status := ""
var _dirty := false
var _loaded_id := ""
var _loaded_json := ""

var _canvas: Control
var _chip_row: HBoxContainer
var _status_label: Label
var _count_label: Label
var _id_edit: LineEdit
var _name_edit: LineEdit
var _tool_buttons: Dictionary = {}


func _ready() -> void:
	pal = Themes.get_theme(Game.theme_id)
	_build_ui()
	if Game.editor_snapshot.is_empty():
		new_level(40, 50)
	else:
		restore(Game.editor_snapshot)
	_refresh("")


# ------------------------------------------------------------------ build UI
func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.color = pal.get("background", Color(0.055, 0.055, 0.062))
	bg.size = VIEW
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var title := UITheme.label("LEVEL EDITOR", 22, Color(0.96, 0.93, 0.93), 4,
		Color(0.35, 0.05, 0.06, 1.0))
	title.position = Vector2(12, 6)
	title.size = Vector2(300, 24)
	add_child(title)

	var hint := UITheme.label("click / drag to paint  •  1-5 tools", 10, Color(0.72, 0.66, 0.68))
	hint.position = Vector2(300, 10)
	hint.size = Vector2(230, 16)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	add_child(hint)

	_id_edit = LineEdit.new()
	_id_edit.text = level_id
	_id_edit.position = Vector2(12, 34)
	_id_edit.size = Vector2(210, 24)
	_id_edit.placeholder_text = "level id"
	_id_edit.add_theme_font_size_override("font_size", 12)
	_id_edit.text_changed.connect(func(t: String) -> void:
		level_id = t.strip_edges()
		_dirty = true)
	add_child(_id_edit)

	_name_edit = LineEdit.new()
	_name_edit.text = display_name
	_name_edit.position = Vector2(230, 34)
	_name_edit.size = Vector2(298, 24)
	_name_edit.placeholder_text = "display name"
	_name_edit.add_theme_font_size_override("font_size", 12)
	_name_edit.text_changed.connect(func(t: String) -> void:
		display_name = t.strip_edges()
		topic = "EDITOR — %s" % (t.strip_edges() if t.strip_edges() != "" else "LEVEL")
		_dirty = true)
	add_child(_name_edit)

	_canvas = FieldCanvas.new()
	_canvas.name = "Field"
	_canvas.ed = self
	add_child(_canvas)

	var colour_label := UITheme.label("BRICK COLOUR", 10, Color(0.86, 0.78, 0.78))
	colour_label.position = Vector2(12, 676)
	add_child(colour_label)

	_chip_row = HBoxContainer.new()
	_chip_row.position = Vector2(104, 674)
	_chip_row.size = Vector2(424, 22)
	_chip_row.add_theme_constant_override("separation", 3)
	add_child(_chip_row)

	var tool_row := HBoxContainer.new()
	tool_row.position = Vector2(10, 700)
	tool_row.size = Vector2(520, 30)
	tool_row.add_theme_constant_override("separation", 4)
	add_child(tool_row)
	var tools := [
		["PAINT", TOOL_PAINT, Color(0.92, 0.35, 0.35)],
		["ERASE", TOOL_ERASE, Color(0.55, 0.58, 0.66)],
		["CHANNEL", TOOL_CHANNEL, Color(0.25, 0.75, 0.9)],
		["BORDER", TOOL_BORDER, Color(0.62, 0.64, 0.70)],
		["TIP", TOOL_TIP, Color(0.95, 0.75, 0.2)],
	]
	for t in tools:
		var accent: Color = t[2]
		var b := UITheme.button(str(t[0]), 11, accent, Vector2(100, 28))
		var tool_id: String = str(t[1])
		b.pressed.connect(func() -> void: set_tool(tool_id))
		tool_row.add_child(b)
		_tool_buttons[tool_id] = b

	var size_row := HBoxContainer.new()
	size_row.position = Vector2(10, 734)
	size_row.size = Vector2(520, 28)
	size_row.add_theme_constant_override("separation", 4)
	add_child(size_row)
	var b40 := UITheme.button("40x50", 11, Color(0.35, 0.6, 0.85), Vector2(74, 26))
	b40.pressed.connect(func() -> void: new_level(40, 50))
	size_row.add_child(b40)
	var b20 := UITheme.button("20x26", 11, Color(0.35, 0.6, 0.85), Vector2(74, 26))
	b20.pressed.connect(func() -> void: new_level(20, 26))
	size_row.add_child(b20)
	var b80 := UITheme.button("80x100", 11, Color(0.35, 0.6, 0.85), Vector2(74, 26))
	b80.pressed.connect(func() -> void: new_level(80, 100))
	size_row.add_child(b80)
	var bclear := UITheme.button("CLEAR", 11, Color(0.6, 0.4, 0.4), Vector2(74, 26))
	bclear.pressed.connect(func() -> void: _clear_art())
	size_row.add_child(bclear)
	var bopen := UITheme.button("LOAD NEXT", 11, Color(0.4, 0.55, 0.7), Vector2(104, 26))
	bopen.pressed.connect(_cycle_level)
	size_row.add_child(bopen)
	var bov := UITheme.button("OVERWRITE: OFF", 10, Color(0.7, 0.5, 0.35), Vector2(96, 26))
	bov.pressed.connect(func() -> void:
		allow_overwrite = not allow_overwrite
		bov.text = "OVERWRITE: %s" % ("ON" if allow_overwrite else "OFF"))
	size_row.add_child(bov)

	var action_row := HBoxContainer.new()
	action_row.position = Vector2(10, 766)
	action_row.size = Vector2(520, 36)
	action_row.add_theme_constant_override("separation", 4)
	add_child(action_row)
	var bsave := UITheme.button("SAVE", 13, Color(0.3, 0.75, 0.45), Vector2(100, 34))
	bsave.pressed.connect(func() -> void: save_to(""))
	action_row.add_child(bsave)
	var bload := UITheme.button("LOAD", 13, Color(0.35, 0.6, 0.9), Vector2(100, 34))
	bload.pressed.connect(func() -> void: load_level_id(_next_load_id()))
	action_row.add_child(bload)
	# IMPORT ANY ART: pick an image, it is stretched onto the CURRENT grid (the
	# counts line shows that grid) and becomes the painted art. Any size, any
	# aspect — SAVE then writes the normal PNG + JSON pair.
	var bimport := UITheme.button("IMPORT", 12, Color(0.78, 0.45, 0.95), Vector2(100, 34))
	bimport.pressed.connect(_open_import_dialog)
	action_row.add_child(bimport)
	# IMPORT PIXEL FILE: one step from a pixel-art PNG to a saved, playable
	# level — it picks the file through the same native picker, converts it
	# 1 pixel = 1 brick, applies the auto-solid grey rule and writes the
	# PNG + JSON pair into user://levels, where the menu already looks.
	var bpixel := UITheme.button("IMPORT PIXEL", 11, Color(0.62, 0.42, 0.98), Vector2(112, 34))
	bpixel.pressed.connect(_open_pixel_import_dialog)
	action_row.add_child(bpixel)
	var bplay := UITheme.button("PLAY", 13, Color(0.92, 0.35, 0.35), Vector2(100, 34))
	bplay.pressed.connect(func() -> void: play())
	action_row.add_child(bplay)
	var bmenu := UITheme.button("MENU", 13, Color(0.45, 0.45, 0.5), Vector2(100, 34))
	bmenu.pressed.connect(func() -> void: Game.goto_menu())
	action_row.add_child(bmenu)

	_status_label = UITheme.label("", 10, Color(0.86, 0.9, 0.95))
	_status_label.position = Vector2(12, 808)
	_status_label.size = Vector2(516, 40)
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_status_label)

	_count_label = UITheme.label("", 10, Color(0.72, 0.76, 0.82))
	_count_label.position = Vector2(12, 852)
	_count_label.size = Vector2(516, 16)
	add_child(_count_label)

	var foot := UITheme.label(
		"CHANNEL clears a stem + fork + two arms — a level without a fork cannot be saved.",
		9, Color(0.62, 0.58, 0.6))
	foot.position = Vector2(12, 874)
	foot.size = Vector2(516, 30)
	foot.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(foot)

	var back := UITheme.button("< BACK", 10, Color(0.45, 0.45, 0.5), Vector2(90, 26))
	back.position = Vector2(438, 8)
	back.pressed.connect(func() -> void: Game.goto_menu())
	add_child(back)


# ------------------------------------------------------------------ level state
## A fresh level of the given grid size: empty art, a default Y channel in the
## same place level_02 uses (fork at 68% of the height), solid border on.
func new_level(c: int, r: int) -> void:
	cols = clampi(c, 4, 128)
	rows = clampi(r, 4, 128)
	cell = DEFAULT_CELL
	origin = Vector2(round((VIEW.x - cols * cell) * 0.5), FIELD_TOP)
	_art = []
	_art.resize(cols * rows)
	_art.fill(Color(0, 0, 0, 0))
	_tips = []
	_border_solid = true
	_band_solid = []
	_channel = {}
	_loaded_id = ""
	_loaded_json = ""
	if level_id == "" or level_id.begins_with("level_0"):
		level_id = "editor_level"
		display_name = "MY LEVEL"
		topic = "EDITOR LEVEL"
	carve_at(Vector2i(cols / 2, int(round(rows * 0.68))))
	_build_palette()
	_sync_fields()
	_refresh("new %dx%d level" % [cols, rows])


func _clear_art() -> void:
	_art.fill(Color(0, 0, 0, 0))
	_refresh("grid cleared — the channel is still carved")
	_dirty = true


func colour_at(c: Vector2i) -> Color:
	if c.x < 0 or c.y < 0 or c.x >= cols or c.y >= rows:
		return Color(0, 0, 0, 0)
	return _art[c.y * cols + c.x]


func paint_cell(c: Vector2i, col: Variant = null) -> void:
	if c.x < 0 or c.y < 0 or c.x >= cols or c.y >= rows:
		return
	var use: Color = _palette[_palette_index] if _palette.size() > _palette_index else Color(0.647, 0.275, 0.275)
	if col != null:
		use = col
	if use.a < 0.5:
		_art[c.y * cols + c.x] = Color(0, 0, 0, 0)
	else:
		_art[c.y * cols + c.x] = Color(use.r, use.g, use.b, 1.0)
	_dirty = true
	_refresh("")


func erase_cell(c: Vector2i) -> void:
	if c.x < 0 or c.y < 0 or c.x >= cols or c.y >= rows:
		return
	_art[c.y * cols + c.x] = Color(0, 0, 0, 0)
	_dirty = true
	_refresh("")


## Carve the Y channel with its fork at `fork`. Geometry comes from the loader's
## own carve_channel(); the tips are derived from the arm ends.
func carve_at(fork: Vector2i) -> void:
	var fx := clampi(fork.x, 2, cols - 3)
	var fy := clampi(fork.y, 3, rows - 2)
	var arm_dx := maxi(3, mini(7, fx - 1))
	var arm_dy := maxi(3, mini(8, fy - 3))
	var left := Vector2i(clampi(fx - arm_dx, 1, cols - 2), clampi(fy - arm_dy, 1, rows - 2))
	var right := Vector2i(clampi(fx + arm_dx, 1, cols - 2), clampi(fy - arm_dy, 1, rows - 2))
	_channel = {
		"fork": [fx, fy],
		"stem_cols": [fx, fx + 1],
		"stem_bottom": rows - 1,
		"arm_width": 3,
		"arms": [[left.x, left.y], [right.x, right.y]],
	}
	_derive_tips()
	_dirty = true
	_refresh("channel carved — fork %s" % str(Vector2i(fx, fy)))


func clear_channel() -> void:
	_channel = {}
	_tips = []
	_dirty = true
	_refresh("channel removed")


func _derive_tips() -> void:
	_tips = []
	if _channel.is_empty():
		return
	var carved := _carved()
	var grid: Array = carved["grid"]
	var fork := Vector2i(int(_channel["fork"][0]), int(_channel["fork"][1]))
	for a in _channel.get("arms", []):
		var arm := Vector2i(int(a[0]), int(a[1]))
		var tip := BreakoutLevelWriter.resolve_tip(grid, cols, rows, fork, arm)
		if tip.x >= 0 and not _tips.has(tip):
			_tips.append(tip)
		if _tips.size() >= 2:
			break


func add_tip(cell_pos: Vector2i) -> void:
	var carved := _carved()
	if not BreakoutLevelWriter.is_brick(carved["grid"], cols, rows, cell_pos):
		_refresh("a power-up tip must be a brick — that cell is empty")
		return
	if _tips.has(cell_pos):
		_tips.erase(cell_pos)
		_refresh("tip removed")
		return
	if _tips.size() >= 2:
		_tips.pop_front()
	_tips.append(cell_pos)
	_dirty = true
	_refresh("power-up tip %s" % str(cell_pos))


func set_border_solid(on: bool) -> void:
	_border_solid = on
	_dirty = true
	_refresh("border is %s" % ("SOLID (unbreakable)" if on else "breakable"))


func is_border_solid() -> bool:
	return _border_solid


func set_tool(tool: String) -> void:
	_tool = tool
	for k in _tool_buttons:
		var b: Button = _tool_buttons[k]
		b.modulate = Color(1, 1, 1, 1) if k == tool else Color(0.72, 0.72, 0.76, 1)
	AudioManager.play("click")
	_refresh("tool: %s" % tool.to_upper())


func current_tool() -> String:
	return _tool


func select_colour(index: int) -> void:
	if index >= 0 and index < _palette.size():
		_palette_index = index
		_tool = TOOL_PAINT
		_restyle_palette()
		_refresh("colour %s" % _palette[index].to_html(false))


func palette() -> Array:
	return _palette


func palette_index() -> int:
	return _palette_index


func is_channel_cell(c: Vector2i) -> bool:
	var carved := _carved()
	for cellv in carved["cells"]:
		if cellv == c:
			return true
	return false


## The solid cells the level will carry: the border ring (when the solid
## border is on) UNION the auto-solid grey rule the loader applies — so the
## editor PREVIEW marks a grey wall as solid exactly like the game will, and a
## saved level lists it explicitly as well.
func unbreakable_cells() -> Array:
	var grid: Array = _carved()["grid"]
	var listed: Array = []
	if _border_solid:
		listed = BreakoutLevelWriter.border_unbreakable(grid, cols, rows)
	# BRIEF 26: the grey frame bars around an imported corridor band are walls.
	for cell in _band_solid:
		if not listed.has(cell):
			listed.append(cell)
	return BreakoutLevel.solid_cells(grid, cols, rows, listed)


func tips() -> Array:
	return _tips


func counts() -> Dictionary:
	var grid: Array = _carved()["grid"]
	var bricks := BreakoutLevelWriter.count_bricks(grid)
	var unb := unbreakable_cells()
	return {"bricks": bricks, "unbreakable": unb.size(),
		"breakable": bricks - unb.size(), "channel": _carved()["cells"].size()}


## The carved grid: what is drawn, saved as the PNG and played.
func _carved() -> Dictionary:
	if _channel.is_empty():
		return {"grid": _art.duplicate(), "cells": []}
	return BreakoutLevelWriter.carve(_art, cols, rows, _channel)


func channel_spec() -> Dictionary:
	return _channel


# ------------------------------------------------------------------ save / load
## Save the level as the shipped PNG + JSON pair. An empty `base_dir` means
## res://data/levels, falling back to user://levels when that is read-only
## (exported builds) — the game loads from both.
func save_to(base_dir := "") -> Dictionary:
	if _tips.is_empty() and not _channel.is_empty():
		_derive_tips()
	var carved := _carved()
	var grid: Array = carved["grid"]
	var unb := unbreakable_cells()
	var want_dir := base_dir
	if want_dir == "":
		want_dir = BreakoutLevelWriter.RES_DIR
	# Writing into user:// can never clobber a shipped file, so a shipped id is
	# allowed there (that is the path PLAY uses); res:// needs OVERWRITE on.
	var check := BreakoutLevelWriter.validate(level_id, grid, cols, rows, _channel,
		_tips, unb, allow_overwrite or want_dir == BreakoutLevelWriter.USER_DIR)
	if not bool(check.get("ok", false)):
		_refresh("NOT SAVED — %s" % str(check.get("err", "")))
		AudioManager.play("error")
		return check
	var res := BreakoutLevelWriter.write(want_dir, level_id, display_name, topic,
		grid, cols, rows, cell, origin, _channel, _tips, unb)
	if not bool(res.get("ok", false)) and base_dir == "":
		# res:// is read-only here (an exported build): fall back to user://.
		res = BreakoutLevelWriter.write(BreakoutLevelWriter.USER_DIR, level_id,
			display_name, topic, grid, cols, rows, cell, origin, _channel, _tips, unb)
	if bool(res.get("ok", false)):
		_loaded_id = level_id
		_loaded_json = str(res.get("json", ""))
		Game.editor_snapshot = snapshot()
		_dirty = false
		AudioManager.play("confirm")
		_refresh("saved %s  •  %d bricks (%d breakable / %d unbreakable)" % [
			str(res.get("dir", "")), int(res.get("bricks", 0)),
			int(res.get("breakable", 0)), int(res.get("unbreakable", 0))])
	else:
		AudioManager.play("error")
		_refresh("NOT SAVED — %s" % str(res.get("err", "")))
	return res


## Open a shipped or saved level back into the editor.
func load_level_id(id: String) -> bool:
	var json_path := BreakoutLevelWriter.find_json(id)
	if json_path == "":
		_refresh("no level called '%s' in res:// or user://" % id)
		AudioManager.play("error")
		return false
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(json_path))
	if not parsed is Dictionary:
		_refresh("cannot read %s" % json_path)
		AudioManager.play("error")
		return false
	var d: Dictionary = parsed
	var lv := BreakoutLevel.load_level(json_path)
	if not bool(lv.get("ok", false)):
		_refresh("cannot load %s — %s" % [id, str(lv.get("err", ""))])
		AudioManager.play("error")
		return false
	cols = int(lv["cols"])
	rows = int(lv["rows"])
	cell = float(lv["cell"])
	origin = lv["origin"]
	level_id = str(d.get("id", id))
	display_name = str(d.get("display_name", level_id.to_upper()))
	topic = str(d.get("topic", "EDITOR LEVEL"))
	# The PNG is already carved; re-carving the same spec is idempotent, so the
	# art loads as the level's bricks and the channel spec comes from the JSON.
	# Same reader as the game (FileAccess + buffer decode): on Android a res://
	# PNG lives inside the APK and globalize_path + load_from_file returns null.
	var img := BreakoutLevel.load_png_image(str(lv["image"]))
	if img == null:
		_refresh("cannot decode %s" % str(lv["image"]))
		AudioManager.play("error")
		return false
	if img.get_width() != cols or img.get_height() != rows:
		img.resize(cols, rows, Image.INTERPOLATE_NEAREST)
	img.convert(Image.FORMAT_RGBA8)
	_art = []
	_art.resize(cols * rows)
	for r in rows:
		for c in cols:
			var px := img.get_pixel(c, r)
			_art[r * cols + c] = Color(px.r, px.g, px.b, 1.0) if px.a >= 0.5 else Color(0, 0, 0, 0)
	_channel = d.get("channel", {})
	if not (_channel is Dictionary):
		_channel = {}
	_band_solid = []
	_tips = []
	for t in d.get("powerup_tips", []):
		if t is Array and (t as Array).size() == 2:
			_tips.append(Vector2i(int(t[0]), int(t[1])))
	_border_solid = not (d.get("unbreakable_cells", []) as Array).is_empty()
	_loaded_id = id
	_loaded_json = json_path
	_build_palette()
	_sync_fields()
	_dirty = false
	AudioManager.play("confirm")
	var cnt := counts()
	_refresh("loaded %s  •  %d bricks / %d breakable / %d unbreakable" % [
		id, int(cnt["bricks"]), int(cnt["breakable"]), int(cnt["unbreakable"])])
	return true


# ------------------------------------------------------------------ import
## IMPORT ANY ART. `path` is any image file the picker can reach (Android's
## filesystem, res://, user://); the image does NOT have to be the grid's pixel
## size — it is STRETCHED onto exactly cols x rows, so any portrait art becomes
## a playable level. The current grid size is used unless target_cols/rows are
## given; the channel, tips and border follow the normal editor rules, and
## SAVE writes the standard PNG + JSON pair (no second format).
## Returns {ok, err, cols, rows, source_w, source_h, bricks}.
func import_art(path: String, target_cols := 0, target_rows := 0) -> Dictionary:
	var img := BreakoutLevel.load_png_image(path)
	if img == null:
		_refresh("IMPORT FAILED — cannot decode %s" % path)
		AudioManager.play("error")
		return {"ok": false, "err": "cannot decode %s" % path}
	var src_w := img.get_width()
	var src_h := img.get_height()
	if src_w <= 0 or src_h <= 0:
		_refresh("IMPORT FAILED — %s has no pixels" % path)
		AudioManager.play("error")
		return {"ok": false, "err": "empty image"}
	var tc := clampi(target_cols if target_cols > 0 else cols, 4, 128)
	var tr := clampi(target_rows if target_rows > 0 else rows, 4, 128)
	img.convert(Image.FORMAT_RGBA8)
	if src_w != tc or src_h != tr:
		# Stretch to fill the grid. Shrinking a photo needs a real filter;
		# growing pixel art must stay crisp, so nearest wins upwards.
		var shrinking := tc * tr < src_w * src_h
		img.resize(tc, tr, Image.INTERPOLATE_LANCZOS if shrinking else Image.INTERPOLATE_NEAREST)
	# Adopt the new grid. `cell` only shrinks when the grid needs it (80x100 ->
	# cell 6, exactly like the shipped Ronaldo level), so the field stays in
	# the same 480x600 area and the portrait layout never changes.
	cols = tc
	rows = tr
	cell = minf(DEFAULT_CELL, minf(480.0 / float(cols), 600.0 / float(rows)))
	origin = Vector2(round((VIEW.x - cols * cell) * 0.5), FIELD_TOP)
	_art = []
	_art.resize(cols * rows)
	var filled := 0
	for r in rows:
		for c in cols:
			var px := img.get_pixel(c, r)
			if px.a >= 0.5:
				_art[r * cols + c] = Color(px.r, px.g, px.b, 1.0)
				filled += 1
			else:
				_art[r * cols + c] = Color(0, 0, 0, 0)
	# The channel is geometry, not art: keep a valid existing one, otherwise
	# carve the default Y so the imported level has its two paths immediately.
	# BRIEF 26 — IMPORT-TIME AUTO-CORRIDOR: Choubey ships portraits with the
	# corridor's blank band built in, so when one is found IT sets the channel
	# (never the default Y) and the grey bars around it become solid. Without a
	# band the old keep-or-default-Y rule below still applies unchanged.
	var band := find_blank_band(_art, cols, rows)
	_band_solid = []
	if not band.is_empty():
		_set_band_channel(band)
		_band_solid = _band_solid_cells(band)
	else:
		var keep := not _channel.is_empty()
		if keep:
			var fork := _fork_cell()
			keep = fork.x > 0 and fork.y > 0 and fork.x < cols and fork.y < rows
		if not keep:
			carve_at(Vector2i(cols / 2, int(round(rows * 0.68))))
	_tips = []
	_derive_tips()
	_border_solid = true
	_build_palette()
	_sync_fields()
	_dirty = true
	var cnt := counts()
	AudioManager.play("confirm")
	var band_note := ""
	if not band.is_empty():
		band_note = "  •  blank band row %d: corridor auto-set (fork %s), %d grey frame cells solid" % [
			int(band["row"]), str(Vector2i(int(_channel["fork"][0]), int(_channel["fork"][1]))),
			_band_solid.size()]
	_refresh("imported %s  •  %dx%d art stretched to %dx%d  •  %d bricks / %d breakable%s" % [
		path.get_file(), src_w, src_h, cols, rows, int(cnt["bricks"]), int(cnt["breakable"]),
		band_note])
	return {"ok": true, "err": "", "cols": cols, "rows": rows,
		"source_w": src_w, "source_h": src_h, "bricks": int(cnt["bricks"]),
		"band_row": int(band.get("row", -1)), "band_cells": int(band.get("length", 0)),
		"band_solid": _band_solid.size()}


## BRIEF 26 — find the corridor band in imported art: the longest horizontal run
## of EMPTY cells that has a brick row directly above and directly below it (1 or
## 2 rows tall, matching how Choubey draws it). Returns
## {row, height, first, last, length} or {} when the art has no band.
##
## Requiring bricks on both sides is what keeps open background out of the run:
## the portrait's transparent margin has no bricks above it. The length floor then
## rejects the short runs a portrait's shading leaves behind.
func find_blank_band(grid: Array, c_count: int, r_count: int) -> Dictionary:
	var best: Dictionary = {}
	var need := maxi(BAND_MIN_CELLS, int(ceil(float(c_count) * BAND_MIN_FRACTION)))
	for height in range(1, BAND_MAX_HEIGHT + 1):
		for r in range(1, r_count - height):
			var run_start := -1
			for c in range(0, c_count + 1):
				var in_band := c < c_count and _band_column(grid, c_count, r_count, c, r, height)
				if in_band and run_start < 0:
					run_start = c
				elif not in_band and run_start >= 0:
					var length := c - run_start
					# The band is a CLOSED slot: bricks at both of its ends ("between
					# two frame bars"). Without that, an already-carved corridor left
					# in a shipped PNG (Ronaldo's 2-row strip runs on past its stem)
					# would read as a band and silently re-carve the level.
					var closed := run_start > 0 and c < c_count \
						and BreakoutLevelWriter.is_brick(grid, c_count, r_count, Vector2i(run_start - 1, r)) \
						and BreakoutLevelWriter.is_brick(grid, c_count, r_count, Vector2i(c, r))
					if closed and length >= need and length > int(best.get("length", 0)):
						best = {"row": r, "height": height, "first": run_start,
							"last": c - 1, "length": length}
					run_start = -1
	return best


## Is (c, r) the first empty row of a band `height` rows tall, with bricks
## directly above and below it?
func _band_column(grid: Array, c_count: int, r_count: int, c: int, r: int,
		height: int) -> bool:
	for k in height:
		if BreakoutLevelWriter.is_brick(grid, c_count, r_count, Vector2i(c, r + k)):
			return false
	if not BreakoutLevelWriter.is_brick(grid, c_count, r_count, Vector2i(c, r - 1)):
		return false
	return BreakoutLevelWriter.is_brick(grid, c_count, r_count, Vector2i(c, r + height))


## BRIEF 26 — set the channel FROM the band: the fork sits in the band, the stem
## runs down under it to the last row, and one arm runs along the band to each
## end. `arm_width` stays 1 so the carve never leaves the blank row — a wider
## brush would eat the brick rows above and below the band (the Kai v1 mistake).
func _set_band_channel(band: Dictionary) -> void:
	var row := int(band["row"])
	var first_col := int(band["first"])
	var last_col := int(band["last"])
	# The fork sits one cell in from the band's left end so that BOTH arm tips
	# land on the frame bricks: BreakoutLevelWriter.validate() refuses an arm
	# that does not resolve to a brick, and an arm pointing down the stem (empty
	# all the way to the bottom row) can never resolve — the vertical corridor is
	# the stem itself, which stem_cols/stem_bottom carve.
	var fx := clampi(mini(first_col + 1, last_col), 1, cols - 2)
	_channel = {
		"fork": [fx, row],
		"stem_cols": [fx, fx + 1],
		"stem_bottom": rows - 1,
		"arm_width": 1,
		"arms": [[last_col, row], [first_col, row]],
	}


## BRIEF 26 — the solid frame: grey bricks directly above and below the band,
## classified by the loader's own rule (BreakoutLevel.is_grey).
##
## Only a grey BAR counts: a continuous run along the band of at least half the
## band's length. Choubey's corridor walls run the band's whole length, while a
## portrait's shading also lands in the grey range by a pixel or two (Pattinson's
## collar reads chroma 24 against the 25 limit) — those scattered cells are
## picture content and must stay breakable.
func _band_solid_cells(band: Dictionary) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var row := int(band["row"])
	var first_col := int(band["first"])
	var last_col := int(band["last"])
	var min_run := maxi(4, int(ceil(float(last_col - first_col + 1) * BAND_SOLID_MIN_RUN)))
	for rr in [row - 1, row + int(band["height"])]:
		if rr < 0 or rr >= rows:
			continue
		var run_start := -1
		for c in range(first_col, last_col + 2):
			var grey_bar := false
			if c <= last_col:
				grey_bar = BreakoutLevelWriter.is_brick(_art, cols, rows, Vector2i(c, rr)) \
					and BreakoutLevel.is_grey(_art[rr * cols + c])
			if grey_bar and run_start < 0:
				run_start = c
			elif not grey_bar and run_start >= 0:
				if c - run_start >= min_run:
					for cc in range(run_start, c):
						out.append(Vector2i(cc, rr))
				run_start = -1
	return out


func _fork_cell() -> Vector2i:
	if _channel.get("fork") is Array and (_channel["fork"] as Array).size() == 2:
		return Vector2i(int(_channel["fork"][0]), int(_channel["fork"][1]))
	return Vector2i(-1, -1)


## The picker: any image on the device. Importing never needs an import step
## from Godot (the PNG is read with FileAccess), so a file from Downloads works.
##
## PART C — PHONE-FRIENDLY IMPORT. `use_native_dialog` must be TRUE: on Android
## Godot only hands the job to the system picker (Storage Access Framework,
## ACTION_OPEN_DOCUMENT) when native dialogs are requested with
## ACCESS_FILESYSTEM. With it false the engine falls back to its own
## Godot-drawn FileDialog, which is the dialog Choubey could not browse the
## phone with. On desktop the same property opens the OS dialog (GTK/portal on
## Linux, the Windows picker); if no native dialog is available there, Godot
## falls back to its drawn one by itself, so a bare desktop session still
## works. The picked file arrives as `file_selected` with a path that
## `BreakoutLevel.load_png_image()` can read (on Android the picker copies it
## into the app's cache).
func _open_import_dialog(target := 0, target_rows := 0, pixel_mode := false) -> void:
	var dlg := FileDialog.new()
	dlg.title = "IMPORT ANY PORTRAIT ART (%dx%d grid)" % [cols, rows] if not pixel_mode \
		else "IMPORT PIXEL FILE (1 pixel = 1 brick)"
	dlg.access = FileDialog.ACCESS_FILESYSTEM
	dlg.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	dlg.filters = PackedStringArray(["*.png, *.jpg, *.jpeg ; Images"])
	dlg.use_native_dialog = true
	dlg.size = Vector2i(520, 620)
	dlg.position = Vector2i(10, 200)
	dlg.file_selected.connect(func(path: String) -> void:
		if pixel_mode:
			import_pixel_file(path)
		else:
			import_art(path, target, target_rows)
		dlg.queue_free())
	dlg.canceled.connect(func() -> void: dlg.queue_free())
	add_child(dlg)
	dlg.popup_centered()
	_refresh("pick an image — it will be stretched to the %dx%d grid" % [cols, rows])


# ------------------------------------------------------- direct pixel import
## PART D — DIRECT PIXEL-FILE IMPORT.
## Pick a pixel-art PNG and get a LEVEL: 1 pixel = 1 brick (no stretching), the
## auto-solid grey rule applied automatically (scripts/level_loader.gd), saved
## as the normal PNG + JSON pair in user://levels, registered in Game.LEVELS so
## it shows up in the menu, and left loaded in the editor so PLAY works.
## Returns {ok, err, id, json, png, cols, rows, bricks, unbreakable}.
func import_pixel_file(path: String) -> Dictionary:
	var probe := BreakoutLevel.load_png_image(path)
	if probe == null:
		_refresh("PIXEL IMPORT FAILED — cannot decode %s" % path)
		AudioManager.play("error")
		return {"ok": false, "err": "cannot decode %s" % path}
	var pw := clampi(probe.get_width(), 4, 128)
	var ph := clampi(probe.get_height(), 4, 128)
	# 1 pixel = 1 brick: the target grid IS the image, so import_art does no
	# resampling at all and the art keeps its exact pixels.
	var res := import_art(path, pw, ph)
	if not bool(res.get("ok", false)):
		return res
	level_id = _pixel_level_id(path)
	display_name = level_id.replace("_", " ").to_upper()
	topic = "IMPORTED PIXEL ART"
	var saved := save_to(BreakoutLevelWriter.USER_DIR)
	if not bool(saved.get("ok", false)):
		_refresh("PIXEL IMPORT — imported but NOT saved: %s" % str(saved.get("err", "")))
		AudioManager.play("error")
		return saved
	# The menu lists Game.LEVELS, so the new level is playable from it at once.
	Game.refresh_levels()
	var idx: int = Game.LEVELS.find(level_id)
	if idx >= 0:
		Game.menu_level_idx = idx
	var cnt := counts()
	AudioManager.play("confirm")
	_refresh("PIXEL IMPORT %s  •  %dx%d  •  %d bricks / %d breakable / %d unbreakable (grey walls solid)  •  in the menu" % [
		level_id, cols, rows, int(cnt["bricks"]), int(cnt["breakable"]), int(cnt["unbreakable"])])
	return {"ok": true, "err": "", "id": level_id,
		"json": str(saved.get("json", "")), "png": str(saved.get("png", "")),
		"cols": cols, "rows": rows, "bricks": int(cnt["bricks"]),
		"breakable": int(cnt["breakable"]), "unbreakable": int(cnt["unbreakable"])}


## A level id for an imported file that cannot collide with anything that
## already exists (a shipped id would otherwise be resolved to the shipped
## level by Game.level_json_path()).
func _pixel_level_id(path: String) -> String:
	var raw := path.get_file().get_basename().to_lower()
	var clean := ""
	for i in raw.length():
		var ch := raw[i]
		if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9"):
			clean += ch
		elif ch == "_" or ch == "-" or ch == " ":
			clean += "_"
	if clean == "" or not (clean[0] >= "a" and clean[0] <= "z"):
		clean = "pixel_" + clean
	clean = clean.substr(0, 48)
	var candidate := clean
	var n := 2
	while BreakoutLevelWriter.find_json(candidate) != "":
		candidate = "%s_%d" % [clean, n]
		n += 1
	return candidate


func _open_pixel_import_dialog() -> void:
	_open_import_dialog(0, 0, true)
	_refresh("pick a pixel-art PNG — 1 pixel becomes 1 brick, a blank corridor band sets the channel and the grey bars around it turn solid")


func _next_load_id() -> String:
	var ids := BreakoutLevelWriter.find_all()
	if ids.is_empty():
		return ""
	var idx := ids.find(_loaded_id)
	return str(ids[(idx + 1) % ids.size()])


func _cycle_level() -> void:
	var ids := BreakoutLevelWriter.find_all()
	if ids.is_empty():
		_refresh("no levels to load")
		return
	var idx := ids.find(_loaded_id)
	load_level_id(str(ids[(idx + 1) % ids.size()]))


# ------------------------------------------------------------------ play
## PLAY saves the level (to user://levels — a shipped level file is never
## overwritten) and launches the real game on it. Game.editor_snapshot keeps the
## editing state, so coming back leaves the level intact.
func play() -> Dictionary:
	var res := save_to(BreakoutLevelWriter.USER_DIR)
	if not bool(res.get("ok", false)):
		return res
	Game.editor_snapshot = snapshot()
	Game.editor_return = true
	Game.start_level(level_id, Game.resolve_seed(), str(res.get("json", "")))
	return res


func snapshot() -> Dictionary:
	return {
		"cols": cols, "rows": rows, "cell": cell, "origin": origin,
		"level_id": level_id, "display_name": display_name, "topic": topic,
		"art": _art.duplicate(), "channel": _channel.duplicate(true),
		"tips": _tips.duplicate(), "border": _border_solid,
		"band_solid": _band_solid.duplicate(),
		"allow_overwrite": allow_overwrite, "loaded_id": _loaded_id,
		"loaded_json": _loaded_json,
	}


func restore(s: Dictionary) -> void:
	cols = int(s.get("cols", 40))
	rows = int(s.get("rows", 50))
	cell = float(s.get("cell", DEFAULT_CELL))
	origin = Vector2(s.get("origin", Vector2(30, FIELD_TOP)))
	level_id = str(s.get("level_id", "editor_level"))
	display_name = str(s.get("display_name", "MY LEVEL"))
	topic = str(s.get("topic", "EDITOR LEVEL"))
	_art = (s.get("art", []) as Array).duplicate()
	if _art.size() != cols * rows:
		_art = []
		_art.resize(cols * rows)
		_art.fill(Color(0, 0, 0, 0))
	_channel = (s.get("channel", {}) as Dictionary).duplicate(true)
	_tips = (s.get("tips", []) as Array).duplicate()
	_border_solid = bool(s.get("border", true))
	_band_solid = []
	for cell in (s.get("band_solid", []) as Array):
		if cell is Vector2i:
			_band_solid.append(cell)
	allow_overwrite = bool(s.get("allow_overwrite", false))
	_loaded_id = str(s.get("loaded_id", ""))
	_loaded_json = str(s.get("loaded_json", ""))
	_build_palette()
	_sync_fields()
	_refresh("level restored")


# ------------------------------------------------------------------ UI helpers
func _build_palette() -> void:
	_palette = []
	var fixed := [
		pal.get("brick", Color(0.647, 0.275, 0.275)),
		pal.get("brick_dark", Color(0.50, 0.19, 0.20)),
		pal.get("frame", Color(0.52, 0.54, 0.58)),
		pal.get("accent", Color(0.90, 0.20, 0.22)),
		Color(0.98, 0.82, 0.28),
		Color(1, 1, 1),
		Color(0.12, 0.12, 0.14),
	]
	for c in fixed:
		_push_colour(c)
	# The colours the loaded portrait actually uses, most frequent first, so a
	# shipped level stays editable with its own palette.
	var freq := {}
	for col in _art:
		var cc: Color = col
		if cc.a < 0.5:
			continue
		var key := cc.to_html(false)
		freq[key] = int(freq.get(key, 0)) + 1
	var keys := freq.keys()
	keys.sort_custom(func(a: Variant, b: Variant) -> bool:
		return int(freq[a]) > int(freq[b]))
	for i in mini(11, keys.size()):
		_push_colour(Color(str(keys[i])))
	if _palette_index >= _palette.size():
		_palette_index = 0
	_build_chips()


func _push_colour(c: Color) -> void:
	for existing in _palette:
		if (existing as Color).is_equal_approx(c):
			return
	_palette.append(c)


func _build_chips() -> void:
	if _chip_row == null:
		return
	# remove_child BEFORE queue_free: a freed-pending chip is still a child until
	# the end of the frame, and _restyle_palette() indexes the palette by child
	# position.
	for child in _chip_row.get_children():
		_chip_row.remove_child(child)
		child.queue_free()
	for i in _palette.size():
		var b := Button.new()
		b.custom_minimum_size = Vector2(18, 18)
		b.focus_mode = Control.FOCUS_NONE
		b.tooltip_text = (_palette[i] as Color).to_html(false)
		var idx := i
		b.pressed.connect(func() -> void: select_colour(idx))
		_chip_row.add_child(b)
	_restyle_palette()


func _restyle_palette() -> void:
	if _chip_row == null:
		return
	var children := _chip_row.get_children()
	for i in mini(children.size(), _palette.size()):
		var b: Button = children[i]
		var batching: Color = _palette[i]
		var sb := StyleBoxFlat.new()
		sb.bg_color = batching
		sb.set_corner_radius_all(3)
		sb.set_border_width_all(2)
		sb.border_color = Color(1, 1, 1, 0.95) if i == _palette_index else Color(0, 0, 0, 0.55)
		b.add_theme_stylebox_override("normal", sb)
		b.add_theme_stylebox_override("hover", sb)
		b.add_theme_stylebox_override("pressed", sb)


func _sync_fields() -> void:
	if _id_edit != null and _id_edit.text != level_id:
		_id_edit.text = level_id
	if _name_edit != null and _name_edit.text != display_name:
		_name_edit.text = display_name


func _refresh(message: String) -> void:
	if message != "":
		_status = message
	# A new level carves its channel before there are any bricks, so the arm
	# tips can only be resolved once art exists. Derive them as soon as they can
	# exist; a tip the designer placed by hand is never overwritten.
	if _tips.is_empty() and not _channel.is_empty():
		_derive_tips()
	if _canvas != null:
		_canvas.position = origin
		_canvas.size = Vector2(cols * cell, rows * cell)
		_canvas.queue_redraw()
	if _status_label != null:
		_status_label.text = _status
	if _count_label != null:
		var cnt := counts()
		_count_label.text = "%dx%d  •  %d bricks  •  %d breakable  •  %d unbreakable  •  %d channel cells%s" % [
			cols, rows, int(cnt["bricks"]), int(cnt["breakable"]),
			int(cnt["unbreakable"]), int(cnt["channel"]),
			"  •  UNSAVED" if _dirty else ""]
	status_changed.emit(_status)


func status_text() -> String:
	return _status


## Where the pointer landed, in grid space (used by the canvas, and directly by
## the editor test suite).
func pointer(local: Vector2) -> void:
	var c := Vector2i(floori(local.x / cell), floori(local.y / cell))
	if c.x < 0 or c.y < 0 or c.x >= cols or c.y >= rows:
		_hover = Vector2i(-1, -1)
		_canvas.queue_redraw()
		return
	_hover = c
	_apply(c)


func _apply(c: Vector2i) -> void:
	match _tool:
		TOOL_PAINT:
			paint_cell(c, _palette[_palette_index] if _palette.size() > _palette_index else null)
		TOOL_ERASE:
			erase_cell(c)
		TOOL_CHANNEL:
			carve_at(c)
		TOOL_BORDER:
			set_border_solid(not _border_solid)
		TOOL_TIP:
			add_tip(c)
	_canvas.queue_redraw()


func _unhandled_key_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not (event as InputEventKey).pressed:
		return
	match (event as InputEventKey).keycode:
		KEY_1: set_tool(TOOL_PAINT)
		KEY_2: set_tool(TOOL_ERASE)
		KEY_3: set_tool(TOOL_CHANNEL)
		KEY_4: set_tool(TOOL_BORDER)
		KEY_5: set_tool(TOOL_TIP)
		KEY_ESCAPE: Game.goto_menu()


# ------------------------------------------------------------------ drawing
## The grid is drawn exactly as BrickField draws it: same origin, same cell
## pitch, same inner = cell - 2 brick with the 1.5 px darker bottom row.
func draw_field(c: Control) -> void:
	if cols <= 0 or rows <= 0:
		return
	var carved := _carved()
	var grid: Array = carved["grid"]
	var channel_cells: Array = carved["cells"]
	var w := cols * cell
	var h := rows * cell
	var inner := cell - 2.0

	c.draw_rect(Rect2(Vector2(-8, -8), Vector2(w + 16, h + 16)),
		pal.get("frame_dark", Color(0.28, 0.29, 0.33)))
	c.draw_rect(Rect2(Vector2(-4, -4), Vector2(w + 8, h + 8)),
		pal.get("frame", Color(0.52, 0.54, 0.58)))
	c.draw_rect(Rect2(Vector2.ZERO, Vector2(w, h)), Color(0.02, 0.02, 0.025))
	c.draw_rect(Rect2(Vector2(-8, -8), Vector2(w + 16, 5)),
		pal.get("top_strip", Color(0.72, 0.12, 0.14)))

	var unb := {}
	for u in unbreakable_cells():
		unb[u] = true

	for r in rows:
		for col_i in cols:
			var col: Color = grid[r * cols + col_i]
			if col.a < 0.5:
				continue
			var x := float(col_i) * cell
			var y := float(r) * cell
			c.draw_rect(Rect2(x, y, inner, inner), col)
			c.draw_rect(Rect2(x, y + inner - 1.5, inner, 1.5), col.darkened(0.35))
			if unb.has(Vector2i(col_i, r)):
				c.draw_rect(Rect2(x, y, inner, inner), Color(0.62, 0.64, 0.68, 0.42))
				c.draw_rect(Rect2(x, y, inner, inner), Color(0.80, 0.83, 0.88, 0.7), false, 1.0)

	# the channel, always visible while editing
	for cellv in channel_cells:
		var cv: Vector2i = cellv
		c.draw_rect(Rect2(cv.x * cell, cv.y * cell, cell, cell), Color(0.25, 0.85, 1.0, 0.16))

	# grid lines every 5 cells, so the designer can count
	var line := Color(1, 1, 1, 0.05)
	for col_i in range(5, cols, 5):
		c.draw_line(Vector2(col_i * cell, 0), Vector2(col_i * cell, h), line, 1.0)
	for r in range(5, rows, 5):
		c.draw_line(Vector2(0, r * cell), Vector2(w, r * cell), line, 1.0)

	# power-up tips
	for t in _tips:
		var tv: Vector2i = t
		var ctr := Vector2(tv.x * cell + cell * 0.5, tv.y * cell + cell * 0.5)
		c.draw_circle(ctr, cell * 0.34, Color(0.98, 0.82, 0.28, 0.95))

	if _hover.x >= 0:
		c.draw_rect(Rect2(_hover.x * cell, _hover.y * cell, cell, cell),
			Color(1, 1, 1, 0.9), false, 1.5)


# ------------------------------------------------------------------ canvas
class FieldCanvas extends Control:
	var ed: BreakoutEditor

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton:
			var mb := event as InputEventMouseButton
			if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
				ed.pointer(mb.position)
		elif event is InputEventMouseMotion:
			var mm := event as InputEventMouseMotion
			if (mm.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
				ed.pointer(mm.position)
		elif event is InputEventScreenTouch:
			var st := event as InputEventScreenTouch
			if st.pressed:
				ed.pointer(st.position)
		elif event is InputEventScreenDrag:
			ed.pointer((event as InputEventScreenDrag).position)

	func _draw() -> void:
		if ed != null:
			ed.draw_field(self)
