extends Control

# Campfire crafting menu (Phase 2 camping slice; spec:
# docs/product-specs/camping-crafting-survival.md), restyled onto the GBC stage
# idiom (restyle slice wave 2): an opaque 160x144 stage (gbc_stage.gd) with the
# gsc background art and a white plate composition — title plate, clipped entry
# rows (black ink, dim ink when short on ingredients; black arrow cursor), and
# autowrap detail/hint plates (menu_list_stage.gd). Behavior is unchanged: a
# flat entry list of the five campfire recipes (crafting_runtime.craftable_at_station)
# with have/need ingredient counts, greyed when short; then the fire toggle
# (Extinguish/Light) and Demolish. Demolition STAYS a menu entry because
# field_action_router routes faced-campfire Z HERE now instead of straight to
# harvest_tile — the build loop's witness escape (Cut refunds) must never be
# shadowed by the new Z precedence. Self-wires through /root/GameRuntime; the
# fire toggle is a router-supplied Callable (absent, the entry hides). Recipe
# ingredients are read REFLECTIVELY off the pinned Recipes domain const
# (camp_menu_access.gd, extracted at the 220 wall).

signal closed

const GbcStage := preload("res://scripts/ui/gbc_stage.gd")
const MenuList := preload("res://scripts/ui/menu_list_stage.gd")
const Access := preload("res://scripts/ui/camp_menu_access.gd")

const ENTRY_RECIPE := "recipe"
const ENTRY_TOGGLE := "toggle"
const ENTRY_DEMOLISH := "demolish"
const COLOR_OK := Color(0.9, 0.92, 0.96, 1.0) # legacy dark-theme fg, kept for API stability; enabled rows now use black ink
const COLOR_MISSING := Color(0.58, 0.58, 0.64, 1.0) # the short-on-ingredients dim ink

var _runtime: Node = null
var _toggle_light: Callable = Callable()
var _rows: Array = []
var _tile := Vector2i.ZERO
var _station_id := ""
var _stage: Control
var _display: TextureRect
var _list: MenuList.Rows
var _title: Label
var _detail: Label
var _hint: Label

func _ready() -> void:
	visible = false
	var parts := GbcStage.build(self) # opaque black backing + 160x144 stage + integer-scaled display
	_stage = parts.stage
	_display = parts.display
	GbcStage.on_resized(self, _display)
	var built := MenuList.build(_stage, {
		"title": "CAMPFIRE", "title_rect": Rect2(36, 6, 88, 14),
		"rows_rect": Rect2(6, 24, 148, 62), "max_visible": 7,
		"detail_rect": Rect2(6, 90, 148, 30),
		"hint_rect": Rect2(6, 124, 148, 10), "hint": "Z: Craft   X: Close"})
	_list = built.rows
	_title = built.title_label
	_detail = built.detail_label
	_hint = built.hint_label

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

# --- Scenario/lead seams (the old MenuPanel/Margin/VBox/Entries ItemList reads) ---
func stage_root() -> Control: return _stage
func row_texts() -> Array: return _list.row_texts()
func selected_row_text() -> String: return _list.row_text(_list.selected())
func select_row(index: int) -> void: _list.select(index)
func row_count() -> int: return _list.row_count()
func row_rect(index: int) -> Rect2: return _list.row_rect(index) # stage-local

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

# Click convenience (the old item_clicked route) via the stage-inverse hit test.
func _gui_input(event: InputEvent) -> void:
	if not visible or not (event is InputEventMouseButton):
		return
	var button := event as InputEventMouseButton
	if button.pressed and button.button_index == MOUSE_BUTTON_LEFT:
		var hit := MenuList.hit_row(_display, button.position, _list)
		if hit >= 0:
			_on_entry_clicked(hit, button.position, MOUSE_BUTTON_LEFT)
			accept_event()

func _refresh() -> void:
	_rows.clear()
	var texts: Array = []
	var inks: Array = []
	for output_id in Access.craftable_ids(Access.crafting(_runtime), _station_id):
		_add_recipe_row(texts, inks, str(output_id))
	if _toggle_light.is_valid():
		_add_row(texts, inks, ENTRY_TOGGLE, "", "Extinguish the fire" if Access.placement_is_lit(_runtime, _tile) else "Light the fire", true)
	_add_row(texts, inks, ENTRY_DEMOLISH, "", "Demolish the %s" % _station_id.replace("_", " "), true)
	_hint.text = "Z: Craft   X: Close"
	_list.set_rows(texts, inks) # resets the cursor to row 0 (the old _entries.select(0) contract)
	_update_detail()

func _add_recipe_row(texts: Array, inks: Array, output_id: String) -> void:
	var parts: Array = []
	var craftable := true
	var ingredients := Access.ingredients_for(Access.crafting(_runtime), output_id)
	if not ingredients.is_empty():
		for item_id in ingredients.keys():
			var have := Access.item_count(_runtime, str(item_id))
			var need := int(ingredients[item_id])
			craftable = craftable and have >= need
			parts.append("%d/%d %s" % [have, need, Access.item_label(_runtime, str(item_id))])
	else: # reflective table absent: fall back to the runtime's missing counts
		for item_id in Access.missing_for(Access.crafting(_runtime), output_id).keys():
			craftable = false
			parts.append("needs %s" % Access.item_label(_runtime, str(item_id)))
	var label := Access.item_label(_runtime, output_id) # "<Name> — have/need ..." when costs resolve
	_add_row(texts, inks, ENTRY_RECIPE, output_id, label if parts.is_empty() else "%s — %s" % [label, ", ".join(parts)], craftable)

func _add_row(texts: Array, inks: Array, kind: String, row_id: String, label: String, enabled: bool) -> void:
	_rows.append({"kind": kind, "id": row_id})
	texts.append(label)
	inks.append(Color.BLACK if enabled else COLOR_MISSING) # greyed row = dim ink (white-plate ink rule)

func _activate_selected() -> void:
	if _list.row_count() == 0 or _list.selected() >= _rows.size():
		return
	var row: Dictionary = _rows[_list.selected()]
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
	var crafting: Variant = Access.crafting(_runtime)
	if crafting == null or not crafting.has_method("craft"):
		Access.toast(self, "Nothing can be crafted here yet.", 1.6)
		return
	var result: Variant = crafting.call("craft", output_id, _station_id)
	Access.toast(self, str((result as Dictionary).get("message", "Nothing happened.")) if result is Dictionary else "Nothing happened.", 1.8)
	if _runtime != null:
		_runtime.save_game()
	_refresh()

# Only reachable via the toggle row, which only exists when the callable is valid.
func _toggle() -> void:
	var result: Variant = _toggle_light.call(_tile)
	Access.toast(self, str((result as Dictionary).get("message", "")) if result is Dictionary else "", 1.6)
	_refresh()

# Demolish runs BEFORE close so the closed-driven save captures the refund.
func _demolish() -> void:
	var result: Variant = _runtime.harvest_tile(_tile) if _runtime != null else {}
	close_menu()
	Access.toast(self, str((result as Dictionary).get("message", "")) if result is Dictionary else "", 1.8)

func _move_selection(direction: int) -> void:
	if _list.row_count() == 0:
		return
	_list.move(direction)
	_update_detail()

# Selected-row detail: missing counts (the crafting runtime's menu contract)
# or a ready note — the bag-screen-style description line.
func _update_detail() -> void:
	_detail.text = ""
	if _list.row_count() == 0 or _list.selected() >= _rows.size() \
			or str((_rows[_list.selected()] as Dictionary).get("kind", "")) != ENTRY_RECIPE:
		return
	var missing := Access.missing_for(Access.crafting(_runtime), str(_rows[_list.selected()].get("id", "")))
	if missing.is_empty():
		_detail.text = "Ready to craft."
		return
	_detail.text = "Still needed: %s" % ", ".join(missing.keys().map(
		func(item_id): return "%d %s" % [int(missing[item_id]), Access.item_label(_runtime, str(item_id))]))

func _on_entry_clicked(index: int, _at_position: Vector2, _mouse_button_index: int) -> void:
	_list.select(index)
	_activate_selected()
