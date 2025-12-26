extends Node
## RanchManager - Manages Pokemon living at the player's base
## Handles ranch Pokemon spawning, behavior, harvesting, and happiness

# Signals
signal pokemon_added(pokemon: Pokemon)
signal pokemon_removed(pokemon: Pokemon)
signal resource_harvested(item_id: String, amount: int, pokemon: Pokemon)
signal pokemon_happiness_changed(pokemon: Pokemon, new_happiness: int)

# Ranch Pokemon data
var _ranch_pokemon: Array[Pokemon] = []
var _overworld_pokemon: Array = []  # OverworldPokemon nodes
var _spawn_container: Node2D = null

# Harvest tracking
var _harvest_timers: Dictionary = {}  # Pokemon -> time since last harvest

# Constants
const MAX_RANCH_POKEMON := 20
const HARVEST_INTERVAL := 60.0  # Seconds between harvests
const HAPPINESS_GAIN_RATE := 1  # Happiness points per minute on ranch


func _ready() -> void:
	print("RanchManager initialized")


func _process(delta: float) -> void:
	# Update harvest timers
	for pokemon in _harvest_timers.keys():
		if not is_instance_valid(pokemon):
			_harvest_timers.erase(pokemon)
			continue
		
		_harvest_timers[pokemon] += delta
	
	# Slowly increase happiness for ranch Pokemon
	# (simplified - in real game would be more complex)


## Set spawn container reference
func set_container(container: Node2D) -> void:
	_spawn_container = container


## Add Pokemon to ranch
func add_to_ranch(pokemon: Pokemon) -> bool:
	if _ranch_pokemon.size() >= MAX_RANCH_POKEMON:
		return false
	
	if pokemon in _ranch_pokemon:
		return false
	
	_ranch_pokemon.append(pokemon)
	_harvest_timers[pokemon] = 0.0
	
	# Spawn overworld entity
	_spawn_ranch_pokemon(pokemon)
	
	pokemon_added.emit(pokemon)
	print("Added ", pokemon.get_display_name(), " to ranch")
	return true


## Remove Pokemon from ranch
func remove_from_ranch(pokemon: Pokemon) -> bool:
	if pokemon not in _ranch_pokemon:
		return false
	
	_ranch_pokemon.erase(pokemon)
	_harvest_timers.erase(pokemon)
	
	# Remove overworld entity
	_despawn_ranch_pokemon(pokemon)
	
	pokemon_removed.emit(pokemon)
	return true


## Get Pokemon from ranch at index
func get_ranch_pokemon(index: int) -> Pokemon:
	if index < 0 or index >= _ranch_pokemon.size():
		return null
	return _ranch_pokemon[index]


## Get all ranch Pokemon
func get_all_ranch_pokemon() -> Array[Pokemon]:
	return _ranch_pokemon.duplicate()


## Get ranch Pokemon count
func get_ranch_count() -> int:
	return _ranch_pokemon.size()


## Check if Pokemon is on ranch
func is_on_ranch(pokemon: Pokemon) -> bool:
	return pokemon in _ranch_pokemon


## Spawn overworld entity for ranch Pokemon
func _spawn_ranch_pokemon(pokemon: Pokemon) -> void:
	if _spawn_container == null:
		return
	
	var owp := OverworldPokemon.new()
	
	# Find spawn position near structures
	var spawn_tile := _find_ranch_spawn_position()
	owp.position = Vector2(spawn_tile.x * 16 + 8, spawn_tile.y * 16 + 8)
	
	owp.setup(pokemon, OverworldPokemon.OverworldType.RANCH)
	owp.set_home(spawn_tile)
	
	# Connect interaction
	owp.interacted.connect(_on_ranch_pokemon_interacted)
	
	_spawn_container.add_child(owp)
	_overworld_pokemon.append(owp)


func _find_ranch_spawn_position() -> Vector2i:
	"""Find a valid position for ranch Pokemon near player structures"""
	# Get all structure positions
	var structures := BuildManager.get_placed_structures_data()
	
	if structures.is_empty():
		# No structures, spawn at origin
		return Vector2i(0, 0)
	
	# Pick random structure and spawn nearby
	var struct: Dictionary = structures[randi() % structures.size()]
	var base_tile := Vector2i(struct.get("x", 0), struct.get("y", 0))
	
	# Find empty tile near structure
	for _attempt in range(10):
		var offset := Vector2i(randi_range(-3, 3), randi_range(-3, 3))
		var tile := base_tile + offset
		
		# Check if tile is valid
		if not BuildManager.has_structure_at(tile):
			return tile
	
	return base_tile + Vector2i(1, 1)


## Despawn overworld entity for ranch Pokemon
func _despawn_ranch_pokemon(pokemon: Pokemon) -> void:
	for owp in _overworld_pokemon:
		if is_instance_valid(owp) and owp.pokemon_data == pokemon:
			_overworld_pokemon.erase(owp)
			owp.queue_free()
			return


## Handle interaction with ranch Pokemon
func _on_ranch_pokemon_interacted(owp: OverworldPokemon) -> void:
	if owp.pokemon_data == null:
		return
	
	print("Interacted with ranch Pokemon: ", owp.get_info_string())
	
	# Check for harvest
	if can_harvest(owp.pokemon_data):
		var result := harvest(owp.pokemon_data)
		if result.success:
			print("Harvested: ", result.item_id, " x", result.amount)


## Check if Pokemon can be harvested
func can_harvest(pokemon: Pokemon) -> bool:
	if not _harvest_timers.has(pokemon):
		return false
	
	var species := pokemon.get_species()
	if species == null or species.harvestables.is_empty():
		return false
	
	return _harvest_timers[pokemon] >= HARVEST_INTERVAL


## Harvest resources from Pokemon
func harvest(pokemon: Pokemon) -> Dictionary:
	var result := {"success": false, "item_id": "", "amount": 0}
	
	if not can_harvest(pokemon):
		return result
	
	var species := pokemon.get_species()
	if species == null or species.harvestables.is_empty():
		return result
	
	# Reset timer
	_harvest_timers[pokemon] = 0.0
	
	# Pick random harvestable
	var item_id: String = species.harvestables[randi() % species.harvestables.size()]
	var amount := 1
	
	# Bonus amount based on happiness
	if pokemon.friendship >= 200:
		amount += 1
	
	# Add to inventory
	GameManager.player_inventory.add_item(item_id, amount)
	
	result.success = true
	result.item_id = item_id
	result.amount = amount
	
	resource_harvested.emit(item_id, amount, pokemon)
	return result


## Harvest all ready Pokemon
func harvest_all() -> Dictionary:
	var total := {"items": {}, "count": 0}
	
	for pokemon in _ranch_pokemon:
		if can_harvest(pokemon):
			var result := harvest(pokemon)
			if result.success:
				var item_id: String = result.item_id
				if not total.items.has(item_id):
					total.items[item_id] = 0
				total.items[item_id] += result.amount
				total.count += 1
	
	return total


## Get time until harvest ready for Pokemon
func get_harvest_time_remaining(pokemon: Pokemon) -> float:
	if not _harvest_timers.has(pokemon):
		return HARVEST_INTERVAL
	
	return maxf(0.0, HARVEST_INTERVAL - _harvest_timers[pokemon])


## Update ranch Pokemon positions (call after loading structures)
func refresh_positions() -> void:
	for owp in _overworld_pokemon:
		if is_instance_valid(owp):
			var new_pos := _find_ranch_spawn_position()
			owp.set_home(new_pos)
			owp.grid_position = new_pos
			owp.position = Vector2(new_pos.x * 16 + 8, new_pos.y * 16 + 8)


## Clear all ranch Pokemon overworld entities
func clear_overworld() -> void:
	for owp in _overworld_pokemon:
		if is_instance_valid(owp):
			owp.queue_free()
	_overworld_pokemon.clear()


## Respawn all ranch Pokemon overworld entities
func respawn_all() -> void:
	clear_overworld()
	
	for pokemon in _ranch_pokemon:
		_spawn_ranch_pokemon(pokemon)


## Get save data
func get_save_data() -> Dictionary:
	var pokemon_data: Array = []
	for pokemon in _ranch_pokemon:
		pokemon_data.append(pokemon.to_dict())
	
	var timers: Dictionary = {}
	for pokemon in _harvest_timers.keys():
		var idx := _ranch_pokemon.find(pokemon)
		if idx >= 0:
			timers[idx] = _harvest_timers[pokemon]
	
	return {
		"pokemon": pokemon_data,
		"timers": timers
	}


## Load save data
func load_save_data(data: Dictionary) -> void:
	_ranch_pokemon.clear()
	_harvest_timers.clear()
	clear_overworld()
	
	var pokemon_data: Array = data.get("pokemon", [])
	var timers: Dictionary = data.get("timers", {})
	
	for i in range(pokemon_data.size()):
		var pkmn := Pokemon.from_dict(pokemon_data[i])
		if pkmn:
			# Set species reference
			var species := SpeciesDatabase.get_species(pkmn.species_id)
			if species:
				pkmn.set_species(species)
			
			_ranch_pokemon.append(pkmn)
			_harvest_timers[pkmn] = timers.get(str(i), 0.0)
	
	# Respawn overworld entities
	if _spawn_container:
		respawn_all()


## Move Pokemon from party to ranch
func deposit_from_party(party_index: int) -> bool:
	if party_index < 0 or party_index >= GameManager.player_party.size():
		return false
	
	# Keep at least one Pokemon in party
	if GameManager.player_party.size() <= 1:
		return false
	
	var pokemon: Pokemon = GameManager.player_party[party_index]
	
	# Can't deposit last healthy Pokemon
	var healthy_count := 0
	for i in range(GameManager.player_party.size()):
		if i != party_index and GameManager.player_party[i].can_battle():
			healthy_count += 1
	if healthy_count == 0:
		return false
	
	if add_to_ranch(pokemon):
		GameManager.player_party.remove_at(party_index)
		return true
	
	return false


## Withdraw Pokemon from ranch to party
func withdraw_to_party(ranch_index: int) -> bool:
	if not GameManager.can_add_to_party():
		return false
	
	var pokemon := get_ranch_pokemon(ranch_index)
	if pokemon == null:
		return false
	
	if remove_from_ranch(pokemon):
		GameManager.player_party.append(pokemon)
		return true
	
	return false
