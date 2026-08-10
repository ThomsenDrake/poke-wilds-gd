extends Node

const TraceLogger := preload("res://scripts/core/trace_logger.gd")
const PokemonCatalog := preload("res://scripts/data/pokemon_catalog.gd")
const PokemonRules := preload("res://scripts/domain/pokemon_rules.gd")
const FieldMoves := preload("res://scripts/domain/field_moves.gd")
const WorldOverrides := preload("res://scripts/domain/world_overrides.gd")
const SessionState := preload("res://scripts/runtime/session_state.gd")
const SessionPayload := preload("res://scripts/runtime/session_payload.gd") # the creation-identity normalizers (begin_created_game mirrors the load path)
const SaveStore := preload("res://scripts/runtime/save_store.gd")
const BattleRuntime := preload("res://scripts/runtime/battle_runtime.gd")
const BuildRuntime := preload("res://scripts/runtime/build_runtime.gd")
const HarvestRuntime := preload("res://scripts/runtime/harvest_runtime.gd")
const StorageRuntime := preload("res://scripts/runtime/storage_runtime.gd")
const MusicRouter := preload("res://scripts/runtime/music_router.gd")
const WorldGenerator := preload("res://scripts/domain/world_generator.gd")
const BiomeEncounters := preload("res://scripts/domain/biome_encounters.gd")
const EncounterSelection := preload("res://scripts/domain/encounter_selection.gd")
const DayPhase := preload("res://scripts/domain/day_phase.gd")
const NightSystem := preload("res://scripts/runtime/night_system.gd")
const MaterialDrops := preload("res://scripts/domain/material_drops.gd")
const CraftingRuntime := preload("res://scripts/runtime/crafting_runtime.gd")
const CampingRuntime := preload("res://scripts/runtime/camping_runtime.gd")
const FieldMoveRuntime := preload("res://scripts/runtime/field_move_runtime.gd")
const HabitatRuntime := preload("res://scripts/runtime/habitat_runtime.gd")
const FishingRuntime := preload("res://scripts/runtime/fishing_runtime.gd")
const BreedingRuntime := preload("res://scripts/runtime/breeding_runtime.gd")
const OverworldMonsRuntime := preload("res://scripts/runtime/overworld_mons_runtime.gd")
const LandmarkRuntime := preload("res://scripts/runtime/landmark_runtime.gd")
const WildEncounterDraw := preload("res://scripts/runtime/wild_encounter_draw.gd")

signal world_overridden(tile: Vector2i) # per harvest/placement so the view re-renders the tile in place

var trace = TraceLogger.new()
var catalog = PokemonCatalog.new()
var pokemon_rules = PokemonRules.new()
var session = SessionState.new()
var save_store = SaveStore.new()
var battle_runtime = BattleRuntime.new()
var build_runtime = BuildRuntime.new()
var harvest_runtime = HarvestRuntime.new()
var storage_runtime = StorageRuntime.new()
var music_router = MusicRouter.new()
var _world_gen = WorldGenerator.new()
var _biome_encounters = BiomeEncounters.new()
var night_system = NightSystem.new()
var crafting_runtime = CraftingRuntime.new()
var camping_runtime = CampingRuntime.new()
var field_move_runtime = FieldMoveRuntime.new()
var habitat_runtime = HabitatRuntime.new()
var fishing_runtime = FishingRuntime.new()
var breeding_runtime = BreedingRuntime.new()
var overworld_mons_runtime = OverworldMonsRuntime.new()
var landmark_runtime = LandmarkRuntime.new()
var wild_encounter_draw = WildEncounterDraw.new()
var stone_evolution_runtime = preload("res://scripts/runtime/stone_evolution_runtime.gd").new()
var player_avatar: Node = null # wired by field_action_router.setup; seed_for_smoke pins its trigger-draw rng
var _rng = RandomNumberGenerator.new()
var _initialized = false
var _boot_save_loaded := false # set ONLY in ensure_initialized's session_loaded branch (the title-screen CONTINUE gate)

func _ready() -> void:
	_rng.randomize()
	catalog.setup(trace)
	save_store.setup(trace)
	battle_runtime.setup(session, catalog, pokemon_rules, trace, Callable(self, "_retreat_allowed"))
	build_runtime.setup(session, catalog, trace, _world_gen)
	harvest_runtime.setup(session, catalog, trace, _world_gen, build_runtime, world_overridden.emit)
	storage_runtime.setup(session, trace, _world_gen, Callable(catalog, "get_species"))
	night_system.setup(session, catalog, trace, Callable(_world_gen, "placements_for_save"), Callable(_biome_encounters, "is_battle_viable"), _rng)
	crafting_runtime.setup(session, catalog, trace)
	camping_runtime.setup(session, trace)
	field_move_runtime.setup(session, catalog, trace, _world_gen, night_system, world_overridden.emit) # Phase-7 audit: NO _rng — the eight moves roll nothing (a future roll re-injects it, the fishing_runtime precedent)
	habitat_runtime.setup(session, catalog, pokemon_rules, trace, _world_gen)
	fishing_runtime.setup(session, catalog, pokemon_rules, trace, _world_gen, _rng, Callable(catalog, "get_move"))
	breeding_runtime.setup(session, catalog, pokemon_rules, trace, _world_gen, _rng, world_overridden.emit, self)
	overworld_mons_runtime.setup(session, catalog, pokemon_rules, trace, _world_gen, _biome_encounters, field_move_runtime) # Phase 6: NO _rng — the derived-hash stream (spec § Determinism)
	overworld_mons_runtime.encounter_requested.connect(_on_entity_encounter) # forced-battle presentation bridge (zero main.gd lines)
	landmark_runtime.setup(session, catalog, trace, _world_gen, _biome_encounters, overworld_mons_runtime, music_router) # Phase 7 Build 1: entry/puzzle/scope; state ONLY via the frozen seam
	_world_gen.landmark_resolver = Callable(landmark_runtime, "tile_logic_for_active") # footprints + the door overlay at the single mutation boundary
	wild_encounter_draw.setup(session, catalog, pokemon_rules, trace, _rng, night_system, landmark_runtime, _biome_encounters) # Build-2 extraction: generate_wild_encounter's wild-draw tail (the shared _rng rides by REFERENCE)
	stone_evolution_runtime.setup(session, catalog, pokemon_rules, trace)
	# Placements reuse the harvest sync path: one signal, world_view re-renders in place.
	build_runtime.structure_placed.connect(func(tile: Vector2i) -> void: breeding_runtime.note_structures_changed(); world_overridden.emit(tile))
	build_runtime.structure_removed.connect(func(tile: Vector2i) -> void: breeding_runtime.note_structures_changed(); world_overridden.emit(tile))
	music_router.setup(trace) # under this autoload so its lazy player is in the tree and audible
	add_child(music_router)
	add_child(preload("res://scripts/runtime/performance_monitors.gd").new()) # release-build-queryable agent surface (Performance.get_custom_monitor); self-registers in _ready, unregisters in _exit_tree

func ensure_initialized(silent_new_game: bool = true) -> void:
	if _initialized:
		return
	catalog.load_all()
	var payload = save_store.load_payload()
	if not payload.is_empty() and int(payload.get("version", 1)) < SessionState.SAVE_VERSION and not SessionState.SaveMigration.can_represent_infinite(payload): # infinite-world slice: a TRULY CHAINED legacy save can't be one plane — preserve + fresh start (.newer.bak precedent); chain-less flattens losslessly in apply
		warn("GameRuntime", "Chained save cannot represent a single infinite world; preserved it and starting fresh.", {"preserved_path": save_store._preserve(".chained.bak")}) # _preserve ARMS live-path protection on preserve-failure (the .corrupt.bak/.newer.bak precedent — the autosave can never clobber the un-preserved chained save)
		if silent_new_game: new_game()
		return
	if not payload.is_empty() and _apply_loaded_payload(payload):
		trace.emit_event("session_loaded", "GameRuntime", {
			"party_size": session.party.size(), "player_tile": _tile_payload(session.player_tile)})
		_boot_save_loaded = true; _initialized = true
		return
	if not payload.is_empty(): # parsed-but-unapplicable save: preserve player data before new_game()
		warn("GameRuntime", "Save parsed but could not be applied; preserved it and starting fresh.", {"preserved_path": save_store._preserve(".unusable.bak")}) # _preserve ARMS live-path protection on failure (the .chained.bak precedent — never clobber on a failed preserve)
	if silent_new_game: new_game()

# Creation-flow seam (title_flow slice): commits identity/odds through the SAME normalizers the load path
# rides (session_payload), THEN the pinned new_game draw order (starter shiny first, world seed second). No choice consumes the shared _rng; the pause-menu path never rides this seam.
func begin_created_game(creation: Dictionary) -> void:
	session.player_name = SessionPayload.normalize_player_name(creation.get("player_name", SessionState.DEFAULT_PLAYER_NAME))
	session.player_avatar = SessionPayload.normalize_player_avatar(creation.get("player_avatar", SessionState.DEFAULT_PLAYER_AVATAR))
	session.shiny_odds_choice = SessionPayload.normalize_shiny_odds(creation.get("shiny_odds", SessionState.SHINY_ODDS_DEFAULT))
	PokemonRules.shiny_odds = session.shiny_odds_choice
	new_game(int(creation.get("world_seed", -1)))

func new_game(custom_seed: int = -1) -> void:
	var starter = _build_starter()
	var world_seed: int = custom_seed if custom_seed >= 0 else int(_rng.randi() & 0x7fffffff) # the infinite-world seed (infinite-world slice: one seamless plane): the start menu's SeedPrompt choice, or the shared _rng draw — the starter draw above ALWAYS runs first, so a custom seed skips ONLY this one draw (the pinned stream order)
	_world_gen.clear_overrides(); _world_gen.clear_placements()
	session.world_seed = world_seed; session.landmark_state = {} # BEFORE the scan: the landmark resolver seam reads
	# both off the SESSION (footprints + the door overlay), so a pre-reset scan rates candidates against the PREVIOUS world's footprints and can commit a walled spawn; find_walkable_spawn's own setup(seed) reseeds the generator (no explicit setup here), and the scan draws no shared _rng.
	var spawn = _world_gen.find_walkable_spawn(world_seed)
	session.reset_for_new_game(world_seed, starter, spawn); _initialized = true
	overworld_mons_runtime.stamp_legendaries() # Build 2: the frozen seven as world-fixed statics (AFTER the reset sets the seed)
	save_game()
	trace.emit_event("session_created", "GameRuntime", {"world_seed": session.world_seed,
		"player_tile": _tile_payload(session.player_tile), "party_size": session.party.size()})

func save_game() -> void: # split save: clears + placements stay two keys; the merged map is view-only
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
func has_loaded_save() -> bool: return _boot_save_loaded

func set_player_tile(tile_position: Vector2i) -> void: session.player_tile = tile_position

# One overworld step: lifetime counter + one clock minute + the repel decay (session) + the Phase 5 habitat + breeding ticks + the Phase 6 entity tick.
func note_player_step() -> void:
	session.note_step_taken()
	session.advance_time(1)
	habitat_runtime.note_step()
	breeding_runtime.tick() # party-egg hatch countdown + rate-limited pen lay scan
	overworld_mons_runtime.note_player_step(int(session.total_steps), session.player_tile, DayPhase.time_of_day_label(session.time_of_day_minutes)) # Phase 6: after habitat/breeding
	landmark_runtime.note_player_step(session.player_tile) # Phase 7: entry traces + tower music + ruins guardian (after the Phase 6 tick)

func get_time_of_day_minutes() -> int: return session.time_of_day_minutes


# True when ANY party member can perform the field move (the single capability check).
func party_has_field_move_ability(move_id: String) -> bool:
	var get_species := Callable(catalog, "get_species")
	for mon in session.party:
		if mon is Dictionary and FieldMoves.can_perform(mon, move_id, get_species):
			return true
	return false


func get_campsite_pokemon() -> Array: return camping_runtime.get_campsite_pokemon() # campsite hold lives in camping_runtime
func retrieve_campsite_mon(index: int) -> Dictionary: return camping_runtime.retrieve_campsite_mon(index)


# Harvest/demolish lives in harvest_runtime; callers keep this name.
func harvest_tile(tile: Vector2i, mon_constraint: Dictionary = {}) -> Dictionary:
	return harvest_runtime.harvest_tile(tile, mon_constraint)

func deposit_to_nearest(party_index: int) -> Dictionary: # box first; Phase 5 falls back to the nearest pen
	var result := storage_runtime.deposit_to_nearest(party_index)
	return result if str(result.get("reason", "")) != "no_box" else breeding_runtime.deposit_to_nearest_pen(party_index) # Phase 5: no box -> nearest pen


# Party-screen DEPOSIT gate callable (RUNTIME_METHODS maps "box_tile_near" here): {found, tile}, never a sentinel.
func box_tile_near(center: Vector2i) -> Dictionary:
	return storage_runtime.box_tile_near(center)


func nearest_box_tile() -> Dictionary:
	return storage_runtime.nearest_box_tile()


# Phase 5 breeding pen pass-throughs (party-screen DEPOSIT gate, fence-Z action, ground-egg render read).
func pen_tile_near(center: Vector2i) -> Dictionary: return breeding_runtime.pen_tile_near(center)
func breeding_interact(faced: Vector2i) -> Dictionary: return breeding_runtime.interact(session.player_tile, faced)
func ground_egg_at(tile: Vector2i) -> Dictionary: return breeding_runtime.ground_egg_at(tile)
func use_stone_on_mon(item_id: String, party_index: int) -> Dictionary: return stone_evolution_runtime.use_stone_on_mon(item_id, party_index) # stone slice seam; one of breed_flow_checks.STONE_SEAM_METHODS so run_stone_case auto-arms


# Single capability gate for harvest AND build: a constrained mon must itself be able; else any party member.
func field_move_capable(move_id: String, mon_constraint: Dictionary = {}) -> bool:
	if not mon_constraint.is_empty():
		return FieldMoves.can_perform(mon_constraint, move_id, Callable(catalog, "get_species"))
	return party_has_field_move_ability(move_id)


# MERGED clears+placements (placements shadow) for the world_view mirror — NEVER the save (split keys).
func mutations_for_view() -> Dictionary: return _world_gen.mutations_for_view()


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


# Smoke determinism seam: pins EVERY shared rng (encounter _rng, battle, the avatar's trigger-draw stream) so a scenario's inputs are a pure function of (code, save, seed), never _ready's wall-clock randomize().
func seed_for_smoke(seed: int) -> void:
	_rng.seed = seed
	battle_runtime._rng.seed = seed
	if player_avatar != null: player_avatar._rng.seed = seed

func generate_wild_encounter(tile_pos: Vector2i, biome: String = "") -> Dictionary:
	var provoked_mon := overworld_mons_runtime.take_pending_encounter() # Phase 6: a provoked/attacked entity rides the seam FIRST...
	if not provoked_mon.is_empty(): # ...so repel + night ghosts never touch a forced battle (fishing precedent)
		_trace_legendary_encounter(provoked_mon) # Build 2: the registry-REQUIRED battle-start trace (no-op unless battle_kind "legendary")
		return provoked_mon
	var hooked := fishing_runtime.take_pending_encounter() # Phase 5 fishing: a just-hooked mon rides this seam...
	if not hooked.is_empty(): return hooked # ...BEFORE the wild draw, so repel + night ghosts never touch fishing
	if field_move_runtime.repel_suppresses(): return {} # repel short-circuits BEFORE any encounter rng is consumed
	return wild_encounter_draw.draw(tile_pos, biome) # Build-2 extraction: scope + night ghosts + the draw + shiny_rolled


func _trace_legendary_encounter(mon: Dictionary) -> void: WildEncounterDraw.trace_legendary(mon, trace)

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


# Battle-end: grant the interim type drop on victory/capture; the Phase 5 fishing + Phase 6
# entity marks consume here (each runtime owns its own trace); then save.
func _finish_battle(response: Dictionary) -> Dictionary:
	if not bool(response.get("finished", false)): return response
	var outcome := str(response.get("outcome", ""))
	var enemy: Dictionary = battle_runtime.get_snapshot().get("enemy_mon", {})
	overworld_mons_runtime.note_battle_outcome(outcome, enemy) # reset on EVERY finished battle; removes on ko/catch (:288)
	if ["victory", "caught", "caught_box_full"].has(outcome):
		var drop := MaterialDrops.drop_for(catalog.get_species(str(enemy.get("species_id", ""))))
		if not drop.is_empty():
			session.add_item(drop, 1)
			trace.emit_event("material_dropped", "GameRuntime", {"species_id": str(enemy.get("species_id", "")), "item_id": drop})
	fishing_runtime.note_battle_finished(outcome, str(enemy.get("species_id", ""))) # fish_caught on a fishing capture
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
	session.apply_loaded_state(payload, normalized_party); PokemonRules.shiny_odds = maxi(1, session.shiny_odds_choice)
	_world_gen.setup(session.world_seed) # re-seed to the loaded world, then restore overrides exactly
	_world_gen.clear_overrides()
	var saved_overrides: Variant = payload.get("world_overrides", {})
	if saved_overrides is Dictionary:
		apply_world_overrides(saved_overrides)
	# Placements (v3-additive "structures" key; the session normalized it, absent -> {}): feed the generator's placement map.
	_world_gen.clear_placements()
	_world_gen.apply_placements(session.structures)
	breeding_runtime.apply_save_state(session.pastures) # v4-additive pen state (validates AFTER placements land)
	overworld_mons_runtime.stamp_legendaries() # Build 2: the frozen seven, suppressed by the loaded legendary_removals (AFTER apply_loaded_state)
	return true


func _build_starter() -> Dictionary:
	return EncounterSelection.build_starter_traced(catalog, pokemon_rules, _rng, Callable(catalog, "get_move"), trace)

func _tile_payload(tile_position: Vector2i) -> Array: return [tile_position.x, tile_position.y]

# Live placements (save shape, incl. the additive "lit" field) for the night system's light read.
func placed_structures() -> Dictionary: return _world_gen.placements_for_save()

func _retreat_allowed() -> bool: return night_system.retreat_allowed() # injected into battle_runtime.setup (shadow battles block retreat)
func _on_entity_encounter(tile: Vector2i) -> void: # Phase 6 forced-battle bridge: the normal presentation path, zero main.gd lines
	var player = get_node_or_null("/root/Main/Player") # absent (headless scenarios) ⇒ no-op; _in_battle guards double emission
	if player != null: player.encounter_requested.emit(tile) # main._on_encounter_requested takes the pending mon
