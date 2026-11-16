class_name StarPickup extends Node2D
## The 3-STAR COLLECTIBLE (Stage C).
##
## This is NOT the Stage B score "star" power-up (powerup.gd, a small yellow
## capsule that pays a bonus): this node is the DROPPED collectible that only
## falls at the three level milestones (25 / 50 / 75 % of the breakable bricks,
## or 45 / 90 / 135 s — whichever fires first) and that the paddle must CATCH to
## keep. A star that falls past the paddle is lost for the level.
##
## BreakoutGame owns all of that bookkeeping (_tick_stars); this node only falls
## and draws itself, exactly like PowerUp, so it can never change game state.
##
## It is deliberately BIGGER than a power-up capsule (RADIUS 15 vs 9) and has
## its own glow, so a star can never be mistaken for a drop.

const RADIUS := 15.0
## Slightly slower than a power-up (95): the star is a bigger, rarer target and
## the extra beat makes the catch fair.
const FALL_SPEED := 78.0
const LOST_Y := 1000.0

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


## Circle-vs-rect overlap with the paddle (same forgiveness as PowerUp).
func overlaps(rect: Rect2) -> bool:
	if not alive:
		return false
	var closest := Vector2(
		clampf(position.x, rect.position.x, rect.position.x + rect.size.x),
		clampf(position.y, rect.position.y, rect.position.y + rect.size.y))
	return position.distance_to(closest) <= RADIUS + 3.0


func _draw() -> void:
	# A cheap bloom: three translucent discs instead of a material, so a star
	# costs three draw commands and no shader.
	draw_circle(Vector2.ZERO, RADIUS + 5.0, Color(0.98, 0.82, 0.28, 0.10))
	draw_circle(Vector2.ZERO, RADIUS + 2.0, Color(0.98, 0.82, 0.28, 0.18))
	_draw_star(RADIUS, Color(0.70, 0.50, 0.05, 0.95))
	_draw_star(RADIUS - 1.6, Color(0.98, 0.82, 0.28))
	_draw_star(RADIUS - 5.2, Color(1.0, 0.95, 0.70))


func _draw_star(radius: float, col: Color) -> void:
	var pts := PackedVector2Array()
	for i in 10:
		var r := radius if i % 2 == 0 else radius * 0.44
		var a := -PI * 0.5 + float(i) * PI / 5.0
		pts.append(Vector2(cos(a), sin(a)) * r)
	draw_colored_polygon(pts, col)
