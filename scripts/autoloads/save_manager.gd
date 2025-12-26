extends Node
## SaveManager - Handles saving and loading game data
## Supports multiple save slots and autosave

const SAVE_DIR := "user://saves/"
const SAVE_EXTENSION := ".sav"
const AUTOSAVE_SLOT := "autosave"
const MAX_SAVE_SLOTS := 3

# Save data version for migration
const SAVE_VERSION := 1

# Signals
signal save_completed(slot: String, success: bool)
signal load_completed(slot: String, success: bool)
signal autosave_triggered

# Autosave settings
var autosave_enabled: bool = true
var autosave_interval: float = 300.0  # 5 minutes
var _autosave_timer: float = 0.0

# Pending player position (applied after scene load)
var _pending_player_position: Dictionary = {}


func _ready() -> void:
	# Ensure save directory exists
	DirAccess.make_dir_recursive_absolute(SAVE_DIR)
	print("SaveManager initialized. Save directory: ", SAVE_DIR)


func _process(delta: float) -> void:
	if autosave_enabled and GameManager.current_state == GameManager.GameState.OVERWORLD:
		_autosave_timer += delta
		if _autosave_timer >= autosave_interval:
			_autosave_timer = 0.0
			autosave()


func get_save_path(slot: String) -> String:
	return SAVE_DIR + slot + SAVE_EXTENSION


func save_exists(slot: String) -> bool:
	return FileAccess.file_exists(get_save_path(slot))


func get_save_slots() -> Array[String]:
	var slots: Array[String] = []
	var dir := DirAccess.open(SAVE_DIR)
	if dir:
		dir.list_dir_begin()
		var file_name := dir.get_next()
		while file_name != "":
			if not dir.current_is_dir() and file_name.ends_with(SAVE_EXTENSION):
				slots.append(file_name.replace(SAVE_EXTENSION, ""))
			file_name = dir.get_next()
		dir.list_dir_end()
	return slots


func save_game(slot: String) -> bool:
	var save_data := _create_save_data()
	var path := get_save_path(slot)
	
	# Create backup of existing save
	if FileAccess.file_exists(path):
		var backup_path := path + ".backup"
		DirAccess.copy_absolute(path, backup_path)
	
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("Failed to open save file: " + path)
		save_completed.emit(slot, false)
		return false
	
	var json_string := JSON.stringify(save_data, "\t")
	file.store_string(json_string)
	file.close()
	
	print("Game saved to slot: ", slot)
	save_completed.emit(slot, true)
	return true


func load_game(slot: String) -> bool:
	var path := get_save_path(slot)
	
	if not FileAccess.file_exists(path):
		push_error("Save file does not exist: " + path)
		load_completed.emit(slot, false)
		return false
	
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("Failed to open save file: " + path)
		load_completed.emit(slot, false)
		return false
	
	var json_string := file.get_as_text()
	file.close()
	
	var json := JSON.new()
	var parse_result := json.parse(json_string)
	if parse_result != OK:
		push_error("Failed to parse save file: " + json.get_error_message())
		load_completed.emit(slot, false)
		return false
	
	var save_data: Dictionary = json.data
	
	# Check version and migrate if needed
	var version: int = save_data.get("version", 0)
	if version < SAVE_VERSION:
		save_data = _migrate_save_data(save_data, version)
	
	# Apply save data
	var success := _apply_save_data(save_data)
	
	print("Game loaded from slot: ", slot)
	load_completed.emit(slot, success)
	return success


func delete_save(slot: String) -> bool:
	var path := get_save_path(slot)
	
	if not FileAccess.file_exists(path):
		return true  # Already doesn't exist
	
	var err := DirAccess.remove_absolute(path)
	if err != OK:
		push_error("Failed to delete save file: " + path)
		return false
	
	# Also remove backup if it exists
	var backup_path := path + ".backup"
	if FileAccess.file_exists(backup_path):
		DirAccess.remove_absolute(backup_path)
	
	print("Save deleted: ", slot)
	return true


func autosave() -> void:
	if GameManager.current_state != GameManager.GameState.OVERWORLD:
		return
	
	autosave_triggered.emit()
	save_game(AUTOSAVE_SLOT)


func get_save_info(slot: String) -> Dictionary:
	"""Returns metadata about a save without fully loading it"""
	var path := get_save_path(slot)
	
	if not FileAccess.file_exists(path):
		return {}
	
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	
	var json_string := file.get_as_text()
	file.close()
	
	var json := JSON.new()
	if json.parse(json_string) != OK:
		return {}
	
	var save_data: Dictionary = json.data
	
	var party: Array = save_data.get("party", [])
	var lead_pokemon := ""
	if party.size() > 0:
		lead_pokemon = party[0].get("species_id", "")
	
	return {
		"player_name": save_data.get("player_name", "Unknown"),
		"play_time": save_data.get("play_time", 0),
		"party_count": party.size(),
		"lead_pokemon": lead_pokemon,
		"timestamp": save_data.get("timestamp", 0),
		"version": save_data.get("version", 0)
	}


func _create_save_data() -> Dictionary:
	var save_data := {
		"version": SAVE_VERSION,
		"timestamp": Time.get_unix_time_from_system(),
		"play_time": GameManager.game_time_seconds,
		
		# Player data
		"player_name": GameManager.player_name,
		"player_money": GameManager.player_money,
		"player_position": _serialize_player_position(),
		
		# Pokemon data
		"party": _serialize_party(),
		"pc_boxes": _serialize_pc_boxes(),
		
		# Inventory
		"inventory": GameManager.player_inventory.to_dict(),
		
		# World data
		"world_seed": GameManager.current_seed,
		"game_time": GameManager.game_time_seconds,
		
		# Structures
		"structures": BuildManager.get_placed_structures_data(),
		
		# Ranch and Breeding
		"ranch": RanchManager.get_save_data(),
		"breeding": BreedingManager.get_save_data(),
		
		# Settings
		"settings": GameManager.settings.duplicate()
	}
	
	return save_data


func _apply_save_data(data: Dictionary) -> bool:
	# Player data
	GameManager.player_name = data.get("player_name", "")
	GameManager.player_money = data.get("player_money", 0)
	
	# Pokemon data
	GameManager.player_party = _deserialize_party(data.get("party", []))
	GameManager.player_pc_boxes = _deserialize_pc_boxes(data.get("pc_boxes", []))
	
	# Inventory
	var inv_data: Dictionary = data.get("inventory", {})
	if not inv_data.is_empty():
		GameManager.player_inventory.from_dict(inv_data)
	
	# World data
	GameManager.current_seed = data.get("world_seed", 0)
	GameManager.game_time_seconds = data.get("game_time", 0.0)
	
	# Structures
	var structures_data: Array = data.get("structures", [])
	BuildManager.load_placed_structures(structures_data)
	
	# Ranch and Breeding
	var ranch_data: Dictionary = data.get("ranch", {})
	if not ranch_data.is_empty():
		RanchManager.load_save_data(ranch_data)
	
	var breeding_data: Dictionary = data.get("breeding", {})
	if not breeding_data.is_empty():
		BreedingManager.load_save_data(breeding_data)
	
	# Settings
	var saved_settings: Dictionary = data.get("settings", {})
	for key in saved_settings:
		if GameManager.settings.has(key):
			GameManager.settings[key] = saved_settings[key]
	
	# Apply audio settings
	AudioManager.music_volume = GameManager.settings.music_volume
	AudioManager.sfx_volume = GameManager.settings.sfx_volume
	
	# Store player position for later restoration
	_pending_player_position = data.get("player_position", {})
	
	return true


func _migrate_save_data(data: Dictionary, from_version: int) -> Dictionary:
	# Migrate save data from older versions
	# Add migration logic here as needed
	
	print("Migrating save data from version ", from_version, " to ", SAVE_VERSION)
	data["version"] = SAVE_VERSION
	return data


func _serialize_player_position() -> Dictionary:
	"""Serialize player grid position and facing direction"""
	# Try to find the player node in the scene tree
	var players := get_tree().get_nodes_in_group("player")
	if players.size() > 0:
		var player := players[0]
		return {
			"x": player.grid_position.x,
			"y": player.grid_position.y,
			"facing": player.facing
		}
	return {}


func get_pending_player_position() -> Dictionary:
	"""Get pending player position data (call after load to restore position)"""
	return _pending_player_position


func clear_pending_player_position() -> void:
	"""Clear pending player position after it's been applied"""
	_pending_player_position = {}


func _serialize_party() -> Array:
	var party_data: Array = []
	for pokemon in GameManager.player_party:
		party_data.append(_serialize_pokemon(pokemon))
	return party_data


func _deserialize_party(data: Array) -> Array[Pokemon]:
	var party: Array[Pokemon] = []
	for pokemon_data in data:
		var pokemon := _deserialize_pokemon(pokemon_data)
		if pokemon != null:
			party.append(pokemon)
	return party


func _serialize_pc_boxes() -> Array:
	var boxes_data: Array = []
	for box in GameManager.player_pc_boxes:
		var box_data: Array = []
		for pokemon in box:
			box_data.append(_serialize_pokemon(pokemon))
		boxes_data.append(box_data)
	return boxes_data


func _deserialize_pc_boxes(data: Array) -> Array:
	var boxes: Array = []
	for box_data in data:
		var box: Array = []
		for pokemon_data in box_data:
			var pokemon = _deserialize_pokemon(pokemon_data)
			if pokemon != null:
				box.append(pokemon)
		boxes.append(box)
	
	# Ensure we have the correct number of boxes
	while boxes.size() < GameManager.MAX_PC_BOXES:
		boxes.append([])
	
	return boxes


func _serialize_pokemon(pokemon: Pokemon) -> Dictionary:
	if pokemon == null:
		return {}
	
	return pokemon.to_dict()


func _deserialize_pokemon(data: Dictionary) -> Pokemon:
	if data.is_empty():
		return null
	
	var pokemon := Pokemon.from_dict(data)
	
	# Load species reference
	if pokemon:
		var species := SpeciesDatabase.get_species(pokemon.species_id)
		if species:
			pokemon.set_species(species)
			pokemon.recalculate_stats()
	
	return pokemon
