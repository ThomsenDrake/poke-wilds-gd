extends Node
## BreedingManager - Handles Pokemon breeding at Breeding Dens
## Manages egg production, compatibility, and inheritance

# Signals
signal egg_produced(egg: Pokemon, den_tile: Vector2i)
signal breeding_started(pokemon1: Pokemon, pokemon2: Pokemon, den_tile: Vector2i)
signal breeding_updated(den_tile: Vector2i, progress: float)

# Breeding den data: Dictionary of Vector2i -> BreedingDenData
var _breeding_dens: Dictionary = {}

# Egg hatching data: Dictionary of egg Pokemon -> steps
var _eggs_steps: Dictionary = {}

# Constants
const STEPS_PER_EGG_CYCLE := 256
const BASE_BREEDING_TIME := 300.0  # Seconds to produce an egg


class BreedingDenData:
	var tile: Vector2i = Vector2i.ZERO
	var pokemon1: Pokemon = null
	var pokemon2: Pokemon = null
	var progress: float = 0.0  # 0.0 to 1.0
	var has_egg: bool = false
	var produced_egg: Pokemon = null


func _ready() -> void:
	print("BreedingManager initialized")


func _process(delta: float) -> void:
	# Update breeding progress for all dens
	for tile in _breeding_dens.keys():
		var den: BreedingDenData = _breeding_dens[tile]
		if den.pokemon1 and den.pokemon2 and not den.has_egg:
			_update_breeding(den, delta)


func _update_breeding(den: BreedingDenData, delta: float) -> void:
	"""Update breeding progress for a den"""
	if not can_breed(den.pokemon1, den.pokemon2):
		return
	
	# Calculate breeding speed based on compatibility
	var compatibility := get_compatibility(den.pokemon1, den.pokemon2)
	var speed_mult := 1.0 + (compatibility / 100.0)
	
	den.progress += (delta / BASE_BREEDING_TIME) * speed_mult
	breeding_updated.emit(den.tile, den.progress)
	
	if den.progress >= 1.0:
		_produce_egg(den)


func _produce_egg(den: BreedingDenData) -> void:
	"""Produce an egg from the breeding pair"""
	var egg := create_egg(den.pokemon1, den.pokemon2)
	if egg:
		den.has_egg = true
		den.produced_egg = egg
		den.progress = 1.0
		egg_produced.emit(egg, den.tile)
		print("Egg produced at breeding den: ", den.tile)


## Register a breeding den at tile
func register_den(tile: Vector2i) -> void:
	if not _breeding_dens.has(tile):
		var den := BreedingDenData.new()
		den.tile = tile
		_breeding_dens[tile] = den


## Unregister a breeding den
func unregister_den(tile: Vector2i) -> void:
	_breeding_dens.erase(tile)


## Place Pokemon in breeding den
func place_pokemon(tile: Vector2i, pokemon: Pokemon, slot: int) -> bool:
	if not _breeding_dens.has(tile):
		register_den(tile)
	
	var den: BreedingDenData = _breeding_dens[tile]
	
	if slot == 0:
		if den.pokemon1 != null:
			return false
		den.pokemon1 = pokemon
	else:
		if den.pokemon2 != null:
			return false
		den.pokemon2 = pokemon
	
	# Reset progress when changing Pokemon
	den.progress = 0.0
	den.has_egg = false
	den.produced_egg = null
	
	# Emit signal if both Pokemon present
	if den.pokemon1 and den.pokemon2:
		breeding_started.emit(den.pokemon1, den.pokemon2, tile)
	
	return true


## Remove Pokemon from breeding den
func remove_pokemon(tile: Vector2i, slot: int) -> Pokemon:
	if not _breeding_dens.has(tile):
		return null
	
	var den: BreedingDenData = _breeding_dens[tile]
	var pokemon: Pokemon = null
	
	if slot == 0:
		pokemon = den.pokemon1
		den.pokemon1 = null
	else:
		pokemon = den.pokemon2
		den.pokemon2 = null
	
	den.progress = 0.0
	return pokemon


## Collect egg from breeding den
func collect_egg(tile: Vector2i) -> Pokemon:
	if not _breeding_dens.has(tile):
		return null
	
	var den: BreedingDenData = _breeding_dens[tile]
	if not den.has_egg or den.produced_egg == null:
		return null
	
	var egg := den.produced_egg
	den.has_egg = false
	den.produced_egg = null
	den.progress = 0.0
	
	return egg


## Get den data
func get_den_data(tile: Vector2i) -> BreedingDenData:
	return _breeding_dens.get(tile)


## Check if two Pokemon can breed
func can_breed(pokemon1: Pokemon, pokemon2: Pokemon) -> bool:
	if pokemon1 == null or pokemon2 == null:
		return false
	
	# Can't breed eggs
	if pokemon1.is_egg or pokemon2.is_egg:
		return false
	
	var species1 := pokemon1.get_species()
	var species2 := pokemon2.get_species()
	
	if species1 == null or species2 == null:
		return false
	
	# Check if either can breed
	if not species1.can_breed() and not species2.can_breed():
		return false
	
	# Check gender compatibility
	if pokemon1.gender == "none" or pokemon2.gender == "none":
		# Genderless can only breed with Ditto
		if species1.id != "DITTO" and species2.id != "DITTO":
			return false
	elif pokemon1.gender == pokemon2.gender:
		# Same gender can't breed (unless Ditto)
		if species1.id != "DITTO" and species2.id != "DITTO":
			return false
	
	# Check egg group compatibility
	if not _share_egg_group(species1, species2):
		# Ditto can breed with anything
		if species1.id != "DITTO" and species2.id != "DITTO":
			return false
	
	return true


func _share_egg_group(species1: PokemonSpecies, species2: PokemonSpecies) -> bool:
	"""Check if two species share an egg group"""
	var groups1 := [species1.egg_group1, species1.egg_group2]
	var groups2 := [species2.egg_group1, species2.egg_group2]
	
	for g1 in groups1:
		if g1 == PokemonSpecies.EggGroup.UNDISCOVERED:
			continue
		for g2 in groups2:
			if g2 == PokemonSpecies.EggGroup.UNDISCOVERED:
				continue
			if g1 == g2:
				return true
	
	return false


## Get breeding compatibility percentage (affects speed and IV inheritance)
func get_compatibility(pokemon1: Pokemon, pokemon2: Pokemon) -> int:
	if not can_breed(pokemon1, pokemon2):
		return 0
	
	var species1 := pokemon1.get_species()
	var species2 := pokemon2.get_species()
	
	# Same species = higher compatibility
	if species1.id == species2.id:
		# Same trainer = lower
		if pokemon1.trainer_id == pokemon2.trainer_id:
			return 50
		else:
			return 70
	else:
		# Different species
		if pokemon1.trainer_id == pokemon2.trainer_id:
			return 20
		else:
			return 50


## Create an egg from two Pokemon
func create_egg(pokemon1: Pokemon, pokemon2: Pokemon) -> Pokemon:
	if not can_breed(pokemon1, pokemon2):
		return null
	
	var species1 := pokemon1.get_species()
	var species2 := pokemon2.get_species()
	
	# Determine egg species (always from female/non-Ditto parent)
	var egg_species: PokemonSpecies
	if species1.id == "DITTO":
		egg_species = species2
	elif species2.id == "DITTO":
		egg_species = species1
	elif pokemon1.gender == "female":
		egg_species = species1
	else:
		egg_species = species2
	
	# Get base form (for Pokemon with baby forms)
	egg_species = _get_baby_form(egg_species)
	
	# Determine inherited moves
	var inherited_moves := _get_inherited_moves(pokemon1, pokemon2, egg_species)
	
	# Create the egg
	var egg := Pokemon.create_egg(egg_species, inherited_moves)
	
	# Inherit IVs (3 random IVs from parents in Gen 6+, simplified here)
	_inherit_ivs(egg, pokemon1, pokemon2)
	
	return egg


func _get_baby_form(species: PokemonSpecies) -> PokemonSpecies:
	"""Get the baby/base form of a species"""
	if species.pre_evolution != "":
		var baby := SpeciesDatabase.get_species(species.pre_evolution)
		if baby:
			return _get_baby_form(baby)  # Recurse for multi-stage
	return species


func _get_inherited_moves(pokemon1: Pokemon, pokemon2: Pokemon, egg_species: PokemonSpecies) -> Array[String]:
	"""Determine which moves the egg should inherit"""
	var moves: Array[String] = []
	
	# Get moves both parents know that are egg moves for the species
	for move_id in pokemon1.move_ids:
		if move_id in egg_species.egg_moves and move_id not in moves:
			moves.append(move_id)
	
	for move_id in pokemon2.move_ids:
		if move_id in egg_species.egg_moves and move_id not in moves:
			moves.append(move_id)
	
	# Add level 1 moves if space
	for move_id in egg_species.get_moves_at_level(1):
		if move_id not in moves and moves.size() < 4:
			moves.append(move_id)
	
	return moves


func _inherit_ivs(egg: Pokemon, parent1: Pokemon, parent2: Pokemon) -> void:
	"""Inherit IVs from parents"""
	var stats := ["hp", "attack", "defense", "speed", "sp_attack", "sp_defense"]
	var inherited := []
	
	# Randomly pick 3 stats to inherit
	stats.shuffle()
	for i in range(3):
		inherited.append(stats[i])
	
	# Inherit from random parent
	for stat in inherited:
		var from_parent := parent1 if randi() % 2 == 0 else parent2
		match stat:
			"hp": egg.iv_hp = from_parent.iv_hp
			"attack": egg.iv_attack = from_parent.iv_attack
			"defense": egg.iv_defense = from_parent.iv_defense
			"speed": egg.iv_speed = from_parent.iv_speed
			"sp_attack": egg.iv_sp_attack = from_parent.iv_sp_attack
			"sp_defense": egg.iv_sp_defense = from_parent.iv_sp_defense


## Register an egg for step tracking
func register_egg(egg: Pokemon) -> void:
	if egg.is_egg:
		_eggs_steps[egg] = 0


## Add steps to all eggs (called when player walks)
func add_steps(steps: int) -> Array[Pokemon]:
	"""Add steps to all eggs, return any that hatched"""
	var hatched: Array[Pokemon] = []
	
	for egg in _eggs_steps.keys():
		if not is_instance_valid(egg):
			_eggs_steps.erase(egg)
			continue
		
		_eggs_steps[egg] += steps
		
		var species: PokemonSpecies = egg.get_species()
		if species:
			var required_steps: int = species.egg_cycles * STEPS_PER_EGG_CYCLE
			if _eggs_steps[egg] >= required_steps:
				# Hatch!
				_hatch_egg(egg)
				hatched.append(egg)
				_eggs_steps.erase(egg)
	
	return hatched


func _hatch_egg(egg: Pokemon) -> void:
	"""Hatch an egg into a Pokemon"""
	egg.is_egg = false
	egg.level = 1
	egg.experience = 0
	egg.recalculate_stats()
	egg.current_hp = egg.max_hp
	
	print("Egg hatched into ", egg.get_display_name(), "!")


## Get hatching progress for an egg (0.0 to 1.0)
func get_hatch_progress(egg: Pokemon) -> float:
	if not _eggs_steps.has(egg):
		return 0.0
	
	var species := egg.get_species()
	if species == null:
		return 0.0
	
	var required := species.egg_cycles * STEPS_PER_EGG_CYCLE
	return float(_eggs_steps[egg]) / float(required)


## Serialize breeding state for saving
func get_save_data() -> Dictionary:
	var dens_data: Array = []
	for tile in _breeding_dens.keys():
		var den: BreedingDenData = _breeding_dens[tile]
		dens_data.append({
			"tile": {"x": tile.x, "y": tile.y},
			"pokemon1": den.pokemon1.to_dict() if den.pokemon1 else null,
			"pokemon2": den.pokemon2.to_dict() if den.pokemon2 else null,
			"progress": den.progress,
			"has_egg": den.has_egg,
			"egg": den.produced_egg.to_dict() if den.produced_egg else null
		})
	
	return {"dens": dens_data}


## Load breeding state from save
func load_save_data(data: Dictionary) -> void:
	_breeding_dens.clear()
	
	var dens_data: Array = data.get("dens", [])
	for den_data in dens_data:
		var tile_data: Dictionary = den_data.get("tile", {})
		var tile := Vector2i(tile_data.get("x", 0), tile_data.get("y", 0))
		
		var den := BreedingDenData.new()
		den.tile = tile
		den.progress = den_data.get("progress", 0.0)
		den.has_egg = den_data.get("has_egg", false)
		
		var p1_data: Dictionary = den_data.get("pokemon1")
		if p1_data:
			den.pokemon1 = Pokemon.from_dict(p1_data)
		
		var p2_data: Dictionary = den_data.get("pokemon2")
		if p2_data:
			den.pokemon2 = Pokemon.from_dict(p2_data)
		
		var egg_data: Dictionary = den_data.get("egg")
		if egg_data:
			den.produced_egg = Pokemon.from_dict(egg_data)
		
		_breeding_dens[tile] = den
