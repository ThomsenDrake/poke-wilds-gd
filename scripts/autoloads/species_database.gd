extends Node
## SpeciesDatabase - Central repository for Pokemon species data
## Loads, caches, and provides access to all PokemonSpecies resources

# Signal when database is fully loaded
signal database_loaded()
signal species_loaded(species_id: String)

# All loaded species indexed by ID
var _species: Dictionary = {}  # String -> PokemonSpecies

# Index by dex number for quick lookup
var _by_dex_number: Dictionary = {}  # int -> PokemonSpecies

# Loading state
var _is_loaded: bool = false
var _loading: bool = false


func _ready() -> void:
	# Register some built-in test species for development
	_register_test_species()
	print("SpeciesDatabase initialized with ", _species.size(), " species")


## Check if database is ready
func is_loaded() -> bool:
	return _is_loaded


## Get a species by ID
func get_species(species_id: String) -> PokemonSpecies:
	var upper_id := species_id.to_upper()
	if _species.has(upper_id):
		return _species[upper_id]
	push_warning("Species not found: ", species_id)
	return null


## Get a species by national dex number
func get_species_by_dex(dex_number: int) -> PokemonSpecies:
	if _by_dex_number.has(dex_number):
		return _by_dex_number[dex_number]
	return null


## Check if a species exists
func has_species(species_id: String) -> bool:
	return _species.has(species_id.to_upper())


## Get all species IDs
func get_all_species_ids() -> Array[String]:
	var ids: Array[String] = []
	ids.assign(_species.keys())
	return ids


## Get species count
func get_species_count() -> int:
	return _species.size()


## Register a species in the database
func register_species(species: PokemonSpecies) -> void:
	var upper_id := species.id.to_upper()
	_species[upper_id] = species
	if species.dex_number > 0:
		_by_dex_number[species.dex_number] = species
	species_loaded.emit(upper_id)


## Get all species of a specific type
func get_species_by_type(type_val: int) -> Array[PokemonSpecies]:
	var result: Array[PokemonSpecies] = []
	for species in _species.values():
		if species.has_type(type_val):
			result.append(species)
	return result


## Get all species that can learn a specific move
func get_species_by_move(move_id: String) -> Array[PokemonSpecies]:
	var result: Array[PokemonSpecies] = []
	for species in _species.values():
		if species.can_learn_move(move_id):
			result.append(species)
	return result


## Get all species that can use a field move
func get_species_with_field_move(field_move: String) -> Array[PokemonSpecies]:
	var result: Array[PokemonSpecies] = []
	var upper_move := field_move.to_upper()
	for species in _species.values():
		match upper_move:
			"CUT":
				if species.can_cut: result.append(species)
			"DIG":
				if species.can_dig: result.append(species)
			"BUILD":
				if species.can_build: result.append(species)
			"SURF":
				if species.can_surf: result.append(species)
			"FLY":
				if species.can_fly: result.append(species)
			"FLASH":
				if species.can_flash: result.append(species)
			"ROCK_SMASH":
				if species.can_rock_smash: result.append(species)
			"STRENGTH":
				if species.can_strength: result.append(species)
			"WATERFALL":
				if species.can_waterfall: result.append(species)
			"HEADBUTT":
				if species.can_headbutt: result.append(species)
			"HARVEST":
				if species.can_harvest: result.append(species)
	return result


## Get random species (for testing or random encounters)
func get_random_species() -> PokemonSpecies:
	if _species.is_empty():
		return null
	var keys := _species.keys()
	var random_key: String = keys[randi() % keys.size()]
	return _species[random_key]


## Create a Pokemon instance from a species ID
func create_pokemon(species_id: String, level: int, shiny: bool = false) -> Pokemon:
	var species := get_species(species_id)
	if species == null:
		push_error("Cannot create Pokemon: species not found: ", species_id)
		return null
	
	var pkmn := Pokemon.create_wild(species, level, shiny)
	return pkmn


## Load species from a JSON file
func load_from_json(file_path: String) -> int:
	if not FileAccess.file_exists(file_path):
		push_error("Species JSON file not found: ", file_path)
		return 0
	
	var file := FileAccess.open(file_path, FileAccess.READ)
	if file == null:
		push_error("Failed to open species JSON: ", file_path)
		return 0
	
	var json := JSON.new()
	var error := json.parse(file.get_as_text())
	file.close()
	
	if error != OK:
		push_error("Failed to parse species JSON: ", json.get_error_message())
		return 0
	
	var data: Array = json.data
	var count := 0
	
	for entry in data:
		var species := PokemonSpecies.from_dict(entry)
		register_species(species)
		count += 1
	
	return count


## Register test species for development
func _register_test_species() -> void:
	# Bulbasaur
	var bulbasaur := PokemonSpecies.new()
	bulbasaur.id = "BULBASAUR"
	bulbasaur.dex_number = 1
	bulbasaur.display_name = "Bulbasaur"
	bulbasaur.category = "Seed Pokemon"
	bulbasaur.base_hp = 45
	bulbasaur.base_attack = 49
	bulbasaur.base_defense = 49
	bulbasaur.base_speed = 45
	bulbasaur.base_sp_attack = 65
	bulbasaur.base_sp_defense = 65
	bulbasaur.type1 = TypeChart.Type.GRASS
	bulbasaur.type2 = TypeChart.Type.POISON
	bulbasaur.catch_rate = 45
	bulbasaur.base_exp = 64
	bulbasaur.growth_rate = PokemonSpecies.GrowthRate.MEDIUM_SLOW
	bulbasaur.level_moves = {
		1: ["TACKLE", "GROWL"],
		3: ["VINE_WHIP"],
		6: ["GROWTH"],
		9: ["LEECH_SEED"],
		12: ["RAZOR_LEAF"],
		15: ["POISON_POWDER", "SLEEP_POWDER"],
		18: ["SEED_BOMB"],
		21: ["TAKE_DOWN"],
		24: ["SWEET_SCENT"],
		27: ["SYNTHESIS"],
		30: ["WORRY_SEED"],
		33: ["DOUBLE_EDGE"],
		36: ["SOLAR_BEAM"]
	}
	bulbasaur.evolutions = [
		{"method": PokemonSpecies.EvolutionMethod.LEVEL, "param": 16, "target": "IVYSAUR"}
	]
	bulbasaur.can_cut = true
	bulbasaur.sprite_front = "res://assets/sprites/pokemon/bulbasaur/front.png"
	bulbasaur.sprite_back = "res://assets/sprites/pokemon/bulbasaur/back.png"
	register_species(bulbasaur)
	
	# Charmander
	var charmander := PokemonSpecies.new()
	charmander.id = "CHARMANDER"
	charmander.dex_number = 4
	charmander.display_name = "Charmander"
	charmander.category = "Lizard Pokemon"
	charmander.base_hp = 39
	charmander.base_attack = 52
	charmander.base_defense = 43
	charmander.base_speed = 65
	charmander.base_sp_attack = 60
	charmander.base_sp_defense = 50
	charmander.type1 = TypeChart.Type.FIRE
	charmander.type2 = -1
	charmander.catch_rate = 45
	charmander.base_exp = 62
	charmander.growth_rate = PokemonSpecies.GrowthRate.MEDIUM_SLOW
	charmander.level_moves = {
		1: ["SCRATCH", "GROWL"],
		4: ["EMBER"],
		8: ["SMOKESCREEN"],
		12: ["DRAGON_RAGE"],
		17: ["SCARY_FACE"],
		21: ["FIRE_FANG"],
		25: ["FLAME_BURST"],
		28: ["SLASH"],
		32: ["FLAMETHROWER"],
		36: ["FIRE_SPIN"],
		40: ["INFERNO"],
		44: ["FLARE_BLITZ"]
	}
	charmander.evolutions = [
		{"method": PokemonSpecies.EvolutionMethod.LEVEL, "param": 16, "target": "CHARMELEON"}
	]
	charmander.can_cut = true
	charmander.can_dig = true
	charmander.sprite_front = "res://assets/sprites/pokemon/charmander/front.png"
	charmander.sprite_back = "res://assets/sprites/pokemon/charmander/back.png"
	register_species(charmander)
	
	# Squirtle
	var squirtle := PokemonSpecies.new()
	squirtle.id = "SQUIRTLE"
	squirtle.dex_number = 7
	squirtle.display_name = "Squirtle"
	squirtle.category = "Tiny Turtle Pokemon"
	squirtle.base_hp = 44
	squirtle.base_attack = 48
	squirtle.base_defense = 65
	squirtle.base_speed = 43
	squirtle.base_sp_attack = 50
	squirtle.base_sp_defense = 64
	squirtle.type1 = TypeChart.Type.WATER
	squirtle.type2 = -1
	squirtle.catch_rate = 45
	squirtle.base_exp = 63
	squirtle.growth_rate = PokemonSpecies.GrowthRate.MEDIUM_SLOW
	squirtle.level_moves = {
		1: ["TACKLE", "TAIL_WHIP"],
		4: ["WATER_GUN"],
		7: ["WITHDRAW"],
		10: ["BUBBLE"],
		13: ["BITE"],
		16: ["RAPID_SPIN"],
		19: ["PROTECT"],
		22: ["WATER_PULSE"],
		25: ["AQUA_TAIL"],
		28: ["SKULL_BASH"],
		31: ["IRON_DEFENSE"],
		34: ["RAIN_DANCE"],
		37: ["HYDRO_PUMP"]
	}
	squirtle.evolutions = [
		{"method": PokemonSpecies.EvolutionMethod.LEVEL, "param": 16, "target": "WARTORTLE"}
	]
	squirtle.can_surf = true
	squirtle.can_waterfall = true
	squirtle.sprite_front = "res://assets/sprites/pokemon/squirtle/front.png"
	squirtle.sprite_back = "res://assets/sprites/pokemon/squirtle/back.png"
	register_species(squirtle)
	
	# Pikachu
	var pikachu := PokemonSpecies.new()
	pikachu.id = "PIKACHU"
	pikachu.dex_number = 25
	pikachu.display_name = "Pikachu"
	pikachu.category = "Mouse Pokemon"
	pikachu.base_hp = 35
	pikachu.base_attack = 55
	pikachu.base_defense = 40
	pikachu.base_speed = 90
	pikachu.base_sp_attack = 50
	pikachu.base_sp_defense = 50
	pikachu.type1 = TypeChart.Type.ELECTRIC
	pikachu.type2 = -1
	pikachu.catch_rate = 190
	pikachu.base_exp = 112
	pikachu.growth_rate = PokemonSpecies.GrowthRate.MEDIUM_FAST
	pikachu.level_moves = {
		1: ["THUNDER_SHOCK", "GROWL"],
		5: ["TAIL_WHIP"],
		10: ["THUNDER_WAVE"],
		13: ["QUICK_ATTACK"],
		18: ["ELECTRO_BALL"],
		21: ["DOUBLE_TEAM"],
		26: ["SPARK"],
		29: ["SLAM"],
		34: ["DISCHARGE"],
		37: ["AGILITY"],
		42: ["WILD_CHARGE"],
		45: ["LIGHT_SCREEN"],
		50: ["THUNDER"]
	}
	pikachu.evolutions = [
		{"method": PokemonSpecies.EvolutionMethod.ITEM, "param": "THUNDER_STONE", "target": "RAICHU"}
	]
	pikachu.can_flash = true
	pikachu.sprite_front = "res://assets/sprites/pokemon/pikachu/front.png"
	pikachu.sprite_back = "res://assets/sprites/pokemon/pikachu/back.png"
	register_species(pikachu)
	
	# Add some additional common wild Pokemon
	_register_common_wild_pokemon()
	
	_is_loaded = true
	database_loaded.emit()


func _register_common_wild_pokemon() -> void:
	"""Register additional common wild Pokemon for encounters"""
	
	# Rattata
	var rattata := PokemonSpecies.new()
	rattata.id = "RATTATA"
	rattata.dex_number = 19
	rattata.display_name = "Rattata"
	rattata.category = "Mouse Pokemon"
	rattata.base_hp = 30
	rattata.base_attack = 56
	rattata.base_defense = 35
	rattata.base_speed = 72
	rattata.base_sp_attack = 25
	rattata.base_sp_defense = 35
	rattata.type1 = TypeChart.Type.NORMAL
	rattata.type2 = -1
	rattata.catch_rate = 255
	rattata.base_exp = 51
	rattata.growth_rate = PokemonSpecies.GrowthRate.MEDIUM_FAST
	rattata.level_moves = {
		1: ["TACKLE", "TAIL_WHIP"],
		4: ["QUICK_ATTACK"],
		7: ["FOCUS_ENERGY"],
		10: ["BITE"],
		13: ["PURSUIT"],
		16: ["HYPER_FANG"],
		19: ["SUCKER_PUNCH"],
		22: ["CRUNCH"],
		25: ["ASSURANCE"],
		28: ["SUPER_FANG"],
		31: ["DOUBLE_EDGE"],
		34: ["ENDEAVOR"]
	}
	rattata.sprite_front = "res://assets/sprites/pokemon/rattata/front.png"
	rattata.sprite_back = "res://assets/sprites/pokemon/rattata/back.png"
	register_species(rattata)
	
	# Pidgey
	var pidgey := PokemonSpecies.new()
	pidgey.id = "PIDGEY"
	pidgey.dex_number = 16
	pidgey.display_name = "Pidgey"
	pidgey.category = "Tiny Bird Pokemon"
	pidgey.base_hp = 40
	pidgey.base_attack = 45
	pidgey.base_defense = 40
	pidgey.base_speed = 56
	pidgey.base_sp_attack = 35
	pidgey.base_sp_defense = 35
	pidgey.type1 = TypeChart.Type.NORMAL
	pidgey.type2 = TypeChart.Type.FLYING
	pidgey.catch_rate = 255
	pidgey.base_exp = 50
	pidgey.growth_rate = PokemonSpecies.GrowthRate.MEDIUM_SLOW
	pidgey.level_moves = {
		1: ["TACKLE"],
		5: ["SAND_ATTACK"],
		9: ["GUST"],
		13: ["QUICK_ATTACK"],
		17: ["WHIRLWIND"],
		21: ["TWISTER"],
		25: ["FEATHER_DANCE"],
		29: ["AGILITY"],
		33: ["WING_ATTACK"],
		37: ["ROOST"],
		41: ["TAILWIND"],
		45: ["MIRROR_MOVE"],
		49: ["AIR_SLASH"],
		53: ["HURRICANE"]
	}
	pidgey.can_fly = true
	pidgey.sprite_front = "res://assets/sprites/pokemon/pidgey/front.png"
	pidgey.sprite_back = "res://assets/sprites/pokemon/pidgey/back.png"
	register_species(pidgey)
	
	# Spearow
	var spearow := PokemonSpecies.new()
	spearow.id = "SPEAROW"
	spearow.dex_number = 21
	spearow.display_name = "Spearow"
	spearow.category = "Tiny Bird Pokemon"
	spearow.base_hp = 40
	spearow.base_attack = 60
	spearow.base_defense = 30
	spearow.base_speed = 70
	spearow.base_sp_attack = 31
	spearow.base_sp_defense = 31
	spearow.type1 = TypeChart.Type.NORMAL
	spearow.type2 = TypeChart.Type.FLYING
	spearow.catch_rate = 255
	spearow.base_exp = 52
	spearow.growth_rate = PokemonSpecies.GrowthRate.MEDIUM_FAST
	spearow.level_moves = {
		1: ["PECK", "GROWL"],
		5: ["LEER"],
		9: ["FURY_ATTACK"],
		13: ["PURSUIT"],
		17: ["AERIAL_ACE"],
		21: ["MIRROR_MOVE"],
		25: ["AGILITY"],
		29: ["ASSURANCE"],
		33: ["ROOST"],
		37: ["DRILL_PECK"]
	}
	spearow.can_fly = true
	spearow.sprite_front = "res://assets/sprites/pokemon/spearow/front.png"
	spearow.sprite_back = "res://assets/sprites/pokemon/spearow/back.png"
	register_species(spearow)
	
	# Caterpie
	var caterpie := PokemonSpecies.new()
	caterpie.id = "CATERPIE"
	caterpie.dex_number = 10
	caterpie.display_name = "Caterpie"
	caterpie.category = "Worm Pokemon"
	caterpie.base_hp = 45
	caterpie.base_attack = 30
	caterpie.base_defense = 35
	caterpie.base_speed = 45
	caterpie.base_sp_attack = 20
	caterpie.base_sp_defense = 20
	caterpie.type1 = TypeChart.Type.BUG
	caterpie.type2 = -1
	caterpie.catch_rate = 255
	caterpie.base_exp = 39
	caterpie.growth_rate = PokemonSpecies.GrowthRate.MEDIUM_FAST
	caterpie.level_moves = {
		1: ["TACKLE", "STRING_SHOT"],
		9: ["BUG_BITE"]
	}
	caterpie.evolutions = [
		{"method": PokemonSpecies.EvolutionMethod.LEVEL, "param": 7, "target": "METAPOD"}
	]
	caterpie.sprite_front = "res://assets/sprites/pokemon/caterpie/front.png"
	caterpie.sprite_back = "res://assets/sprites/pokemon/caterpie/back.png"
	register_species(caterpie)
	
	# Weedle
	var weedle := PokemonSpecies.new()
	weedle.id = "WEEDLE"
	weedle.dex_number = 13
	weedle.display_name = "Weedle"
	weedle.category = "Hairy Bug Pokemon"
	weedle.base_hp = 40
	weedle.base_attack = 35
	weedle.base_defense = 30
	weedle.base_speed = 50
	weedle.base_sp_attack = 20
	weedle.base_sp_defense = 20
	weedle.type1 = TypeChart.Type.BUG
	weedle.type2 = TypeChart.Type.POISON
	weedle.catch_rate = 255
	weedle.base_exp = 39
	weedle.growth_rate = PokemonSpecies.GrowthRate.MEDIUM_FAST
	weedle.level_moves = {
		1: ["POISON_STING", "STRING_SHOT"],
		9: ["BUG_BITE"]
	}
	weedle.evolutions = [
		{"method": PokemonSpecies.EvolutionMethod.LEVEL, "param": 7, "target": "KAKUNA"}
	]
	weedle.sprite_front = "res://assets/sprites/pokemon/weedle/front.png"
	weedle.sprite_back = "res://assets/sprites/pokemon/weedle/back.png"
	register_species(weedle)
	
	# Oddish
	var oddish := PokemonSpecies.new()
	oddish.id = "ODDISH"
	oddish.dex_number = 43
	oddish.display_name = "Oddish"
	oddish.category = "Weed Pokemon"
	oddish.base_hp = 45
	oddish.base_attack = 50
	oddish.base_defense = 55
	oddish.base_speed = 30
	oddish.base_sp_attack = 75
	oddish.base_sp_defense = 65
	oddish.type1 = TypeChart.Type.GRASS
	oddish.type2 = TypeChart.Type.POISON
	oddish.catch_rate = 255
	oddish.base_exp = 64
	oddish.growth_rate = PokemonSpecies.GrowthRate.MEDIUM_SLOW
	oddish.level_moves = {
		1: ["ABSORB"],
		4: ["GROWTH"],
		8: ["SWEET_SCENT"],
		12: ["ACID"],
		14: ["POISON_POWDER", "STUN_SPORE", "SLEEP_POWDER"],
		18: ["MEGA_DRAIN"],
		22: ["LUCKY_CHANT"],
		26: ["NATURAL_GIFT"],
		30: ["MOONLIGHT"],
		34: ["GIGA_DRAIN"],
		38: ["PETAL_DANCE"]
	}
	oddish.evolutions = [
		{"method": PokemonSpecies.EvolutionMethod.LEVEL, "param": 21, "target": "GLOOM"}
	]
	oddish.can_cut = true
	oddish.sprite_front = "res://assets/sprites/pokemon/oddish/front.png"
	oddish.sprite_back = "res://assets/sprites/pokemon/oddish/back.png"
	register_species(oddish)
	
	# Bellsprout
	var bellsprout := PokemonSpecies.new()
	bellsprout.id = "BELLSPROUT"
	bellsprout.dex_number = 69
	bellsprout.display_name = "Bellsprout"
	bellsprout.category = "Flower Pokemon"
	bellsprout.base_hp = 50
	bellsprout.base_attack = 75
	bellsprout.base_defense = 35
	bellsprout.base_speed = 40
	bellsprout.base_sp_attack = 70
	bellsprout.base_sp_defense = 30
	bellsprout.type1 = TypeChart.Type.GRASS
	bellsprout.type2 = TypeChart.Type.POISON
	bellsprout.catch_rate = 255
	bellsprout.base_exp = 60
	bellsprout.growth_rate = PokemonSpecies.GrowthRate.MEDIUM_SLOW
	bellsprout.level_moves = {
		1: ["VINE_WHIP"],
		4: ["GROWTH"],
		7: ["WRAP"],
		11: ["SLEEP_POWDER"],
		13: ["POISON_POWDER"],
		15: ["STUN_SPORE"],
		17: ["ACID"],
		23: ["KNOCK_OFF"],
		29: ["SWEET_SCENT"],
		35: ["GASTRO_ACID"],
		41: ["RAZOR_LEAF"],
		47: ["SLAM"],
		50: ["WRING_OUT"]
	}
	bellsprout.evolutions = [
		{"method": PokemonSpecies.EvolutionMethod.LEVEL, "param": 21, "target": "WEEPINBELL"}
	]
	bellsprout.can_cut = true
	bellsprout.sprite_front = "res://assets/sprites/pokemon/bellsprout/front.png"
	bellsprout.sprite_back = "res://assets/sprites/pokemon/bellsprout/back.png"
	register_species(bellsprout)
	
	# Magikarp
	var magikarp := PokemonSpecies.new()
	magikarp.id = "MAGIKARP"
	magikarp.dex_number = 129
	magikarp.display_name = "Magikarp"
	magikarp.category = "Fish Pokemon"
	magikarp.base_hp = 20
	magikarp.base_attack = 10
	magikarp.base_defense = 55
	magikarp.base_speed = 80
	magikarp.base_sp_attack = 15
	magikarp.base_sp_defense = 20
	magikarp.type1 = TypeChart.Type.WATER
	magikarp.type2 = -1
	magikarp.catch_rate = 255
	magikarp.base_exp = 40
	magikarp.growth_rate = PokemonSpecies.GrowthRate.SLOW
	magikarp.level_moves = {
		1: ["SPLASH"],
		15: ["TACKLE"],
		30: ["FLAIL"]
	}
	magikarp.evolutions = [
		{"method": PokemonSpecies.EvolutionMethod.LEVEL, "param": 20, "target": "GYARADOS"}
	]
	magikarp.sprite_front = "res://assets/sprites/pokemon/magikarp/front.png"
	magikarp.sprite_back = "res://assets/sprites/pokemon/magikarp/back.png"
	register_species(magikarp)
	
	# Goldeen
	var goldeen := PokemonSpecies.new()
	goldeen.id = "GOLDEEN"
	goldeen.dex_number = 118
	goldeen.display_name = "Goldeen"
	goldeen.category = "Goldfish Pokemon"
	goldeen.base_hp = 45
	goldeen.base_attack = 67
	goldeen.base_defense = 60
	goldeen.base_speed = 63
	goldeen.base_sp_attack = 35
	goldeen.base_sp_defense = 50
	goldeen.type1 = TypeChart.Type.WATER
	goldeen.type2 = -1
	goldeen.catch_rate = 225
	goldeen.base_exp = 64
	goldeen.growth_rate = PokemonSpecies.GrowthRate.MEDIUM_FAST
	goldeen.level_moves = {
		1: ["PECK", "TAIL_WHIP", "WATER_SPORT"],
		7: ["SUPERSONIC"],
		11: ["HORN_ATTACK"],
		17: ["FLAIL"],
		21: ["WATER_PULSE"],
		27: ["AQUA_RING"],
		31: ["FURY_ATTACK"],
		37: ["WATERFALL"],
		41: ["HORN_DRILL"],
		47: ["AGILITY"],
		51: ["MEGAHORN"]
	}
	goldeen.evolutions = [
		{"method": PokemonSpecies.EvolutionMethod.LEVEL, "param": 33, "target": "SEAKING"}
	]
	goldeen.can_surf = true
	goldeen.can_waterfall = true
	goldeen.sprite_front = "res://assets/sprites/pokemon/goldeen/front.png"
	goldeen.sprite_back = "res://assets/sprites/pokemon/goldeen/back.png"
	register_species(goldeen)
	
	# Psyduck
	var psyduck := PokemonSpecies.new()
	psyduck.id = "PSYDUCK"
	psyduck.dex_number = 54
	psyduck.display_name = "Psyduck"
	psyduck.category = "Duck Pokemon"
	psyduck.base_hp = 50
	psyduck.base_attack = 52
	psyduck.base_defense = 48
	psyduck.base_speed = 55
	psyduck.base_sp_attack = 65
	psyduck.base_sp_defense = 50
	psyduck.type1 = TypeChart.Type.WATER
	psyduck.type2 = -1
	psyduck.catch_rate = 190
	psyduck.base_exp = 64
	psyduck.growth_rate = PokemonSpecies.GrowthRate.MEDIUM_FAST
	psyduck.level_moves = {
		1: ["WATER_SPORT", "SCRATCH"],
		4: ["TAIL_WHIP"],
		8: ["WATER_GUN"],
		11: ["DISABLE"],
		15: ["CONFUSION"],
		18: ["WATER_PULSE"],
		22: ["FURY_SWIPES"],
		25: ["SCREECH"],
		29: ["ZEN_HEADBUTT"],
		32: ["AQUA_TAIL"],
		36: ["SOAK"],
		39: ["PSYCH_UP"],
		43: ["AMNESIA"],
		46: ["HYDRO_PUMP"],
		50: ["WONDER_ROOM"]
	}
	psyduck.evolutions = [
		{"method": PokemonSpecies.EvolutionMethod.LEVEL, "param": 33, "target": "GOLDUCK"}
	]
	psyduck.can_surf = true
	psyduck.sprite_front = "res://assets/sprites/pokemon/psyduck/front.png"
	psyduck.sprite_back = "res://assets/sprites/pokemon/psyduck/back.png"
	register_species(psyduck)
	
	# Sandshrew
	var sandshrew := PokemonSpecies.new()
	sandshrew.id = "SANDSHREW"
	sandshrew.dex_number = 27
	sandshrew.display_name = "Sandshrew"
	sandshrew.category = "Mouse Pokemon"
	sandshrew.base_hp = 50
	sandshrew.base_attack = 75
	sandshrew.base_defense = 85
	sandshrew.base_speed = 40
	sandshrew.base_sp_attack = 20
	sandshrew.base_sp_defense = 30
	sandshrew.type1 = TypeChart.Type.GROUND
	sandshrew.type2 = -1
	sandshrew.catch_rate = 255
	sandshrew.base_exp = 60
	sandshrew.growth_rate = PokemonSpecies.GrowthRate.MEDIUM_FAST
	sandshrew.level_moves = {
		1: ["SCRATCH", "DEFENSE_CURL"],
		3: ["SAND_ATTACK"],
		5: ["POISON_STING"],
		7: ["ROLLOUT"],
		9: ["RAPID_SPIN"],
		11: ["FURY_CUTTER"],
		14: ["MAGNITUDE"],
		17: ["SWIFT"],
		20: ["FURY_SWIPES"],
		23: ["SAND_TOMB"],
		26: ["SLASH"],
		30: ["DIG"],
		34: ["GYRO_BALL"],
		38: ["SANDSTORM"],
		42: ["EARTHQUAKE"]
	}
	sandshrew.evolutions = [
		{"method": PokemonSpecies.EvolutionMethod.LEVEL, "param": 22, "target": "SANDSLASH"}
	]
	sandshrew.can_dig = true
	sandshrew.sprite_front = "res://assets/sprites/pokemon/sandshrew/front.png"
	sandshrew.sprite_back = "res://assets/sprites/pokemon/sandshrew/back.png"
	register_species(sandshrew)
	
	# Diglett
	var diglett := PokemonSpecies.new()
	diglett.id = "DIGLETT"
	diglett.dex_number = 50
	diglett.display_name = "Diglett"
	diglett.category = "Mole Pokemon"
	diglett.base_hp = 10
	diglett.base_attack = 55
	diglett.base_defense = 25
	diglett.base_speed = 95
	diglett.base_sp_attack = 35
	diglett.base_sp_defense = 45
	diglett.type1 = TypeChart.Type.GROUND
	diglett.type2 = -1
	diglett.catch_rate = 255
	diglett.base_exp = 53
	diglett.growth_rate = PokemonSpecies.GrowthRate.MEDIUM_FAST
	diglett.level_moves = {
		1: ["SCRATCH", "SAND_ATTACK"],
		4: ["GROWL"],
		7: ["ASTONISH"],
		12: ["MUD_SLAP"],
		15: ["MAGNITUDE"],
		18: ["BULLDOZE"],
		23: ["SUCKER_PUNCH"],
		26: ["MUD_BOMB"],
		29: ["EARTH_POWER"],
		34: ["DIG"],
		37: ["SLASH"],
		40: ["EARTHQUAKE"],
		45: ["FISSURE"]
	}
	diglett.evolutions = [
		{"method": PokemonSpecies.EvolutionMethod.LEVEL, "param": 26, "target": "DUGTRIO"}
	]
	diglett.can_dig = true
	diglett.sprite_front = "res://assets/sprites/pokemon/diglett/front.png"
	diglett.sprite_back = "res://assets/sprites/pokemon/diglett/back.png"
	register_species(diglett)
	
	# Geodude
	var geodude := PokemonSpecies.new()
	geodude.id = "GEODUDE"
	geodude.dex_number = 74
	geodude.display_name = "Geodude"
	geodude.category = "Rock Pokemon"
	geodude.base_hp = 40
	geodude.base_attack = 80
	geodude.base_defense = 100
	geodude.base_speed = 20
	geodude.base_sp_attack = 30
	geodude.base_sp_defense = 30
	geodude.type1 = TypeChart.Type.ROCK
	geodude.type2 = TypeChart.Type.GROUND
	geodude.catch_rate = 255
	geodude.base_exp = 60
	geodude.growth_rate = PokemonSpecies.GrowthRate.MEDIUM_SLOW
	geodude.level_moves = {
		1: ["TACKLE", "DEFENSE_CURL"],
		4: ["MUD_SPORT"],
		6: ["ROCK_POLISH"],
		10: ["ROLLOUT"],
		12: ["MAGNITUDE"],
		16: ["ROCK_THROW"],
		18: ["SMACK_DOWN"],
		22: ["BULLDOZE"],
		24: ["SELF_DESTRUCT"],
		28: ["STEALTH_ROCK"],
		30: ["ROCK_BLAST"],
		34: ["EARTHQUAKE"],
		36: ["EXPLOSION"],
		40: ["DOUBLE_EDGE"],
		42: ["STONE_EDGE"]
	}
	geodude.evolutions = [
		{"method": PokemonSpecies.EvolutionMethod.LEVEL, "param": 25, "target": "GRAVELER"}
	]
	geodude.can_rock_smash = true
	geodude.can_strength = true
	geodude.sprite_front = "res://assets/sprites/pokemon/geodude/front.png"
	geodude.sprite_back = "res://assets/sprites/pokemon/geodude/back.png"
	register_species(geodude)
	
	# Onix
	var onix := PokemonSpecies.new()
	onix.id = "ONIX"
	onix.dex_number = 95
	onix.display_name = "Onix"
	onix.category = "Rock Snake Pokemon"
	onix.base_hp = 35
	onix.base_attack = 45
	onix.base_defense = 160
	onix.base_speed = 70
	onix.base_sp_attack = 30
	onix.base_sp_defense = 45
	onix.type1 = TypeChart.Type.ROCK
	onix.type2 = TypeChart.Type.GROUND
	onix.catch_rate = 45
	onix.base_exp = 77
	onix.growth_rate = PokemonSpecies.GrowthRate.MEDIUM_FAST
	onix.level_moves = {
		1: ["MUD_SPORT", "TACKLE", "HARDEN", "BIND"],
		4: ["CURSE"],
		7: ["ROCK_THROW"],
		10: ["RAGE"],
		13: ["ROCK_TOMB"],
		16: ["STEALTH_ROCK"],
		19: ["ROCK_POLISH"],
		22: ["SMACK_DOWN"],
		25: ["DRAGON_BREATH"],
		28: ["SLAM"],
		31: ["SCREECH"],
		34: ["ROCK_SLIDE"],
		37: ["SAND_TOMB"],
		40: ["IRON_TAIL"],
		43: ["DIG"],
		46: ["STONE_EDGE"],
		49: ["DOUBLE_EDGE"],
		52: ["SANDSTORM"]
	}
	onix.evolutions = [
		{"method": PokemonSpecies.EvolutionMethod.TRADE_ITEM, "param": "METAL_COAT", "target": "STEELIX"}
	]
	onix.can_rock_smash = true
	onix.can_strength = true
	onix.can_dig = true
	onix.sprite_front = "res://assets/sprites/pokemon/onix/front.png"
	onix.sprite_back = "res://assets/sprites/pokemon/onix/back.png"
	register_species(onix)
