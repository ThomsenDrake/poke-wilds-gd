extends Control

# The way-stone SELECTOR (infinite-world slice; renamed from the Phase-7 beacon selector,
# which listed edge-band beacons — the edge-beacon concept retired with world chaining),
# restyled onto the GBC stage idiom (restyle slice wave 2): an opaque 160x144 stage
# (gbc_stage.gd) with the gsc background art, a white title plate, a clipped white-plate
# row list (black ink + black arrow cursor, windowed past 10 rows), and a hint plate
# (menu_list_stage.gd composition). A registration-ordered list of the registered
# intra-world way-stones. The screen is DUMB by layer contract (ui may not import
# domain per check_architecture): the opener (field_move_actions) supplies the rows off
# field_move_runtime.way_stone_tiles() — already registration-ordered, so the list
# order IS the deterministic order — plus a resolve Callable that warps + saves; this
# screen only lists, navigates, and reports the chosen tile. Z chooses, X/Enter cancels.
#
# WIRING: the argless `closed` signal is input_router's latch contract (a Z-select /
# X-close this frame must not also fire Main's menu-toggle / context polls). main.gd's
# bind_ui_consumers array is frozen AT its 220 budget, so the screen SELF-WIRES the
# latch — the documented reach into the scene script's _input_router (mirrors the
# field_action_router._toggle_campfire documented-reach precedent); bind_ui_consumers
# is idempotent, so the boot-time attempt + the open-time heal never double-connect.

signal closed

const GbcStage := preload("res://scripts/ui/gbc_stage.gd")
const MenuList := preload("res://scripts/ui/menu_list_stage.gd")

const COLOR_ROW := Color(0.9, 0.92, 0.96, 1.0) # legacy dark-theme fg, kept for API stability; rows now use black ink

var _rows: Array = [] # [{"label": String, "tile": Vector2i}] in registration order
var _resolve: Callable = Callable() # opener-supplied: resolve.call(chosen_tile)
var _stage: Control
var _display: TextureRect
var _list: MenuList.Rows
var _title: Label
var _hint: Label

func _ready() -> void:
	visible = false
	var parts := GbcStage.build(self) # opaque black backing + 160x144 stage + integer-scaled display
	_stage = parts.stage
	_display = parts.display
	GbcStage.on_resized(self, _display)
	var built := MenuList.build(_stage, {
		"title": "WAY STONES", "title_rect": Rect2(28, 6, 104, 14),
		"rows_rect": Rect2(8, 24, 144, 88), "max_visible": 10,
		"hint_rect": Rect2(8, 118, 144, 10), "hint": "Z: Travel   X: Close"})
	_list = built.rows
	_title = built.title_label
	_hint = built.hint_label
	_wire_input_latch() # best-effort at boot; open_selector heals a current_scene miss

func open_selector(title: String, rows: Array, resolve: Callable) -> void:
	_title.text = title
	_rows = rows.duplicate(true)
	_resolve = resolve
	_refresh()
	_wire_input_latch()
	visible = true

func close_selector() -> void:
	if not visible:
		return
	visible = false
	closed.emit() # argless — the latch contract (input_router.bind_ui_consumers)

# --- Scenario/lead seams (the old Entries ItemList reads; _rows stays the data witness) ---
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
		close_selector()
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
	var texts: Array = []
	for row in _rows:
		texts.append(str((row as Dictionary).get("label", "")))
	_hint.text = "Z: Travel   X: Close"
	_list.set_rows(texts) # resets the cursor to row 0 (the old _entries.select(0) contract)

func _activate_selected() -> void:
	if _list.row_count() == 0 or _list.selected() >= _rows.size():
		return
	var raw: Variant = (_rows[_list.selected()] as Dictionary).get("tile", Vector2i.ZERO)
	var tile: Vector2i = raw if raw is Vector2i else Vector2i.ZERO
	var resolve := _resolve
	close_selector() # latch + avatar re-enable BEFORE the resolve press could reach the same-frame polls
	if resolve.is_valid():
		resolve.call(tile)

func _move_selection(direction: int) -> void:
	if _list.row_count() == 0:
		return
	_list.move(direction)

# The same-frame latch reach (header comment): get_tree().current_scene is the Main
# script that owns _input_router; bind_ui_consumers connects `closed` (argless) to it.
# No-op when the router is absent (non-Main hosts), leaving X/Enter still screen-safe.
func _wire_input_latch() -> void:
	var tree: SceneTree = get_tree()
	var scene_root: Node = tree.current_scene if tree != null else null
	var router: Variant = scene_root.get("_input_router") if scene_root != null else null
	if router != null and (router as Object).has_method("bind_ui_consumers"):
		(router as Object).call("bind_ui_consumers", [self])

func _on_entry_clicked(index: int, _at_position: Vector2, _mouse_button_index: int) -> void:
	_list.select(index)
	_activate_selected()
