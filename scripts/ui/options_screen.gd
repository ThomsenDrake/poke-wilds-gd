extends Control

# Options screen (title-screen submenu; spec: docs/product-specs/menu-and-save.md +
# overworld-pokemon.md). Configures the random-encounter OPT-IN. The session is the single
# source (get/set_encounter_settings); every change persists at once via save_game. Three
# rows: WILD ENCOUNTERS (Z / ←/→ cycles OFF -> CLASSIC -> ANYWHERE), ENCOUNTER RATE (←/→
# nudges the per-step chance along the pinned 0.02 ladder, greyed while encounters are OFF),
# and BACK. The default OFF means wild battles come ONLY from a shared-tile sprite collision
# (overworld-pokemon.md); the session stores OFF as {} so a never-touched save keeps its exact
# byte shape. Self-wires through the /root/GameRuntime autoload (the camp_menu convention);
# the mode/rate constants ride SessionState (ui -> runtime is layer-legal), single-sourced.

const SessionState := preload("res://scripts/runtime/session_state.gd")

signal closed

const ENTRY_MODE := "mode"
const ENTRY_RATE := "rate"
const ENTRY_BACK := "back"
const COLOR_OK := Color(0.9, 0.92, 0.96, 1.0)
const COLOR_DIM := Color(0.58, 0.58, 0.64, 1.0)
const MODE_LABELS := {"off": "OFF (contact only)", "classic": "CLASSIC (encounter tiles)", "anywhere": "ANYWHERE (any tile)"}
const MODE_DETAIL := "OFF: battles only when you bump a wild Pokémon. CLASSIC: a per-step roll on tall-grass / encounter tiles. ANYWHERE: that roll on any tile you can stand on."
const RATE_DETAIL := "The chance per step that a random wild battle starts (only while encounters are on)."

@onready var _title: Label = $MenuPanel/Margin/VBox/Title
@onready var _entries: ItemList = $MenuPanel/Margin/VBox/Entries
@onready var _detail: Label = $MenuPanel/Margin/VBox/Detail
@onready var _hint: Label = $MenuPanel/Margin/VBox/Hint

var _runtime: Node = null
var _rows: Array = []
var _mode_index := 0 # index into SessionState.ENCOUNTER_MODES
var _rate_index := 0 # index along the MIN..MAX ladder (STEP apart)

func _ready() -> void:
	visible = false
	_entries.item_clicked.connect(_on_entry_clicked)
	_wire_input_latch() # an Enter/X close must set the same-frame latch, or poll_menu_toggle re-fires and shuts the whole StartMenu

# The same-frame latch reach (the WayStoneSelector precedent): this screen is a StartMenu child,
# NOT in main.gd's frozen bind_ui_consumers array, so it self-wires `closed` (argless — the
# latch contract) to the scene's _input_router. No-op when the router is absent (non-Main host).
func _wire_input_latch() -> void:
	var tree: SceneTree = get_tree()
	var scene_root: Node = tree.current_scene if tree != null else null
	var router: Variant = scene_root.get("_input_router") if scene_root != null else null
	if router != null and (router as Object).has_method("bind_ui_consumers"):
		(router as Object).call("bind_ui_consumers", [self])

func open_screen() -> void:
	_runtime = get_node_or_null("/root/GameRuntime")
	_load_settings()
	_title.text = "OPTIONS"
	_refresh()
	visible = true

func close_screen() -> void:
	if not visible:
		return
	if _runtime != null:
		_runtime.save_game() # persist ONCE on close (not per nudge — scrubbing the rate would otherwise write a full save per 2% step)
	visible = false
	closed.emit()

func _load_settings() -> void:
	var settings: Dictionary = _session_settings()
	_mode_index = maxi(0, SessionState.ENCOUNTER_MODES.find(str(settings.get("mode", "off"))))
	_rate_index = clampi(int(round((float(settings.get("rate", SessionState.ENCOUNTER_RATE_DEFAULT)) - SessionState.ENCOUNTER_RATE_MIN) / SessionState.ENCOUNTER_RATE_STEP)), 0, _rate_steps() - 1)

func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("move_up"):
		_move_selection(-1)
	elif event.is_action_pressed("move_down"):
		_move_selection(1)
	elif event.is_action_pressed("move_left"):
		_nudge(-1)
	elif event.is_action_pressed("move_right"):
		_nudge(1)
	elif event.is_action_pressed("action_a"):
		_activate_selected()
	elif event.is_action_pressed("action_b") or event.is_action_pressed("start"):
		close_screen()
	else:
		return
	get_viewport().set_input_as_handled()

func _refresh() -> void:
	var sel := _selected_index() # capture BEFORE clear(): ItemList.clear() drops the selection, and rebuilding would snap the cursor to row 0 (breaking repeated rate nudges)
	_rows.clear()
	_entries.clear()
	var mode := _mode_str()
	_add_row(ENTRY_MODE, "WILD ENCOUNTERS — %s" % str(MODE_LABELS.get(mode, mode)), true)
	_add_row(ENTRY_RATE, "ENCOUNTER RATE — %d%%" % _rate_pct(), mode != "off")
	_add_row(ENTRY_BACK, "BACK", true)
	_hint.text = "Z: Change   Left/Right: Adjust   X: Back"
	_entries.select(clampi(sel, 0, _entries.item_count - 1))
	_update_detail()

func _add_row(kind: String, label: String, enabled: bool) -> void:
	_rows.append({"kind": kind})
	_entries.add_item(label)
	_entries.set_item_custom_fg_color(_entries.item_count - 1, COLOR_OK if enabled else COLOR_DIM)

func _nudge(direction: int) -> void:
	var kind := _selected_kind()
	if kind == ENTRY_MODE:
		_mode_index = wrapi(_mode_index + direction, 0, SessionState.ENCOUNTER_MODES.size())
		_apply()
	elif kind == ENTRY_RATE and _mode_str() != "off":
		_rate_index = clampi(_rate_index + direction, 0, _rate_steps() - 1)
		_apply()

func _activate_selected() -> void:
	match _selected_kind():
		ENTRY_MODE:
			_mode_index = wrapi(_mode_index + 1, 0, SessionState.ENCOUNTER_MODES.size())
			_apply()
		ENTRY_RATE:
			_nudge(1)
		ENTRY_BACK:
			close_screen()

# Session is the single source; write-through on every change (the setting takes effect at
# once), persisted by the single save on close_screen. set_encounter_settings validates +
# snaps the rate, and stores OFF as {} (canonical).
func _apply() -> void:
	var session = _runtime.get("session") if _runtime != null else null
	if session == null:
		return
	session.set_encounter_settings(_mode_str(), _rate_value())
	_refresh()

func _move_selection(direction: int) -> void:
	if _entries.item_count == 0:
		return
	_entries.select(wrapi(_selected_index() + direction, 0, _entries.item_count))
	_entries.ensure_current_is_visible()
	_update_detail()

func _update_detail() -> void:
	match _selected_kind():
		ENTRY_MODE: _detail.text = MODE_DETAIL
		ENTRY_RATE: _detail.text = RATE_DETAIL
		_: _detail.text = "Return to the menu."

func _on_entry_clicked(index: int, _at_position: Vector2, _mouse_button_index: int) -> void:
	_entries.select(index)
	_activate_selected()

func _session_settings() -> Dictionary:
	var session = _runtime.get("session") if _runtime != null else null
	return session.get_encounter_settings() if session != null else {"mode": "off", "rate": SessionState.ENCOUNTER_RATE_DEFAULT}

func _mode_str() -> String: return str(SessionState.ENCOUNTER_MODES[_mode_index])
func _rate_value() -> float: return SessionState.ENCOUNTER_RATE_MIN + float(_rate_index) * SessionState.ENCOUNTER_RATE_STEP
func _rate_pct() -> int: return int(round(_rate_value() * 100.0))
func _rate_steps() -> int: return int(round((SessionState.ENCOUNTER_RATE_MAX - SessionState.ENCOUNTER_RATE_MIN) / SessionState.ENCOUNTER_RATE_STEP)) + 1

func _selected_index() -> int:
	var selected := _entries.get_selected_items()
	return int(selected[0]) if not selected.is_empty() else 0

func _selected_kind() -> String:
	var index := _selected_index()
	return str((_rows[index] as Dictionary).get("kind", "")) if index < _rows.size() else ""
