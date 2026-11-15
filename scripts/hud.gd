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
var _dim: ColorRect
var _popup: Panel
var _title: Label
var _sub: Label
var _stars: Control


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

	_lives = UITheme.label("LIVES 3", 13, Color(0.96, 0.72, 0.70), 3, Color(0, 0, 0, 0.85))
	_lives.position = Vector2(380, 6)
	_lives.size = Vector2(150, 18)
	_lives.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	add_child(_lives)

	_level = UITheme.label("", 10, Color(0.72, 0.74, 0.78), 3, Color(0, 0, 0, 0.85))
	_level.position = Vector2(240, 25)
	_level.size = Vector2(290, 16)
	_level.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	add_child(_level)


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


func show_win(score: int, seconds: float) -> void:
	_dim.visible = true
	_popup.visible = true
	_title.text = "Congratulations"
	_sub.text = "You win!"
	_stars.visible = true
	_stars.queue_redraw()
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


## Three gold stars, drawn (no font glyph dependency).
class StarRow extends Control:
	func _draw() -> void:
		var cx := size.x * 0.5
		var cy := size.y * 0.5
		for i in 3:
			var offset := Vector2(cx + float(i - 1) * 46.0, cy)
			_draw_star(offset, 17.0, Color(0.98, 0.82, 0.28))
			_draw_star(offset, 17.0, Color(1, 0.94, 0.62), true)

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
