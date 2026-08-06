extends RefCounted

# Slice 3 semantic sidecar collector (vision-fidelity.md, snapshot-sidecar.md):
# per-shot sidecar CONTENT from the live scene through ctx; SnapshotCapture.capture()
# injects the rest. Byte-stable per seed (ts_msec/trace_cursor excepted).

const UiRenderModel := preload("res://scripts/app/ui_render_model.gd")
const UiRenderArt := preload("res://scripts/app/ui_render_art.gd")
const WorldDrawOrder := preload("res://scripts/app/world_draw_order.gd")
const MonsCollect := preload("res://scripts/app/render_introspection_mons.gd")

const SIDECAR_SUFFIX := ".sidecar.json"

static func collect(ctx: Dictionary, shot: String, crafted: Dictionary) -> Dictionary:
	var result := {"crafted_state": crafted.duplicate(true), "capture_env": _capture_env(), "labels": [],
		"draw_order": [], "cursor_pairs": [], "canary_rect": [], "palette_regions": {"canary": [], "hud": []},
		"expected_regions": {"ink": [], "forbidden": [], "strings": []}, "mons_y_sort": [], "nest_rings": []}
	match _shot_kind(shot):
		"battle": _collect_battle(ctx, result)
		"menu": _collect_menu(ctx, result, shot)
		"overworld": MonsCollect.collect_world(ctx, result, _collect_draw_order)
	return result

static func _collect_battle(ctx: Dictionary, result: Dictionary) -> void:
	var view: Node = ctx.get("battle_view")
	if view == null:
		return
	var stage: Control = view.get_node_or_null("BattleViewport/BattleStage")
	var display: Control = view.get_node_or_null("BattleDisplay")
	if stage == null or display == null:
		return
	var display_rect: Rect2 = display.get_global_rect()
	var state := _battle_state(view)
	var snapshot: Dictionary = view._snapshot.duplicate(true)
	snapshot["message"] = str(view._message)
	var model: Dictionary = UiRenderModel.expected(state, snapshot)
	_collect_labels(stage, result, display_rect, true)
	_map_expected(result, model, display_rect)
	_collect_pairs(result, stage, model, display_rect)
	var enemy: TextureRect = stage.get_node_or_null("EnemySprite")
	result["canary_rect"] = UiRenderModel.map_region(enemy.get_global_rect(), display_rect) if enemy != null else []
	result["palette_regions"] = {"canary": result["canary_rect"], "hud": _hud_palette_regions(state, display_rect)}
	_collect_draw_order(stage.get_children(), result, func(item): return _stage_path(stage, item), true)

static func _collect_labels(root: Control, result: Dictionary, display_rect: Rect2, mapped: bool) -> void:
	for label in UiRenderModel.visible_labels(root):
		var stage_rect := _int_rect(UiRenderModel.ink_rect(label))
		result["labels"].append({"text": str(label.text), "stage_rect": stage_rect, "display_rect":
			UiRenderModel.map_region(Rect2(stage_rect[0], stage_rect[1], stage_rect[2], stage_rect[3]), display_rect)
			if mapped else stage_rect})
	_sort_labels(result["labels"])

static func _collect_menu(ctx: Dictionary, result: Dictionary, shot: String) -> void:
	var menu: Control = ctx.get("start_menu")
	if menu == null:
		return
	_collect_labels(menu, result, Rect2(), false)
	MonsCollect.collect_menu_stage(menu, result)
	var texts := {}
	for label in UiRenderModel.visible_labels(menu):
		texts[str(label.text)] = _int_rect(UiRenderModel.ink_rect(label))
	var strings := []
	for text in texts:
		strings.append({"text": str(text), "region": texts[text], "mode": "box", "avoid": []})
	for text in UiRenderModel.menu_expected_texts(_menu_state(shot), _menu_snapshot(ctx)):
		if not texts.has(str(text)):
			strings.append({"text": str(text), "region": [], "mode": "box", "avoid": []})
	result["expected_regions"] = {"ink": [], "forbidden": [], "strings": strings}

static func _map_expected(result: Dictionary, model: Dictionary, display_rect: Rect2) -> void:
	var strings := []
	for entry in model["strings"]:
		strings.append({"text": str(entry["text"]), "mode": str(entry["mode"]),
			"region": UiRenderModel.map_region(entry["region"], display_rect),
			"avoid": _map_rects(entry["avoid"], display_rect)})
	result["expected_regions"] = {"ink": _map_rects(model["ink"], display_rect),
		"forbidden": _map_rects(model["forbidden"], display_rect), "strings": strings}

static func _map_rects(regions: Array, display_rect: Rect2) -> Array:
	return regions.map(func(region): return UiRenderModel.map_region(region, display_rect))

static func _collect_pairs(result: Dictionary, stage: Control, model: Dictionary, display_rect: Rect2) -> void:
	var cursor: TextureRect = stage.get_node_or_null("Cursor")
	var live: Array = UiRenderModel.map_region(cursor.get_global_rect(), display_rect) \
		if cursor != null and cursor.visible else []
	for pair in model["pairs"]:
		result["cursor_pairs"].append({"id": str(pair["id"]), "live": live,
			"cursor": UiRenderModel.map_region(pair["cursor"], display_rect),
			"row": UiRenderModel.map_region(pair["row"], display_rect)})

static func _hud_palette_regions(state: String, display_rect: Rect2) -> Array:
	var interiors: Array = []
	match state:
		"battle_action", "battle_message":
			interiors = [UiRenderArt.MSG_INTERIOR, UiRenderArt.ACTION_INTERIOR]
		"battle_moves", "battle_item":
			interiors = [UiRenderArt.SIDE_INTERIOR, UiRenderArt.MOVE_INTERIOR]
	return interiors.map(func(interior): return UiRenderModel.map_region(interior, display_rect))

static func _collect_draw_order(items: Array, result: Dictionary, namer: Callable, recursive: bool = false) -> void:
	var canvas := []
	for item in items:
		if item is CanvasItem:
			canvas.append(item)
	if recursive:  # BFS: descendants of descendants join as well
		var i := 0
		while i < canvas.size():
			canvas.append_array((canvas[i] as Node).get_children().filter(func(child): return child is CanvasItem)); i += 1
	canvas.sort_custom(func(a, b): return WorldDrawOrder.draws_over(b, a))
	for item in canvas:
		var sort_y := WorldDrawOrder.y_sort_key(item)
		var texture := ""
		if item is TextureRect and (item as TextureRect).texture != null:
			var tex: Texture = (item as TextureRect).texture
			texture = tex.resource_path
			if texture.is_empty() and tex is AtlasTexture and (tex as AtlasTexture).atlas != null:
				texture = (tex as AtlasTexture).atlas.resource_path
		result["draw_order"].append({"node": str(namer.call(item)), "z": WorldDrawOrder.effective_z(item),
			"y_sort": null if is_nan(sort_y) else sort_y, "texture": texture,
			"rect": _int_rect((item as Control).get_global_rect()) if item is Control else []})

static func _node_label(item: Node) -> String:
	var node_name := str(item.name)
	return node_name if not node_name.begins_with("@") else "%s_%d" % [item.get_class(), item.get_index()]

static func _stage_path(stage: Node, item: Node) -> String:
	var parts: Array = []
	var node: Node = item
	while node != null and node != stage:
		parts.push_front(_node_label(node)); node = node.get_parent()
	return "/".join(PackedStringArray(parts))

static func _shot_kind(shot: String) -> String:
	if shot.contains("battle"):
		return "battle"
	return "menu" if ["06_", "07_", "08_", "28_", "29_"].any(func(prefix): return shot.begins_with(prefix)) else "overworld"


static func _menu_state(shot: String) -> String:
	if shot.begins_with("28_"): return "stone_picker"
	return "party_egg_summary" if shot.begins_with("29_") else ""

static func _menu_snapshot(ctx: Dictionary) -> Dictionary:
	var runtime: Node = ctx.get("runtime")
	var party: Array = runtime.get_party_snapshot() if runtime != null else []
	var egg: Dictionary = (party[0].get("egg", {}) if bool(party[0].get("is_egg", false)) else {}) if not party.is_empty() else {}
	return {"party": party, "egg": egg}

static func _battle_state(view: Node) -> String:
	match str(view._menu_state):
		"moves": return "battle_moves"
		"item": return "battle_item"
	return "battle_message" if str(view._message) != "" else "battle_action"

static func _capture_env() -> Dictionary:
	return {"renderer": str(ProjectSettings.get_setting("rendering/renderer/rendering_method", "")),
		"adapter_name": str(RenderingServer.get_video_adapter_name()),
		"adapter_version": str(RenderingServer.get_video_adapter_api_version()),
		"driver_info": [],  # get_video_adapter_driver_info() absent in Godot 4.6.1
		"godot_version": str(Engine.get_version_info().get("string", ""))}

static func _sort_labels(labels: Array) -> void:
	labels.sort_custom(func(a, b):
		if a["text"] != b["text"]:
			return a["text"] < b["text"]
		if a["stage_rect"][1] != b["stage_rect"][1]:
			return a["stage_rect"][1] < b["stage_rect"][1]
		return a["stage_rect"][0] < b["stage_rect"][0])

static func _int_rect(rect: Rect2) -> Array:
	return [int(rect.position.x), int(rect.position.y), int(rect.size.x), int(rect.size.y)]

# Root-viewport crop fallback for the battle SubViewport (#115402 readback):
# BattleDisplay rect scaled by frame / visible rect; pure; empty when unavailable.
static func crop_battle_display(root_viewport: Viewport, battle_view: Node) -> Image:
	var frame: Image = root_viewport.get_texture().get_image()
	var display := battle_view.get_node_or_null("BattleDisplay") as Control
	if frame == null or frame.is_empty() or display == null:
		return Image.new()
	var visible_size: Vector2 = root_viewport.get_visible_rect().size
	if visible_size.x <= 0.0 or visible_size.y <= 0.0:
		return Image.new()
	var texel_scale := Vector2(frame.get_size()) / visible_size
	var rect: Rect2 = display.get_global_rect()
	var crop := Rect2i(Vector2i((rect.position * texel_scale).round()), Vector2i((rect.size * texel_scale).round()))
	crop = crop.intersection(Rect2i(Vector2i.ZERO, frame.get_size()))
	if crop.size.x <= 0 or crop.size.y <= 0:
		return Image.new()
	var image := frame.get_region(crop)
	image.convert(Image.FORMAT_RGBA8)
	return image

static func copy_sidecar(shot_dir: String, shot_name: String, baseline_dir: String) -> bool:
	var source := "%s/%s%s" % [shot_dir, shot_name, SIDECAR_SUFFIX]
	if not FileAccess.file_exists(source):
		return false
	return DirAccess.copy_absolute(ProjectSettings.globalize_path(source),
		ProjectSettings.globalize_path("%s/%s%s" % [baseline_dir, shot_name, SIDECAR_SUFFIX])) == OK

static func prune_sidecars(baseline_dir: String, shots: Array, foreign: Callable = Callable()) -> Array:
	var pruned := []
	var dir := DirAccess.open(ProjectSettings.globalize_path(baseline_dir))
	if dir == null:
		return pruned
	for filename in dir.get_files():
		if not filename.ends_with(SIDECAR_SUFFIX):
			continue
		var shot_name := filename.substr(0, filename.length() - SIDECAR_SUFFIX.length())
		if not shots.has(shot_name) and not (foreign.is_valid() and foreign.call(shot_name)):
			dir.remove(filename)
			pruned.append(filename)
	return pruned
