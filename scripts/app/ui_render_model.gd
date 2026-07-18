extends RefCounted

# Lane 2 (ui_render_audit) expected-region model. Regions are measured from
# the baked art PNGs (scripts/app/ui_render_art.gd), expected strings come
# from snapshot/catalog data, and extents come from fonts.ttf at size 7 —
# never from the game's layout code. Also hosts the worst-case fixtures the
# audit renders with and the pixel-half bridge to tools/visual_lint.py.

const UiRenderArt := preload("res://scripts/app/ui_render_art.gd")

const FONT_PATH := "res://pokewilds/fonts.ttf"
const FONT_SIZE := 7
const STAGE := Rect2(0, 0, 160, 144)
const LINT_DIR := "res://.godot-smoke/lint"
const LINT_SCRIPT := "res://tools/visual_lint.py"
const INK_MIN := 0.02
const FORBIDDEN_MAX := 0.01

static var _font: Font = null


static func battle_font() -> Font:
	if _font == null:
		_font = load(FONT_PATH)
	return _font


static func measure(text: String) -> Vector2:
	return battle_font().get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, FONT_SIZE)


# Expected scene description for one deterministic UI state. Returns:
# {"ink": [Rect2], "forbidden": [Rect2], "pairs": [{"id","cursor","row"}],
#  "strings": [{"text","region","mode","avoid"}]} in stage pixels (160x144).
# mode "anchor": a Label with this text must sit at region.position (+-1.5px);
# mode "box": the Label's ink must fit region and dodge the avoid rects.
# String regions use the font ascent as height: baked GSC glyphs are 7px
# tall, so adjacent 8px-pitch rows never overlap.
static func expected(state: String, snapshot: Dictionary) -> Dictionary:
	var result := {"ink": [], "forbidden": [], "pairs": [], "strings": []}
	var cap := battle_font().get_ascent(FONT_SIZE)
	match state:
		"battle_action", "battle_message":
			for entry in UiRenderArt.ACTION_ROWS:
				result["ink"].append(entry["row"])
				result["pairs"].append({"id": entry["id"], "cursor": entry["cursor"], "row": entry["row"]})
			result["forbidden"].append_array(UiRenderArt.ACTION_FORBIDDEN)
			var message := str(snapshot.get("message", ""))
			if state == "battle_message" and not message.is_empty():
				result["strings"].append({"text": message, "region": UiRenderArt.MSG_INTERIOR, "mode": "box", "avoid": []})
		"battle_moves":
			var moves: Array = snapshot.get("player_mon", {}).get("moves", [])
			for i in range(mini(moves.size(), UiRenderArt.MOVE_ROW_TOPS.size())):
				var text := str(moves[i].get("name", "")).to_upper()
				var region := Rect2(UiRenderArt.MOVE_ANCHOR + Vector2(0, i * 8), Vector2(measure(text).x, cap))
				result["ink"].append(region)
				result["strings"].append({"text": text, "region": region, "mode": "anchor", "avoid": []})
				result["pairs"].append({"id": "move_%d" % i, "cursor": Rect2(UiRenderArt.MOVE_CURSOR_X, UiRenderArt.MOVE_ROW_TOPS[i], 4, 4), "row": region})
			result["forbidden"].append_array(UiRenderArt.MOVE_FORBIDDEN)
			var selected: Dictionary = moves[0] if not moves.is_empty() and moves[0] is Dictionary else {}
			var type_text := str(selected.get("type", "")).to_upper()
			if not type_text.is_empty():
				result["strings"].append({"text": type_text, "region": UiRenderArt.SIDE_INTERIOR, "mode": "box", "avoid": [UiRenderArt.TYPE_SLASH_INK]})
			for text in [str(int(selected.get("pp", 0))), str(int(selected.get("max_pp", selected.get("pp", 0))))]:
				result["strings"].append({"text": text, "region": UiRenderArt.SIDE_INTERIOR, "mode": "box", "avoid": [UiRenderArt.PP_SLASH_INK]})
		"battle_item":
			var bag: Dictionary = snapshot.get("bag", {})
			var ids := ["poke_ball", "potion", "back"]
			var texts := ["POKE BALL x%d" % int(bag.get("poke_ball", 0)),
				"POTION x%d" % int(bag.get("potion", 0)), "BACK"]
			for i in range(texts.size()):
				var region := Rect2(UiRenderArt.ITEM_ANCHOR + Vector2(0, i * 8), Vector2(measure(texts[i]).x, cap))
				result["ink"].append(region)
				result["strings"].append({"text": texts[i], "region": region, "mode": "anchor", "avoid": []})
				result["pairs"].append({"id": ids[i], "cursor": Rect2(UiRenderArt.ITEM_CURSOR_X, UiRenderArt.ITEM_ROW_TOPS[i], 4, 4), "row": region})
			result["forbidden"].append_array(UiRenderArt.ITEM_FORBIDDEN)
	return result


# --- Label geometry (ink truth: what actually gets drawn) ---

# Drawn-ink rect of a Label in its viewport's coordinates: font extents with
# alignment and clipping applied; the font ascent bounds the glyph band.
static func ink_rect(label: Label) -> Rect2:
	var rect := label.get_global_rect()
	if label.autowrap_mode != TextServer.AUTOWRAP_OFF:
		return rect
	var font := label.get_theme_font("font")
	var font_size := label.get_theme_font_size("font_size")
	var need := font.get_string_size(label.text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size)
	var width := minf(need.x, rect.size.x) if label.clip_text else need.x
	var x := rect.position.x
	if label.horizontal_alignment == HORIZONTAL_ALIGNMENT_RIGHT:
		x += rect.size.x - width
	elif label.horizontal_alignment == HORIZONTAL_ALIGNMENT_CENTER:
		x += (rect.size.x - width) * 0.5
	return Rect2(x, rect.position.y, width, font.get_ascent(font_size))


static func visible_labels(root: Control) -> Array:
	var found := []
	for node in root.find_children("*", "Label", true, false):
		if shown(node) and not node.text.is_empty():
			found.append(node)
	return found


# Visibility relative to the owning viewport, so the hidden BattleView root
# does not mask the render-driven visibility flags inside its SubViewport.
static func shown(control: Control) -> bool:
	var node: Node = control
	while node != null and node is not Viewport:
		if node is CanvasItem and not (node as CanvasItem).visible:
			return false
		node = node.get_parent()
	return true


# --- Pixel-half bridge to tools/visual_lint.py (windowed runs only) ---

static func map_region(region: Rect2, display_rect: Rect2) -> Array:
	var scale := display_rect.size.x / 160.0
	var mapped := Rect2(display_rect.position + region.position * scale, region.size * scale)
	return [int(mapped.position.x), int(mapped.position.y), int(mapped.size.x), int(mapped.size.y)]


# Captures already happened on the caller side; this writes the job next to
# the capture, runs the lint, crops evidence for each finding into the lint
# directory, and returns the findings array (empty on a clean verdict or when
# the lint never produced a verdict file).
static func run_lint(state: String, model: Dictionary, image: Image, display_rect: Rect2) -> Array:
	var dir := ProjectSettings.globalize_path(LINT_DIR)
	DirAccess.make_dir_recursive_absolute(dir)
	var base := "%s/%s" % [dir, state]
	image.save_png(base + ".png")
	var job := {"ink_regions": [], "forbidden_zones": [], "text_rows": [], "ink_min": INK_MIN,
		"forbidden_max": FORBIDDEN_MAX, "band_max": int(roundf(12.0 * display_rect.size.x / 160.0))}
	for region in model["ink"]:
		job["ink_regions"].append(map_region(region, display_rect))
	for region in model["forbidden"]:
		job["forbidden_zones"].append(map_region(region, display_rect))
	for expected in model["strings"]:
		if str(expected["mode"]) == "anchor":
			job["text_rows"].append(map_region(expected["region"], display_rect))
	FileAccess.open(base + ".job.json", FileAccess.WRITE).store_string(JSON.stringify(job))
	OS.execute("python3", [ProjectSettings.globalize_path(LINT_SCRIPT),
		"--image", base + ".png", "--job", base + ".job.json", "--out", base + ".out.json"], [])
	var file := FileAccess.open(base + ".out.json", FileAccess.READ)
	if file == null:
		return [{"kind": "lint_unavailable", "region": [0, 0, 0, 0]}]
	var verdict: Variant = JSON.parse_string(file.get_as_text())
	var findings: Array = verdict.get("findings", []) if verdict is Dictionary else []
	for i in range(findings.size()):
		_crop_evidence(image, "%s_finding_%d" % [state, i], findings[i].get("region", []))
	return findings


static func _crop_evidence(image: Image, name: String, region: Array) -> void:
	if region.size() < 4:
		return
	var rect := Rect2i(int(region[0]), int(region[1]), int(region[2]), int(region[3])).intersection(Rect2i(Vector2i.ZERO, image.get_size()))
	if rect.size.x > 0 and rect.size.y > 0:
		image.get_region(rect).save_png("%s/%s.png" % [ProjectSettings.globalize_path(LINT_DIR), name])


# --- Worst-case fixtures (catalog/data-anchored audit inputs) ---

static func worst_snapshot(catalog) -> Dictionary:
	var species := worst_entry(catalog.species.values(), "display_name")
	var move := worst_entry(catalog.moves.values(), "display_name")
	var typed := worst_typed_move(catalog)
	var moves := []
	for source in [typed, move, move, move]:
		moves.append({"move_id": str(source.get("move_id", "")), "name": str(source.get("display_name", "")),
			"type": str(source.get("type", "NORMAL")), "pp": int(source.get("pp", 20)), "max_pp": int(source.get("pp", 20))})
	var mon := {"name": str(species.get("display_name", "?")), "level": 100, "current_hp": 100, "max_hp": 100,
		"status": "PSN", "back_path": "", "front_path": "", "moves": moves}
	var message := "%s used PECK!" % str(species.get("display_name", "?")).get_slice(" ", 0).to_upper()
	return {"player_mon": mon, "enemy_mon": mon, "bag": {"poke_ball": 99, "potion": 99}, "message": message}


static func worst_party(species: Dictionary) -> Array:
	var party := []
	for i in range(6):
		party.append({"name": str(species.get("display_name", "Pokemon")), "species_id": str(species.get("species_id", "")),
			"moves": [], "level": 100, "current_hp": 100, "max_hp": 100, "status": "PSN" if i % 2 == 0 else "", "exp": 0,
			"types": species.get("types", PackedStringArray(["NORMAL"])), "stats": {"atk": 100, "def": 100, "spe": 100, "sat": 100, "sdf": 100}})
	return party


static func worst_bag(catalog) -> Array:
	var items: Array = catalog.items.values()
	items.sort_custom(func(a, b): return str(a.get("display_name", "")).length() > str(b.get("display_name", "")).length())
	var bag := []
	for i in range(mini(6, items.size())):
		bag.append({"item_id": str(items[i].get("item_id", "")), "count": 99})
	return bag


static func worst_entry(entries: Array, field: String) -> Dictionary:
	var best: Dictionary = {}
	for entry in entries:
		if entry is Dictionary and str((entry as Dictionary).get(field, "")).length() > str(best.get(field, "")).length():
			best = entry
	return best


static func worst_typed_move(catalog) -> Dictionary:
	var best: Dictionary = {}
	for move in catalog.moves.values():
		if str(move.get("type", "")).length() > str(best.get("type", "")).length():
			best = move
	return best
