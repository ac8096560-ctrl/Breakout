extends Node
## BREAKOUT TEST HARNESS (autoload "TestRunner").
##
## One mode per suite, one machine-readable verdict line per suite, one
## summary line for the run, exit code 0 on pass / 1 on fail — the same
## contract as WorldRace's TestRunner, with its own prefix:
##
##   godot --headless --path . -- --breakout-test     gameplay suites
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
	await _check_win(g)
	g.queue_free()
	await get_tree().process_frame

	var g2: Node = await _new_game()
	g2.debug_force_play()
	await _check_lose(g2)
	g2.queue_free()
	await get_tree().process_frame

	await _report("WR_BREAKOUT_RESULT", _fails == 0, "failing suites: %d" % _fails)


func _check_level_load() -> void:
	var lv := BreakoutLevel.load_level(LEVEL_JSON)
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
			and int(lv["powerup_cells"].size()) == 2 and colours.size() >= 4 and channel_empty
		detail = "bricks=%d channel=%d colours=%d tips=%d" % [
			int(lv["bricks"]), int(lv["channel_cells"].size()), colours.size(),
			int(lv["powerup_cells"].size())]
	_suite("level_load", ok, detail)


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


func _check_win(g: Node) -> void:
	var ended: Array = []
	g.game_ended.connect(func(res: Dictionary) -> void: ended.append(res))
	g.debug_clear_all_bricks()
	await get_tree().process_frame
	await get_tree().physics_frame
	var ok := str(g.state) == "level_clear" and ended.size() == 1 \
		and bool((ended[0] as Dictionary).get("won", false))
	_suite("win_state", ok, "state=%s ends=%d bricks_left=%d" % [
		str(g.state), ended.size(), int(g.bricks_left)])


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
