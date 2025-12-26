class_name BattleCalculator
extends RefCounted
## BattleCalculator - Pokemon damage and battle calculations
## Implements Gen 2-style formulas for damage, accuracy, critical hits, etc.

# Critical hit rates by stage (Gen 2)
const CRIT_RATES := [17, 8, 4, 3, 2]  # Denominator for 1/N chance

# Stat stage multipliers (index 0 = -6, index 6 = 0, index 12 = +6)
const STAT_MULTIPLIERS := [
	2.0/8.0, 2.0/7.0, 2.0/6.0, 2.0/5.0, 2.0/4.0, 2.0/3.0,  # -6 to -1
	2.0/2.0,  # 0 (neutral)
	3.0/2.0, 4.0/2.0, 5.0/2.0, 6.0/2.0, 7.0/2.0, 8.0/2.0   # +1 to +6
]

# Accuracy/evasion multipliers
const ACC_MULTIPLIERS := [
	3.0/9.0, 3.0/8.0, 3.0/7.0, 3.0/6.0, 3.0/5.0, 3.0/4.0,  # -6 to -1
	3.0/3.0,  # 0 (neutral)
	4.0/3.0, 5.0/3.0, 6.0/3.0, 7.0/3.0, 8.0/3.0, 9.0/3.0   # +1 to +6
]

# Status effect damage
const BURN_DAMAGE_DIVISOR := 8      # 1/8 max HP per turn
const POISON_DAMAGE_DIVISOR := 8    # 1/8 max HP per turn
const TOXIC_DAMAGE_START := 16      # Starts at 1/16, increases


## Calculate damage for an attack
## Returns dictionary with {damage: int, critical: bool, effectiveness: float, type_message: String}
static func calculate_damage(
	attacker: Pokemon,
	defender: Pokemon, 
	move: MoveData,
	is_critical: bool = false
) -> Dictionary:
	var result := {
		"damage": 0,
		"critical": is_critical,
		"effectiveness": 1.0,
		"type_message": ""
	}
	
	# Status moves don't deal damage
	if move.category == MoveData.Category.STATUS:
		return result
	
	# Fixed damage moves
	if move.effect == MoveData.Effect.FIXED_DAMAGE:
		result.damage = move.fixed_damage if move.fixed_damage > 0 else attacker.level
		return result
	
	# Super Fang - half current HP
	if move.effect == MoveData.Effect.SUPER_FANG:
		result.damage = maxi(1, defender.current_hp / 2)
		return result
	
	# OHKO moves
	if move.effect == MoveData.Effect.ONE_HIT_KO:
		result.damage = defender.current_hp
		return result
	
	# Get attack and defense stats
	var attack_stat: int
	var defense_stat: int
	
	if move.category == MoveData.Category.PHYSICAL:
		attack_stat = attacker.get_effective_stat("attack")
		defense_stat = defender.get_effective_stat("defense")
	else:  # Special
		attack_stat = attacker.get_effective_stat("sp_attack")
		defense_stat = defender.get_effective_stat("sp_defense")
	
	# Critical hits ignore negative attack stages and positive defense stages
	if is_critical:
		if attacker.stage_attack < 0:
			attack_stat = attacker.max_attack if move.category == MoveData.Category.PHYSICAL else attacker.max_sp_attack
		if defender.stage_defense > 0:
			defense_stat = defender.max_defense if move.category == MoveData.Category.PHYSICAL else defender.max_sp_defense
	
	# Burn halves physical attack
	if attacker.status == Pokemon.Status.BURN and move.category == MoveData.Category.PHYSICAL:
		attack_stat = attack_stat / 2
	
	# Gen 2 Damage Formula:
	# ((2 * Level / 5 + 2) * Power * Attack / Defense / 50 + 2) * Modifiers
	var level := attacker.level
	var power := move.power
	
	var base_damage := floori(floori(floori(2.0 * level / 5.0 + 2.0) * power * attack_stat / defense_stat) / 50.0) + 2
	
	# Apply modifiers
	var modifier := 1.0
	
	# Critical hit (2x damage in Gen 2)
	if is_critical:
		modifier *= 2.0
	
	# STAB (Same Type Attack Bonus)
	var attacker_species := attacker.get_species()
	if attacker_species and attacker_species.has_type(move.type):
		modifier *= 1.5
	
	# Type effectiveness
	var defender_species := defender.get_species()
	if defender_species:
		var defender_types := defender_species.get_types()
		var effectiveness := TypeChart.get_effectiveness_against(move.type, defender_types)
		result.effectiveness = effectiveness
		modifier *= effectiveness
		
		if effectiveness == 0:
			result.type_message = "immune"
		elif effectiveness < 1.0:
			result.type_message = "not_very_effective"
		elif effectiveness > 1.0:
			result.type_message = "super_effective"
	
	# Weather effects would go here
	
	# Random factor (85-100% in Gen 2)
	var random_factor := randf_range(0.85, 1.0)
	modifier *= random_factor
	
	# Calculate final damage
	result.damage = maxi(1, floori(base_damage * modifier))
	
	return result


## Check if an attack hits
static func check_accuracy(
	attacker: Pokemon,
	defender: Pokemon,
	move: MoveData
) -> bool:
	# Moves with 0 accuracy always hit (e.g., Swift, Aerial Ace)
	if move.accuracy == 0:
		return true
	
	# Accuracy formula: MoveAccuracy * AccuracyStage / EvasionStage
	var accuracy_stage := clampi(attacker.stage_accuracy + 6, 0, 12)
	var evasion_stage := clampi(defender.stage_evasion + 6, 0, 12)
	
	var stage_modifier: float = ACC_MULTIPLIERS[accuracy_stage] / ACC_MULTIPLIERS[evasion_stage]
	var final_accuracy: float = move.accuracy * stage_modifier
	
	var roll: int = randi() % 100
	return roll < final_accuracy


## Check for critical hit
static func check_critical(attacker: Pokemon, move: MoveData) -> bool:
	var crit_stage := 0
	
	# High crit moves add +1 stage
	# Focus Energy adds +1 stage
	# Specific items/abilities would add more
	
	crit_stage = clampi(crit_stage, 0, CRIT_RATES.size() - 1)
	var crit_rate: int = CRIT_RATES[crit_stage]
	
	var roll: int = randi() % crit_rate
	return roll == 0


## Calculate experience gained from defeating a Pokemon
static func calculate_exp_gain(
	winner: Pokemon,
	loser: Pokemon,
	is_wild: bool,
	participants_count: int = 1
) -> int:
	var loser_species := loser.get_species()
	if loser_species == null:
		return 0
	
	# Gen 2 EXP formula:
	# (a * b * L) / (7 * s)
	# a = 1.5 if trainer battle, 1 if wild
	# b = base exp yield of defeated Pokemon
	# L = level of defeated Pokemon
	# s = number of Pokemon that participated
	
	var a := 1.0 if is_wild else 1.5
	var b := loser_species.base_exp
	var L := loser.level
	var s := maxi(1, participants_count)
	
	var exp := int(a * b * L / (7.0 * s))
	
	# Lucky Egg, traded Pokemon bonuses would go here
	
	return maxi(1, exp)


## Calculate catch rate for a wild Pokemon
static func calculate_catch_rate(
	pokemon: Pokemon,
	ball_modifier: float = 1.0
) -> int:
	var species := pokemon.get_species()
	if species == null:
		return 0
	
	# Gen 2 catch formula
	# a = (3 * MaxHP - 2 * CurrentHP) * CatchRate * BallMod / (3 * MaxHP) * StatusMod
	
	var max_hp := pokemon.max_hp
	var current_hp := pokemon.current_hp
	var catch_rate := species.catch_rate
	
	var hp_factor := (3.0 * max_hp - 2.0 * current_hp) / (3.0 * max_hp)
	var status_mod := 1.0
	
	# Status conditions increase catch rate
	match pokemon.status:
		Pokemon.Status.SLEEP, Pokemon.Status.FREEZE:
			status_mod = 2.0
		Pokemon.Status.PARALYSIS, Pokemon.Status.BURN, Pokemon.Status.POISON, Pokemon.Status.BADLY_POISONED:
			status_mod = 1.5
	
	var a := hp_factor * catch_rate * ball_modifier * status_mod
	
	return clampi(int(a), 0, 255)


## Calculate shake probability for pokeball
static func calculate_shake_chance(catch_rate: int) -> int:
	# b = 65536 / sqrt(sqrt(255 / a))
	if catch_rate >= 255:
		return 65536  # Guaranteed catch
	
	var divisor := 255.0 / float(catch_rate)
	var b := 65536.0 / sqrt(sqrt(divisor))
	
	return int(b)


## Simulate pokeball throw
## Returns number of shakes (0-3), 4 = caught
static func throw_pokeball(pokemon: Pokemon, ball_modifier: float = 1.0) -> int:
	var catch_rate := calculate_catch_rate(pokemon, ball_modifier)
	
	# If catch rate >= 255, automatic catch
	if catch_rate >= 255:
		return 4
	
	var shake_chance := calculate_shake_chance(catch_rate)
	
	# Need 4 successful shake checks to catch
	for i in range(4):
		var roll := randi() % 65536
		if roll >= shake_chance:
			return i  # Failed on shake i
	
	return 4  # Caught!


## Calculate flee chance for wild battle
static func calculate_flee_chance(player_pokemon: Pokemon, wild_pokemon: Pokemon, attempts: int) -> bool:
	# Speed-based flee formula
	# F = (PlayerSpeed * 128 / WildSpeed) + 30 * Attempts
	
	var player_speed := player_pokemon.get_effective_stat("speed")
	var wild_speed := wild_pokemon.get_effective_stat("speed")
	
	if wild_speed == 0:
		wild_speed = 1
	
	var f := (player_speed * 128 / wild_speed) + 30 * attempts
	
	if f >= 255:
		return true
	
	var roll := randi() % 256
	return roll < f


## Apply end-of-turn effects (poison, burn, etc.)
static func apply_end_of_turn_damage(pokemon: Pokemon) -> int:
	var damage := 0
	
	match pokemon.status:
		Pokemon.Status.BURN:
			damage = maxi(1, pokemon.max_hp / BURN_DAMAGE_DIVISOR)
		Pokemon.Status.POISON:
			damage = maxi(1, pokemon.max_hp / POISON_DAMAGE_DIVISOR)
		Pokemon.Status.BADLY_POISONED:
			# Toxic damage increases each turn
			pokemon.status_turns += 1
			var toxic_mult := pokemon.status_turns
			damage = maxi(1, pokemon.max_hp * toxic_mult / 16)
	
	return damage


## Check if a Pokemon can move this turn
static func can_move_this_turn(pokemon: Pokemon) -> Dictionary:
	var result := {
		"can_move": true,
		"message": ""
	}
	
	match pokemon.status:
		Pokemon.Status.FREEZE:
			# 20% chance to thaw
			if randi() % 5 == 0:
				pokemon.status = Pokemon.Status.NONE
				result.message = "thawed"
			else:
				result.can_move = false
				result.message = "frozen"
		
		Pokemon.Status.SLEEP:
			if pokemon.status_turns <= 0:
				pokemon.status = Pokemon.Status.NONE
				result.message = "woke_up"
			else:
				pokemon.status_turns -= 1
				result.can_move = false
				result.message = "asleep"
		
		Pokemon.Status.PARALYSIS:
			# 25% chance to be fully paralyzed
			if randi() % 4 == 0:
				result.can_move = false
				result.message = "paralyzed"
	
	# Check volatile statuses
	if Pokemon.VolatileStatus.CONFUSION in pokemon.volatile_statuses:
		# Confusion check
		var conf_turns: int = pokemon.volatile_data.get("confusion_turns", 0)
		if conf_turns <= 0:
			pokemon.volatile_statuses.erase(Pokemon.VolatileStatus.CONFUSION)
			result.message = "snapped_out"
		else:
			pokemon.volatile_data["confusion_turns"] = conf_turns - 1
			# 50% chance to hurt self
			if randi() % 2 == 0:
				result.can_move = false
				result.message = "confused"
	
	if Pokemon.VolatileStatus.FLINCH in pokemon.volatile_statuses:
		result.can_move = false
		result.message = "flinched"
		# Flinch is consumed
		pokemon.volatile_statuses.erase(Pokemon.VolatileStatus.FLINCH)
	
	return result


## Apply stat change from a move
static func apply_stat_change(pokemon: Pokemon, stat: String, stages: int) -> int:
	return pokemon.modify_stage(stat, stages)


## Get stat name for display
static func get_stat_display_name(stat: String) -> String:
	match stat:
		"attack": return "Attack"
		"defense": return "Defense"
		"speed": return "Speed"
		"sp_attack": return "Sp. Atk"
		"sp_defense": return "Sp. Def"
		"accuracy": return "Accuracy"
		"evasion": return "Evasion"
		_: return stat.capitalize()
