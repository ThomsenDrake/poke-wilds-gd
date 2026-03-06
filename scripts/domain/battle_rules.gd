extends RefCounted


func apply_attack(attacker: Dictionary, defender: Dictionary, move: Dictionary, rng: RandomNumberGenerator) -> String:
	var attacker_name = str(attacker.get("name", "Pokemon"))
	var defender_name = str(defender.get("name", "Pokemon"))
	var move_name = str(move.get("name", move.get("move_id", "move")))
	var power = int(move.get("power", 0))
	var accuracy = int(move.get("accuracy", 100))

	if rng.randi_range(1, 100) > accuracy:
		return "%s used %s.\nBut it missed!" % [attacker_name, move_name]

	if power <= 0:
		return "%s used %s.\nBut nothing happened." % [attacker_name, move_name]

	var level = int(attacker.get("level", 1))
	var attacker_stats = attacker.get("stats", {})
	var defender_stats = defender.get("stats", {})
	var category = str(move.get("category", "PHYSICAL"))

	var attack_stat = int(attacker_stats.get("atk", 5))
	var defense_stat = int(defender_stats.get("def", 5))
	if category == "SPECIAL":
		attack_stat = int(attacker_stats.get("sat", 5))
		defense_stat = int(defender_stats.get("sdf", 5))

	var base_damage = (((2.0 * level / 5.0 + 2.0) * power * max(1, attack_stat) / max(1, defense_stat)) / 50.0) + 2.0
	var damage = maxi(1, int(floor(base_damage * rng.randf_range(0.85, 1.0))))
	var current_hp = int(defender.get("current_hp", 1))
	defender["current_hp"] = maxi(0, current_hp - damage)

	var text = "%s used %s!\n%s took %d damage." % [attacker_name, move_name, defender_name, damage]
	if int(defender["current_hp"]) <= 0:
		text += "\n%s fainted!" % defender_name
	return text


func choose_enemy_move_index(enemy_mon: Dictionary, rng: RandomNumberGenerator) -> int:
	var moves = enemy_mon.get("moves", [])
	var usable_indexes: Array = []
	for i in range(moves.size()):
		var move = moves[i]
		if int(move.get("pp", 0)) > 0:
			usable_indexes.append(i)
	if usable_indexes.is_empty():
		return -1
	return int(usable_indexes[rng.randi_range(0, usable_indexes.size() - 1)])


func calculate_catch_chance(enemy_mon: Dictionary) -> float:
	var enemy_hp = int(enemy_mon.get("current_hp", 1))
	var enemy_max_hp = max(1, int(enemy_mon.get("max_hp", 1)))
	var hp_ratio = float(enemy_hp) / float(enemy_max_hp)
	return clampf(0.15 + ((1.0 - hp_ratio) * 0.75), 0.15, 0.9)
