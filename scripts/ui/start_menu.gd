extends Control

# Start menu loop: entry list (POKEMON, BAG, SAVE, NEW GAME, CLOSE) hosting the
# party and bag screens as child scenes. Menu-level trace events stay in
# main.gd (menu_opened/menu_closed) and GameRuntime (save_written).
#
# Injected context: main.gd may call setup() with a Dictionary of Callables.
# Keys backed by the runtime fall back to /root/GameRuntime automatically:
#   get_party_snapshot() -> Array       get_bag_snapshot() -> Array
#   get_party_member(i) -> Dictionary   set_party_member(i, mon)
#   remove_item(item_id, count) -> bool set_party_lead(index)
#   save_game() / new_game()
# Keys with no fallback (screens degrade gracefully when absent):
#   get_species(species_id) -> Dictionary  -> hides FIELD MOVE actions + EXP line
#   get_item(item_id) -> Dictionary        -> bag falls back to raw item ids
#   get_field_move_name(move_id) -> String -> field moves show their raw slug
#   experience_for_level(level, growth) -> int -> summary omits the EXP line
#
# field_move_requested carries the move id plus the party index of the mon the
# player picked; main.gd resolves the action through the harvest resolver.

signal closed
signal game_reset
signal field_move_requested(move_id: String, mon_index: int)

const RUNTIME_METHODS := {
	"get_party_snapshot": "get_party_snapshot",
	"set_party_lead": "set_party_lead",
	"save_game": "save_game",
	"new_game": "new_game",
}

const SESSION_METHODS := {
	"get_bag_snapshot": "get_bag_snapshot",
	"get_party_member": "get_party_member",
	"set_party_member": "set_party_member",
	"remove_item": "remove_item",
}

const ENTRIES: PackedStringArray = ["POKEMON", "BAG", "SAVE", "NEW GAME", "CLOSE"]
const ENTRY_POKEMON := 0
const ENTRY_BAG := 1
const ENTRY_SAVE := 2
const ENTRY_NEW_GAME := 3
const ENTRY_CLOSE := 4

@onready var _dim: ColorRect = $Dim
@onready var _menu_panel: PanelContainer = $MenuPanel
@onready var _entries: ItemList = $MenuPanel/Margin/VBox/Entries
@onready var _party_screen = $PartyScreen
@onready var _bag_screen = $BagScreen

var _raw_context: Dictionary = {}
var _context: Dictionary = {}


func _ready() -> void:
	visible = false
	for entry in ENTRIES:
		_entries.add_item(entry)
	_entries.item_clicked.connect(_on_entry_clicked)
	_entries.select(0)
	_party_screen.closed.connect(_on_submenu_closed)
	_bag_screen.closed.connect(_on_submenu_closed)
	_party_screen.field_move_requested.connect(_on_field_move_requested)
	setup(_raw_context)


func setup(context: Dictionary) -> void:
	_raw_context = context.duplicate()
	_context = _resolve_context(_raw_context)
	if is_node_ready():
		_party_screen.setup(_context)
		_bag_screen.setup(_context)


func show_menu() -> void:
	visible = true
	_dim.visible = true
	_menu_panel.visible = true
	_party_screen.close_screen()
	_bag_screen.close_screen()
	_entries.select(0)
	_entries.ensure_current_is_visible()


func hide_menu() -> void:
	if not visible:
		return
	_party_screen.close_screen()
	_bag_screen.close_screen()
	visible = false
	closed.emit()


func perform_save() -> void:
	_call_context("save_game")


func _unhandled_input(event: InputEvent) -> void:
	if not visible or _submenu_open():
		return
	if event.is_action_pressed("move_up"):
		_move_selection(-1)
	elif event.is_action_pressed("move_down"):
		_move_selection(1)
	elif event.is_action_pressed("action_a"):
		_activate_entry(_selected_entry())
	elif event.is_action_pressed("action_b"):
		hide_menu()
	else:
		return
	get_viewport().set_input_as_handled()


func _activate_entry(index: int) -> void:
	match index:
		ENTRY_POKEMON:
			_open_submenu(_party_screen)
		ENTRY_BAG:
			_open_submenu(_bag_screen)
		ENTRY_SAVE:
			perform_save()
		ENTRY_NEW_GAME:
			_call_context("new_game")
			game_reset.emit()
		ENTRY_CLOSE:
			hide_menu()


# Submenus draw their own full-rect dim; hiding ours avoids a doubled overlay.
func _open_submenu(screen: Control) -> void:
	_dim.visible = false
	_menu_panel.visible = false
	screen.open_screen()


func _on_submenu_closed() -> void:
	if visible:
		_dim.visible = true
		_menu_panel.visible = true


# The party screen's own signal carries only the move id, so the selected
# party index is read back from the screen (party_screen.gd is not part of
# this workstream; its _selected holds the row the player confirmed on).
func _on_field_move_requested(move_id: String) -> void:
	field_move_requested.emit(move_id, int(_party_screen.get("_selected")))
	hide_menu()


func _move_selection(direction: int) -> void:
	var next := wrapi(_selected_entry() + direction, 0, ENTRIES.size())
	_entries.select(next)
	_entries.ensure_current_is_visible()


func _selected_entry() -> int:
	var selected := _entries.get_selected_items()
	return int(selected[0]) if not selected.is_empty() else 0


func _submenu_open() -> bool:
	return _party_screen.visible or _bag_screen.visible


func _on_entry_clicked(index: int, _at_position: Vector2, _mouse_button_index: int) -> void:
	_entries.select(index)
	_activate_entry(index)


func _resolve_context(context: Dictionary) -> Dictionary:
	var resolved := context.duplicate()
	var runtime := _runtime()
	if runtime == null:
		return resolved
	for key in RUNTIME_METHODS:
		if not _context_accessor(resolved, key).is_valid():
			resolved[key] = _node_accessor(runtime, RUNTIME_METHODS[key])
	for key in SESSION_METHODS:
		if not _context_accessor(resolved, key).is_valid():
			resolved[key] = _node_accessor(runtime.get("session"), SESSION_METHODS[key])
	return resolved


func _context_accessor(context: Dictionary, key: String) -> Callable:
	var value: Variant = context.get(key, Callable())
	return value if value is Callable else Callable()


func _node_accessor(target: Variant, method: String) -> Callable:
	if target is Object and (target as Object).has_method(method):
		return Callable(target, method)
	return Callable()


func _call_context(key: String, args: Array = []) -> Variant:
	var accessor := _context_accessor(_context, key)
	if not accessor.is_valid():
		return null
	return accessor.callv(args)


func _runtime() -> Node:
	return get_node_or_null("/root/GameRuntime")
