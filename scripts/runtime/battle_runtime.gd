extends RefCounted

const BattleRules := preload("res://scripts/domain/battle_rules.gd")
const AttackAnims := preload("res://scripts/data/attack_anims.gd")

const BALL_ID := "poke_ball"
const DEFAULT_CATCH_RATE := 45
const POTION_HEAL := 20

var _session = null
var _catalog = null
var _pokemon_rules = null
var _trace = null
var _rules = BattleRules.new()
var _anims = AttackAnims.new()
var _rng = RandomNumberGenerator.new()

var _active = false
var _player_party_index = -1
var _player_mon: Dictionary = {}
var _enemy_mon: Dictionary = {}


func _init() -> void:
	_rng.randomize()


func setup(session_state, catalog, pokemon_rules, trace_logger) -> void:
	_session = session_state
	_catalog = catalog
	_pokemon_rules = pokemon_rules
	_trace = trace_logger


func start_wild_battle(wild_mon: Dictionary) -> Dictionary:
	_player_party_index = _session.get_active_party_index()
	if _player_party_index < 0:
		_session.heal_party_full()
		_player_party_index = _session.get_active_party_index()
	if _player_party_index < 0:
		return _end_battle("defeat", "Your party has no usable Pokemon.")

	var current_player = _session.get_party_member(_player_party_index)
	if current_player.is_empty():
		return _end_battle("defeat", "Could not load active party member.")

	_player_mon = current_player.duplicate(true)
	_enemy_mon = wild_mon.duplicate(true)
	_rules.reset_stages(_player_mon)
	_rules.reset_stages(_enemy_mon)
	_active = true
	return _response("A wild %s appeared!" % str(_enemy_mon.get("name", "Pokemon")), "action")


func get_snapshot() -> Dictionary:
	return {"player_mon": _player_mon.duplicate(true), "enemy_mon": _enemy_mon.duplicate(true),
		"bag": {"poke_ball": _session.get_item_count(BALL_ID), "potion": _session.get_item_count("potion")}}


func perform_move(index: int) -> Dictionary:
	if not _active:
		return {}
	var moves = _player_mon.get("moves", [])
	if index < 0 or index >= moves.size():
		return _response("That move is unavailable.", "action")
	if int(moves[index].get("pp", 0)) <= 0:
		return _response("No PP left for that move.", "action")

	var lines: Array = []
	var turns: Array = []
	var finished = _resolve_round(index, lines, turns)
	if not finished.is_empty():
		return _with_turns(finished, turns)
	return _with_turns(_response("\n".join(lines), "action"), turns)


func use_pokeball() -> Dictionary:
	if not _active:
		return {}
	if not _session.consume_item(BALL_ID, 1):
		return _response("No Poke Balls left.", "action")

	var species_entry = _catalog.get_species(str(_enemy_mon.get("species_id", "")))
	var catch_rate = int(species_entry.get("catch_rate", DEFAULT_CATCH_RATE))
	var attempt = _rules.attempt_capture(_enemy_mon, BALL_ID, _rng, catch_rate)
	if bool(attempt.get("success", false)):
		_rules.reset_stages(_enemy_mon)
		var caught = _session.add_pokemon_to_party(_enemy_mon.duplicate(true))
		var mon_name := str(_enemy_mon.get("name", "Pokemon"))
		var message := ("Gotcha! %s was caught." if caught else "Caught %s, but your party is full.") % mon_name
		return _handle_victory("caught" if caught else "caught_box_full", [message])

	var lines: Array = ["The wild %s broke free!" % str(_enemy_mon.get("name", "Pokemon"))]
	var turns: Array = []
	var finished = _enemy_counterattack(lines, turns)
	if not finished.is_empty():
		return _with_turns(finished, turns)
	return _with_turns(_response("\n".join(lines), "action"), turns)


func use_potion() -> Dictionary:
	if not _active:
		return {}
	if not _session.consume_item("potion", 1):
		return _response("No Potions left.", "action")

	var max_hp = int(_player_mon.get("max_hp", 1))
	var current_hp = int(_player_mon.get("current_hp", 1))
	if current_hp >= max_hp:
		_session.add_item("potion", 1)
		return _response("HP is already full.", "action")

	var healed = min(POTION_HEAL, max_hp - current_hp)
	_player_mon["current_hp"] = current_hp + healed
	var lines: Array = ["%s recovered %d HP." % [str(_player_mon.get("name", "Pokemon")), healed]]
	var turns: Array = []
	var finished = _enemy_counterattack(lines, turns)
	if not finished.is_empty():
		return _with_turns(finished, turns)
	return _with_turns(_response("\n".join(lines), "action"), turns)


func run_from_battle() -> Dictionary:
	if not _active:
		return {}
	if _rules.is_trapped(_player_mon): return _response("Can't escape!", "action")
	return _end_battle("escaped", "Got away safely!")


# One round in priority/speed order (player wins ties), then end-of-turn ticks.
func _resolve_round(player_move_index: int, lines: Array, turns: Array) -> Dictionary:
	var enemy_index = _rules.choose_enemy_move_index(_enemy_mon, _rng)
	var enemy_move: Dictionary = (_enemy_mon.get("moves", []) as Array)[enemy_index] if enemy_index >= 0 else {}
	var player_move: Dictionary = (_player_mon.get("moves", []) as Array)[player_move_index]
	var enemy_first: bool = _move_priority(enemy_move) > _move_priority(player_move) \
		or (_move_priority(enemy_move) == _move_priority(player_move) \
		and _rules.effective_stat(_enemy_mon, "spe") > _rules.effective_stat(_player_mon, "spe"))
	var skip_side := ""
	for side in (["enemy", "player"] if enemy_first else ["player", "enemy"]):
		if side == skip_side:
			continue
		var result = _act(side, player_move_index if side == "player" else enemy_index, lines, turns)
		if bool(result.get("flinched", false)):
			skip_side = "enemy" if side == "player" else "player"
		var finished = _check_knockout(lines)
		if not finished.is_empty():
			return finished
	return _apply_end_of_turn(lines)


func _move_priority(move: Dictionary) -> int: return 1 if str(move.get("effect", "")) == "EFFECT_PRIORITY_HIT" else 0


func _enemy_counterattack(lines: Array, turns: Array) -> Dictionary:
	_act("enemy", _rules.choose_enemy_move_index(_enemy_mon, _rng), lines, turns)
	var finished = _check_knockout(lines)
	if not finished.is_empty():
		return finished
	return _apply_end_of_turn(lines)


func _act(side: String, move_index: int, lines: Array, turns: Array) -> Dictionary:
	var attacker = _player_mon if side == "player" else _enemy_mon
	var defender = _enemy_mon if side == "player" else _player_mon
	if move_index < 0:
		lines.append("%s has no moves left." % str(attacker.get("name", "Pokemon")))
		return {}
	_spend_pp(attacker, move_index)
	var move: Dictionary = attacker.get("moves", [])[move_index]
	var result = _rules.execute_attack(attacker, defender, move, _rng)
	var effect = str(result.get("unhandled_effect", ""))
	if not effect.is_empty() and _trace != null:
		_trace.warning("BattleRuntime", "Unhandled move effect in battle.", {"move_id": str(result.get("move_id", "")), "effect": effect})
	lines.append(str(result.get("message", "")))
	turns.append(_anims.turn_for(side, result))
	return result


func _spend_pp(mon: Dictionary, move_index: int) -> void:
	var moves = mon.get("moves", [])
	if move_index < 0 or move_index >= moves.size():
		return
	var move: Dictionary = moves[move_index]
	move["pp"] = maxi(0, int(move.get("pp", 0)) - 1)
	moves[move_index] = move
	mon["moves"] = moves


func _check_knockout(lines: Array) -> Dictionary:
	if int(_enemy_mon.get("current_hp", 0)) <= 0:
		return _handle_victory("victory", lines)
	if int(_player_mon.get("current_hp", 0)) <= 0:
		return _handle_player_faint(lines)
	return {}


func _apply_end_of_turn(lines: Array) -> Dictionary:
	for side in ["player", "enemy"]:
		var mon = _player_mon if side == "player" else _enemy_mon
		if int(mon.get("current_hp", 0)) <= 0:
			continue
		var tick = _rules.apply_end_of_turn_status(mon)
		if int(tick.get("damage", 0)) <= 0:
			continue
		var mon_name = str(mon.get("name", "Pokemon"))
		lines.append("%s is hurt by poison!" % mon_name if str(tick.get("status", "")) == "PSN" else "%s is hurt by its burn!" % mon_name)
		if bool(tick.get("fainted", false)):
			lines.append("%s fainted!" % mon_name)
			if side == "enemy":
				return _handle_victory("victory", lines)
			return _handle_player_faint(lines)
	return {}


# Attaches the round's per-action turns so the battle view can animate them
# before showing the resulting snapshot/message. Additive response key.
func _with_turns(response: Dictionary, turns: Array) -> Dictionary:
	response["turns"] = turns
	return response


func _handle_player_faint(lines: Array) -> Dictionary:
	_rules.reset_stages(_player_mon)
	_session.set_party_member(_player_party_index, _player_mon)
	var next_index = _session.get_next_healthy_party_index(_player_party_index)
	if next_index >= 0:
		_player_party_index = next_index
		_player_mon = _session.get_party_member(_player_party_index).duplicate(true)
		_rules.reset_stages(_player_mon)
		lines.append("%s, go!" % str(_player_mon.get("name", "Pokemon")))
		return _response("\n".join(lines), "action")
	lines.append("You blacked out.")
	return _end_battle("defeat", "\n".join(lines))


func _handle_victory(outcome: String, lines: Array) -> Dictionary:
	if outcome == "victory":
		lines.append("You won the battle.")
	var enemy_entry = _catalog.get_species(str(_enemy_mon.get("species_id", "")))
	var exp_reward = _pokemon_rules.experience_yield(enemy_entry, int(_enemy_mon.get("level", 1)))
	var species_entry = _catalog.get_species(str(_player_mon.get("species_id", "")))
	var summary := {}
	if not species_entry.is_empty():
		summary = _pokemon_rules.award_experience(_player_mon, species_entry, exp_reward, Callable(_catalog, "get_move"))
		_player_mon = summary.get("mon", _player_mon)

	lines.append("+%d EXP." % exp_reward)
	var evolved := {}
	if int(summary.get("levels_gained", 0)) > 0:
		lines.append("%s grew to Lv.%d." % [str(_player_mon.get("name", "Pokemon")), int(summary.get("new_level", 1))])
		var learned = summary.get("learned_moves", [])
		if learned is Array and not learned.is_empty():
			lines.append("Learned: %s." % ", ".join(learned))
		evolved = _try_evolve(lines)
	return _end_battle(outcome, "\n".join(lines), evolved)


func _try_evolve(lines: Array) -> Dictionary:
	var evolution = _pokemon_rules.check_level_evolution(_player_mon, Callable(_catalog, "get_species"))
	var target_id = str(evolution.get("target", ""))
	if target_id.is_empty():
		return {}
	var target_entry = _catalog.get_species(target_id)
	if target_entry.is_empty():
		# Dangling evolution target: skip silently.
		return {}

	var from_id = str(_player_mon.get("species_id", ""))
	var from_name = str(_player_mon.get("name", "Pokemon"))
	var old_max_hp = maxi(1, int(_player_mon.get("max_hp", 1)))
	var hp_ratio = clampf(float(int(_player_mon.get("current_hp", 0))) / float(old_max_hp), 0.0, 1.0)
	var stats = _pokemon_rules.build_stats(target_entry.get("base_stats", {}), int(_player_mon.get("level", 1)))
	_player_mon["species_id"] = str(target_entry.get("species_id", target_id))
	_player_mon["name"] = str(target_entry.get("display_name", from_name))
	_player_mon["types"] = target_entry.get("types", PackedStringArray(["NORMAL", "NORMAL"]))
	_player_mon["front_path"] = str(target_entry.get("front_path", ""))
	_player_mon["back_path"] = str(target_entry.get("back_path", ""))
	_player_mon["catch_rate"] = int(target_entry.get("catch_rate", DEFAULT_CATCH_RATE))
	_player_mon["stats"] = stats
	_player_mon["max_hp"] = int(stats.get("hp", old_max_hp))
	_player_mon["current_hp"] = clampi(int(round(hp_ratio * float(_player_mon["max_hp"]))), 1, int(_player_mon["max_hp"]))
	lines.append("%s evolved into %s!" % [from_name, str(_player_mon["name"])])
	return {"from": from_id, "to": str(_player_mon["species_id"])}


func _end_battle(outcome: String, message: String, evolved: Dictionary = {}) -> Dictionary:
	_rules.reset_stages(_player_mon)
	_rules.reset_stages(_enemy_mon)
	if _player_party_index >= 0 and not _player_mon.is_empty():
		_session.set_party_member(_player_party_index, _player_mon)

	if outcome == "defeat":
		_session.heal_party_full()
		_session.player_tile = Vector2i.ZERO

	_active = false
	if _trace != null:
		_trace.emit_event("battle_finished", "BattleRuntime", {"outcome": outcome})
	return {
		"active": false,
		"finished": true,
		"outcome": outcome,
		"message": message,
		"menu": "",
		"evolved": evolved,
		"snapshot": get_snapshot()
	}


func _response(message: String, menu: String) -> Dictionary:
	return {
		"active": _active,
		"finished": false,
		"outcome": "",
		"message": message,
		"menu": menu,
		"evolved": {},
		"snapshot": get_snapshot()
	}
