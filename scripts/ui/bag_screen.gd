extends Control

# Bag screen: item list with the highlighted item's description. POTION opens
# a party picker and heals the chosen member; the SLEEPING BAG rests the party
# through camping_runtime (Phase 2 camping seam); anything else reports that it
# cannot be used here. Data comes from the injected context (see start_menu.gd).

signal closed

const PartyRows := preload("res://scripts/ui/party_rows.gd")

const POTION_ITEM_ID := "potion"
const POTION_HEAL_AMOUNT := 20
# Phase 2 camping slice (spec: camping-crafting-survival.md): a REUSABLE key item
# (never consumed) — its Z entry routes to camping_runtime.rest("bag").
const SLEEPING_BAG_ITEM_ID := "sleeping_bag"
const STATE_ITEMS := "items"
const STATE_PARTY_PICK := "party_pick"

@onready var _items: ItemList = $Panel/Margin/VBox/Body/Items
@onready var _description: Label = $Panel/Margin/VBox/Body/SideColumn/Description
@onready var _party_panel: PanelContainer = $Panel/Margin/VBox/Body/SideColumn/PartyPanel
@onready var _party_rows: VBoxContainer = $Panel/Margin/VBox/Body/SideColumn/PartyPanel/Margin/VBox/PartyRows
@onready var _hint: Label = $Panel/Margin/VBox/Hint
@onready var _message_box = $MessageBox

var _context: Dictionary = {}
var _entries: Array = []
var _party: Array = []
var _selected := 0
var _party_selected := 0
var _state := STATE_ITEMS

func _ready() -> void:
	visible = false

func setup(context: Dictionary) -> void:
	_context = context

func open_screen() -> void:
	_state = STATE_ITEMS
	_party_panel.visible = false
	visible = true
	_refresh_items()
	if _entries.is_empty():
		_message_box.show_message("The bag is empty.", 1.6)
	_update_hint()

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
	if _state == STATE_PARTY_PICK:
		if not _party.is_empty():
			_party_selected = wrapi(_party_selected + direction, 0, _party.size())
			_update_party_markers()
	elif not _entries.is_empty():
		_selected = wrapi(_selected + direction, 0, _entries.size())
		_items.select(_selected)
		_items.ensure_current_is_visible()
		_update_description()

func _confirm() -> void:
	if _state == STATE_PARTY_PICK:
		_apply_potion()
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
	_items.clear()
	for entry_variant in _entries:
		if entry_variant is Dictionary:
			var entry: Dictionary = entry_variant
			_items.add_item("%s x%d" % [_item_display_name(str(entry.get("item_id", ""))), int(entry.get("count", 0))])
	_selected = clampi(_selected, 0, maxi(0, _entries.size() - 1))
	if not _entries.is_empty():
		_items.select(_selected)
		_items.ensure_current_is_visible()
	_update_description()

func _activate_item() -> void:
	if _entries.is_empty() or _selected >= _entries.size():
		return
	var item_id := str((_entries[_selected] as Dictionary).get("item_id", ""))
	if item_id == POTION_ITEM_ID:
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
	_party_panel.visible = true
	_rebuild_party_rows()
	_update_hint()

func _close_party_pick() -> void:
	_state = STATE_ITEMS
	_party_panel.visible = false
	_update_hint()

func _apply_potion() -> void:
	if _party.is_empty() or _party_selected >= _party.size():
		return
	var mon: Dictionary = (_party[_party_selected] as Dictionary).duplicate(true)
	var max_hp := maxi(1, int(mon.get("max_hp", 1)))
	var current_hp := int(mon.get("current_hp", 0))
	if current_hp >= max_hp:
		_message_box.show_message("It would have no effect.", 1.4)
		return
	mon["current_hp"] = mini(max_hp, current_hp + POTION_HEAL_AMOUNT)
	_call_context("set_party_member", [_party_selected, mon])
	_call_context("remove_item", [POTION_ITEM_ID, 1])
	_message_box.show_message("Used Potion on %s." % str(mon.get("name", "Pokemon")), 1.6)
	_close_party_pick()
	_refresh_items()

# Sleeping bag (Phase 2 camping slice; spec: camping-crafting-survival.md): a
# reusable key item, so the count never decrements. camping_runtime.rest("bag")
# owns the heal, the time advance and the campsite trail — the SAME semantics as
# the faced-bed path field_action_router routes; the screen only surfaces the
# message, resyncs the world tint to the advanced clock, and saves. Self-wires
# through the /root/GameRuntime autoload (camp_menu's convention).
func _use_sleeping_bag() -> void:
	var runtime := get_node_or_null("/root/GameRuntime")
	var camping: Variant = runtime.get("camping_runtime") if runtime != null else null
	if camping == null or not camping.has_method("rest"):
		_message_box.show_message("Can't use that here.", 1.4)
		return
	var result: Variant = camping.call("rest", "bag")
	var response: Dictionary = result if result is Dictionary else {}
	var text := str(response.get("message", ""))
	_message_box.show_message(text if not text.is_empty() else "You rested for a while.", 2.2)
	if bool(response.get("ok", false)) and runtime != null:
		var world := get_node_or_null("/root/Main/World")
		if world != null and world.has_method("set_time_of_day"):
			world.set_time_of_day(int(runtime.get_time_of_day_minutes()))
		runtime.save_game()

func _rebuild_party_rows() -> void:
	for child in _party_rows.get_children():
		_party_rows.remove_child(child)
		child.queue_free()
	for i in range(_party.size()):
		_party_rows.add_child(PartyRows.build_row(_party[i], i == _party_selected))

func _update_party_markers() -> void:
	for i in range(_party_rows.get_child_count()):
		var row := _party_rows.get_child(i) as HBoxContainer
		if row != null:
			PartyRows.set_selected(row, i == _party_selected)

func _item_display_name(item_id: String) -> String:
	var display_name := str(_catalog_item(item_id).get("display_name", ""))
	if not display_name.is_empty():
		return display_name.capitalize()
	return item_id.capitalize()


func _catalog_item(item_id: String) -> Dictionary:
	var accessor: Callable = _context.get("get_item", Callable())
	if not accessor.is_valid():
		return {}
	var item: Variant = accessor.call(item_id.strip_edges().to_lower())
	return item if item is Dictionary else {}


func _update_description() -> void:
	_description.text = ""
	if _entries.is_empty() or _selected >= _entries.size():
		return
	var item_id := str((_entries[_selected] as Dictionary).get("item_id", ""))
	_description.text = str(_catalog_item(item_id).get("description", ""))

func _update_hint() -> void:
	_hint.text = "Z: Heal   X: Back" if _state == STATE_PARTY_PICK else "Z: Use   X: Back"

func _call_context(key: String, args: Array = []) -> Variant:
	var accessor: Callable = _context.get(key, Callable())
	if not accessor.is_valid():
		return null
	return accessor.callv(args)
