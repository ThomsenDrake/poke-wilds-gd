extends Node

const SAVE_PATH := "user://godot_port_save.json"
const PokemonDatabase := preload("res://scripts/data/pokemon_database.gd")

var database = PokemonDatabase.new()
var initialized = false

var world_seed: int = 1337
var player_tile: Vector2i = Vector2i.ZERO
var party: Array = []
var bag: Dictionary = {}

var _rng = RandomNumberGenerator.new()


func ensure_initialized() -> void:
	if initialized:
		return

	database.load_all()
	_rng.randomize()
	if not load_game():
		new_game()
	initialized = true


func new_game() -> void:
	world_seed = int(_rng.randi() & 0x7fffffff)
	player_tile = Vector2i.ZERO
	party.clear()
	bag = {
		"pokeball": 10,
		"potion": 5
	}

	var starter = create_pokemon_instance("CHIKORITA", 5)
	if starter.is_empty():
		var fallback_id = database.get_random_encounter_species(_rng)
		if not fallback_id.is_empty():
			starter = create_pokemon_instance(fallback_id, 5)
	if not starter.is_empty():
		party.append(starter)
	save_game()


func get_active_party_index() -> int:
	for i in range(party.size()):
		var mon = party[i]
		if int(mon.get("current_hp", 0)) > 0:
			return i
	return -1


func get_next_healthy_party_index(excluding_index: int) -> int:
	for i in range(party.size()):
		if i == excluding_index:
			continue
		var mon = party[i]
		if int(mon.get("current_hp", 0)) > 0:
			return i
	return -1


func get_party_member(index: int) -> Dictionary:
	if index < 0 or index >= party.size():
		return {}
	return party[index]


func set_party_member(index: int, mon: Dictionary) -> void:
	if index < 0 or index >= party.size():
		return
	party[index] = mon


func add_pokemon_to_party(mon: Dictionary) -> bool:
	if party.size() >= 6:
		return false
	party.append(mon)
	return true


func set_party_lead(index: int) -> void:
	if index <= 0 or index >= party.size():
		return
	var selected = party[index]
	party.remove_at(index)
	party.insert(0, selected)


func heal_party_full() -> void:
	for i in range(party.size()):
		var mon = party[i]
		mon["current_hp"] = int(mon.get("max_hp", 1))
		party[i] = mon


func get_item_count(item_id: String) -> int:
	return int(bag.get(item_id, 0))


func consume_item(item_id: String, amount: int = 1) -> bool:
	var current = get_item_count(item_id)
	if current < amount:
		return false
	bag[item_id] = current - amount
	return true


func add_item(item_id: String, amount: int = 1) -> void:
	bag[item_id] = get_item_count(item_id) + amount


func generate_wild_encounter(tile_pos: Vector2i) -> Dictionary:
	var species_id = database.get_random_encounter_species(_rng)
	if species_id.is_empty():
		return {}

	var distance = abs(tile_pos.x) + abs(tile_pos.y)
	var level = 2 + int(distance / 24) + _rng.randi_range(0, 3)
	level = clampi(level, 2, 80)

	return create_pokemon_instance(species_id, level)


func create_pokemon_instance(species_id: String, level: int) -> Dictionary:
	var species = database.get_species(species_id)
	if species.is_empty():
		return {}

	var safe_level = clampi(level, 1, 100)
	var base_stats = species.get("base_stats", {})
	var stats = _build_stats(base_stats, safe_level)
	var max_hp = int(stats.get("hp", 1))
	var move_ids = _collect_move_ids_for_level(species, safe_level)
	var moves = _build_move_set(move_ids)

	if moves.is_empty():
		var fallback_move = database.get_move("TACKLE")
		if not fallback_move.is_empty():
			moves.append(_create_move_runtime_data(fallback_move))

	return {
		"species_id": str(species.get("species_id", species_id)),
		"name": str(species.get("display_name", species_id.capitalize())),
		"level": safe_level,
		"exp": experience_for_level(safe_level),
		"types": species.get("types", PackedStringArray(["NORMAL", "NORMAL"])),
		"stats": stats,
		"max_hp": max_hp,
		"current_hp": max_hp,
		"moves": moves,
		"front_path": str(species.get("front_path", "")),
		"back_path": str(species.get("back_path", ""))
	}


func experience_for_level(level: int) -> int:
	var clamped = clampi(level, 1, 100)
	return clamped * clamped * clamped


func award_experience(party_index: int, amount: int) -> Dictionary:
	if party_index < 0 or party_index >= party.size():
		return {"levels_gained": 0, "new_level": 0, "learned_moves": []}

	var mon: Dictionary = party[party_index]
	var species_id = str(mon.get("species_id", ""))
	var species_entry = database.get_species(species_id)
	if species_entry.is_empty():
		return {"levels_gained": 0, "new_level": int(mon.get("level", 1)), "learned_moves": []}

	var old_level = int(mon.get("level", 1))
	var exp_total = int(mon.get("exp", experience_for_level(old_level))) + max(0, amount)
	var new_level = old_level
	while new_level < 100 and exp_total >= experience_for_level(new_level + 1):
		new_level += 1

	var learned_moves: Array = []
	if new_level > old_level:
		var old_max_hp = int(mon.get("max_hp", 1))
		var new_stats = _build_stats(species_entry.get("base_stats", {}), new_level)
		var new_max_hp = int(new_stats.get("hp", old_max_hp))
		mon["stats"] = new_stats
		mon["max_hp"] = new_max_hp
		mon["current_hp"] = clampi(int(mon.get("current_hp", 1)) + (new_max_hp - old_max_hp), 1, new_max_hp)
		mon["level"] = new_level

		learned_moves = _collect_newly_learned_moves(species_entry, old_level + 1, new_level)
		for move_id_variant in learned_moves:
			_add_move_to_mon(mon, str(move_id_variant))

	mon["exp"] = exp_total
	party[party_index] = mon
	return {
		"levels_gained": new_level - old_level,
		"new_level": new_level,
		"learned_moves": learned_moves
	}


func save_game() -> void:
	var payload = {
		"world_seed": world_seed,
		"player_x": player_tile.x,
		"player_y": player_tile.y,
		"party": party,
		"bag": bag
	}
	var file = FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(payload))
	file.close()


func load_game() -> bool:
	if not FileAccess.file_exists(SAVE_PATH):
		return false

	var file = FileAccess.open(SAVE_PATH, FileAccess.READ)
	if file == null:
		return false

	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	if parsed is not Dictionary:
		return false

	var data: Dictionary = parsed
	world_seed = int(data.get("world_seed", 1337))
	player_tile = Vector2i(int(data.get("player_x", 0)), int(data.get("player_y", 0)))
	bag = data.get("bag", {"pokeball": 10, "potion": 5})
	party = []

	var loaded_party = data.get("party", [])
	if loaded_party is Array:
		for mon_variant in loaded_party:
			if mon_variant is Dictionary:
				party.append(_normalize_loaded_mon(mon_variant))

	return not party.is_empty()


func _build_stats(base_stats: Dictionary, level: int) -> Dictionary:
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


func _build_move_set(move_ids: Array) -> Array:
	var move_set: Array = []
	for move_id_variant in move_ids:
		var move_id = str(move_id_variant)
		var move_entry = database.get_move(move_id)
		if move_entry.is_empty():
			continue
		move_set.append(_create_move_runtime_data(move_entry))
	return move_set


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


func _normalize_loaded_mon(raw_mon: Dictionary) -> Dictionary:
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


func _add_move_to_mon(mon: Dictionary, move_id: String) -> void:
	var move_data = database.get_move(move_id)
	if move_data.is_empty():
		return

	var moves = mon.get("moves", [])
	if moves is not Array:
		moves = []

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
