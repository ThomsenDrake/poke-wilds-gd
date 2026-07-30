extends RefCounted

# Phase 7 Build 2 — the wild-draw tail EXTRACTED from game_runtime.generate_wild_encounter
# at the 320 wall (world-depth.md § Implementation shape :186 "EXTRACT another block"; the
# encounter_selection precedent). game_runtime keeps the SEAM ORDER (entity pending FIRST,
# fishing SECOND, the repel gate, the wild draw LAST) + the Build-2 legendary_encounter
# battle-start trace; this owns the draw itself: the footprint-local landmark scope, the
# night-ghost branch, the shared encounter _rng (injected by REFERENCE — never a new
# generator, the pinned wild stream) and the every-creation shiny_rolled trace (source
# string "GameRuntime" — byte-identical to the pre-extraction emit).

const PokemonRules := preload("res://scripts/domain/pokemon_rules.gd")
const EncounterSelection := preload("res://scripts/domain/encounter_selection.gd")
const DayPhase := preload("res://scripts/domain/day_phase.gd")

var _session = null
var _catalog = null
var _rules = null
var _trace = null
var _rng = null
var _night_system = null
var _landmark_runtime = null
var _biome_encounters = null

func setup(session_state, catalog, pokemon_rules, trace_logger, rng, night_system, landmark_runtime, biome_encounters) -> void:
	_session = session_state; _catalog = catalog; _rules = pokemon_rules; _trace = trace_logger
	_rng = rng; _night_system = night_system; _landmark_runtime = landmark_runtime; _biome_encounters = biome_encounters


# The wild draw: footprint-local token scope ("" outside -> byte-identical stream), the
# species pick (landmark table OR the world biome pool with the night-ghost branch), the
# instance + the every-creation shiny_rolled (odds provable both directions).
func draw(tile_pos: Vector2i, biome: String) -> Dictionary:
	var scope: Dictionary = _landmark_runtime.encounter_scope_for(tile_pos, biome) # Phase 7: footprint-local token scope ("" outside -> byte-identical stream)
	var species_id = _landmark_runtime.pick_species_for(scope, _biome_encounters, DayPhase.time_of_day_label(_session.time_of_day_minutes), _rng) if str(scope.get("token", "")) != "" else _pick_encounter_species(biome)
	var species_entry: Dictionary = EncounterSelection.species_entry_for(_catalog, species_id, str(scope.get("biome", biome)), _trace)
	if species_entry.is_empty():
		return {}
	var level = _landmark_runtime.level_for_scope(scope, species_id, tile_pos, _rng)
	var wild_mon: Dictionary = _rules.create_pokemon_instance(species_entry, level, Callable(_catalog, "get_move"), _rng)
	# shiny_rolled fires on EVERY creation (odds provable both directions; the shiny_odds scenario).
	_trace.emit_event("shiny_rolled", "GameRuntime", {"species_id": str(wild_mon.get("species_id", "")), "is_shiny": bool(wild_mon.get("is_shiny", false)), "odds": PokemonRules.shiny_odds, "origin": "wild"})
	return wild_mon


func _pick_encounter_species(biome: String) -> String:
	# Night danger: unlit-night draws may become shadow ghosts (night_system rolls the shared _rng; empty by day or in light).
	var ghost: String = _night_system.try_ghost_species(_session.player_tile)
	return ghost if not ghost.is_empty() else EncounterSelection.pick_wild_species(_catalog, _biome_encounters, biome, DayPhase.time_of_day_label(_session.time_of_day_minutes), _rng, _trace)
