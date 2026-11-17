class_name Brick extends StaticBody2D
## One brick CELL. Collision only — the visible brick field is drawn by
## BrickField in ONE canvas item (see brick_field.gd) so a 1,700-brick level
## does not cost 1,700 draw calls.
##
## The scene owns the reaction: this node only carries its cell coordinate and
## a `live` flag; BreakoutGame.break_cell() removes it and updates the state.
## `unbreakable` marks a solid border brick (a wall, not a brick): the ball
## bounces off it in physics and the scene never breaks it.

## The collision rect is 2 px smaller than the visual brick on each side, so
## adjacent bricks never overlap and the ball cannot slip between them. It
## MUST scale with the level's cell size: at cell 12 the rect is 10 px (the
## original value), at cell 6 it is 4 px. A hardcoded 10 px rect on a 6 px
## brick overlaps its neighbours and shrinks the 2-cell stem gap to exactly
## the ball's diameter, so the ball can never enter the level (measured:
## level_04 80x100 sims, 300 s, 0 hits on all seeds before this fix).
const SIZE := 10.0

var cell := Vector2i.ZERO
var live := true
var unbreakable := false


func setup(c: Vector2i, world_position: Vector2, cell_size: float = 12.0) -> void:
	cell = c
	position = world_position
	collision_layer = 4          # bricks
	collision_mask = 0
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(maxf(2.0, cell_size - 2.0), maxf(2.0, cell_size - 2.0))
	shape.shape = rect
	add_child(shape)
