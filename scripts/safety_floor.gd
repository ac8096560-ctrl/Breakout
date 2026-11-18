class_name SafetyFloor extends Node2D
## The SAFETY FLOOR (Stage C, item 3) — the glowing bar the "floor" power-up
## raises just above the bottom edge, BELOW the paddle, for DURATION seconds.
##
## While it is up, BreakoutGame._tick_balls() reflects every ball that reaches
## it back upwards, so a ball can never drop out and cost a life. It is NOT a
## physics body and it does not touch falling power-ups: those are Node2D
## movers that fall straight through it, so the player still needs the paddle
## for a drop.
##
## The node owns its own timer (left) and its own drawing so the expire and the
## last-2-second warning blink are one thing; the game only calls tick() and
## reads active().
##
## Visual: a wide cyan bar with a halo — deliberately unlike the salmon paddle
## (104 x 14 at y = 890) it protects.

const DURATION := 10.0
## The bar blinks for this long before it disappears, so the player knows the
## safety is about to end.
const WARN_SECONDS := 2.0
const WIDTH := 498.0
const HEIGHT := 7.0
## Just above the bottom edge of the 540x960 frame (bottom = 960), well below
## the paddle line (890). Brief 25 moved the paddle down to open the gap under
## the portrait, so the bar moved down with it (880 -> 930) and stays 33 px
## under the paddle's face — it must never sit ABOVE the paddle, or it would
## reflect the ball before the player could catch it and no level could be won.
const Y := 930.0

var left := 0.0
var pal: Dictionary = {}


func _ready() -> void:
	position = Vector2(270.0, Y)
	z_index = 4
	visible = false


## Raise (or REFRESH) the floor. A second catch while one is up restarts the
## timer — it never stacks a second floor.
func start(seconds := DURATION) -> void:
	left = seconds
	visible = true
	queue_redraw()


func tick(delta: float) -> void:
	if left <= 0.0:
		return
	left = maxf(0.0, left - delta)
	if left <= 0.0:
		visible = false
	queue_redraw()


func active() -> bool:
	return left > 0.0


func clear() -> void:
	left = 0.0
	visible = false
	queue_redraw()


func _draw() -> void:
	if left <= 0.0:
		return
	var col: Color = pal.get("safety_floor", Color(0.30, 0.90, 0.95))
	var blink := 1.0
	if left <= WARN_SECONDS:
		# 0.35 .. 1.0: an unmistakable "about to go" pulse.
		blink = 0.35 + 0.65 * absf(sin(left * 9.0))
	var half := WIDTH * 0.5
	# halo
	draw_rect(Rect2(-half - 4.0, -HEIGHT, WIDTH + 8.0, HEIGHT * 3.0),
		Color(col.r, col.g, col.b, 0.10 * blink))
	# body
	draw_rect(Rect2(-half, -HEIGHT * 0.5, WIDTH, HEIGHT),
		Color(col.r, col.g, col.b, 0.92 * blink))
	# bright top edge + end caps so the bar never reads as the paddle
	draw_rect(Rect2(-half, -HEIGHT * 0.5 - 1.5, WIDTH, 2.0),
		Color(1, 1, 1, 0.55 * blink))
	draw_rect(Rect2(-half - 3.0, -HEIGHT * 1.5, 6.0, HEIGHT * 3.0),
		Color(col.r, col.g, col.b, 0.85 * blink))
	draw_rect(Rect2(half - 3.0, -HEIGHT * 1.5, 6.0, HEIGHT * 3.0),
		Color(col.r, col.g, col.b, 0.85 * blink))
