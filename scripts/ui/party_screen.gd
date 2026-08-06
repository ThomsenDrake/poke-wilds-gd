extends Control

# Party screen on the GBC stage idiom (restyle slice wave 2): opaque black
# backing + the native 160x144 SubViewport stage (gbc_stage.gd), integer-scaled
# NEAREST, gsc/background1.png art under white plates (party_screen_stage.gd).
# The LIST plate holds ≤6 two-line party rows (party_rows.gd keeps the
# layout_audit HBoxContainer contract: child0 ">" marker, child1 name Label);
# confirming pops the GSC-idiom action plate (bottom-anchored, dynamic height —
# a literal left/right two-plate layout cannot hold fonts.ttf@7's worst rows:
# name 116px + the 128px "RETRIEVE:" label exceed the 160px stage); SUMMARY is
# a modal plate. Behavior unchanged: d-pad list; MOVE reorders live (Z commits,
# X restores); DEPOSIT/RETRIEVE; FIELD MOVE display; eggs pre-hatch status.
# Action open/dispatch: party_action_dispatch.gd (the 220-wall extraction).
# Scenario seams: stage_root(), row_texts(), selected_row_text(), select_row(i),
# row_count(), row_rect(i), action_row_text(i); rows at stage_root()/ListPlate/Rows.

signal closed
signal field_move_requested(move_id: String)

const PartyRows := preload("res://scripts/ui/party_rows.gd")
const PartyActions := preload("res://scripts/ui/party_actions.gd")
const GbcStage := preload("res://scripts/ui/gbc_stage.gd")
const PartyStage := preload("res://scripts/ui/party_screen_stage.gd")
const ActionDispatch := preload("res://scripts/ui/party_action_dispatch.gd")

var _stage: Control
var _rows: VBoxContainer
var _hint: Label
var _summary_plate: Control
var _summary_text: Label
var _action_plate: Control = null
var _action_rows = null # the GbcWidgets.RowList while the action plate is up

var _context: Dictionary = {}
var _party: Array = []
var _selected := 0
var _state := "list" # list | action | summary | move
var _actions: Array = []
var _action_selected := 0
var _move_order: Array = [] # during MOVE: original party index per current slot

func _ready() -> void:
	visible = false
	var parts := GbcStage.build(self) # {viewport, stage, display, backing}
	_stage = parts.stage
	GbcStage.on_resized(self, parts.display)
	var built := PartyStage.build(_stage)
	_rows = built.rows
	_hint = built.hint
	_summary_plate = built.summary_plate
	_summary_text = built.summary_text

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

# --- Scenario seams (restyle design §2; replaces the old Panel/Rows node reads) ---
func stage_root() -> Control: return _stage
func row_count() -> int: return _party.size()

func row_texts() -> Array:
	var texts: Array = []
	for row in _rows.get_children():
		if row is HBoxContainer and row.get_child_count() > 1:
			texts.append((row.get_child(1) as Label).text)
	return texts

func selected_row_text() -> String:
	var texts := row_texts()
	return str(texts[_selected]) if _selected >= 0 and _selected < texts.size() else ""

func select_row(index: int) -> void:
	if _party.is_empty():
		return
	_selected = wrapi(index, 0, _party.size())
	PartyRows.refresh_markers(_rows, _selected)

func row_rect(index: int) -> Rect2: # stage-local (SubViewport canvas coords)
	if index < 0 or index >= _rows.get_child_count():
		return Rect2()
	return (_rows.get_child(index) as Control).get_global_rect()

func action_row_text(index: int) -> String:
	return str((_actions[index] as Dictionary).get("label", "?")) if index >= 0 and index < _actions.size() else ""

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
			_action_rows.select(_action_selected)
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
		PartyRows.refresh_markers(_rows, _selected)

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
	if mode != "action":
		_free_action_plate()
	elif _action_plate == null:
		_build_action_plate()
	_summary_plate.visible = mode == "summary"
	match mode:
		"list":
			_hint.text = "Z: Actions   X: Back"
		"action":
			_hint.text = "Z: Confirm   X: Back"
		"move": # shortened: the old "Up/Down: Move..." string is 220px at fonts.ttf@7; the stage is 160px
			_hint.text = "Z: Confirm   X: Cancel"
		"summary":
			_hint.text = "Z/X: Back"

func _build_action_plate() -> void:
	var labels: Array = []
	for action in _actions:
		labels.append(str(action.get("label", "?")))
	var built := PartyStage.build_actions(_stage, labels)
	_action_plate = built.plate
	_action_rows = built.rows
	_action_rows.select(_action_selected)

func _free_action_plate() -> void:
	if _action_plate != null:
		_action_plate.queue_free()
		_action_plate = null
	if _action_rows != null:
		_action_rows.root().queue_free()
		_action_rows = null

func _refresh_party() -> void:
	var snapshot: Variant = _call_context("get_party_snapshot")
	_party = snapshot if snapshot is Array else []
	_selected = clampi(_selected, 0, maxi(0, _party.size() - 1))

func _rebuild() -> void:
	_refresh_party()
	_rebuild_rows()

func _rebuild_rows() -> void:
	PartyRows.rebuild(_rows, _party, _selected)

func _open_actions() -> void:
	ActionDispatch.open_actions(self)

func _activate_action() -> void:
	ActionDispatch.activate(self)

func _call_context(key: String, args: Array = []) -> Variant:
	var accessor: Callable = _context.get(key, Callable())
	if not accessor.is_valid():
		return null
	return accessor.callv(args)
