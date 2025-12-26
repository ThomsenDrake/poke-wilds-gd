@tool
class_name Pokemon
extends Resource
## Pokemon - Individual Pokemon instance
## Contains IVs, EVs, calculated stats, current HP, status, moves, and battle state

# Status conditions
enum Status {
	NONE,
	BURN,
	FREEZE,
	PARALYSIS,
	POISON,
	BADLY_POISONED,  # Toxic
	SLEEP
}

# Volatile status (cleared on switch/battle end)
enum VolatileStatus {
	NONE,
	CONFUSION,
	INFATUATION,
	FLINCH,
	LEECH_SEED,
	CURSE,
	NIGHTMARE,
	TRAPPED,         # Mean Look, Spider Web
	PERISH_SONG,
	ENCORE
}

# Reference to species data
@export var species_id: String = ""
var _species: PokemonSpecies = null

# Basic info
@export var nickname: String = ""
@export var level: int = 5
@export var experience: int = 0
@export var gender: String = "male"  # "male", "female", "none"
@export var is_shiny: bool = false
@export var is_egg: bool = false
@export var friendship: int = 70     # 0-255, base is species-dependent
@export var met_level: int = 5
@export var met_location: String = ""
@export var original_trainer: String = ""
@export var trainer_id: int = 0

# Individual Values (0-31, determined at catch/hatch)
@export var iv_hp: int = 0
@export var iv_attack: int = 0
@export var iv_defense: int = 0
@export var iv_speed: int = 0
@export var iv_sp_attack: int = 0
@export var iv_sp_defense: int = 0

# Effort Values (0-255 each, 510 total max)
@export var ev_hp: int = 0
@export var ev_attack: int = 0
@export var ev_defense: int = 0
@export var ev_speed: int = 0
@export var ev_sp_attack: int = 0
@export var ev_sp_defense: int = 0

# Calculated max stats (recalculated on level up)
var max_hp: int = 1
var max_attack: int = 1
var max_defense: int = 1
var max_speed: int = 1
var max_sp_attack: int = 1
var max_sp_defense: int = 1

# Current battle stats (can be modified by stat stages)
var current_hp: int = 1
var current_attack: int = 1
var current_defense: int = 1
var current_speed: int = 1
var current_sp_attack: int = 1
var current_sp_defense: int = 1

# Stat stages (-6 to +6, reset on switch)
var stage_attack: int = 0
var stage_defense: int = 0
var stage_speed: int = 0
var stage_sp_attack: int = 0
var stage_sp_defense: int = 0
var stage_accuracy: int = 0
var stage_evasion: int = 0

# Status conditions
@export var status: Status = Status.NONE
@export var status_turns: int = 0    # Turns remaining (for sleep, toxic counter)
var volatile_statuses: Array[VolatileStatus] = []
var volatile_data: Dictionary = {}   # Extra data (confusion turns, encore move, etc.)

# Moves (up to 4)
@export var move_ids: Array[String] = []
@export var move_pp: Array[int] = []       # Current PP for each move
@export var move_pp_ups: Array[int] = []   # PP Up count for each move (0-3)

# Held item
@export var held_item: String = ""

# Ability (if using abilities)
@export var ability: String = ""

# Pokerus
@export var has_pokerus: bool = false
@export var pokerus_days: int = 0


## Initialize a new Pokemon from species
static func create_wild(species: PokemonSpecies, p_level: int, p_shiny: bool = false) -> Pokemon:
	var pkmn := Pokemon.new()
	pkmn.species_id = species.id
	pkmn._species = species
	pkmn.level = p_level
	pkmn.is_shiny = p_shiny
	pkmn.gender = species.roll_gender()
	
	# Generate random IVs (0-31)
	pkmn.iv_hp = randi() % 32
	pkmn.iv_attack = randi() % 32
	pkmn.iv_defense = randi() % 32
	pkmn.iv_speed = randi() % 32
	pkmn.iv_sp_attack = randi() % 32
	pkmn.iv_sp_defense = randi() % 32
	
	# Calculate stats
	pkmn.recalculate_stats()
	pkmn.current_hp = pkmn.max_hp
	
	# Set default moves based on level
	var default_moves := species.get_default_moves(p_level)
	pkmn.move_ids.assign(default_moves)
	pkmn.move_pp.clear()
	pkmn.move_pp_ups.clear()
	for _i in range(default_moves.size()):
		pkmn.move_pp.append(10)  # Will be set properly when move data is loaded
		pkmn.move_pp_ups.append(0)
	
	# Set experience to match level
	pkmn.experience = species.exp_for_level(p_level)
	
	return pkmn


## Create a Pokemon egg
static func create_egg(species: PokemonSpecies, inherited_moves: Array[String] = []) -> Pokemon:
	var pkmn := Pokemon.new()
	pkmn.species_id = species.id
	pkmn._species = species
	pkmn.level = 1  # Will be level 1 when hatched
	pkmn.is_egg = true
	pkmn.gender = species.roll_gender()
	pkmn.is_shiny = GameManager.is_shiny_roll()
	
	# Generate IVs (breeding can pass some from parents, simplified here)
	pkmn.iv_hp = randi() % 32
	pkmn.iv_attack = randi() % 32
	pkmn.iv_defense = randi() % 32
	pkmn.iv_speed = randi() % 32
	pkmn.iv_sp_attack = randi() % 32
	pkmn.iv_sp_defense = randi() % 32
	
	# Egg moves + level 1 moves
	var moves: Array[String] = []
	for move in inherited_moves:
		if moves.size() < 4:
			moves.append(move)
	for move in species.get_moves_at_level(1):
		if move not in moves and moves.size() < 4:
			moves.append(move)
	pkmn.move_ids.assign(moves)
	
	return pkmn


## Get species data (lazy load)
func get_species() -> PokemonSpecies:
	if _species == null:
		# TODO: Load from SpeciesDatabase autoload
		push_warning("Species not loaded for: ", species_id)
	return _species


## Set species reference
func set_species(species: PokemonSpecies) -> void:
	_species = species
	species_id = species.id


## Recalculate max stats based on level, IVs, EVs, and base stats
## Uses Gen 3+ stat formulas (slightly different from Gen 2)
func recalculate_stats() -> void:
	var species := get_species()
	if species == null:
		return
	
	# HP formula: floor((2 * Base + IV + floor(EV/4)) * Level / 100) + Level + 10
	max_hp = _calc_hp_stat(species.base_hp, iv_hp, ev_hp)
	
	# Other stats: floor((floor((2 * Base + IV + floor(EV/4)) * Level / 100) + 5) * Nature)
	# Ignoring nature for now (would be 0.9, 1.0, or 1.1)
	max_attack = _calc_stat(species.base_attack, iv_attack, ev_attack)
	max_defense = _calc_stat(species.base_defense, iv_defense, ev_defense)
	max_speed = _calc_stat(species.base_speed, iv_speed, ev_speed)
	max_sp_attack = _calc_stat(species.base_sp_attack, iv_sp_attack, ev_sp_attack)
	max_sp_defense = _calc_stat(species.base_sp_defense, iv_sp_defense, ev_sp_defense)
	
	# Reset current stats to max
	current_attack = max_attack
	current_defense = max_defense
	current_speed = max_speed
	current_sp_attack = max_sp_attack
	current_sp_defense = max_sp_defense


func _calc_hp_stat(base: int, iv: int, ev: int) -> int:
	# Shedinja special case
	if species_id == "SHEDINJA":
		return 1
	return int(floori((2.0 * base + iv + floori(ev / 4.0)) * level / 100.0)) + level + 10


func _calc_stat(base: int, iv: int, ev: int) -> int:
	return int(floori((2.0 * base + iv + floori(ev / 4.0)) * level / 100.0)) + 5


## Apply stat stage modifier and return effective stat
func get_effective_stat(stat_name: String) -> int:
	var base_stat: int
	var stage: int
	
	match stat_name:
		"attack":
			base_stat = current_attack
			stage = stage_attack
		"defense":
			base_stat = current_defense
			stage = stage_defense
		"speed":
			base_stat = current_speed
			stage = stage_speed
		"sp_attack":
			base_stat = current_sp_attack
			stage = stage_sp_attack
		"sp_defense":
			base_stat = current_sp_defense
			stage = stage_sp_defense
		_:
			return 0
	
	return _apply_stage_multiplier(base_stat, stage)


## Get accuracy/evasion stage multiplier
func get_accuracy_multiplier() -> float:
	return _get_accuracy_stage_multiplier(stage_accuracy)


func get_evasion_multiplier() -> float:
	return _get_accuracy_stage_multiplier(stage_evasion)


func _apply_stage_multiplier(stat: int, stage: int) -> int:
	# Gen 2+ stat stage multipliers
	var multipliers := [2.0/8, 2.0/7, 2.0/6, 2.0/5, 2.0/4, 2.0/3, 2.0/2, 3.0/2, 4.0/2, 5.0/2, 6.0/2, 7.0/2, 8.0/2]
	var index := clampi(stage + 6, 0, 12)
	return int(stat * multipliers[index])


func _get_accuracy_stage_multiplier(stage: int) -> float:
	# Accuracy/evasion multipliers
	var multipliers := [3.0/9, 3.0/8, 3.0/7, 3.0/6, 3.0/5, 3.0/4, 3.0/3, 4.0/3, 5.0/3, 6.0/3, 7.0/3, 8.0/3, 9.0/3]
	var index := clampi(stage + 6, 0, 12)
	return multipliers[index]


## Modify a stat stage
func modify_stage(stat_name: String, change: int) -> int:
	var old_stage: int
	var new_stage: int
	
	match stat_name:
		"attack":
			old_stage = stage_attack
			stage_attack = clampi(stage_attack + change, -6, 6)
			new_stage = stage_attack
		"defense":
			old_stage = stage_defense
			stage_defense = clampi(stage_defense + change, -6, 6)
			new_stage = stage_defense
		"speed":
			old_stage = stage_speed
			stage_speed = clampi(stage_speed + change, -6, 6)
			new_stage = stage_speed
		"sp_attack":
			old_stage = stage_sp_attack
			stage_sp_attack = clampi(stage_sp_attack + change, -6, 6)
			new_stage = stage_sp_attack
		"sp_defense":
			old_stage = stage_sp_defense
			stage_sp_defense = clampi(stage_sp_defense + change, -6, 6)
			new_stage = stage_sp_defense
		"accuracy":
			old_stage = stage_accuracy
			stage_accuracy = clampi(stage_accuracy + change, -6, 6)
			new_stage = stage_accuracy
		"evasion":
			old_stage = stage_evasion
			stage_evasion = clampi(stage_evasion + change, -6, 6)
			new_stage = stage_evasion
		_:
			return 0
	
	return new_stage - old_stage  # Actual change (might be less at limits)


## Reset all stat stages (on switch out or battle end)
func reset_stages() -> void:
	stage_attack = 0
	stage_defense = 0
	stage_speed = 0
	stage_sp_attack = 0
	stage_sp_defense = 0
	stage_accuracy = 0
	stage_evasion = 0


## Clear volatile statuses (on switch out or battle end)
func clear_volatile_statuses() -> void:
	volatile_statuses.clear()
	volatile_data.clear()


## Take damage
func take_damage(amount: int) -> void:
	current_hp = maxi(0, current_hp - amount)


## Heal HP - returns actual amount healed
func heal(amount: int) -> int:
	var old_hp := current_hp
	current_hp = mini(max_hp, current_hp + amount)
	return current_hp - old_hp


## Fully heal (Pokemon Center, etc.)
func full_heal() -> void:
	current_hp = max_hp
	status = Status.NONE
	status_turns = 0
	clear_volatile_statuses()
	
	# Restore PP
	for i in range(move_pp.size()):
		move_pp[i] = _get_max_pp(i)


func _get_max_pp(move_index: int) -> int:
	# TODO: Look up move data to get actual max PP
	var base_pp := 10  # Default
	var ups := move_pp_ups[move_index] if move_index < move_pp_ups.size() else 0
	return base_pp + (base_pp * ups / 5)


## Check if fainted
func is_fainted() -> bool:
	return current_hp <= 0


## Check if can battle
func can_battle() -> bool:
	return not is_fainted() and not is_egg


## Gain experience and handle level ups
## Returns number of levels gained
func gain_experience(amount: int) -> int:
	if is_egg or level >= GameManager.MAX_LEVEL:
		return 0
	
	var species := get_species()
	if species == null:
		return 0
	
	experience += amount
	var levels_gained := 0
	
	# Check for level ups
	while level < GameManager.MAX_LEVEL:
		var exp_needed := species.exp_for_level(level + 1)
		if experience >= exp_needed:
			level += 1
			levels_gained += 1
			recalculate_stats()
			# Heal HP proportionally to the increase
			var hp_ratio := float(current_hp) / float(max_hp - 1) if max_hp > 1 else 1.0
			current_hp = int(max_hp * hp_ratio)
		else:
			break
	
	return levels_gained


## Get experience needed for next level
func exp_to_next_level() -> int:
	var species := get_species()
	if species == null or level >= GameManager.MAX_LEVEL:
		return 0
	return species.exp_for_level(level + 1) - experience


## Get display name (nickname or species name)
func get_display_name() -> String:
	if nickname != "":
		return nickname
	var species := get_species()
	if species:
		return species.display_name
	return species_id


## Get total IV sum (for hidden power, etc.)
func get_iv_total() -> int:
	return iv_hp + iv_attack + iv_defense + iv_speed + iv_sp_attack + iv_sp_defense


## Get total EV sum
func get_ev_total() -> int:
	return ev_hp + ev_attack + ev_defense + ev_speed + ev_sp_attack + ev_sp_defense


## Can still gain EVs?
func can_gain_evs() -> bool:
	return get_ev_total() < 510


## Add EVs from defeating a Pokemon
func add_evs(stat: String, amount: int) -> void:
	if not can_gain_evs():
		return
	
	var remaining := 510 - get_ev_total()
	amount = mini(amount, remaining)
	
	# Pokerus doubles EV gain
	if has_pokerus:
		amount *= 2
		amount = mini(amount, remaining)
	
	match stat:
		"hp":
			ev_hp = mini(255, ev_hp + amount)
		"attack":
			ev_attack = mini(255, ev_attack + amount)
		"defense":
			ev_defense = mini(255, ev_defense + amount)
		"speed":
			ev_speed = mini(255, ev_speed + amount)
		"sp_attack":
			ev_sp_attack = mini(255, ev_sp_attack + amount)
		"sp_defense":
			ev_sp_defense = mini(255, ev_sp_defense + amount)


## Serialize for saving
func to_dict() -> Dictionary:
	return {
		"species_id": species_id,
		"nickname": nickname,
		"level": level,
		"experience": experience,
		"gender": gender,
		"is_shiny": is_shiny,
		"is_egg": is_egg,
		"friendship": friendship,
		"met_level": met_level,
		"met_location": met_location,
		"original_trainer": original_trainer,
		"trainer_id": trainer_id,
		"ivs": {
			"hp": iv_hp, "attack": iv_attack, "defense": iv_defense,
			"speed": iv_speed, "sp_attack": iv_sp_attack, "sp_defense": iv_sp_defense
		},
		"evs": {
			"hp": ev_hp, "attack": ev_attack, "defense": ev_defense,
			"speed": ev_speed, "sp_attack": ev_sp_attack, "sp_defense": ev_sp_defense
		},
		"current_hp": current_hp,
		"status": status,
		"status_turns": status_turns,
		"move_ids": move_ids,
		"move_pp": move_pp,
		"move_pp_ups": move_pp_ups,
		"held_item": held_item,
		"ability": ability,
		"has_pokerus": has_pokerus,
		"pokerus_days": pokerus_days
	}


## Deserialize from save
static func from_dict(data: Dictionary) -> Pokemon:
	var pkmn := Pokemon.new()
	pkmn.species_id = data.get("species_id", "")
	pkmn.nickname = data.get("nickname", "")
	pkmn.level = data.get("level", 5)
	pkmn.experience = data.get("experience", 0)
	pkmn.gender = data.get("gender", "male")
	pkmn.is_shiny = data.get("is_shiny", false)
	pkmn.is_egg = data.get("is_egg", false)
	pkmn.friendship = data.get("friendship", 70)
	pkmn.met_level = data.get("met_level", 5)
	pkmn.met_location = data.get("met_location", "")
	pkmn.original_trainer = data.get("original_trainer", "")
	pkmn.trainer_id = data.get("trainer_id", 0)
	
	var ivs: Dictionary = data.get("ivs", {})
	pkmn.iv_hp = ivs.get("hp", 0)
	pkmn.iv_attack = ivs.get("attack", 0)
	pkmn.iv_defense = ivs.get("defense", 0)
	pkmn.iv_speed = ivs.get("speed", 0)
	pkmn.iv_sp_attack = ivs.get("sp_attack", 0)
	pkmn.iv_sp_defense = ivs.get("sp_defense", 0)
	
	var evs: Dictionary = data.get("evs", {})
	pkmn.ev_hp = evs.get("hp", 0)
	pkmn.ev_attack = evs.get("attack", 0)
	pkmn.ev_defense = evs.get("defense", 0)
	pkmn.ev_speed = evs.get("speed", 0)
	pkmn.ev_sp_attack = evs.get("sp_attack", 0)
	pkmn.ev_sp_defense = evs.get("sp_defense", 0)
	
	pkmn.current_hp = data.get("current_hp", 1)
	pkmn.status = data.get("status", Status.NONE)
	pkmn.status_turns = data.get("status_turns", 0)
	
	pkmn.move_ids.assign(data.get("move_ids", []))
	pkmn.move_pp.assign(data.get("move_pp", []))
	pkmn.move_pp_ups.assign(data.get("move_pp_ups", []))
	
	pkmn.held_item = data.get("held_item", "")
	pkmn.ability = data.get("ability", "")
	pkmn.has_pokerus = data.get("has_pokerus", false)
	pkmn.pokerus_days = data.get("pokerus_days", 0)
	
	# Recalculate stats (species needs to be set separately)
	# pkmn.recalculate_stats()
	
	return pkmn
