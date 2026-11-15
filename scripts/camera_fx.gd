class_name CameraFX extends Camera2D
## Cinematic race camera: impact shake, finish zoom pulse, winner focus —
## plus the master-prompt §5 chase mode: smoothly track the GROUP of racing
## racers and adapt the zoom so the whole action stays framed inside the
## 9:16 portrait view, with clamped zoom bounds so the framing never
## oscillates. Safe fixed-arena behavior is the fallback (follow off).

const FOLLOW_MARGIN := 1.28          # extra frame around the racer group
const FOLLOW_ZOOM_MIN := 0.55        # safe bounds — no abrupt oscillation
const FOLLOW_ZOOM_MAX := 1.15
const FOLLOW_POS_SPEED := 6.0        # exp smoothing for position (1/s)
const FOLLOW_ZOOM_SPEED := 3.2
## M-K: zoom changes below this are invisible but would keep the camera
## breathing every frame (measured: |Δzoom| p95 = 0.012 on a live race).
const ZOOM_DEADBAND := 0.004
## M-K: hard ceiling on zoom slew, so a racer leaving/joining the group can
## never snap the framing — 0.45 zoom units per second.
const ZOOM_MAX_RATE := 0.45

var base_pos := Vector2.ZERO
var base_zoom := Vector2.ONE
var trauma := 0.0
var _t := 0.0

# --- capture-fallback anti-oscillation (master prompt §5)
var _pulse_amount := 0.0          # follow-mode zoom pulse envelope
var _pulse_t := 0.0
var _pulse_dur := 0.55

# --- group chase (portrait 9:16, leverages the 540x960 design frame)
var follow_enabled := false
var follow_rect := Rect2()            # arena bounds the camera may not leave
var _follow_lerp_pos := Vector2.ZERO
var _follow_lerp_zoom := Vector2.ONE

func setup(center: Vector2, base := Vector2.ONE) -> void:
	base_pos = center
	position = center
	base_zoom = base
	zoom = base
	_follow_lerp_pos = center
	_follow_lerp_zoom = base
	make_current()


## Master prompt §5 — enable smooth group tracking over the given playable
## region. The camera centers on the RACING racers' centroid, zooms so the
## whole group (plus a margin) fits the portrait view, never zooms past the
## clamped bounds, and never shows space outside the arena rect.
func enable_follow(p_rect: Rect2) -> void:
	follow_rect = p_rect
	follow_enabled = true
	_follow_lerp_pos = follow_rect.get_center() if follow_rect.size != Vector2.ZERO else base_pos
	_follow_lerp_zoom = base_zoom


## 0..1 fraction of the remaining distance to cover this frame, for a given
## exponential rate (1/s). Independent of the frame rate by construction.
static func _exp_t(speed: float, delta: float) -> float:
	return 1.0 - exp(-speed * maxf(0.0, delta))


func add_trauma(x: float) -> void:
	trauma = minf(1.0, trauma + x)


func zoom_pulse(amount := 0.05, dur := 0.55) -> void:
	if follow_enabled:
		# follow mode: run the pulse as an envelope on top of the adaptive
		# zoom — no tween fight with _follow_step, no base_zoom yank.
		_pulse_amount = amount
		_pulse_t = 0.0
		_pulse_dur = dur
	else:
		var tw := create_tween()
		tw.tween_property(self, "zoom", base_zoom * (1.0 + amount), dur * 0.35).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
		tw.tween_property(self, "zoom", base_zoom, dur * 0.65).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


func focus_brief(pos: Vector2, k := 0.10) -> void:
	if follow_enabled:
		return                     # the chase camera is already framing the action
	var tw := create_tween()
	tw.tween_property(self, "position", base_pos + (pos - base_pos) * k, 0.35).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tw.tween_interval(0.9)
	tw.tween_property(self, "position", base_pos, 0.6).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


func _process(delta: float) -> void:
	_t += delta
	trauma = maxf(0.0, trauma - delta * 1.5)
	var sh := trauma * trauma
	if follow_enabled:
		_follow_step(delta)
	else:
		offset = Vector2(sin(_t * 47.0), cos(_t * 38.7)) * 9.0 * sh


## Group-tracking step: centroid + adapated zoom, both exp-smoothed, bounds
## clamped. Shake still applies on the offset so impacts stay visible.
func _follow_step(delta: float) -> void:
	var alive: Array = []
	for r in get_tree().get_nodes_in_group("racers"):
		if is_instance_valid(r) and r.get("state") == 1:   # Racer.RS.RACING
			alive.append(r)
	var target_pos := _follow_lerp_pos
	var target_zoom := _follow_lerp_zoom
	if alive.is_empty():
		# no racers running: drift back to the stable arena framing
		target_pos = base_pos
		target_zoom = base_zoom
	else:
		var lo: Vector2 = alive[0].global_position
		var hi := lo
		var sum := Vector2.ZERO
		for r in alive:
			var p: Vector2 = r.global_position
			lo = lo.min(p)
			hi = hi.max(p)
			sum += p
		target_pos = sum / float(alive.size())
		var needed := (hi - lo) * FOLLOW_MARGIN + Vector2(80, 80)
		var view := get_viewport_rect().size
		var z := minf(view.x / maxf(needed.x, 1.0), view.y / maxf(needed.y, 1.0))
		z = clampf(z, FOLLOW_ZOOM_MIN, FOLLOW_ZOOM_MAX)
		target_zoom = Vector2.ONE * z
		# never reveal world outside the arena (portrait safe bounds)
		var half := Vector2(view.x, view.y) * 0.5 / z
		if follow_rect.size.x < view.x / z:
			target_pos.x = follow_rect.get_center().x
		else:
			target_pos.x = clampf(target_pos.x,
					follow_rect.position.x + half.x, follow_rect.end.x - half.x)
		if follow_rect.size.y < view.y / z:
			target_pos.y = follow_rect.get_center().y
		else:
			target_pos.y = clampf(target_pos.y,
					follow_rect.position.y + half.y, follow_rect.end.y - half.y)
	# M-K: FRAME-RATE-INDEPENDENT smoothing. `min(1, speed*delta)` is a
	# first-order approximation that changes its damping whenever the frame
	# rate moves — and this game's frame rate moves between 20 and 60 FPS, so
	# the same pan eased differently in every take. `1 - exp(-speed*delta)` is
	# the exact first-order response: identical motion at any frame rate.
	_follow_lerp_pos = _follow_lerp_pos.lerp(target_pos, _exp_t(FOLLOW_POS_SPEED, delta))
	var zt := target_zoom.x
	var zc := _follow_lerp_zoom.x
	# no zoom motion at all for sub-pixel changes...
	if absf(zt - zc) < ZOOM_DEADBAND:
		zt = zc
	# ...and a slew limit on the ones that are visible (no snaps when the
	# racer group suddenly spreads or a racer is eliminated)
	var max_step := ZOOM_MAX_RATE * delta
	zt = zc + clampf(zt - zc, -max_step, max_step)
	var zn := lerpf(zc, zt, _exp_t(FOLLOW_ZOOM_SPEED, delta))
	_follow_lerp_zoom = Vector2.ONE * zn
	# zoom pulse envelope on top of the adaptive zoom (see zoom_pulse)
	var pulse := 1.0
	if _pulse_t < _pulse_dur:
		_pulse_t += delta
		var k: float = clampf(_pulse_t / _pulse_dur, 0.0, 1.0)
		pulse = 1.0 + _pulse_amount * sin(k * PI)
	position = _follow_lerp_pos
	zoom = _follow_lerp_zoom * pulse
	offset = Vector2(sin(_t * 47.0), cos(_t * 38.7)) * 9.0 * trauma * trauma

