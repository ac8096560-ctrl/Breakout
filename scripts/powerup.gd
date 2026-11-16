class_name PowerUp extends Node2D
## A falling power-up. Stage A ships the "+3" multi-ball in two colours (blue
## and green — the reference shows no behavioural difference between them).
## The gold "x3" triples the balls in play (up to MAX_BALLS).
##
## Stage B adds the two remaining reference drops, drawn so they read at a
## glance and never rely on a font glyph:
##   "minus"  orange circle with a white bar   -> takes one ball out of play
##   "star"   yellow circle with a white star  -> score bonus + x3 for 5 s
##
## Stage C adds the SAFETY FLOOR:
##   "floor"  cyan capsule with a glowing BAR drawn WIDER than the capsule
##            -> raises the bouncing floor below the paddle for 10 s
##            (the overhanging bar is what makes it unmistakable next to the
##             three round glyph capsules)
##
## The scene decides what a catch MEANS; this node only falls and draws itself.
##
## It falls STRAIGHT DOWN, must be caught by the paddle, and is simply lost if
## it exits the bottom of the screen. Collection is decided by the scene
## (BreakoutGame._tick_powerups) so this node stays passive.

const RADIUS := 9.0
const FALL_SPEED := 95.0      # ~66 px/s at 360x640, i.e. the reference's rate at 540x960
## Falling power-ups (including the safety floor's capsule) ignore the safety
## floor itself: they are plain Node2D movers, so they fall straight through
## and the player still has to catch them with the paddle.
const LOST_Y := 1000.0

var kind := "plus3"
var tint := Color(0.22, 0.48, 0.92)
var alive := true


func _ready() -> void:
	z_index = 7


func _physics_process(delta: float) -> void:
	if not alive:
		return
	position.y += FALL_SPEED * delta
	queue_redraw()
	if position.y > LOST_Y:
		alive = false
		queue_free()


## Circle-vs-rect overlap with the paddle, with a little forgiveness so a
## pixel-perfect miss does not feel like a bug.
func overlaps(rect: Rect2) -> bool:
	if not alive:
		return false
	var closest := Vector2(
		clampf(position.x, rect.position.x, rect.position.x + rect.size.x),
		clampf(position.y, rect.position.y, rect.position.y + rect.size.y))
	return position.distance_to(closest) <= RADIUS + 3.0


func _draw() -> void:
	var font := ThemeDB.fallback_font
	draw_circle(Vector2.ZERO, RADIUS + 1.5, Color(0, 0, 0, 0.45))
	draw_circle(Vector2.ZERO, RADIUS, tint)
	draw_arc(Vector2.ZERO, RADIUS - 1.0, 0.0, TAU, 24, Color(1, 1, 1, 0.55), 1.5)
	match kind:
		"plus3":
			draw_string(font, Vector2(-8, 4), "+3", HORIZONTAL_ALIGNMENT_CENTER, 16, 10,
				Color(1, 1, 1, 0.96))
		"times3":
			draw_string(font, Vector2(-8, 4), "x3", HORIZONTAL_ALIGNMENT_CENTER, 16, 10,
				Color(1, 1, 1, 0.96))
		"minus":
			# a drawn bar, not a "-" glyph: the debuff must read at 9 px
			draw_line(Vector2(-5.0, 0), Vector2(5.0, 0), Color(1, 1, 1, 0.96), 2.6)
		"star":
			_draw_star(Color(1, 1, 1, 0.96))
		"floor":
			# A glowing FLOOR icon that overhangs the capsule on purpose: the
			# four other drops are round glyphs, this one is a wide bar.
			draw_rect(Rect2(-14.0, -4.0, 28.0, 8.0), Color(0, 0, 0, 0.35))
			draw_rect(Rect2(-13.0, -3.0, 26.0, 5.0), Color(1, 1, 1, 0.95))
			draw_rect(Rect2(-13.0, -3.0, 26.0, 2.0),
				Color(tint.r, tint.g, tint.b, 0.95))
			draw_rect(Rect2(-9.0, 3.0, 18.0, 2.0), Color(tint.r, tint.g, tint.b, 0.75))


## A white five-pointed star, drawn from a polygon (no font dependency).
func _draw_star(col: Color) -> void:
	var pts := PackedVector2Array()
	for i in 10:
		var r := 6.0 if i % 2 == 0 else 2.6
		var a := -PI * 0.5 + float(i) * PI / 5.0
		pts.append(Vector2(cos(a), sin(a)) * r)
	draw_colored_polygon(pts, col)
