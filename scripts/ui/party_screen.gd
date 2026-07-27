extends Control

# Party screen: d-pad list of party members; confirming opens an action menu (SWAP LEAD /
# MOVE / SUMMARY / FIELD MOVE / DEPOSIT / RETRIEVE / CANCEL); SUMMARY shows a compact stats
# panel. FIELD MOVE entries are capability display: only cut/dig/smash (and Build) act. MOVE
# reorders arbitrarily (up/down live, Z commits, X restores). DEPOSIT moves the selected
# member into the box beside the player — falling back to a breeding PEN (Phase 5) — offered
# only while one exists (refusals flash the Hint). RETRIEVE pulls the oldest campsite-held
# mon. EGGS ride the list with a pre-hatch status (no field moves, no FNT). Data: injected
# context (see start_menu.gd).

signal closed
signal field_move_requested(move_id: String)

const PartyRows := preload("res://scripts/ui/party_rows.gd")
const PartyActions := preload("res://scripts/ui/party_actions.gd")

@onready var _rows: VBoxContainer = $Panel/Margin/HBox/ListColumn/Rows
@onready var _hint: Label = $Panel/Margin/HBox/ListColumn/Hint
@onready var _action_panel: PanelContainer = $Panel/Margin/HBox/SideColumn/ActionPanel
@onready var _action_list: ItemList = $Panel/Margin/HBox/SideColumn/ActionPanel/Margin/ActionList
@onready var _summary_panel: PanelContainer = $Panel/Margin/HBox/SideColumn/SummaryPanel
@onready var _summary_text: Label = $Panel/Margin/HBox/SideColumn/SummaryPanel/Margin/SummaryText

var _context: Dictionary = {}
var _party: Array = []
var _selected := 0
var _state := "list" # list | action | summary | move
var _actions: Array = []
var _action_selected := 0
var _move_order: Array = [] # during MOVE: original party index per current slot

func _ready() -> void:
	visible = false

func setup(context: Dictionary) -> void:
	_context = context

func open_screen() -> void:
	_refresh_party()
	_selected = 0
	visible = true
	_rebuild_rows()
	_show_panel("list")

func close_screen() -> void:
	visible = false

func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("move_up"):
		_move(-1)
	elif event.is_action_pressed("move_down"):
		_move(1)
	elif event.is_action_pressed("action_a"):
		_confirm()
	elif event.is_action_pressed("action_b"):
		_back()
	else:
		return
	get_viewport().set_input_as_handled()

func _move(direction: int) -> void:
	if _state == "action":
		if not _actions.is_empty():
			_action_selected = wrapi(_action_selected + direction, 0, _actions.size())
			_action_list.select(_action_selected)
			_action_list.ensure_current_is_visible()
	elif _state == "move":
		var target := PartyActions.move_target_index(_selected, direction, _party.size())
		if target >= 0 and target != _selected:
			_call_context("move_party_member", [_selected, target])
			var original: int = _move_order[_selected]
			_move_order.remove_at(_selected)
			_move_order.insert(target, original)
			_selected = target
			_rebuild()
	elif _state == "list" and not _party.is_empty():
		_selected = wrapi(_selected + direction, 0, _party.size())
		for i in range(_rows.get_child_count()):
			var row := _rows.get_child(i) as HBoxContainer
			if row != null:
				PartyRows.set_selected(row, i == _selected)

func _confirm() -> void:
	match _state:
		"list":
			_open_actions()
		"action":
			_activate_action()
		"move":
			_move_order = [] # commit: the live order IS the party order now
			_show_panel("list")
		"summary":
			_show_panel("action")

func _back() -> void:
	match _state:
		"list":
			close_screen()
			closed.emit()
		"action":
			_show_panel("list")
		"move": # cancel: restore the pre-MOVE order, then drop the tracking
			_call_context("set_party_order", [PartyActions.inverse_permutation(_move_order)])
			_move_order = []
			_rebuild()
			_show_panel("list")
		"summary":
			_show_panel("action")

func _show_panel(mode: String) -> void:
	_state = mode
	_action_panel.visible = mode == "action"
	_summary_panel.visible = mode == "summary"
	match mode:
		"list":
			_hint.text = "Z: Actions   X: Back"
		"action":
			_hint.text = "Z: Confirm   X: Back"
		"move":
			_hint.text = "Up/Down: Move   Z: Confirm   X: Cancel"
		"summary":
			_hint.text = "Z/X: Back"

func _refresh_party() -> void:
	var snapshot: Variant = _call_context("get_party_snapshot")
	_party = snapshot if snapshot is Array else []
	_selected = clampi(_selected, 0, maxi(0, _party.size() - 1))

func _rebuild() -> void:
	_refresh_party()
	_rebuild_rows()

func _rebuild_rows() -> void:
	for child in _rows.get_children():
		_rows.remove_child(child)
		child.queue_free()
	if _party.is_empty():
		var empty_label := Label.new()
		empty_label.text = "No Pokemon yet."
		_rows.add_child(empty_label)
		return
	for i in range(_party.size()):
		_rows.add_child(PartyRows.build_row(_party[i], i == _selected))

func _open_actions() -> void:
	if _party.is_empty():
		return
	var held: Variant = _call_context("get_campsite_pokemon")
	var player_tile: Variant = _call_context("get_player_tile")
	var box: Variant = _call_context("box_tile_near", [player_tile]) if player_tile is Vector2i else {}
	var pen: Variant = _call_context("pen_tile_near", [player_tile]) if player_tile is Vector2i else {} # Phase 5: DEPOSIT falls back to a pen
	var has_box: bool = (box is Dictionary and bool((box as Dictionary).get("found", false))) or (pen is Dictionary and bool((pen as Dictionary).get("found", false)))
	_actions = PartyActions.build_action_entries(_party[_selected], _eligible_field_moves(_party[_selected]),
		_context.get("get_field_move_name", Callable()), held if held is Array else [],
		_party.size(), has_box)
	_action_list.clear()
	for action in _actions:
		_action_list.add_item(str(action.get("label", "?")))
	_action_selected = 0
	_action_list.select(0)
	_show_panel("action")

func _activate_action() -> void:
	if _action_selected < 0 or _action_selected >= _actions.size():
		return
	var action: Dictionary = _actions[_action_selected]
	match str(action.get("id", "")):
		"swap":
			_call_context("set_party_lead", [_selected])
			_rebuild()
			_show_panel("list")
		"move":
			_move_order = range(_party.size()) # party == display order at entry
			_show_panel("move")
		"summary":
			_summary_text.text = PartyRows.summary_text(_party[_selected],
				_context.get("get_species", Callable()), _context.get("experience_for_level", Callable()))
			_show_panel("summary")
		"field_move":
			close_screen()
			field_move_requested.emit(str(action.get("move_id", "")))
		"deposit":
			var result: Variant = _call_context("deposit_to_nearest", [_selected])
			if result is Dictionary and bool((result as Dictionary).get("ok", false)):
				_rebuild()
				_show_panel("list")
			else: # refusals (last member, witness guard, no box) flash the Hint
				_hint.text = str((result as Dictionary).get("message", "That can't be done.")) if result is Dictionary else "That can't be done."
		"retrieve":
			_call_context("retrieve_campsite_mon", [0])
			_rebuild()
			_show_panel("list")
		_:
			_show_panel("list")

func _eligible_field_moves(mon: Dictionary) -> Array:
	var move_ids: Array = []
	if bool(mon.get("is_egg", false)): # eggs perform no field moves
		return move_ids
	var get_species: Callable = _context.get("get_species", Callable())
	if not get_species.is_valid():
		return move_ids
	var species: Variant = get_species.call(str(mon.get("species_id", "")))
	var flags: Variant = (species as Dictionary).get("field_moves", {}) if species is Dictionary else {}
	if flags is not Dictionary:
		return move_ids
	for id_variant in (flags as Dictionary).keys(): # flag==1: the mon is capable
		if int((flags as Dictionary)[id_variant]) == 1:
			move_ids.append(str(id_variant))
	move_ids.sort()
	return move_ids

func _call_context(key: String, args: Array = []) -> Variant:
	var accessor: Callable = _context.get(key, Callable())
	if not accessor.is_valid():
		return null
	return accessor.callv(args)
