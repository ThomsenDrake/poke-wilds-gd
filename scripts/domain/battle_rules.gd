extends RefCounted

const TypeChart := preload("res://scripts/domain/type_chart.gd")
const BattleStatus := preload("res://scripts/domain/battle_status.gd")
const BattleText := preload("res://scripts/domain/battle_text.gd")

const CRIT_RATE := 1.0 / 24.0
const CRIT_MULTIPLIER := 1.5
const STAB_MULTIPLIER := 1.5
const RANDOM_FACTOR_MIN := 0.85
const BURN_ATTACK_FACTOR := 0.5
const DEFAULT_CATCH_RATE := 45
const RECOIL_DIVISOR := 4
const LEECH_DIVISOR := 2
const OHKO_EFFECT := "EFFECT_OHKO"
# Effects that target the user; the defender's protect never blocks them.
const SELF_TARGET_EFFECTS: PackedStringArray = ["EFFECT_HEAL", "EFFECT_PROTECT"]
const HIT_STATUS_EFFECTS := {"EFFECT_POISON_HIT": "PSN", "EFFECT_BURN_HIT": "BRN", "EFFECT_PARALYZE_HIT": "PAR", "EFFECT_SLEEP_HIT": "SLP", "EFFECT_FREEZE_HIT": "FRZ", "EFFECT_POISON_MULTI_HIT": "PSN", "EFFECT_FLAME_WHEEL": "BRN", "EFFECT_SACRED_FIRE": "BRN"}
const PURE_STATUS_EFFECTS := {"EFFECT_POISON": "PSN", "EFFECT_BURN": "BRN", "EFFECT_PARALYZE": "PAR", "EFFECT_SLEEP": "SLP"}
# Value 0 means "roll 2-5"; a positive value is a fixed hit count.
const MULTI_HIT_EFFECTS := {"EFFECT_MULTI_HIT": 0, "EFFECT_POISON_MULTI_HIT": 0, "EFFECT_DOUBLE_HIT": 2}

var _status = BattleStatus.new()

func apply_attack(attacker: Dictionary, defender: Dictionary, move: Dictionary, rng: RandomNumberGenerator) -> String:
	return str(execute_attack(attacker, defender, move, rng).get("message", ""))

func execute_attack(attacker: Dictionary, defender: Dictionary, move: Dictionary, rng: RandomNumberGenerator) -> Dictionary:
	var result = _new_attack_result(move)
	var effect = str(move.get("effect", "EFFECT_NORMAL_HIT"))
	result["priority"] = 1 if effect == "EFFECT_PRIORITY_HIT" else 0
	var gate = _status.check_pre_move_status(attacker, rng)
	result["woke_up"] = bool(gate.get("woke_up", false))
	result["thawed"] = bool(gate.get("thawed", false))
	var acted = false
	if not bool(gate.get("can_move", true)):
		result["blocked_by"] = str(gate.get("status", ""))
	else:
		move = _forced_move(attacker, move, result)
		effect = str(move.get("effect", "EFFECT_NORMAL_HIT"))
		var volatile = _status.check_volatile_gates(attacker, rng)
		result["snapped_out"] = bool(volatile.get("snapped_out", false))
		result["blocked_by"] = str(volatile.get("blocked_by", ""))
		if bool(volatile.get("hurt_self", false)):
			result["hurt_itself"] = true
			result["self_damage"] = _status.confusion_self_hit(attacker, rng)
			result["self_fainted"] = int(attacker.get("current_hp", 0)) <= 0
		elif result["blocked_by"].is_empty():
			acted = _resolve_move(attacker, defender, move, effect, rng, result)
	if acted:
		var usage = _status.record_move_use(attacker, str(move.get("move_id", "")), effect, bool(result.get("hit", false)), rng)
		result["self_confused"] = bool(usage.get("self_confused", false))
		result["fury_streak"] = int(usage.get("fury_streak", 0))
	result["message"] = BattleText.attack_message(result, str(attacker.get("name", "Pokemon")),
		str(defender.get("name", "Pokemon")), _move_display_name(move))
	return result

# Accuracy/protect gates plus move application; true when the move was really used.
func _resolve_move(attacker: Dictionary, defender: Dictionary, move: Dictionary, effect: String, rng: RandomNumberGenerator, result: Dictionary) -> bool:
	if _status.is_protected(defender) and not _targets_self(effect):
		result["protected_target"] = true
		return true
	if effect != "EFFECT_ALWAYS_HIT" and not _accuracy_check(attacker, defender, move, rng):
		return true
	result["hit"] = true
	if effect == OHKO_EFFECT:
		var ohko_damage = _status.apply_ohko(attacker, defender)
		result["ohko"] = ohko_damage >= 0
		result["failed"] = ohko_damage < 0
		result["damage"] = maxi(0, ohko_damage)
		result["fainted"] = ohko_damage >= 0
	elif int(move.get("power", 0)) <= 0:
		_apply_status_move(attacker, defender, effect, rng, result)
	else:
		if not _is_handled_damage_effect(effect):
			result["unhandled_effect"] = effect
		_apply_damage_move(attacker, defender, move, effect, rng, result)
	return true

func calculate_damage(attacker: Dictionary, defender: Dictionary, move: Dictionary, rng: RandomNumberGenerator, critical: bool = false) -> Dictionary:
	var power = int(move.get("power", 0))
	if power <= 0:
		return {"damage": 0, "effectiveness": 1.0, "stab": false}
	var category = str(move.get("category", "PHYSICAL"))
	var attack_key = "sat" if category == "SPECIAL" else "atk"
	var defense_key = "sdf" if category == "SPECIAL" else "def"
	var attack_stat = effective_stat(attacker, attack_key)
	var defense_stat = effective_stat(defender, defense_key)
	if category == "PHYSICAL" and str(attacker.get("status", "")) == "BRN":
		attack_stat = maxi(1, int(floor(attack_stat * BURN_ATTACK_FACTOR)))
	var move_type = str(move.get("type", "NORMAL"))
	var defender_types = defender.get("types", PackedStringArray(["NORMAL"]))
	if defender_types is not PackedStringArray:
		defender_types = PackedStringArray(["NORMAL"])
	var effectiveness = TypeChart.effectiveness(move_type, defender_types)
	if effectiveness <= 0.0:
		return {"damage": 0, "effectiveness": 0.0, "stab": false}
	var stab = _has_type(attacker, move_type)
	var level = int(attacker.get("level", 1))
	var base = int(floor((floor(2.0 * level / 5.0 + 2.0) * power * attack_stat / defense_stat) / 50.0)) + 2
	var damage = float(base)
	if stab:
		damage = floor(damage * STAB_MULTIPLIER)
	damage = floor(damage * effectiveness)
	if critical:
		damage = floor(damage * CRIT_MULTIPLIER)
	damage = floor(damage * rng.randf_range(RANDOM_FACTOR_MIN, 1.0))
	return {"damage": maxi(1, int(damage)), "effectiveness": effectiveness, "stab": stab}

func calculate_catch_chance(enemy_mon: Dictionary, ball_id: String = "POKE_BALL", catch_rate: int = -1) -> float:
	return float(_catch_context(enemy_mon, ball_id, catch_rate).get("probability", 0.0))

func attempt_capture(enemy_mon: Dictionary, ball_id: String, rng: RandomNumberGenerator, catch_rate: int = -1) -> Dictionary:
	var context = _catch_context(enemy_mon, ball_id, catch_rate)
	context["roll"] = rng.randf()
	context["success"] = float(context["roll"]) < float(context.get("probability", 0.0))
	return context

func choose_enemy_move_index(enemy_mon: Dictionary, rng: RandomNumberGenerator) -> int:
	var usable_indexes: Array = []
	for i in range(enemy_mon.get("moves", []).size()):
		var move = enemy_mon.get("moves", [])[i]
		if int(move.get("pp", 0)) > 0:
			usable_indexes.append(i)
	if usable_indexes.is_empty():
		return -1
	return int(usable_indexes[rng.randi_range(0, usable_indexes.size() - 1)])

func effective_stat(mon: Dictionary, stat_key: String) -> int:
	return _status.effective_stat(mon, stat_key)

func reset_stages(mon: Dictionary) -> void:
	_status.reset_stages(mon)

func apply_end_of_turn_status(mon: Dictionary) -> Dictionary:
	return _status.apply_end_of_turn_status(mon)

# True while a partial trap holds the mon; runtime should refuse run-away then.
func is_trapped(mon: Dictionary) -> bool:
	return _status.is_trapped(mon)

func _accuracy_check(attacker: Dictionary, defender: Dictionary, move: Dictionary, rng: RandomNumberGenerator) -> bool:
	var accuracy = float(move.get("accuracy", 100))
	var attacker_stages = _status.ensure_stages(attacker)
	var defender_stages = _status.ensure_stages(defender)
	var combined = clampi(int(attacker_stages.get("accuracy", 0)) - int(defender_stages.get("evasion", 0)), -6, 6)
	var chance = accuracy * BattleStatus.accuracy_stage_multiplier(combined)
	return rng.randf() * 100.0 < chance

func _forced_move(attacker: Dictionary, move: Dictionary, result: Dictionary) -> Dictionary:
	var forced_id = _status.forced_move_id(attacker)
	if forced_id.is_empty() or forced_id == str(move.get("move_id", "")):
		return move
	for candidate in attacker.get("moves", []):
		if candidate is Dictionary and str((candidate as Dictionary).get("move_id", "")) == forced_id:
			result["forced_move"] = forced_id
			result["move_id"] = forced_id
			return candidate
	_status.clear_move_locks(attacker)
	return move

func _targets_self(effect: String) -> bool:
	if SELF_TARGET_EFFECTS.has(effect):
		return true
	var stage_effect = BattleStatus.parse_stage_effect(effect)
	return not stage_effect.is_empty() and int(stage_effect.get("stages", 0)) > 0

func _apply_status_move(attacker: Dictionary, defender: Dictionary, effect: String, rng: RandomNumberGenerator, result: Dictionary) -> void:
	if PURE_STATUS_EFFECTS.has(effect):
		var status = str(PURE_STATUS_EFFECTS[effect])
		result["failed"] = not _status.inflict_status(defender, status, rng)
		result["status_applied"] = "" if result["failed"] else status
		return
	var stage_effect = BattleStatus.parse_stage_effect(effect)
	if not stage_effect.is_empty():
		result["stat_changes"].append_array(_status.apply_stage_change(attacker, defender, stage_effect))
		return
	match effect:
		"EFFECT_CONFUSE":
			_set_flag(result, "confused", _status.inflict_confusion(defender, rng))
		"EFFECT_HEAL":
			result["restored"] = _status.apply_heal_move(attacker)
			result["failed"] = int(result["restored"]) <= 0
		"EFFECT_PROTECT":
			_set_flag(result, "protected", _status.try_protect(attacker))
		"EFFECT_ENCORE":
			result["encored"] = _status.try_encore(defender)
			result["failed"] = str(result["encored"]).is_empty()
		"EFFECT_ATTRACT":
			_set_flag(result, "infatuated", _status.try_infatuate(attacker, defender))
		_:
			result["unhandled_effect"] = effect

func _set_flag(result: Dictionary, key: String, ok: bool) -> void:
	result[key] = ok
	result["failed"] = not ok

func _apply_damage_move(attacker: Dictionary, defender: Dictionary, move: Dictionary, effect: String, rng: RandomNumberGenerator, result: Dictionary) -> void:
	var critical = rng.randf() < CRIT_RATE
	result["critical"] = critical
	var stage_effect = BattleStatus.parse_stage_effect(effect)
	var effect_chance = int(move.get("effect_chance", 0))
	var total_hits = _hits_for_effect(effect, rng)
	var strike_move = move
	if effect == "EFFECT_FURY_CUTTER" and _status.fury_multiplier(attacker) > 1.0:
		strike_move = move.duplicate()
		strike_move["power"] = int(floor(float(int(move.get("power", 0))) * _status.fury_multiplier(attacker)))
	var landed = 0
	for hit_index in range(total_hits):
		var damage_info = calculate_damage(attacker, defender, strike_move, rng, critical)
		var effectiveness = float(damage_info.get("effectiveness", 1.0))
		result["effectiveness"] = effectiveness
		result["stab"] = bool(damage_info.get("stab", false))
		if effectiveness <= 0.0:
			break
		var damage = int(damage_info.get("damage", 0))
		defender["current_hp"] = maxi(0, int(defender.get("current_hp", 1)) - damage)
		result["damage"] = int(result.get("damage", 0)) + damage
		landed += 1
		if int(defender.get("current_hp", 0)) <= 0:
			break
		_roll_secondary_effects(attacker, defender, effect, effect_chance, stage_effect, rng, result)
	result["hits"] = landed
	result["fainted"] = int(defender.get("current_hp", 0)) <= 0
	if landed > 0 and effect == "EFFECT_TRAP_TARGET" and _status.apply_trap(defender, rng):
		result["trapped"] = true
	var total_damage = int(result.get("damage", 0))
	if total_damage <= 0:
		return
	if effect == "EFFECT_RECOIL_HIT":
		var recoil = maxi(1, int(floor(float(total_damage) / RECOIL_DIVISOR)))
		attacker["current_hp"] = maxi(0, int(attacker.get("current_hp", 1)) - recoil)
		result["recoil"] = recoil
	elif effect == "EFFECT_LEECH_HIT":
		var max_hp = maxi(1, int(attacker.get("max_hp", 1)))
		var missing = max_hp - int(attacker.get("current_hp", max_hp))
		var healed = mini(missing, maxi(1, int(floor(float(total_damage) / LEECH_DIVISOR))))
		attacker["current_hp"] = int(attacker.get("current_hp", max_hp)) + healed
		result["healed"] = healed

func _roll_secondary_effects(attacker: Dictionary, defender: Dictionary, effect: String, effect_chance: int, stage_effect: Dictionary, rng: RandomNumberGenerator, result: Dictionary) -> void:
	if effect_chance <= 0 or rng.randi_range(1, 100) > effect_chance:
		return
	if HIT_STATUS_EFFECTS.has(effect) and str(result.get("status_applied", "")).is_empty():
		var status = str(HIT_STATUS_EFFECTS[effect])
		if _status.inflict_status(defender, status, rng):
			result["status_applied"] = status
	elif effect == "EFFECT_CONFUSE_HIT":
		result["confused"] = _status.inflict_confusion(defender, rng)
	elif effect == "EFFECT_FLINCH_HIT":
		result["flinched"] = true
	elif not stage_effect.is_empty() and bool(stage_effect.get("on_hit", false)):
		result["stat_changes"].append_array(_status.apply_stage_change(attacker, defender, stage_effect))

func _is_handled_damage_effect(effect: String) -> bool:
	if effect.is_empty() or HIT_STATUS_EFFECTS.has(effect) or MULTI_HIT_EFFECTS.has(effect):
		return true
	if ["EFFECT_NORMAL_HIT", "EFFECT_ALWAYS_HIT", "EFFECT_PRIORITY_HIT", "EFFECT_FLINCH_HIT", "EFFECT_RECOIL_HIT", "EFFECT_LEECH_HIT", "EFFECT_CONFUSE_HIT", "EFFECT_TRAP_TARGET", "EFFECT_RAMPAGE", "EFFECT_FURY_CUTTER"].has(effect):
		return true
	return not BattleStatus.parse_stage_effect(effect).is_empty()

func _hits_for_effect(effect: String, rng: RandomNumberGenerator) -> int:
	if not MULTI_HIT_EFFECTS.has(effect):
		return 1
	var fixed = int(MULTI_HIT_EFFECTS[effect])
	if fixed > 0:
		return fixed
	var roll = rng.randi_range(1, 8)
	if roll <= 3: return 2
	if roll <= 6: return 3
	return roll - 3

func _catch_context(enemy_mon: Dictionary, ball_id: String, catch_rate: int) -> Dictionary:
	var rate = clampi(catch_rate if catch_rate > 0 else int(enemy_mon.get("catch_rate", DEFAULT_CATCH_RATE)), 1, 255)
	var max_hp = maxi(1, int(enemy_mon.get("max_hp", 1)))
	var current_hp = clampi(int(enemy_mon.get("current_hp", max_hp)), 0, max_hp)
	var ball_bonus = _ball_bonus(ball_id)
	var status_bonus = _status_catch_bonus(str(enemy_mon.get("status", "")))
	var catch_value = floor(((3.0 * max_hp - 2.0 * current_hp) * rate * ball_bonus) / (3.0 * max_hp)) * status_bonus
	return {"success": false, "roll": 0.0, "probability": clampf(catch_value / 255.0, 0.0, 1.0),
		"catch_value": catch_value, "catch_rate": rate, "ball_bonus": ball_bonus, "status_bonus": status_bonus}

func _ball_bonus(ball_id: String) -> float:
	match ball_id.strip_edges().to_upper().replace("_", ""):
		"GREATBALL": return 1.5
		"ULTRABALL": return 2.0
	return 1.0

func _status_catch_bonus(status: String) -> float:
	match status:
		"SLP", "FRZ": return 2.0
		"BRN", "PSN", "PAR": return 1.5
	return 1.0

func _has_type(mon: Dictionary, type_id: String) -> bool:
	var types = mon.get("types", PackedStringArray())
	if types is not PackedStringArray:
		return false
	var wanted = type_id.strip_edges().to_upper()
	for raw_type in types:
		if str(raw_type).strip_edges().to_upper() == wanted:
			return true
	return false
static func move_priority(move: Dictionary) -> int: return 1 if str(move.get("effect", "")) == "EFFECT_PRIORITY_HIT" else 0
func _move_display_name(move: Dictionary) -> String:
	var move_name = str(move.get("name", ""))
	if move_name.is_empty():
		move_name = str(move.get("move_id", "move")).capitalize()
	return move_name

func _new_attack_result(move: Dictionary) -> Dictionary:
	return {
		"move_id": str(move.get("move_id", "")), "hit": false, "damage": 0, "hits": 0,
		"critical": false, "effectiveness": 1.0, "stab": false, "fainted": false,
		"recoil": 0, "healed": 0, "status_applied": "", "flinched": false, "failed": false,
		"stat_changes": [], "blocked_by": "", "woke_up": false, "thawed": false,
		"priority": 0, "snapped_out": false, "hurt_itself": false, "self_damage": 0, "self_fainted": false,
		"confused": false, "infatuated": false, "trapped": false, "protected": false, "protected_target": false,
		"ohko": false, "restored": 0, "encored": "", "forced_move": "", "self_confused": false, "fury_streak": 0, "unhandled_effect": "", "message": "",
	}
