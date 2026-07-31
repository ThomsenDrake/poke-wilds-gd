extends Control

# Phase 7 Build 3 — the multi-beacon SELECTOR (world-depth.md § Teleport Beacons (1);
# fresh-faq.md:178-192: "you can select one of the Beacons to be Teleported to it").
# Closes the last-registered-only divergence: a registration-ordered list of the ACTIVE
# world's edge-band way-stones. The screen is DUMB by layer contract (ui may not import
# domain per check_architecture): the opener (field_move_actions) supplies the rows off
# world_chain_runtime.beacon_tiles() — already registration-ordered, so the list order
# IS the deterministic order — plus a resolve Callable that warps + saves; this screen
# only lists, navigates, and reports the chosen tile. Z chooses, X/Enter cancels.
#
# WIRING: the argless `closed` signal is input_router's latch contract (a Z-select /
# X-close this frame must not also fire Main's menu-toggle / context polls). main.gd's
# bind_ui_consumers array is frozen AT its 220 budget, so the screen SELF-WIRES the
# latch — the documented reach into the scene script's _input_router (mirrors the
# field_action_router._toggle_campfire documented-reach precedent); bind_ui_consumers
# is idempotent, so the boot-time attempt + the open-time heal never double-connect.

signal closed

const COLOR_ROW := Color(0.9, 0.92, 0.96, 1.0)

@onready var _title: Label = $MenuPanel/Margin/VBox/Title
@onready var _entries: ItemList = $MenuPanel/Margin/VBox/Entries
@onready var _hint: Label = $MenuPanel/Margin/VBox/Hint

var _rows: Array = [] # [{"label": String, "tile": Vector2i}] in registration order
var _resolve: Callable = Callable() # opener-supplied: resolve.call(chosen_tile)

func _ready() -> void:
	visible = false
	_entries.item_clicked.connect(_on_entry_clicked)
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

func _refresh() -> void:
	_entries.clear()
	for row in _rows:
		_entries.add_item(str((row as Dictionary).get("label", "")))
		_entries.set_item_custom_fg_color(_entries.item_count - 1, COLOR_ROW)
	_hint.text = "Z: Travel   X: Close"
	if _entries.item_count > 0:
		_entries.select(0)

func _activate_selected() -> void:
	var selected := _entries.get_selected_items()
	if selected.is_empty() or int(selected[0]) >= _rows.size():
		return
	var raw: Variant = (_rows[int(selected[0])] as Dictionary).get("tile", Vector2i.ZERO)
	var tile: Vector2i = raw if raw is Vector2i else Vector2i.ZERO
	var resolve := _resolve
	close_selector() # latch + avatar re-enable BEFORE the resolve press could reach the same-frame polls
	if resolve.is_valid():
		resolve.call(tile)

func _move_selection(direction: int) -> void:
	if _entries.item_count == 0:
		return
	var selected := _entries.get_selected_items()
	_entries.select(wrapi((int(selected[0]) if not selected.is_empty() else 0) + direction, 0, _entries.item_count))
	_entries.ensure_current_is_visible()

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
	_entries.select(index)
	_activate_selected()
