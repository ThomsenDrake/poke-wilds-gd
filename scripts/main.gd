extends Node2D

@onready var _world = $World
@onready var _player = $Player
@onready var _message_box = $UI/MessageBox
@onready var _battle_view = $UI/BattleView
@onready var _start_menu = $UI/StartMenu
@onready var _music_player: AudioStreamPlayer = $MusicPlayer

var _in_battle = false
var _menu_open = false

const OVERWORLD_TRACK := "res://pokewilds/music/route_1.ogg"
const BATTLE_TRACK := "res://pokewilds/music/wild_battle.ogg"


func _ready() -> void:
	_configure_input_map()

	var state: Node = _state()
	state.call("ensure_initialized")

	_world.rebuild(int(state.get("world_seed")))
	_player.setup(_world)
	_player.set_tile_position(state.get("player_tile"))
	_world.sync_visible(_player.tile_position)

	_player.tile_changed.connect(_on_player_tile_changed)
	_player.encounter_requested.connect(_on_encounter_requested)
	_player.blocked.connect(_on_player_blocked)
	_battle_view.battle_finished.connect(_on_battle_finished)
	_start_menu.closed.connect(_on_menu_closed)
	_start_menu.game_reset.connect(_on_game_reset)

	_play_music(OVERWORLD_TRACK)
	_message_box.show_message("Port in progress: Explore, battle, catch, and save with Enter.", 4.0)


func _process(_delta: float) -> void:
	if Input.is_action_just_pressed("start"):
		_toggle_menu()


func _on_player_tile_changed(tile_position: Vector2i) -> void:
	_world.sync_visible(tile_position)
	var state: Node = _state()
	state.set("player_tile", tile_position)
	state.call("save_game")


func _on_player_blocked(_step_direction: Vector2i) -> void:
	if _in_battle or _menu_open:
		return
	_message_box.show_message("Can't move there.", 0.8)


func _on_encounter_requested(tile_position: Vector2i) -> void:
	if _in_battle or _menu_open:
		return

	var state: Node = _state()
	var wild_mon = state.call("generate_wild_encounter", tile_position)
	if wild_mon is not Dictionary or (wild_mon as Dictionary).is_empty():
		return

	_in_battle = true
	_player.input_enabled = false
	_play_music(BATTLE_TRACK)
	_battle_view.start_wild_battle(wild_mon)


func _on_battle_finished(outcome: String, message: String) -> void:
	_in_battle = false
	_player.input_enabled = true
	_play_music(OVERWORLD_TRACK)

	var state: Node = _state()
	var updated_tile: Vector2i = state.get("player_tile")
	_player.set_tile_position(updated_tile)
	_world.rebuild(int(state.get("world_seed")))
	_world.sync_visible(_player.tile_position)

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
	else:
		_start_menu.hide_menu()


func _on_menu_closed() -> void:
	_menu_open = false
	_player.input_enabled = true
	_state().call("save_game")
	_message_box.show_message("Saved.", 0.8)


func _on_game_reset() -> void:
	var state: Node = _state()
	_world.rebuild(int(state.get("world_seed")))
	_player.set_tile_position(state.get("player_tile"))
	_world.sync_visible(_player.tile_position)
	_message_box.show_message("New game started.", 1.4)


func _play_music(track_path: String) -> void:
	if not ResourceLoader.exists(track_path):
		return
	var stream: AudioStream = load(track_path)
	if stream == null:
		return
	if _music_player.stream == stream and _music_player.playing:
		return
	_music_player.stream = stream
	_music_player.play()


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


func _state() -> Node:
	return get_node("/root/GameState")
