extends Control

# Options screen (title-screen submenu; spec: docs/product-specs/menu-and-save.md +
# overworld-pokemon.md), restyled onto the GBC stage idiom (restyle slice wave 2):
# an opaque 160x144 stage (gbc_stage.gd) with the gsc background art, a white
# title plate, a three-row white plate (black ink; the greyed row is DIM ink),
# and autowrap detail/hint plates (menu_list_stage.gd composition). Behavior is
# unchanged: configures the random-encounter OPT-IN; the session is the single
# source (get/set_encounter_settings); every change persists at once via
# save_game. Three rows: WILD ENCOUNTERS (Z / ←/→ cycles OFF -> CLASSIC ->
# ANYWHERE), ENCOUNTER RATE (←/→ nudges the per-step chance along the pinned
# 0.02 ladder, greyed while encounters are OFF), and BACK. The default OFF means
# wild battles come ONLY from a shared-tile sprite collision (overworld-pokemon.md);
# the session stores OFF as {} so a never-touched save keeps its exact byte shape.
# Self-wires through the /root/GameRuntime autoload (the camp_menu convention);
# the mode/rate constants ride SessionState (ui -> runtime is layer-legal).

const SessionState := preload("res://scripts/runtime/session_state.gd")
const GbcStage := preload("res://scripts/ui/gbc_stage.gd")
const MenuList := preload("res://scripts/ui/menu_list_stage.gd")

signal closed

const ENTRY_MODE := "mode"
const ENTRY_RATE := "rate"
const ENTRY_BACK := "back"
const COLOR_OK := Color(0.9, 0.92, 0.96, 1.0) # legacy dark-theme fg, kept for API stability; enabled rows now use black ink
const COLOR_DIM := Color(0.58, 0.58, 0.64, 1.0) # the greyed-row dim ink
const MODE_LABELS := {"off": "OFF (contact only)", "classic": "CLASSIC (encounter tiles)", "anywhere": "ANYWHERE (any tile)"}
const MODE_DETAIL := "OFF: battles only when you bump a wild Pokémon. CLASSIC: a per-step roll on tall-grass / encounter tiles. ANYWHERE: that roll on any tile you can stand on."
const RATE_DETAIL := "The chance per step that a random wild battle starts (only while encounters are on)."

var _runtime: Node = null
var _rows: Array = []
var _mode_index := 0 # index into SessionState.ENCOUNTER_MODES
var _rate_index := 0 # index along the MIN..MAX ladder (STEP apart)
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
		"title": "OPTIONS", "title_rect": Rect2(48, 6, 64, 14),
		"rows_rect": Rect2(8, 24, 144, 34),
		"detail_rect": Rect2(8, 62, 144, 52),
		"hint_rect": Rect2(8, 118, 144, 22), "hint": "Z: Change   Left/Right: Adjust   X: Back"})
	_list = built.rows
	_title = built.title_label
	_detail = built.detail_label
	_hint = built.hint_label
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

# --- Scenario/lead seams (the old ItemList reads): stage + row access ---
func stage_root() -> Control: return _stage
func row_texts() -> Array: return _list.row_texts()
func selected_row_text() -> String: return _list.row_text(_list.selected())
func select_row(index: int) -> void: _list.select(index)
func row_count() -> int: return _list.row_count()
func row_rect(index: int) -> Rect2: return _list.row_rect(index) # stage-local

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
	var sel := _list.selected() if _list.row_count() > 0 else 0 # capture BEFORE set_rows(): the rebuild resets the cursor to row 0 (breaking repeated rate nudges)
	_rows.clear()
	var texts: Array = []
	var inks: Array = []
	var mode := _mode_str()
	_add_row(texts, inks, ENTRY_MODE, "WILD ENCOUNTERS — %s" % str(MODE_LABELS.get(mode, mode)), true)
	_add_row(texts, inks, ENTRY_RATE, "ENCOUNTER RATE — %d%%" % _rate_pct(), mode != "off")
	_add_row(texts, inks, ENTRY_BACK, "BACK", true)
	_hint.text = "Z: Change   Left/Right: Adjust   X: Back"
	_list.set_rows(texts, inks)
	_list.select(clampi(sel, 0, _list.row_count() - 1))
	_update_detail()

func _add_row(texts: Array, inks: Array, kind: String, label: String, enabled: bool) -> void:
	_rows.append({"kind": kind})
	texts.append(label)
	inks.append(Color.BLACK if enabled else COLOR_DIM) # greyed row = dim ink (white-plate ink rule)

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
	if _list.row_count() == 0:
		return
	_list.move(direction)
	_update_detail()

func _update_detail() -> void:
	match _selected_kind():
		ENTRY_MODE: _detail.text = MODE_DETAIL
		ENTRY_RATE: _detail.text = RATE_DETAIL
		_: _detail.text = "Return to the menu."

func _on_entry_clicked(index: int, _at_position: Vector2, _mouse_button_index: int) -> void:
	_list.select(index)
	_activate_selected()

func _session_settings() -> Dictionary:
	var session = _runtime.get("session") if _runtime != null else null
	return session.get_encounter_settings() if session != null else {"mode": "off", "rate": SessionState.ENCOUNTER_RATE_DEFAULT}

func _mode_str() -> String: return str(SessionState.ENCOUNTER_MODES[_mode_index])
func _rate_value() -> float: return SessionState.ENCOUNTER_RATE_MIN + float(_rate_index) * SessionState.ENCOUNTER_RATE_STEP
func _rate_pct() -> int: return int(round(_rate_value() * 100.0))
func _rate_steps() -> int: return int(round((SessionState.ENCOUNTER_RATE_MAX - SessionState.ENCOUNTER_RATE_MIN) / SessionState.ENCOUNTER_RATE_STEP)) + 1

func _selected_index() -> int:
	return _list.selected() if _list.row_count() > 0 else 0

func _selected_kind() -> String:
	var index := _selected_index()
	return str((_rows[index] as Dictionary).get("kind", "")) if index < _rows.size() else ""
