extends Node2D

const GameRuntimePath := "/root/GameRuntime"
const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")
const InputRouter := preload("res://scripts/app/input_router.gd")

@onready var _world = $World
@onready var _player = $Player
@onready var _message_box = $UI/MessageBox
@onready var _battle_view = $UI/BattleView
@onready var _start_menu = $UI/StartMenu
@onready var _smoke_scenarios = $SmokeScenarios

var _smoke_runner = SmokeScenarioRunner.new()
var _input_router = InputRouter.new(Callable(self, "_toggle_menu"))
var _in_battle = false
var _menu_open = false
var _suppress_close_toast = false

func _ready() -> void:
	_input_router.configure_input_map()
	_runtime().emit_trace("boot_started", "App.Main", {"scene": "res://scenes/app/Main.tscn"})
	_runtime().ensure_initialized()

	_start_menu.setup({
		"get_species": Callable(_runtime().catalog, "get_species"),
		"get_item": Callable(_runtime().catalog, "get_item"),
		"get_field_move_name": Callable(_runtime().catalog, "get_field_move_name"),
		"experience_for_level": Callable(_runtime().pokemon_rules, "experience_for_level")
	})
	_player.setup(_world)
	_connect_signals()
	_sync_world_from_runtime()
	_message_box.show_message("Port in progress: Explore, battle, catch, and save with Enter.", 4.0)
	_runtime().emit_trace("boot_ready", "App.Main", {"player_tile": _tile_payload(_player.tile_position)})

	var smoke_scenario = _smoke_runner.consume_requested_scenario()
	if not smoke_scenario.is_empty():
		_smoke_scenarios.call_deferred("run", smoke_scenario, smoke_context())


func _process(_delta: float) -> void:
	_input_router.poll_menu_toggle()


func _on_player_tile_changed(tile_position: Vector2i) -> void:
	_world.sync_visible(tile_position)
	_runtime().set_player_tile(tile_position)
	_runtime().note_player_step()
	_world.set_time_of_day(_runtime().get_time_of_day_minutes())
	_play_biome_music()
	_runtime().save_game()


func _on_player_blocked(reason: String, tile: Vector2i) -> void:
	if _in_battle or _menu_open:
		return
	_message_box.show_message(reason if not reason.is_empty() else "Can't move there.", 0.8)
	var field_move = _world.tile_requires_field_move(tile) if _world != null else ""
	_runtime().emit_trace("traversal_blocked", "App.Main", {
		"tile": _tile_payload(tile),
		"reason": reason,
		"requires_field_move": field_move
	})


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
	_music_router().play_battle_track("wild")
	_battle_view.start_wild_battle(wild_mon)


func _on_battle_finished(outcome: String, message: String) -> void:
	_in_battle = false
	_player.input_enabled = true
	_sync_world_from_runtime()

	match outcome:
		"victory":
			_message_box.show_message(message, 1.6)
		"caught", "caught_box_full":
			_message_box.show_message(message, 2.4)
		"escaped":
			_message_box.show_message(message, 1.2)
		"defeat":
			_message_box.show_message(message + " You were returned to the start.", 2.4)
		_:
			_message_box.show_message(message, 1.8)


func _toggle_menu() -> void:
	if _in_battle:
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
	_player.input_enabled = true
	_runtime().save_game()
	_runtime().emit_trace("menu_closed", "App.Main", {})
	if _suppress_close_toast:
		_suppress_close_toast = false
	else:
		_message_box.show_message("Saved.", 0.8)


func _on_field_move_requested(move_id: String) -> void:
	_suppress_close_toast = _menu_open
	_runtime().unlock_field_move(move_id)
	_runtime().emit_trace("field_move_used", "App.Main", {"move_id": move_id})
	_message_box.show_message("The way is clear!", 1.6)


func _on_game_reset() -> void:
	_sync_world_from_runtime()
	_message_box.show_message("New game started.", 1.4)


func _sync_world_from_runtime() -> void:
	_player.set_tile_position(_runtime().get_player_tile())
	_world.rebuild(_runtime().get_world_seed())
	_world.sync_visible(_player.tile_position)
	_world.set_time_of_day(_runtime().get_time_of_day_minutes())
	_play_biome_music()
	_runtime().emit_trace("world_rebuilt", "App.Main", {
		"world_seed": _runtime().get_world_seed(),
		"center_tile": _tile_payload(_player.tile_position)
	})

func _connect_signals() -> void:
	_player.tile_changed.connect(_on_player_tile_changed)
	_player.encounter_requested.connect(_on_encounter_requested)
	_player.blocked.connect(_on_player_blocked)
	_battle_view.battle_finished.connect(_on_battle_finished)
	_start_menu.closed.connect(_on_menu_closed)
	_start_menu.game_reset.connect(_on_game_reset)
	_start_menu.field_move_requested.connect(_on_field_move_requested)


func _runtime() -> Node:
	return get_node(GameRuntimePath)


func _music_router() -> Node:
	return _runtime().music_router


# Re-requests the biome track at the player's tile. The router no-ops when that
# track is already playing, so per-step calls only switch on biome changes.
func _play_biome_music() -> void:
	_music_router().play_biome_track(_world.get_tile_biome(_player.tile_position))


func _tile_payload(tile_position: Vector2i) -> Array:
	return [tile_position.x, tile_position.y]

func smoke_context() -> Dictionary:
	return {
		"world": _world,
		"player": _player,
		"runtime": _runtime(),
		"battle_view": _battle_view,
		"start_menu": _start_menu,
		"message_box": _message_box,
		"music_router": _music_router(),
		"toggle_menu": Callable(self, "_toggle_menu"),
		"set_battle": Callable(self, "_smoke_set_battle"),
		"field_move": Callable(self, "_on_field_move_requested")
	}


func _smoke_set_battle(active: bool) -> void:
	_in_battle = active
	_player.input_enabled = not active
