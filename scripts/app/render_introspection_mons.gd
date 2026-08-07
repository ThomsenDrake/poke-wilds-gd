extends RefCounted

# Overworld-mon sidecar collectors extracted from render_introspection.gd at the
# app 220 wall (vision-suite expansion Track A.1). Stamps mons_y_sort + nest_rings
# so the deterministic reviewer can answer the overworld_mons rubric questions
# without a model. Rects are canvas/display px (get_global_transform_with_canvas).

const WorldDrawOrder := preload("res://scripts/app/world_draw_order.gd")


# World-layer draw_order (Ground/Prop/Player) + EntityLayer mons_y_sort/nest_rings.
static func collect_world(ctx: Dictionary, result: Dictionary) -> void:
	var world: Node = ctx.get("world")
	if world == null:
		return
	var root: Node = world.get_tree().current_scene if world.get_tree() != null else null
	var nodes: Array = [world.get_node_or_null("GroundLayer"), world.get_node_or_null("PropLayer"), ctx.get("player")]
	var canvas: Array = []
	for item in nodes:
		if item is CanvasItem:
			canvas.append(item)
	canvas.sort_custom(func(a, b): return WorldDrawOrder.draws_over(b, a))
	for item in canvas:
		var sort_y := WorldDrawOrder.y_sort_key(item)
		result["draw_order"].append({
			"node": str(root.get_path_to(item)) if root != null else str(item.name),
			"z": WorldDrawOrder.effective_z(item),
			"y_sort": null if is_nan(sort_y) else sort_y,
			"texture": "",
			"rect": [],
			"space": "display" # world collectors emit canvas px, never 160x144 stage px
		})
	collect_entities(ctx, result)


# Append EntityLayer sprites into draw_order + stamp mons_y_sort / nest_rings.
# No-op when the layer is absent or inactive (inert baselines stay byte-stable).
static func collect_entities(ctx: Dictionary, result: Dictionary) -> void:
	var world: Node = ctx.get("world")
	if world == null:
		return
	var root: Node = world.get_tree().current_scene if world.get_tree() != null else null
	var layer: Node = root.get_node_or_null("EntityLayer") if root != null else null
	if layer == null:
		return
	var sprites: Array = []
	for child in layer.get_children():
		if child is CanvasItem and (child as CanvasItem).visible:
			sprites.append(child)
	sprites.sort_custom(func(a, b): return WorldDrawOrder.draws_over(b, a))
	var mons_y_sort: Array = []
	var nest_rings: Array = []
	for item in sprites:
		var sort_y := WorldDrawOrder.y_sort_key(item)
		var rect := _canvas_item_rect(item)
		var node_path := str(root.get_path_to(item)) if root != null else str(item.name)
		var entry := {"node": node_path, "z": WorldDrawOrder.effective_z(item),
			"y_sort": null if is_nan(sort_y) else sort_y, "texture": _texture_path(item),
			"rect": rect, "space": "display"} # canvas px — see collect_world
		result["draw_order"].append(entry)
		var kind := _entity_kind(item)
		if kind == "nest":
			nest_rings.append({"node": node_path, "rect": rect})
		elif kind != "":
			mons_y_sort.append({"node": node_path, "kind": kind, "y_sort": entry["y_sort"],
				"z": entry["z"], "rect": rect})
	result["mons_y_sort"] = mons_y_sort
	result["nest_rings"] = nest_rings
	if not nest_rings.is_empty():
		var expected: Variant = result.get("expected_regions", {})
		if not (expected is Dictionary):
			expected = {"ink": [], "forbidden": [], "strings": []}
		var ink: Array = []
		var existing = (expected as Dictionary).get("ink", [])
		if existing is Array:
			ink = (existing as Array).duplicate()
		for nest in nest_rings:
			var nest_rect: Variant = nest.get("rect")
			if nest_rect is Array and not (nest_rect as Array).is_empty():
				ink.append(nest_rect)
		(expected as Dictionary)["ink"] = ink
		result["expected_regions"] = expected


# Stage-space draw_order for a GBC menu ScreenStage (art-anchor live compare).
static func collect_menu_stage(menu: Control, result: Dictionary) -> void:
	if menu == null:
		return
	var stage: Control = menu.get_node_or_null("ScreenViewport/ScreenStage")
	if stage == null:
		return
	var canvas: Array = []
	for child in stage.get_children():
		if child is CanvasItem:
			canvas.append(child)
	var i := 0
	while i < canvas.size(): # BFS descendants (plates nest under cards/columns)
		canvas.append_array((canvas[i] as Node).get_children().filter(
			func(child): return child is CanvasItem))
		i += 1
	canvas.sort_custom(func(a, b): return WorldDrawOrder.draws_over(b, a))
	for item in canvas:
		var sort_y := WorldDrawOrder.y_sort_key(item)
		var rect: Array = []
		if item is Control:
			# Stage SubViewport: get_global_rect is stage-local (art-anchor space).
			rect = [int((item as Control).get_global_rect().position.x),
				int((item as Control).get_global_rect().position.y),
				int((item as Control).get_global_rect().size.x),
				int((item as Control).get_global_rect().size.y)]
		result["draw_order"].append({"node": _stage_path(stage, item),
			"z": WorldDrawOrder.effective_z(item),
			"y_sort": null if is_nan(sort_y) else sort_y, "texture": _texture_path(item),
			"rect": rect})


static func _entity_kind(item: Node) -> String:
	var name := str(item.name)
	if name.begins_with("Nest_"):
		return "nest"
	if name.begins_with("Entity_"):
		if item.get_node_or_null("AlphaMarker") != null:
			return "guardian"
		return "mon"
	return ""


static func _canvas_item_rect(item: CanvasItem) -> Array:
	if item is Control:
		var r: Rect2 = (item as Control).get_global_rect()
		return [int(r.position.x), int(r.position.y), int(r.size.x), int(r.size.y)]
	if item is Sprite2D:
		var sprite := item as Sprite2D
		if sprite.texture == null:
			return []
		var size := Vector2(sprite.texture.get_width(), sprite.texture.get_height()) * sprite.scale
		var local_tl := sprite.offset
		if sprite.centered:
			local_tl -= size * 0.5
		var xform := sprite.get_global_transform_with_canvas()
		var tl: Vector2 = xform * local_tl
		var br: Vector2 = xform * (local_tl + size)
		var x0 := int(floor(minf(tl.x, br.x)))
		var y0 := int(floor(minf(tl.y, br.y)))
		var x1 := int(ceil(maxf(tl.x, br.x)))
		var y1 := int(ceil(maxf(tl.y, br.y)))
		return [x0, y0, maxi(1, x1 - x0), maxi(1, y1 - y0)]
	return []


static func _texture_path(item: CanvasItem) -> String:
	if item is TextureRect and (item as TextureRect).texture != null:
		var tex: Texture = (item as TextureRect).texture
		var path := tex.resource_path
		if path.is_empty() and tex is AtlasTexture and (tex as AtlasTexture).atlas != null:
			path = (tex as AtlasTexture).atlas.resource_path
		return path
	if item is Sprite2D and (item as Sprite2D).texture != null:
		var stex: Texture = (item as Sprite2D).texture
		var spath := stex.resource_path
		if spath.is_empty() and stex is AtlasTexture and (stex as AtlasTexture).atlas != null:
			spath = (stex as AtlasTexture).atlas.resource_path
		return spath
	return ""


static func _stage_path(stage: Node, item: Node) -> String:
	var parts: Array = []
	var node: Node = item
	while node != null and node != stage:
		var node_name := str(node.name)
		parts.push_front(node_name if not node_name.begins_with("@") else "%s_%d" % [node.get_class(), node.get_index()])
		node = node.get_parent()
	return "/".join(PackedStringArray(parts))
