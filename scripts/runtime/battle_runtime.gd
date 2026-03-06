extends RefCounted

const BattleRules := preload("res://scripts/domain/battle_rules.gd")

var _session = null
var _catalog = null
var _pokemon_rules = null
var _trace = null
var _rules = BattleRules.new()
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
	_active = true
	return _response("A wild %s appeared!" % str(_enemy_mon.get("name", "Pokemon")), "action")


func get_snapshot() -> Dictionary:
	return {
		"player_mon": _player_mon.duplicate(true),
		"enemy_mon": _enemy_mon.duplicate(true),
		"bag": {
			"pokeball": _session.get_item_count("pokeball"),
			"potion": _session.get_item_count("potion")
		}
	}


func perform_move(index: int) -> Dictionary:
	if not _active:
		return {}
	var moves = _player_mon.get("moves", [])
	if index < 0 or index >= moves.size():
		return _response("That move is unavailable.", "action")

	var move: Dictionary = moves[index]
	var pp = int(move.get("pp", 0))
	if pp <= 0:
		return _response("No PP left for that move.", "action")

	move["pp"] = pp - 1
	moves[index] = move
	_player_mon["moves"] = moves

	var turn_text = _rules.apply_attack(_player_mon, _enemy_mon, move, _rng)
	if int(_enemy_mon.get("current_hp", 0)) <= 0:
		return _handle_victory("victory", "You won the battle.")

	turn_text += "\n" + _enemy_take_turn()
	if int(_player_mon.get("current_hp", 0)) <= 0:
		return _handle_player_faint(turn_text)
	return _response(turn_text, "action")


func use_pokeball() -> Dictionary:
	if not _active:
		return {}
	if not _session.consume_item("pokeball", 1):
		return _response("No Poke Balls left.", "action")

	if _rng.randf() <= _rules.calculate_catch_chance(_enemy_mon):
		var caught = _session.add_pokemon_to_party(_enemy_mon.duplicate(true))
		var outcome = "caught" if caught else "caught_box_full"
		var message = "Gotcha! %s was caught." % str(_enemy_mon.get("name", "Pokemon"))
		if not caught:
			message = "Caught %s, but your party is full." % str(_enemy_mon.get("name", "Pokemon"))
		return _handle_victory(outcome, message)

	var text = "The wild %s broke free!" % str(_enemy_mon.get("name", "Pokemon"))
	text += "\n" + _enemy_take_turn()
	if int(_player_mon.get("current_hp", 0)) <= 0:
		return _handle_player_faint(text)
	return _response(text, "action")


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

	var healed = min(20, max_hp - current_hp)
	_player_mon["current_hp"] = current_hp + healed
	var text = "%s recovered %d HP." % [str(_player_mon.get("name", "Pokemon")), healed]
	text += "\n" + _enemy_take_turn()
	if int(_player_mon.get("current_hp", 0)) <= 0:
		return _handle_player_faint(text)
	return _response(text, "action")


func run_from_battle() -> Dictionary:
	if not _active:
		return {}
	return _end_battle("escaped", "Got away safely!")


func _enemy_take_turn() -> String:
	var pick = _rules.choose_enemy_move_index(_enemy_mon, _rng)
	if pick < 0:
		return "%s has no moves left." % str(_enemy_mon.get("name", "Wild Pokemon"))

	var moves = _enemy_mon.get("moves", [])
	var chosen_move: Dictionary = moves[pick]
	chosen_move["pp"] = int(chosen_move.get("pp", 0)) - 1
	moves[pick] = chosen_move
	_enemy_mon["moves"] = moves
	return _rules.apply_attack(_enemy_mon, _player_mon, chosen_move, _rng)


func _handle_player_faint(prefix: String) -> Dictionary:
	var next_index = _session.get_next_healthy_party_index(_player_party_index)
	if next_index >= 0:
		_session.set_party_member(_player_party_index, _player_mon)
		_player_party_index = next_index
		_player_mon = _session.get_party_member(_player_party_index).duplicate(true)
		return _response("%s\n%s, go!" % [prefix, str(_player_mon.get("name", "Pokemon"))], "action")
	return _end_battle("defeat", "You blacked out.")


func _handle_victory(outcome: String, base_message: String) -> Dictionary:
	var exp_reward = max(10, int(_enemy_mon.get("level", 1)) * 18)
	var species_id = str(_player_mon.get("species_id", ""))
	var species_entry = _catalog.get_species(species_id)
	var summary = {"levels_gained": 0, "new_level": int(_player_mon.get("level", 1)), "learned_moves": []}
	if not species_entry.is_empty():
		summary = _pokemon_rules.award_experience(_player_mon, species_entry, exp_reward, Callable(_catalog, "get_move"))
		_player_mon = summary.get("mon", _player_mon)

	var message = "%s +%d EXP." % [base_message, exp_reward]
	var levels_gained = int(summary.get("levels_gained", 0))
	if levels_gained > 0:
		message += " %s grew to Lv.%d." % [str(_player_mon.get("name", "Pokemon")), int(summary.get("new_level", 1))]
		var learned = summary.get("learned_moves", [])
		if learned is Array and not learned.is_empty():
			message += " Learned: %s." % ", ".join(learned)
	return _end_battle(outcome, message)


func _end_battle(outcome: String, message: String) -> Dictionary:
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
		"snapshot": get_snapshot()
	}


func _response(message: String, menu: String) -> Dictionary:
	return {
		"active": _active,
		"finished": false,
		"outcome": "",
		"message": message,
		"menu": menu,
		"snapshot": get_snapshot()
	}
