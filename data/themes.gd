class_name Themes
## Visual themes for Pixel Breakout. A theme is PURE DATA: the brick field, the
## paddle, the ball, the frame and the HUD read it. Adding a palette (neon,
## paper, arcade ...) means adding an entry here — no gameplay change.
##
## Breakout keys the game reads: brick / brick_frame / paddle / ball /
## background / floor / frame / accent / powerup_blue / powerup_green /
## game_over.

const THEMES := {
	# The reference look: uniform muted rose bricks, grey frame, a thin red
	# strip along the very top edge, black play floor.
	"rose": {
		"display": "Muted Rose",
		"background": Color(0.055, 0.055, 0.062),
		"floor": Color(0.012, 0.012, 0.016),
		"frame": Color(0.52, 0.54, 0.58),
		"frame_dark": Color(0.28, 0.29, 0.33),
		"top_strip": Color(0.72, 0.12, 0.14),
		"brick": Color(0.647, 0.275, 0.275),
		"brick_dark": Color(0.50, 0.19, 0.20),
		"paddle": Color(0.95, 0.52, 0.46),
		"paddle_dark": Color(0.78, 0.35, 0.31),
		"ball": Color(1.0, 1.0, 1.0),
		"accent": Color(0.90, 0.20, 0.22),
		"powerup_blue": Color(0.22, 0.48, 0.92),
		"powerup_green": Color(0.20, 0.70, 0.36),
		"powerup_gold": Color(0.95, 0.75, 0.15),
		"powerup_orange": Color(0.95, 0.52, 0.15),
		"game_over": Color(0.86, 0.28, 0.26),
		"star": Color(0.98, 0.82, 0.28),
		"safety_floor": Color(0.30, 0.90, 0.95),
		"guide": Color(0.46, 0.48, 0.52),
	},
	# A cool alternative palette — same geometry, different mood.
	"neon": {
		"display": "Neon Arcade",
		"background": Color(0.035, 0.045, 0.075),
		"floor": Color(0.02, 0.025, 0.05),
		"frame": Color(0.30, 0.62, 0.82),
		"frame_dark": Color(0.16, 0.32, 0.45),
		"top_strip": Color(0.36, 0.86, 0.95),
		"brick": Color(0.29, 0.52, 0.86),
		"brick_dark": Color(0.18, 0.33, 0.60),
		"paddle": Color(0.40, 0.92, 0.80),
		"paddle_dark": Color(0.20, 0.62, 0.55),
		"ball": Color(1.0, 0.98, 0.90),
		"accent": Color(0.36, 0.86, 0.95),
		"powerup_blue": Color(0.24, 0.54, 0.96),
		"powerup_green": Color(0.26, 0.78, 0.42),
		"powerup_gold": Color(0.96, 0.80, 0.20),
		"powerup_orange": Color(0.97, 0.56, 0.18),
		"game_over": Color(0.95, 0.42, 0.42),
		"star": Color(0.98, 0.86, 0.32),
		"safety_floor": Color(0.34, 0.94, 0.98),
		"guide": Color(0.40, 0.46, 0.56),
	},
}


static func get_theme(id: String) -> Dictionary:
	return THEMES.get(id, THEMES["rose"])


static func ids() -> Array:
	return THEMES.keys()
