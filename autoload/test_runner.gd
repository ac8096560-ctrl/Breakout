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
	elif _args.has("--breakout-sim"):
		call_deferred("_suite_sim")
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
	await _check_apk_loader()

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
	await _check_nuke(g)
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

	# ---------------- Stage C (Brief 20) ----------------------------------
	Game.level_id = "level_01_portrait"
	await _check_level03()

	var g4: Node = await _new_game()
	g4.debug_force_play()
	await _check_times3_in_place(g4)
	await _check_times3_cap(g4)
	await _check_combo(g4)
	g4.queue_free()
	await get_tree().process_frame

	var g5: Node = await _new_game()
	g5.debug_force_play()
	await _check_safety_floor(g5)
	g5.queue_free()
	await get_tree().process_frame

	var g6: Node = await _new_game()
	g6.debug_force_play()
	await _check_stars(g6)
	g6.queue_free()
	await get_tree().process_frame

	var g7: Node = await _new_game()
	g7.debug_force_play()
	await _check_stars_three(g7)
	g7.queue_free()
	await get_tree().process_frame

	await _report("WR_BREAKOUT_RESULT", _fails == 0, "failing suites: %d" % _fails)


func _check_level_load() -> void:
	# Every registered level must load and satisfy the design rules (enough
	# bricks, a carved channel, two power-up tips, a real palette, and an
	# empty channel). Adding a level to Game.LEVELS automatically tests it.
	var all_ok := true
	var details: Array[String] = []
	for level_id in Game.SHIPPED_LEVELS:
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
				and int(lv["breakable"]) > 900 \
				and int(lv["stranded_breakable"]) == 0
			# Brief 23 B: level_02's GREY frame is solid without being listed — its
			# 174 listed cells plus the 71 grey bricks in the picture's frame band
			# (245 solid / 1653 breakable). The first version of this rule took the
			# photo's whole grey BACKGROUND (670 cells, one edge-reaching region)
			# and left 44 bricks unreachable: the level could not be won at all.
			if level_id == "level_02_jensen":
				ok = ok and int(lv["unbreakable"]) == 245 and int(lv["breakable"]) == 1653 \
					and int(lv["unbreakable_from_list"]) == 174 \
					and int(lv["unbreakable_from_grey"]) == 71
			# ...and the rule must NOT touch the PORTRAIT: every solid cell of
			# level_04 comes from its explicit list, none from the grey rule (its
			# neutral pixels are skin and hair shading inside the picture).
			if level_id == "level_04_ronaldo":
				ok = ok and int(lv["unbreakable"]) == 994 \
					and int(lv["unbreakable_from_grey"]) == 0
			detail = "%s bricks=%d breakable=%d unbreakable=%d channel=%d colours=%d tips=%d" % [
				level_id, int(lv["bricks"]), int(lv["breakable"]), int(lv["unbreakable"]),
				int(lv["channel_cells"].size()), colours.size(),
				int(lv["powerup_cells"].size())]
		if not ok:
			all_ok = false
		details.append(detail)
	_suite("level_load", all_ok, " | ".join(details))


# ---------------------------------------------------------------- Brief 22
## Task 1 — THE APK LOADER PATH. On Android every res:// file is packed INSIDE
## the APK, so ProjectSettings.globalize_path() + Image.load_from_file() returns
## null and every level failed to load (ok:false, "cannot decode png") in the
## built APK. This check goes through the bytes path the game now uses for the
## four shipped levels and prints ok + bricks/breakable for each, plus a PNG
## that is NOT the level's pixel size (it must be scaled, never rejected).
func _check_apk_loader() -> void:
	var all_ok := true
	var details: Array[String] = []
	for level_id in Game.SHIPPED_LEVELS:
		var json_path := BreakoutLevelWriter.find_json(level_id)
		var lv := BreakoutLevel.load_level(json_path)
		var ok := json_path != "" and bool(lv.get("ok", false))
		var img: Image = null
		if ok:
			img = BreakoutLevel.load_png_image(str(lv["image"]))
			ok = img != null and img.get_width() == int(lv["cols"]) \
				and img.get_height() == int(lv["rows"])
			ok = ok and int(lv["bricks"]) > 900 and int(lv["breakable"]) > 0
		details.append("%s ok=%s bricks=%d breakable=%d" % [
			level_id, str(ok), int(lv.get("bricks", 0)), int(lv.get("breakable", 0))])
		if not ok:
			all_ok = false
	# A hand-made PNG whose pixel size does not match the level grid: the
	# loader must STRETCH it onto the grid instead of failing, which is what
	# keeps old/imported art playable (Task 2).
	var probe_dir := "user://breakout_apk_probe"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(probe_dir))
	var small := Image.create(10, 12, false, Image.FORMAT_RGBA8)
	small.fill(Color(0.6, 0.3, 0.3, 1.0))
	small.save_png(probe_dir.path_join("portrait.png"))
	var body := {
		"id": "apk_probe", "display_name": "PROBE", "image": "portrait.png",
		"cols": 20, "rows": 26, "cell": 12.0, "origin": [30, 64],
		"channel": {"fork": [10, 18], "stem_cols": [10, 11], "stem_bottom": 25,
			"arm_width": 3, "arms": [[4, 8], [16, 8]]},
		"powerup_tips": [[4, 8], [16, 8]], "unbreakable_cells": [],
	}
	var f := FileAccess.open(probe_dir.path_join("apk_probe.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(body))
	f.close()
	var probe := BreakoutLevel.load_level(probe_dir.path_join("apk_probe.json"))
	var scaled_ok := bool(probe.get("ok", false)) \
		and int(probe["cols"]) == 20 and int(probe["rows"]) == 26 \
		and (probe["grid"] as Array).size() == 20 * 26 and int(probe["bricks"]) > 300
	details.append("mismatched png 10x12 -> grid 20x26 ok=%s bricks=%d" % [
		str(scaled_ok), int(probe.get("bricks", 0))])
	all_ok = all_ok and scaled_ok
	_suite("apk_level_loader", all_ok, " | ".join(details))


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
	var cap := int(g.ball_cap())
	var want := mini(before * 3, cap)
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
## expires after 5 s. The Stage C combo is reset first: this suite measures the
## STAR multiplier on ONE brick, not the chain that brick happened to join.
func _check_powerup_star(g: Node) -> void:
	g.debug_ensure_playing()
	g.debug_clear_balls()
	g.debug_spawn_ball(Vector2(270, 600), Vector2(0, -420))
	g.debug_ensure_playing()
	g.debug_reset_combo()
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
	g.debug_reset_combo()
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
## gameplay uses. Brief 22 pool: +3 54%, x3 20%, minus 10%, star 5%,
## floor 10%, NUKE 2%.
func _check_drop_pool(g: Node) -> void:
	var n := 2000
	var counts := {"plus3": 0, "times3": 0, "minus": 0, "star": 0, "floor": 0, "nuke": 0}
	g.rng.seed = 20261116
	for i in n:
		counts[g._pick_powerup_kind()] += 1
	var r_plus := float(counts["plus3"]) / float(n)
	# --- the cap the pool is measured against lives in the game, not here
	var r_times := float(counts["times3"]) / float(n)
	var r_minus := float(counts["minus"]) / float(n)
	var r_star := float(counts["star"]) / float(n)
	var r_floor := float(counts["floor"]) / float(n)
	var r_nuke := float(counts["nuke"]) / float(n)
	var total := r_plus + r_times + r_minus + r_star + r_floor + r_nuke
	var ok := absf(r_plus - 0.53) < 0.04 and absf(r_times - 0.20) < 0.04 \
		and absf(r_minus - 0.10) < 0.03 and absf(r_star - 0.05) < 0.02 \
		and absf(r_floor - 0.10) < 0.03 and absf(r_nuke - 0.02) < 0.015 \
		and absf(total - 1.0) < 0.001
	_suite("drop_pool", ok, "plus3=%.1f%% times3=%.1f%% minus=%.1f%% star=%.1f%% floor=%.1f%% nuke=%.1f%% sum=%.3f (n=%d)" % [
		r_plus * 100.0, r_times * 100.0, r_minus * 100.0, r_star * 100.0,
		r_floor * 100.0, r_nuke * 100.0, total, n])


## Brief 22 — the NUKE. One catch breaks EVERY breakable brick inside the
## blast radius of the lowest remaining brick, through the real break_cell
## path (so bricks_left/score/drops/WIN all agree), and never breaks a wall.
func _check_nuke(g: Node) -> void:
	# No ball may be in flight while the blast count is computed: a stray ball
	# that broke a brick in between would make expect != broke for a reason
	# that has nothing to do with the nuke.
	g.debug_clear_balls()
	await get_tree().physics_frame
	g.debug_ensure_playing()
	g.debug_clear_powerups()
	g.debug_ensure_playing()
	var blast: Vector2i = g._nuke_blast_cell()
	var r := int(g.NUKE_RADIUS)
	var expect := 0
	var lowest := -1
	var walls_before := 0
	for c in g._bodies.keys():
		var cellp: Vector2i = c
		var b: Brick = g._bodies[c]
		if b.unbreakable:
			walls_before += 1
			continue
		lowest = maxi(lowest, cellp.y)
		var dx := absi(cellp.x - blast.x)
		var dy := absi(cellp.y - blast.y)
		if dx * dx + dy * dy <= r * r:
			expect += 1
	var before := int(g.bricks_left)
	g.debug_spawn_powerup_at_paddle("nuke")
	for i in 8:
		await get_tree().physics_frame
	var broke := before - int(g.bricks_left)
	var walls_after := 0
	for c2 in g._bodies.keys():
		if (g._bodies[c2] as Brick).unbreakable:
			walls_after += 1
	var ok := int(g.nukes_caught) == 1 and broke == expect and expect > 100 \
		and walls_after == walls_before and int(g.nuke_bricks) == broke \
		and blast.y == lowest
	_suite("powerup_nuke", ok,
		"blast=%s (lowest=%d) broke=%d expected=%d caught=%d walls %d->%d telemetry=%d" % [
			str(blast), lowest, broke, expect, int(g.nukes_caught),
			walls_before, walls_after, int(g.nuke_bricks)])
	g.debug_clear_powerups()
	g.debug_ensure_playing()


# ================================================================== Stage C
# Brief 20: x3 in-place split, 3-star collectible, safety floor, the solid
# guide-path level and the combo chain.

## The y of the open black strip between the field's bottom edge and the paddle
## (Brief 25 moved both). A parked / keep-alive ball lives there: below every
## brick, above the paddle, so it cannot break anything or get caught while a
## suite measures something else. Derived, never a fixed 700 — the field bottom
## is cols*cell tall now, so a hard-coded y would land inside the grid.
func _open_band_y(g: Node, below := 36.0) -> float:
	return float(g.origin.y + float(g.rows) * g.cell) + below


## A ball parked BELOW the brick field moving sideways: it keeps the flow in
## STATE_PLAYING (so the timers tick) without ever breaking a brick.
func _park_ball(g: Node) -> void:
	g.debug_clear_balls()
	g.debug_clear_powerups()
	g.debug_spawn_ball(Vector2(270.0, _open_band_y(g)), Vector2(60.0, 0.0))
	g.debug_ensure_playing()


func _cells_to_break(g: Node, n: int) -> Array:
	var out: Array = []
	for c in g._bodies.keys():
		if out.size() >= n:
			break
		if (g._bodies[c] as Brick).unbreakable:
			continue
		out.append(c)
	return out


## --- item 1: x3 = Ball Multitude, an IN-PLACE split ----------------------
func _check_times3_in_place(g: Node) -> void:
	g.auto_play = false
	g.debug_ensure_playing()
	g.debug_clear_balls()
	var at := Vector2(270.0, 520.0)
	var parent: Ball = g.debug_spawn_ball(at, Vector2(0, -420))
	var vel0 := parent.vel
	var added := int(g._split_balls_in_place())
	var count := int(g.ball_count())
	var same_pos := true
	var speeds_ok := true
	var vels: Array = []
	for x in g._balls:
		var bb := x as Ball
		if not is_instance_valid(bb):
			continue
		if bb.position.distance_to(at) > 0.01:
			same_pos = false
		if absf(bb.speed() - 420.0) > 0.5:
			speeds_ok = false
		vels.append(bb.vel)
	var distinct := vels.size() == 3 \
		and (vels[0] as Vector2).is_equal_approx(vel0) \
		and not (vels[1] as Vector2).is_equal_approx(vels[0] as Vector2) \
		and not (vels[2] as Vector2).is_equal_approx(vels[0] as Vector2) \
		and not (vels[1] as Vector2).is_equal_approx(vels[2] as Vector2)
	# divergence: half a second later the trio is spread out instead of stacked
	for i in 30:
		await get_tree().physics_frame
	var spread := 0.0
	if g._balls.size() == 3:
		var p0: Vector2 = (g._balls[0] as Ball).position
		spread = maxf(spread, p0.distance_to((g._balls[1] as Ball).position))
		spread = maxf(spread, p0.distance_to((g._balls[2] as Ball).position))
	var ok := added == 2 and count == 3 and same_pos and speeds_ok and distinct \
		and spread > 20.0
	_suite("times3_in_place", ok,
		"1 ball -> %d (added %d) same_pos=%s same_speed=%s distinct_vels=%s spread=%.1fpx after 0.5s" % [
			count, added, str(same_pos), str(speeds_ok), str(distinct), spread])


func _check_times3_cap(g: Node) -> void:
	g.auto_play = false
	g.debug_ensure_playing()
	g.debug_clear_balls()
	# Start above 1/3 of the cap so the split MUST be clipped by it (the
	# reference cap is 120, so 100 balls ask for 300).
	for i in 100:
		g.debug_spawn_ball(Vector2(60.0 + float(i % 20) * 20.0, 600.0 - float(i / 20) * 12.0),
			Vector2(0, -420))
	g.debug_ensure_playing()
	var before := int(g.ball_count())
	var added := int(g._split_balls_in_place())
	var after := int(g.ball_count())
	g.debug_clear_balls()
	var cap := int(g.ball_cap())
	var ok := before == 100 and after == cap and added == cap - 100
	_suite("times3_cap", ok, "balls %d -> %d (added %d, cap %d)" % [before, after, added, cap])


## --- item 5: the combo chain --------------------------------------------
func _check_combo(g: Node) -> void:
	g.auto_play = false
	g.lives = 3
	_park_ball(g)
	await get_tree().physics_frame
	g.debug_reset_combo()
	var cells := _cells_to_break(g, 10)
	if cells.size() < 10:
		_suite("combo_chain", false, "not enough bricks")
		return
	var s0 := int(g.score)
	g.break_cell(cells[0], true)
	var d1 := int(g.score) - s0
	var c1 := int(g.combo)
	var window := float(g._combo_left)
	g.break_cell(cells[1], true)
	var d2 := int(g.score) - s0 - d1
	var c2 := int(g.combo)
	g.break_cell(cells[2], true)
	var d3 := int(g.score) - s0 - d1 - d2
	var c3 := int(g.combo)
	# --- the HUD, measured with NOTHING in play, so no stray ball can extend
	# the chain between the breaks and the frame the HUD renders.
	g.debug_clear_balls()
	g.debug_clear_powerups()
	g.debug_reset_combo()
	g.debug_ensure_playing()
	for i in 5:
		g.break_cell(cells[3 + i], true)
	var c5 := int(g.combo)
	# TWO process frames: `process_frame` is emitted BEFORE the nodes' _process
	# runs, so a single await still shows the previous frame's label.
	await get_tree().process_frame
	await get_tree().process_frame
	var hud_text := str(g.hud.combo_text())
	# --- the 1.2 s window: let it lapse in real physics time, then break again
	_park_ball(g)
	var frames := 0
	while int(g.combo) > 1 and frames < 200:
		g.debug_ensure_playing()
		await get_tree().physics_frame
		frames += 1
	var reset_after := float(frames) / 60.0
	await get_tree().process_frame
	await get_tree().process_frame
	var hud_off := str(g.hud.combo_text()) == ""
	var s1 := int(g.score)
	g.break_cell(cells[8], true)
	var d4 := int(g.score) - s1
	var c6 := int(g.combo)
	var ok := d1 == 10 and c1 == 1 \
		and d2 == 20 and c2 == 2 \
		and d3 == 30 and c3 == 3 \
		and absf(window - 1.2) < 0.03 \
		and c5 == 5 and hud_text == "COMBO x5" \
		and reset_after >= 1.1 and reset_after <= 1.45 \
		and d4 == 10 and c6 == 1 and hud_off
	_suite("combo_chain", ok,
		"scores %d/%d/%d (combo 1/2/3) window=%.2fs | rapid 5 -> combo %d hud=\"%s\" | reset_after=%.2fs then %d (combo %d) hidden_after=%s" % [
			d1, d2, d3, window, c5, hud_text, reset_after, d4, c6, str(hud_off)])


## --- item 3: the safety floor -------------------------------------------
func _floor_nodes(g: Node) -> int:
	var n := 0
	for c in g.get_children():
		if c.name == "SafetyFloor":
			n += 1
	return n


func _check_safety_floor(g: Node) -> void:
	g.auto_play = false
	g.lives = 3
	_park_ball(g)
	g.paddle.move_to_x(270.0)
	await get_tree().physics_frame

	# 1) catching the drop raises the floor for 10 s
	g.debug_spawn_powerup_at_paddle("floor")
	for i in 8:
		await get_tree().physics_frame
	var raised := bool(g.floor_active())
	var left0 := float(g.floor_left())
	var drawn: bool = g._floor.visible
	var one_floor := _floor_nodes(g) == 1

	# 2) it really lasts ~10 s of GAME time, measured from the catch itself
	Engine.time_scale = 6.0
	var t_start := float(g.elapsed)
	var guard := 0
	while bool(g.floor_active()) and guard < 3000:
		g.debug_ensure_playing()
		if int(g.ball_count()) == 0:
			g.debug_spawn_ball(Vector2(270.0, _open_band_y(g)), Vector2(60.0, 0.0))
		await get_tree().physics_frame
		guard += 1
	var lasted := float(g.elapsed) - t_start
	Engine.time_scale = 1.0
	var gone: bool = not bool(g.floor_active()) and not bool(g._floor.visible)

	# 3) raise it again for the bounce tests
	g.debug_ensure_playing()
	g.debug_spawn_powerup_at_paddle("floor")
	for i in 8:
		await get_tree().physics_frame
	var up_again := bool(g.floor_active())

	# 4) a ball aimed STRAIGHT DOWN is bounced back, no life lost
	g.debug_clear_balls()
	var lives0 := int(g.lives)
	var down: Ball = g.debug_spawn_ball(Vector2(80.0, 800.0), Vector2(0.0, 420.0))
	var bounced := false
	for i in 60:
		await get_tree().physics_frame
		if not is_instance_valid(down) or not down.active:
			break
		if down.vel.y < -100.0:
			bounced = true
			break
	var no_loss := int(g.lives) == lives0 and int(g.ball_count()) > 0

	# 5) a falling POWER-UP falls straight through the floor
	var p: PowerUp = g.debug_spawn_powerup_at_paddle("plus3")
	# Start ABOVE the floor and fall PAST it. The threshold is the floor's own Y,
	# not a fixed number, so the check can never go vacuous when the layout moves
	# the bar (it is now at 930, not 880).
	p.position = Vector2(150.0, SafetyFloor.Y - 75.0)
	for i in 70:
		await get_tree().physics_frame
	var through := is_instance_valid(p) and p.alive and p.position.y > SafetyFloor.Y + 10.0
	if is_instance_valid(p):
		p.alive = false
		p.queue_free()

	# 6) a second catch while it is still up REFRESHES the timer (no second floor)
	var first := float(g.floor_left())
	var was_active := bool(g.floor_active())
	for i in 120:
		g.debug_ensure_playing()
		if int(g.ball_count()) == 0:
			g.debug_spawn_ball(Vector2(270.0, _open_band_y(g)), Vector2(60.0, 0.0))
		await get_tree().physics_frame
	var mid := float(g.floor_left())
	g.debug_spawn_powerup_at_paddle("floor")
	for i in 8:
		await get_tree().physics_frame
	var refreshed := float(g.floor_left())
	var one_again := _floor_nodes(g) == 1

	# 7) after it expires a ball can drop again and it costs a life
	Engine.time_scale = 6.0
	var guard2 := 0
	while bool(g.floor_active()) and guard2 < 3000:
		g.debug_ensure_playing()
		if int(g.ball_count()) == 0:
			g.debug_spawn_ball(Vector2(270.0, _open_band_y(g)), Vector2(60.0, 0.0))
		await get_tree().physics_frame
		guard2 += 1
	Engine.time_scale = 1.0
	var lives1 := int(g.lives)
	g.debug_clear_balls()
	g.debug_ensure_playing()
	g.paddle.move_to_x(60.0)
	var fall: Ball = g.debug_spawn_ball(Vector2(400.0, 800.0), Vector2(0.0, 420.0))
	for i in 40:
		await get_tree().physics_frame
		if not is_instance_valid(fall) or not fall.active:
			break
	var dropped := int(g.lives) == lives1 - 1

	var ok: bool = raised and left0 > 9.4 and left0 <= 10.01 and drawn and one_floor \
		and lasted >= 9.4 and lasted <= 10.4 and gone and up_again \
		and bounced and no_loss and through \
		and was_active and first > 3.0 and mid < first - 1.5 \
		and refreshed > 9.4 and one_again and dropped
	_suite("safety_floor", ok,
		"raised=%s left=%.2fs drawn=%s single=%s lasted=%.2fs game-time gone=%s re_raised=%s | " % [
			str(raised), left0, str(drawn), str(one_floor), lasted, str(gone), str(up_again)] \
		+ "bounce=%s no_life_loss=%s powerup_through=%s | refresh %.2f->%.2f->%.2f (was_active=%s single=%s) | expired_drop_costs_life=%s" % [
			str(bounced), str(no_loss), str(through), first, mid, refreshed,
			str(was_active), str(one_again), str(dropped)])
	g.debug_clear_balls()


## --- item 2: the 3-star collectible --------------------------------------
func _catch_star(g: Node, idx := 0) -> bool:
	if g._stars.size() <= idx:
		return false
	var s := g._stars[idx] as StarPickup
	s.position = g.paddle.position + Vector2(0, -4)
	return true


## Put a star PAST the paddle (where the game counts it lost), derived from the
## paddle's own line instead of a fixed y: Brief 25 moved the paddle down to
## 890, so a hard-coded 800 would now sit above it and the star would never be
## missed. Intent is unchanged — the star is off to the side and below the bar.
func _miss_star(g: Node, idx := 0) -> bool:
	if g._stars.size() <= idx:
		return false
	var s := g._stars[idx] as StarPickup
	s.position = Vector2(g.paddle.position.x + 220.0, g.paddle.position.y + 30.0)
	return true


func _check_stars(g: Node) -> void:
	g.auto_play = false
	g.lives = 3
	_park_ball(g)
	g.paddle.move_to_x(270.0)
	await get_tree().physics_frame
	var total := int(g.bricks_total)

	# 1) TIME milestone: 45 s elapsed drops star 1 long before 25 % of the bricks
	g.elapsed = 46.0
	g.debug_break_n(1)
	for i in 3:
		await get_tree().physics_frame
	var time_drop := int(g.star_count()) == 1 and int(g.stars_dropped) == 1
	var frac_at_drop := float(total - int(g.bricks_left)) / float(total)
	var small_frac := frac_at_drop < 0.25
	_catch_star(g, 0)
	for i in 3:
		await get_tree().physics_frame
	var hud1 := str(g.hud.star_display())
	var caught1 := int(g.stars_collected)

	# 2) BRICK milestone: 50 % broken drops star 2, then it is MISSED
	g.debug_break_n(int(ceil(float(total) * 0.5)) - (total - int(g.bricks_left)))
	for i in 3:
		await get_tree().physics_frame
	var brick_drop := int(g.star_count()) == 1 and int(g.stars_dropped) == 2
	_miss_star(g, 0)
	for i in 3:
		await get_tree().physics_frame
	var lost := int(g.stars_lost) == 1 and int(g.stars_collected) == caught1

	# 3) a missed star never re-drops: keep breaking, the milestone stays spent
	g.debug_break_n(20)
	for i in 3:
		await get_tree().physics_frame
	var no_redrop := int(g.stars_dropped) == 2 and int(g.star_count()) == 0

	# 4) 75 % / time milestone 3 still fires, and a catch is kept
	g.elapsed = 136.0
	g.debug_break_n(1)
	for i in 3:
		await get_tree().physics_frame
	var third := int(g.stars_dropped) == 3
	_catch_star(g, 0)
	for i in 3:
		await get_tree().physics_frame
	var hud2 := str(g.hud.star_display())
	var caught2 := int(g.stars_collected)

	# 5) the win popup shows exactly what was collected (2 of 3 here)
	var ended: Array = []
	g.game_ended.connect(func(res: Dictionary) -> void: ended.append(res))
	g.debug_clear_all_bricks()
	await get_tree().process_frame
	await get_tree().physics_frame
	var win_stars := int(g.hud.win_stars())
	var banner := str(g.hud.win_banner_text())
	var res_stars := -1
	if ended.size() == 1:
		res_stars = int((ended[0] as Dictionary).get("stars", -1))
	var ok := time_drop and small_frac and caught1 == 1 and hud1 == "★☆☆" \
		and brick_drop and lost and no_redrop and third \
		and caught2 == 2 and hud2 == "★★☆" \
		and win_stars == 2 and banner == "" and res_stars == 2 \
		and str(g.state) == "level_clear"
	_suite("star_collectible", ok,
		"time_drop=%s (frac %.3f) caught=%d hud=%s | brick_drop=%s missed_lost=%s no_redrop=%s | third=%s caught=%d hud=%s | win=%d banner=\"%s\" result=%d" % [
			str(time_drop), frac_at_drop, caught1, hud1,
			str(brick_drop), str(lost), str(no_redrop), str(third), caught2, hud2,
			win_stars, banner, res_stars])


## Three stars caught, then a win: the "3 STAR!" banner and the count.
func _check_stars_three(g: Node) -> void:
	g.auto_play = false
	g.lives = 3
	_park_ball(g)
	g.paddle.move_to_x(270.0)
	await get_tree().physics_frame
	var total := int(g.bricks_total)
	var marks := [0.25, 0.50, 0.75]
	for frac in marks:
		g.debug_break_n(int(ceil(float(total) * float(frac))) - (total - int(g.bricks_left)))
		for i in 3:
			await get_tree().physics_frame
		_catch_star(g, 0)
		for i in 3:
			await get_tree().physics_frame
	var caught := int(g.stars_collected)
	var hud := str(g.hud.star_display())
	var ended: Array = []
	g.game_ended.connect(func(res: Dictionary) -> void: ended.append(res))
	g.debug_clear_all_bricks()
	await get_tree().process_frame
	await get_tree().physics_frame
	var banner := str(g.hud.win_banner_text())
	var win_stars := int(g.hud.win_stars())
	var res_stars := -1
	if ended.size() == 1:
		res_stars = int((ended[0] as Dictionary).get("stars", -1))
	var ok := caught == 3 and hud == "★★★" \
		and win_stars == 3 and banner == "3 STAR!" and res_stars == 3
	_suite("star_three_win", ok,
		"caught=%d hud=%s win_stars=%d banner=\"%s\" result=%d" % [
			caught, hud, win_stars, banner, res_stars])


## --- item 4: level_03, the solid guide path -----------------------------
func _check_level03() -> void:
	Game.level_id = "level_03_solid_path"
	var g: Node = await _new_game()
	g.debug_force_play()
	g.auto_play = false

	# 1) The trap a real take hit is structurally impossible here: level_03
	# ships ZERO unbreakable cells, so every brick the ball can touch is
	# progress. An unbreakable brick has a horizontal bottom face, the auto-play
	# paddle returns the ball nearly vertically, and the black play floor under
	# that face becomes a permanent ping-pong channel (measured twice: Muse's
	# recorded take under the left margin, and a real-time sim of the
	# walls-to-row-49 build on seed 7, 150 s with 1 brick broken).
	var walls := 0
	for cell in (g._bodies as Dictionary).keys():
		if bool(g.is_unbreakable(cell)):
			walls += 1
	# the brick flanking the carved channel (col 4 is empty art in level_01)
	var guide := Vector2i(8, 20)
	var before := int(g.bricks_left)
	var score_before := int(g.score)
	var broke_cells: Array = []
	g.brick_broken.connect(func(c: Vector2i) -> void: broke_cells.append(c))
	g.debug_clear_balls()
	var b: Ball = g.debug_spawn_ball(g.cell_center(guide) + Vector2(0, 14),
		Vector2(0, -420))
	for i in 24:
		await get_tree().physics_frame
		if not is_instance_valid(b) or not b.active:
			break
		if not broke_cells.is_empty():
			break
	var broke := not broke_cells.is_empty()
	var first := Vector2i(-1, -1)
	if broke:
		first = broke_cells[0]
	# the brick the ball touched must be GONE from the body map (it really was
	# breakable) and the break must have scored exactly one brick
	var gone: bool = broke and not (g._bodies as Dictionary).has(first)
	var gained: bool = int(g.score) > score_before
	var one: bool = int(g.bricks_left) == before - 1

	_suite("level03_no_unbreakable", walls == 0 and broke and gone and gained and one,
		"unbreakable_cells=%d touched=%s broke=%s removed=%s scored=%s one=%s" % [
			walls, str(first), str(broke), str(gone), str(gained), str(one)])

	# 2) the channel delivers the ball to the portrait, in two steps.
	# GDScript lambdas capture by VALUE, so the recorded breaks go into an
	# Array (a reference type) instead of into local ints.
	var hits: Array = []
	g.brick_broken.connect(func(c: Vector2i) -> void: hits.append(c))
	var entry_x := float(g.origin.x + (float(g.level["stem_cols"][0])
		+ float(g.level["stem_cols"][1]) + 1.0) * g.cell * 0.5)
	# (a) a ball served up the doorway breaks the corridor's mouth first
	g.debug_clear_balls()
	g.debug_clear_powerups()
	g.debug_ensure_playing()
	g.debug_spawn_ball(Vector2(entry_x, _open_band_y(g, 74.0)), Vector2(0, -420))
	for i in 200:
		g.lives = 3
		if int(g.ball_count()) == 0:
			g.debug_spawn_ball(Vector2(entry_x, _open_band_y(g, 74.0)), Vector2(0, -420))
		g.debug_ensure_playing()
		await get_tree().physics_frame
		if not hits.is_empty():
			break
	var mouth := Vector2i(-1, -1)
	if not hits.is_empty():
		mouth = hits[0]
	# the mouth is cols 5..7 at the portrait's lower-left edge (rows 43..49)
	var via_mouth := mouth.x >= 5 and mouth.x <= 7 and mouth.y >= 43
	# (b) a ball inside the carved corridor climbs it into the portrait
	g.debug_clear_balls()
	g.debug_clear_powerups()
	g.debug_ensure_playing()
	hits.clear()
	g.debug_spawn_ball(Vector2(entry_x, 480.0), Vector2(0, -420))
	var deepest := 99
	var deep_cell := Vector2i(-1, -1)
	for i in 200:
		g.lives = 3
		if int(g.ball_count()) == 0:
			g.debug_spawn_ball(Vector2(entry_x, 480.0), Vector2(0, -420))
		g.debug_ensure_playing()
		await get_tree().physics_frame
		for h in hits:
			var hc: Vector2i = h
			if hc.y < deepest:
				deepest = hc.y
				deep_cell = hc
		if deepest <= 16:
			break
	# the corridor's far end is the portrait's left cheek (rows 9..15, col 6..7)
	var in_portrait := deepest <= 16 and deep_cell.x >= 5 and deep_cell.x <= 7
	_suite("level03_guide_path", via_mouth and in_portrait,
		"entry_x=%.1f first_break=%s via_channel_mouth=%s | corridor climb: deepest=%s row=%d reaches_portrait=%s" % [
			entry_x, str(mouth), str(via_mouth), str(deep_cell), deepest, str(in_portrait)])
	g.queue_free()
	await get_tree().process_frame
	Game.level_id = "level_01_portrait"


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
	# Brief 23 B: the editor PREVIEW must agree with the loader — its grey frame
	# is solid (245 solid / 1653 breakable), not the old manual 174 / 1724.
	var shipped_ok: bool = loaded and int(cnt["bricks"]) == 1898 \
		and int(cnt["breakable"]) == 1653 and int(cnt["unbreakable"]) == 245 \
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

	await _check_editor_import(ed)
	await _check_grey_frame()

	await _report("WR_BREAKOUT_EDITOR_RESULT", _fails == 0, "failing suites: %d" % _fails)


## Task 2 — IMPORT ANY ART. A 37x91 image (neither the grid nor an aspect the
## grid shares) is stretched onto a 20x26 grid, saved as the standard pair and
## loaded back by the game's own loader; then the same art goes onto an 80x100
## grid, the shipped Ronaldo size. Nothing may end in a size dead end.
func _check_editor_import(ed: Node) -> void:
	var src_path := "user://breakout_import_probe_37x91.png"
	var img := Image.create(37, 91, false, Image.FORMAT_RGBA8)
	for y in 91:
		for x in 37:
			img.set_pixel(x, y, Color(float(x) / 36.0, float(y) / 90.0, 0.35, 1.0))
	img.save_png(ProjectSettings.globalize_path(src_path))

	ed.new_level(20, 26)
	ed.level_id = "editor_import_20x26"
	var res: Dictionary = ed.import_art(src_path)
	var cnt: Dictionary = ed.counts()
	var imp_ok: bool = bool(res.get("ok", false)) and int(res.get("cols", 0)) == 20 \
		and int(res.get("rows", 0)) == 26 and int(cnt["bricks"]) > 300
	var saved: Dictionary = ed.save_to("user://breakout_editor_test")
	var lv: Dictionary = BreakoutLevel.load_level(str(saved.get("json", "")))
	var png: Image = BreakoutLevel.load_png_image(str(lv.get("image", "")))
	var round_ok: bool = bool(saved.get("ok", false)) and bool(lv.get("ok", false)) \
		and int(lv.get("cols", 0)) == 20 and int(lv.get("rows", 0)) == 26 \
		and png != null and png.get_width() == 20 and png.get_height() == 26
	_suite("editor_import_any_size", imp_ok and round_ok,
		"37x91 -> 20x26 import=%s bricks=%d saved=%s loader=%s png=%s" % [
			str(imp_ok), int(cnt["bricks"]), str(saved.get("ok", false)),
			str(lv.get("ok", false)),
			"%dx%d" % [png.get_width(), png.get_height()] if png != null else "null"])

	# The same art onto the 80x100 Ronaldo grid, played through the loader.
	ed.new_level(80, 100)
	ed.level_id = "editor_import_80x100"
	var res80: Dictionary = ed.import_art(src_path, 80, 100)
	var saved80: Dictionary = ed.save_to("user://breakout_editor_test")
	var lv80: Dictionary = BreakoutLevel.load_level(str(saved80.get("json", "")))
	var big_ok: bool = bool(res80.get("ok", false)) and bool(saved80.get("ok", false)) \
		and bool(lv80.get("ok", false)) and int(lv80.get("cols", 0)) == 80 \
		and int(lv80.get("rows", 0)) == 100 and int(lv80.get("breakable", 0)) > 3000
	_suite("editor_import_ronaldo_grid", big_ok,
		"37x91 -> 80x100 ok=%s breakable=%d tiles=%d" % [
			str(big_ok), int(lv80.get("breakable", 0)), int(lv80.get("bricks", 0))])

	# --- BRIEF 23 D: DIRECT PIXEL-FILE IMPORT. One call takes a real level PNG
	# (a shipped one, so the art is known-good) and must produce: 1 pixel = 1
	# brick (80x100), the auto-solid grey rule applied, a written PNG + JSON
	# pair, and the id registered for the menu. `keep=1` leaves the imported
	# level on disk so a following --breakout-sim can prove it is winnable.
	var keep := _args.has("keep=1")
	var px: Dictionary = ed.import_pixel_file("res://data/levels/level_04_ronaldo.png")
	var pid := str(px.get("id", ""))
	var pjson := str(px.get("json", ""))
	var plv: Dictionary = BreakoutLevel.load_level(pjson)
	var png_ok := false
	if str(px.get("png", "")) != "":
		var pimg := BreakoutLevel.load_png_image(str(px["png"]))
		png_ok = pimg != null and pimg.get_width() == 80 and pimg.get_height() == 100
	var pixel_ok: bool = bool(px.get("ok", false)) and pid != "" \
		and pid != "level_04_ronaldo" \
		and int(px.get("cols", 0)) == 80 and int(px.get("rows", 0)) == 100 \
		and png_ok and bool(plv.get("ok", false)) \
		and int(plv.get("breakable", 0)) == int(px.get("breakable", -1)) \
		and int(plv.get("unbreakable", 0)) == int(px.get("unbreakable", -1)) \
		and Game.LEVELS.has(pid)
	_suite("editor_import_pixel_file", pixel_ok,
		"png -> id=%s %dx%d bricks=%d breakable=%d unbreakable=%d grey_solid=%d saved=%s in_menu=%s keep=%s" % [
			pid, int(plv.get("cols", 0)), int(plv.get("rows", 0)),
			int(plv.get("bricks", 0)), int(plv.get("breakable", 0)),
			int(plv.get("unbreakable", 0)), int(plv.get("unbreakable_from_grey", 0)),
			str(FileAccess.file_exists(pjson)), str(Game.LEVELS.has(pid)), str(keep)])
	if keep and pid != "":
		print("WR_BREAKOUT_PIXEL_KEPT id=%s json=%s" % [pid, pjson])
	else:
		# Leave nothing behind in the user's level folder.
		for p in [pjson, str(px.get("png", ""))]:
			if str(p) != "" and FileAccess.file_exists(str(p)):
				DirAccess.remove_absolute(ProjectSettings.globalize_path(str(p)))

	# --- leave the player's menu exactly as it was found. PLAY from the editor
	# writes user://levels/editor_play_level, and Game.LEVELS lists that folder,
	# so a suite run must remove its own artifacts instead of adding a level to
	# the real menu.
	for p in ["user://levels/editor_play_level.json", "user://levels/editor_play_level.png"]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
	Game.refresh_levels()


## Brief 23 B (follow-up) — A FRAME THAT A RESIZE LEFT IN PIECES.
## The real Messi art is not in this repository, so this rebuilds the geometry
## the brief describes and checks the RULE against it: an 80x100 portrait with a
## closed grey frame around it (top bars + side walls forming a rectangle), the
## frame broken into single-cell pieces the way a resize leaves it, neutral grey
## SHADING inside the portrait that must stay breakable, and no manual
## unbreakable_cells at all. The rule must wall in the frame and nothing else.
func _check_grey_frame() -> void:
	var dir := "user://breakout_grey_frame"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var cols := 80
	var rows := 100
	var inset := 5
	var img := Image.create(cols, rows, false, Image.FORMAT_RGBA8)
	var shading: Array[Vector2i] = []
	var frame_grey: Array[Vector2i] = []
	for r in range(inset + 4, rows - inset - 5):
		for c in range(inset + 3, cols - inset - 4):
			img.set_pixel(c, r, Color8(198, 140, 110, 255))
	for r in range(inset + 4, inset + 16):
		for c in range(inset + 3, cols - inset - 4):
			img.set_pixel(c, r, Color8(52, 34, 28, 255))
	# Neutral shading inside the face: grey to the colour test, but it is picture
	# content — exactly the case that must stay breakable.
	for blob in [[30, 22, 8, 6], [46, 30, 10, 8], [60, 20, 6, 10]]:
		for r in range(int(blob[0]), int(blob[0]) + int(blob[2])):
			for c in range(int(blob[1]), int(blob[1]) + int(blob[3])):
				img.set_pixel(c, r, Color8(120, 118, 116, 255))
				shading.append(Vector2i(c, r))
	# The closed frame. Every third cell is a resize-stained near-grey (chroma
	# 30): lost to the colour test, which is the fragmentation the brief describes.
	var ring: Array[Vector2i] = []
	var top := inset
	var bot := rows - inset - 1
	var left := inset
	var right := cols - inset - 1
	for c in range(left, right + 1):
		ring.append(Vector2i(c, top))
		ring.append(Vector2i(c, bot))
	for r in range(top + 1, bot):
		ring.append(Vector2i(left, r))
		ring.append(Vector2i(right, r))
	for i in ring.size():
		var cell: Vector2i = ring[i]
		if i % 3 == 0:
			img.set_pixel(cell.x, cell.y, Color8(150, 142, 120, 255))
		else:
			img.set_pixel(cell.x, cell.y, Color8(128, 128, 128, 255))
			frame_grey.append(cell)
	img.save_png(ProjectSettings.globalize_path(dir.path_join("messi_frame.png")))
	var meta := {"id": "test_grey_frame", "display_name": "GREY FRAME",
		"image": "messi_frame.png", "cols": cols, "rows": rows, "cell": 6.0,
		"origin": [30, 74], "unbreakable_cells": []}
	var json_path := ProjectSettings.globalize_path(dir.path_join("messi_frame.json"))
	var f := FileAccess.open(json_path, FileAccess.WRITE)
	f.store_string(JSON.stringify(meta))
	f.close()
	var lv := BreakoutLevel.load_level(dir.path_join("messi_frame.json"))
	var solid := {}
	for u in lv.get("unbreakable_cells", []):
		solid[u] = true
	var covered := 0
	for cell in frame_grey:
		if solid.has(cell):
			covered += 1
	var shading_solid := 0
	for cell in shading:
		if solid.has(cell):
			shading_solid += 1
	# The carve always opens the channel through the frame's bottom bar, so a few
	# frame cells legitimately stop being bricks.
	var ok: bool = bool(lv.get("ok", false)) and covered >= frame_grey.size() - 4 \
		and shading_solid == 0 and int(lv.get("stranded_breakable", -1)) == 0
	_suite("editor_grey_frame", ok,
		"frame_cells=%d frame_grey=%d covered=%d (%d%%) shading_grey=%d shading_solid=%d grey_solid=%d stranded=%d unstained_out_of_reach=%d" % [
			ring.size(), frame_grey.size(), covered,
			int(100.0 * float(covered) / maxf(1.0, float(frame_grey.size()))),
			shading.size(), shading_solid, int(lv.get("unbreakable_from_grey", 0)),
			int(lv.get("stranded_breakable", -1)), ring.size() - frame_grey.size()])
	for name in ["messi_frame.png", "messi_frame.json"]:
		var p := ProjectSettings.globalize_path(dir.path_join(name))
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)


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
func _resolve_level_arg(want: String) -> bool:
	# A registered level is played by id; anything else (a measurement fixture)
	# is resolved the same way --breakout-record resolves an editor level.
	Game.level_id = want
	Game.play_level_path = ""
	if Game.LEVELS.has(want):
		return true
	var jp := BreakoutLevelWriter.find_json(want)
	if jp == "":
		return false
	Game.play_level_path = jp
	return true


func _suite_pace() -> void:
	Game.auto_play = true
	# Optional level selection, so the new guide-path level can be measured:
	#   --breakout-pace level=level_03_solid_path
	for a in _args:
		if str(a).begins_with("level="):
			_resolve_level_arg(str(a).trim_prefix("level="))
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
	print("WR_BREAKOUT_PACE level=%s cleared=%s elapsed=%.1f first_multiball=%.1f peak_balls=%d score=%d bricks_total=%d stars=%d/%d lost=%d peak_combo=%d" % [
		str(Game.level_id), str(won), float(g.elapsed), first_mb, maxi(peak, int(g.peak_balls)),
		int(g.score), int(g.bricks_total), int(g.stars_collected), int(g.stars_dropped),
		int(g.stars_lost), int(g.peak_combo)])
	await _report("WR_BREAKOUT_PACE_RESULT", won, "cleared at %.1fs" % float(g.elapsed))


# -------------------------------------------------- real-time simulation
## REAL-TIME winnability measurement.
##
## Why this exists: --breakout-pace runs at Engine.time_scale = 6, where a
## 420 px/s ball moves ~42 px per physics step — enough to skip a 10 px brick or
## a 1-cell wall. A pace clear is therefore NOT proof that a recorded take wins.
## This mode runs at time_scale 1 (the exact timestep a take records at) and
## reports the LONGEST STRETCH WITH NO BRICK BROKEN, which is what a stall looks
## like from the outside.
##
##   --breakout-sim level=level_03_solid_path seconds=200 seed=1
func _suite_sim() -> void:
	Game.auto_play = true
	var want := Game.level_id
	var secs := 120.0
	var seedv := 1
	for a in _args:
		var s := str(a)
		if s.begins_with("level="):
			want = s.trim_prefix("level=")
		elif s.begins_with("seconds="):
			secs = float(s.trim_prefix("seconds="))
		elif s.begins_with("seed="):
			seedv = int(s.trim_prefix("seed="))
	if not _resolve_level_arg(want):
		print("WR_BREAKOUT_SIM level=%s error=level not found" % want)
		await _report("WR_BREAKOUT_SIM_RESULT", false, "level not found: %s" % want)
		return
	Game.game_seed = seedv
	Engine.time_scale = 1.0
	var g: Node = await _new_game()
	if int(g.bricks_left) <= 0:
		await _report("WR_BREAKOUT_SIM_RESULT", false, "level failed to load")
		return
	var ended: Array = []
	g.game_ended.connect(func(res: Dictionary) -> void: ended.append(res))
	g.debug_force_play()
	var hits := 0
	var last_break_at := 0.0
	var longest_stall := 0.0
	var min_x := 1.0e9
	var max_x := -1.0e9
	var next_trace := 10.0
	var t0 := Time.get_ticks_msec()
	while ended.is_empty() and float(g.elapsed) < secs \
			and Time.get_ticks_msec() - t0 < int(secs * 1000.0) + 20000:
		await get_tree().process_frame
		var now := float(g.elapsed)
		longest_stall = maxf(longest_stall, now - last_break_at)
		if int(g.brick_hits) != hits:
			hits = int(g.brick_hits)
			last_break_at = now
		for b in g._balls:
			if is_instance_valid(b):
				min_x = minf(min_x, (b as Ball).position.x)
				max_x = maxf(max_x, (b as Ball).position.x)
		if now >= next_trace:
			next_trace += 10.0
			var bx := -1.0
			if not (g._balls as Array).is_empty() and is_instance_valid(g._balls[0]):
				bx = float((g._balls[0] as Ball).position.x)
			var by := -1.0
			if not (g._balls as Array).is_empty() and is_instance_valid(g._balls[0]):
				by = float((g._balls[0] as Ball).position.y)
			var bv := Vector2.ZERO
			var bs := 0.0
			if not (g._balls as Array).is_empty() and is_instance_valid(g._balls[0]):
				bv = (g._balls[0] as Ball).vel
				bs = (g._balls[0] as Ball).speed()
			print("WR_BREAKOUT_SIM_TRACE t=%.0f balls=%d bricks=%d lives=%d score=%d x=%.0f y=%.0f vel=(%.0f,%.0f) spd=%.0f pad=%.0f stall=%.1f" % [
				now, int(g.ball_count()), int(g.bricks_left), int(g.lives),
				int(g.score), bx, by, bv.x, bv.y, bs, float(g.paddle.position.x),
				now - last_break_at])
	Engine.time_scale = 1.0
	# dump=1: print where the LAST breakable bricks are, as an ASCII map of the
	# live grid ('o' breakable, '#' unbreakable, '.' empty). This is how a tail
	# stall is diagnosed: unreachable pockets vs bricks that are merely far apart.
	if _args.has("dump=1"):
		var live := {}
		for c in g._bodies.keys():
			live[c] = not (g._bodies[c] as Brick).unbreakable
		var gc := int(g.cols)
		var gr := int(g.rows)
		print("WR_BREAKOUT_SIM_DUMP cols=%d rows=%d left=%d" % [gc, gr, int(g.bricks_left)])
		for rr in gr:
			var line := "%3d " % rr
			for cc in gc:
				var key := Vector2i(cc, rr)
				if not live.has(key):
					line += "."
				elif bool(live[key]):
					line += "o"
				else:
					line += "#"
			print("WR_BREAKOUT_SIM_DUMP %s" % line)
	var won := ended.size() == 1 and bool((ended[0] as Dictionary).get("won", false))
	print("WR_BREAKOUT_SIM level=%s seed=%d won=%s elapsed=%.1f bricks_left=%d bricks_total=%d score=%d lives=%d hits=%d longest_stall=%.1fs ball_x=[%.0f..%.0f] stars=%d/%d nukes=%d nuke_bricks=%d peak_balls=%d" % [
		want, seedv, str(won), float(g.elapsed), int(g.bricks_left), int(g.bricks_total),
		int(g.score), int(g.lives), int(g.brick_hits), longest_stall,
		min_x if min_x < 1.0e9 else -1.0, max_x if max_x > -1.0e9 else -1.0,
		int(g.stars_collected), int(g.stars_dropped),
		int(g.nukes_caught), int(g.nuke_bricks), int(g.peak_balls)])
	await _report("WR_BREAKOUT_SIM_RESULT", won,
		"level=%s seed=%d won=%s at %.1fs (longest stall %.1fs, bricks_left %d)" % [
			want, seedv, str(won), float(g.elapsed), longest_stall, int(g.bricks_left)])


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
	# The two timelines the take was built from, so a sync problem can be read
	# off the take instead of guessed at: how many seconds of wall clock the
	# recording covered, how many seconds of audio the tap produced, and how
	# fast the machine actually rendered/captured.
	print("WR_BREAKOUT_RECORD_TIMING real_seconds=%.3f audio_seconds=%.3f sync_delta=%+.3f captured=%d render_fps=%.2f capture_fps=%.2f dup_frames=%d duration=%.3f" % [
		float(res.get("real_seconds", 0.0)), float(res.get("audio_seconds", 0.0)),
		float(res.get("sync_delta", 0.0)), int(res.get("captured", 0)),
		float(res.get("render_fps", 0.0)), float(res.get("capture_fps", 0.0)),
		int(res.get("dup_frames", 0)), float(res.get("duration", 0.0))])
	# The A/V sync correction this take got, and the outcome it recorded, so a
	# report never has to guess either one.
	print("WR_BREAKOUT_RECORD_SYNC audio_seconds=%.3f video_seconds=%.3f atempo=%.6f residual=%.3f win_wall=%.3f" % [
		float(res.get("sync_audio_seconds", 0.0)), float(res.get("sync_video_seconds", 0.0)),
		float(res.get("sync_atempo", 1.0)),
		float(res.get("sync_audio_seconds", 0.0)) / maxf(0.0001, float(res.get("sync_atempo", 1.0))) \
			- float(res.get("sync_video_seconds", 0.0)),
		float(res.get("sync_win_seconds", -1.0))])
	# The take restarted the race, so the scene that was on screen when it began
	# is gone: read the outcome from the LIVE scene instead.
	var live: Node = get_tree().current_scene
	if live != null and is_instance_valid(live) and live.has_signal("game_ended"):
		print("WR_BREAKOUT_RECORD_GAME state=%s elapsed=%.1f score=%d stars=%d bricks_left=%d won=%s" % [
			str(live.get("state")), float(live.get("elapsed")), int(live.get("score")),
			int(live.get("stars_collected")), int(live.get("bricks_left")),
			str(str(live.get("state")) == "level_clear")])
	await _report("WR_BREAKOUT_RECORD_RESULT", ok,
		"take saved" if ok else "recording failed: %s" % str(RecordSession.last_error))
