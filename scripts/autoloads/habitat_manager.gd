extends Node
## HabitatManager - Manages wild Pokemon spawning in the overworld
## Spawns Pokemon based on biome, time of day, and rarity

# Signals
signal pokemon_spawned(pokemon: Node)
signal pokemon_despawned(pokemon: Node)

# Spawn settings
const MAX_WILD_POKEMON := 8
const SPAWN_RADIUS := 6          # Tiles from player
const DESPAWN_RADIUS := 10       # Tiles from player
const SPAWN_CHECK_INTERVAL := 2.0  # Seconds

# State
var _spawned_pokemon: Array = []
var _spawn_timer: float = 0.0
var _spawn_container: Node2D = null
var _player_ref: Node = null
var _tilemap_ref: Node = null

# Spawn tables by biome
var _biome_spawns: Dictionary = {}


func _ready() -> void:
	_init_spawn_tables()
	print("HabitatManager initialized")


func _init_spawn_tables() -> void:
	"""Initialize spawn tables for different biomes"""
	# Grass biome spawns
	_biome_spawns["grass"] = [
		{"species": "RATTATA", "weight": 30, "min_level": 2, "max_level": 5},
		{"species": "PIDGEY", "weight": 25, "min_level": 2, "max_level": 5},
		{"species": "CATERPIE", "weight": 15, "min_level": 3, "max_level": 5},
		{"species": "WEEDLE", "weight": 15, "min_level": 3, "max_level": 5},
		{"species": "PIKACHU", "weight": 5, "min_level": 4, "max_level": 7},
	]
	
	_biome_spawns["tall_grass"] = [
		{"species": "RATTATA", "weight": 20, "min_level": 3, "max_level": 6},
		{"species": "PIDGEY", "weight": 20, "min_level": 3, "max_level": 6},
		{"species": "BULBASAUR", "weight": 10, "min_level": 5, "max_level": 8},
		{"species": "ODDISH", "weight": 15, "min_level": 4, "max_level": 7},
		{"species": "BELLSPROUT", "weight": 15, "min_level": 4, "max_level": 7},
	]
	
	_biome_spawns["forest"] = [
		{"species": "CATERPIE", "weight": 20, "min_level": 4, "max_level": 8},
		{"species": "WEEDLE", "weight": 20, "min_level": 4, "max_level": 8},
		{"species": "BULBASAUR", "weight": 15, "min_level": 5, "max_level": 10},
		{"species": "PIKACHU", "weight": 10, "min_level": 6, "max_level": 10},
	]
	
	_biome_spawns["water"] = [
		{"species": "MAGIKARP", "weight": 40, "min_level": 5, "max_level": 15},
		{"species": "GOLDEEN", "weight": 25, "min_level": 5, "max_level": 12},
		{"species": "SQUIRTLE", "weight": 10, "min_level": 8, "max_level": 15},
		{"species": "PSYDUCK", "weight": 15, "min_level": 6, "max_level": 12},
	]
	
	_biome_spawns["sand"] = [
		{"species": "SANDSHREW", "weight": 25, "min_level": 5, "max_level": 10},
		{"species": "DIGLETT", "weight": 25, "min_level": 4, "max_level": 9},
		{"species": "GEODUDE", "weight": 20, "min_level": 6, "max_level": 12},
	]
	
	_biome_spawns["rock"] = [
		{"species": "GEODUDE", "weight": 30, "min_level": 6, "max_level": 12},
		{"species": "ONIX", "weight": 10, "min_level": 10, "max_level": 18},
	]


## Set references from overworld
func set_references(player: Node, tilemap: Node, container: Node2D) -> void:
	_player_ref = player
	_tilemap_ref = tilemap
	_spawn_container = container


func _process(delta: float) -> void:
	if _player_ref == null or _spawn_container == null:
		return
	
	_spawn_timer += delta
	if _spawn_timer >= SPAWN_CHECK_INTERVAL:
		_spawn_timer = 0.0
		_check_spawns()
		_check_despawns()


func _check_spawns() -> void:
	"""Check if we should spawn new Pokemon"""
	if _spawned_pokemon.size() >= MAX_WILD_POKEMON:
		return
	
	# Find valid spawn tile near player
	var player_tile := Vector2i(
		int(_player_ref.global_position.x / 16),
		int(_player_ref.global_position.y / 16)
	)
	
	# Try to find spawn location
	for _attempt in range(5):
		var offset := Vector2i(
			randi_range(-SPAWN_RADIUS, SPAWN_RADIUS),
			randi_range(-SPAWN_RADIUS, SPAWN_RADIUS)
		)
		
		# Don't spawn too close
		if offset.length() < 3:
			continue
		
		var spawn_tile := player_tile + offset
		
		# Check if valid spawn location
		if _is_valid_spawn_tile(spawn_tile):
			_spawn_pokemon_at(spawn_tile)
			break


func _check_despawns() -> void:
	"""Remove Pokemon that are too far from player"""
	if _player_ref == null:
		return
	
	var player_tile := Vector2i(
		int(_player_ref.global_position.x / 16),
		int(_player_ref.global_position.y / 16)
	)
	
	var to_remove: Array = []
	
	for pokemon in _spawned_pokemon:
		if not is_instance_valid(pokemon):
			to_remove.append(pokemon)
			continue
		
		var dist: float = pokemon.grid_position.distance_to(player_tile)
		if dist > DESPAWN_RADIUS:
			to_remove.append(pokemon)
	
	for pokemon in to_remove:
		_despawn_pokemon(pokemon)


func _is_valid_spawn_tile(tile: Vector2i) -> bool:
	"""Check if tile is valid for spawning"""
	if _tilemap_ref == null:
		return false
	
	# Check tile type
	var tile_name: String = _tilemap_ref.get_tile_name(tile)
	
	# Can't spawn on solid tiles
	if _tilemap_ref.is_tile_solid(tile):
		return false
	
	# Check if tile has Pokemon already
	for pokemon in _spawned_pokemon:
		if is_instance_valid(pokemon) and pokemon.grid_position == tile:
			return false
	
	# Check if tile has structure
	if BuildManager.has_structure_at(tile):
		return false
	
	return true


func _spawn_pokemon_at(tile: Vector2i) -> void:
	"""Spawn a Pokemon at the given tile"""
	if _tilemap_ref == null or _spawn_container == null:
		return
	
	var tile_name: String = _tilemap_ref.get_tile_name(tile)
	var biome := _get_biome_from_tile(tile_name)
	
	# Get spawn data
	var spawn_data := _roll_spawn(biome)
	if spawn_data.is_empty():
		return
	
	# Create Pokemon
	var species_id: String = spawn_data.get("species", "RATTATA")
	var min_level: int = spawn_data.get("min_level", 3)
	var max_level: int = spawn_data.get("max_level", 6)
	var level := randi_range(min_level, max_level)
	
	var pokemon := SpeciesDatabase.create_pokemon(species_id, level)
	if pokemon == null:
		return
	
	# Create overworld Pokemon entity
	var owp := OverworldPokemon.new()
	owp.position = Vector2(tile.x * 16 + 8, tile.y * 16 + 8)
	owp.setup(pokemon, OverworldPokemon.OverworldType.WILD)
	
	# Connect signals
	owp.interacted.connect(_on_pokemon_interacted)
	owp.touched_player.connect(_on_pokemon_touched_player)
	
	_spawn_container.add_child(owp)
	_spawned_pokemon.append(owp)
	
	pokemon_spawned.emit(owp)
	
	# Log spawn event
	GameLogger.log_spawn(species_id + " Lv" + str(level), true, Vector2(tile.x * 16, tile.y * 16), {
		"species": species_id,
		"level": level,
		"tile_x": tile.x,
		"tile_y": tile.y,
		"biome": biome
	})
	print("Spawned wild ", species_id, " Lv", level, " at ", tile)


func _despawn_pokemon(pokemon: Node) -> void:
	"""Remove a spawned Pokemon"""
	_spawned_pokemon.erase(pokemon)
	
	if is_instance_valid(pokemon):
		# Log despawn event
		var pokemon_name := "Unknown"
		var pos := Vector2.ZERO
		if pokemon.has_method("get_info_string"):
			pokemon_name = pokemon.get_info_string()
		if "position" in pokemon:
			pos = pokemon.position
		GameLogger.log_spawn(pokemon_name, false, pos)
		
		pokemon_despawned.emit(pokemon)
		pokemon.queue_free()


func _get_biome_from_tile(tile_name: String) -> String:
	"""Map tile name to biome"""
	match tile_name:
		"tall_grass": return "tall_grass"
		"water", "deep_water": return "water"
		"sand": return "sand"
		"rock": return "rock"
		"tree": return "forest"
		_: return "grass"


func _roll_spawn(biome: String) -> Dictionary:
	"""Roll for a spawn from the biome's spawn table"""
	if not _biome_spawns.has(biome):
		biome = "grass"
	
	var spawns: Array = _biome_spawns[biome]
	if spawns.is_empty():
		return {}
	
	# Calculate total weight
	var total_weight := 0
	for spawn in spawns:
		total_weight += spawn.get("weight", 10)
	
	# Roll
	var roll := randi() % total_weight
	var current := 0
	
	for spawn in spawns:
		current += spawn.get("weight", 10)
		if roll < current:
			return spawn
	
	return spawns[0]


func _on_pokemon_interacted(pokemon: OverworldPokemon) -> void:
	"""Handle player interacting with wild Pokemon"""
	if pokemon.pokemon_data == null:
		return
	
	print("Interacted with wild ", pokemon.get_info_string())
	
	# Start wild battle
	if pokemon.overworld_type == OverworldPokemon.OverworldType.WILD:
		_start_battle_with(pokemon)


func _on_pokemon_touched_player(pokemon: OverworldPokemon) -> void:
	"""Handle wild Pokemon touching player"""
	if pokemon.pokemon_data == null:
		return
	
	if pokemon.overworld_type == OverworldPokemon.OverworldType.WILD:
		_start_battle_with(pokemon)


func _start_battle_with(pokemon: OverworldPokemon) -> void:
	"""Start a battle with the given Pokemon"""
	if pokemon.pokemon_data == null:
		return
	
	# Ensure player has at least one Pokemon
	_ensure_player_party()
	if GameManager.player_party.is_empty():
		push_error("Cannot start battle: player has no Pokemon!")
		return
	
	# Disable spawning during battle
	_spawn_timer = -999.0
	
	# Freeze player
	if _player_ref and _player_ref.has_method("set_movement_enabled"):
		_player_ref.set_movement_enabled(false)
	
	# Change game state
	GameManager.change_state(GameManager.GameState.BATTLE)
	
	# Start battle
	BattleManager.start_wild_battle(GameManager.player_party, pokemon.pokemon_data)
	
	# Connect to battle end to handle this Pokemon
	if not BattleManager.battle_ended.is_connected(_on_battle_ended.bind(pokemon)):
		BattleManager.battle_ended.connect(_on_battle_ended.bind(pokemon), CONNECT_ONE_SHOT)


func _on_battle_ended(result: String, data: Dictionary, pokemon: OverworldPokemon) -> void:
	"""Handle battle ending"""
	_spawn_timer = 0.0
	
	# Remove the Pokemon if caught or defeated
	if result == "victory" or result == "caught":
		_despawn_pokemon(pokemon)
	elif result == "fled":
		# Make Pokemon flee
		if is_instance_valid(pokemon):
			pokemon.behavior = OverworldPokemon.Behavior.FLEE
			pokemon.follow_target = _player_ref


## Clear all spawned Pokemon
func clear_all() -> void:
	for pokemon in _spawned_pokemon.duplicate():
		_despawn_pokemon(pokemon)


## Get count of spawned Pokemon
func get_spawn_count() -> int:
	return _spawned_pokemon.size()


## Add spawn entry to a biome
func add_spawn_entry(biome: String, species_id: String, weight: int, min_level: int, max_level: int) -> void:
	if not _biome_spawns.has(biome):
		_biome_spawns[biome] = []
	
	_biome_spawns[biome].append({
		"species": species_id,
		"weight": weight,
		"min_level": min_level,
		"max_level": max_level
	})


## Ensure player has at least one Pokemon for battles
func _ensure_player_party() -> void:
	if GameManager.player_party.is_empty():
		# Create a starter Pokemon for the player
		var starter := SpeciesDatabase.create_pokemon("PIKACHU", 10)
		if starter:
			starter.nickname = "PIKACHU"
			GameManager.player_party.append(starter)
			print("HabitatManager: Created starter Pokemon: ", starter.get_display_name(), " Lv", starter.level)
