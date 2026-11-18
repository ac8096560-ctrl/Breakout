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
## Brief 25 LAYOUT (follow-up 2): the paddle sits LOWER than the reference's
## 76%, so there is clearly more room between the portrait's bottom edge and the
## bar that has to catch the ball. The field now ends at 64 + 675 = 739 (see the
## width rule in _load_level), and the paddle line is 890: a 151 px gap, where
## it used to be 96 px (field bottom 664, paddle 760). At 420 px/s that is
## 0.36 s of visible ball travel instead of 0.23 s, which is the reaction room
## Choubey asked for. The safety floor moved down with the bar
## (SafetyFloor.Y = 930) and the loss line is still below the frame at 1000.
const PADDLE_Y := 890.0
## The reference pace, unchanged: 420 px/s is the take level_01/02/03 were
## tuned at, and a swept move_and_collide query makes any of these speeds
## tunnel-proof on the 4 px level_04 bricks.
const BALL_SPEED := 420.0
## Brief 22's DENSE-FIELD ball set. A 60-90 s take on a ~5,000-brick 80x100
## field needs ~2x the brick rate a 962-brick field needs, and a ball's
## collision rate scales with its speed and with how many balls are in play.
## Applying that to every level would shorten the already-tuned 962-brick
## takes by ~25% (measured), so it is applied only to a DENSE field — see
## DENSE_BRICKS. 570 px/s is a 0.45 s wall-to-wall crossing in the portrait.
const BALL_SPEED_DENSE := 570.0
## Serve angle, degrees from straight up. The solid border leaves only the
## 2-cell stem gap as the entry and the reference ball goes straight up it, so
## the serve is aimed at the stem and kept inside the gap. The angle is NOT a
## flat constant any more (Brief 22): 2 deg drifts tan(2 deg) * 74 px ~ 2.6 px
## over the trip to the gap, which threads level_01's 24 px stem but misses
## level_04's 12 px one (a 4 px window for an 8 px ball) — measured as a 19 s
## opening stall in which the first ball never entered the field. The angle is
## now derived from the level's own stem width (see _serve_angle_deg), so every
## level threads its stem, and SERVE_ANGLE_DEG is the cap.
const SERVE_ANGLE_DEG := 2.0
const START_LIVES := 3
const READY_SECONDS := 1.2
const LOST_SECONDS := 0.7
const LOSS_Y := 1000.0
const MAX_BALLS := 120
## Brief 22's dense-field cap (see BALL_SPEED_DENSE): on the dense 80x100 field
## the ball count — not only the ball speed — is what keeps the brick rate up
## once the field thins out (a ball that finds no brick for a second is a
## wasted ball).
const MAX_BALLS_DENSE := 180
## A field with this many breakable bricks plays at the dense-field pace. Only
## level_04 (4,951 breakable) is above it: level_01 is 962, level_02 1,724,
## level_03 1,064, so those three keep the reference pace they were tuned at.
const DENSE_BRICKS := 2500
const MAX_POWERUPS := 40
## Brief 25 — the drop PACE is time-based, not a flat number: the chance per
## broken brick ramps from START to END across RAMP_SECONDS of ELAPSED GAME
## TIME, so the early game is slower (few drops, few extra balls, a long
## ramp-up) and the mid/late game is faster (more drops per brick, more balls,
## a quicker finish). Measured with the new layout, the flat 0.20 was simply too
## slow once the field got bigger and the paddle moved down (level_05_messi
## cleared at 60.2 s, level_04 at 100.0 s), so the END of the ramp is well above
## the old value and the ramp is only 30 s long: the full rate is reached at
## the middle of a ~1 minute take and held there, which is exactly "slow at the
## start, fast from the middle". It is a GLOBAL rule: it reads elapsed time
## only, never the level id or the level's size.
##
## The two guaranteed drops that put the first multi-ball in the EARLY game are
## untouched by the ramp: the channel's two tip cells always drop one, and so
## does the FIRST_DROP_BRICKS-th brick of a take (whichever brick that turns out
## to be — the outcome still comes from play, nothing is scripted).
const POWERUP_CHANCE_START := 0.10
const POWERUP_CHANCE_END := 0.42
const POWERUP_RAMP_SECONDS := 40.0
## The drop pool. The six kinds sum to exactly 1.0:
##   +3 52%   x3 20%   minus 9%   star 5%   safety floor 10%   NUKE 4%
## "+3"/"x3" keep the reference's multi-ball rhythm; minus/star stay rare so
## the first multi-ball still lands around t=8 s; the floor is a real defensive
## drop at 10%; the NUKE (Brief 22) is the rarest drop because ONE catch can
## erase a 10-cell radius, and it is what ends a dense level's tail.
const DROP_WEIGHTS := {"plus3": 0.52, "times3": 0.20, "minus": 0.09, "star": 0.05, "floor": 0.10, "nuke": 0.04}
## The fixed pick order. It is also the order the rng is consumed in, so a
## seeded take stays deterministic.
const DROP_ORDER := ["plus3", "times3", "minus", "star", "floor", "nuke"]
## ---------------- Brief 22: the NUKE -------------------------------------
## One catch detonates a radial blast that breaks EVERY breakable brick within
## NUKE_RADIUS (14) cells of the blast cell (Euclidean, in CELLS, so it is the same
## number of bricks on a 12 px grid and on level_04's 6 px grid).
##
## The blast cell is the LOWEST remaining breakable brick (ties: nearest the
## field's centre column). That rule is what makes the drop matter where a take
## actually stalls: the last few hundred bricks of a dense level sit lowest and
## are the ones a 120-ball field keeps missing, while early on the same blast
## just takes a bite out of a still-dense field. Nothing is scripted — the drop
## is an ordinary pool draw and the blast breaks through the normal break_cell
## path (score, combo, drops and the win rule all still apply).
const NUKE_RADIUS := 14
## Unbreakable cells (the border and level_04's two grey wall columns) are
## walls and are never broken by a blast.
## Stage B DESIGN CHOICES (the reference study does not resolve these):
##   orange "—"  removes exactly ONE ball, and does nothing at one ball, so the
##               debuff can never cause a loss by itself.
##   yellow star  a flat STAR_BONUS plus a x3 brick-score multiplier for 5 s.
const STAR_BONUS := 250
const STAR_MULT := 3
const STAR_SECONDS := 5.0
const FIRST_DROP_BRICKS := 30
## ---------------- Stage C: the five new rules ------------------------------
## 1) "x3" is an IN-PLACE split: every ball in play becomes its own ball plus
##    two siblings at the SAME position, their velocities rotated +-25 deg
##    around the parent's heading at the same speed, so they visibly diverge.
const SPLIT_SPREAD_DEG := 25.0
## 2) The 3-STAR COLLECTIBLE. One star per milestone, at most three per level.
##    Each milestone fires on WHICHEVER comes first: that share of the
##    breakable bricks broken, or that elapsed time.
const STAR_MILESTONES := 3
const STAR_BRICK_FRACS := [0.25, 0.50, 0.75]
const STAR_TIMES := [45.0, 90.0, 135.0]
## 3) The safety floor: 10 s up, below the paddle, bouncing every ball back.
const FLOOR_SECONDS := SafetyFloor.DURATION
## 5) The combo chain. 1.2 s between breaks keeps it alive; the multiplier is
##    the chain length (cap 999) and a brick scores 10 x combo.
const COMBO_WINDOW := 1.2
const COMBO_MAX := 999
const COMBO_SCORE := 10
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
var score_mult := 1        # star bonus multiplier (1 = none)
var star_left := 0.0       # seconds of x3 left
var combo := 1             # Stage C: bricks broken inside COMBO_WINDOW chain
var stars_collected := 0   # the 3-star collectible: caught this level
var stars_dropped := 0     # milestones that fired a star
var stars_lost := 0        # stars the paddle missed (gone for this level)
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
var peak_combo := 1
## Brief 22 NUKE telemetry: how many were caught / how many bricks a blast took.
var nukes_caught := 0
var nuke_bricks := 0

var rng := RandomNumberGenerator.new()
var field: BrickField
var paddle: Paddle
var bricks_root: Node2D
var balls_root: Node2D
var powerups_root: Node2D
var stars_root: Node2D
var fx_root: Node2D
var hud: Control

var _bodies: Dictionary = {}       # Vector2i -> Brick
var _balls: Array = []
var _powerups: Array = []
var _stars: Array = []             # falling 3-star collectibles
var _star_done: Array = [false, false, false]   # milestone i has fired
var _star_source := Vector2.ZERO   # last broken brick (a star falls from there)
var _combo_left := 0.0             # seconds left in the current combo chain
var _floor: SafetyFloor = null     # the safety-floor bar (one at a time)
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

	stars_root = Node2D.new()
	stars_root.name = "Stars"
	add_child(stars_root)

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

	# The safety floor: ONE node, created up-front and hidden, so a catch only
	# raises the bar and can never spawn a second one.
	_floor = SafetyFloor.new()
	_floor.name = "SafetyFloor"
	_floor.pal = pal
	add_child(_floor)

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
		#
		# Brief 25: the side walls are pulled 2 px INWARD so their inner faces
		# (x = 2 and 538) sit BEHIND the edge bricks (a brick body is cell - 2
		# wide, so at 13.5 px pitch the outermost body starts at x = 1). When the
		# field was 30 px in from each wall that seam never mattered; with the
		# field flush to the frame the 1 px slot between wall and brick became a
		# squeeze channel and the ball was extruded OUT of the arena (measured:
		# sim ball_x reached -46 and 632). Overlapping the wall behind the brick
		# removes the slot, so a squeezed ball is pushed back inside.
		[Vector2(270, 64), Vector2(560, 20)],
		[Vector2(-8, 480), Vector2(20, 980)],
		[Vector2(548, 480), Vector2(20, 980)],
	]
	for s in specs:
		var shape := CollisionShape2D.new()
		var rect := RectangleShape2D.new()
		rect.size = s[1]
		shape.shape = rect
		shape.position = s[0]
		walls.add_child(shape)


func _load_level() -> void:
	# Game resolves the path: a level played from the editor is an explicit
	# user:// file, otherwise the shipped folder, otherwise user:// by id.
	var path := Game.level_json_path()
	level = BreakoutLevel.load_level(path)
	if not bool(level.get("ok", false)):
		push_error("level load failed: %s" % str(level.get("err", "")))
		return
	cols = int(level["cols"])
	rows = int(level["rows"])
	cell = float(level["cell"])
	origin = level["origin"]
	# --- Brief 25 LAYOUT (follow-up 3): the field spans the FULL 540 px width,
	# with no empty background margin left or right of the portrait. The pitch is
	# DERIVED from the column count instead of being read from the JSON, so the
	# rule is identical for every level (and for an editor-saved one): 40 columns
	# -> 13.5 px, 80 columns -> 6.75 px, both exactly VIEW.x wide. One uniform
	# scale is used for both axes (the vertical origin the level carries is kept),
	# so the art is scaled up, never stretched, and no column is cropped: the
	# grid is 540 x 675 for every shipped level. Only x moves to 0 — the level's
	# own top offset stays, which is what keeps the HUD and the top wall clear.
	cell = VIEW.x / float(cols)
	origin = Vector2(0.0, origin.y)
	grid = level["grid"]
	# The win counts BREAKABLE bricks only: the solid border is a wall, and
	# counting it would make a level unwinnable (it can never be broken).
	bricks_total = int(level["breakable"])
	bricks_left = bricks_total
	for t in level["powerup_cells"]:
		_tip_cells.append(t)
	for u in level["unbreakable_cells"]:
		_unbreakable_cells.append(u)
	_channel_set = {}
	for ch in level["channel_cells"]:
		_channel_set[ch] = true
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
			b.setup(Vector2i(c, r), cell_center(Vector2i(c, r)), cell)
			b.unbreakable = _unbreakable_cells.has(Vector2i(c, r))
			_bodies[Vector2i(c, r)] = b


func cell_center(c: Vector2i) -> Vector2:
	return origin + (Vector2(c) + Vector2(0.5, 0.5)) * cell


## Brief 22 pacing rule: a DENSE field (see DENSE_BRICKS) plays with the fast,
## high-ball-count set; every other field keeps the reference pace. Read from
## the level that actually loaded, never from its id.
func is_dense_field() -> bool:
	return bricks_total >= DENSE_BRICKS


func ball_speed() -> float:
	return BALL_SPEED_DENSE if is_dense_field() else BALL_SPEED


func ball_cap() -> int:
	return MAX_BALLS_DENSE if is_dense_field() else MAX_BALLS


## Brief 25: the power-up drop chance at THIS instant of the take — a straight
## line from POWERUP_CHANCE_START at t=0 to POWERUP_CHANCE_END at
## POWERUP_RAMP_SECONDS, held at END afterwards. Same value on every level.
func powerup_chance() -> float:
	var t := clampf(elapsed / POWERUP_RAMP_SECONDS, 0.0, 1.0)
	return lerpf(POWERUP_CHANCE_START, POWERUP_CHANCE_END, t)


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
		var lim := _serve_angle_deg()
		var ang := deg_to_rad(rng.randf_range(-lim, lim))
		_held_ball.position = paddle.position + Vector2(0, -22.0)
		_held_ball.launch(Vector2(sin(ang), -cos(ang)) * (ball_speed() + rng.randf_range(-12.0, 12.0)))
	_held_ball = null
	state_changed.emit(state)


## The widest serve angle THIS level can thread: the ball must still be inside
## the stem gap when it reaches the bottom of the brick field. Derived from the
## level's stem width and cell size (never a hardcoded per-level value), so a
## 12 px stem gets a ~1 deg serve and a 24 px stem keeps the full 2 deg.
func _serve_angle_deg() -> float:
	var sc: Array = level.get("stem_cols", [])
	if sc.size() != 2 or cell <= 0.0:
		return SERVE_ANGLE_DEG
	var stem_w := (float(sc[1]) - float(sc[0]) + 1.0) * cell
	# Half the gap, minus the ball, times a safety factor: the serve may use
	# only ~60% of the room it has.
	var slack := maxf(0.0, stem_w * 0.5 - Ball.RADIUS) * 0.6
	var travel := maxf(20.0, PADDLE_Y - (origin.y + float(rows) * cell))
	if slack <= 0.0:
		return 0.0
	return clampf(rad_to_deg(atan(slack / travel)), 0.0, SERVE_ANGLE_DEG)


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
			_tick_star(delta)
			_tick_combo(delta)
			_tick_floor(delta)
			_tick_stars(delta)
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
	var lim := _serve_angle_deg()
	var ang := deg_to_rad(rng.randf_range(-lim, lim))
	b.launch(Vector2(sin(ang), -cos(ang)) * ball_speed())
	state_changed.emit(state)


func _tick_balls() -> void:
	for b in _balls.duplicate():
		if not is_instance_valid(b):
			_balls.erase(b)
			continue
		# The safety floor: while it is up EVERY falling ball is bounced back,
		# so nothing can drop out and cost a life. Reflecting here (instead of
		# a physics body) makes it exact: no tunnelling at high speed, and no
		# moment where a ball is between the floor and the loss line.
		if _floor != null and _floor.active() and b.vel.y > 0.0 \
				and b.position.y >= SafetyFloor.Y - Ball.RADIUS:
			b.position.y = SafetyFloor.Y - Ball.RADIUS - 0.5
			b.vel.y = -absf(b.vel.y)
			AudioManager.play("bounce", -8.0)
		# ARENA CONTAINMENT. The field is flush to the frame (Brief 25), so the
		# ball can be squeezed into a wall/brick junction and come out on the
		# wrong side; a ball outside the arena can never come back and can travel
		# sideways for a whole take (measured once: x = 15194). Reflect it back at
		# the wall's inner face instead. This never fires in normal play — it is
		# the same kind of last-resort guard as the safety floor below.
		if b.position.x < Ball.RADIUS or b.position.x > VIEW.x - Ball.RADIUS:
			b.position.x = clampf(b.position.x, Ball.RADIUS, VIEW.x - Ball.RADIUS)
			b.vel.x = -b.vel.x
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
	# Freeze FIRST: from this instant no ball or falling power-up may move or
	# break a brick, so the popup's score is exactly the HUD's score (the
	# defect this fixes was popup 18700 vs HUD 18850).
	_freeze_world()
	AudioManager.play("victory" if won else "defeat")
	if won and hud != null:
		hud.show_win(score, elapsed, stars_collected)
	elif hud != null:
		hud.show_game_over(score, bricks_left)
	state_changed.emit(state)
	game_ended.emit({
		"won": won, "score": score, "lives": lives,
		"bricks_left": bricks_left, "bricks_total": bricks_total,
		"elapsed": elapsed, "level": level_id, "seed": seed_value,
		"balls": _balls.size(), "peak_balls": peak_balls,
		"first_multiball_at": first_multiball_at,
		"stars": stars_collected, "stars_dropped": stars_dropped,
		"stars_lost": stars_lost, "peak_combo": peak_combo,
		"nukes": nukes_caught, "nuke_bricks": nuke_bricks,
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


## Auto-play: track the LOWEST ball (the one nearest the danger line), predict
## where it will cross the paddle line, and (Stage D) PLACE THE PADDLE OFF
## CENTRE so the ball leaves at a chosen angle. This is the recording mode — a
## Short is watchable with no input at all.
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
	# 2) A ball is about to arrive: AIM it. The paddle stands at
	# `arrival - rel * half_width`, so the ball lands `rel * half_width` away
	# from the paddle centre and leaves at `rel * MAX_BOUNCE_DEG` degrees.
	# |rel| <= AIM_REL_MAX keeps the contact point well inside the 104 px face,
	# so the ball is still caught — aiming never trades a save for an angle.
	if best != null and best_eta < AIM_WINDOW:
		var arrival := _predict_arrival(best)
		if best != _aim_ball or absf(arrival - _aim_arrival) > AIM_REPLAN_PX:
			_aim_ball = best
			_aim_arrival = arrival
			_aim_rel = _plan_aim_rel(arrival)
		return arrival - _aim_rel * Paddle.SIZE.x * 0.5
	# 3) A drop is catchable before the next save: take it. Brief 22 replaced
	# "chase whichever drop is lowest" with a VALUE-WEIGHTED pick — a NUKE is
	# worth more than a "+3", the "-1 ball" debuff is never chased, and the
	# 3-star collectibles are picked up too — because catching the big drops is
	# what turns a 120-ball field into a cleared level.
	var drop_x := _best_pickup_x()
	if drop_x >= 0.0:
		var travel := absf(drop_x - paddle.position.x) / 1500.0
		if best == null or best_eta > travel + 0.30:
			return drop_x
	if best != null:
		return _lead_x(best)
	return paddle.position.x


## What the AI thinks each falling drop is worth. Positive = worth a detour;
## "minus" is negative because it only removes a ball, so the paddle ignores it.
const PICKUP_VALUE := {"nuke": 9.0, "star": 7.0, "times3": 5.0, "plus3": 4.0, "floor": 2.0, "minus": -2.0}


## The x of the best falling pickup to go and catch right now (-1 when there
## is none). Score = value - time-to-paddle - sideways distance, so the biggest
## drop wins unless it is about to be lost anyway. Both power-ups and the
## 3-star collectibles are considered.
func _best_pickup_x() -> float:
	var best := 0.0
	var best_x := -1.0
	var line := paddle.position.y
	for p in _powerups:
		if not is_instance_valid(p):
			continue
		var up := p as PowerUp
		if not up.alive or up.position.y > line:
			continue
		var value := float(PICKUP_VALUE.get(up.kind, 1.0))
		if value <= 0.0:
			continue
		var eta := maxf(0.0, (line - up.position.y) / PowerUp.FALL_SPEED)
		var score := value * 10.0 - eta * 0.8 - absf(up.position.x - paddle.position.x) * 0.02
		if score > best:
			best = score
			best_x = up.position.x
	for s in _stars:
		if not is_instance_valid(s):
			continue
		var st := s as StarPickup
		if not st.alive or st.position.y > line:
			continue
		var eta2 := maxf(0.0, (line - st.position.y) / StarPickup.FALL_SPEED)
		var score2 := float(PICKUP_VALUE["star"]) * 10.0 - eta2 * 0.8 \
			- absf(st.position.x - paddle.position.x) * 0.02
		if score2 > best:
			best = score2
			best_x = st.position.x
	return best_x


## The x where a falling ball crosses the paddle line, WITH the side walls
## folded in: a return that reaches x=560 arrives back at x=520, not at 560.
## (The old version clamped instead, which mis-placed the paddle on wide
## returns and is what the aiming needs to be exact.)
func _lead_x(b: Ball) -> float:
	var x := b.position.x
	if b.vel.y > 1.0:
		var eta := clampf((paddle.position.y - b.position.y) / float(b.vel.y), 0.0, 2.0)
		x += float(b.vel.x) * eta
	x = _fold_x(x)
	return clampf(x, Paddle.SIZE.x * 0.5, VIEW.x - Paddle.SIZE.x * 0.5)


## Where the ball will actually cross the paddle line: the ball is marched DOWN
## through the level's own grid, so the corridor walls a descending ball is
## rattling between are taken into account instead of being ignored. A straight
## line prediction is what left the old paddle ~10 px off inside a 24 px
## corridor, which is the difference between catching and aiming.
func _predict_arrival(b: Ball) -> float:
	if b.vel.y <= 1.0:
		return _lead_x(b)
	var p := b.position
	var d := b.vel.normalized()
	var guard := 0
	var paddle_line := paddle.position.y - Paddle.SIZE.y * 0.5
	while p.y < paddle_line and guard < 700:
		guard += 1
		var next := p + d * AIM_STEP
		if next.x < Ball.RADIUS or next.x > VIEW.x - Ball.RADIUS:
			d.x = -d.x
			next = p + d * AIM_STEP
		var cell := _cell_at(next)
		if cell.x >= 0 and cell.y >= 0 and cell.x < cols and cell.y < rows \
				and _cell_solid(cell):
			if _unbreakable_cells.has(cell):
				if _cell_at(p).x != cell.x:
					d.x = -d.x
				else:
					d.y = -d.y
				next = p + d * AIM_STEP
			else:
				break          # a breakable brick ends the fall: it never arrives
		p = next
	return _fold_x(p.x)


## Reflect an x off the two side walls (the ball's centre can only live in
## [RADIUS, VIEW.x - RADIUS]).
func _fold_x(x: float) -> float:
	var lo := Ball.RADIUS
	var hi := VIEW.x - Ball.RADIUS
	var span := hi - lo
	if span <= 0.0:
		return lo
	var t := fposmod(x - lo, span * 2.0)
	return lo + (t if t <= span else span * 2.0 - t)


# ------------------------------------------- Stage D: the aiming auto-play
## The AI used to centre the paddle, which returns the ball at ~0 deg. A
## corridor needs an ANGLED return: the hit position on the 104 px paddle maps
## linearly to the bounce angle (-62..+62 deg, Paddle.bounce_for), so the AI can
## pick any heading up to ~50 deg by standing off centre.
##
## The heading is chosen by RAY-SIMULATING the ball forward from the paddle face
## over the level's own brick grid: a 3-degree sweep of candidate angles, a
## handful of wall and brick bounces each, and the angle that reaches the most
## BREAKABLE bricks soonest wins. Unbreakable walls (a corridor's grey walls)
## reflect instead of breaking, so a shot that just rattles around a dead end
## scores nothing and is rejected, while a shot that turns a corner and reaches
## the portrait scores.
## The search is deterministic (fixed candidate list, no rng) and only reads
## state the game already has, so a seeded take stays reproducible.
const AIM_WINDOW := 1.2         # seconds before the ball arrives that aiming runs
const AIM_REPLAN_PX := 6.0      # replan when the predicted arrival moved this far
## 0.8 of the face = ~50 deg. Keeping 10 px of face spare means a prediction
## that is a few px out still catches the ball.
const AIM_REL_MAX := 0.8
## Sweep the whole range in 3 deg steps. A corridor's periodic zig-zag makes a
## shot very sensitive to its angle (the winding fixture goes through its 24 px
## mouth at 12 deg but misses it at 9 or 18), so a coarse 10 deg sweep is not
## enough; the finer one costs nothing because the short probe stops after a
## handful of bounces.
const AIM_MIN_DEG := -48.0
const AIM_STEP_DEG := 3.0
const AIM_BOUNCES := 6          # short probe: bricks reachable straight away
## A winding corridor rattle costs one bounce per wall crossing, so the deep
## pass needs a much larger budget than the short probe (the fixture's path is
## ~1500 px and ~45 crossings, so 260 is comfortable).
const AIM_BOUNCES_DEEP := 260   # second pass when the short probe sees nothing
const AIM_STEP := 3.0           # ray-march step in px (a cell is 12 px)
const AIM_MAX_STEPS := 4200     # ~12,600 px of simulated travel, hard cap
const AIM_HIT_SCORE := 100.0
const AIM_HIT_DECAY := 11.0     # a brick hit later in the path is worth less
const AIM_EFFORT := 0.02        # break ties towards the straighter shot
## Steering into the level's OWN carved channel is worth something even when no
## brick is reachable from the paddle line: a corridor level can seal the field
## behind solid walls (level_04's portrait frame), and the channel is then the
## only way back in. `--breakout-sim level=ref_winding_track` is the same case.
const AIM_CHANNEL_BONUS := 40.0
## Inner face of the top play-field wall (centre 64, 20 px tall) plus the ball.
const AIM_TOP_Y := 78.0

var _aim_ball: Ball = null
var _aim_arrival := 0.0
var _aim_rel := 0.0
## The carved channel, as a set, for the aim planner (see AIM_CHANNEL_BONUS).
var _channel_set: Dictionary = {}


## Relative hit position (-1..1) that sends the ball at the best heading from
## `arrival_x`. Pure: same grid + same arrival -> same answer.
func _plan_aim_rel(arrival_x: float) -> float:
	var from := Vector2(clampf(arrival_x, Ball.RADIUS, VIEW.x - Ball.RADIUS),
		paddle.position.y - Paddle.SIZE.y * 0.5 - Ball.RADIUS)
	var best := -1.0e9
	var best_rel := 0.0
	for a in _aim_angles():
		var dir := Vector2(sin(deg_to_rad(a)), -cos(deg_to_rad(a)))
		var score := float(_aim_score(from, dir, AIM_BOUNCES)["score"]) - absf(a) * AIM_EFFORT
		if score > best:
			best = score
			best_rel = a / Paddle.MAX_BOUNCE_DEG
	if best < 1.0:
		# Nothing breakable within the short probe (a corridor's far end, an
		# already cleared area): look much further before settling for
		# straight up, so a winding level can still be steered into its turns.
		for a in _aim_angles():
			var dir := Vector2(sin(deg_to_rad(a)), -cos(deg_to_rad(a)))
			var score := float(_aim_score(from, dir, AIM_BOUNCES_DEEP)["score"]) - absf(a) * AIM_EFFORT
			if score > best:
				best = score
				best_rel = a / Paddle.MAX_BOUNCE_DEG
	if best < 1.0:
		# Still nothing: the field is walled off and the level's carved channel
		# is the only way in (level_04's portrait frame). Aim so the ball comes
		# BACK to the paddle line on top of the channel's stem, which is the only
		# place a straight return can enter the corridor from.
		var stem := _stem_centre_x()
		var best_setup := -1.0e9
		for a in _aim_angles():
			var dir := Vector2(sin(deg_to_rad(a)), -cos(deg_to_rad(a)))
			var res := _aim_score(from, dir, AIM_BOUNCES_DEEP)
			var end_x := float(res["end_x"])
			if end_x < 0.0:
				continue
			var score := -absf(end_x - stem) - absf(a) * AIM_EFFORT
			if score > best_setup:
				best_setup = score
				best_rel = a / Paddle.MAX_BOUNCE_DEG
	return clampf(best_rel, -AIM_REL_MAX, AIM_REL_MAX)


## Candidate bounce angles, symmetric around straight up, clamped to the range
## the paddle can actually produce (AIM_REL_MAX * MAX_BOUNCE_DEG).
func _aim_angles() -> Array:
	var out: Array = []
	var limit := AIM_REL_MAX * Paddle.MAX_BOUNCE_DEG
	var a := AIM_MIN_DEG
	while a <= limit + 0.001:
		out.append(a)
		a += AIM_STEP_DEG
	return out


## Score one candidate heading: march the ball through the grid, breaking what
## is breakable (a broken cell is passed through, like the real ball) and
## reflecting off the walls, and pay out for every distinct breakable brick.
## Returns {score, end_x}: end_x is where the simulated ball comes back to the
## paddle line (-1 when the march ran out of budget), which the corridor-entry
## pass below uses to line the NEXT return up with the level's stem.
func _aim_score(from: Vector2, dir: Vector2, max_bounces: int) -> Dictionary:
	var p := from
	var d := dir
	var score := 0.0
	var hits := 0
	var bounces := 0
	var steps := 0
	var broken := {}
	var in_channel := false
	var came_back := false
	var paddle_line := paddle.position.y - Paddle.SIZE.y * 0.5
	while bounces < max_bounces and steps < AIM_MAX_STEPS:
		steps += 1
		var next := p + d * AIM_STEP
		if next.x < Ball.RADIUS or next.x > VIEW.x - Ball.RADIUS:
			d.x = -d.x
			next = p + d * AIM_STEP
		if next.y < AIM_TOP_Y:
			d.y = -d.y
			next = p + d * AIM_STEP
		if next.y > paddle_line:
			came_back = true
			break
		var cell := _cell_at(next)
		if cell.x >= 0 and cell.y >= 0 and cell.x < cols and cell.y < rows \
				and not broken.has(cell) and _cell_solid(cell):
			if _unbreakable_cells.has(cell):
				bounces += 1
				if _cell_at(p).x != cell.x:
					d.x = -d.x
				else:
					d.y = -d.y
				next = p + d * AIM_STEP
			else:
				broken[cell] = true
				hits += 1
				score += maxf(0.0, AIM_HIT_SCORE - AIM_HIT_DECAY * float(hits - 1))
		elif _channel_set.has(cell):
			in_channel = true
		p = next
	if in_channel:
		score += AIM_CHANNEL_BONUS
	return {"score": score, "end_x": _fold_x(p.x) if came_back else -1.0}


func _cell_at(p: Vector2) -> Vector2i:
	return Vector2i(floori((p.x - origin.x) / cell), floori((p.y - origin.y) / cell))


func _cell_solid(c: Vector2i) -> bool:
	if c.y < 0 or c.y >= rows or c.x < 0 or c.x >= cols:
		return false
	return (grid[c.y * cols + c.x] as Color).a >= 0.5


func _input(event: InputEvent) -> void:
	if state == STATE_LEVEL_CLEAR or state == STATE_GAME_OVER:
		if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
			# A take launched from the editor goes back to the editor, not the menu.
			if Game.editor_return:
				Game.goto_editor()
			else:
				Game.goto_menu()
		elif event is InputEventKey and (event as InputEventKey).pressed \
				and (event as InputEventKey).keycode == KEY_R:
			Game.restart_game()
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
	var cap := ball_cap()
	for i in n:
		if _balls.size() >= cap:
			break
		var ang := deg_to_rad(rng.randf_range(-62.0, 62.0))
		var pos := Vector2(clampf(at.x, 12.0, 528.0), clampf(at.y, 80.0, PADDLE_Y - 40.0))
		var b := _new_ball(pos)
		b.launch(Vector2(sin(ang), -cos(ang)) * ball_speed())
		added += 1
	return added


## Stage C item 1 — "Ball Multitude": EVERY ball in play splits into three AT
## ITS OWN POSITION. The parent keeps its exact position and velocity; two
## children appear on top of it with the same speed and their headings rotated
## +25 and -25 degrees, so the trio diverges instead of stacking. The paddle is
## not involved at all (spawning balls at the paddle is "+3"'s job).
## Returns how many balls were added; the total is capped at MAX_BALLS, and a
## triple that would overshoot the cap only adds up to it.
func _split_balls_in_place() -> int:
	var parents: Array = _balls.duplicate()
	var added := 0
	var cap := ball_cap()
	for parent in parents:
		if not is_instance_valid(parent):
			continue
		var b := parent as Ball
		# A held or already-lost ball has no heading to spread around.
		if not b.active or b.vel.length_squared() < 1.0:
			continue
		for side in [-1.0, 1.0]:
			if _balls.size() >= cap:
				return added
			var child := _new_ball(b.position)
			child.launch(b.vel.rotated(deg_to_rad(SPLIT_SPREAD_DEG) * side))
			added += 1
	return added


# ------------------------------------------------------------------ bricks
func break_cell(c: Vector2i, silent := false) -> void:
	# Once the level is clear (or the take is over) nothing may break, score or
	# drop: the freeze is only complete if the scoring path itself is closed.
	if state == STATE_LEVEL_CLEAR or state == STATE_GAME_OVER:
		return
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
	# Stage C item 5: the combo chain is the brick's multiplier.
	_bump_combo()
	score += COMBO_SCORE * combo * score_mult
	field.queue_redraw()
	var p := cell_center(c)
	_star_source = p
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
			and (was_tip or first_drop or rng.randf() < powerup_chance()):
		_drop_powerup(p)
	_check_star_milestones()
	if bricks_left <= win_leftover():
		_finish(true)


# ------------------------------------------------------------------ power-ups
## The drop pool in ONE place, so the drop-rate suite measures exactly the code
## gameplay runs. The fixed order also keeps rng consumption deterministic.
func _pick_powerup_kind() -> String:
	var r := rng.randf()
	var acc := 0.0
	for kind in DROP_ORDER:
		acc += float(DROP_WEIGHTS[kind])
		if r < acc:
			return kind
	return "floor"


func _drop_powerup(at: Vector2) -> void:
	if state == STATE_LEVEL_CLEAR or state == STATE_GAME_OVER:
		return
	if _powerups.size() >= MAX_POWERUPS:
		return
	var p := PowerUp.new()
	p.kind = _pick_powerup_kind()
	match p.kind:
		"times3":
			p.tint = pal.get("powerup_gold", Color(0.95, 0.75, 0.15))
		"minus":
			p.tint = pal.get("powerup_orange", Color(0.95, 0.52, 0.15))
		"star":
			p.tint = pal.get("star", Color(0.98, 0.82, 0.28))
		"floor":
			p.tint = pal.get("safety_floor", Color(0.30, 0.90, 0.95))
		"nuke":
			p.tint = pal.get("powerup_nuke", Color(1.0, 0.25, 0.72))
		_:
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


func _collect_powerup(up: PowerUp) -> void:
	up.alive = false
	_powerups.erase(up)
	var at := up.position
	up.queue_free()
	powerups_caught += 1
	AudioManager.play("powerup")
	FX.ring(fx_root, at, pal.get("powerup_blue", Color(0.22, 0.48, 0.92)), 26.0, 0.40)
	if first_multiball_at < 0.0 and (up.kind == "plus3" or up.kind == "times3"):
		first_multiball_at = elapsed
	match up.kind:
		"times3":
			# Stage C: Ball Multitude splits EVERY ball where it is — the paddle
			# spawns nothing.
			_split_balls_in_place()
		"floor":
			# One floor only: a second catch REFRESHES the timer.
			_floor.start(FLOOR_SECONDS)
		"minus":
			# DESIGN CHOICE: -1 ball; a single remaining ball is never taken.
			_remove_one_ball()
		"star":
			# DESIGN CHOICE: flat bonus + x3 brick score for STAR_SECONDS.
			score += STAR_BONUS
			score_mult = STAR_MULT
			star_left = STAR_SECONDS
		"nuke":
			# Brief 22: radial blast, described in NUKE_RADIUS above.
			_detonate_nuke()
		_:
			_add_balls(3, at)
	paddle.show_buff(BUFF_SECONDS)


## Brief 22 — the NUKE blast. shatter every breakable brick inside
## NUKE_RADIUS cells of the blast cell through the normal break_cell() path,
## so scoring, combos, drops, star milestones and the win rule all behave
## exactly as in normal play. Walls (unbreakable cells) are left standing.
## Returns the number of bricks broken.
func _detonate_nuke() -> int:
	if state != STATE_PLAYING:
		return 0
	var blast := _nuke_blast_cell()
	if blast.x < 0:
		return 0
	var centre := cell_center(blast)
	var r2 := NUKE_RADIUS * NUKE_RADIUS
	var broke := 0
	for c in _bodies.keys():
		var cellp: Vector2i = c
		var dx := absi(cellp.x - blast.x)
		var dy := absi(cellp.y - blast.y)
		if dx * dx + dy * dy > r2:
			continue
		var b: Brick = _bodies[c]
		if b.unbreakable:
			continue
		break_cell(cellp, true)
		broke += 1
		if state != STATE_PLAYING:
			# The blast cleared the level (the win rule fired inside break_cell).
			break
	nukes_caught += 1
	nuke_bricks += broke
	var tint: Color = pal.get("powerup_nuke", Color(1.0, 0.25, 0.72))
	FX.flash(fx_root, centre, tint, 150.0, 0.55)
	FX.ring(fx_root, centre, tint, 120.0, 0.60)
	FX.ring(fx_root, centre, Color(1, 1, 1, 0.9), 70.0, 0.40)
	AudioManager.play("powerup")
	return broke


## The cell a NUKE detonates on: the lowest remaining breakable brick, ties
## broken by the closest to the field's centre column. -1 when the field has
## no breakable brick left.
func _nuke_blast_cell() -> Vector2i:
	var best := Vector2i(-1, -1)
	var best_row := -1
	var best_dx := 1.0e9
	for c in _bodies.keys():
		var cellp: Vector2i = c
		var b: Brick = _bodies[c]
		if b.unbreakable:
			continue
		var dx := absf(float(cellp.x) - float(cols) * 0.5)
		if cellp.y > best_row or (cellp.y == best_row and dx < best_dx):
			best_row = cellp.y
			best_dx = dx
			best = cellp
	return best


## Take exactly one ball out of play. Returns false (and does nothing) at one
## ball, so the orange debuff can never end a take by itself.
func _remove_one_ball() -> bool:
	if _balls.size() <= 1:
		return false
	var b: Ball = _balls.pop_back()
	if is_instance_valid(b):
		b.active = false
		b.vel = Vector2.ZERO
		b.queue_free()
	return true


func _tick_star(delta: float) -> void:
	if score_mult <= 1:
		return
	star_left = maxf(0.0, star_left - delta)
	if star_left <= 0.0:
		star_left = 0.0
		score_mult = 1


# ------------------------------------------------- Stage C: combo (item 5)
## 1.2 s between breaks keeps the chain alive; the chain length IS the score
## multiplier (cap 999) and a brick pays 10 x combo (times the Stage B star
## multiplier when that is running).
func _tick_combo(delta: float) -> void:
	if _combo_left <= 0.0:
		return
	_combo_left = maxf(0.0, _combo_left - delta)
	if _combo_left <= 0.0 and combo != 1:
		combo = 1


func _bump_combo() -> void:
	if _combo_left > 0.0:
		combo = mini(combo + 1, COMBO_MAX)
	else:
		combo = 1
	_combo_left = COMBO_WINDOW
	peak_combo = maxi(peak_combo, combo)


# ------------------------------------- Stage C: safety floor (item 3)
func _tick_floor(delta: float) -> void:
	if _floor != null:
		_floor.tick(delta)


# ------------------------------- Stage C: the 3-star collectible (item 2)
## Fire at most ONE milestone per call, so two stars can never be spawned on
## top of each other: the next break (or the next frame's clock check) fires
## the next one.
func _check_star_milestones() -> void:
	if state == STATE_LEVEL_CLEAR or state == STATE_GAME_OVER:
		return
	var broken := maxi(0, bricks_total - bricks_left)
	var frac := float(broken) / maxf(1.0, float(bricks_total))
	for i in STAR_MILESTONES:
		if bool(_star_done[i]):
			continue
		# EITHER trigger, whichever comes first, for THIS milestone.
		if frac >= float(STAR_BRICK_FRACS[i]) or elapsed >= float(STAR_TIMES[i]):
			_star_done[i] = true
			_drop_star()
			return


## A star falls from the last broken brick (clamped into the field), or from
## the top of the field when the clock — not a brick — fired the milestone.
func _drop_star() -> void:
	var src := _star_source
	if src == Vector2.ZERO:
		src = Vector2(VIEW.x * 0.5, origin.y + cell * 2.0)
	var s := StarPickup.new()
	s.position = Vector2(
		clampf(src.x, StarPickup.RADIUS, VIEW.x - StarPickup.RADIUS),
		clampf(src.y, origin.y + cell, PADDLE_Y - 220.0))
	stars_root.add_child(s)
	_stars.append(s)
	stars_dropped += 1


## Catch or lose every falling star. A star that gets past the paddle is LOST
## for the level: its milestone is already marked done, so it never re-drops.
func _tick_stars(_delta: float) -> void:
	_check_star_milestones()
	if _stars.is_empty():
		return
	var rect := paddle.rect()
	for s in _stars.duplicate():
		if not is_instance_valid(s):
			_stars.erase(s)
			continue
		var star := s as StarPickup
		if not star.alive:
			_stars.erase(star)
			continue
		if star.overlaps(rect):
			_collect_star(star)
		elif star.position.y > PADDLE_Y + 24.0:
			# past the paddle: gone for this level
			star.alive = false
			_stars.erase(star)
			star.queue_free()
			stars_lost += 1


func _collect_star(star: StarPickup) -> void:
	star.alive = false
	_stars.erase(star)
	var at := star.position
	star.queue_free()
	stars_collected += 1
	AudioManager.play("powerup")
	FX.flash(fx_root, at, pal.get("star", Color(0.98, 0.82, 0.28)), 46.0, 0.45)
	FX.ring(fx_root, at, pal.get("star", Color(0.98, 0.82, 0.28)), 34.0, 0.50)


## The win / game-over freeze. Ball and PowerUp move in their OWN _physics_process,
## so leaving the flow state alone is not enough: every one of them is stopped
## here, and the lists are emptied so nothing can be scored after the popup.
func _freeze_world() -> void:
	for b in _balls:
		if is_instance_valid(b):
			(b as Ball).active = false
			(b as Ball).vel = Vector2.ZERO
	_balls.clear()
	for p in _powerups:
		if is_instance_valid(p):
			(p as PowerUp).alive = false
			p.queue_free()
	_powerups.clear()
	for s in _stars:
		if is_instance_valid(s):
			(s as StarPickup).alive = false
			s.queue_free()
	_stars.clear()
	if _floor != null:
		_floor.clear()
	_held_ball = null


# ------------------------------------------------------------------ reporting / tests
func state_name() -> String:
	return state


func results_visible() -> bool:
	return state == STATE_LEVEL_CLEAR or state == STATE_GAME_OVER


func ball_count() -> int:
	return _balls.size()


func powerup_count() -> int:
	return _powerups.size()


func star_count() -> int:
	return _stars.size()


func star_pickups() -> Array:
	return _stars


func floor_active() -> bool:
	return _floor != null and _floor.active()


func floor_left() -> float:
	return 0.0 if _floor == null else _floor.left


func combo_value() -> int:
	return combo


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


## Test housekeeping: drop every falling power-up (a leftover "+3" caught by
## the paddle would spawn balls that break bricks mid-measurement).
func debug_clear_powerups() -> void:
	for p in _powerups.duplicate():
		if is_instance_valid(p):
			(p as PowerUp).alive = false
			p.queue_free()
	_powerups.clear()


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
	elif kind == "floor":
		p.tint = pal.get("safety_floor", Color(0.30, 0.90, 0.95))
	elif kind == "nuke":
		p.tint = pal.get("powerup_nuke", Color(1.0, 0.25, 0.72))
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


## Break up to `n` breakable bricks silently (the real break_cell path, so
## scoring, drops, combos and star milestones behave exactly as in play).
func debug_break_n(n: int) -> int:
	var broken := 0
	for c in _bodies.keys():
		if broken >= n:
			break
		var b: Brick = _bodies[c]
		if b.unbreakable:
			continue
		break_cell(c, true)
		broken += 1
	return broken


## Close the combo chain (a deterministic starting point for the combo and
## star-multiplier suites, which measure ONE brick's value).
func debug_reset_combo() -> void:
	combo = 1
	_combo_left = 0.0
	peak_combo = 1
