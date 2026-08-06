extends Control

# Start menu loop: entry list (POKEMON, BAG, SAVE, OPTIONS, NEW GAME, CLOSE) hosting
# the party, bag, and options screens as child scenes, restyled onto the GBC stage
# idiom (wave 2): opaque black backing + the 160x144 gbc_stage, menu1.png's
# right-side panel full-stage, and the six ENTRIES as a black-ink row list on a
# white plate with the black arrow cursor (stage composition: start_menu_stage.gd).
# Dim/MenuPanel survive as contentless visibility WITNESSES (kept node names; rect
# reads moved to the stage_root() seam). NEW GAME confirms through the MessageBox
# sibling (Z: Yes / X: No) before the reset; the menu closes on the reset.
# Injected context: setup() takes a Dictionary of Callables; runtime-backed keys
# fall back to /root/GameRuntime; the no-fallback keys degrade the screens
# gracefully when absent. field_move_requested carries the move id plus the picked
# mon's party index (main.gd resolves the action through the harvest resolver).

signal closed
signal game_reset
signal new_game_requested
signal field_move_requested(move_id: String, mon_index: int)

const MenuContext := preload("res://scripts/ui/menu_context.gd") # context Callable resolution, extracted at the 220 wall
const SeedPrompt := preload("res://scripts/ui/seed_prompt.gd") # NEW GAME custom-seed entry, extracted at the 220 wall
const GbcStage := preload("res://scripts/ui/gbc_stage.gd")
const StartMenuStage := preload("res://scripts/ui/start_menu_stage.gd") # stage composition + host wiring, extracted at the 220 wall

const RUNTIME_METHODS := {
	"get_party_snapshot": "get_party_snapshot", "set_party_lead": "set_party_lead", "save_game": "save_game", "new_game": "new_game",
	"get_campsite_pokemon": "get_campsite_pokemon", "retrieve_campsite_mon": "retrieve_campsite_mon",
	"deposit_to_nearest": "deposit_to_nearest", "box_tile_near": "box_tile_near", "get_player_tile": "get_player_tile", "pen_tile_near": "pen_tile_near",
}

const SESSION_METHODS := {
	"get_bag_snapshot": "get_bag_snapshot", "get_party_member": "get_party_member", "set_party_member": "set_party_member",
	"remove_item": "remove_item", "move_party_member": "move_party_member", "set_party_order": "set_party_order",
}

const ENTRIES: PackedStringArray = ["POKEMON", "BAG", "SAVE", "OPTIONS", "NEW GAME", "CLOSE"]
const ENTRY_POKEMON := 0
const ENTRY_BAG := 1
const ENTRY_SAVE := 2
const ENTRY_OPTIONS := 3
const ENTRY_NEW_GAME := 4
const ENTRY_CLOSE := 5

@onready var _party_screen = $PartyScreen
@onready var _bag_screen = $BagScreen
@onready var _options_screen = $OptionsScreen

var _dim: Control # visibility witness (the submenu show/hide coordination below)
var _menu_panel: Control # visibility witness (kept node name for app readers)
var _stage: Control
var _display: TextureRect
var _menu_card: Control # the stage group hidden while a submenu is open
var _rows # GbcWidgets.RowList over ENTRIES (black ink + black arrow cursor)
var _raw_context: Dictionary = {}
var _context: Dictionary = {}
var _awaiting_confirm := false
var _seed_prompt: Control

func _ready() -> void:
	visible = false
	var parts := GbcStage.build(self) # {viewport, stage, display, backing}
	_stage = parts.stage; _display = parts.display
	GbcStage.on_resized(self, _display)
	var built := StartMenuStage.compose(self, parts) # stage parts BEFORE the submenu children + witnesses
	_menu_card = built.card; _rows = built.rows; _dim = built.dim; _menu_panel = built.panel
	_rows.set_rows(Array(ENTRIES)) # resets the cursor to row 0 (the POKEMON start)
	_party_screen.closed.connect(_on_submenu_closed); _bag_screen.closed.connect(_on_submenu_closed); _options_screen.closed.connect(_on_submenu_closed)
	_party_screen.field_move_requested.connect(_on_field_move_requested)
	var confirm_box := get_node_or_null("../MessageBox")
	if confirm_box != null and confirm_box.has_signal("confirmed"):
		confirm_box.connect("confirmed", _on_new_game_confirmed); confirm_box.connect("cancelled", _on_new_game_cancelled)
	_seed_prompt = SeedPrompt.new(); add_child(_seed_prompt) # sceneless: built + wired here (Main.tscn stays untouched)
	_seed_prompt.seed_confirmed.connect(_on_new_game_confirmed); _seed_prompt.cancelled.connect(_on_new_game_cancelled)
	setup(_raw_context)

func setup(context: Dictionary) -> void:
	_raw_context = context.duplicate()
	_context = _resolve_context(_raw_context)
	if is_node_ready():
		_party_screen.setup(_context)
		_bag_screen.setup(_context)

func show_menu() -> void:
	visible = true
	_dim.visible = true; _menu_panel.visible = true; _menu_card.visible = true
	_party_screen.close_screen(); _bag_screen.close_screen(); _options_screen.close_screen()
	_rows.select(0)

func hide_menu() -> void:
	if not visible:
		return
	var confirm_box := get_node_or_null("../MessageBox")
	if confirm_box != null and confirm_box.call("is_confirming"):
		confirm_box.call("hide_message") # drop a pending confirm; toasts survive
	_seed_prompt.close_prompt() # a pending seed entry drops with the menu (silent: no cancelled)
	_awaiting_confirm = false
	_party_screen.close_screen(); _bag_screen.close_screen(); _options_screen.close_screen()
	visible = false
	closed.emit()

func perform_save() -> void:
	_call_context("save_game")

# --- Scenario seams (restyle design §2: the lead's app-retargets read these) ---
func stage_root() -> Control: return _stage
func row_texts() -> Array: return _rows.row_texts()
func selected_row_text() -> String: return _rows.row_text(_rows.selected())
func select_row(index: int) -> void: _rows.select(index)
func row_count() -> int: return _rows.row_count()
func row_rect(index: int) -> Rect2: return _rows.row_rect(index) # stage-local (click hit tests)

func _unhandled_input(event: InputEvent) -> void:
	# While a New Game confirm is pending this menu must not touch Z/X: it receives
	# unhandled input BEFORE the MessageBox sibling that owns the confirm answer.
	if _awaiting_confirm and not _seed_prompt.visible and (event.is_action_pressed("move_left") or event.is_action_pressed("move_right")):
		_open_seed_prompt(); get_viewport().set_input_as_handled(); return # the confirm-phase seed gesture — Z/X keep falling through to the MessageBox answer
	if not visible or _submenu_open() or _awaiting_confirm or _seed_prompt.visible:
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

# The ItemList click convenience, retargeted: root _gui_input + the stage inverse
# map (gbc_stage.stage_point) + row hit tests; handler name/signature preserved.
func _gui_input(event: InputEvent) -> void:
	if not visible or _submenu_open() or _awaiting_confirm or _seed_prompt.visible:
		return
	var click := event as InputEventMouseButton # the cast keeps .position typed (the repo's InputEventKey pattern)
	if click != null and click.pressed and click.button_index == MOUSE_BUTTON_LEFT:
		var row := StartMenuStage.row_at(_rows, _display, click.position)
		if row >= 0:
			_on_entry_clicked(row, click.position, MOUSE_BUTTON_LEFT)
			accept_event()

func _activate_entry(index: int) -> void:
	match index:
		ENTRY_POKEMON:
			_open_submenu(_party_screen)
		ENTRY_BAG:
			_open_submenu(_bag_screen)
		ENTRY_SAVE:
			perform_save()
		ENTRY_OPTIONS:
			_open_submenu(_options_screen)
		ENTRY_NEW_GAME:
			_begin_new_game_confirm()
		ENTRY_CLOSE:
			hide_menu()

# NEW GAME is destructive, so it first asks through the MessageBox sibling's
# confirm; the menu closes on confirm (main.gd resyncs the world on game_reset).
func _begin_new_game_confirm() -> void:
	var confirm_box := get_node_or_null("../MessageBox")
	if confirm_box == null or not confirm_box.has_method("show_confirm"):
		var runtime := _runtime()
		if runtime != null:
			runtime.warn("StartMenu", "Confirm box is missing; NEW GAME was refused.", {})
		return
	_awaiting_confirm = true
	new_game_requested.emit()
	confirm_box.call("show_confirm", "Start a new game? Your current save will be erased.", "←/→: custom seed")

func _open_seed_prompt() -> void: get_node("../MessageBox").call("hide_message"); _seed_prompt.open_prompt() # the confirm drops and the prompt supersedes it; _awaiting_confirm STAYS set until the prompt answers

func _on_new_game_confirmed(seed_value: int = -1) -> void:
	# The confirmed signal is SHARED (the StorageScreen's RELEASE rides it too):
	if not _awaiting_confirm: return # a confirm this menu did not open is not a reset
	_awaiting_confirm = false
	_call_context("new_game", [seed_value]) # -1 (the MessageBox Z) keeps the runtime's random draw; a SeedPrompt seed rides through
	hide_menu(); game_reset.emit()

func _on_new_game_cancelled() -> void: _awaiting_confirm = false

# Submenus draw their own full-rect dim; hiding ours avoids a doubled overlay.
func _open_submenu(screen: Control) -> void:
	_dim.visible = false; _menu_panel.visible = false; _menu_card.visible = false
	screen.open_screen()

func _on_submenu_closed() -> void:
	if visible:
		_dim.visible = true; _menu_panel.visible = true; _menu_card.visible = true

# The party screen's signal carries only the move id; the picked index is read
# back from its _selected. Emit FIRST (the field-move route may open the
# WayStoneSelector MODAL), then hide — the close never clobbers the modal.
func _on_field_move_requested(move_id: String) -> void:
	field_move_requested.emit(move_id, int(_party_screen.get("_selected")))
	hide_menu()

func _move_selection(direction: int) -> void:
	_rows.move(direction) # RowList wraps (the old wrapi over ENTRIES.size())

func _selected_entry() -> int:
	return _rows.selected() if _rows.row_count() > 0 else 0

func _submenu_open() -> bool:
	return _party_screen.visible or _bag_screen.visible or _options_screen.visible

func _on_entry_clicked(index: int, _at_position: Vector2, _mouse_button_index: int) -> void:
	_rows.select(index)
	_activate_entry(index)

func _resolve_context(context: Dictionary) -> Dictionary:
	return MenuContext.resolve(context, RUNTIME_METHODS, SESSION_METHODS, _runtime())

func _call_context(key: String, args: Array = []) -> Variant:
	return MenuContext.call_context(_context, key, args)

func _runtime() -> Node:
	return get_node_or_null("/root/GameRuntime")
