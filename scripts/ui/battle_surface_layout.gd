extends RefCounted

# Baked-art measurements (battle_screen2.png, attack_screen1.png, battle_bg1.png):
# baked GSC glyphs are 7px tall; fonts.ttf at size 7 puts cap ink at label.y + 1 .. + 7.
const MOVE_ROW_TOPS := [104.0, 112.0, 120.0, 128.0]

var _frame_cache := {}


# Small status tags (BRN/PSN/PAR/SLP/FRZ) sit at the right end of each HUD name row.
func enemy_status_rect() -> Rect2:
	return Rect2(84, 8, 20, 9)


func player_status_rect() -> Rect2:
	return Rect2(139, 64, 20, 9)


func build_status_label(is_enemy: bool) -> Label:
	var rect := enemy_status_rect() if is_enemy else player_status_rect()
	var label := Label.new()
	label.position = rect.position
	label.size = rect.size
	label.clip_text = true
	return label


# Covers the baked `:L` plate glyphs and the player plate's baked HP `/` so
# level and HP numbers can flow dynamically without double-drawing.
func build_glyph_covers() -> Control:
	var covers := Control.new()
	covers.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for rect in [Rect2(32, 9, 8, 6), Rect2(112, 65, 8, 6), Rect2(111, 80, 9, 9)]:
		var cover := ColorRect.new()
		cover.color = Color.WHITE
		cover.position = rect.position
		cover.size = rect.size
		covers.add_child(cover)
	return covers


# HUD plates show the full display name when it fits the field at the battle
# font, else fall back to the base-species first token ("DARMANITAN GALARIAN
# ZENMODE" -> "DARMANITAN"); clip_text stays as the final backstop.
func hud_name(font: Font, font_size: int, raw_name: String, max_width: float) -> String:
	var display := raw_name.to_upper()
	if font.get_string_size(display, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size).x <= max_width:
		return display
	return display.get_slice(" ", 0)


# Levels ride just after the rendered name ink; an overlong name slides the
# whole name+level row left so the level label rect stays onstage. A visible
# status tag reserves its width at the stage edge and sits after the level ink.
func place_hud_levels(enemy_name: Label, enemy_level: Label, player_name: Label, player_level: Label, enemy_status: Label = null, player_status: Label = null) -> void:
	_place_hud_level(enemy_name, enemy_level, 13.0, enemy_status)
	_place_hud_level(player_name, player_level, 76.0, player_status)


func _place_hud_level(name_label: Label, level_label: Label, name_x: float, status_label: Label = null) -> void:
	var font := name_label.get_theme_font("font")
	var font_size := name_label.get_theme_font_size("font_size")
	var ink := minf(font.get_string_size(name_label.text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size).x, name_label.size.x)
	var reserve := status_label.size.x + 2.0 if status_label != null and not status_label.text.is_empty() else 0.0
	var max_level_x := 160.0 - reserve - level_label.size.x - 1.0
	name_label.position.x = name_x - maxf(0.0, name_x + ink + 2.0 - max_level_x)
	level_label.position.x = minf(name_x + ink + 2.0, max_level_x)
	if status_label != null:
		var level_ink: float = font.get_string_size(level_label.text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size).x
		status_label.position.x = minf(level_label.position.x + level_ink + 2.0, 160.0 - status_label.size.x)


func overlay_key(menu_state: String) -> String:
	if menu_state == "moves":
		return "moves"
	return "action" if menu_state == "action" else ""


func model(menu_state: String, snapshot: Dictionary) -> Array:
	match menu_state:
		"moves":
			return _move_model(snapshot.get("player_mon", {}).get("moves", []))
		"item":
			return _item_model(snapshot.get("bag", {}))
		_:
			return _action_model()


func first_selectable(menu_state: String, snapshot: Dictionary) -> String:
	for option in model(menu_state, snapshot):
		if bool(option.get("enabled", false)):
			return str(option.get("id", ""))
	return ""


func next_selection(menu_state: String, snapshot: Dictionary, current: String, direction: Vector2i) -> String:
	var option_model = model(menu_state, snapshot)
	var current_option = find_option(option_model, current)
	if current_option.is_empty():
		return first_selectable(menu_state, snapshot)
	var best_id := current
	var best_score := INF
	for option in option_model:
		if not bool(option.get("enabled", false)) or str(option.get("id", "")) == current:
			continue
		var diff: Vector2i = option.get("grid", Vector2i.ZERO) - current_option.get("grid", Vector2i.ZERO)
		var score := INF
		if direction.x != 0 and diff.x != 0 and sign(diff.x) == direction.x:
			score = abs(diff.x) * 100 + abs(diff.y)
		elif direction.y != 0 and diff.y != 0 and sign(diff.y) == direction.y:
			score = abs(diff.y) * 100 + abs(diff.x)
		if score < best_score:
			best_score = score
			best_id = str(option.get("id", ""))
	return best_id


func option_from_point(menu_state: String, snapshot: Dictionary, point: Vector2) -> String:
	for option in model(menu_state, snapshot):
		var hit_rect: Rect2 = option.get("rect", Rect2())
		if hit_rect.has_point(point) and bool(option.get("enabled", false)):
			return str(option.get("id", ""))
	return ""


func find_option(option_model: Array, option_id: String) -> Dictionary:
	for option in option_model:
		if str(option.get("id", "")) == option_id:
			return option
	return {}


func move_info(option: Dictionary) -> Dictionary:
	var move = option.get("move", {})
	if move is Dictionary:
		return move
	return {}


# Front sprites are vertical animation strips (frame counts are not always
# uniform, e.g. cottonee 40x238, minior 56x128). Policy: taller than wide ->
# strip, crop first (0,0,width,width) frame; otherwise use as-is. Cached by path.
func pokemon_frame(path: String) -> Texture2D:
	if path.is_empty():
		return _placeholder_texture()
	var cached = _frame_cache.get(path)
	if cached != null:
		return cached
	var frame: Texture2D = null
	if ResourceLoader.exists(path):
		frame = load(path)
	if frame == null or frame is not Texture2D:
		frame = _placeholder_texture()
	elif frame.get_height() > frame.get_width():
		var first := AtlasTexture.new()
		first.atlas = frame
		first.region = Rect2(0, 0, frame.get_width(), frame.get_width())
		frame = first
	_frame_cache[path] = frame
	return frame


func _placeholder_texture() -> Texture2D:
	var image := Image.create(40, 40, false, Image.FORMAT_RGBA8)
	image.fill_rect(Rect2i(4, 4, 32, 32), Color(0.149, 0.149, 0.149))
	var rows := ["###", "..#", "..#", ".#.", ".#.", "...", ".#."]
	for gy in range(rows.size()):
		for gx in range(3):
			if rows[gy].substr(gx, 1) == "#": image.fill_rect(Rect2i(14 + gx * 4, 6 + gy * 4, 4, 4), Color(0.867, 0.867, 0.867))
	return ImageTexture.create_from_image(image)


func _action_model() -> Array:
	return [
		_entry("fight", "FIGHT", Vector2(80, 111), Vector2(72, 112), Rect2(68, 108, 38, 16), Vector2i(0, 0), true),
		_entry("pkmn", "PKMN", Vector2(123, 111), Vector2(115, 112), Rect2(106, 108, 48, 16), Vector2i(1, 0), false),
		_entry("item", "ITEM", Vector2(80, 127), Vector2(72, 128), Rect2(68, 124, 38, 16), Vector2i(0, 1), true),
		_entry("run", "RUN", Vector2(126, 127), Vector2(115, 128), Rect2(106, 124, 48, 16), Vector2i(1, 1), true),
	]


func _move_model(moves: Array) -> Array:
	var result: Array = []
	for i in range(min(moves.size(), MOVE_ROW_TOPS.size())):
		var move_variant = moves[i]
		if move_variant is not Dictionary:
			continue
		var move: Dictionary = move_variant
		var row_top: float = MOVE_ROW_TOPS[i]
		var entry = _entry(
			"move_%d" % i,
			str(move.get("name", move.get("move_id", "MOVE"))).to_upper(),
			Vector2(45, row_top - 1.0),
			Vector2(37, row_top),
			Rect2(37, row_top, 116, 8),
			Vector2i(0, i),
			int(move.get("pp", 0)) > 0,
			Vector2(108, 8)
		)
		entry["move"] = move
		result.append(entry)
	return result


# Single-column rows: "POKE BALL x99" measures 76px at the battle font, so the
# old two-column layout drew the POKE BALL count over the POTION label.
func _item_model(bag: Dictionary) -> Array:
	return [
		_entry("poke_ball", "POKE BALL x%d" % int(bag.get("poke_ball", 0)), Vector2(16, 111), Vector2(8, 112), Rect2(7, 110, 146, 8), Vector2i(0, 0), int(bag.get("poke_ball", 0)) > 0, Vector2(140, 8)),
		_entry("potion", "POTION x%d" % int(bag.get("potion", 0)), Vector2(16, 119), Vector2(8, 120), Rect2(7, 118, 146, 8), Vector2i(0, 1), int(bag.get("potion", 0)) > 0, Vector2(140, 8)),
		_entry("back", "BACK", Vector2(16, 127), Vector2(8, 128), Rect2(7, 126, 146, 8), Vector2i(0, 2), true, Vector2(140, 8)),
	]


func _entry(id: String, text: String, label_pos: Vector2, cursor_pos: Vector2, rect: Rect2, grid: Vector2i, enabled: bool, label_size: Vector2 = Vector2(56, 8)) -> Dictionary:
	return {"id": id, "text": text, "label_pos": label_pos, "label_size": label_size,
		"cursor_pos": cursor_pos, "rect": rect, "grid": grid, "enabled": enabled}
