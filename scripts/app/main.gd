extends Node2D

const GameRuntimePath := "/root/GameRuntime"
const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")
const CryPlayer := preload("res://scripts/runtime/cry_player.gd")
const InputRouter := preload("res://scripts/app/input_router.gd")
const FieldActionRouter := preload("res://scripts/app/field_action_router.gd")
const StructureLayer := preload("res://scripts/runtime/structure_layer.gd")
const MainSmokeContext := preload("res://scripts/app/main_smoke_context.gd")

@onready var _world = $World
@onready var _player = $Player
@onready var _message_box = $UI/MessageBox
@onready var _battle_view = $UI/BattleView
@onready var _start_menu = $UI/StartMenu
@onready var _smoke_scenarios = $SmokeScenarios

var _smoke_runner = SmokeScenarioRunner.new()
var _cry_player = CryPlayer.new()
var _field_router = FieldActionRouter.new()
var _input_router = InputRouter.new(Callable(self, "_toggle_menu"), Callable(self, "_on_context_action"), Callable(_field_router, "toggle_build_mode"))
var _structure_layer = StructureLayer.new()
var _in_battle = false
var _menu_open = false
var _suppress_close_toast = false
var _battle_enemy_dex := 0

func _ready() -> void:
	_input_router.configure_input_map(); _input_router.bind_ui_consumers([$UI/CampMenu, _start_menu, _message_box, $UI/StorageScreen, $UI/TitleScreen, $UI/CreationScreen])
	_runtime().emit_trace("boot_started", "App.Main", {"scene": "res://scenes/app/Main.tscn"})
	var smoke_scenario = _smoke_runner.consume_requested_scenario() # consumed BEFORE ensure_initialized (title_flow boot split): scenario presence IS the silent-new-game flag
	_runtime().ensure_initialized(not smoke_scenario.is_empty())
	# Registered next to the music router so its player enters the tree.
	_cry_player.setup(_runtime().trace)
	_runtime().add_child(_cry_player)

	_start_menu.setup({
		"get_species": Callable(_runtime().catalog, "get_species"),
		"get_item": Callable(_runtime().catalog, "get_item"),
		"get_field_move_name": Callable(_runtime().catalog, "get_field_move_name"),
		"experience_for_level": Callable(_runtime().pokemon_rules, "experience_for_level")
	})
	_player.setup(_world)
	# Build mode: y-sort-enabled sibling of World/Player so the ghost joins the prop/player depth chain.
	_structure_layer.name = "StructureLayer"
	add_child(_structure_layer)
	_structure_layer.setup(_runtime(), _world, _player, Callable(_message_box, "show_message"))
	_structure_layer.build_finished.connect(Callable(_field_router, "on_build_finished"))
	_field_router.setup(_runtime(), _world, _player, _structure_layer, Callable(_message_box, "show_message"), $UI/CampMenu, $UI/StorageScreen)
	_connect_signals()
	if not smoke_scenario.is_empty(): # SCENARIO BOOT: today's path exactly — world sync + toast at boot, dispatch below
		_sync_world_from_runtime()
		_message_box.show_message("Port in progress: Explore, battle, catch, and save with Enter.", 4.0)
	_runtime().emit_trace("boot_ready", "App.Main", {"player_tile": _tile_payload(_player.tile_position)})
	if not smoke_scenario.is_empty():
		_smoke_scenarios.call_deferred("run", smoke_scenario, MainSmokeContext.build(self))
	else: # PLAYER BOOT: no world sync/toast/save here — the title flow owns the screen until _enter_world
		_player.input_enabled = false
		$UI/TitleScreen.begin_boot(_runtime().has_loaded_save())


func _process(_delta: float) -> void:
	var free: bool = not _in_battle and not _menu_open and not _player.is_moving() and not $UI/StorageScreen.visible and not $UI/TitleScreen.visible and not $UI/CreationScreen.visible and not $UI/WayStoneSelector.visible
	_input_router.poll(free, free and not _structure_layer.is_active())


func _on_player_tile_changed(tile_position: Vector2i) -> void:
	_world.sync_visible(tile_position)
	_runtime().set_player_tile(tile_position)
	_runtime().note_player_step()
	if _runtime().get_player_tile() != tile_position: _sync_world_from_runtime(); _runtime().save_game(); return # a dungeon warp re-homed the player mid-step: re-anchor + rebuild on the canonical _sync path (the waystone-warp precedent)
	_world.set_time_of_day(_runtime().get_time_of_day_minutes())
	if not _in_battle: _play_biome_music() # contact battles start inside note_player_step; do not stomp the battle theme
	_runtime().save_game()


func _on_player_blocked(reason: String, tile: Vector2i) -> void:
	if _in_battle or _menu_open:
		return
	_message_box.show_message(reason if not reason.is_empty() else "Can't move there.", 0.8) # infinite-world slice: no world edge; the traversal_blocked trace below keeps the pinned raw reason
	var field_move = _world.tile_requires_field_move(tile) if _world != null else ""
	_runtime().emit_trace("traversal_blocked", "App.Main", {"tile": _tile_payload(tile),
		"reason": reason, "requires_field_move": field_move})


func _on_encounter_requested(tile_position: Vector2i) -> void:
	if _in_battle or _menu_open:
		return
	var biome = _world.get_tile_biome(tile_position)
	var wild_mon = _runtime().generate_wild_encounter(tile_position, biome)
	if wild_mon.is_empty():
		_runtime().warn("App.Main", "Wild encounter came back empty; battle skipped.", {"biome": biome})
		return
	_in_battle = true
	_player.input_enabled = false
	_message_box.hide_message()
	_music_router().play_battle_track(str(wild_mon.get("battle_kind", "wild"))) # Build 2: a legendary static's pending payload sets "legendary" (music_router.gd:33); default "wild"
	_battle_enemy_dex = _dex_for_species(str(wild_mon.get("species_id", "")))
	_cry_player.play_cry(_battle_enemy_dex)
	_battle_view.start_wild_battle(wild_mon)


func _on_battle_finished(outcome: String, message: String) -> void:
	_in_battle = false; _input_router.note_press_consumed() # battle-end press must not re-fire the same-frame overworld polls (input_router's latch)
	_player.input_enabled = true
	_sync_world_from_runtime()

	match outcome:
		"victory":
			_cry_player.play_cry(_battle_enemy_dex)
			_message_box.show_message(message, 1.6)
		"caught", "caught_box_full":
			_message_box.show_message(message, 2.4)
		"escaped":
			_message_box.show_message(message, 1.2)
		"defeat":
			_cry_player.play_cry(_party_lead_dex())
			_message_box.show_message(message + " You were returned to the start.", 2.4)
		_:
			_message_box.show_message(message, 1.8)


func _toggle_menu() -> void:
	if _in_battle or _structure_layer.is_active() or $UI/CampMenu.visible or $UI/StorageScreen.visible or $UI/TitleScreen.visible or $UI/CreationScreen.visible:
		return
	_menu_open = not _menu_open
	_player.input_enabled = not _menu_open
	if _menu_open:
		_start_menu.show_menu()
		_runtime().emit_trace("menu_opened", "App.Main", {})
	else:
		_start_menu.hide_menu()


func _on_menu_closed() -> void:
	_menu_open = false
	_player.input_enabled = not ($UI/WayStoneSelector.visible if has_node("UI/WayStoneSelector") else false) # a modal way-stone selector owns the avatar until its closed latch (field_move_actions._on_selector_closed); the menu close must not clobber it (the _toggle_menu :119 UI-visibility precedent)
	_runtime().save_game()
	_runtime().emit_trace("menu_closed", "App.Main", {})
	if _suppress_close_toast:
		_suppress_close_toast = false
	else:
		_message_box.show_message("Saved.", 0.8)


# Party-screen FIELD MOVE: the router consumes move_id (Build -> build mode).
func _on_field_move_requested(move_id: String, mon_index: int = -1) -> void:
	_suppress_close_toast = _menu_open
	_field_router.on_field_move_requested(move_id, mon_index)


func _on_context_action() -> void:
	_field_router.on_context_action()


func _on_game_reset() -> void:
	_sync_world_from_runtime(); _player.set_avatar(_runtime().session.player_avatar) # SAME-LINE avatar re-apply: identity persists across the pinned pause-menu reset (the encounter_settings precedent)
	_message_box.show_message("New game started.", 1.4)


func _sync_world_from_runtime() -> void:
	_player.set_tile_position(_runtime().get_player_tile())
	_world.rebuild(_runtime().get_world_seed())
	_world.sync_visible(_player.tile_position)
	_world.set_time_of_day(_runtime().get_time_of_day_minutes())
	_play_biome_music()
	_runtime().emit_trace("world_rebuilt", "App.Main", {"world_seed": _runtime().get_world_seed(),
		"center_tile": _tile_payload(_player.tile_position)})

func _connect_signals() -> void:
	_player.tile_changed.connect(_on_player_tile_changed)
	_player.encounter_requested.connect(_on_encounter_requested)
	_player.blocked.connect(_on_player_blocked)
	_battle_view.battle_finished.connect(_on_battle_finished)
	_start_menu.closed.connect(_on_menu_closed)
	_start_menu.game_reset.connect(_on_game_reset)
	_start_menu.field_move_requested.connect(_on_field_move_requested)
	$UI/TitleScreen.continue_chosen.connect(_enter_world)
	$UI/CreationScreen.creation_confirmed.connect(_on_creation_confirmed)
	$UI/TitleScreen.new_game_chosen.connect($UI/CreationScreen.open_screen) # direct signal->method: creation opens straight from the title, no handler
	$UI/CreationScreen.cancelled.connect($UI/TitleScreen.show_title) # direct signal->method: SEED-step X returns to the title
	_runtime().dungeon_runtime.message_requested.connect(Callable(_message_box, "show_message")) # the Regigigas seal refusal surfaces on the step that triggers it


# Title-flow entrypoints: CONTINUE and the confirmed creation both land in _enter_world.
func _enter_world() -> void: _player.set_avatar(_runtime().session.player_avatar); _sync_world_from_runtime(); _player.input_enabled = true

func _on_creation_confirmed(creation: Dictionary) -> void:
	_runtime().begin_created_game(creation); _enter_world()


func _runtime() -> Node: return get_node(GameRuntimePath)


func _music_router() -> Node: return _runtime().music_router


func _dex_for_species(species_id: String) -> int:
	return int(_runtime().catalog.get_species(species_id).get("dex_number", 0))


func _party_lead_dex() -> int:
	var party: Array = _runtime().get_party_snapshot()
	if party.is_empty():
		return 0
	return _dex_for_species(str(party[0].get("species_id", "")))


# Re-requests the biome track at the player's tile. The router no-ops when that
# track is already playing, so per-step calls only switch on biome changes.
func _play_biome_music() -> void:
	_music_router().play_biome_track(_world.get_tile_biome(_player.tile_position))


func _tile_payload(tile_position: Vector2i) -> Array:
	return [tile_position.x, tile_position.y]

func _smoke_set_battle(active: bool) -> void:
	_in_battle = active
	_player.input_enabled = not active
