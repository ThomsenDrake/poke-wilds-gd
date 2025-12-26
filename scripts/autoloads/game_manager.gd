extends Node
## GameManager - Core game state and constants
## Manages global game state, settings, and provides game-wide utilities

# Game Constants - Display
const TILE_SIZE := 16
const BASE_VIEWPORT_WIDTH := 480   # Base game resolution (30 tiles wide)
const BASE_VIEWPORT_HEIGHT := 432  # 10:9 aspect ratio (27 tiles tall)
const VIEWPORT_TILES_X := 30       # 480 / 16
const VIEWPORT_TILES_Y := 27       # 432 / 16

# Legacy aliases (for backward compatibility)
const SCREEN_WIDTH := BASE_VIEWPORT_WIDTH
const SCREEN_HEIGHT := BASE_VIEWPORT_HEIGHT

# Camera zoom limits
const CAMERA_ZOOM_MIN := 0.5
const CAMERA_ZOOM_MAX := 2.0
const CAMERA_ZOOM_STEP := 0.25
const CAMERA_ZOOM_DEFAULT := 1.0

# Pokemon Constants
const MAX_PARTY_SIZE := 6
const MAX_PC_BOXES := 14
const MAX_BOX_SIZE := 20
const MAX_LEVEL := 100
const SHINY_ODDS := 256  # 1 in 256

# Game States
enum GameState {
	NONE,
	TITLE_SCREEN,
	OVERWORLD,
	BATTLE,
	MENU,
	DIALOG,
	CUTSCENE,
	LOADING
}

# Time of Day
enum TimeOfDay {
	MORNING,   # 4:00 - 9:59
	DAY,       # 10:00 - 17:59
	EVENING,   # 18:00 - 19:59
	NIGHT      # 20:00 - 3:59
}

# Signals
signal game_state_changed(old_state: GameState, new_state: GameState)
signal time_of_day_changed(new_time: TimeOfDay)
signal camera_zoom_changed(zoom: float)
signal aspect_ratio_changed(ratio: String)
signal fullscreen_changed(is_fullscreen: bool)

# Current State
var current_state: GameState = GameState.NONE
var previous_state: GameState = GameState.NONE
var time_of_day: TimeOfDay = TimeOfDay.DAY
var game_time_seconds: float = 0.0  # In-game time in seconds

# Player Data (will be moved to PlayerData resource later)
var player_name: String = ""
var player_money: int = 0
var player_party: Array = []  # Array of Pokemon instances
var player_pc_boxes: Array = []  # Array of arrays of Pokemon
var player_inventory: Inventory = null  # Player's bag

# World State
var current_seed: int = 0
var world_generated: bool = false

# Settings
var settings := {
	"music_volume": 1.0,
	"sfx_volume": 1.0,
	"text_speed": 1,  # 0=slow, 1=medium, 2=fast
	"battle_animations": true,
	"shiny_odds_multiplier": 1,  # For custom shiny odds
	# Display settings
	"aspect_ratio": "10:9",      # Options: "10:9", "16:9"
	"fullscreen": false,
	"window_scale": 2,           # Options: 1, 2, 3, 4
	"camera_zoom": 1.0,          # Range: 0.5 to 2.0
}


func _ready() -> void:
	# Initialize random seed
	randomize()
	current_seed = randi()
	
	# Initialize PC boxes
	for i in range(MAX_PC_BOXES):
		player_pc_boxes.append([])
	
	# Initialize inventory (starter items given after ItemDatabase is ready)
	player_inventory = Inventory.new()
	
	# Wait for ItemDatabase to be ready before giving starter items
	if ItemDatabase.is_loaded():
		player_inventory.give_starter_items()
	else:
		ItemDatabase.database_loaded.connect(_on_item_database_loaded, CONNECT_ONE_SHOT)
	
	# Apply display settings
	_apply_display_settings()
	
	print("GameManager initialized with seed: ", current_seed)
	print("Display: ", BASE_VIEWPORT_WIDTH, "x", BASE_VIEWPORT_HEIGHT, " (", VIEWPORT_TILES_X, "x", VIEWPORT_TILES_Y, " tiles)")


func _process(delta: float) -> void:
	# Update game time (1 real second = 1 in-game minute for day/night cycle)
	if current_state == GameState.OVERWORLD:
		game_time_seconds += delta * 60.0
		_update_time_of_day()


func change_state(new_state: GameState) -> void:
	if new_state == current_state:
		return
	
	previous_state = current_state
	current_state = new_state
	game_state_changed.emit(previous_state, current_state)
	print("Game state changed: ", GameState.keys()[previous_state], " -> ", GameState.keys()[current_state])


func _update_time_of_day() -> void:
	# Convert game time to hours (0-24)
	var hours := fmod(game_time_seconds / 60.0, 24.0)
	var new_time: TimeOfDay
	
	if hours >= 4.0 and hours < 10.0:
		new_time = TimeOfDay.MORNING
	elif hours >= 10.0 and hours < 18.0:
		new_time = TimeOfDay.DAY
	elif hours >= 18.0 and hours < 20.0:
		new_time = TimeOfDay.EVENING
	else:
		new_time = TimeOfDay.NIGHT
	
	if new_time != time_of_day:
		time_of_day = new_time
		time_of_day_changed.emit(time_of_day)


func set_game_time(hours: float) -> void:
	game_time_seconds = hours * 60.0
	_update_time_of_day()


func get_time_string() -> String:
	var hours := int(fmod(game_time_seconds / 60.0, 24.0))
	var minutes := int(fmod(game_time_seconds, 60.0))
	return "%02d:%02d" % [hours, minutes]


# Utility functions
func is_shiny_roll() -> bool:
	var odds: int = SHINY_ODDS / int(settings.shiny_odds_multiplier)
	return randi() % maxi(1, odds) == 0


func can_add_to_party() -> bool:
	return player_party.size() < MAX_PARTY_SIZE


func add_pokemon_to_party(pokemon) -> bool:
	if can_add_to_party():
		player_party.append(pokemon)
		return true
	return false


func add_pokemon_to_pc(pokemon, box_index: int = -1) -> bool:
	# Find first available box if not specified
	if box_index < 0:
		for i in range(player_pc_boxes.size()):
			if player_pc_boxes[i].size() < MAX_BOX_SIZE:
				box_index = i
				break
	
	if box_index < 0 or box_index >= player_pc_boxes.size():
		return false
	
	if player_pc_boxes[box_index].size() < MAX_BOX_SIZE:
		player_pc_boxes[box_index].append(pokemon)
		return true
	
	return false


func get_first_healthy_pokemon():
	for pokemon in player_party:
		if pokemon.current_hp > 0:
			return pokemon
	return null


func has_healthy_pokemon() -> bool:
	return get_first_healthy_pokemon() != null


## Get a Pokemon from a PC box
func get_pc_pokemon(box_index: int, slot_index: int) -> Pokemon:
	if box_index < 0 or box_index >= player_pc_boxes.size():
		return null
	if slot_index < 0 or slot_index >= player_pc_boxes[box_index].size():
		return null
	return player_pc_boxes[box_index][slot_index]


## Remove a Pokemon from a PC box
func remove_from_pc(box_index: int, slot_index: int) -> Pokemon:
	if box_index < 0 or box_index >= player_pc_boxes.size():
		return null
	if slot_index < 0 or slot_index >= player_pc_boxes[box_index].size():
		return null
	return player_pc_boxes[box_index].pop_at(slot_index)


## Withdraw Pokemon from PC to party
func withdraw_pokemon(box_index: int, slot_index: int) -> bool:
	if not can_add_to_party():
		return false
	
	var pokemon := remove_from_pc(box_index, slot_index)
	if pokemon == null:
		return false
	
	player_party.append(pokemon)
	return true


## Deposit Pokemon from party to PC
func deposit_pokemon(party_index: int, box_index: int = -1) -> bool:
	if party_index < 0 or party_index >= player_party.size():
		return false
	
	# Must keep at least one Pokemon in party
	if player_party.size() <= 1:
		return false
	
	# Must keep at least one healthy Pokemon
	var healthy_count := 0
	for i in range(player_party.size()):
		if i != party_index and player_party[i].can_battle():
			healthy_count += 1
	if healthy_count == 0:
		return false
	
	var pokemon: Pokemon = player_party[party_index]
	if add_pokemon_to_pc(pokemon, box_index):
		player_party.remove_at(party_index)
		return true
	return false


## Move Pokemon within PC (between boxes or slots)
func move_pc_pokemon(from_box: int, from_slot: int, to_box: int, to_slot: int) -> bool:
	if from_box < 0 or from_box >= player_pc_boxes.size():
		return false
	if to_box < 0 or to_box >= player_pc_boxes.size():
		return false
	if from_slot < 0 or from_slot >= player_pc_boxes[from_box].size():
		return false
	
	var pokemon: Pokemon = player_pc_boxes[from_box][from_slot]
	
	# If moving to an empty slot at the end
	if to_slot >= player_pc_boxes[to_box].size():
		if player_pc_boxes[to_box].size() >= MAX_BOX_SIZE:
			return false
		player_pc_boxes[from_box].remove_at(from_slot)
		player_pc_boxes[to_box].append(pokemon)
		return true
	
	# Swap with existing Pokemon
	var other: Pokemon = player_pc_boxes[to_box][to_slot]
	player_pc_boxes[to_box][to_slot] = pokemon
	player_pc_boxes[from_box][from_slot] = other
	return true


## Get count of Pokemon in a box
func get_box_count(box_index: int) -> int:
	if box_index < 0 or box_index >= player_pc_boxes.size():
		return 0
	return player_pc_boxes[box_index].size()


## Get total Pokemon in PC
func get_total_pc_pokemon() -> int:
	var total := 0
	for box in player_pc_boxes:
		total += box.size()
	return total


## Get box name (can be customized later)
func get_box_name(box_index: int) -> String:
	return "BOX " + str(box_index + 1)


# ============ Display Settings ============

func _apply_display_settings() -> void:
	"""Apply display settings from config"""
	# Apply fullscreen
	if settings.fullscreen:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		# Apply window scale (only in windowed mode)
		var scale: int = settings.window_scale
		var width := BASE_VIEWPORT_WIDTH * scale
		var height := BASE_VIEWPORT_HEIGHT * scale
		DisplayServer.window_set_size(Vector2i(width, height))
		# Center window on screen
		var screen_size := DisplayServer.screen_get_size()
		var window_pos := Vector2i(
			(screen_size.x - width) / 2,
			(screen_size.y - height) / 2
		)
		DisplayServer.window_set_position(window_pos)


func toggle_fullscreen() -> void:
	"""Toggle fullscreen mode"""
	settings.fullscreen = not settings.fullscreen
	_apply_display_settings()
	fullscreen_changed.emit(settings.fullscreen)
	print("Fullscreen: ", settings.fullscreen)


func set_fullscreen(enabled: bool) -> void:
	"""Set fullscreen mode"""
	if settings.fullscreen != enabled:
		settings.fullscreen = enabled
		_apply_display_settings()
		fullscreen_changed.emit(settings.fullscreen)


func is_fullscreen() -> bool:
	"""Check if currently fullscreen"""
	return settings.fullscreen


func set_window_scale(scale: int) -> void:
	"""Set window scale (1, 2, 3, or 4)"""
	scale = clampi(scale, 1, 4)
	if settings.window_scale != scale:
		settings.window_scale = scale
		if not settings.fullscreen:
			_apply_display_settings()


func get_window_scale() -> int:
	"""Get current window scale"""
	return settings.window_scale


func set_aspect_ratio(ratio: String) -> void:
	"""Set aspect ratio (10:9 or 16:9) - requires restart"""
	if ratio in ["10:9", "16:9"] and settings.aspect_ratio != ratio:
		settings.aspect_ratio = ratio
		aspect_ratio_changed.emit(ratio)
		print("Aspect ratio changed to: ", ratio, " (requires restart)")


func get_aspect_ratio() -> String:
	"""Get current aspect ratio setting"""
	return settings.aspect_ratio


func set_camera_zoom(zoom: float) -> void:
	"""Set camera zoom level (0.5 to 2.0)"""
	zoom = clampf(zoom, CAMERA_ZOOM_MIN, CAMERA_ZOOM_MAX)
	if not is_equal_approx(settings.camera_zoom, zoom):
		settings.camera_zoom = zoom
		camera_zoom_changed.emit(zoom)


func get_camera_zoom() -> float:
	"""Get current camera zoom level"""
	return settings.camera_zoom


func adjust_camera_zoom(delta: float) -> void:
	"""Adjust camera zoom by delta amount"""
	set_camera_zoom(settings.camera_zoom + delta)


func reset_camera_zoom() -> void:
	"""Reset camera zoom to default"""
	set_camera_zoom(CAMERA_ZOOM_DEFAULT)


func get_viewport_size() -> Vector2i:
	"""Get current viewport size based on aspect ratio"""
	if settings.aspect_ratio == "16:9":
		return Vector2i(640, 360)
	else:  # 10:9
		return Vector2i(BASE_VIEWPORT_WIDTH, BASE_VIEWPORT_HEIGHT)


func _on_item_database_loaded() -> void:
	"""Called when ItemDatabase finishes loading"""
	if player_inventory:
		player_inventory.give_starter_items()
