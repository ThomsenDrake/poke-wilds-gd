@tool
class_name PokemonSpecies
extends Resource
## PokemonSpecies - Resource class for Pokemon species data
## Contains base stats, types, learn sets, evolutions, and field move capabilities

# Evolution methods matching the original game
enum EvolutionMethod {
	NONE,
	LEVEL,           # Evolve at specific level
	LEVEL_ATK_GT,    # Level when Attack > Defense (Hitmonlee)
	LEVEL_DEF_GT,    # Level when Defense > Attack (Hitmonchan)
	LEVEL_ATK_EQ,    # Level when Attack == Defense (Hitmontop)
	ITEM,            # Use evolution stone
	TRADE,           # Trade to evolve
	TRADE_ITEM,      # Trade while holding item
	HAPPINESS,       # High friendship
	HAPPINESS_DAY,   # High friendship during day
	HAPPINESS_NIGHT, # High friendship at night
	LEVEL_MALE,      # Level up if male
	LEVEL_FEMALE,    # Level up if female
	LOCATION,        # Level up at specific location
	HOLD_ITEM_DAY,   # Level up holding item during day
	HOLD_ITEM_NIGHT  # Level up holding item at night
}

# Gender ratio constants (matches original game)
enum GenderRatio {
	ALWAYS_MALE = 0,      # 100% male
	MOSTLY_MALE = 31,     # 87.5% male
	MORE_MALE = 63,       # 75% male
	EQUAL = 127,          # 50/50
	MORE_FEMALE = 191,    # 75% female
	MOSTLY_FEMALE = 223,  # 87.5% female
	ALWAYS_FEMALE = 254,  # 100% female
	GENDERLESS = 255      # No gender
}

# Experience growth rates
enum GrowthRate {
	FAST,
	MEDIUM_FAST,
	MEDIUM_SLOW,
	SLOW,
	ERRATIC,
	FLUCTUATING
}

# Egg groups for breeding
enum EggGroup {
	MONSTER,
	WATER_1,
	WATER_2,
	WATER_3,
	BUG,
	FLYING,
	FIELD,
	FAIRY,
	GRASS,
	HUMAN_LIKE,
	MINERAL,
	AMORPHOUS,
	DITTO,
	DRAGON,
	UNDISCOVERED
}

# Basic identification
@export var id: String = ""                      # Internal identifier (e.g., "BULBASAUR")
@export var dex_number: int = 0                  # National dex number
@export var display_name: String = ""            # Display name
@export var category: String = ""                # Species category (e.g., "Seed Pokemon")

# Base stats (Gen 2 style: HP, Attack, Defense, Speed, Special Attack, Special Defense)
@export var base_hp: int = 1
@export var base_attack: int = 1
@export var base_defense: int = 1
@export var base_speed: int = 1
@export var base_sp_attack: int = 1
@export var base_sp_defense: int = 1

# Types (using TypeChart.Type values)
@export var type1: int = 0                       # Primary type (always set)
@export var type2: int = -1                      # Secondary type (-1 if single type)

# Catch/breeding data
@export var catch_rate: int = 45                 # 0-255, higher = easier
@export var base_exp: int = 64                   # Base experience yield
@export var gender_ratio: GenderRatio = GenderRatio.EQUAL
@export var egg_cycles: int = 20                 # Steps to hatch / 256
@export var growth_rate: GrowthRate = GrowthRate.MEDIUM_FAST
@export var egg_group1: EggGroup = EggGroup.UNDISCOVERED
@export var egg_group2: EggGroup = EggGroup.UNDISCOVERED

# Physical characteristics
@export var height_m: float = 1.0                # Height in meters
@export var weight_kg: float = 10.0              # Weight in kilograms

# Abilities (Gen 3+ but some fan games include them)
@export var ability1: String = ""
@export var ability2: String = ""
@export var hidden_ability: String = ""

# Held items in wild encounters
@export var wild_item_common: String = ""        # 50% chance
@export var wild_item_rare: String = ""          # 5% chance

# Learnset: Dictionary of level -> Array of move IDs
# e.g., {1: ["TACKLE", "GROWL"], 7: ["LEECH_SEED"]}
@export var level_moves: Dictionary = {}

# TM/HM compatibility: Array of move IDs this species can learn
@export var tm_moves: Array[String] = []
@export var hm_moves: Array[String] = []

# Egg moves: Array of move IDs learnable through breeding
@export var egg_moves: Array[String] = []

# Tutor moves: Array of move IDs learnable from move tutors
@export var tutor_moves: Array[String] = []

# Evolution data: Array of evolution entries
# Each entry: {"method": EvolutionMethod, "param": variant, "target": species_id}
@export var evolutions: Array[Dictionary] = []

# Pre-evolution (for baby Pokemon lookups)
@export var pre_evolution: String = ""

# Field move capabilities (PokeWilds specific)
@export var can_cut: bool = false
@export var can_dig: bool = false
@export var can_build: bool = false
@export var can_surf: bool = false
@export var can_fly: bool = false
@export var can_flash: bool = false
@export var can_rock_smash: bool = false
@export var can_strength: bool = false
@export var can_waterfall: bool = false
@export var can_headbutt: bool = false
@export var can_harvest: bool = false

# Sprite paths (relative to assets/)
@export var sprite_front: String = ""
@export var sprite_back: String = ""
@export var sprite_front_shiny: String = ""
@export var sprite_back_shiny: String = ""
@export var sprite_icon: String = ""
@export var sprite_overworld: String = ""

# Habitat info for overworld spawning (PokeWilds specific)
@export var habitat_grass: float = 0.0           # Spawn weight in grass
@export var habitat_water: float = 0.0           # Spawn weight in water
@export var habitat_cave: float = 0.0            # Spawn weight in caves
@export var habitat_mountain: float = 0.0        # Spawn weight on mountains
@export var habitat_forest: float = 0.0          # Spawn weight in forests
@export var habitat_desert: float = 0.0          # Spawn weight in desert
@export var habitat_snow: float = 0.0            # Spawn weight in snow
@export var min_spawn_level: int = 2
@export var max_spawn_level: int = 5

# Harvestable drops when Pokemon is on your team (PokeWilds specific)
@export var harvestables: Array[String] = []     # Item IDs this Pokemon can provide


## Get array of types for this species
func get_types() -> Array[int]:
	if type2 >= 0:
		return [type1, type2]
	return [type1]


## Check if species has a specific type
func has_type(type_val: int) -> bool:
	return type1 == type_val or type2 == type_val


## Get base stat total (BST)
func get_base_stat_total() -> int:
	return base_hp + base_attack + base_defense + base_speed + base_sp_attack + base_sp_defense


## Get all moves learnable at or before a given level
func get_moves_at_level(level: int) -> Array[String]:
	var moves: Array[String] = []
	for lv in level_moves.keys():
		if lv <= level:
			for move_id in level_moves[lv]:
				if move_id not in moves:
					moves.append(move_id)
	return moves


## Get the last 4 moves learnable at or before a given level (for wild Pokemon)
func get_default_moves(level: int) -> Array[String]:
	var all_moves := get_moves_at_level(level)
	# Return last 4 moves (most recently learned)
	var start := maxi(0, all_moves.size() - 4)
	return all_moves.slice(start)


## Check if species can learn a specific move by any method
func can_learn_move(move_id: String) -> bool:
	# Check level-up moves
	for moves in level_moves.values():
		if move_id in moves:
			return true
	# Check TM/HM/Egg/Tutor
	return move_id in tm_moves or move_id in hm_moves or move_id in egg_moves or move_id in tutor_moves


## Check if species can use any field moves
func has_field_moves() -> bool:
	return can_cut or can_dig or can_build or can_surf or can_fly or can_flash or \
		   can_rock_smash or can_strength or can_waterfall or can_headbutt or can_harvest


## Get list of available field moves for this species
func get_field_moves() -> Array[String]:
	var moves: Array[String] = []
	if can_cut: moves.append("CUT")
	if can_dig: moves.append("DIG")
	if can_build: moves.append("BUILD")
	if can_surf: moves.append("SURF")
	if can_fly: moves.append("FLY")
	if can_flash: moves.append("FLASH")
	if can_rock_smash: moves.append("ROCK_SMASH")
	if can_strength: moves.append("STRENGTH")
	if can_waterfall: moves.append("WATERFALL")
	if can_headbutt: moves.append("HEADBUTT")
	if can_harvest: moves.append("HARVEST")
	return moves


## Determine gender based on species ratio
func roll_gender() -> String:
	if gender_ratio == GenderRatio.GENDERLESS:
		return "none"
	if gender_ratio == GenderRatio.ALWAYS_MALE:
		return "male"
	if gender_ratio == GenderRatio.ALWAYS_FEMALE:
		return "female"
	
	# Roll against gender ratio threshold
	var roll := randi() % 256
	if roll < gender_ratio:
		return "female"
	return "male"


## Check if this species can breed
func can_breed() -> bool:
	return egg_group1 != EggGroup.UNDISCOVERED


## Calculate experience needed for a level (Gen 2 formulas)
func exp_for_level(level: int) -> int:
	match growth_rate:
		GrowthRate.FAST:
			return int(0.8 * pow(level, 3))
		GrowthRate.MEDIUM_FAST:
			return int(pow(level, 3))
		GrowthRate.MEDIUM_SLOW:
			return int(1.2 * pow(level, 3) - 15 * pow(level, 2) + 100 * level - 140)
		GrowthRate.SLOW:
			return int(1.25 * pow(level, 3))
		GrowthRate.ERRATIC:
			if level <= 50:
				return int(pow(level, 3) * (100 - level) / 50)
			elif level <= 68:
				return int(pow(level, 3) * (150 - level) / 100)
			elif level <= 98:
				return int(pow(level, 3) * ((1911 - 10 * level) / 3) / 500)
			else:
				return int(pow(level, 3) * (160 - level) / 100)
		GrowthRate.FLUCTUATING:
			if level <= 15:
				return int(pow(level, 3) * ((level + 1) / 3 + 24) / 50)
			elif level <= 36:
				return int(pow(level, 3) * (level + 14) / 50)
			else:
				return int(pow(level, 3) * (level / 2 + 32) / 50)
	return int(pow(level, 3))


## Serialize to dictionary for saving/export
func to_dict() -> Dictionary:
	return {
		"id": id,
		"dex_number": dex_number,
		"display_name": display_name,
		"category": category,
		"base_stats": {
			"hp": base_hp,
			"attack": base_attack,
			"defense": base_defense,
			"speed": base_speed,
			"sp_attack": base_sp_attack,
			"sp_defense": base_sp_defense
		},
		"types": [type1, type2] if type2 >= 0 else [type1],
		"catch_rate": catch_rate,
		"base_exp": base_exp,
		"gender_ratio": gender_ratio,
		"growth_rate": growth_rate,
		"level_moves": level_moves,
		"tm_moves": tm_moves,
		"hm_moves": hm_moves,
		"egg_moves": egg_moves,
		"evolutions": evolutions,
		"field_moves": get_field_moves()
	}


## Create from dictionary
static func from_dict(data: Dictionary) -> PokemonSpecies:
	var species := PokemonSpecies.new()
	species.id = data.get("id", "")
	species.dex_number = data.get("dex_number", 0)
	species.display_name = data.get("display_name", "")
	species.category = data.get("category", "")
	
	var stats: Dictionary = data.get("base_stats", {})
	species.base_hp = stats.get("hp", 1)
	species.base_attack = stats.get("attack", 1)
	species.base_defense = stats.get("defense", 1)
	species.base_speed = stats.get("speed", 1)
	species.base_sp_attack = stats.get("sp_attack", 1)
	species.base_sp_defense = stats.get("sp_defense", 1)
	
	var types: Array = data.get("types", [0])
	species.type1 = types[0] if types.size() > 0 else 0
	species.type2 = types[1] if types.size() > 1 else -1
	
	species.catch_rate = data.get("catch_rate", 45)
	species.base_exp = data.get("base_exp", 64)
	species.gender_ratio = data.get("gender_ratio", GenderRatio.EQUAL)
	species.growth_rate = data.get("growth_rate", GrowthRate.MEDIUM_FAST)
	species.level_moves = data.get("level_moves", {})
	species.tm_moves.assign(data.get("tm_moves", []))
	species.hm_moves.assign(data.get("hm_moves", []))
	species.egg_moves.assign(data.get("egg_moves", []))
	species.evolutions.assign(data.get("evolutions", []))
	
	return species
