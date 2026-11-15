class_name Paddle extends AnimatableBody2D
## The paddle: a salmon bar that moves LEFT/RIGHT only, never up/down.
##
## Three inputs feed it (see BreakoutGame):
##   * mouse / touch drag   — the real player path
##   * arrow keys           — desktop fallback
##   * auto-play            — the paddle AI used for recording (default)
##
## A hit's horizontal position sets the bounce angle: the centre of the bar
## returns the ball nearly straight up, the edges send it out at ~60 degrees.

const SIZE := Vector2(104, 14)
const MAX_BOUNCE_DEG := 62.0

var pal: Dictionary = {}
var buff_left := 0.0          # "x3" badge timer (set when a +3 is caught)


func _ready() -> void:
	sync_to_physics = false
	collision_layer = 2          # paddle
	collision_mask = 0
	z_index = 5
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = SIZE
	shape.shape = rect
	add_child(shape)


func rect() -> Rect2:
	return Rect2(position - SIZE * 0.5, SIZE)


func move_to_x(x: float) -> void:
	position.x = clampf(x, SIZE.x * 0.5 + 2.0, 540.0 - SIZE.x * 0.5 - 2.0)


func _physics_process(delta: float) -> void:
	if buff_left > 0.0:
		buff_left = maxf(0.0, buff_left - delta)
		queue_redraw()


## Velocity a caught ball leaves with: offset -1 = far left edge, 0 = centre,
## +1 = far right edge.
func bounce_for(ball_x: float, speed: float) -> Vector2:
	var rel := clampf((ball_x - position.x) / (SIZE.x * 0.5), -1.0, 1.0)
	var angle := deg_to_rad(lerpf(-MAX_BOUNCE_DEG, MAX_BOUNCE_DEG, (rel + 1.0) * 0.5))
	return Vector2(sin(angle), -cos(angle)) * speed


func show_buff(seconds: float) -> void:
	buff_left = maxf(buff_left, seconds)
	queue_redraw()


func _draw() -> void:
	var body: Color = pal.get("paddle", Color(0.95, 0.52, 0.46))
	var dark: Color = pal.get("paddle_dark", Color(0.78, 0.35, 0.31))
	var r := Rect2(-SIZE * 0.5, SIZE)
	draw_rect(r, body)
	draw_rect(Rect2(r.position.x, r.position.y + SIZE.y - 3.0, SIZE.x, 3.0), dark)
	draw_rect(Rect2(r.position.x + 1.0, r.position.y + 1.0, SIZE.x - 2.0, 2.0),
		Color(1, 1, 1, 0.22))
	if buff_left > 0.0:
		var font := ThemeDB.fallback_font
		draw_string(font, Vector2(-14, -6), "x3", HORIZONTAL_ALIGNMENT_CENTER, 28, 12,
			Color(0.95, 1.0, 0.85))
