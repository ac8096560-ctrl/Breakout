extends Node
## BREAKOUT TEST HARNESS (autoload "TestRunner").
##
## One mode per suite, one machine-readable verdict line per suite, one
## summary line for the run, exit code 0 on pass / 1 on fail — the same
## contract as WorldRace's TestRunner, with its own prefix:
##
##   godot --headless --path . -- --breakout-test     gameplay suites
##   godot --headless --path . -- --breakout-editor-test  level editor suite
##   godot --headless --path . -- --breakout-smoke    menu loads, game builds
##   godot --headless --path . -- --breakout-pace     70s pacing measurement
##   godot --path . -- --breakout-record              record one take (needs a display)
##
## Never treat a missing verdict line as a pass: the run prints one line per
## suite plus WR_BREAKOUT_<MODE>_RESULT PASS|FAIL.

const GAME_SCENE := "res://scenes/game.tscn"
const LEVEL_JSON := "res://data/levels/level_01_portrait.json"

var _args: PackedStringArray = []
var _fails := 0


func _ready() -> void:
	_args = OS.get_cmdline_user_args()
	if _args.has("--breakout-test"):
		call_deferred("_suite_all")
	elif _args.has("--breakout-editor-test"):
		call_deferred("_suite_editor")
	elif _args.has("--breakout-smoke"):
		call_deferred("_suite_smoke")
	elif _args.has("--breakout-pace"):
		call_deferred("_suite_pace")
	elif _args.has("--breakout-record"):
		call_deferred("_suite_record")


# ------------------------------------------------------------------ helpers
func _suite(name: String, ok: bool, detail: String) -> void:
	print("WR_BREAKOUT_SUITE %s %s %s" % [name, "PASS" if ok else "FAIL", detail])
	if not ok:
		_fails += 1


func _report(kind: String, ok: bool, detail: String) -> void:
	print("%s %s %s" % [kind, "PASS" if ok else "FAIL", detail])
	await get_tree().process_frame
	await get_tree().process_frame
	get_tree().quit(0 if ok else 1)


func _new_game() -> Node:
	var g: Node = load(GAME_SCENE).instantiate()
	add_child(g)
	await get_tree().process_frame
	await get_tree().physics_frame
	return g


# ------------------------------------------------------------------ suites
func _suite_all() -> void:
	await _check_level_load()

	var g: Node = await _new_game()
	g.debug_force_play()
	await _check_ball_bounce(g)
	await _check_brick_break(g)
	await _check_paddle_catch(g)
	await _check_player_input(g)
	await _check_multiball(g)
	await _check_multiball_times3(g)
	await _check_powerup_minus(g)
	await _check_powerup_star(g)
	await _check_drop_pool(g)
	await _check_win(g)
	g.queue_free()
	await get_tree().process_frame

	var g2: Node = await _new_game()
	g2.debug_force_play()
	await _check_lose(g2)
	g2.queue_free()
	await get_tree().process_frame

	# The solid border exists only on level_02, so it gets its own instance.
	Game.level_id = "level_02_jensen"
	var g3: Node = await _new_game()
	g3.debug_force_play()
	await _check_unbreakable_border(g3)
	g3.queue_free()
	await get_tree().process_frame

	await _report("WR_BREAKOUT_RESULT", _fails == 0, "failing suites: %d" % _fails)


func _check_level_load() -> void:
	# Every registered level must load and satisfy the design rules (enough
	# bricks, a carved channel, two power-up tips, a real palette, and an
	# empty channel). Adding a level to Game.LEVELS automatically tests it.
	var all_ok := true
	var details: Array[String] = []
	for level_id in Game.LEVELS:
		var lv := BreakoutLevel.load_level("res://data/levels/%s.json" % level_id)
		var ok := bool(lv.get("ok", false))
		var detail := str(lv.get("err", ""))
		if ok:
			var colours := {}
			var grid: Array = lv["grid"]
			var channel_empty := true
			for c in lv["channel_cells"]:
				var cellc: Vector2i = c
				if (grid[cellc.y * int(lv["cols"]) + cellc.x] as Color).a >= 0.5:
					channel_empty = false
			for col in grid:
				var cc: Color = col
				if cc.a >= 0.5:
					colours[cc.to_html(false)] = true
			ok = int(lv["bricks"]) > 900 and int(lv["channel_cells"].size()) > 20 \
				and int(lv["powerup_cells"].size()) == 2 and colours.size() >= 4 and channel_empty \
				and int(lv["breakable"]) + int(lv["unbreakable"]) == int(lv["bricks"]) \
				and int(lv["breakable"]) > 900
			# level_02's solid border is 174 unbreakable cells, 1724 breakable
			if level_id == "level_02_jensen":
				ok = ok and int(lv["unbreakable"]) == 174 and int(lv["breakable"]) == 1724
			detail = "%s bricks=%d breakable=%d unbreakable=%d channel=%d colours=%d tips=%d" % [
				level_id, int(lv["bricks"]), int(lv["breakable"]), int(lv["unbreakable"]),
				int(lv["channel_cells"].size()), colours.size(),
				int(lv["powerup_cells"].size())]
		if not ok:
			all_ok = false
		details.append(detail)
	_suite("level_load", all_ok, " | ".join(details))


func _check_ball_bounce(g: Node) -> void:
	g.debug_clear_balls()
	var b: Ball = g.debug_spawn_ball(Vector2(60, 500), Vector2(-240, -140))
	var bounced := false
	for i in 60:
		await get_tree().physics_frame
		if not is_instance_valid(b) or not b.active:
			break
		if b.vel.x > 0.0 and b.position.x > 10.0:
			bounced = true
			break
	_suite("ball_bounce", bounced, "vel=%s pos=%s" % [
		str(b.vel) if is_instance_valid(b) else "freed",
		str(b.position) if is_instance_valid(b) else "freed"])
	g.debug_clear_balls()
	g.debug_ensure_playing()


func _check_brick_break(g: Node) -> void:
	var before := int(g.bricks_left)
	var target := Vector2i(-1, -1)
	for c in g._bodies.keys():
		var cellc: Vector2i = c
		if cellc.y < 12 and cellc.x > 2 and cellc.x < 37:
			var b0: Brick = g._bodies[c]
			if b0.unbreakable:
				continue
			target = cellc
			break
	if target.x < 0:
		_suite("brick_break", false, "no brick found")
		return
	var at: Vector2 = g.cell_center(target)
	var b: Ball = g.debug_spawn_ball(at + Vector2(0, 16), Vector2(0, -350))
	var broke := false
	for i in 20:
		await get_tree().physics_frame
		if int(g.bricks_left) < before:
			broke = true
			break
	_suite("brick_break", broke, "cell=%s before=%d after=%d score=%d" % [
		str(target), before, int(g.bricks_left), int(g.score)])
	if is_instance_valid(b):
		b.active = false
		b.queue_free()
	g.debug_clear_balls()
	g.debug_ensure_playing()


func _check_paddle_catch(g: Node) -> void:
	var px: float = g.paddle.position.x
	var right: Vector2 = g.paddle.bounce_for(px + 40.0, 350.0)
	var left: Vector2 = g.paddle.bounce_for(px - 40.0, 350.0)
	var centre: Vector2 = g.paddle.bounce_for(px, 350.0)
	var ok := right.y < -120.0 and right.x > 100.0 and left.y < -120.0 and left.x < -100.0 \
		and absf(centre.x) < 6.0 and centre.y < -300.0
	_suite("paddle_catch", ok, "right=%s left=%s centre=%s" % [
		str(right.round()), str(left.round()), str(centre.round())])


## The NEW input path: a mouse motion must take the paddle OUT of auto-play and
## steer it to the pointer; a key press must also hand control to the player.
## (Driven through the same _input() handler the window feeds.)
func _check_player_input(g: Node) -> void:
	var before := float(g.paddle.position.x)
	var ev := InputEventMouseMotion.new()
	ev.position = Vector2(120, 500)
	g._input(ev)
	var auto_off := not bool(g.auto_play)
	for i in 20:
		await get_tree().physics_frame
	var tracked := absf(float(g.paddle.position.x) - 120.0) < 30.0
	# keyboard fallback leaves auto-play too (direction read from Input)
	g.auto_play = true
	var kb := InputEventKey.new()
	kb.keycode = KEY_LEFT
	kb.pressed = true
	g._input(kb)
	var kb_off := not bool(g.auto_play)
	_suite("player_input", auto_off and tracked and kb_off,
		"auto_play_off=%s paddle_x=%.1f (was %.1f) key_off=%s" % [
			str(auto_off), float(g.paddle.position.x), before, str(kb_off)])


func _check_multiball(g: Node) -> void:
	g.debug_ensure_playing()
	if int(g.ball_count()) == 0:
		g.debug_spawn_ball(Vector2(270, 500), Vector2(0, -300))
	await get_tree().physics_frame
	var before := int(g.ball_count())
	g.debug_spawn_powerup_at_paddle()
	for i in 8:
		await get_tree().physics_frame
	var after := int(g.ball_count())
	var ok := after == before + 3 and float(g.first_multiball_at) >= 0.0 \
		and int(g.powerups_caught) >= 1
	_suite("multiball_plus3", ok, "balls %d -> %d caught=%d first=%.2fs" % [
		before, after, int(g.powerups_caught), float(g.first_multiball_at)])


func _check_multiball_times3(g: Node) -> void:
	g.debug_ensure_playing()
	if int(g.ball_count()) == 0:
		g.debug_spawn_ball(Vector2(270, 500), Vector2(0, -300))
	await get_tree().physics_frame
	var before := int(g.ball_count())
	var caught_before := int(g.powerups_caught)
	g.debug_spawn_powerup_at_paddle("times3")
	for i in 8:
		await get_tree().physics_frame
	var after := int(g.ball_count())
	# 120 mirrors BreakoutGame.MAX_BALLS (the test harness cannot see it).
	var want := mini(before * 3, 120)
	var ok := after == want and int(g.powerups_caught) == caught_before + 1
	_suite("multiball_times3", ok, "balls %d -> %d (want %d) caught=%d" % [
		before, after, want, int(g.powerups_caught)])


func _check_unbreakable_border(g: Node) -> void:
	# The solid border (level_02's grey ring) is a wall: a ball hitting it
	# bounces off and breaks nothing — no brick removed, no score, no count.
	var cell := Vector2i(10, 49)
	var before := int(g.bricks_left)
	var score_before := int(g.score)
	var is_wall := bool(g.is_unbreakable(cell))
	g.debug_clear_balls()
	var at: Vector2 = g.cell_center(cell) + Vector2(0, 16)
	var b: Ball = g.debug_spawn_ball(at, Vector2(0, -350))
	var bounced := false
	for i in 20:
		await get_tree().physics_frame
		if not is_instance_valid(b) or not b.active:
			break
		if b.vel.y > 0.0:
			bounced = true
			break
	var still_there: bool = g._bodies.has(cell) and bool((g._bodies[cell] as Brick).live)
	var ok: bool = is_wall and bounced and still_there \
		and int(g.bricks_left) == before and int(g.score) == score_before
	_suite("unbreakable_border", ok, "cell=%s wall=%s bounced=%s still_live=%s bricks=%d->%d score=%d->%d" % [
		str(cell), str(is_wall), str(bounced), str(still_there),
		before, int(g.bricks_left), score_before, int(g.score)])
	if is_instance_valid(b):
		b.active = false
		b.queue_free()
	g.debug_clear_balls()
	g.debug_ensure_playing()


func _check_win(g: Node) -> void:
	var ended: Array = []
	g.game_ended.connect(func(res: Dictionary) -> void: ended.append(res))
	# Stage B freeze check: balls and a falling power-up are in the world when the
	# last brick goes, and NOTHING may move or score after the popup appears (the
	# defect was popup 18700 vs HUD 18850).
	g.debug_clear_balls()
	for i in 3:
		g.debug_spawn_ball(Vector2(80 + i * 180, 700), Vector2(0, -420))
	g.debug_spawn_powerup_at_paddle("plus3")
	g.debug_ensure_playing()
	await get_tree().physics_frame
	g.debug_clear_all_bricks()
	await get_tree().process_frame
	await get_tree().physics_frame
	await get_tree().physics_frame
	var frozen_score := int(g.score)
	for i in 30:
		await get_tree().physics_frame
	var still_frozen: bool = int(g.score) == frozen_score \
		and int(g.ball_count()) == 0 and int(g.powerup_count()) == 0
	var ok := str(g.state) == "level_clear" and ended.size() == 1 \
		and bool((ended[0] as Dictionary).get("won", false)) \
		and int((ended[0] as Dictionary).get("score", -1)) == frozen_score \
		and still_frozen
	_suite("win_state", ok,
		"state=%s ends=%d bricks_left=%d score=%d frozen=%s balls=%d powerups=%d" % [
			str(g.state), ended.size(), int(g.bricks_left), frozen_score,
			str(still_frozen), int(g.ball_count()), int(g.powerup_count())])


func _check_lose(g: Node) -> void:
	var ended: Array = []
	g.game_ended.connect(func(res: Dictionary) -> void: ended.append(res))
	g.lives = 1
	g.debug_clear_balls()
	for i in 5:
		await get_tree().physics_frame
	var ok := str(g.state) == "game_over" and ended.size() == 1 \
		and not bool((ended[0] as Dictionary).get("won", true))
	_suite("lose_state", ok, "state=%s ends=%d lives=%d" % [
		str(g.state), ended.size(), int(g.lives)])


# ------------------------------------------------------------------ Stage B power-ups
## The orange "minus" removes exactly ONE ball and does nothing at one ball (so
## the debuff can never end a take by itself).
func _check_powerup_minus(g: Node) -> void:
	g.debug_ensure_playing()
	g.debug_clear_balls()
	for i in 3:
		g.debug_spawn_ball(Vector2(270, 600), Vector2(0, -420))
	g.debug_ensure_playing()
	await get_tree().physics_frame
	var before := int(g.ball_count())
	g.debug_spawn_powerup_at_paddle("minus")
	for i in 8:
		await get_tree().physics_frame
	var after := int(g.ball_count())
	# one ball left: the debuff must be inert
	g.debug_clear_balls()
	g.debug_spawn_ball(Vector2(270, 600), Vector2(0, -420))
	g.debug_ensure_playing()
	await get_tree().physics_frame
	var one := int(g.ball_count())
	g.debug_spawn_powerup_at_paddle("minus")
	for i in 8:
		await get_tree().physics_frame
	var still := int(g.ball_count())
	var ok := before == 3 and after == 2 and one == 1 and still == 1
	_suite("powerup_minus", ok, "balls %d -> %d ; at one ball %d -> %d" % [
		before, after, one, still])
	g.debug_clear_balls()
	g.debug_spawn_ball(Vector2(270, 600), Vector2(0, -420))
	g.debug_ensure_playing()


## The yellow star pays the flat bonus, triples brick score while it runs and
## expires after 5 s.
func _check_powerup_star(g: Node) -> void:
	g.debug_ensure_playing()
	g.debug_clear_balls()
	g.debug_spawn_ball(Vector2(270, 600), Vector2(0, -420))
	g.debug_ensure_playing()
	await get_tree().physics_frame
	var score0 := int(g.score)
	g.debug_spawn_powerup_at_paddle("star")
	for i in 8:
		await get_tree().physics_frame
	var bonus := int(g.score) - score0
	var mult_on := int(g.score_mult) == 3 and float(g.star_left) > 0.0
	# a brick broken while the star is active scores x3
	var target := Vector2i(-1, -1)
	for c in g._bodies.keys():
		var cellc: Vector2i = c
		if (g._bodies[c] as Brick).unbreakable:
			continue
		target = cellc
		break
	var scored := 0
	if target.x >= 0:
		var s0 := int(g.score)
		g.break_cell(target)
		scored = int(g.score) - s0
	# expiry: physics runs at 60 Hz, so 5 s is ~300 frames
	var frames := 0
	while int(g.score_mult) > 1 and frames < 480:
		if int(g.ball_count()) == 0:
			g.debug_spawn_ball(Vector2(270, 600), Vector2(0, -420))
		g.debug_ensure_playing()
		await get_tree().physics_frame
		frames += 1
	var seconds := float(frames) / 60.0
	var ok := bonus == 250 and mult_on and scored == 30 \
		and int(g.score_mult) == 1 and seconds >= 4.0 and seconds <= 6.0
	_suite("powerup_star", ok, "bonus=%d mult_on=%s brick_x3=%d expired_after=%.2fs mult=%d" % [
		bonus, str(mult_on), scored, seconds, int(g.score_mult)])


## The drop pool: measured rates over a fixed-seed sample of the SAME picker
## gameplay uses (+3 60%, x3 25%, minus 10%, star 5%).
func _check_drop_pool(g: Node) -> void:
	var n := 2000
	var counts := {"plus3": 0, "times3": 0, "minus": 0, "star": 0}
	g.rng.seed = 20261116
	for i in n:
		counts[g._pick_powerup_kind()] += 1
	var r_plus := float(counts["plus3"]) / float(n)
	var r_times := float(counts["times3"]) / float(n)
	var r_minus := float(counts["minus"]) / float(n)
	var r_star := float(counts["star"]) / float(n)
	var ok := absf(r_plus - 0.60) < 0.04 and absf(r_times - 0.25) < 0.04 \
		and absf(r_minus - 0.10) < 0.03 and absf(r_star - 0.05) < 0.02
	_suite("drop_pool", ok, "plus3=%.1f%% times3=%.1f%% minus=%.1f%% star=%.1f%% (n=%d)" % [
		r_plus * 100.0, r_times * 100.0, r_minus * 100.0, r_star * 100.0, n])


# ------------------------------------------------------------------ editor
func _suite_editor() -> void:
	var dir := "user://breakout_editor_test"
	var ed: Node = load("res://scenes/editor.tscn").instantiate()
	add_child(ed)
	await get_tree().process_frame

	# --- paint a cell -> the grid holds the colour; erase -> the cell is empty
	ed.new_level(20, 26)
	var c := Vector2i(5, 4)
	ed.paint_cell(c, Color(0.8, 0.2, 0.2))
	var painted: bool = (ed.colour_at(c) as Color).is_equal_approx(Color(0.8, 0.2, 0.2))
	ed.add_tip(c)
	var tip_set: bool = (ed.tips() as Array).has(c)
	ed.erase_cell(c)
	var erased: bool = float((ed.colour_at(c) as Color).a) < 0.5
	_suite("editor_paint", painted and erased and tip_set,
		"paint=%s tip=%s erase=%s" % [str(painted), str(tip_set), str(erased)])

	# --- save -> PNG + JSON round-trip through the real LevelLoader
	ed.new_level(20, 26)
	for r in 26:
		for cc in 20:
			ed.paint_cell(Vector2i(cc, r), Color(0.55, 0.30, 0.30))
	ed.set_border_solid(true)
	ed.carve_at(Vector2i(10, 18))
	ed.level_id = "editor_roundtrip"
	var saved: Dictionary = ed.save_to(dir)
	var counts: Dictionary = ed.counts()
	var lv: Dictionary = BreakoutLevel.load_level(str(saved.get("json", "")))
	var round_trip: bool = bool(saved.get("ok", false)) and bool(lv.get("ok", false)) \
		and int(lv.get("bricks", -1)) == int(counts["bricks"]) \
		and int(lv.get("breakable", -1)) == int(counts["breakable"]) \
		and int(lv.get("unbreakable", -1)) == int(counts["unbreakable"]) \
		and int((lv.get("channel_cells", []) as Array).size()) > 20 \
		and int((lv.get("powerup_cells", []) as Array).size()) == 2
	_suite("editor_save_roundtrip", round_trip,
		"editor=%d/%d/%d loader=%d/%d/%d channel=%d tips=%d json=%s" % [
			int(counts["bricks"]), int(counts["breakable"]), int(counts["unbreakable"]),
			int(lv.get("bricks", -1)), int(lv.get("breakable", -1)), int(lv.get("unbreakable", -1)),
			int((lv.get("channel_cells", []) as Array).size()),
			int((lv.get("powerup_cells", []) as Array).size()), str(saved.get("dir", ""))])

	# --- SAVE writes the pair into the project's level folder when it is writable
	# (a dev run), and falls back to user:// when res:// is read-only. The probe
	# level is deleted again so a dev run leaves nothing behind.
	ed.new_level(20, 26)
	for r in 26:
		for cc in 20:
			ed.paint_cell(Vector2i(cc, r), Color(0.45, 0.30, 0.30))
	ed.level_id = "editor_probe_save"
	var res_save: Dictionary = ed.save_to("")
	var probe_json := str(res_save.get("json", ""))
	var probe_png := str(res_save.get("png", ""))
	var wrote: bool = bool(res_save.get("ok", false)) \
		and FileAccess.file_exists(probe_json) and FileAccess.file_exists(probe_png)
	for p in [probe_json, probe_png]:
		if str(p) != "" and FileAccess.file_exists(str(p)):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(str(p)))
	var cleaned: bool = probe_json != "" and not FileAccess.file_exists(probe_json)
	_suite("editor_save_location", wrote and cleaned, "dir=%s pair_written=%s cleaned=%s" % [
		str(res_save.get("dir", "")), str(wrote), str(cleaned)])

	# --- save WITHOUT a channel is refused, with a reason
	var ed2: Node = load("res://scenes/editor.tscn").instantiate()
	add_child(ed2)
	await get_tree().process_frame
	ed2.new_level(20, 26)
	ed2.level_id = "editor_no_channel"
	for r in 8:
		for cc in 8:
			ed2.paint_cell(Vector2i(cc + 2, r + 2), Color(0.6, 0.3, 0.3))
	ed2.clear_channel()
	var refused: Dictionary = ed2.save_to(dir)
	var refused_ok: bool = not bool(refused.get("ok", true)) \
		and str(refused.get("err", "")).to_lower().contains("channel")
	_suite("editor_refuse_no_channel", refused_ok, "err=%s" % str(refused.get("err", "")))
	ed2.queue_free()

	# --- a shipped level loads back into the editor: bricks + channel + border
	var loaded: bool = ed.load_level_id("level_02_jensen")
	var cnt: Dictionary = ed.counts()
	var shipped_ok: bool = loaded and int(cnt["bricks"]) == 1898 \
		and int(cnt["breakable"]) == 1724 and int(cnt["unbreakable"]) == 174 \
		and ed.is_channel_cell(Vector2i(20, 40)) and ed.is_border_solid()
	_suite("editor_load_shipped", shipped_ok,
		"bricks=%d breakable=%d unbreakable=%d channel_shown=%s border=%s" % [
			int(cnt["bricks"]), int(cnt["breakable"]), int(cnt["unbreakable"]),
			str(ed.is_channel_cell(Vector2i(20, 40))), str(ed.is_border_solid())])

	# --- PLAY from the editor starts the game on the edited level
	ed.new_level(20, 26)
	for r in 26:
		for cc in 20:
			ed.paint_cell(Vector2i(cc, r), Color(0.5, 0.35, 0.35))
	ed.level_id = "editor_play_level"
	var played: Dictionary = ed.play()
	for i in 30:
		await get_tree().process_frame
	var scene: Node = get_tree().current_scene
	var play_ok: bool = bool(played.get("ok", false)) and scene != null \
		and scene.has_signal("game_ended") and int(scene.bricks_left) > 0 \
		and str(Game.level_id) == "editor_play_level"
	_suite("editor_play", play_ok, "ok=%s scene=%s level=%s bricks_left=%d" % [
		str(played.get("ok", false)),
		("game" if scene != null and scene.has_signal("game_ended") else str(scene)),
		str(Game.level_id),
		int(scene.bricks_left) if scene != null and scene.has_signal("game_ended") else -1])

	await _report("WR_BREAKOUT_EDITOR_RESULT", _fails == 0, "failing suites: %d" % _fails)


# ------------------------------------------------------------------ smoke
func _suite_smoke() -> void:
	var ok := true
	var detail := ""
	var menu: Node = get_tree().current_scene
	var buttons := 0
	if menu != null:
		for n in menu.find_children("*", "Button", true, false):
			buttons += 1
	ok = ok and menu != null and buttons >= 5
	detail += "menu_buttons=%d " % buttons

	var game: Node = await _new_game()
	ok = ok and int(game.bricks_left) > 900 and game.hud != null and game.paddle != null
	detail += "bricks=%d balls=%d state=%s" % [
		int(game.bricks_left), int(game.ball_count()), str(game.state)]
	await _report("WR_BREAKOUT_SMOKE_RESULT", ok, detail)


# ------------------------------------------------------------------ pacing
func _suite_pace() -> void:
	Game.auto_play = true
	Engine.time_scale = 6.0
	var g: Node = await _new_game()
	var ended: Array = []
	g.game_ended.connect(func(res: Dictionary) -> void: ended.append(res))
	g.debug_force_play()
	var t0 := Time.get_ticks_msec()
	var first_mb := -1.0
	var peak := 0
	var next_trace := 5.0
	while ended.is_empty() and float(g.elapsed) < 140.0 and Time.get_ticks_msec() - t0 < 240000:
		await get_tree().process_frame
		if first_mb < 0.0 and float(g.first_multiball_at) > 0.0:
			first_mb = float(g.first_multiball_at)
		peak = maxi(peak, int(g.ball_count()))
		if float(g.elapsed) >= next_trace:
			next_trace += 5.0
			print("WR_BREAKOUT_PACE_TRACE t=%.0f balls=%d bricks=%d lives=%d score=%d y=%.0f" % [
				float(g.elapsed), int(g.ball_count()), int(g.bricks_left), int(g.lives),
				int(g.score),
				float(g._balls[0].position.y) if not (g._balls as Array).is_empty() else -1.0])
	Engine.time_scale = 1.0
	var won := ended.size() == 1 and bool((ended[0] as Dictionary).get("won", false))
	print("WR_BREAKOUT_PACE cleared=%s elapsed=%.1f first_multiball=%.1f peak_balls=%d score=%d bricks_total=%d" % [
		str(won), float(g.elapsed), first_mb, maxi(peak, int(g.peak_balls)), int(g.score),
		int(g.bricks_total)])
	await _report("WR_BREAKOUT_PACE_RESULT", won, "cleared at %.1fs" % float(g.elapsed))


# ------------------------------------------------------------------ recording
func _suite_record() -> void:
	Game.auto_play = true
	Game.menu_seed_idx = 0                    # seed 1
	# Optional level selection: --breakout-record level=level_02_jensen
	# (default: the menu's current level, index 0). Lets a take be recorded
	# for any registered level without touching the menu.
	# A level the editor saved (res://data/levels or user://levels) is recordable
	# by id too, so an editor-built level can produce a take.
	var custom_id := ""
	var custom_json := ""
	for a in _args:
		if str(a).begins_with("level="):
			var want := str(a).trim_prefix("level=")
			var idx := Game.LEVELS.find(want)
			if idx >= 0:
				Game.menu_level_idx = idx
			else:
				var jp := BreakoutLevelWriter.find_json(want)
				if jp != "":
					custom_id = want
					custom_json = jp
	if custom_id != "":
		Game.start_level(custom_id, 1, custom_json)
	else:
		Game.start_game(1)
	var game: Node = null
	for i in 120:
		await get_tree().process_frame
		var s: Node = get_tree().current_scene
		if s != null and s.has_signal("game_ended"):
			game = s
			break
	if game == null:
		await _report("WR_BREAKOUT_RECORD_RESULT", false, "game scene did not load")
		return
	var r: Dictionary = RecordSession.begin(true)
	if not bool(r.get("ok", false)):
		await _report("WR_BREAKOUT_RECORD_RESULT", false,
			"recorder refused: %s" % str(r.get("err", "")))
		return
	var t0 := Time.get_ticks_msec()
	while RecordSession.state != RecordSession.STATE_SAVED \
			and RecordSession.state != RecordSession.STATE_ERROR:
		if Time.get_ticks_msec() - t0 > 300000:
			break
		await get_tree().create_timer(1.0).timeout
	var res: Dictionary = GameRecorder.last_result
	var ok := RecordSession.state == RecordSession.STATE_SAVED \
		and str(res.get("path", "")) != ""
	print("WR_BREAKOUT_RECORD path=%s frames=%d size=%dx%d fps=%d format=%s" % [
		str(res.get("path", "")), int(res.get("frames", 0)), int(res.get("width", 0)),
		int(res.get("height", 0)), int(res.get("fps", 0)), str(res.get("format", ""))])
	await _report("WR_BREAKOUT_RECORD_RESULT", ok,
		"take saved" if ok else "recording failed: %s" % str(RecordSession.last_error))
