extends Node

# Layout audit dispatched from SmokeScenarios: renders the live battle surface
# and start-menu screens with worst-case catalog data (longest species/move/
# item names, 100/100 HP, a long two-line message) and asserts font metrics
# fit their rects and cursors/markers sit on their rows. No pixel reading.

const BattleSurfaceLayout := preload("res://scripts/ui/battle_surface_layout.gd")

const FIT_TOLERANCE := 1.0
const ALIGN_TOLERANCE := 2.0

var _ctx: Dictionary = {}
var _layout := BattleSurfaceLayout.new()
var _failures: Array = []
var _labels_checked := 0
var _cursors_checked := 0
var _screens_checked := 0

func run(ctx: Dictionary) -> void:
	_ctx = ctx
	var catalog = _runtime().get("catalog")
	var species := _worst_entry(catalog.species.values(), "display_name")
	var move := _worst_entry(catalog.moves.values(), "display_name")
	var move_instance := {"move_id": str(move.get("move_id", "")), "name": str(move.get("display_name", "")), "type": str(move.get("type", "NORMAL")), "power": int(move.get("power", 0)), "max_pp": int(move.get("pp", 20)), "pp": int(move.get("pp", 20))}
	var moves := [move_instance, move_instance, move_instance, move_instance]
	var mon_name := str(species.get("display_name", "?"))
	var player_mon := {"name": mon_name, "level": 100, "current_hp": 100, "max_hp": 100, "status": "PSN", "back_path": "", "moves": moves}
	var enemy_mon := {"name": mon_name, "level": 100, "current_hp": 100, "max_hp": 100, "status": "FRZ", "front_path": ""}
	var snapshot := {"player_mon": player_mon, "enemy_mon": enemy_mon, "bag": {"poke_ball": 99, "potion": 99}}
	var message := "%s used %s!\nIt's super effective!" % [mon_name.to_upper(), str(move.get("display_name", "?")).to_upper()]
	_audit_battle(snapshot, message)
	await _audit_menus(catalog, species, moves)
	if _failures.is_empty():
		_runtime().emit_trace("layout_audit_passed", "SmokeScenarios", {"labels_checked": _labels_checked, "cursors_checked": _cursors_checked, "screens_checked": _screens_checked})
	else:
		push_error("Layout audit failures:\n" + "\n".join(PackedStringArray(_failures)))

func _audit_battle(snapshot: Dictionary, message: String) -> void:
	var stage: Control = _battle_view().get_node("BattleViewport/BattleStage")
	for menu_state in ["action", "moves", "item"]:
		stage.render(snapshot, menu_state, _layout.first_selectable(menu_state, snapshot), message)
		_audit_labels(stage, "battle_%s" % menu_state, stage.get_global_rect())
		_audit_cursors(stage, snapshot, menu_state)
	stage.render(snapshot, "action", "fight", "")
	# Level labels ride just after the clipped name ink; extents must not overlap.
	for pair in [["EnemyName", "EnemyLevel"], ["PlayerHUD/PlayerName", "PlayerHUD/PlayerLevel"]]:
		var name_label: Label = stage.get_node(pair[0])
		var level_label: Label = stage.get_node(pair[1])
		_labels_checked += 1
		var ink := minf(name_label.get_theme_font("font").get_string_size(name_label.text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, name_label.get_theme_font_size("font_size")).x, name_label.size.x)
		var overlap := name_label.position.x + ink - level_label.position.x
		if overlap > FIT_TOLERANCE:
			_fail("battle_hud %s: overlaps %s name ink by %spx" % [pair[1], pair[0], snappedf(overlap, 0.1)])
	_screens_checked += 1

func _audit_cursors(stage: Control, snapshot: Dictionary, menu_state: String) -> void:
	var cursor: TextureRect = stage.get_node("Cursor")
	for option in _layout.model(menu_state, snapshot):
		if not bool(option.get("enabled", false)):
			continue
		_cursors_checked += 1
		var option_id := str(option.get("id", ""))
		var label_rect := Rect2(option.get("label_pos", Vector2.ZERO), option.get("label_size", Vector2.ZERO))
		var cursor_rect := Rect2(option.get("cursor_pos", Vector2.ZERO), cursor.size)
		var drift := absf(cursor_rect.get_center().y - label_rect.get_center().y)
		if drift > ALIGN_TOLERANCE:
			_fail("battle_%s cursor %s: %spx off the row center" % [menu_state, option_id, snappedf(drift, 0.1)])
		elif cursor_rect.end.x > label_rect.position.x + FIT_TOLERANCE:
			_fail("battle_%s cursor %s: right edge covers the row text" % [menu_state, option_id])

func _audit_menus(catalog, species: Dictionary, moves: Array) -> void:
	var menu := _start_menu()
	var original: Dictionary = menu._raw_context
	var party := _worst_party(species, moves)
	var bag := _worst_bag(catalog)
	var injected := original.duplicate()
	injected["get_party_snapshot"] = func(): return party
	injected["get_bag_snapshot"] = func(): return bag
	menu.setup(injected)
	_call("toggle_menu")
	await _settle(2)
	_audit_labels(menu, "start_menu", menu.get_node("MenuPanel").get_global_rect())
	_screens_checked += 1
	menu._activate_entry(0)
	await _settle(2)
	var party_screen: Control = menu.get_node("PartyScreen")
	var panel_rect: Rect2 = party_screen.get_node("Panel").get_global_rect()
	_audit_labels(party_screen, "party", panel_rect)
	_audit_rows(party_screen.get_node("Panel/Margin/HBox/ListColumn/Rows"), "party")
	party_screen._confirm()
	await _settle(2)
	_audit_labels(party_screen, "party_actions", panel_rect)
	party_screen._action_selected = 1
	party_screen._activate_action()
	await _settle(2)
	_audit_labels(party_screen, "party_summary", panel_rect)
	_screens_checked += 1
	party_screen.close_screen()
	menu._activate_entry(1)
	await _settle(2)
	var bag_screen: Control = menu.get_node("BagScreen")
	bag_screen._selected = maxi(0, bag.size() - 2) # longest-description row
	bag_screen._update_description()
	await _settle(2)
	_audit_labels(bag_screen, "bag", bag_screen.get_node("Panel").get_global_rect())
	bag_screen._selected = bag.size() - 1 # potion row opens the party picker
	bag_screen._activate_item()
	await _settle(2)
	_audit_rows(bag_screen.get_node("Panel/Margin/VBox/Body/SideColumn/PartyPanel/Margin/VBox/PartyRows"), "bag_picker")
	_screens_checked += 1
	bag_screen.close_screen()
	_call("toggle_menu")
	menu.setup(original)

func _audit_labels(root: Control, tag: String, bounds: Rect2) -> void:
	for label: Label in _visible_children(root, "Label"):
		if label.text.is_empty():
			continue
		_labels_checked += 1
		var font := label.get_theme_font("font")
		var need := font.get_string_size(label.text, HORIZONTAL_ALIGNMENT_LEFT,
			-1.0 if label.autowrap_mode == TextServer.AUTOWRAP_OFF else label.size.x, label.get_theme_font_size("font_size"))
		if need.x > label.size.x + FIT_TOLERANCE or need.y > label.size.y + FIT_TOLERANCE:
			_fail("%s %s: text \"%s\" needs %s, rect is %s" % [tag, label.name, label.text.left(32), need, label.size])
		if not bounds.grow(FIT_TOLERANCE).encloses(label.get_global_rect()):
			_fail("%s %s: rect escapes its panel bounds" % [tag, label.name])
	for list: ItemList in _visible_children(root, "ItemList"):
		var font := list.get_theme_font("font")
		var font_size := list.get_theme_font_size("font_size")
		for i in range(list.item_count):
			_labels_checked += 1
			if font.get_string_size(list.get_item_text(i), HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size).x > list.size.x + FIT_TOLERANCE:
				_fail("%s %s row %d: \"%s\" overflows the %spx list" % [tag, list.name, i, list.get_item_text(i).left(24), list.size.x])

# Rows must fit their width; the selected row's marker must sit on the text.
func _audit_rows(rows: Container, tag: String) -> void:
	for i in range(rows.get_child_count()):
		var row := rows.get_child(i) as HBoxContainer
		if row == null:
			continue
		if row.get_combined_minimum_size().x > row.size.x + FIT_TOLERANCE:
			_fail("%s row %d: content needs %spx, row is %spx wide" % [tag, i, row.get_combined_minimum_size().x, row.size.x])
		if i > 0 or row.get_child_count() < 2:
			continue
		var marker := row.get_child(0) as Label
		var name_label := row.get_child(1) as Label
		if marker == null or name_label == null:
			continue
		_cursors_checked += 1
		var marker_rect := marker.get_global_rect()
		var text_rect := name_label.get_global_rect()
		if marker.text != ">":
			_fail("%s row 0: selected row lost its > marker" % tag)
		if absf(marker_rect.get_center().y - text_rect.get_center().y) > ALIGN_TOLERANCE or marker_rect.end.x > text_rect.position.x + FIT_TOLERANCE:
			_fail("%s row 0: > marker misaligned with the row text" % tag)

func _visible_children(root: Control, type: String) -> Array:
	var found := []
	for node in root.find_children("*", type, true, false):
		if _shown(node):
			found.append(node)
	return found

func _worst_entry(entries: Array, field: String) -> Dictionary:
	var best: Dictionary = {}
	for entry in entries:
		if entry is Dictionary and str((entry as Dictionary).get(field, "")).length() > str(best.get(field, "")).length():
			best = entry
	return best

func _worst_party(species: Dictionary, moves: Array) -> Array:
	var party := []
	var hps := [[1, 100], [100, 100], [55, 100], [0, 100], [99, 100], [7, 100]]
	for i in range(hps.size()):
		party.append({"name": str(species.get("display_name", "Pokemon")), "species_id": str(species.get("species_id", "")), "moves": moves,
			"level": 99 if i == 0 else 100, "current_hp": hps[i][0], "max_hp": hps[i][1], "status": "BRN" if i % 2 == 0 else "", "exp": 0,
			"types": species.get("types", PackedStringArray(["NORMAL"])), "stats": {"atk": 100, "def": 100, "spe": 100, "sat": 100, "sdf": 100}})
	return party

func _worst_bag(catalog) -> Array:
	var items: Array = catalog.items.values()
	items.sort_custom(func(a, b): return str(a.get("display_name", "")).length() > str(b.get("display_name", "")).length())
	var bag := []
	for i in range(mini(6, items.size())):
		bag.append({"item_id": str(items[i].get("item_id", "")), "count": 99})
	bag.append({"item_id": str(_worst_entry(items, "description").get("item_id", "")), "count": 99})
	bag.append({"item_id": "potion", "count": 99})
	return bag

# Visibility relative to the owning viewport, so the hidden BattleView root
# does not mask the render-driven visibility flags inside its SubViewport.
func _shown(control: Control) -> bool:
	var node: Node = control
	while node != null and node is not Viewport:
		if node is CanvasItem and not (node as CanvasItem).visible:
			return false
		node = node.get_parent()
	return true

func _fail(message: String) -> void:
	_failures.append(message)

func _settle(frames: int) -> void:
	for _i in range(frames):
		await get_tree().process_frame

func _call(key: String, args: Array = []) -> void:
	var callable: Callable = _ctx.get(key, Callable())
	if callable.is_valid():
		callable.callv(args)

func _runtime() -> Node: return _ctx["runtime"]
func _battle_view() -> Node: return _ctx["battle_view"]
func _start_menu() -> Node: return _ctx["start_menu"]
