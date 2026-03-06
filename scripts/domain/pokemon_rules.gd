extends RefCounted


func experience_for_level(level: int) -> int:
	var clamped = clampi(level, 1, 100)
	return clamped * clamped * clamped


func build_stats(base_stats: Dictionary, level: int) -> Dictionary:
	var base_hp = int(base_stats.get("hp", 45))
	var base_atk = int(base_stats.get("atk", 49))
	var base_def = int(base_stats.get("def", 49))
	var base_spe = int(base_stats.get("spe", 45))
	var base_sat = int(base_stats.get("sat", 49))
	var base_sdf = int(base_stats.get("sdf", 49))

	var hp = int(floor((2.0 * base_hp * level) / 100.0)) + level + 10
	var atk = int(floor((2.0 * base_atk * level) / 100.0)) + 5
	var deff = int(floor((2.0 * base_def * level) / 100.0)) + 5
	var spe = int(floor((2.0 * base_spe * level) / 100.0)) + 5
	var sat = int(floor((2.0 * base_sat * level) / 100.0)) + 5
	var sdf = int(floor((2.0 * base_sdf * level) / 100.0)) + 5

	return {
		"hp": max(1, hp),
		"atk": max(1, atk),
		"def": max(1, deff),
		"spe": max(1, spe),
		"sat": max(1, sat),
		"sdf": max(1, sdf)
	}


func create_pokemon_instance(species_entry: Dictionary, level: int, move_lookup: Callable) -> Dictionary:
	if species_entry.is_empty():
		return {}

	var safe_level = clampi(level, 1, 100)
	var stats = build_stats(species_entry.get("base_stats", {}), safe_level)
	var max_hp = int(stats.get("hp", 1))
	var move_ids = _collect_move_ids_for_level(species_entry, safe_level)
	var moves = build_move_set(move_ids, move_lookup)

	if moves.is_empty():
		var fallback_move = move_lookup.call("TACKLE")
		if fallback_move is Dictionary and not (fallback_move as Dictionary).is_empty():
			moves.append(_create_move_runtime_data(fallback_move))

	return {
		"species_id": str(species_entry.get("species_id", "")),
		"name": str(species_entry.get("display_name", "Pokemon")),
		"level": safe_level,
		"exp": experience_for_level(safe_level),
		"types": species_entry.get("types", PackedStringArray(["NORMAL", "NORMAL"])),
		"stats": stats,
		"max_hp": max_hp,
		"current_hp": max_hp,
		"moves": moves,
		"front_path": str(species_entry.get("front_path", "")),
		"back_path": str(species_entry.get("back_path", ""))
	}


func build_move_set(move_ids: Array, move_lookup: Callable) -> Array:
	var move_set: Array = []
	for move_id_variant in move_ids:
		var move_id = str(move_id_variant)
		var move_entry = move_lookup.call(move_id)
		if move_entry is not Dictionary or (move_entry as Dictionary).is_empty():
			continue
		move_set.append(_create_move_runtime_data(move_entry))
	return move_set


func award_experience(mon: Dictionary, species_entry: Dictionary, amount: int, move_lookup: Callable) -> Dictionary:
	var updated_mon = mon.duplicate(true)
	var old_level = int(updated_mon.get("level", 1))
	var exp_total = int(updated_mon.get("exp", experience_for_level(old_level))) + max(0, amount)
	var new_level = old_level
	while new_level < 100 and exp_total >= experience_for_level(new_level + 1):
		new_level += 1

	var learned_moves: Array = []
	if new_level > old_level:
		var old_max_hp = int(updated_mon.get("max_hp", 1))
		var new_stats = build_stats(species_entry.get("base_stats", {}), new_level)
		var new_max_hp = int(new_stats.get("hp", old_max_hp))
		updated_mon["stats"] = new_stats
		updated_mon["max_hp"] = new_max_hp
		updated_mon["current_hp"] = clampi(int(updated_mon.get("current_hp", 1)) + (new_max_hp - old_max_hp), 1, new_max_hp)
		updated_mon["level"] = new_level

		learned_moves = _collect_newly_learned_moves(species_entry, old_level + 1, new_level)
		for move_id_variant in learned_moves:
			var move_data = move_lookup.call(str(move_id_variant))
			if move_data is Dictionary and not (move_data as Dictionary).is_empty():
				_add_move_to_mon(updated_mon, move_data)

	updated_mon["exp"] = exp_total
	return {
		"mon": updated_mon,
		"levels_gained": new_level - old_level,
		"new_level": new_level,
		"learned_moves": learned_moves
	}


func normalize_loaded_mon(raw_mon: Dictionary) -> Dictionary:
	var mon = raw_mon.duplicate(true)
	mon["level"] = int(mon.get("level", 1))
	mon["exp"] = int(mon.get("exp", experience_for_level(int(mon["level"]))))
	mon["max_hp"] = int(mon.get("max_hp", 1))
	mon["current_hp"] = int(mon.get("current_hp", mon["max_hp"]))
	if mon["current_hp"] > mon["max_hp"]:
		mon["current_hp"] = mon["max_hp"]

	var stats = mon.get("stats", {})
	if stats is Dictionary:
		stats["hp"] = int(stats.get("hp", mon["max_hp"]))
		stats["atk"] = int(stats.get("atk", 5))
		stats["def"] = int(stats.get("def", 5))
		stats["spe"] = int(stats.get("spe", 5))
		stats["sat"] = int(stats.get("sat", 5))
		stats["sdf"] = int(stats.get("sdf", 5))
		mon["stats"] = stats

	var normalized_moves: Array = []
	var moves_data = mon.get("moves", [])
	if moves_data is Array:
		for move_variant in moves_data:
			if move_variant is not Dictionary:
				continue
			var move_data: Dictionary = move_variant
			move_data["power"] = int(move_data.get("power", 0))
			move_data["accuracy"] = int(move_data.get("accuracy", 100))
			move_data["max_pp"] = int(move_data.get("max_pp", 10))
			move_data["pp"] = clampi(int(move_data.get("pp", move_data["max_pp"])), 0, move_data["max_pp"])
			normalized_moves.append(move_data)
	mon["moves"] = normalized_moves
	return mon


func _collect_move_ids_for_level(species_entry: Dictionary, level: int) -> Array:
	var learnset = species_entry.get("learnset", [])
	var candidates: Array = []
	if learnset is Array:
		for entry_variant in learnset:
			if entry_variant is not Dictionary:
				continue
			var entry: Dictionary = entry_variant
			var unlock_level = int(entry.get("level", 1))
			if unlock_level <= level:
				var move_id = str(entry.get("move_id", ""))
				if not move_id.is_empty() and not candidates.has(move_id):
					candidates.append(move_id)

	if candidates.is_empty():
		return ["TACKLE"]
	if candidates.size() <= 4:
		return candidates
	return candidates.slice(candidates.size() - 4, candidates.size())


func _collect_newly_learned_moves(species_entry: Dictionary, start_level: int, end_level: int) -> Array:
	var result: Array = []
	var learnset = species_entry.get("learnset", [])
	if learnset is not Array:
		return result

	for entry_variant in learnset:
		if entry_variant is not Dictionary:
			continue
		var entry: Dictionary = entry_variant
		var unlock_level = int(entry.get("level", 0))
		if unlock_level < start_level or unlock_level > end_level:
			continue
		var move_id = str(entry.get("move_id", ""))
		if not move_id.is_empty() and not result.has(move_id):
			result.append(move_id)
	return result


func _create_move_runtime_data(move_entry: Dictionary) -> Dictionary:
	var max_pp = int(move_entry.get("pp", 20))
	return {
		"move_id": str(move_entry.get("move_id", "")),
		"name": str(move_entry.get("display_name", "")),
		"power": int(move_entry.get("power", 0)),
		"accuracy": int(move_entry.get("accuracy", 100)),
		"type": str(move_entry.get("type", "NORMAL")),
		"category": str(move_entry.get("category", "PHYSICAL")),
		"max_pp": max_pp,
		"pp": max_pp
	}


func _add_move_to_mon(mon: Dictionary, move_data: Dictionary) -> void:
	var moves = mon.get("moves", [])
	if moves is not Array:
		moves = []

	var move_id = str(move_data.get("move_id", ""))
	for existing_variant in moves:
		if existing_variant is not Dictionary:
			continue
		var existing: Dictionary = existing_variant
		if str(existing.get("move_id", "")) == move_id:
			mon["moves"] = moves
			return

	var runtime_move = _create_move_runtime_data(move_data)
	if moves.size() < 4:
		moves.append(runtime_move)
	else:
		moves.remove_at(0)
		moves.append(runtime_move)
	mon["moves"] = moves
