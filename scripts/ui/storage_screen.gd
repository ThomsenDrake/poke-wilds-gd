extends Control

# Storage Box screen (Phase 3; spec: docs/product-specs/storage-and-party.md).
# Two columns — the opened box's mons and the party (n/6) — with per-side
# actions: box WITHDRAW / RELEASE / SUMMARY / CANCEL, party DEPOSIT / SUMMARY /
# CANCEL. The box is INDEPENDENT per placement: this screen always addresses
# the ONE box at `_tile`, never a shared store. RELEASE is permanent and
# confirm-gated through the MessageBox sibling (the New Game precedent): while
# a confirm is pending this screen releases Z/X to the box owning the answer
# and gates mouse clicks on the action list too (the click route used to
# withdraw mid-confirm, letting the confirm release a DIFFERENT mon).
# Self-wires through /root/GameRuntime (camp_menu precedent); ui imports only ui.

signal closed

const PartyRows := preload("res://scripts/ui/party_rows.gd")
const HINTS := {"browse": "Z: Actions   Left/Right: Side   X: Close",
	"actions": "Z: Confirm   X: Back", "summary": "Z/X: Back"}

@onready var _box_title: Label = $Panel/Margin/HBox/BoxColumn/BoxTitle
@onready var _box_rows: VBoxContainer = $Panel/Margin/HBox/BoxColumn/BoxRows
@onready var _party_title: Label = $Panel/Margin/HBox/PartyColumn/PartyTitle
@onready var _party_rows: VBoxContainer = $Panel/Margin/HBox/PartyColumn/PartyRows
@onready var _action_panel: PanelContainer = $Panel/Margin/HBox/SideColumn/ActionPanel
@onready var _action_list: ItemList = $Panel/Margin/HBox/SideColumn/ActionPanel/Margin/ActionList
@onready var _summary_panel: PanelContainer = $Panel/Margin/HBox/SideColumn/SummaryPanel
@onready var _summary_text: Label = $Panel/Margin/HBox/SideColumn/SummaryPanel/Margin/SummaryText
@onready var _detail: Label = $Panel/Margin/HBox/SideColumn/Detail
@onready var _hint: Label = $Panel/Margin/HBox/SideColumn/Hint

var _runtime: Node = null
var _tile := Vector2i.ZERO
var _side := "box" # box | party — the column the cursor lives in
var _box_index := 0; var _party_index := 0
var _box: Array = []; var _party: Array = []
var _state := "browse" # browse | actions | summary
var _actions: Array = []; var _action_selected := 0
var _summary_mon: Dictionary = {}
var _awaiting_confirm := false; var _confirm_index := 0

func _ready() -> void:
	visible = false
	_action_list.item_clicked.connect(_on_entry_clicked)
	var confirm_box := get_node_or_null("../MessageBox")
	if confirm_box != null and confirm_box.has_signal("confirmed"):
		confirm_box.connect("confirmed", _on_release_confirmed)
		confirm_box.connect("cancelled", _on_release_cancelled)

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
	_refresh()
	visible = true
	_show_state("browse")
func close_screen() -> void:
	if not visible:
		return
	visible = false; closed.emit()
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
func _navigate(direction: int) -> void:
	if _state == "actions" and not _actions.is_empty():
		_action_selected = wrapi(_action_selected + direction, 0, _actions.size())
		_action_list.select(_action_selected)
		_action_list.ensure_current_is_visible()
	elif _state == "browse" and (_box.size() if _side == "box" else _party.size()) > 0:
		if _side == "box":
			_box_index = wrapi(_box_index + direction, 0, _box.size())
		else:
			_party_index = wrapi(_party_index + direction, 0, _party.size())
		_rebuild_rows()
func _switch_side() -> void: # left/right swaps the cursor's column
	if _state != "browse":
		return
	_side = "party" if _side == "box" else "box"
	_rebuild_rows()
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
	_action_panel.visible = mode == "actions"
	_summary_panel.visible = mode == "summary"
	_hint.text = str(HINTS.get(mode, ""))
func _open_actions() -> void:
	if (_side == "box" and _box.is_empty()) or (_side == "party" and _party.is_empty()):
		_detail.text = "The box is empty." if _side == "box" else "No Pokemon in the party."
		return
	_actions = [{"id": "withdraw", "label": "WITHDRAW"}, {"id": "release", "label": "RELEASE"}, {"id": "summary", "label": "SUMMARY"}, {"id": "cancel", "label": "CANCEL"}] \
		if _side == "box" else [{"id": "deposit", "label": "DEPOSIT"}, {"id": "summary", "label": "SUMMARY"}, {"id": "cancel", "label": "CANCEL"}]
	_action_list.clear()
	for action in _actions:
		_action_list.add_item(str(action.get("label", "?")))
	_action_selected = 0
	_action_list.select(0)
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
			_begin_release_confirm()
		"summary":
			_summary_mon = _active_mon()
			_summary_text.text = PartyRows.summary_text(_summary_mon, _rules_accessor("get_species"), _rules_accessor("experience_for_level"))
			_show_state("summary")
		_:
			_show_state("browse")
func _apply(result: Variant) -> void: # ok -> refresh; message always to Detail
	var response: Dictionary = result if result is Dictionary else {}
	_detail.text = str(response.get("message", "That can't be done."))
	if bool(response.get("ok", false)):
		if _runtime != null:
			_runtime.save_game()
		_refresh()
		_show_state("browse")

# RELEASE is permanent (no overworld-mon drop until Phase 6 — documented
# deviation), so the wording double-emphasizes permanence before the confirm.
func _begin_release_confirm() -> void:
	var confirm_box := get_node_or_null("../MessageBox")
	if confirm_box == null or not confirm_box.has_method("show_confirm"):
		_detail.text = "The confirm box is missing; release was refused."
		return
	_confirm_index = _box_index
	_awaiting_confirm = true
	confirm_box.call("show_confirm", "Release %s? It will be gone for good." % str(_active_mon().get("name", "this Pokemon")))
func _on_release_confirmed() -> void:
	# The MessageBox confirmed signal is SHARED (the StartMenu's NEW GAME confirm
	# rides it too): a confirm this screen did not open releases nothing.
	if not _awaiting_confirm:
		return
	_awaiting_confirm = false
	var storage: Variant = _storage()
	_apply(storage.release_from_box(_tile, _confirm_index) if storage != null else {})
func _on_release_cancelled() -> void: _awaiting_confirm = false # the spec's cancel branch: back to the actions
func _refresh() -> void:
	var storage: Variant = _storage()
	_box = storage.box_snapshot(_tile) if storage != null else []
	var session: Variant = _runtime.get("session") if _runtime != null else null
	var snapshot: Variant = session.get_party_snapshot() if session != null else []
	_party = snapshot if snapshot is Array else []
	_box_index = clampi(_box_index, 0, maxi(0, _box.size() - 1)); _party_index = clampi(_party_index, 0, maxi(0, _party.size() - 1))
	_box_title.text = "STORAGE BOX %d" % _box.size()
	_party_title.text = "PARTY %d/6" % _party.size()
	_rebuild_rows()
func _rebuild_rows() -> void:
	_fill_column(_box_rows, _box, _box_index if _side == "box" else -1, "Empty.")
	_fill_column(_party_rows, _party, _party_index if _side == "party" else -1, "No Pokemon yet.")
func _fill_column(column: VBoxContainer, entries: Array, selected: int, empty_text: String) -> void:
	for child in column.get_children():
		column.remove_child(child)
		child.queue_free()
	if entries.is_empty():
		var empty_label := Label.new()
		empty_label.text = empty_text
		column.add_child(empty_label)
		return
	for i in range(entries.size()):
		column.add_child(PartyRows.build_row(entries[i], i == selected))
func _active_mon() -> Dictionary:
	if _side == "box":
		return _box[_box_index] if _box_index >= 0 and _box_index < _box.size() else {}
	return _party[_party_index] if _party_index >= 0 and _party_index < _party.size() else {}
func _storage() -> Variant:
	return _runtime.get("storage_runtime") if _runtime != null else null

# Summary accessors: catalog species + rules exp curve; invalid callables
# degrade PartyRows.summary_text gracefully (party-screen precedent).
func _rules_accessor(method: String) -> Callable:
	if _runtime == null:
		return Callable()
	var target: Variant = _runtime.catalog if method == "get_species" else _runtime.pokemon_rules
	return Callable(target, method) if target is Object and (target as Object).has_method(method) else Callable()
func _on_entry_clicked(index: int, _at_position: Vector2, _mouse_button_index: int) -> void:
	if _awaiting_confirm: return # a pending RELEASE confirm owns the list; a click must not mutate the box (0.2)
	_action_list.select(index)
	_action_selected = index
	_activate_action()
