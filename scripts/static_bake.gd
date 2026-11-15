class_name StaticBake
## M-K: draws a group of STATIC decorative canvas items ONCE into a texture and
## puts that texture on screen as a single Sprite2D.
##
## Why: this arena is vector art — a 26x14 floor plus its margin dressing issued
## ~2,570 draw calls per frame, and the measured cost of a canvas draw call on
## the target machine is ~6.5 us. Baked, the same pixels cost one call per layer.
## Nothing about the art changes: the SAME nodes are cloned and drawn by the
## same `_draw()` code into an off-screen viewport, so the texture is the
## renderer's own output. The originals stay in the tree (sensors, tweens and
## animated children keep working) and simply stop drawing.
##
## Test-visible contract: returns the created Sprite2D, or null when it refused
## (empty list, absurd size, no image). Callers must be able to live with null.

static func _drop(vp: Node, host: Node) -> void:
	if vp != null and is_instance_valid(vp):
		if vp.get_parent() != null:
			vp.get_parent().remove_child(vp)
		vp.queue_free()


static func _copy_script_state(src: Node, dst: Node) -> void:
	for p in src.get_property_list():
		if int(p.get("usage", 0)) & PROPERTY_USAGE_SCRIPT_VARIABLE != 0:
			dst.set(str(p["name"]), src.get(str(p["name"])))
	for i in mini(src.get_child_count(), dst.get_child_count()):
		_copy_script_state(src.get_child(i), dst.get_child(i))


## `keep_glow`: the sources have ANIMATED Sprite2D children (finish-line glow,
## pad glow) that must keep pulsing. In that mode the clones are captured
## without their sprite children, and the originals are suppressed with their
## own `baked` flag instead of `visible = false` — so the live glow keeps
## drawing on top of the baked plate, exactly once.
static func bake(host: Node, sources: Array, rect: Rect2, z: int, tex_name: String,
		keep_glow := false) -> Sprite2D:
	if host == null or not host.is_inside_tree() or sources.is_empty():
		return null
	# The dummy (headless) renderer has no texture to hand back — asking it for
	# one logs `Parameter "t" is null` on every suite run and yields nothing.
	# Headless races simply keep their live vector art.
	if DisplayServer.get_name() == "headless":
		return null
	var tree := host.get_tree()
	if tree == null:
		return null
	var size := Vector2i(maxi(1, int(ceilf(rect.size.x))), maxi(1, int(ceilf(rect.size.y))))
	if size.x > 4096 or size.y > 4096:
		push_warning("StaticBake: refusing %s (%dx%d px)" % [tex_name, size.x, size.y])
		return null
	var vp := SubViewport.new()
	vp.size = size
	vp.transparent_bg = true
	vp.disable_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	host.add_child(vp)
	var holder := Node2D.new()
	holder.position = -rect.position          # world coords -> viewport pixels
	vp.add_child(holder)
	var cloned := 0
	for src in sources:
		if not is_instance_valid(src) or not (src is CanvasItem):
			continue
		var c: Node = (src as Node).duplicate()
		# Node.duplicate() copies NODE properties but NOT the script's own
		# variables (measured: a Rock lost its generated `pts`, a tile its
		# `blades`). Without this the bake would render default-coloured,
		# detail-free art — a silent visual regression. Copy them by hand.
		_copy_script_state(src as Node, c)
		holder.add_child(c)
		if keep_glow:
			for ch in c.get_children():
				if ch is Sprite2D:
					(ch as Sprite2D).visible = false
		cloned += 1
	if cloned == 0:
		host.remove_child(vp)
		vp.queue_free()
		return null
	# the first frame allocates the render target, the second draws into it
	await tree.process_frame
	if not is_instance_valid(vp) or not is_instance_valid(host) or not host.is_inside_tree():
		_drop(vp, host)
		return null
	await tree.process_frame
	if not is_instance_valid(vp) or not is_instance_valid(host) or not host.is_inside_tree():
		_drop(vp, host)
		return null
	var vtex := vp.get_texture()
	var img: Image = vtex.get_image() if vtex != null else null
	host.remove_child(vp)
	vp.queue_free()
	if img == null or img.get_width() < 1 or img.get_height() < 1:
		push_warning("StaticBake: %s produced no image" % tex_name)
		return null
	img.convert(Image.FORMAT_RGBA8)
	var sp := Sprite2D.new()
	sp.name = tex_name
	sp.texture = ImageTexture.create_from_image(img)
	sp.centered = false
	sp.position = rect.position
	sp.z_index = z
	sp.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	host.add_child(sp)
	# the originals stop drawing; their children (sensors, animated glows) live on
	for src in sources:
		if not is_instance_valid(src):
			continue
		if keep_glow and "baked" in src:
			src.set("baked", true)
			(src as CanvasItem).queue_redraw()
		else:
			(src as CanvasItem).visible = false
	return sp
