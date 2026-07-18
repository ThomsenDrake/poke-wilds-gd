extends RefCounted

# Battle-transient stat stages and the BRN/PSN/PAR/SLP/FRZ status model.
# Pure rules only: callers pass mon dictionaries and an injected rng.
const STATUSES: PackedStringArray = ["BRN", "PSN", "PAR", "SLP", "FRZ"]
const STAT_KEYS: PackedStringArray = ["atk", "def", "sat", "sdf", "spe", "accuracy", "evasion"]
const COMBAT_STAT_KEYS: PackedStringArray = ["atk", "def", "sat", "sdf", "spe"]
const MIN_STAGE := -6
const MAX_STAGE := 6
const PARALYSIS_SPEED_FACTOR := 0.25
const PARALYSIS_BLOCK_CHANCE := 0.25
const FREEZE_THAW_CHANCE := 0.2
const POISON_DAMAGE_DIVISOR := 8
const BURN_DAMAGE_DIVISOR := 16
const MIN_SLEEP_TURNS := 1
const MAX_SLEEP_TURNS := 3


static func is_valid_status(status: String) -> bool:
	return STATUSES.has(status.strip_edges().to_upper())


static func stat_stage_multiplier(stage: int) -> float:
	var clamped = clampi(stage, MIN_STAGE, MAX_STAGE)
	if clamped >= 0:
		return (2.0 + clamped) / 2.0
	return 2.0 / (2.0 - clamped)


static func accuracy_stage_multiplier(stage: int) -> float:
	var clamped = clampi(stage, MIN_STAGE, MAX_STAGE)
	if clamped >= 0:
		return (3.0 + clamped) / 3.0
	return 3.0 / (3.0 - clamped)


func ensure_stages(mon: Dictionary) -> Dictionary:
	var stages = mon.get("stages", {})
	if stages is not Dictionary:
		stages = {}
	for key in STAT_KEYS:
		stages[key] = clampi(int(stages.get(key, 0)), MIN_STAGE, MAX_STAGE)
	mon["stages"] = stages
	return stages


func reset_stages(mon: Dictionary) -> void:
	mon.erase("stages")


func change_stage(mon: Dictionary, stat_key: String, delta: int) -> Dictionary:
	if not STAT_KEYS.has(stat_key):
		return {"stat": stat_key, "delta_applied": 0, "new_stage": 0}
	var stages = ensure_stages(mon)
	var old_stage = int(stages.get(stat_key, 0))
	var new_stage = clampi(old_stage + delta, MIN_STAGE, MAX_STAGE)
	stages[stat_key] = new_stage
	return {"stat": stat_key, "delta_applied": new_stage - old_stage, "new_stage": new_stage}


func effective_stat(mon: Dictionary, stat_key: String) -> int:
	var stats = mon.get("stats", {})
	var base = 1
	if stats is Dictionary:
		base = maxi(1, int(stats.get(stat_key, 1)))
	var stage = int(ensure_stages(mon).get(stat_key, 0))
	var value = base
	if stat_key == "accuracy" or stat_key == "evasion":
		value = int(floor(base * accuracy_stage_multiplier(stage)))
	else:
		value = int(floor(base * stat_stage_multiplier(stage)))
	if stat_key == "spe" and str(mon.get("status", "")) == "PAR":
		value = int(floor(value * PARALYSIS_SPEED_FACTOR))
	return maxi(1, value)


func inflict_status(mon: Dictionary, status: String, rng: RandomNumberGenerator) -> bool:
	if not is_valid_status(status):
		return false
	if int(mon.get("current_hp", 0)) <= 0:
		return false
	if not str(mon.get("status", "")).is_empty():
		return false
	mon["status"] = status
	mon["sleep_turns"] = rng.randi_range(MIN_SLEEP_TURNS, MAX_SLEEP_TURNS) if status == "SLP" else 0
	return true


func cure_status(mon: Dictionary) -> void:
	mon["status"] = ""
	mon["sleep_turns"] = 0


func check_pre_move_status(mon: Dictionary, rng: RandomNumberGenerator) -> Dictionary:
	var result = {"can_move": true, "status": "", "woke_up": false, "thawed": false}
	match str(mon.get("status", "")):
		"PAR":
			if rng.randf() < PARALYSIS_BLOCK_CHANCE:
				result["can_move"] = false
				result["status"] = "PAR"
		"SLP":
			var turns = int(mon.get("sleep_turns", 0))
			if turns > 0:
				mon["sleep_turns"] = turns - 1
				result["can_move"] = false
				result["status"] = "SLP"
			else:
				cure_status(mon)
				result["woke_up"] = true
		"FRZ":
			if rng.randf() < FREEZE_THAW_CHANCE:
				cure_status(mon)
				result["thawed"] = true
			else:
				result["can_move"] = false
				result["status"] = "FRZ"
	return result


func apply_end_of_turn_status(mon: Dictionary) -> Dictionary:
	var result = {"status": str(mon.get("status", "")), "damage": 0, "fainted": false}
	var max_hp = maxi(1, int(mon.get("max_hp", 1)))
	var damage = 0
	match result["status"]:
		"PSN":
			damage = maxi(1, int(floor(float(max_hp) / POISON_DAMAGE_DIVISOR)))
		"BRN":
			damage = maxi(1, int(floor(float(max_hp) / BURN_DAMAGE_DIVISOR)))
	if damage > 0 and int(mon.get("current_hp", 0)) > 0:
		mon["current_hp"] = maxi(0, int(mon.get("current_hp", 0)) - damage)
		result["damage"] = damage
		result["fainted"] = int(mon.get("current_hp", 0)) <= 0
	return result
