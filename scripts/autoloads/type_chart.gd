extends Node
## TypeChart - Pokemon type effectiveness calculations
## Implements Gen 2 type chart with 18 types (including Fairy)

# Type enum for strong typing
enum Type {
	NORMAL,
	FIRE,
	WATER,
	ELECTRIC,
	GRASS,
	ICE,
	FIGHTING,
	POISON,
	GROUND,
	FLYING,
	PSYCHIC,
	BUG,
	ROCK,
	GHOST,
	DRAGON,
	DARK,
	STEEL,
	FAIRY
}

# Type names for display and parsing
const TYPE_NAMES: Array[String] = [
	"Normal", "Fire", "Water", "Electric", "Grass", "Ice",
	"Fighting", "Poison", "Ground", "Flying", "Psychic", "Bug",
	"Rock", "Ghost", "Dragon", "Dark", "Steel", "Fairy"
]

# Effectiveness multipliers
const IMMUNE := 0.0
const NOT_EFFECTIVE := 0.5
const NEUTRAL := 1.0
const SUPER_EFFECTIVE := 2.0

# Type effectiveness chart: [attacking_type][defending_type] = multiplier
# Only storing non-neutral matchups to save space
var _effectiveness: Dictionary = {}


func _ready() -> void:
	_build_type_chart()
	print("TypeChart initialized with ", TYPE_NAMES.size(), " types")


func _build_type_chart() -> void:
	# Initialize all matchups as neutral
	for atk in Type.values():
		_effectiveness[atk] = {}
	
	# NORMAL attacking
	_set_effectiveness(Type.NORMAL, Type.ROCK, NOT_EFFECTIVE)
	_set_effectiveness(Type.NORMAL, Type.STEEL, NOT_EFFECTIVE)
	_set_effectiveness(Type.NORMAL, Type.GHOST, IMMUNE)
	
	# FIRE attacking
	_set_effectiveness(Type.FIRE, Type.FIRE, NOT_EFFECTIVE)
	_set_effectiveness(Type.FIRE, Type.WATER, NOT_EFFECTIVE)
	_set_effectiveness(Type.FIRE, Type.ROCK, NOT_EFFECTIVE)
	_set_effectiveness(Type.FIRE, Type.DRAGON, NOT_EFFECTIVE)
	_set_effectiveness(Type.FIRE, Type.GRASS, SUPER_EFFECTIVE)
	_set_effectiveness(Type.FIRE, Type.ICE, SUPER_EFFECTIVE)
	_set_effectiveness(Type.FIRE, Type.BUG, SUPER_EFFECTIVE)
	_set_effectiveness(Type.FIRE, Type.STEEL, SUPER_EFFECTIVE)
	
	# WATER attacking
	_set_effectiveness(Type.WATER, Type.WATER, NOT_EFFECTIVE)
	_set_effectiveness(Type.WATER, Type.GRASS, NOT_EFFECTIVE)
	_set_effectiveness(Type.WATER, Type.DRAGON, NOT_EFFECTIVE)
	_set_effectiveness(Type.WATER, Type.FIRE, SUPER_EFFECTIVE)
	_set_effectiveness(Type.WATER, Type.GROUND, SUPER_EFFECTIVE)
	_set_effectiveness(Type.WATER, Type.ROCK, SUPER_EFFECTIVE)
	
	# ELECTRIC attacking
	_set_effectiveness(Type.ELECTRIC, Type.ELECTRIC, NOT_EFFECTIVE)
	_set_effectiveness(Type.ELECTRIC, Type.GRASS, NOT_EFFECTIVE)
	_set_effectiveness(Type.ELECTRIC, Type.DRAGON, NOT_EFFECTIVE)
	_set_effectiveness(Type.ELECTRIC, Type.GROUND, IMMUNE)
	_set_effectiveness(Type.ELECTRIC, Type.WATER, SUPER_EFFECTIVE)
	_set_effectiveness(Type.ELECTRIC, Type.FLYING, SUPER_EFFECTIVE)
	
	# GRASS attacking
	_set_effectiveness(Type.GRASS, Type.FIRE, NOT_EFFECTIVE)
	_set_effectiveness(Type.GRASS, Type.GRASS, NOT_EFFECTIVE)
	_set_effectiveness(Type.GRASS, Type.POISON, NOT_EFFECTIVE)
	_set_effectiveness(Type.GRASS, Type.FLYING, NOT_EFFECTIVE)
	_set_effectiveness(Type.GRASS, Type.BUG, NOT_EFFECTIVE)
	_set_effectiveness(Type.GRASS, Type.DRAGON, NOT_EFFECTIVE)
	_set_effectiveness(Type.GRASS, Type.STEEL, NOT_EFFECTIVE)
	_set_effectiveness(Type.GRASS, Type.WATER, SUPER_EFFECTIVE)
	_set_effectiveness(Type.GRASS, Type.GROUND, SUPER_EFFECTIVE)
	_set_effectiveness(Type.GRASS, Type.ROCK, SUPER_EFFECTIVE)
	
	# ICE attacking
	_set_effectiveness(Type.ICE, Type.FIRE, NOT_EFFECTIVE)
	_set_effectiveness(Type.ICE, Type.WATER, NOT_EFFECTIVE)
	_set_effectiveness(Type.ICE, Type.ICE, NOT_EFFECTIVE)
	_set_effectiveness(Type.ICE, Type.STEEL, NOT_EFFECTIVE)
	_set_effectiveness(Type.ICE, Type.GRASS, SUPER_EFFECTIVE)
	_set_effectiveness(Type.ICE, Type.GROUND, SUPER_EFFECTIVE)
	_set_effectiveness(Type.ICE, Type.FLYING, SUPER_EFFECTIVE)
	_set_effectiveness(Type.ICE, Type.DRAGON, SUPER_EFFECTIVE)
	
	# FIGHTING attacking
	_set_effectiveness(Type.FIGHTING, Type.POISON, NOT_EFFECTIVE)
	_set_effectiveness(Type.FIGHTING, Type.FLYING, NOT_EFFECTIVE)
	_set_effectiveness(Type.FIGHTING, Type.PSYCHIC, NOT_EFFECTIVE)
	_set_effectiveness(Type.FIGHTING, Type.BUG, NOT_EFFECTIVE)
	_set_effectiveness(Type.FIGHTING, Type.FAIRY, NOT_EFFECTIVE)
	_set_effectiveness(Type.FIGHTING, Type.GHOST, IMMUNE)
	_set_effectiveness(Type.FIGHTING, Type.NORMAL, SUPER_EFFECTIVE)
	_set_effectiveness(Type.FIGHTING, Type.ICE, SUPER_EFFECTIVE)
	_set_effectiveness(Type.FIGHTING, Type.ROCK, SUPER_EFFECTIVE)
	_set_effectiveness(Type.FIGHTING, Type.DARK, SUPER_EFFECTIVE)
	_set_effectiveness(Type.FIGHTING, Type.STEEL, SUPER_EFFECTIVE)
	
	# POISON attacking
	_set_effectiveness(Type.POISON, Type.POISON, NOT_EFFECTIVE)
	_set_effectiveness(Type.POISON, Type.GROUND, NOT_EFFECTIVE)
	_set_effectiveness(Type.POISON, Type.ROCK, NOT_EFFECTIVE)
	_set_effectiveness(Type.POISON, Type.GHOST, NOT_EFFECTIVE)
	_set_effectiveness(Type.POISON, Type.STEEL, IMMUNE)
	_set_effectiveness(Type.POISON, Type.GRASS, SUPER_EFFECTIVE)
	_set_effectiveness(Type.POISON, Type.FAIRY, SUPER_EFFECTIVE)
	
	# GROUND attacking
	_set_effectiveness(Type.GROUND, Type.GRASS, NOT_EFFECTIVE)
	_set_effectiveness(Type.GROUND, Type.BUG, NOT_EFFECTIVE)
	_set_effectiveness(Type.GROUND, Type.FLYING, IMMUNE)
	_set_effectiveness(Type.GROUND, Type.FIRE, SUPER_EFFECTIVE)
	_set_effectiveness(Type.GROUND, Type.ELECTRIC, SUPER_EFFECTIVE)
	_set_effectiveness(Type.GROUND, Type.POISON, SUPER_EFFECTIVE)
	_set_effectiveness(Type.GROUND, Type.ROCK, SUPER_EFFECTIVE)
	_set_effectiveness(Type.GROUND, Type.STEEL, SUPER_EFFECTIVE)
	
	# FLYING attacking
	_set_effectiveness(Type.FLYING, Type.ELECTRIC, NOT_EFFECTIVE)
	_set_effectiveness(Type.FLYING, Type.ROCK, NOT_EFFECTIVE)
	_set_effectiveness(Type.FLYING, Type.STEEL, NOT_EFFECTIVE)
	_set_effectiveness(Type.FLYING, Type.GRASS, SUPER_EFFECTIVE)
	_set_effectiveness(Type.FLYING, Type.FIGHTING, SUPER_EFFECTIVE)
	_set_effectiveness(Type.FLYING, Type.BUG, SUPER_EFFECTIVE)
	
	# PSYCHIC attacking
	_set_effectiveness(Type.PSYCHIC, Type.PSYCHIC, NOT_EFFECTIVE)
	_set_effectiveness(Type.PSYCHIC, Type.STEEL, NOT_EFFECTIVE)
	_set_effectiveness(Type.PSYCHIC, Type.DARK, IMMUNE)
	_set_effectiveness(Type.PSYCHIC, Type.FIGHTING, SUPER_EFFECTIVE)
	_set_effectiveness(Type.PSYCHIC, Type.POISON, SUPER_EFFECTIVE)
	
	# BUG attacking
	_set_effectiveness(Type.BUG, Type.FIRE, NOT_EFFECTIVE)
	_set_effectiveness(Type.BUG, Type.FIGHTING, NOT_EFFECTIVE)
	_set_effectiveness(Type.BUG, Type.POISON, NOT_EFFECTIVE)
	_set_effectiveness(Type.BUG, Type.FLYING, NOT_EFFECTIVE)
	_set_effectiveness(Type.BUG, Type.GHOST, NOT_EFFECTIVE)
	_set_effectiveness(Type.BUG, Type.STEEL, NOT_EFFECTIVE)
	_set_effectiveness(Type.BUG, Type.FAIRY, NOT_EFFECTIVE)
	_set_effectiveness(Type.BUG, Type.GRASS, SUPER_EFFECTIVE)
	_set_effectiveness(Type.BUG, Type.PSYCHIC, SUPER_EFFECTIVE)
	_set_effectiveness(Type.BUG, Type.DARK, SUPER_EFFECTIVE)
	
	# ROCK attacking
	_set_effectiveness(Type.ROCK, Type.FIGHTING, NOT_EFFECTIVE)
	_set_effectiveness(Type.ROCK, Type.GROUND, NOT_EFFECTIVE)
	_set_effectiveness(Type.ROCK, Type.STEEL, NOT_EFFECTIVE)
	_set_effectiveness(Type.ROCK, Type.FIRE, SUPER_EFFECTIVE)
	_set_effectiveness(Type.ROCK, Type.ICE, SUPER_EFFECTIVE)
	_set_effectiveness(Type.ROCK, Type.FLYING, SUPER_EFFECTIVE)
	_set_effectiveness(Type.ROCK, Type.BUG, SUPER_EFFECTIVE)
	
	# GHOST attacking
	_set_effectiveness(Type.GHOST, Type.DARK, NOT_EFFECTIVE)
	_set_effectiveness(Type.GHOST, Type.NORMAL, IMMUNE)
	_set_effectiveness(Type.GHOST, Type.PSYCHIC, SUPER_EFFECTIVE)
	_set_effectiveness(Type.GHOST, Type.GHOST, SUPER_EFFECTIVE)
	
	# DRAGON attacking
	_set_effectiveness(Type.DRAGON, Type.STEEL, NOT_EFFECTIVE)
	_set_effectiveness(Type.DRAGON, Type.FAIRY, IMMUNE)
	_set_effectiveness(Type.DRAGON, Type.DRAGON, SUPER_EFFECTIVE)
	
	# DARK attacking
	_set_effectiveness(Type.DARK, Type.FIGHTING, NOT_EFFECTIVE)
	_set_effectiveness(Type.DARK, Type.DARK, NOT_EFFECTIVE)
	_set_effectiveness(Type.DARK, Type.FAIRY, NOT_EFFECTIVE)
	_set_effectiveness(Type.DARK, Type.PSYCHIC, SUPER_EFFECTIVE)
	_set_effectiveness(Type.DARK, Type.GHOST, SUPER_EFFECTIVE)
	
	# STEEL attacking
	_set_effectiveness(Type.STEEL, Type.FIRE, NOT_EFFECTIVE)
	_set_effectiveness(Type.STEEL, Type.WATER, NOT_EFFECTIVE)
	_set_effectiveness(Type.STEEL, Type.ELECTRIC, NOT_EFFECTIVE)
	_set_effectiveness(Type.STEEL, Type.STEEL, NOT_EFFECTIVE)
	_set_effectiveness(Type.STEEL, Type.ICE, SUPER_EFFECTIVE)
	_set_effectiveness(Type.STEEL, Type.ROCK, SUPER_EFFECTIVE)
	_set_effectiveness(Type.STEEL, Type.FAIRY, SUPER_EFFECTIVE)
	
	# FAIRY attacking
	_set_effectiveness(Type.FAIRY, Type.FIRE, NOT_EFFECTIVE)
	_set_effectiveness(Type.FAIRY, Type.POISON, NOT_EFFECTIVE)
	_set_effectiveness(Type.FAIRY, Type.STEEL, NOT_EFFECTIVE)
	_set_effectiveness(Type.FAIRY, Type.FIGHTING, SUPER_EFFECTIVE)
	_set_effectiveness(Type.FAIRY, Type.DRAGON, SUPER_EFFECTIVE)
	_set_effectiveness(Type.FAIRY, Type.DARK, SUPER_EFFECTIVE)


func _set_effectiveness(attacker: Type, defender: Type, multiplier: float) -> void:
	_effectiveness[attacker][defender] = multiplier


## Get effectiveness multiplier for a single type matchup
func get_effectiveness(attack_type: Type, defend_type: Type) -> float:
	if _effectiveness[attack_type].has(defend_type):
		return _effectiveness[attack_type][defend_type]
	return NEUTRAL


## Get total effectiveness against a Pokemon with one or two types
func get_effectiveness_against(attack_type: Type, defend_types: Array) -> float:
	var multiplier := 1.0
	for defend_type in defend_types:
		multiplier *= get_effectiveness(attack_type, defend_type)
	return multiplier


## Check if move is super effective (multiplier > 1)
func is_super_effective(attack_type: Type, defend_types: Array) -> bool:
	return get_effectiveness_against(attack_type, defend_types) > 1.0


## Check if move is not very effective (multiplier < 1 but > 0)
func is_not_effective(attack_type: Type, defend_types: Array) -> bool:
	var mult := get_effectiveness_against(attack_type, defend_types)
	return mult < 1.0 and mult > 0.0


## Check if move has no effect (multiplier = 0)
func is_immune(attack_type: Type, defend_types: Array) -> bool:
	return get_effectiveness_against(attack_type, defend_types) == 0.0


## Get type enum from string name (case-insensitive)
func type_from_string(type_name: String) -> Type:
	var upper := type_name.to_upper()
	for i in range(TYPE_NAMES.size()):
		if TYPE_NAMES[i].to_upper() == upper:
			return i as Type
	push_warning("Unknown type: ", type_name)
	return Type.NORMAL


## Get type name string from enum
func type_to_string(type_val: Type) -> String:
	if type_val >= 0 and type_val < TYPE_NAMES.size():
		return TYPE_NAMES[type_val]
	return "???"


## Get all types that this type is super effective against
func get_super_effective_against(attack_type: Type) -> Array[Type]:
	var result: Array[Type] = []
	for defend_type in Type.values():
		if get_effectiveness(attack_type, defend_type) == SUPER_EFFECTIVE:
			result.append(defend_type)
	return result


## Get all types that this type is weak to
func get_weaknesses(defend_type: Type) -> Array[Type]:
	var result: Array[Type] = []
	for attack_type in Type.values():
		if get_effectiveness(attack_type, defend_type) == SUPER_EFFECTIVE:
			result.append(attack_type)
	return result


## Get all types that this type resists
func get_resistances(defend_type: Type) -> Array[Type]:
	var result: Array[Type] = []
	for attack_type in Type.values():
		if get_effectiveness(attack_type, defend_type) == NOT_EFFECTIVE:
			result.append(attack_type)
	return result


## Get all types that this type is immune to
func get_immunities(defend_type: Type) -> Array[Type]:
	var result: Array[Type] = []
	for attack_type in Type.values():
		if get_effectiveness(attack_type, defend_type) == IMMUNE:
			result.append(attack_type)
	return result
