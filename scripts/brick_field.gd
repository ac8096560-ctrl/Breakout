class_name BrickField extends Node2D
## Draws the ENTIRE brick field (frame, top strip, every live brick) in one
## canvas item, from the level's cell grid. Redrawn only when a brick breaks.
##
## Why: the reference level is ~1,700 bricks. One Node2D per brick with its own
## _draw() is ~3,400 draw commands per frame. The StaticBake pattern from
## WorldRace collapses static art into one texture — bricks cannot be baked
## because each one disappears on its own, so the same idea is applied the
## other way round: one draw pass over the grid, and the collision bodies carry
## no visuals at all.

var grid: Array = []
var cols := 0
var rows := 0
var cell := 12.0
var origin := Vector2.ZERO
var pal: Dictionary = {}


func configure(c: int, r: int, c_size: float, o: Vector2, colors: Dictionary, cells: Array) -> void:
	cols = c
	rows = r
	cell = c_size
	origin = o
	pal = colors
	grid = cells
	queue_redraw()


func _draw() -> void:
	if cols <= 0 or rows <= 0:
		return
	var w := cols * cell
	var h := rows * cell
	# --- grey frame around the grid, black inside
	var frame_col: Color = pal.get("frame", Color(0.52, 0.54, 0.58))
	var frame_dark: Color = pal.get("frame_dark", Color(0.28, 0.29, 0.33))
	draw_rect(Rect2(origin - Vector2(8, 8), Vector2(w + 16, h + 16)), frame_dark)
	draw_rect(Rect2(origin - Vector2(4, 4), Vector2(w + 8, h + 8)), frame_col)
	draw_rect(Rect2(origin, Vector2(w, h)), Color(0.02, 0.02, 0.025))
	# --- thin red strip along the very top edge (reference detail)
	draw_rect(Rect2(origin - Vector2(8, 8), Vector2(w + 16, 5)),
		pal.get("top_strip", Color(0.72, 0.12, 0.14)))
	# --- bricks
	var inner := cell - 2.0
	var dark: Color = pal.get("brick_dark", Color(0.5, 0.19, 0.20))
	for r in rows:
		var row_base := r * cols
		var y := origin.y + r * cell
		for c in cols:
			var col: Color = grid[row_base + c]
			if col.a < 0.5:
				continue
			var x := origin.x + c * cell
			draw_rect(Rect2(x, y, inner, inner), col)
			# one 1px darker row at the bottom gives the field its pixel grain
			draw_rect(Rect2(x, y + inner - 1.5, inner, 1.5), col.darkened(0.35))
