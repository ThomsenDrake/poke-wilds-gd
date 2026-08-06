extends Control

# Bag screen on the GBC stage idiom (restyle slice wave 2): opaque black
# backing + the native 160x144 SubViewport stage (gbc_stage.gd), integer-scaled
# NEAREST into the window. item_menu_gsc1.png full stage (guarded; plate
# fallback — bag_screen_stage.gd): item rows + the black arrow cursor in the
# art's list interior, description + hint in the baked bottom frame, and the
# party pick as a modal white plate. The item list WINDOWS (VISIBLE_ROWS per
# page) when the bag outgrows the frame. Behavior is unchanged: POTION heals
# and EVOLUTION STONES evolve a party-picked member (stones confirm through
# GameRuntime's use_stone_on_mon; eggs refused); SLEEPING BAG rests; the child
# MessageBox instance (same scene, already restyled) surfaces the toasts.
#
# Scenario seams (the lead's app retargets): stage_root(), and
# row_texts()/row_count()/select_row(i)/row_rect(i) over the VISIBLE window,
# selected_row_text(); the picker rows container lives at
# stage_root()/PickerPlate/Rows.

signal closed

const PartyRows := preload("res://scripts/ui/party_rows.gd")
const StoneEvolutionRuntime := preload("res://scripts/runtime/stone_evolution_runtime.gd") # STONE_ITEM_IDS single-sourced off the runtime module: routing + validation can never disagree
const GbcStage := preload("res://scripts/ui/gbc_stage.gd")
const BagStage := preload("res://scripts/ui/bag_screen_stage.gd")
const ItemUse := preload("res://scripts/ui/bag_item_use.gd")

const POTION_ITEM_ID := "potion"
const POTION_HEAL_AMOUNT := 20
# Phase 2 camping: a REUSABLE key item (never consumed); Z routes to camping_runtime.rest("bag").
const SLEEPING_BAG_ITEM_ID := "sleeping_bag"
const STATE_ITEMS := "items"
const STATE_PARTY_PICK := "party_pick"
const VISIBLE_ROWS := BagStage.VISIBLE_ROWS

@onready var _message_box = $MessageBox

var _stage: Control
var _rows # GbcWidgets.RowList over the visible item window
var _description: Label
var _hint: Label
var _picker_plate: Control
var _picker_rows: VBoxContainer

var _context: Dictionary = {}
var _entries: Array = []
var _party: Array = []
var _selected := 0
var _party_selected := 0
var _pending_item := ""
var _state := STATE_ITEMS
var _window_top := 0

func _ready() -> void:
	visible = false
	var parts := GbcStage.build(self) # {viewport, stage, display, backing}
	_stage = parts.stage
	GbcStage.on_resized(self, parts.display)
	var built := BagStage.build(_stage)
	_rows = built.rows
	_description = built.description
	_hint = built.hint
	_picker_plate = built.picker_plate
	_picker_rows = built.picker_rows

func setup(context: Dictionary) -> void:
	_context = context

func open_screen() -> void:
	_state = STATE_ITEMS
	_picker_plate.visible = false
	visible = true
	_refresh_items()
	if _entries.is_empty():
		_message_box.show_message("The bag is empty.", 1.6)
	_update_hint()

func close_screen() -> void:
	visible = false

# --- Scenario seams (restyle design §2; the old Panel/Items node reads) ---
func stage_root() -> Control: return _stage
func row_count() -> int: return _rows.row_count()
func row_texts() -> Array: return _rows.row_texts()

func selected_row_text() -> String:
	return _rows.row_text(_selected - _window_top) if not _entries.is_empty() else ""

func select_row(index: int) -> void: # a VISIBLE-row index (wraps within the page)
	if _entries.is_empty() or _rows.row_count() == 0:
		return
	_selected = _window_top + wrapi(index, 0, _rows.row_count())
	_sync_item_rows()
	_update_description()

func select_item(index: int) -> void: # an ABSOLUTE entry index (scrolls the window to it)
	if index < 0 or index >= _entries.size():
		return
	_selected = index
	_sync_item_rows()
	_update_description()

func row_rect(index: int) -> Rect2: # stage-local rect of a VISIBLE row
	if index < 0 or index >= _rows.row_count():
		return Rect2()
	return _rows.row_rect(index)

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
	if _state == STATE_PARTY_PICK:
		if not _party.is_empty():
			_party_selected = wrapi(_party_selected + direction, 0, _party.size())
			PartyRows.refresh_markers(_picker_rows, _party_selected)
	elif not _entries.is_empty():
		_selected = wrapi(_selected + direction, 0, _entries.size())
		_sync_item_rows()
		_update_description()

func _confirm() -> void:
	if _state == STATE_PARTY_PICK:
		_apply_potion() if _pending_item == POTION_ITEM_ID else _apply_stone()
	else:
		_activate_item()

func _back() -> void:
	if _state == STATE_PARTY_PICK:
		_close_party_pick()
	else:
		close_screen()
		closed.emit()

func _refresh_items() -> void:
	var snapshot: Variant = _call_context("get_bag_snapshot")
	_entries = snapshot if snapshot is Array else []
	_selected = clampi(_selected, 0, maxi(0, _entries.size() - 1))
	_sync_item_rows()
	_update_description()

# Rebuilds the visible page of item rows, following _selected with the window
# (RowList.set_rows resets the cursor; select() restores the visible index).
func _sync_item_rows() -> void:
	_window_top = clampi(_window_top, 0, maxi(0, _entries.size() - VISIBLE_ROWS))
	if _selected < _window_top:
		_window_top = _selected
	elif _selected >= _window_top + VISIBLE_ROWS:
		_window_top = _selected - VISIBLE_ROWS + 1
	var texts: Array = []
	var get_item: Callable = _context.get("get_item", Callable())
	for i in range(_window_top, mini(_window_top + VISIBLE_ROWS, _entries.size())):
		texts.append(BagStage.row_text(_entries[i], get_item))
	_rows.set_rows(texts)
	if not _entries.is_empty():
		_rows.select(_selected - _window_top)

func _activate_item() -> void:
	if _entries.is_empty() or _selected >= _entries.size():
		return
	var item_id := str((_entries[_selected] as Dictionary).get("item_id", ""))
	if item_id == POTION_ITEM_ID or StoneEvolutionRuntime.STONE_ITEM_IDS.has(item_id):
		_pending_item = item_id
		_open_party_pick()
	elif item_id == SLEEPING_BAG_ITEM_ID:
		_use_sleeping_bag()
	else:
		_message_box.show_message("Can't use that here.", 1.4)

func _open_party_pick() -> void:
	var snapshot: Variant = _call_context("get_party_snapshot")
	_party = snapshot if snapshot is Array else []
	if _party.is_empty():
		_message_box.show_message("No Pokemon to use it on.", 1.4)
		return
	_party_selected = 0
	_state = STATE_PARTY_PICK
	_picker_plate.visible = true
	PartyRows.rebuild(_picker_rows, _party, _party_selected)
	_update_hint()

func _close_party_pick() -> void:
	_state = STATE_ITEMS
	_picker_plate.visible = false
	_update_hint()

func _apply_potion() -> void:
	ItemUse.apply_potion(self)

func _apply_stone() -> void:
	ItemUse.apply_stone(self)

func _use_sleeping_bag() -> void:
	ItemUse.use_sleeping_bag(self)

func _update_description() -> void:
	_description.text = ""
	if _entries.is_empty() or _selected >= _entries.size():
		return
	var item_id := str((_entries[_selected] as Dictionary).get("item_id", ""))
	_description.text = BagStage.item_description(item_id, _context.get("get_item", Callable()))

func _update_hint() -> void:
	_hint.text = "Z: Heal   X: Back" if _state == STATE_PARTY_PICK and _pending_item == POTION_ITEM_ID else "Z: Use   X: Back"

func _call_context(key: String, args: Array = []) -> Variant:
	var accessor: Callable = _context.get(key, Callable())
	if not accessor.is_valid():
		return null
	return accessor.callv(args)
