extends Control

# Storage Box screen (Phase 3; spec: docs/product-specs/storage-and-party.md),
# restyled onto the GBC stage idiom (restyle slice wave 2): an opaque 160x144
# stage (gbc_stage.gd), gsc background art, and white plates — box/party title
# plates, two two-line-entry columns (">" marker on the cursor row), detail +
# hint plates, the actions popup plate, and the summary overlay plate (all
# composed in storage_screen_stage.gd). Behavior is unchanged: two columns —
# the opened box's mons and the party (n/6) — with per-side actions (box
# WITHDRAW / RELEASE / SUMMARY / CANCEL, party DEPOSIT / SUMMARY / CANCEL). The
# box is INDEPENDENT per placement (the ONE box at `_tile`, never a shared
# store). RELEASE is permanent and confirm-gated through the MessageBox sibling
# (the New Game precedent): while a confirm is pending this screen releases Z/X
# to the box owning the answer and gates action-list clicks too (a mid-confirm
# click used to withdraw, letting the confirm release a DIFFERENT mon).
# Self-wires through /root/GameRuntime (camp_menu precedent); ui imports only ui.

signal closed

const GbcStage := preload("res://scripts/ui/gbc_stage.gd")
const MenuList := preload("res://scripts/ui/menu_list_stage.gd")
const PartyRows := preload("res://scripts/ui/party_rows.gd")
const StorageStage := preload("res://scripts/ui/storage_screen_stage.gd")
const HINTS := {"browse": "Z: Actions   Left/Right: Side   X: Close",
	"actions": "Z: Confirm   X: Back", "summary": "Z/X: Back"}

var _runtime: Node = null
var _tile := Vector2i.ZERO
var _side := "box" # box | party — the column the cursor lives in
var _box_index := 0; var _party_index := 0
var _box: Array = []; var _party: Array = []
var _state := "browse" # browse | actions | summary
var _actions: Array = []; var _action_selected := 0
var _summary_mon: Dictionary = {}
var _awaiting_confirm := false; var _confirm_index := 0
var _stage: Control
var _display: TextureRect
var _box_title: Label
var _party_title: Label
var _box_column: StorageStage.Column
var _party_column: StorageStage.Column
var _action_plate: Control
var _action_rows: MenuList.Rows
var _summary_plate: Control
var _summary_text: Label
var _detail: Label
var _hint: Label

func _ready() -> void:
	visible = false
	var parts := GbcStage.build(self) # opaque black backing + 160x144 stage + integer-scaled display
	_stage = parts.stage
	_display = parts.display
	GbcStage.on_resized(self, _display)
	var built := StorageStage.build(_stage)
	_box_title = built.box_title; _party_title = built.party_title
	_box_column = built.box_column; _party_column = built.party_column
	_action_plate = built.action_plate; _action_rows = built.action_rows
	_summary_plate = built.summary_plate; _summary_text = built.summary_label
	_detail = built.detail_label; _hint = built.hint_label
	var confirm_box := get_node_or_null("../MessageBox")
	if confirm_box != null and confirm_box.has_signal("confirmed"):
		confirm_box.connect("confirmed", StorageStage.on_release_confirmed.bind(self))
		confirm_box.connect("cancelled", StorageStage.on_release_cancelled.bind(self))

# Opens the box at `tile` (app layer disables the avatar first — campfire-menu
# pattern); open_box traces box_opened; closing emits `closed` (router saves).
func open_screen(tile: Vector2i) -> void:
	_runtime = get_node_or_null("/root/GameRuntime")
	_tile = tile
	_side = "box"
	_box_index = 0; _party_index = 0
	_detail.text = ""
	var storage: Variant = _storage()
	if storage != null:
		storage.open_box(tile)
	StorageStage.refresh(self)
	visible = true
	_show_state("browse")
func close_screen() -> void:
	if not visible:
		return
	visible = false; closed.emit()

# --- Scenario/lead seams (the old ActionList ItemList reads; clicks hit-test these) ---
func stage_root() -> Control: return _stage
func row_texts() -> Array: return _action_rows.row_texts()
func selected_row_text() -> String: return _action_rows.row_text(_action_rows.selected())
func select_row(index: int) -> void:
	_action_rows.select(index)
	_action_selected = _action_rows.selected()
func row_count() -> int: return _action_rows.row_count()
func row_rect(index: int) -> Rect2: return _action_rows.row_rect(index) # stage-local

func _unhandled_input(event: InputEvent) -> void:
	if not visible or _awaiting_confirm: # a pending confirm owns Z/X on MessageBox
		return
	if event.is_action_pressed("move_up"):
		_navigate(-1)
	elif event.is_action_pressed("move_down"):
		_navigate(1)
	elif event.is_action_pressed("move_left") or event.is_action_pressed("move_right"):
		_switch_side()
	elif event.is_action_pressed("action_a"):
		_confirm()
	elif event.is_action_pressed("action_b"):
		_back()
	else:
		return
	get_viewport().set_input_as_handled()

# Click convenience (the old ActionList item_clicked route) via the stage-inverse
# hit test; only the action rows were ever clickable, so only they are hit-tested.
func _gui_input(event: InputEvent) -> void:
	if not visible or not (event is InputEventMouseButton):
		return
	var button := event as InputEventMouseButton
	if button.pressed and button.button_index == MOUSE_BUTTON_LEFT:
		var hit := MenuList.hit_row(_display, button.position, _action_rows)
		if hit >= 0:
			_on_entry_clicked(hit, button.position, MOUSE_BUTTON_LEFT)
			accept_event()

func _navigate(direction: int) -> void:
	if _state == "actions" and not _actions.is_empty():
		_action_selected = wrapi(_action_selected + direction, 0, _actions.size())
		_action_rows.select(_action_selected)
	elif _state == "browse" and (_box.size() if _side == "box" else _party.size()) > 0:
		if _side == "box":
			_box_index = wrapi(_box_index + direction, 0, _box.size())
		else:
			_party_index = wrapi(_party_index + direction, 0, _party.size())
		StorageStage.rebuild_rows(self)
func _switch_side() -> void: # left/right swaps the cursor's column
	if _state != "browse":
		return
	_side = "party" if _side == "box" else "box"
	StorageStage.rebuild_rows(self)
func _confirm() -> void:
	match _state:
		"browse":
			_open_actions()
		"actions":
			_activate_action()
		"summary":
			_show_state("actions")
func _back() -> void:
	match _state:
		"browse":
			close_screen()
		"actions":
			_show_state("browse")
		"summary":
			_show_state("actions")
func _show_state(mode: String) -> void:
	_state = mode
	_action_plate.visible = mode == "actions"
	_summary_plate.visible = mode == "summary"
	_hint.text = str(HINTS.get(mode, ""))
func _open_actions() -> void:
	if (_side == "box" and _box.is_empty()) or (_side == "party" and _party.is_empty()):
		_detail.text = "The box is empty." if _side == "box" else "No Pokemon in the party."
		return
	_actions = [{"id": "withdraw", "label": "WITHDRAW"}, {"id": "release", "label": "RELEASE"}, {"id": "summary", "label": "SUMMARY"}, {"id": "cancel", "label": "CANCEL"}] \
		if _side == "box" else [{"id": "deposit", "label": "DEPOSIT"}, {"id": "summary", "label": "SUMMARY"}, {"id": "cancel", "label": "CANCEL"}]
	var texts: Array = []
	for action in _actions:
		texts.append(str(action.get("label", "?")))
	_action_rows.set_rows(texts) # resets the action cursor to row 0
	_action_selected = 0
	_detail.text = ""
	_show_state("actions")
func _activate_action() -> void:
	if _action_selected < 0 or _action_selected >= _actions.size():
		return
	var storage: Variant = _storage()
	match str(_actions[_action_selected].get("id", "")):
		"withdraw":
			_apply(storage.withdraw(_tile, _box_index) if storage != null else {})
		"deposit":
			_apply(storage.deposit(_tile, _party_index) if storage != null else {})
		"release":
			StorageStage.begin_release_confirm(self)
		"summary":
			_summary_mon = _active_mon()
			_summary_text.text = PartyRows.summary_text(_summary_mon, StorageStage.rules_accessor(_runtime, "get_species"), StorageStage.rules_accessor(_runtime, "experience_for_level"))
			_show_state("summary")
		_:
			_show_state("browse")
func _apply(result: Variant) -> void: # ok -> refresh; message always to Detail
	var response: Dictionary = result if result is Dictionary else {}
	_detail.text = str(response.get("message", "That can't be done."))
	if bool(response.get("ok", false)):
		if _runtime != null:
			_runtime.save_game()
		StorageStage.refresh(self)
		_show_state("browse")

# RELEASE confirm trio + _refresh/_rebuild_rows live in storage_screen_stage.gd
# (bound/static calls; the 220-wall extraction) — the gate, the _awaiting_confirm
# member, and the title/row strings stay byte-identical.
func _active_mon() -> Dictionary:
	if _side == "box":
		return _box[_box_index] if _box_index >= 0 and _box_index < _box.size() else {}
	return _party[_party_index] if _party_index >= 0 and _party_index < _party.size() else {}
func _storage() -> Variant:
	return _runtime.get("storage_runtime") if _runtime != null else null
func _on_entry_clicked(index: int, _at_position: Vector2, _mouse_button_index: int) -> void:
	if _awaiting_confirm: return # a pending RELEASE confirm owns the list; a click must not mutate the box (0.2)
	_action_rows.select(index)
	_action_selected = index
	_activate_action()
