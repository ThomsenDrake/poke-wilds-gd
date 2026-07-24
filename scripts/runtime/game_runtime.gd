extends Node

const TraceLogger := preload("res://scripts/core/trace_logger.gd")
const PokemonCatalog := preload("res://scripts/data/pokemon_catalog.gd")
const PokemonRules := preload("res://scripts/domain/pokemon_rules.gd")
const FieldMoves := preload("res://scripts/domain/field_moves.gd")
const WorldOverrides := preload("res://scripts/domain/world_overrides.gd")
const HarvestResolver := preload("res://scripts/runtime/harvest_resolver.gd")
const SessionState := preload("res://scripts/runtime/session_state.gd")
const SaveStore := preload("res://scripts/runtime/save_store.gd")
const BattleRuntime := preload("res://scripts/runtime/battle_runtime.gd")
const BuildRuntime := preload("res://scripts/runtime/build_runtime.gd")
const MusicRouter := preload("res://scripts/runtime/music_router.gd")
const WorldGenerator := preload("res://scripts/domain/world_generator.gd")
const BiomeEncounters := preload("res://scripts/domain/biome_encounters.gd")
const EncounterSelection := preload("res://scripts/domain/encounter_selection.gd")
const DayPhase := preload("res://scripts/domain/day_phase.gd")
const NightSystem := preload("res://scripts/runtime/night_system.gd")
const MaterialDrops := preload("res://scripts/domain/material_drops.gd")
const CraftingRuntime := preload("res://scripts/runtime/crafting_runtime.gd")
const CampingRuntime := preload("res://scripts/runtime/camping_runtime.gd")

# Emitted per successful harvest so the view can re-render the tile without a world rebuild.
signal world_overridden(tile: Vector2i)

var trace = TraceLogger.new()
var catalog = PokemonCatalog.new()
var pokemon_rules = PokemonRules.new()
var session = SessionState.new()
var save_store = SaveStore.new()
var battle_runtime = BattleRuntime.new()
var build_runtime = BuildRuntime.new()
var music_router = MusicRouter.new()
var _world_gen = WorldGenerator.new()
var _biome_encounters = BiomeEncounters.new()
var night_system = NightSystem.new()
var crafting_runtime = CraftingRuntime.new()
var camping_runtime = CampingRuntime.new()
var _rng = RandomNumberGenerator.new()
var _initialized = false


func _ready() -> void:
	_rng.randomize()
	catalog.setup(trace)
	save_store.setup(trace)
	battle_runtime.setup(session, catalog, pokemon_rules, trace, Callable(self, "_retreat_allowed"))
	build_runtime.setup(session, catalog, trace, _world_gen)
	night_system.setup(session, catalog, trace, Callable(_world_gen, "placements_for_save"), Callable(_biome_encounters, "is_battle_viable"), _rng)
	crafting_runtime.setup(session, catalog, trace)
	camping_runtime.setup(session, trace)
	# Placements reuse the harvest sync path: one signal, world_view re-renders in place.
	build_runtime.structure_placed.connect(func(tile: Vector2i) -> void: world_overridden.emit(tile))
	build_runtime.structure_removed.connect(func(tile: Vector2i) -> void: world_overridden.emit(tile))
	# The router lives under this autoload so its lazy player is in the tree and audible.
	music_router.setup(trace)
	add_child(music_router)


func ensure_initialized() -> void:
	if _initialized:
		return
	catalog.load_all()
	var payload = save_store.load_payload()
	if not payload.is_empty() and _apply_loaded_payload(payload):
		trace.emit_event("session_loaded", "GameRuntime", {
			"party_size": session.party.size(), "player_tile": _tile_payload(session.player_tile)})
		_initialized = true
		return
	# A parsed-but-unapplicable save still holds player data; preserve it before new_game().
	if not payload.is_empty():
		warn("GameRuntime", "Save parsed but could not be applied; preserved it and starting fresh.", {"preserved_path": save_store.preserve_save(".unusable.bak")})
	new_game()


func new_game() -> void:
	_world_gen.clear_overrides()
	_world_gen.clear_placements()
	var starter = _build_starter()
	var seed = int(_rng.randi() & 0x7fffffff)
	var spawn = _world_gen.find_walkable_spawn(seed)
	session.reset_for_new_game(seed, starter, spawn)
	_initialized = true
	save_game()
	trace.emit_event("session_created", "GameRuntime", {"world_seed": session.world_seed,
		"player_tile": _tile_payload(session.player_tile), "party_size": session.party.size()})


func save_game() -> void:
	# Split save: clears ("world_overrides") + placements ("structures") stay two keys; the merged map is view-only.
	if not save_store.write_payload(session.to_save_payload(_world_gen.overrides_for_save(), _world_gen.placements_for_save())):
		trace.warning("GameRuntime", "Could not write save file.", {})
		return
	trace.emit_event("save_written", "GameRuntime", {"party_size": session.party.size(),
		"player_tile": _tile_payload(session.player_tile)})


func emit_trace(event_name: String, source: String, payload: Dictionary = {}) -> void:
	trace.emit_event(event_name, source, payload)


func warn(source: String, message: String, payload: Dictionary = {}) -> void:
	trace.warning(source, message, payload)


func get_world_seed() -> int: return session.world_seed


func get_player_tile() -> Vector2i: return session.player_tile


func set_player_tile(tile_position: Vector2i) -> void:
	session.player_tile = tile_position


# One completed overworld step: lifetime counter plus one minute of clock time.
func note_player_step() -> void:
	session.note_step_taken()
	session.advance_time(1)


func get_time_of_day_minutes() -> int: return session.time_of_day_minutes


# True when any party member can perform the field move (the single capability check).
func party_has_field_move_ability(move_id: String) -> bool:
	var get_species := Callable(catalog, "get_species")
	for mon in session.party:
		if mon is Dictionary and FieldMoves.can_perform(mon, move_id, get_species):
			return true
	return false


# Campsite hold (Phase 0 defect 0.1) now lives in camping_runtime; these keep callers working.
func get_campsite_pokemon() -> Array: return camping_runtime.get_campsite_pokemon()
func retrieve_campsite_mon(index: int) -> Dictionary: return camping_runtime.retrieve_campsite_mon(index)


# Harvests one faced tile through the shared resolver: action, capability, override stamp, yield, trace.
# A built tile instead routes to demolition (Cut refunds everything; hard-stone shells need Smash).
func harvest_tile(tile: Vector2i, mon_constraint: Dictionary = {}) -> Dictionary:
	var logic: Dictionary = _world_gen.get_tile_logic(tile)
	var action := HarvestResolver.action_for_tile(logic)
	if action.is_empty():
		if str(logic.get("override_kind", "")) == "placed":
			return build_runtime.try_demolish(tile, mon_constraint)
		return {"ok": false, "move_id": "", "message": "There is nothing left here.", "yield_item": ""}
	if not field_move_capable(action, mon_constraint):
		var mon_name := str(mon_constraint.get("name", "")) if not mon_constraint.is_empty() else ""
		return {"ok": false, "move_id": action, "message": HarvestResolver.refusal_message(action, logic, mon_name), "yield_item": ""}
	var yield_item := HarvestResolver.yield_for(action, logic)
	if yield_item.is_empty() or not _world_gen.add_override(tile, HarvestResolver.kind_for(action), action, session.total_steps):
		trace.warning("GameRuntime", "Harvest was refused by the world override map.", {"tile": _tile_payload(tile), "move_id": action})
		return {"ok": false, "move_id": action, "message": "Nothing happened.", "yield_item": ""}
	session.add_item(yield_item)
	trace.emit_event("field_move_used", "GameRuntime", {
		"move_id": action,
		"tile": _tile_payload(tile),
		"yield": yield_item
	})
	world_overridden.emit(tile)
	var item_name := str(catalog.get_item(yield_item).get("display_name", yield_item))
	return {"ok": true, "move_id": action, "message": HarvestResolver.success_message(action, item_name), "yield_item": yield_item}


# Single capability gate for harvest AND build: a constrained mon must itself be able; else any party member.
func field_move_capable(move_id: String, mon_constraint: Dictionary = {}) -> bool:
	if not mon_constraint.is_empty():
		return FieldMoves.can_perform(mon_constraint, move_id, Callable(catalog, "get_species"))
	return party_has_field_move_ability(move_id)


# MERGED clears + placements (placements shadow) for the world_view mirror; the name mirrors the
# generator. NEVER feed it to the SAVE (stays split via save_game); clears-only readers use
# _world_gen.overrides_for_save().
func mutations_for_view() -> Dictionary:
	return _world_gen.mutations_for_view()


func apply_world_overrides(saved: Dictionary) -> void:
	if saved.size() > WorldOverrides.MAX_OVERRIDES:
		trace.warning("GameRuntime", "Saved world overrides exceed the cap; extra entries were dropped.",
			{"saved_entries": saved.size(), "cap": WorldOverrides.MAX_OVERRIDES})
	_world_gen.apply_overrides(saved)


func get_party_snapshot() -> Array:
	return session.get_party_snapshot()


func get_item_count(item_id: String) -> int:
	return session.get_item_count(item_id)


func set_party_lead(index: int) -> void:
	session.set_party_lead(index)


# Smoke determinism seam (house seeding convention; visual_sweep pins
# battle_runtime._rng directly, playtest_soak its bot): pins BOTH rngs so a
# scenario's audited inputs are a pure function of (code, save, seed), never
# the per-process wall-clock seed from _ready's randomize().
func seed_for_smoke(seed: int) -> void:
	_rng.seed = seed
	battle_runtime._rng.seed = seed


func generate_wild_encounter(tile_pos: Vector2i, biome: String = "") -> Dictionary:
	var species_id = _pick_encounter_species(biome)
	var species_entry = {}
	if not species_id.is_empty():
		species_entry = catalog.get_species(species_id)
	if species_entry.is_empty():
		species_entry = EncounterSelection.fallback_species_entry(catalog.species)
		if species_entry.is_empty():
			trace.warning("GameRuntime", "Species catalog is empty; skipping the wild encounter.", {"biome": biome})
			return {}
		trace.warning("GameRuntime", "Encounter species list was empty; using a fallback species.",
			{"fallback_species_id": str(species_entry.get("species_id", ""))})
	var level = EncounterSelection.level_from_distance(tile_pos, _rng)
	return pokemon_rules.create_pokemon_instance(species_entry, level, Callable(catalog, "get_move"))


func _pick_encounter_species(biome: String) -> String:
	# Night danger: unlit-night draws may become shadow ghosts (night_system rolls the shared _rng; empty by day or in light).
	var ghost := night_system.try_ghost_species(session.player_tile)
	if not ghost.is_empty(): return ghost
	if not biome.is_empty():
		var filtered = _biome_encounters.filter_species_ids(catalog.species, biome, DayPhase.time_of_day_label(session.time_of_day_minutes))
		if bool(filtered.get("used_fallback", false)):
			trace.warning("GameRuntime", "Biome encounter filter fell back to the full catalog.",
				{"biome": biome, "reason": str(filtered.get("reason", ""))})
		var ids = filtered.get("ids", [])
		if ids is Array and not (ids as Array).is_empty():
			return str(ids[_rng.randi_range(0, (ids as Array).size() - 1)])
	return catalog.get_random_encounter_species(_rng)


func start_wild_battle(wild_mon: Dictionary) -> Dictionary:
	night_system.begin_battle(wild_mon)
	trace.emit_event("encounter_started", "GameRuntime", {
		"species_id": str(wild_mon.get("species_id", "")),
		"level": int(wild_mon.get("level", 1))
	})
	return battle_runtime.start_wild_battle(wild_mon)


func perform_battle_move(index: int) -> Dictionary:
	return _finish_battle(battle_runtime.perform_move(index))


func use_pokeball() -> Dictionary:
	return _finish_battle(battle_runtime.use_pokeball())


func use_potion() -> Dictionary:
	return battle_runtime.use_potion()


func run_from_battle() -> Dictionary:
	return _finish_battle(battle_runtime.run_from_battle())


# Battle-end: grant the interim type-derived material drop on victory/capture, then save.
func _finish_battle(response: Dictionary) -> Dictionary:
	if not bool(response.get("finished", false)): return response
	if ["victory", "caught", "caught_box_full"].has(str(response.get("outcome", ""))):
		var enemy: Dictionary = battle_runtime.get_snapshot().get("enemy_mon", {})
		var drop := MaterialDrops.drop_for(catalog.get_species(str(enemy.get("species_id", ""))))
		if not drop.is_empty():
			session.add_item(drop, 1)
			trace.emit_event("material_dropped", "GameRuntime", {"species_id": str(enemy.get("species_id", "")), "item_id": drop})
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
	# Re-seed the generator to the loaded world, then restore saved overrides exactly.
	_world_gen.setup(session.world_seed)
	_world_gen.clear_overrides()
	var saved_overrides: Variant = payload.get("world_overrides", {})
	if saved_overrides is Dictionary:
		apply_world_overrides(saved_overrides)
	# Placements (v3-additive "structures" key): the session normalized the key
	# (absent/invalid backfills to {}); feed the generator's placement map.
	_world_gen.clear_placements()
	_world_gen.apply_placements(session.structures)
	return true


func _build_starter() -> Dictionary:
	var starter_species = EncounterSelection.fallback_species_entry(catalog.species)
	var starter = pokemon_rules.create_pokemon_instance(starter_species, 5, Callable(catalog, "get_move"))
	if not starter.is_empty():
		return starter

	var fallback_id = catalog.get_random_encounter_species(_rng)
	if fallback_id.is_empty():
		trace.warning("GameRuntime", "Species catalog is empty; starting a new game without a starter.", {})
		return {}
	return pokemon_rules.create_pokemon_instance(catalog.get_species(fallback_id), 5, Callable(catalog, "get_move"))


func _tile_payload(tile_position: Vector2i) -> Array: return [tile_position.x, tile_position.y]


# Live placements (save shape, incl. the additive "lit" field) for the night system's light read.
func placed_structures() -> Dictionary: return _world_gen.placements_for_save()


func _retreat_allowed() -> bool: return night_system.retreat_allowed() # injected into battle_runtime.setup (shadow battles block retreat)
