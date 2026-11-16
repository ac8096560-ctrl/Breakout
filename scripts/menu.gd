extends Control
## Code-built menu (same pattern as WorldRace's menu.gd): title, PLAY, portrait
## select, seed select, auto-play toggle and the three audio sliders. The main
## scene of the project.

var _seed_label: Label
var _level_btn: Button
var _auto_btn: Button


func _ready() -> void:
	_build_background()
	_build_title()
	_build_buttons()
	_build_audio()


func _build_background() -> void:
	var bg := ColorRect.new()
	bg.size = Vector2(540, 960)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/bg.gdshader")
	var th := Themes.get_theme(Game.theme_id)
	mat.set_shader_parameter("top", th.background)
	mat.set_shader_parameter("bottom", th.floor)
	mat.set_shader_parameter("center_glow", th.brick)
	mat.set_shader_parameter("glow_amount", 0.35)
	bg.material = mat
	add_child(bg)

	# a faint pixel grid behind the title, like an unlit brick field
	var field := Control.new()
	field.size = Vector2(540, 960)
	field.mouse_filter = Control.MOUSE_FILTER_IGNORE
	field.draw.connect(func() -> void:
		var c: Color = th.brick
		c.a = 0.055
		for y in 34:
			for x in 27:
				field.draw_rect(Rect2(24 + x * 18, 300 + y * 18, 12, 12), c))
	add_child(field)


func _build_title() -> void:
	var glow := UITheme.label("PIXEL BREAKOUT", 52, Color(0.95, 0.35, 0.35, 0.28))
	glow.position = Vector2(0, 118)
	glow.size = Vector2(540, 70)
	glow.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(glow)

	var title := UITheme.label("PIXEL BREAKOUT", 48, Color(0.96, 0.93, 0.93), 8,
		Color(0.35, 0.05, 0.06, 1.0))
	title.position = Vector2(0, 122)
	title.size = Vector2(540, 70)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(title)

	var sub := UITheme.label("TWO PATHS. ONE BALL. WHICH WAY WILL IT GO?", 13,
		Color(0.80, 0.66, 0.66))
	sub.position = Vector2(0, 196)
	sub.size = Vector2(540, 22)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(sub)


func _build_buttons() -> void:
	# Stage B: the designer mode lives one tap from the menu.
	var editor := UITheme.button("LEVEL EDITOR", 15, Color(0.30, 0.72, 0.62), Vector2(300, 44))
	editor.position = Vector2(120, 502)
	editor.pressed.connect(func() -> void: Game.goto_editor())
	add_child(editor)

	_level_btn = UITheme.button(_level_text(), 14, Color(0.95, 0.75, 0.35), Vector2(300, 44))
	_level_btn.position = Vector2(120, 560)
	_level_btn.pressed.connect(func() -> void:
		Game.menu_level_idx = (Game.menu_level_idx + 1) % Game.LEVELS.size()
		_level_btn.text = _level_text())
	add_child(_level_btn)

	var play := UITheme.button("PLAY", 30, Color(0.92, 0.35, 0.35), Vector2(300, 76))
	play.position = Vector2(120, 618)
	play.pressed.connect(func() -> void:
		Game.start_game(Game.resolve_seed()))
	add_child(play)

	_auto_btn = UITheme.button(_auto_text(), 14, Color(0.35, 0.65, 0.9), Vector2(300, 40))
	_auto_btn.position = Vector2(120, 706)
	_auto_btn.pressed.connect(func() -> void:
		Game.auto_play = not Game.auto_play
		_auto_btn.text = _auto_text())
	add_child(_auto_btn)

	var left := UITheme.button("<", 20, Color(0.3, 0.55, 0.85), Vector2(44, 40))
	left.position = Vector2(178, 762)
	left.pressed.connect(func() -> void: _cycle_seed(-1))
	add_child(left)

	_seed_label = UITheme.label(Game.seed_label(), 18, Color(0.85, 0.88, 0.94))
	_seed_label.position = Vector2(230, 772)
	_seed_label.size = Vector2(80, 24)
	_seed_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(_seed_label)

	var right := UITheme.button(">", 20, Color(0.3, 0.55, 0.85), Vector2(44, 40))
	right.position = Vector2(318, 762)
	right.pressed.connect(func() -> void: _cycle_seed(1))
	add_child(right)

	var foot := UITheme.label("GODOT 4.7  •  PORTRAIT 540x960  •  PORTRAIT-BRICK LEVELS", 11,
		Color(0.55, 0.44, 0.46))
	foot.position = Vector2(0, 930)
	foot.size = Vector2(540, 20)
	foot.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(foot)


func _build_audio() -> void:
	var panel := Panel.new()
	panel.position = Vector2(90, 812)
	panel.size = Vector2(360, 110)
	panel.add_theme_stylebox_override("panel", UITheme.panel_style(
		Color(0.05, 0.04, 0.045, 0.86), 12, Color(0.55, 0.32, 0.32, 0.45), 1, 8))
	add_child(panel)

	for i in 3:
		var key: String = ["master", "sfx", "music"][i]
		var y := 10 + i * 32
		var lab := UITheme.label(["MASTER", "SFX", "MUSIC"][i], 10, Color(0.86, 0.78, 0.78))
		lab.position = Vector2(16, y + 4)
		lab.size = Vector2(66, 16)
		panel.add_child(lab)
		var slider := HSlider.new()
		slider.min_value = 0.0
		slider.max_value = 1.0
		slider.step = 0.05
		slider.value = AudioManager.volume(key)
		slider.position = Vector2(86, y)
		slider.size = Vector2(214, 20)
		slider.focus_mode = Control.FOCUS_NONE
		panel.add_child(slider)
		var val := UITheme.label("%d%%" % roundi(slider.value * 100.0), 10, Color(0.7, 0.62, 0.62))
		val.position = Vector2(306, y + 2)
		val.size = Vector2(42, 16)
		val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		panel.add_child(val)
		var bound_key := key
		slider.value_changed.connect(func(v: float) -> void:
			AudioManager.set_volume(bound_key, v)
			val.text = "%d%%" % roundi(v * 100.0))
		slider.drag_ended.connect(func(_changed: bool) -> void: AudioManager.play("click"))


func _level_text() -> String:
	return "PORTRAIT: %s" % Game.level_display_name()


func _auto_text() -> String:
	return "AUTO-PLAY: %s" % ("ON" if Game.auto_play else "OFF")


func _cycle_seed(dir: int) -> void:
	Game.menu_seed_idx = posmod(Game.menu_seed_idx + dir, Game.SEED_OPTIONS.size())
	_seed_label.text = Game.seed_label()
