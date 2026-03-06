extends Node

const TraceLogger := preload("res://scripts/core/trace_logger.gd")
const PokemonCatalog := preload("res://scripts/data/pokemon_catalog.gd")
const PokemonRules := preload("res://scripts/domain/pokemon_rules.gd")
const SessionState := preload("res://scripts/runtime/session_state.gd")
const SaveStore := preload("res://scripts/runtime/save_store.gd")
const BattleRuntime := preload("res://scripts/runtime/battle_runtime.gd")

var trace = TraceLogger.new()
var catalog = PokemonCatalog.new()
var pokemon_rules = PokemonRules.new()
var session = SessionState.new()
var save_store = SaveStore.new()
var battle_runtime = BattleRuntime.new()
var _rng = RandomNumberGenerator.new()
var _initialized = false


func _ready() -> void:
	_rng.randomize()
	catalog.setup(trace)
	battle_runtime.setup(session, catalog, pokemon_rules, trace)


func ensure_initialized() -> void:
	if _initialized:
		return

	catalog.load_all()
	var payload = save_store.load_payload()
	if payload.is_empty() or not _apply_loaded_payload(payload):
		new_game()
	else:
		trace.emit_event("session_loaded", "GameRuntime", {
			"party_size": session.party.size(),
			"player_tile": _tile_payload(session.player_tile)
		})
		_initialized = true


func new_game() -> void:
	var starter = _build_starter()
	session.reset_for_new_game(int(_rng.randi() & 0x7fffffff), starter)
	_initialized = true
	save_game()
	trace.emit_event("session_created", "GameRuntime", {
		"world_seed": session.world_seed,
		"party_size": session.party.size()
	})


func save_game() -> void:
	if not save_store.write_payload(session.to_save_payload()):
		trace.warning("GameRuntime", "Could not write save file.", {})
		return
	trace.emit_event("save_written", "GameRuntime", {
		"party_size": session.party.size(),
		"player_tile": _tile_payload(session.player_tile)
	})


func emit_trace(event_name: String, source: String, payload: Dictionary = {}) -> void:
	trace.emit_event(event_name, source, payload)


func warn(source: String, message: String, payload: Dictionary = {}) -> void:
	trace.warning(source, message, payload)


func get_world_seed() -> int:
	return session.world_seed


func get_player_tile() -> Vector2i:
	return session.player_tile


func set_player_tile(tile_position: Vector2i) -> void:
	session.player_tile = tile_position


func get_party_snapshot() -> Array:
	return session.get_party_snapshot()


func get_item_count(item_id: String) -> int:
	return session.get_item_count(item_id)


func set_party_lead(index: int) -> void:
	session.set_party_lead(index)


func generate_wild_encounter(tile_pos: Vector2i) -> Dictionary:
	var species_id = catalog.get_random_encounter_species(_rng)
	var species_entry = {}
	if not species_id.is_empty():
		species_entry = catalog.get_species(species_id)
	if species_entry.is_empty():
		species_entry = _fallback_species_entry()
		if species_entry.is_empty():
			trace.warning("GameRuntime", "Could not build a fallback encounter species; using a synthetic battle mon.", {})
			return _synthetic_pokemon_instance("SmokeMon", level_from_distance(tile_pos))
		trace.warning("GameRuntime", "Encounter species list was empty; using a fallback species.", {
			"fallback_species_id": str(species_entry.get("species_id", ""))
		})
	var distance = abs(tile_pos.x) + abs(tile_pos.y)
	var level = level_from_distance(tile_pos)
	return pokemon_rules.create_pokemon_instance(species_entry, level, Callable(catalog, "get_move"))


func start_wild_battle(wild_mon: Dictionary) -> Dictionary:
	trace.emit_event("encounter_started", "GameRuntime", {
		"species_id": str(wild_mon.get("species_id", "")),
		"level": int(wild_mon.get("level", 1))
	})
	return battle_runtime.start_wild_battle(wild_mon)


func perform_battle_move(index: int) -> Dictionary:
	var response = battle_runtime.perform_move(index)
	if bool(response.get("finished", false)):
		save_game()
	return response


func use_pokeball() -> Dictionary:
	var response = battle_runtime.use_pokeball()
	if bool(response.get("finished", false)):
		save_game()
	return response


func use_potion() -> Dictionary:
	return battle_runtime.use_potion()


func run_from_battle() -> Dictionary:
	var response = battle_runtime.run_from_battle()
	if bool(response.get("finished", false)):
		save_game()
	return response


func _apply_loaded_payload(payload: Dictionary) -> bool:
	var normalized_party: Array = []
	var loaded_party = payload.get("party", [])
	if loaded_party is Array:
		for mon_variant in loaded_party:
			if mon_variant is Dictionary:
				normalized_party.append(pokemon_rules.normalize_loaded_mon(mon_variant))
	if normalized_party.is_empty():
		return false
	session.apply_loaded_state(payload, normalized_party)
	return true


func _build_starter() -> Dictionary:
	var starter_species = _fallback_species_entry()
	var starter = pokemon_rules.create_pokemon_instance(starter_species, 5, Callable(catalog, "get_move"))
	if not starter.is_empty():
		return starter

	var fallback_id = catalog.get_random_encounter_species(_rng)
	if fallback_id.is_empty():
		return _synthetic_pokemon_instance("StarterMon", 5)
	return pokemon_rules.create_pokemon_instance(catalog.get_species(fallback_id), 5, Callable(catalog, "get_move"))


func _tile_payload(tile_position: Vector2i) -> Array:
	return [tile_position.x, tile_position.y]


func level_from_distance(tile_pos: Vector2i) -> int:
	var distance = abs(tile_pos.x) + abs(tile_pos.y)
	return clampi(2 + int(distance / 24) + _rng.randi_range(0, 3), 2, 80)


func _fallback_species_entry() -> Dictionary:
	var starter_species = catalog.get_species("CHIKORITA")
	if not starter_species.is_empty():
		return starter_species
	for species_entry in catalog.species.values():
		if species_entry is Dictionary and not (species_entry as Dictionary).is_empty():
			return species_entry
	return {}


func _synthetic_pokemon_instance(name: String, level: int) -> Dictionary:
	var stats = pokemon_rules.build_stats({
		"hp": 45,
		"atk": 49,
		"def": 49,
		"spe": 45,
		"sat": 49,
		"sdf": 49
	}, clampi(level, 1, 100))
	var max_hp = int(stats.get("hp", 1))
	return {
		"species_id": "SMOKE_MON",
		"name": name,
		"level": clampi(level, 1, 100),
		"exp": pokemon_rules.experience_for_level(level),
		"types": PackedStringArray(["NORMAL", "NORMAL"]),
		"stats": stats,
		"max_hp": max_hp,
		"current_hp": max_hp,
		"moves": [{
			"move_id": "TACKLE",
			"name": "Tackle",
			"power": 40,
			"accuracy": 100,
			"type": "NORMAL",
			"category": "PHYSICAL",
			"max_pp": 35,
			"pp": 35
		}],
		"front_path": "",
		"back_path": ""
	}
