extends RefCounted

# Battle-transient state: stat stages, the BRN/PSN/PAR/SLP/FRZ status model, and
# volatile effects (confusion, infatuation, partial trap, move locks, protect).
# Pure rules only: callers pass mon dictionaries and an injected rng.
const STATUSES: PackedStringArray = ["BRN", "PSN", "PAR", "SLP", "FRZ"]
const STAT_KEYS: PackedStringArray = ["atk", "def", "sat", "sdf", "spe", "accuracy", "evasion"]
const COMBAT_STAT_KEYS: PackedStringArray = ["atk", "def", "sat", "sdf", "spe"]
# Battle-only mon keys wiped on switch/battle end and stripped from loaded saves.
const VOLATILE_KEYS: PackedStringArray = ["stages", "confusion_turns", "infatuated", "trap_turns", "rampage_turns",
	"rampage_move", "encore_turns", "encored_move", "protect_active", "last_move_id", "last_move_effect", "fury_streak"]
const STAGE_STAT_KEYS := {"ATTACK": "atk", "DEFENSE": "def", "SP_ATK": "sat", "SP_DEF": "sdf", "SPEED": "spe", "ACCURACY": "accuracy", "EVASION": "evasion", "ALL": "all"}
const MIN_STAGE := -6
const MAX_STAGE := 6
const PARALYSIS_SPEED_FACTOR := 0.25
const PARALYSIS_BLOCK_CHANCE := 0.25
const FREEZE_THAW_CHANCE := 0.2
const POISON_DAMAGE_DIVISOR := 8
const BURN_DAMAGE_DIVISOR := 16
const MIN_SLEEP_TURNS := 1
const MAX_SLEEP_TURNS := 3
const MIN_CONFUSION_TURNS := 2
const MAX_CONFUSION_TURNS := 5
const CONFUSION_SELF_HIT_CHANCE := 0.33
const CONFUSION_SELF_HIT_POWER := 40
const INFATUATION_BLOCK_CHANCE := 0.5
const MIN_TRAP_TURNS := 2
const MAX_TRAP_TURNS := 5
const TRAP_DAMAGE_DIVISOR := 16
const MIN_RAMPAGE_TURNS := 2
const MAX_RAMPAGE_TURNS := 3
const ENCORE_TURNS := 3
const FURY_MAX_STREAK := 2
const HEAL_FRACTION := 0.5

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

# Parses EFFECT_*_UP/DOWN(_2)(_HIT) into {"stat", "stages", "on_hit"}; {} otherwise.
static func parse_stage_effect(effect: String) -> Dictionary:
	if not effect.begins_with("EFFECT_"):
		return {}
	var body = effect.substr(7)
	var on_hit = body.ends_with("_HIT")
	if on_hit:
		body = body.substr(0, body.length() - 4)
	var stages = 1
	if body.ends_with("_2"):
		stages = 2
		body = body.substr(0, body.length() - 2)
	var direction = 0
	if body.ends_with("_UP"):
		direction = 1
		body = body.substr(0, body.length() - 3)
	elif body.ends_with("_DOWN"):
		direction = -1
		body = body.substr(0, body.length() - 5)
	if direction == 0 or not STAGE_STAT_KEYS.has(body):
		return {}
	return {"stat": STAGE_STAT_KEYS[body], "stages": stages * direction, "on_hit": on_hit}

func ensure_stages(mon: Dictionary) -> Dictionary:
	var stages = mon.get("stages", {})
	if stages is not Dictionary:
		stages = {}
	for key in STAT_KEYS:
		stages[key] = clampi(int(stages.get(key, 0)), MIN_STAGE, MAX_STAGE)
	mon["stages"] = stages
	return stages

func reset_stages(mon: Dictionary) -> void:
	for key in VOLATILE_KEYS:
		mon.erase(key)

func change_stage(mon: Dictionary, stat_key: String, delta: int) -> Dictionary:
	if not STAT_KEYS.has(stat_key):
		return {"stat": stat_key, "delta_applied": 0, "new_stage": 0}
	var stages = ensure_stages(mon)
	var old_stage = int(stages.get(stat_key, 0))
	var new_stage = clampi(old_stage + delta, MIN_STAGE, MAX_STAGE)
	stages[stat_key] = new_stage
	return {"stat": stat_key, "delta_applied": new_stage - old_stage, "new_stage": new_stage}

# Applies a parsed stage effect; positive stages target the attacker, negative the defender.
func apply_stage_change(attacker: Dictionary, defender: Dictionary, stage_effect: Dictionary) -> Array:
	var stages = int(stage_effect.get("stages", 0))
	var target_mon = attacker if stages > 0 else defender
	var target_side = "attacker" if stages > 0 else "defender"
	var stat_key = str(stage_effect.get("stat", ""))
	var keys: PackedStringArray = COMBAT_STAT_KEYS if stat_key == "all" else PackedStringArray([stat_key])
	var changes: Array = []
	for key in keys:
		var change = change_stage(target_mon, key, stages)
		change["target"] = target_side
		change["stages"] = stages
		changes.append(change)
	return changes

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

# End-of-round cleanup: status damage, partial-trap damage, protect expiry.
func apply_end_of_turn_status(mon: Dictionary) -> Dictionary:
	var result = {"status": str(mon.get("status", "")), "damage": 0, "fainted": false,
		"trap_damage": 0, "trap_active": false}
	mon.erase("protect_active")
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
	if int(mon.get("trap_turns", 0)) > 0 and int(mon.get("current_hp", 0)) > 0:
		var trap_damage = maxi(1, int(floor(float(max_hp) / TRAP_DAMAGE_DIVISOR)))
		mon["current_hp"] = maxi(0, int(mon.get("current_hp", 0)) - trap_damage)
		mon["trap_turns"] = int(mon.get("trap_turns", 0)) - 1
		result["trap_damage"] = trap_damage
		result["trap_active"] = int(mon.get("trap_turns", 0)) > 0
		result["damage"] = int(result.get("damage", 0)) + trap_damage
	result["fainted"] = int(mon.get("current_hp", 0)) <= 0
	return result

func inflict_confusion(mon: Dictionary, rng: RandomNumberGenerator) -> bool:
	if int(mon.get("current_hp", 0)) <= 0 or int(mon.get("confusion_turns", 0)) > 0:
		return false
	mon["confusion_turns"] = rng.randi_range(MIN_CONFUSION_TURNS, MAX_CONFUSION_TURNS)
	return true

# Pre-move volatile gates: confusion ticks down per attempted move and can force a
# self-hit; infatuation can immobilize. {"snapped_out", "hurt_self", "blocked_by"}.
func check_volatile_gates(mon: Dictionary, rng: RandomNumberGenerator) -> Dictionary:
	var result = {"snapped_out": false, "hurt_self": false, "blocked_by": ""}
	var turns = int(mon.get("confusion_turns", 0))
	if turns > 0:
		mon["confusion_turns"] = turns - 1
		if turns - 1 <= 0:
			result["snapped_out"] = true
		elif rng.randf() < CONFUSION_SELF_HIT_CHANCE:
			result["hurt_self"] = true
			return result
	if bool(mon.get("infatuated", false)) and rng.randf() < INFATUATION_BLOCK_CHANCE:
		result["blocked_by"] = "INFATUATION"
	return result

# Confusion self-hit: 40-power typeless physical vs own defense. Returns the damage.
func confusion_self_hit(mon: Dictionary, rng: RandomNumberGenerator) -> int:
	var level = int(mon.get("level", 1))
	var base = int(floor((floor(2.0 * level / 5.0 + 2.0) * CONFUSION_SELF_HIT_POWER
		* effective_stat(mon, "atk") / effective_stat(mon, "def")) / 50.0)) + 2
	var damage = maxi(1, int(floor(float(base) * rng.randf_range(0.85, 1.0))))
	mon["current_hp"] = maxi(0, int(mon.get("current_hp", 1)) - damage)
	return damage

# Attract needs opposite genders; genderless (or unknown) mons are immune both ways.
func try_infatuate(attacker: Dictionary, defender: Dictionary) -> bool:
	if int(defender.get("current_hp", 0)) <= 0 or bool(defender.get("infatuated", false)):
		return false
	var genders = [str(attacker.get("gender", "")), str(defender.get("gender", ""))]
	if not genders.has("male") or not genders.has("female"):
		return false
	defender["infatuated"] = true
	return true

func apply_trap(mon: Dictionary, rng: RandomNumberGenerator) -> bool:
	if int(mon.get("current_hp", 0)) <= 0 or int(mon.get("trap_turns", 0)) > 0:
		return false
	mon["trap_turns"] = rng.randi_range(MIN_TRAP_TURNS, MAX_TRAP_TURNS)
	return true

# True while a partial trap holds the mon; runtime should refuse run-away then.
func is_trapped(mon: Dictionary) -> bool:
	return int(mon.get("trap_turns", 0)) > 0

# Protect fails when the mon's previous action was already EFFECT_PROTECT.
func try_protect(mon: Dictionary) -> bool:
	if str(mon.get("last_move_effect", "")) == "EFFECT_PROTECT":
		return false
	mon["protect_active"] = true
	return true

func is_protected(mon: Dictionary) -> bool:
	return bool(mon.get("protect_active", false))

# Returns the move the target must repeat for ENCORE_TURNS, or "" when it cannot apply.
func try_encore(mon: Dictionary) -> String:
	var last_move = str(mon.get("last_move_id", ""))
	if last_move.is_empty() or int(mon.get("encore_turns", 0)) > 0 or int(mon.get("current_hp", 0)) <= 0:
		return ""
	mon["encore_turns"] = ENCORE_TURNS
	mon["encored_move"] = last_move
	return last_move

# Active forced move, if any; a rampage lock outranks an encore lock.
func forced_move_id(mon: Dictionary) -> String:
	if int(mon.get("rampage_turns", 0)) > 0:
		return str(mon.get("rampage_move", ""))
	if int(mon.get("encore_turns", 0)) > 0:
		return str(mon.get("encored_move", ""))
	return ""

func clear_move_locks(mon: Dictionary) -> void:
	mon.erase("rampage_turns")
	mon.erase("rampage_move")
	mon.erase("encore_turns")
	mon.erase("encored_move")

# Fury Cutter scaling: x1, x2, x4 by consecutive-hit streak.
func fury_multiplier(mon: Dictionary) -> float:
	return float(1 << clampi(int(mon.get("fury_streak", 0)), 0, FURY_MAX_STREAK))

# Bookkeeping after a mon really used a move: last-move memory, fury streaks, rampage
# start/countdown (self-confuse when it ends), and encore countdown.
func record_move_use(mon: Dictionary, move_id: String, effect: String, hit: bool, rng: RandomNumberGenerator) -> Dictionary:
	var report = {"self_confused": false, "fury_streak": 0}
	mon["last_move_id"] = move_id
	mon["last_move_effect"] = effect
	if effect == "EFFECT_FURY_CUTTER":
		mon["fury_streak"] = clampi(int(mon.get("fury_streak", 0)) + 1, 0, FURY_MAX_STREAK) if hit else 0
	else:
		mon["fury_streak"] = 0
	report["fury_streak"] = int(mon.get("fury_streak", 0))
	if effect == "EFFECT_RAMPAGE" and hit and int(mon.get("rampage_turns", 0)) <= 0:
		mon["rampage_turns"] = rng.randi_range(MIN_RAMPAGE_TURNS, MAX_RAMPAGE_TURNS)
		mon["rampage_move"] = move_id
	if int(mon.get("encore_turns", 0)) > 0:
		mon["encore_turns"] = int(mon.get("encore_turns", 0)) - 1
		if int(mon.get("encore_turns", 0)) <= 0:
			mon.erase("encored_move")
	if int(mon.get("rampage_turns", 0)) > 0 and move_id == str(mon.get("rampage_move", "")):
		mon["rampage_turns"] = int(mon.get("rampage_turns", 0)) - 1
		if int(mon.get("rampage_turns", 0)) <= 0:
			mon.erase("rampage_move")
			report["self_confused"] = inflict_confusion(mon, rng)
	return report

# OHKO: instant faint on hit; fails (-1) when the user is lower-level than the target.
func apply_ohko(attacker: Dictionary, defender: Dictionary) -> int:
	if int(attacker.get("level", 1)) < int(defender.get("level", 1)):
		return -1
	var damage = maxi(0, int(defender.get("current_hp", 1)))
	defender["current_hp"] = 0
	return damage

# EFFECT_HEAL: half of max HP; 0 means the move failed (already at full HP).
func apply_heal_move(mon: Dictionary) -> int:
	var max_hp = maxi(1, int(mon.get("max_hp", 1)))
	var missing = max_hp - int(mon.get("current_hp", max_hp))
	if missing <= 0:
		return 0
	var restored = mini(missing, maxi(1, int(floor(float(max_hp) * HEAL_FRACTION))))
	mon["current_hp"] = int(mon.get("current_hp", max_hp)) + restored
	return restored
