extends Node

const TraceLogger := preload("res://scripts/core/trace_logger.gd")
const PokemonCatalog := preload("res://scripts/data/pokemon_catalog.gd")
const PokemonRules := preload("res://scripts/domain/pokemon_rules.gd")
const SessionState := preload("res://scripts/runtime/session_state.gd")
const SaveStore := preload("res://scripts/runtime/save_store.gd")
const BattleRuntime := preload("res://scripts/runtime/battle_runtime.gd")
const MusicRouter := preload("res://scripts/runtime/music_router.gd")
const WorldGenerator := preload("res://scripts/domain/world_generator.gd")
const BiomeEncounters := preload("res://scripts/domain/biome_encounters.gd")

var trace = TraceLogger.new()
var catalog = PokemonCatalog.new()
var pokemon_rules = PokemonRules.new()
var session = SessionState.new()
var save_store = SaveStore.new()
var battle_runtime = BattleRuntime.new()
var music_router = MusicRouter.new()
var _world_gen = WorldGenerator.new()
var _biome_encounters = BiomeEncounters.new()
var _rng = RandomNumberGenerator.new()
var _initialized = false


func _ready() -> void:
	_rng.randomize()
	catalog.setup(trace)
	battle_runtime.setup(session, catalog, pokemon_rules, trace)
	# The router lives under this autoload so its lazily created player is in
	# the scene tree and audible; main.gd drives it via runtime.music_router.
	music_router.setup(trace)
	add_child(music_router)


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
	var seed = int(_rng.randi() & 0x7fffffff)
	var spawn = _world_gen.find_walkable_spawn(seed)
	session.reset_for_new_game(seed, starter, spawn)
	_initialized = true
	save_game()
	trace.emit_event("session_created", "GameRuntime", {
		"world_seed": session.world_seed,
		"player_tile": _tile_payload(session.player_tile),
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


# One completed overworld step: lifetime counter plus one minute of clock time.
func note_player_step() -> void:
	session.note_step_taken()
	session.advance_time(1)


func get_time_of_day_minutes() -> int:
	return session.time_of_day_minutes


func is_field_move_unlocked(move_id: String) -> bool:
	return session.is_field_move_unlocked(move_id)


func unlock_field_move(move_id: String) -> void:
	session.unlock_field_move(move_id)
	save_game()


func get_party_snapshot() -> Array:
	return session.get_party_snapshot()


func get_item_count(item_id: String) -> int:
	return session.get_item_count(item_id)


func set_party_lead(index: int) -> void:
	session.set_party_lead(index)


func generate_wild_encounter(tile_pos: Vector2i, biome: String = "") -> Dictionary:
	var species_id = _pick_encounter_species(biome)
	var species_entry = {}
	if not species_id.is_empty():
		species_entry = catalog.get_species(species_id)
	if species_entry.is_empty():
		species_entry = _fallback_species_entry()
		if species_entry.is_empty():
			trace.warning("GameRuntime", "Species catalog is empty; skipping the wild encounter.", {"biome": biome})
			return {}
		trace.warning("GameRuntime", "Encounter species list was empty; using a fallback species.", {
			"fallback_species_id": str(species_entry.get("species_id", ""))
		})
	var level = level_from_distance(tile_pos)
	return pokemon_rules.create_pokemon_instance(species_entry, level, Callable(catalog, "get_move"))


func _pick_encounter_species(biome: String) -> String:
	if not biome.is_empty():
		var filtered = _biome_encounters.filter_species_ids(catalog.species, biome)
		if bool(filtered.get("used_fallback", false)):
			trace.warning("GameRuntime", "Biome encounter filter fell back to the full catalog.", {
				"biome": biome,
				"reason": str(filtered.get("reason", ""))
			})
		var ids = filtered.get("ids", [])
		if ids is Array and not (ids as Array).is_empty():
			return str(ids[_rng.randi_range(0, (ids as Array).size() - 1)])
	return catalog.get_random_encounter_species(_rng)


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
		trace.warning("GameRuntime", "Species catalog is empty; starting a new game without a starter.", {})
		return {}
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
