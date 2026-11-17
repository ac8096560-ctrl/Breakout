class_name BreakoutHUD extends Control
## Minimal HUD: score / lives / bricks left / level name in the thin band above
## the brick field, plus the two result popups (win and game over).
##
## The reference has NO in-play HUD at all; this project keeps it deliberately
## tiny and out of the way so the portrait stays the star.

var game: Node = null
var pal: Dictionary = {}

var _score: Label
var _lives: Label
var _bricks: Label
var _level: Label
var _mult: Label
var _combo: Label
var _nukes: Label
var _stars_hud: StarRow
var _dim: ColorRect
var _popup: Panel
var _title: Label
var _sub: Label
var _stars: StarRow
var _star_banner: Label
## Stars caught on this level (0..3), mirrored from the game each frame.
var stars_shown := 0
var combo_shown := 1


func bind(g: Node, colors: Dictionary) -> void:
	game = g
	pal = colors
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	size = Vector2(540, 960)
	_build_top()
	_build_result()


func _build_top() -> void:
	_score = UITheme.label("SCORE 0", 13, Color(0.96, 0.96, 0.96), 3, Color(0, 0, 0, 0.85))
	_score.position = Vector2(10, 6)
	_score.size = Vector2(180, 18)
	add_child(_score)

	_bricks = UITheme.label("BRICKS 0", 11, Color(0.78, 0.80, 0.84), 3, Color(0, 0, 0, 0.85))
	_bricks.position = Vector2(10, 25)
	_bricks.size = Vector2(200, 16)
	add_child(_bricks)

	# Brief 22 — the NUKE counter (its own hot-pink so it matches the drop).
	_nukes = UITheme.label("", 11, Color(1.0, 0.45, 0.82), 3, Color(0, 0, 0, 0.85))
	_nukes.position = Vector2(10, 43)
	_nukes.size = Vector2(200, 16)
	_nukes.visible = false
	add_child(_nukes)

	_lives = UITheme.label("LIVES 3", 13, Color(0.96, 0.72, 0.70), 3, Color(0, 0, 0, 0.85))
	_lives.position = Vector2(380, 6)
	_lives.size = Vector2(150, 18)
	_lives.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	add_child(_lives)

	_level = UITheme.label("", 10, Color(0.72, 0.74, 0.78), 3, Color(0, 0, 0, 0.85))
	_level.position = Vector2(332, 25)
	_level.size = Vector2(198, 16)
	_level.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	add_child(_level)

	# Stage C — the 3-star collectible, drawn (no font glyph dependency): three
	# stars side by side, filled for caught, hollow for not-yet/ lost.
	_stars_hud = StarRow.new()
	_stars_hud.position = Vector2(158, 21)
	_stars_hud.size = Vector2(60, 22)
	_stars_hud.radius = 7.5
	_stars_hud.spacing = 20.0
	add_child(_stars_hud)

	# Stage C — the combo chain, shown only while it is chaining (combo > 1).
	_combo = UITheme.label("", 12, Color(0.62, 0.94, 1.0), 3, Color(0, 0, 0, 0.85))
	_combo.position = Vector2(220, 24)
	_combo.size = Vector2(108, 18)
	_combo.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_combo.visible = false
	add_child(_combo)

	# The star bonus multiplier, shown only while it runs (the paddle badge is a
	# separate status indicator and is left exactly as it was).
	_mult = UITheme.label("", 12, Color(0.99, 0.85, 0.35), 3, Color(0, 0, 0, 0.85))
	_mult.position = Vector2(190, 4)
	_mult.size = Vector2(180, 18)
	_mult.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_mult.visible = false
	add_child(_mult)


func _build_result() -> void:
	_dim = ColorRect.new()
	_dim.color = Color(0, 0, 0, 0.55)
	_dim.size = Vector2(540, 960)
	_dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_dim.visible = false
	add_child(_dim)

	_popup = Panel.new()
	_popup.size = Vector2(420, 250)
	_popup.position = Vector2(60, 355)
	_popup.add_theme_stylebox_override("panel", UITheme.panel_style(
		Color(0.13, 0.13, 0.15, 0.98), 22, Color(1, 1, 1, 0.18), 2, 18))
	_popup.visible = false
	_popup.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_popup)

	_title = UITheme.label("", 34, Color(1, 1, 1), 4, Color(0, 0, 0, 0.6))
	_title.position = Vector2(0, 44)
	_title.size = Vector2(420, 46)
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_popup.add_child(_title)

	_sub = UITheme.label("", 20, Color(0.92, 0.92, 0.94), 3, Color(0, 0, 0, 0.6))
	_sub.position = Vector2(0, 96)
	_sub.size = Vector2(420, 30)
	_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_popup.add_child(_sub)

	_star_banner = UITheme.label("", 22, Color(0.99, 0.86, 0.35), 4, Color(0.35, 0.20, 0.02, 0.9))
	_star_banner.position = Vector2(0, 4)
	_star_banner.size = Vector2(420, 28)
	_star_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_star_banner.visible = false
	_popup.add_child(_star_banner)

	_stars = StarRow.new()
	_stars.position = Vector2(0, 146)
	_stars.size = Vector2(420, 46)
	_stars.visible = false
	_popup.add_child(_stars)


func _process(_delta: float) -> void:
	if game == null or not is_instance_valid(game):
		return
	_score.text = "SCORE %d" % int(game.score)
	_lives.text = "LIVES %d" % int(game.lives)
	_bricks.text = "BRICKS %d" % int(game.bricks_left)
	_level.text = "%s  •  SEED %d" % [str(game.level.get("name", "")), int(game.seed_value)]
	var nukes := int(game.nukes_caught)
	_nukes.visible = nukes > 0
	if nukes > 0:
		_nukes.text = "NUKE x%d  (%d BRICKS)" % [nukes, int(game.nuke_bricks)]
	var mult := int(game.score_mult)
	_mult.visible = mult > 1
	if mult > 1:
		_mult.text = "x%d  %.1fs" % [mult, float(game.star_left)]
	if int(game.stars_collected) != stars_shown:
		stars_shown = int(game.stars_collected)
		_stars_hud.count = stars_shown
		_stars_hud.queue_redraw()
	combo_shown = int(game.combo)
	_combo.visible = combo_shown > 1
	if combo_shown > 1:
		_combo.text = "COMBO x%d" % combo_shown


## The win popup: the score line, the three stars this level actually earned,
## and — when all three were caught — a prominent "3 STAR!" banner.
func show_win(score: int, seconds: float, stars: int) -> void:
	_dim.visible = true
	_popup.visible = true
	_title.text = "Congratulations"
	_sub.text = "You win!"
	stars_shown = clampi(stars, 0, 3)
	_stars.count = stars_shown
	_stars.visible = true
	_stars.queue_redraw()
	_star_banner.visible = stars_shown >= 3
	if stars_shown >= 3:
		_star_banner.text = "3 STAR!"
	# a tiny score line keeps the win screen honest without becoming a tally
	var line := UITheme.label("SCORE %d  •  %.1fs" % [score, seconds], 12,
		Color(0.8, 0.84, 0.9))
	line.position = Vector2(0, 200)
	line.size = Vector2(420, 18)
	line.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_popup.add_child(line)


func show_game_over(score: int, bricks_left: int) -> void:
	_dim.visible = true
	_popup.visible = true
	_title.text = "Game Over"
	_title.add_theme_color_override("font_color", pal.get("game_over", Color(0.86, 0.28, 0.26)))
	_sub.text = "SCORE %d  •  %d BRICKS LEFT" % [score, bricks_left]
	var hint := UITheme.label("CLICK OR PRESS R TO RETRY", 11, Color(0.72, 0.74, 0.8))
	hint.position = Vector2(0, 190)
	hint.size = Vector2(420, 18)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_popup.add_child(hint)


## Three stars, drawn (no font glyph dependency). `count` of them are FILLED
## (caught); the rest are hollow — not yet collected, or lost for this level.
class StarRow extends Control:
	var count := 0
	var radius := 17.0
	var spacing := 46.0

	func _draw() -> void:
		var cx := size.x * 0.5
		var cy := size.y * 0.5
		for i in 3:
			var offset := Vector2(cx + float(i - 1) * spacing, cy)
			if i < count:
				_draw_star(offset, radius, Color(0.98, 0.82, 0.28))
				_draw_star(offset, radius, Color(1, 0.94, 0.62), true)
			else:
				_draw_star(offset, radius, Color(0.55, 0.55, 0.60, 0.90), true)

	func _draw_star(center: Vector2, radius: float, col: Color, outline := false) -> void:
		var pts := PackedVector2Array()
		for i in 10:
			var r := radius if i % 2 == 0 else radius * 0.44
			var a := -PI * 0.5 + float(i) * PI / 5.0
			pts.append(center + Vector2(cos(a), sin(a)) * r)
		if outline:
			pts.append(pts[0])
			draw_polyline(pts, col, 1.5)
		else:
			draw_colored_polygon(pts, col)


## --- machine-readable mirrors of what the HUD DRAWS (used by the suites; the
## player sees the drawn star row and the COMBO label) ---------------------
func star_display() -> String:
	return "★".repeat(clampi(stars_shown, 0, 3)) + "☆".repeat(3 - clampi(stars_shown, 0, 3))


func combo_text() -> String:
	return _combo.text if _combo.visible else ""


func win_banner_text() -> String:
	return _star_banner.text if _star_banner.visible else ""


func win_stars() -> int:
	return _stars.count
