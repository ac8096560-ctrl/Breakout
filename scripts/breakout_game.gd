extends Node2D
## PIXEL BREAKOUT — the game scene and its flow controller.
##
## Own state machine (independent of WorldRace's RaceDirector):
##   ready       ball resting on the paddle, short countdown
##   playing     ball(s) in play, paddle player-or-AI controlled
##   ball_lost   all balls gone, a life was spent, brief beat before re-serve
##   level_clear every brick gone  -> win popup + game_ended
##   game_over   no lives left     -> "Game Over" popup + game_ended
##
## `game_ended` is the level's ONE end signal — RecordSession auto-stops a take
## on it, and nothing else in the game raises it.

signal state_changed(state: String)
signal game_ended(result: Dictionary)
signal brick_broken(cell: Vector2i)

const STATE_READY := "ready"
const STATE_PLAYING := "playing"
const STATE_BALL_LOST := "ball_lost"
const STATE_LEVEL_CLEAR := "level_clear"
const STATE_GAME_OVER := "game_over"

const VIEW := Vector2(540, 960)
## 76% of the frame, like the reference (paddle top at 488/640). With the grid
## ending at 664 the return trip is short, which is what makes the brick rate
## of the reference reachable.
const PADDLE_Y := 760.0
const BALL_SPEED := 420.0
## Serve angle, degrees from straight up. The solid border leaves only the
## 2-cell stem gap (24 px wide, 16 px for the ball centre) as the entry, and
## a wide serve settles into a bounce loop below the border instead of ever
## threading it — the reference ball goes straight up the stem. ±2 deg drifts
## ~3 px over the trip to the gap, so the serve threads it cleanly on the
## first trip while keeping a touch of variety per seed. (±5 deg would drift
## ~7.5 px and nearly clip the border.)
const SERVE_ANGLE_DEG := 2.0
const START_LIVES := 3
const READY_SECONDS := 1.2
const LOST_SECONDS := 0.7
const LOSS_Y := 1000.0
const MAX_BALLS := 120
const MAX_POWERUPS := 40
## Chance per broken brick of dropping a "+3", plus two guaranteed drops that
## put the first multi-ball on screen around the reference's t=8s: the channel's
## two tip cells always drop one, and so does the FIRST_DROP_BRICKS-th brick of
## a take (whichever brick that turns out to be — the outcome still comes from
## play, nothing is scripted).
const POWERUP_CHANCE := 0.20
## 30% of power-up drops are the gold "x3" (triples the balls in play); the
## rest are the blue/green "+3" (adds 3 balls).
const TIMES3_CHANCE := 0.30
const FIRST_DROP_BRICKS := 30
## Nothing falls during the opening beat, so the take starts on ONE ball like
## the reference (whose first multi-ball lands around t=8s) instead of flooding
## the screen in the first two seconds.
const DROP_DELAY := 4.5
## "Clear (nearly) ALL the bricks" — the reference wins on a nearly-empty
## field, and a 1% leftover also stops a single corner brick from stalling a
## take forever. This is the win rule, not a scripted result.
const WIN_LEFTOVER := 0.015
const BUFF_SECONDS := 2.5

var theme_id := "rose"
var pal: Dictionary = {}

var level: Dictionary = {}
var level_id := ""
var cols := 0
var rows := 0
var cell := 12.0
var origin := Vector2.ZERO
var grid: Array = []
var bricks_total := 0
var bricks_left := 0
var score := 0
var lives := START_LIVES
var state := STATE_READY
var elapsed := 0.0
var auto_play := true
var seed_value := 1

# pacing telemetry (also printed by --breakout-pace)
var first_multiball_at := -1.0
var powerups_dropped := 0
var powerups_caught := 0
var peak_balls := 1
var brick_hits := 0

var rng := RandomNumberGenerator.new()
var field: BrickField
var paddle: Paddle
var bricks_root: Node2D
var balls_root: Node2D
var powerups_root: Node2D
var fx_root: Node2D
var hud: Control

var _bodies: Dictionary = {}       # Vector2i -> Brick
var _balls: Array = []
var _powerups: Array = []
var _tip_cells: Array = []
var _unbreakable_cells: Array = []  # Vector2i border cells: walls, not bricks
var _ready_left := READY_SECONDS
var _lost_left := 0.0
var _player_target := -1.0
var _held_ball: Ball = null


func _ready() -> void:
	theme_id = Game.theme_id
	pal = Themes.get_theme(theme_id)
	seed_value = Game.game_seed
	level_id = Game.level_id
	auto_play = Game.auto_play
	rng = RandomNumberGenerator.new()
	rng.seed = seed_value
	_build_scene()
	_load_level()
	_enter_ready()


# ------------------------------------------------------------------ scene
func _build_scene() -> void:
	var bg := ColorRect.new()
	bg.name = "Background"
	bg.color = pal.get("background", Color(0.055, 0.055, 0.062))
	bg.size = VIEW
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	field = BrickField.new()
	field.name = "BrickField"
	field.z_index = 1
	add_child(field)

	bricks_root = Node2D.new()
	bricks_root.name = "Bricks"
	add_child(bricks_root)

	balls_root = Node2D.new()
	balls_root.name = "Balls"
	add_child(balls_root)

	powerups_root = Node2D.new()
	powerups_root.name = "PowerUps"
	add_child(powerups_root)

	fx_root = Node2D.new()
	fx_root.name = "Effects"
	fx_root.z_index = 8
	add_child(fx_root)

	_build_walls()

	paddle = Paddle.new()
	paddle.name = "Paddle"
	paddle.pal = pal
	paddle.position = Vector2(270, PADDLE_Y)
	add_child(paddle)

	var hud_layer := CanvasLayer.new()
	hud_layer.name = "HUDLayer"
	hud_layer.layer = 10
	add_child(hud_layer)
	hud = BreakoutHUD.new()
	hud_layer.add_child(hud)
	hud.bind(self, pal)

	# The REC pill is instantiated by THIS scene (WorldRace builds its own
	# RecorderPanel inside RaceHUD; here the game owns it).
	var rec_layer := CanvasLayer.new()
	rec_layer.name = "RecorderLayer"
	rec_layer.layer = 20
	add_child(rec_layer)
	var panel := RecorderPanel.new()
	panel.name = "RecorderPanel"
	rec_layer.add_child(panel)


func _build_walls() -> void:
	var walls := StaticBody2D.new()
	walls.name = "Walls"
	walls.collision_layer = 1
	walls.collision_mask = 0
	add_child(walls)
	var specs := [
		# centre, size  — top wall sits on the grid's top edge, sides run the
		# full height so the black play floor is walled in as well.
		[Vector2(270, 64), Vector2(560, 20)],
		[Vector2(-10, 480), Vector2(20, 980)],
		[Vector2(550, 480), Vector2(20, 980)],
	]
	for s in specs:
		var shape := CollisionShape2D.new()
		var rect := RectangleShape2D.new()
		rect.size = s[1]
		shape.shape = rect
		shape.position = s[0]
		walls.add_child(shape)


func _load_level() -> void:
	var path := "res://data/levels/%s.json" % Game.level_id
	level = BreakoutLevel.load_level(path)
	if not bool(level.get("ok", false)):
		push_error("level load failed: %s" % str(level.get("err", "")))
		return
	cols = int(level["cols"])
	rows = int(level["rows"])
	cell = float(level["cell"])
	origin = level["origin"]
	grid = level["grid"]
	# The win counts BREAKABLE bricks only: the solid border is a wall, and
	# counting it would make a level unwinnable (it can never be broken).
	bricks_total = int(level["breakable"])
	bricks_left = bricks_total
	for t in level["powerup_cells"]:
		_tip_cells.append(t)
	for u in level["unbreakable_cells"]:
		_unbreakable_cells.append(u)
	field.configure(cols, rows, cell, origin, pal, grid)
	field.queue_redraw()
	_spawn_brick_bodies()


func _spawn_brick_bodies() -> void:
	for r in rows:
		for c in cols:
			var col: Color = grid[r * cols + c]
			if col.a < 0.5:
				continue
			var b := Brick.new()
			b.name = "Brick_%d_%d" % [c, r]
			bricks_root.add_child(b)
			b.setup(Vector2i(c, r), cell_center(Vector2i(c, r)))
			b.unbreakable = _unbreakable_cells.has(Vector2i(c, r))
			_bodies[Vector2i(c, r)] = b


func cell_center(c: Vector2i) -> Vector2:
	return origin + (Vector2(c) + Vector2(0.5, 0.5)) * cell


# ------------------------------------------------------------------ flow
## Game x of the channel stem centre, read from the level's stem_cols so the
## serve aims at the entry gap on every level (level_01 and level_02 both use
## stem_cols [19,20] -> x=270, but nothing here hardcodes that). Falls back
## to the view centre when a level carries no stem data.
func _stem_centre_x() -> float:
	var sc: Array = level.get("stem_cols", [])
	if sc.size() == 2:
		return origin.x + (float(sc[0]) + float(sc[1]) + 1.0) * cell * 0.5
	return VIEW.x * 0.5


func _enter_ready() -> void:
	state = STATE_READY
	_ready_left = READY_SECONDS
	_held_ball = _new_ball(Vector2(paddle.position.x, PADDLE_Y - 22.0))
	_held_ball.active = false
	state_changed.emit(state)


func _start_play() -> void:
	state = STATE_PLAYING
	if _held_ball != null and is_instance_valid(_held_ball):
		# Aim the serve at the channel stem: the border is solid, so the
		# stem gap is the only way in. The paddle is centred on the stem
		# first (a no-op in auto-play, where it already sits there).
		paddle.move_to_x(_stem_centre_x())
		var ang := deg_to_rad(rng.randf_range(-SERVE_ANGLE_DEG, SERVE_ANGLE_DEG))
		_held_ball.position = paddle.position + Vector2(0, -22.0)
		_held_ball.launch(Vector2(sin(ang), -cos(ang)) * (BALL_SPEED + rng.randf_range(-12.0, 12.0)))
	_held_ball = null
	state_changed.emit(state)


func _physics_process(delta: float) -> void:
	match state:
		STATE_READY:
			_update_paddle(delta)
			_ready_left -= delta
			if _ready_left <= 0.0:
				_start_play()
		STATE_PLAYING:
			elapsed += delta
			_update_paddle(delta)
			_tick_powerups(delta)
			_tick_balls()
			peak_balls = maxi(peak_balls, _balls.size())
		STATE_BALL_LOST:
			_update_paddle(delta)
			_lost_left -= delta
			if _lost_left <= 0.0:
				_serve_again()


func _serve_again() -> void:
	state = STATE_PLAYING
	# Re-centre on the stem for the same reason as _start_play: a re-serve
	# from wherever the paddle happened to be can never find the gap.
	paddle.move_to_x(_stem_centre_x())
	var b := _new_ball(paddle.position + Vector2(0, -22.0))
	var ang := deg_to_rad(rng.randf_range(-SERVE_ANGLE_DEG, SERVE_ANGLE_DEG))
	b.launch(Vector2(sin(ang), -cos(ang)) * BALL_SPEED)
	state_changed.emit(state)


func _tick_balls() -> void:
	for b in _balls.duplicate():
		if not is_instance_valid(b):
			_balls.erase(b)
			continue
		if b.position.y > LOSS_Y:
			b.active = false
			_balls.erase(b)
			b.queue_free()
	if _balls.is_empty():
		_on_all_balls_lost()


func _on_all_balls_lost() -> void:
	lives -= 1
	if lives <= 0:
		lives = 0
		_finish(false)
		return
	AudioManager.play("lose_life")
	state = STATE_BALL_LOST
	_lost_left = LOST_SECONDS
	state_changed.emit(state)


func win_leftover() -> int:
	return int(floor(float(bricks_total) * WIN_LEFTOVER))


func _finish(won: bool) -> void:
	if state == STATE_LEVEL_CLEAR or state == STATE_GAME_OVER:
		return
	state = STATE_LEVEL_CLEAR if won else STATE_GAME_OVER
	AudioManager.play("victory" if won else "defeat")
	if won and hud != null:
		hud.show_win(score, elapsed)
	elif hud != null:
		hud.show_game_over(score, bricks_left)
	state_changed.emit(state)
	game_ended.emit({
		"won": won, "score": score, "lives": lives,
		"bricks_left": bricks_left, "bricks_total": bricks_total,
		"elapsed": elapsed, "level": level_id, "seed": seed_value,
		"balls": _balls.size(), "peak_balls": peak_balls,
		"first_multiball_at": first_multiball_at,
	})


## A take (RecordSession / the tests) restarts through this, so a recording
## always begins from the level's first frame with the same seed.
func restart_game() -> void:
	Game.restart_game()


# ------------------------------------------------------------------ paddle
func _update_paddle(delta: float) -> void:
	if auto_play:
		var target := _auto_target()
		var step := 1500.0 * delta
		paddle.move_to_x(move_toward(paddle.position.x, target, step))
		return
	var dir := 0.0
	if Input.is_key_pressed(KEY_LEFT) or Input.is_key_pressed(KEY_A):
		dir -= 1.0
	if Input.is_key_pressed(KEY_RIGHT) or Input.is_key_pressed(KEY_D):
		dir += 1.0
	if dir != 0.0:
		paddle.move_to_x(paddle.position.x + dir * 540.0 * delta)
	elif _player_target >= 0.0:
		paddle.move_to_x(lerpf(paddle.position.x, _player_target, minf(1.0, delta * 26.0)))


## Auto-play: track the LOWEST ball (the one nearest the danger line) and lead
## it a little when it is falling. This is the recording mode — a Short is
## watchable with no input at all.
func _auto_target() -> float:
	# 1) FIRST the ball that will reach the paddle line soonest — that is the
	# one about to be lost. Predicting the arrival x (not the current x) is
	# what makes the AI track "smoothly and accurately".
	var best: Ball = null
	var best_eta := 1.0e9
	for b in _balls:
		if not is_instance_valid(b) or not b.active or b.vel.y <= 1.0:
			continue
		var eta: float = (paddle.position.y - b.position.y) / float(b.vel.y)
		if eta < best_eta:
			best_eta = eta
			best = b
	if best != null and best_eta < 0.85:
		return _lead_x(best)
	# 2) No ball is in danger for a moment: chase the lowest falling power-up,
	# which is what keeps a multi-ball take alive (and is why a recorded take
	# reaches the reference's ball counts).
	var pick: PowerUp = null
	var pick_y := -1.0e9
	for p in _powerups:
		if not is_instance_valid(p):
			continue
		var up := p as PowerUp
		if not up.alive or up.position.y > paddle.position.y:
			continue
		if up.position.y > pick_y:
			pick_y = up.position.y
			pick = up
	if pick != null:
		return pick.position.x
	if best != null:
		return _lead_x(best)
	return paddle.position.x


func _lead_x(b: Ball) -> float:
	var x := b.position.x
	if b.vel.y > 1.0:
		var eta := clampf((paddle.position.y - b.position.y) / float(b.vel.y), 0.0, 1.5)
		x += float(b.vel.x) * eta
	return clampf(x, Paddle.SIZE.x * 0.5, VIEW.x - Paddle.SIZE.x * 0.5)


func _input(event: InputEvent) -> void:
	if state == STATE_LEVEL_CLEAR or state == STATE_GAME_OVER:
		if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
			Game.goto_menu()
		elif event is InputEventKey and (event as InputEventKey).pressed \
				and (event as InputEventKey).keycode == KEY_R:
			Game.start_game(seed_value)
		return
	if event is InputEventMouseMotion:
		auto_play = false
		_player_target = (event as InputEventMouseMotion).position.x
	elif event is InputEventScreenDrag:
		auto_play = false
		_player_target = (event as InputEventScreenDrag).position.x
	elif event is InputEventScreenTouch and (event as InputEventScreenTouch).pressed:
		auto_play = false
		_player_target = (event as InputEventScreenTouch).position.x
	elif event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		auto_play = false
		_player_target = (event as InputEventMouseButton).position.x
	elif event is InputEventKey and (event as InputEventKey).pressed:
		# Desktop fallback: an arrow (or A/D) press hands the paddle to the
		# player, after which _update_paddle reads the held key.
		var code := (event as InputEventKey).keycode
		if code in [KEY_LEFT, KEY_RIGHT, KEY_A, KEY_D]:
			auto_play = false
			_player_target = -1.0


# ------------------------------------------------------------------ balls
func _new_ball(at: Vector2) -> Ball:
	var b := Ball.new()
	b.position = at
	balls_root.add_child(b)
	b.hit_collider.connect(_on_ball_hit.bind(b))
	_balls.append(b)
	return b


func _on_ball_hit(collider: Node, _normal: Vector2, b: Ball) -> void:
	if not is_instance_valid(b):
		return
	if collider is Brick:
		var brick := collider as Brick
		if brick.live:
			if brick.unbreakable:
				# A solid border brick: the ball already bounced off it in
				# physics — it is a wall, not a brick. No break, no score,
				# no power-up, no count change.
				AudioManager.play("bounce", -8.0)
			else:
				break_cell(brick.cell)
	elif collider is Paddle:
		b.vel = paddle.bounce_for(b.position.x, b.speed())
		AudioManager.play("bounce")
	elif collider is StaticBody2D:
		AudioManager.play("bounce", -8.0)


func _add_balls(n: int, at: Vector2) -> int:
	var added := 0
	for i in n:
		if _balls.size() >= MAX_BALLS:
			break
		var ang := deg_to_rad(rng.randf_range(-62.0, 62.0))
		var pos := Vector2(clampf(at.x, 12.0, 528.0), clampf(at.y, 80.0, PADDLE_Y - 40.0))
		var b := _new_ball(pos)
		b.launch(Vector2(sin(ang), -cos(ang)) * BALL_SPEED)
		added += 1
	return added


# ------------------------------------------------------------------ bricks
func break_cell(c: Vector2i, silent := false) -> void:
	if not _bodies.has(c):
		return
	var brick: Brick = _bodies[c]
	if brick.unbreakable:
		return
	_bodies.erase(c)
	brick.live = false
	brick.queue_free()
	if c.y >= 0 and c.y < rows and c.x >= 0 and c.x < cols:
		grid[c.y * cols + c.x] = Color(0, 0, 0, 0)
	bricks_left -= 1
	brick_hits += 1
	score += 10
	field.queue_redraw()
	var p := cell_center(c)
	if not silent:
		# A small, quick pixel puff: the glow texture is 128 px, so scale_amount
		# is a fraction — 1.7 (the WorldRace default for racer impacts) would
		# draw 200 px blobs that swallow the portrait.
		FX.burst(fx_root, p, pal.get("brick", Color(0.647, 0.275, 0.275)), 5, 150.0, 0.30,
			0.11, 190.0, 8)
		AudioManager.play("brick_break")
	brick_broken.emit(c)
	var was_tip := _tip_cells.has(c)
	if was_tip:
		_tip_cells.erase(c)
	var first_drop := brick_hits == FIRST_DROP_BRICKS
	if bricks_left > 0 and elapsed >= DROP_DELAY \
			and (was_tip or first_drop or rng.randf() < POWERUP_CHANCE):
		_drop_powerup(p)
	if bricks_left <= win_leftover():
		_finish(true)


# ------------------------------------------------------------------ power-ups
func _drop_powerup(at: Vector2) -> void:
	if _powerups.size() >= MAX_POWERUPS:
		return
	var p := PowerUp.new()
	if rng.randf() < TIMES3_CHANCE:
		p.kind = "times3"
		p.tint = pal.get("powerup_gold", Color(0.95, 0.75, 0.15))
	else:
		p.kind = "plus3"
		p.tint = pal.get("powerup_blue", Color(0.22, 0.48, 0.92)) if rng.randi() % 2 == 0 \
			else pal.get("powerup_green", Color(0.20, 0.70, 0.36))
	p.position = Vector2(clampf(at.x, PowerUp.RADIUS, VIEW.x - PowerUp.RADIUS), at.y)
	powerups_root.add_child(p)
	_powerups.append(p)
	powerups_dropped += 1


func _tick_powerups(_delta: float) -> void:
	if _powerups.is_empty():
		return
	var rect := paddle.rect()
	for p in _powerups.duplicate():
		if not is_instance_valid(p):
			_powerups.erase(p)
			continue
		var up := p as PowerUp
		if not up.alive:
			_powerups.erase(up)
			continue
		if up.overlaps(rect):
			_collect_powerup(up)


func _multiply_balls(mult: int, at: Vector2) -> void:
	var target := mini(_balls.size() * mult, MAX_BALLS)
	var to_add := target - _balls.size()
	if to_add > 0:
		_add_balls(to_add, at)


func _collect_powerup(up: PowerUp) -> void:
	up.alive = false
	_powerups.erase(up)
	var at := up.position
	up.queue_free()
	powerups_caught += 1
	AudioManager.play("powerup")
	FX.ring(fx_root, at, pal.get("powerup_blue", Color(0.22, 0.48, 0.92)), 26.0, 0.40)
	if first_multiball_at < 0.0:
		first_multiball_at = elapsed
	if up.kind == "times3":
		_multiply_balls(3, at)
	else:
		_add_balls(3, at)
	paddle.show_buff(BUFF_SECONDS)


# ------------------------------------------------------------------ reporting / tests
func state_name() -> String:
	return state


func results_visible() -> bool:
	return state == STATE_LEVEL_CLEAR or state == STATE_GAME_OVER


func ball_count() -> int:
	return _balls.size()


func powerup_count() -> int:
	return _powerups.size()


func held_ball() -> Ball:
	return _held_ball


func paddle_x() -> float:
	return paddle.position.x


func live_bricks() -> int:
	return _bodies.size()


func is_unbreakable(c: Vector2i) -> bool:
	return _unbreakable_cells.has(c)


# --- deterministic hooks used by --breakout-test (never by gameplay) --------
func debug_force_play() -> void:
	_ready_left = 0.0
	if state == STATE_READY:
		_start_play()


## Put the flow back into PLAYING without a serve (test housekeeping: several
## suites poke balls directly, and an empty ball list would otherwise move the
## flow into ball_lost between two checks).
func debug_ensure_playing() -> void:
	_lost_left = 0.0
	if state != STATE_PLAYING:
		state = STATE_PLAYING
		state_changed.emit(state)


func debug_spawn_ball(at: Vector2, vel: Vector2) -> Ball:
	var b := _new_ball(at)
	b.launch(vel)
	return b


func debug_clear_balls() -> void:
	for b in _balls.duplicate():
		if is_instance_valid(b):
			b.active = false
			b.queue_free()
	_balls.clear()


func debug_spawn_powerup_at_paddle(kind: String = "plus3") -> PowerUp:
	var p := PowerUp.new()
	p.kind = kind
	if kind == "times3":
		p.tint = pal.get("powerup_gold", Color(0.95, 0.75, 0.15))
	p.position = paddle.position + Vector2(0, -10)
	powerups_root.add_child(p)
	_powerups.append(p)
	powerups_dropped += 1
	return p


func debug_clear_all_bricks() -> void:
	var cells := _bodies.keys()
	for c in cells:
		var b: Brick = _bodies[c]
		if b.unbreakable:
			continue
		break_cell(c, true)
