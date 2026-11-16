class_name Brick extends StaticBody2D
## One brick CELL. Collision only — the visible brick field is drawn by
## BrickField in ONE canvas item (see brick_field.gd) so a 1,700-brick level
## does not cost 1,700 draw calls.
##
## The scene owns the reaction: this node only carries its cell coordinate and
## a `live` flag; BreakoutGame.break_cell() removes it and updates the state.
## `unbreakable` marks a solid border brick (a wall, not a brick): the ball
## bounces off it in physics and the scene never breaks it.

const SIZE := 10.0

var cell := Vector2i.ZERO
var live := true
var unbreakable := false


func setup(c: Vector2i, world_position: Vector2) -> void:
	cell = c
	position = world_position
	collision_layer = 4          # bricks
	collision_mask = 0
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(SIZE, SIZE)
	shape.shape = rect
	add_child(shape)
