class_name Ball extends CharacterBody2D
## The ball. A Godot physics body (CharacterBody2D, floating motion mode) with
## its own velocity and bounce; it is NOT a Racer and carries no race logic.
##
## The ball reports what it hit and where the surface normal pointed; the scene
## (BreakoutGame) decides what that means — a brick breaks, the paddle sets the
## bounce angle. REPORT-only: nothing in this file changes game state.

signal hit_collider(collider: Node, normal: Vector2)

const RADIUS := 4.0
const MIN_AXIS := 14.0

var vel := Vector2.ZERO
## Set false when the ball is held at the paddle or has already been counted as
## lost, so a queued physics step can never revive it.
var active := true
var _speed := 350.0


func _ready() -> void:
	collision_layer = 0
	collision_mask = 1 | 2 | 4      # walls, paddle, bricks
	motion_mode = MOTION_MODE_FLOATING
	z_index = 6
	var shape := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = RADIUS
	shape.shape = circle
	add_child(shape)


func launch(velocity: Vector2) -> void:
	vel = velocity
	_speed = maxf(1.0, velocity.length())
	active = true


func speed() -> float:
	return _speed


func set_speed(s: float) -> void:
	_speed = maxf(40.0, s)
	if vel.length() > 0.001:
		vel = vel.normalized() * _speed


func _physics_process(delta: float) -> void:
	if not active:
		return
	var col := move_and_collide(vel * delta)
	if col == null:
		return
	var normal := col.get_normal()
	if normal.length_squared() < 0.01:
		normal = Vector2.UP
	# Reflect, then re-normalise: a bounce must never bleed or gain speed.
	vel = vel.bounce(normal).normalized() * _speed
	# A perfectly axis-aligned hit can trap the ball in a repeating line; a
	# couple of degrees keep the field alive without making play unpredictable.
	if absf(vel.x) < MIN_AXIS:
		vel.x = MIN_AXIS * (1.0 if vel.x >= 0.0 else -1.0)
		vel = vel.normalized() * _speed
	if absf(vel.y) < MIN_AXIS:
		vel.y = MIN_AXIS * (-1.0 if vel.y <= 0.0 else 1.0)
		vel = vel.normalized() * _speed
	# Separate from the surface so the next step cannot re-hit it.
	position += normal * 1.0
	hit_collider.emit(col.get_collider(), normal)


func _draw() -> void:
	draw_circle(Vector2.ZERO, RADIUS + 1.6, Color(1, 1, 1, 0.16))
	draw_circle(Vector2.ZERO, RADIUS, Color(1, 1, 1, 0.98))
