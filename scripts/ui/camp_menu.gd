extends Control

# Campfire crafting menu (Phase 2 camping slice; spec:
# docs/product-specs/camping-crafting-survival.md). Flat entry list: the five
# campfire recipes (crafting_runtime.craftable_at_station) with have/need
# ingredient counts, greyed when short; then the fire toggle (Extinguish/Light)
# and Demolish. Demolition STAYS a menu entry because field_action_router
# routes faced-campfire Z HERE now instead of straight to harvest_tile — the
# build loop's witness escape (Cut refunds) must never be shadowed by the new
# Z precedence. Self-wires through the /root/GameRuntime autoload (world_view's
# RuntimePath convention): crafting runtime for list / missing / craft, session
# for bag counts, catalog for names, harvest_tile + save_game for demolish. The
# fire toggle is a router-supplied Callable (placement mutation + campfire_lit
# trace are app-layer wiring); absent, the entry hides. Recipe ingredients are
# read REFLECTIVELY off the crafting runtime's pinned Recipes domain const (ui
# may not import domain per check_architecture), with a missing_for fallback.

signal closed

const ENTRY_RECIPE := "recipe"
const ENTRY_TOGGLE := "toggle"
const ENTRY_DEMOLISH := "demolish"
const COLOR_OK := Color(0.9, 0.92, 0.96, 1.0)
const COLOR_MISSING := Color(0.58, 0.58, 0.64, 1.0)

@onready var _title: Label = $MenuPanel/Margin/VBox/Title
@onready var _entries: ItemList = $MenuPanel/Margin/VBox/Entries
@onready var _detail: Label = $MenuPanel/Margin/VBox/Detail
@onready var _hint: Label = $MenuPanel/Margin/VBox/Hint

var _runtime: Node = null
var _toggle_light: Callable = Callable()
var _rows: Array = []
var _tile := Vector2i.ZERO
var _station_id := ""

func _ready() -> void:
	visible = false
	_entries.item_clicked.connect(_on_entry_clicked)

func open_menu(tile: Vector2i, station_id: String, toggle_light: Callable = Callable()) -> void:
	_runtime = get_node_or_null("/root/GameRuntime")
	_tile = tile
	_station_id = station_id
	_toggle_light = toggle_light
	_title.text = station_id.replace("_", " ").to_upper()
	_refresh()
	visible = true

func close_menu() -> void:
	if not visible:
		return
	visible = false
	closed.emit()

func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("move_up"):
		_move_selection(-1)
	elif event.is_action_pressed("move_down"):
		_move_selection(1)
	elif event.is_action_pressed("action_a"):
		_activate_selected()
	elif event.is_action_pressed("action_b") or event.is_action_pressed("start"):
		close_menu()
	else:
		return
	get_viewport().set_input_as_handled()

func _refresh() -> void:
	_rows.clear()
	_entries.clear()
	for output_id in _craftable_ids():
		_add_recipe_row(str(output_id))
	if _toggle_light.is_valid():
		_add_row(ENTRY_TOGGLE, "", "Extinguish the fire" if _placement_is_lit() else "Light the fire", true)
	_add_row(ENTRY_DEMOLISH, "", "Demolish the %s" % _station_id.replace("_", " "), true)
	_hint.text = "Z: Craft   X: Close"
	_entries.select(0)
	_update_detail()

func _add_recipe_row(output_id: String) -> void:
	var parts: Array = []
	var craftable := true
	var ingredients := _ingredients_for(output_id)
	if not ingredients.is_empty():
		for item_id in ingredients.keys():
			var have := _item_count(str(item_id))
			var need := int(ingredients[item_id])
			craftable = craftable and have >= need
			parts.append("%d/%d %s" % [have, need, _item_label(str(item_id))])
	else: # reflective table absent: fall back to the runtime's missing counts
		for item_id in _missing_for(output_id).keys():
			craftable = false
			parts.append("needs %s" % _item_label(str(item_id)))
	var label := _item_label(output_id) # "<Name> — have/need ..." when costs resolve
	_add_row(ENTRY_RECIPE, output_id, label if parts.is_empty() else "%s — %s" % [label, ", ".join(parts)], craftable)

func _add_row(kind: String, row_id: String, label: String, enabled: bool) -> void:
	_rows.append({"kind": kind, "id": row_id})
	_entries.add_item(label)
	_entries.set_item_custom_fg_color(_entries.item_count - 1, COLOR_OK if enabled else COLOR_MISSING)

func _activate_selected() -> void:
	var selected := _entries.get_selected_items()
	if selected.is_empty() or int(selected[0]) >= _rows.size():
		return
	var row: Dictionary = _rows[int(selected[0])]
	match str(row.get("kind", "")):
		ENTRY_RECIPE:
			_craft(str(row.get("id", "")))
		ENTRY_TOGGLE:
			_toggle()
		ENTRY_DEMOLISH:
			_demolish()

# Craft consumes + grants through the crafting runtime (all-or-nothing); its
# message carries every refusal reason.
func _craft(output_id: String) -> void:
	var crafting: Variant = _crafting()
	if crafting == null or not crafting.has_method("craft"):
		_toast("Nothing can be crafted here yet.", 1.6)
		return
	var result: Variant = crafting.call("craft", output_id, _station_id)
	_toast(str((result as Dictionary).get("message", "Nothing happened.")) if result is Dictionary else "Nothing happened.", 1.8)
	if _runtime != null:
		_runtime.save_game()
	_refresh()

# Only reachable via the toggle row, which only exists when the callable is valid.
func _toggle() -> void:
	var result: Variant = _toggle_light.call(_tile)
	_toast(str((result as Dictionary).get("message", "")) if result is Dictionary else "", 1.6)
	_refresh()

# Demolish runs BEFORE close so the closed-driven save captures the refund.
func _demolish() -> void:
	var result: Variant = _runtime.harvest_tile(_tile) if _runtime != null else {}
	close_menu()
	_toast(str((result as Dictionary).get("message", "")) if result is Dictionary else "", 1.8)

func _move_selection(direction: int) -> void:
	if _entries.item_count == 0:
		return
	var selected := _entries.get_selected_items()
	_entries.select(wrapi((int(selected[0]) if not selected.is_empty() else 0) + direction, 0, _entries.item_count))
	_entries.ensure_current_is_visible()
	_update_detail()

# Selected-row detail: missing counts (the crafting runtime's menu contract)
# or a ready note — the bag-screen-style description line.
func _update_detail() -> void:
	_detail.text = ""
	var selected := _entries.get_selected_items()
	if selected.is_empty() or int(selected[0]) >= _rows.size() \
			or str((_rows[int(selected[0])] as Dictionary).get("kind", "")) != ENTRY_RECIPE:
		return
	var missing := _missing_for(str(_rows[int(selected[0])].get("id", "")))
	if missing.is_empty():
		_detail.text = "Ready to craft."
		return
	_detail.text = "Still needed: %s" % ", ".join(missing.keys().map(
		func(item_id): return "%d %s" % [int(missing[item_id]), _item_label(str(item_id))]))

func _crafting() -> Variant:
	return _runtime.get("crafting_runtime") if _runtime != null else null

func _craftable_ids() -> Array:
	var crafting: Variant = _crafting()
	if crafting == null or not crafting.has_method("craftable_at_station"):
		return []
	var listed: Variant = crafting.call("craftable_at_station", _station_id)
	return listed if listed is Array else []

func _missing_for(output_id: String) -> Dictionary:
	var crafting: Variant = _crafting()
	if crafting == null or not crafting.has_method("missing_for"):
		return {}
	var missing: Variant = crafting.call("missing_for", output_id)
	return missing if missing is Dictionary else {}

# Ingredients read reflectively off the crafting runtime's pinned Recipes
# domain const (script -> Recipes -> RECIPES): the layer-safe read.
func _ingredients_for(output_id: String) -> Dictionary:
	var crafting: Variant = _crafting()
	var script: Variant = (crafting as Object).get_script() if crafting != null else null
	var recipes: Variant = (script as Script).get_script_constant_map().get("Recipes") if script is Script else null
	var table: Variant = (recipes as Script).get_script_constant_map().get("RECIPES") if recipes is Script else null
	var recipe: Variant = (table as Dictionary).get(output_id, {}) if table is Dictionary else {}
	var ingredients: Variant = (recipe as Dictionary).get("ingredients", {}) if recipe is Dictionary else {}
	return ingredients if ingredients is Dictionary else {}

func _item_count(item_id: String) -> int:
	var session: Variant = _runtime.get("session") if _runtime != null else null
	return int(session.get_item_count(item_id)) if session != null else 0

func _item_label(item_id: String) -> String:
	var item: Variant = _runtime.catalog.get_item(item_id.strip_edges().to_lower()) if _runtime != null else {}
	var label := str(item.get("display_name", "")) if item is Dictionary else ""
	return label.capitalize() if not label.is_empty() else item_id.replace("_", " ").capitalize()

# Absent "lit" means lit (structures.placement_is_lit semantics; via the public
# placed_structures accessor — the ui layer never reads the domain rule).
func _placement_is_lit() -> bool:
	if _runtime == null:
		return true
	var entry: Variant = _runtime.placed_structures().get("%d,%d" % [_tile.x, _tile.y], {})
	return entry.get("lit", true) != false if entry is Dictionary else true

func _toast(text: String, seconds: float) -> void:
	if text.is_empty():
		return
	var box := get_node_or_null("../MessageBox")
	if box != null and box.has_method("show_message"):
		box.call("show_message", text, seconds)

func _on_entry_clicked(index: int, _at_position: Vector2, _mouse_button_index: int) -> void:
	_entries.select(index)
	_activate_selected()
