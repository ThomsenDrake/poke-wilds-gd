extends Node2D

const GameRuntimePath := "/root/GameRuntime"
const MusicRouter := preload("res://scripts/runtime/music_router.gd")
const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")

@onready var _world = $World
@onready var _player = $Player
@onready var _message_box = $UI/MessageBox
@onready var _battle_view = $UI/BattleView
@onready var _start_menu = $UI/StartMenu
@onready var _music_player: AudioStreamPlayer = $MusicPlayer

var _music_router = MusicRouter.new()
var _smoke_runner = SmokeScenarioRunner.new()
var _in_battle = false
var _menu_open = false


func _ready() -> void:
	_configure_input_map()
	_runtime().emit_trace("boot_started", "App.Main", {"scene": "res://scenes/app/Main.tscn"})
	_runtime().ensure_initialized()

	_music_router.bind(_music_player)
	_player.setup(_world)
	_connect_signals()
	_sync_world_from_runtime()
	_music_router.play_overworld()
	_message_box.show_message("Port in progress: Explore, battle, catch, and save with Enter.", 4.0)
	_runtime().emit_trace("boot_ready", "App.Main", {"player_tile": _tile_payload(_player.tile_position)})

	var smoke_scenario = _smoke_runner.consume_requested_scenario()
	if not smoke_scenario.is_empty():
		call_deferred("_run_smoke_scenario", smoke_scenario)


func _process(_delta: float) -> void:
	if Input.is_action_just_pressed("start"):
		_toggle_menu()


func _on_player_tile_changed(tile_position: Vector2i) -> void:
	_world.sync_visible(tile_position)
	_runtime().set_player_tile(tile_position)
	_runtime().save_game()


func _on_player_blocked(_step_direction: Vector2i) -> void:
	if _in_battle or _menu_open:
		return
	_message_box.show_message("Can't move there.", 0.8)


func _on_encounter_requested(tile_position: Vector2i) -> void:
	if _in_battle or _menu_open:
		return
	var wild_mon = _runtime().generate_wild_encounter(tile_position)
	if wild_mon.is_empty():
		return
	_in_battle = true
	_player.input_enabled = false
	_music_router.play_battle()
	_battle_view.start_wild_battle(wild_mon)


func _on_battle_finished(outcome: String, message: String) -> void:
	_in_battle = false
	_player.input_enabled = true
	_music_router.play_overworld()
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
	_message_box.show_message("Saved.", 0.8)


func _on_game_reset() -> void:
	_sync_world_from_runtime()
	_message_box.show_message("New game started.", 1.4)


func _sync_world_from_runtime() -> void:
	_player.set_tile_position(_runtime().get_player_tile())
	_world.rebuild(_runtime().get_world_seed())
	_world.sync_visible(_player.tile_position)
	_runtime().emit_trace("world_rebuilt", "App.Main", {
		"world_seed": _runtime().get_world_seed(),
		"center_tile": _tile_payload(_player.tile_position)
	})


func _run_smoke_scenario(scenario: String) -> void:
	match scenario:
		"boot":
			await get_tree().create_timer(0.4).timeout
		"overworld_step":
			await get_tree().create_timer(0.2).timeout
			var direction = _find_smoke_step_direction()
			if direction == Vector2i.ZERO:
				_runtime().warn("App.Main", "Smoke scenario could not find a safe overworld step.", {})
			elif _player.smoke_step(direction):
				await _player.tile_changed
			await get_tree().create_timer(0.2).timeout
		"menu_save":
			await get_tree().create_timer(0.2).timeout
			_toggle_menu()
			await get_tree().create_timer(0.2).timeout
			_start_menu.perform_save()
			await get_tree().create_timer(0.2).timeout
			_start_menu.hide_menu()
			await get_tree().create_timer(0.2).timeout
		"wild_battle":
			await get_tree().create_timer(0.2).timeout
			var wild_mon = _runtime().generate_wild_encounter(_player.tile_position)
			if wild_mon.is_empty():
				_runtime().warn("App.Main", "Smoke scenario could not create a wild encounter.", {})
			else:
				_in_battle = true
				_player.input_enabled = false
				_music_router.play_battle()
				_battle_view.start_wild_battle(wild_mon)
				await get_tree().create_timer(0.2).timeout
				_battle_view.run_smoke_turn()
				await get_tree().create_timer(0.2).timeout
				if _battle_view.visible:
					_battle_view.run_smoke_escape()
					await get_tree().create_timer(0.2).timeout
		_:
			_runtime().warn("App.Main", "Unknown smoke scenario requested.", {"scenario": scenario})
			await get_tree().create_timer(0.2).timeout
	get_tree().quit()


func _find_smoke_step_direction() -> Vector2i:
	for direction in [Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT, Vector2i.UP]:
		var next_tile = _player.tile_position + direction
		if _world.is_tile_walkable(next_tile) and not _world.is_encounter_tile(next_tile):
			return direction
	return Vector2i.ZERO


func _configure_input_map() -> void:
	_ensure_action("move_up", [Key.KEY_UP, Key.KEY_W])
	_ensure_action("move_down", [Key.KEY_DOWN, Key.KEY_S])
	_ensure_action("move_left", [Key.KEY_LEFT, Key.KEY_A])
	_ensure_action("move_right", [Key.KEY_RIGHT, Key.KEY_D])
	_ensure_action("action_a", [Key.KEY_Z])
	_ensure_action("action_b", [Key.KEY_X])
	_ensure_action("run", [Key.KEY_X])
	_ensure_action("start", [Key.KEY_ENTER])


func _ensure_action(action_name: StringName, keys: Array) -> void:
	if not InputMap.has_action(action_name):
		InputMap.add_action(action_name)
	var existing_events = InputMap.action_get_events(action_name)
	for keycode in keys:
		if _has_key_event(existing_events, keycode):
			continue
		var key_event = InputEventKey.new()
		key_event.physical_keycode = keycode
		InputMap.action_add_event(action_name, key_event)


func _has_key_event(events: Array, keycode: Key) -> bool:
	for event in events:
		if event is InputEventKey and event.physical_keycode == keycode:
			return true
	return false


func _connect_signals() -> void:
	_player.tile_changed.connect(_on_player_tile_changed)
	_player.encounter_requested.connect(_on_encounter_requested)
	_player.blocked.connect(_on_player_blocked)
	_battle_view.battle_finished.connect(_on_battle_finished)
	_start_menu.closed.connect(_on_menu_closed)
	_start_menu.game_reset.connect(_on_game_reset)


func _runtime() -> Node:
	return get_node(GameRuntimePath)


func _tile_payload(tile_position: Vector2i) -> Array:
	return [tile_position.x, tile_position.y]
