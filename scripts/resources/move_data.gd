@tool
class_name MoveData
extends Resource
## MoveData - Resource class for Pokemon move/attack data
## Stores power, type, accuracy, PP, category, and effect information

# Move categories (Physical uses Attack/Defense, Special uses SpAtk/SpDef)
enum Category {
	PHYSICAL,
	SPECIAL,
	STATUS
}

# Common move effects
enum Effect {
	NONE,                # Normal damage, no secondary effect
	# Stat modifiers
	RAISE_ATTACK,
	RAISE_DEFENSE,
	RAISE_SPEED,
	RAISE_SPECIAL_ATTACK,
	RAISE_SPECIAL_DEFENSE,
	RAISE_ACCURACY,
	RAISE_EVASION,
	RAISE_ALL_STATS,     # Ancient Power, Silver Wind
	LOWER_ATTACK,
	LOWER_DEFENSE,
	LOWER_SPEED,
	LOWER_SPECIAL_ATTACK,
	LOWER_SPECIAL_DEFENSE,
	LOWER_ACCURACY,
	LOWER_EVASION,
	# Status conditions
	BURN,
	FREEZE,
	PARALYZE,
	POISON,
	BADLY_POISON,        # Toxic
	SLEEP,
	CONFUSE,
	FLINCH,
	INFATUATION,
	# Health/PP
	HEAL_SELF,           # Recover, Rest
	HEAL_HALF_DAMAGE,    # Drain moves
	RECOIL,              # Take fraction of damage dealt
	CRASH,               # Take damage on miss
	# Multi-hit
	MULTI_HIT_2,         # Always 2 hits
	MULTI_HIT_2_5,       # 2-5 hits
	DOUBLE_HIT,          # Double Kick
	# Priority/order
	ALWAYS_FIRST,        # Quick Attack, Extreme Speed (+1 priority)
	ALWAYS_LAST,         # Counter, Mirror Coat
	# Special mechanics
	CHARGE_TURN,         # Solar Beam, Fly, Dig
	RECHARGE_TURN,       # Hyper Beam
	PROTECT,             # Protect, Detect
	ONE_HIT_KO,          # Horn Drill, Fissure
	FIXED_DAMAGE,        # Seismic Toss, Night Shade (level-based)
	SUPER_FANG,          # Deal half current HP
	WEATHER_SUN,
	WEATHER_RAIN,
	WEATHER_SAND,
	WEATHER_HAIL,
	SWITCH_OUT,          # Baton Pass, U-turn
	FORCE_SWITCH,        # Roar, Whirlwind
	TRAP,                # Wrap, Bind, Fire Spin
	LEECH_SEED,
	LIGHT_SCREEN,
	REFLECT,
	SUBSTITUTE,
	ENCORE,
	DISABLE,
	TRANSFORM,
	# Field moves (PokeWilds specific)
	FIELD_CUT,
	FIELD_DIG,
	FIELD_BUILD,
	FIELD_SURF,
	FIELD_FLY,
	FIELD_FLASH,
	FIELD_ROCK_SMASH,
	FIELD_STRENGTH,
	FIELD_WATERFALL,
	FIELD_HEADBUTT,
	FIELD_HARVEST
}

# Core move properties
@export var id: String = ""                    # Internal identifier (e.g., "TACKLE")
@export var display_name: String = ""          # Display name (e.g., "Tackle")
@export var description: String = ""           # Move description for UI

@export var type: int = 0                      # TypeChart.Type enum value
@export var category: Category = Category.PHYSICAL
@export var power: int = 0                     # Base power (0 for status moves)
@export var accuracy: int = 100                # Accuracy percentage (0 = always hits)
@export var pp: int = 10                       # Base PP (Power Points)
@export var max_pp: int = 10                   # Maximum PP after PP Ups

@export var priority: int = 0                  # Turn order priority (-7 to +5)
@export var effect: Effect = Effect.NONE       # Primary effect
@export var effect_chance: int = 0             # % chance for secondary effect (0 = always)

@export var makes_contact: bool = true         # Does move make physical contact?
@export var sound_based: bool = false          # Is it a sound-based move?
@export var is_hm: bool = false                # Is this an HM move?
@export var is_tm: bool = false                # Is this a TM move?

# For moves with special damage calculation
@export var fixed_damage: int = 0              # For FIXED_DAMAGE effect
@export var recoil_percent: int = 0            # % of damage taken as recoil
@export var heal_percent: int = 0              # % of max HP healed
@export var drain_percent: int = 0             # % of damage healed

# For multi-hit moves
@export var min_hits: int = 1
@export var max_hits: int = 1

# Field move flag for overworld use
@export var field_effect: Effect = Effect.NONE


## Check if this move deals damage
func is_damaging() -> bool:
	return power > 0 or effect in [Effect.FIXED_DAMAGE, Effect.SUPER_FANG, Effect.ONE_HIT_KO]


## Check if this move is a status move
func is_status() -> bool:
	return category == Category.STATUS


## Check if this move can be used in the overworld
func has_field_use() -> bool:
	return field_effect != Effect.NONE


## Check if secondary effect applies this use
func roll_effect_chance() -> bool:
	if effect_chance <= 0:
		return true  # Always applies
	return randi() % 100 < effect_chance


## Get effective PP after PP Ups (max 1.6x base PP)
func get_max_pp_with_ups(pp_ups: int) -> int:
	var bonus := mini(pp_ups, 3)  # Max 3 PP Ups
	return pp + (pp * bonus / 5)  # Each PP Up adds 20% of base


## Create a new move instance with full data
static func create(
	p_id: String,
	p_name: String,
	p_type: int,
	p_category: Category,
	p_power: int,
	p_accuracy: int,
	p_pp: int,
	p_effect: Effect = Effect.NONE,
	p_effect_chance: int = 0
) -> MoveData:
	var move := MoveData.new()
	move.id = p_id
	move.display_name = p_name
	move.type = p_type
	move.category = p_category
	move.power = p_power
	move.accuracy = p_accuracy
	move.pp = p_pp
	move.max_pp = p_pp + (p_pp * 3 / 5)  # Max with 3 PP Ups
	move.effect = p_effect
	move.effect_chance = p_effect_chance
	
	# Status moves don't make contact
	if p_category == Category.STATUS:
		move.makes_contact = false
	
	return move


## Serialize to dictionary for saving
func to_dict() -> Dictionary:
	return {
		"id": id,
		"display_name": display_name,
		"description": description,
		"type": type,
		"category": category,
		"power": power,
		"accuracy": accuracy,
		"pp": pp,
		"priority": priority,
		"effect": effect,
		"effect_chance": effect_chance,
		"is_hm": is_hm,
		"is_tm": is_tm,
		"field_effect": field_effect
	}


## Deserialize from dictionary
static func from_dict(data: Dictionary) -> MoveData:
	var move := MoveData.new()
	move.id = data.get("id", "")
	move.display_name = data.get("display_name", "")
	move.description = data.get("description", "")
	move.type = data.get("type", 0)
	move.category = data.get("category", Category.PHYSICAL)
	move.power = data.get("power", 0)
	move.accuracy = data.get("accuracy", 100)
	move.pp = data.get("pp", 10)
	move.max_pp = move.pp + (move.pp * 3 / 5)
	move.priority = data.get("priority", 0)
	move.effect = data.get("effect", Effect.NONE)
	move.effect_chance = data.get("effect_chance", 0)
	move.is_hm = data.get("is_hm", false)
	move.is_tm = data.get("is_tm", false)
	move.field_effect = data.get("field_effect", Effect.NONE)
	return move
