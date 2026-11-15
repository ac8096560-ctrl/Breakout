class_name UITheme
## UI style factories — one consistent premium look for menu + HUD.


static func panel_style(bg := Color(0.045, 0.075, 0.135, 0.90), radius := 14,
		border := Color(0.30, 0.55, 0.75, 0.35), bw := 1, shadow := 10) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(radius)
	sb.set_border_width_all(bw)
	sb.border_color = border
	sb.shadow_color = Color(0, 0, 0, 0.45)
	sb.shadow_size = shadow
	sb.shadow_offset = Vector2(0, 4)
	return sb


static func button(text: String, fsize := 22, accent := Color(0.15, 0.80, 0.45), size := Vector2(240, 52)) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = size
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_size_override("font_size", fsize)
	b.add_theme_color_override("font_color", Color(0.96, 0.99, 1.0))
	b.add_theme_color_override("font_hover_color", Color(1, 1, 1))
	b.add_theme_color_override("font_pressed_color", Color(0.85, 0.95, 0.9))
	var sb := panel_style(Color(accent.r * 0.35, accent.g * 0.35, accent.b * 0.35, 0.95), 12, Color(accent, 0.75), 1, 8)
	var sb_h := panel_style(Color(accent.r * 0.55, accent.g * 0.55, accent.b * 0.55, 0.98), 12, Color(accent, 1.0), 1, 10)
	var sb_p := panel_style(Color(accent.r * 0.25, accent.g * 0.25, accent.b * 0.25, 0.95), 12, Color(accent, 0.6), 1, 4)
	b.add_theme_stylebox_override("normal", sb)
	b.add_theme_stylebox_override("hover", sb_h)
	b.add_theme_stylebox_override("pressed", sb_p)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	# EVERY button built by the shared factory gets the same subtile press
	# click — menu, HUD, Studio and Designer alike — so no screen has to
	# remember to wire it, and no button can end up silent.
	b.pressed.connect(func(): AudioManager.play("click"))
	return b


static func small_button(text: String, size := Vector2(46, 30)) -> Button:
	var b := button(text, 11, Color(0.35, 0.65, 0.9), size)
	return b


static func label(text: String, fsize := 20, col := Color(0.9, 0.94, 1.0), outline := 0, ocol := Color(0, 0, 0, 0.65)) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", fsize)
	l.add_theme_color_override("font_color", col)
	if outline > 0:
		l.add_theme_color_override("font_outline_color", ocol)
		l.add_theme_constant_override("outline_size", outline)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


static func chip(color: Color, size := Vector2(13, 13), radius := 4) -> Panel:
	var p := Panel.new()
	var sb := panel_style(color, radius, Color(1, 1, 1, 0.25), 1, 0)
	sb.shadow_size = 0
	p.add_theme_stylebox_override("panel", sb)
	p.custom_minimum_size = size
	p.size = size
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return p
