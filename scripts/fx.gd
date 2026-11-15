class_name FX
## Shared procedural art helpers. Everything is generated at runtime —
## no external assets. Texture caches keep generation cheap.

static var _tex_cache := {}

## --- diagnostics (inert counters, read by --flicker-test) ---------------
static var stat_bursts := 0        # FX.burst node spawns
static var stat_rings := 0         # FX.ring node spawns
static var stat_squash := 0        # RacerVis.squash tween spawns
static var stat_redirect := 0      # wall-redirect steering events
static var stat_impact := 0        # wall impact effects (squash+burst+trauma)
static var stat_racer_hit := 0     # racer-vs-racer deflection events
static var stat_events: Array = [] # recent collision event descriptions
static var stat_capture := false   # harness window: record stat_events
static var stat_t_racerdraw := 0   # usec spent in RacerVis._draw (cumulative)
static var stat_t_flooddraw := 0   # usec spent in Flood._draw
static var stat_t_floodproc := 0   # usec spent in Flood._process
static var stat_t_miscdraw := 0    # usec spent in other hot _draw calls


static func rng(seed_val: int) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = absi(seed_val) % 2147483647
	return r


## Soft radial falloff texture (white). plateau keeps the center solid:
## 0.0 = pure gaussian glow, 0.5+ = soft ellipse usable as a shadow.
static func radial_tex(plateau := 0.0, res := 128) -> Texture2D:
	var key := "radial_%s_%d" % [str(plateau), res]
	if _tex_cache.has(key):
		return _tex_cache[key]
	var img := Image.create_empty(res, res, false, Image.FORMAT_RGBA8)
	var c := res * 0.5
	for y in res:
		for x in res:
			var d := Vector2(x - c + 0.5, y - c + 0.5).length() / c
			var a: float
			if d >= 1.0:
				a = 0.0
			elif d <= plateau:
				a = 1.0
			else:
				var k := (d - plateau) / maxf(0.0001, 1.0 - plateau)
				a = pow(1.0 - k, 2.6 if plateau > 0.2 else 3.0)
			img.set_pixel(x, y, Color(1, 1, 1, a))
	var tex := ImageTexture.create_from_image(img)
	_tex_cache[key] = tex
	return tex


static func glow_tex() -> Texture2D:
	return radial_tex(0.0)


static func shadow_tex() -> Texture2D:
	return radial_tex(0.45)


## Thin bright ring (for shockwaves / ripples).
static func ring_tex() -> Texture2D:
	if _tex_cache.has("ring"):
		return _tex_cache["ring"]
	var res := 128
	var img := Image.create_empty(res, res, false, Image.FORMAT_RGBA8)
	var c := res * 0.5
	for y in res:
		for x in res:
			var d := Vector2(x - c + 0.5, y - c + 0.5).length() / c
			var a := 0.0
			if d > 0.62 and d < 0.98:
				a = pow(1.0 - absf(d - 0.80) / 0.18, 2.0)
			img.set_pixel(x, y, Color(1, 1, 1, a))
	var tex := ImageTexture.create_from_image(img)
	_tex_cache["ring"] = tex
	return tex


static func add_material() -> CanvasItemMaterial:
	if _tex_cache.has("add_mat"):
		return _tex_cache["add_mat"]
	var m := CanvasItemMaterial.new()
	m.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	_tex_cache["add_mat"] = m
	return m


static func add_glow(parent: Node, pos: Vector2, radius: float, color: Color, energy := 1.0, z := 0) -> Sprite2D:
	var g := Sprite2D.new()
	g.texture = glow_tex()
	g.scale = Vector2.ONE * (radius * 2.0 / 128.0)
	g.modulate = Color(color, energy)
	g.material = add_material()
	g.position = pos
	g.z_index = z
	parent.add_child(g)
	return g


static func add_shadow(parent: Node, pos: Vector2, size: Vector2, alpha := 0.35, z := -1) -> Sprite2D:
	var s := Sprite2D.new()
	s.texture = shadow_tex()
	s.scale = Vector2(size.x / 128.0, size.y / 128.0)
	s.modulate = Color(0, 0, 0.02, alpha)
	s.position = pos
	s.z_index = z
	parent.add_child(s)
	return s


static func ring(parent: Node, pos: Vector2, color: Color, radius: float, life := 0.6, width_scale := 1.0, z := 6) -> void:
	stat_rings += 1
	if parent == null or not is_instance_valid(parent):
		return
	var r := Sprite2D.new()
	r.texture = ring_tex()
	r.material = add_material()
	r.modulate = Color(color, 0.9)
	r.position = pos
	r.z_index = z
	r.scale = Vector2.ONE * (radius * 0.25 / 64.0)
	parent.add_child(r)
	var tw := r.create_tween()
	tw.set_parallel(true)
	tw.tween_property(r, "scale", Vector2.ONE * (radius * 2.0 / 128.0 * width_scale), life).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(r, "modulate:a", 0.0, life).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.chain().tween_callback(r.queue_free)


## A brief additive halo that blooms and fades — the `flash` ingredient of a
## reusable effect (EffectDefs). Cheap: ONE sprite and one tween, freed with it.
static func flash(parent: Node, pos: Vector2, color: Color, radius := 40.0,
		life := 0.22, z := 8) -> void:
	if parent == null or not is_instance_valid(parent):
		return
	var s := Sprite2D.new()
	s.texture = glow_tex()
	s.material = add_material()
	s.modulate = Color(color, 0.85)
	s.position = pos
	s.z_index = z
	s.scale = Vector2.ONE * (radius * 0.6 / 64.0)
	parent.add_child(s)
	var tw := s.create_tween()
	tw.set_parallel(true)
	tw.tween_property(s, "scale", Vector2.ONE * (radius * 2.4 / 128.0), life).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(s, "modulate:a", 0.0, life).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.chain().tween_callback(s.queue_free)


## One-shot particle burst. parent may be null (skipped).
static func burst(parent: Node, pos: Vector2, color: Color, count := 12, speed := 160.0, life := 0.5, size := 3.0, gravity := 240.0, z := 7) -> void:
	stat_bursts += 1
	if parent == null or not is_instance_valid(parent):
		return
	var p := CPUParticles2D.new()
	p.texture = glow_tex()
	p.amount = count
	p.lifetime = life
	p.one_shot = true
	p.explosiveness = 1.0
	p.direction = Vector2.UP
	p.spread = 180.0
	p.gravity = Vector2(0, gravity)
	p.initial_velocity_min = speed * 0.4
	p.initial_velocity_max = speed
	p.scale_amount_min = size * 0.5
	p.scale_amount_max = size
	p.color = Color(color, 0.95)
	p.emitting = false
	p.position = pos
	p.z_index = z
	p.local_coords = false
	parent.add_child(p)
	p.emitting = true
	p.finished.connect(p.queue_free)


## Rounded rectangle polygon (centered at local origin).
static func rounded_rect(size: Vector2, radius: float, segs := 5) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var h := size * 0.5
	var r: float = clampf(radius, 0.5, minf(h.x, h.y) - 0.1)
	var corner := [Vector2(h.x - r, -h.y + r), Vector2(h.x - r, h.y - r), Vector2(-h.x + r, h.y - r), Vector2(-h.x + r, -h.y + r)]
	var start_ang := [-PI * 0.5, 0.0, PI * 0.5, PI]
	for ci in 4:
		for i in range(segs + 1):
			var a: float = start_ang[ci] + PI * 0.5 * float(i) / float(segs)
			pts.append(corner[ci] + Vector2(cos(a), sin(a)) * r)
	return pts
