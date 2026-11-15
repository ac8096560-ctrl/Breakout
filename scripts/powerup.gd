class_name PowerUp extends Node2D
## A falling power-up. Stage A ships the "+3" multi-ball in two colours (blue
## and green — the reference shows no behavioural difference between them).
##
## It falls STRAIGHT DOWN, must be caught by the paddle, and is simply lost if
## it exits the bottom of the screen. Collection is decided by the scene
## (BreakoutGame._tick_powerups) so this node stays passive.

const RADIUS := 9.0
const FALL_SPEED := 95.0      # ~66 px/s at 360x640, i.e. the reference's rate at 540x960
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
	if kind == "plus3":
		draw_string(font, Vector2(-8, 4), "+3", HORIZONTAL_ALIGNMENT_CENTER, 16, 10,
			Color(1, 1, 1, 0.96))
