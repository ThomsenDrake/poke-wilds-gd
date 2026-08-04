extends RefCounted

# Wild-encounter level + fallback-species selection, extracted verbatim from
# game_runtime.gd (level_from_distance + _fallback_species_entry) so the
# runtime holds its 320-line budget while the night-survival wiring lands.
# Pure domain: the shared rng is injected so seed_for_smoke pins the draws
# exactly as before (same instance, same stream, same order).
# Starter/fallback split (new-game flow slice): STARTER_SPECIES_ID feeds build_starter
# (the faithful starter); FALLBACK_SPECIES_ID stays the WILD empty-pool fallback for
# species_entry_for — the starter faithfulness fix must not also move the wild fallback
# (its warning payload `fallback_species_id` + data_audit expectations are pin-adjacent).

const PokemonRules := preload("res://scripts/domain/pokemon_rules.gd")

const STARTER_SPECIES_ID := "MACHOP" # faithful starter: "You start with a Machop, which knows how to Build" (.firecrawl/wiki-getting-started.md:60) — corrects the former unflagged CHIKORITA starter
const FALLBACK_SPECIES_ID := "CHIKORITA" # wild empty-pool fallback — UNCHANGED on purpose (the header split note)


# Levels scale with Manhattan distance from the world origin: a 1-in-24-tile
# gradient plus 0-3 jitter, clamped to 2-80.
static func level_from_distance(tile_pos: Vector2i, rng: RandomNumberGenerator) -> int:
	var distance = abs(tile_pos.x) + abs(tile_pos.y)
	return clampi(2 + int(distance / 24) + rng.randi_range(0, 3), 2, 80)


# The faithful starter species, or the first non-empty catalog entry when the
# starter is missing; {} only for an empty catalog (the caller warns then).
# Rng-free (const catalog lookups), so the split shifts no pinned draw.
static func starter_species_entry(catalog) -> Dictionary:
	var starter = catalog.get_species(STARTER_SPECIES_ID)
	if starter is Dictionary and not (starter as Dictionary).is_empty():
		return starter
	for species_entry in catalog.species.values():
		if species_entry is Dictionary and not (species_entry as Dictionary).is_empty():
			return species_entry
	return {}


# The wild fallback species, or the first non-empty catalog entry when it is
# missing; {} only for an empty catalog (the caller warns then).
static func fallback_species_entry(species_dict: Dictionary) -> Dictionary:
	var fallback = species_dict.get(FALLBACK_SPECIES_ID, {})
	if fallback is Dictionary and not (fallback as Dictionary).is_empty():
		return fallback
	for species_entry in species_dict.values():
		if species_entry is Dictionary and not (species_entry as Dictionary).is_empty():
			return species_entry
	return {}


# Starter construction, extracted from game_runtime.gd's _build_starter for
# the Phase 5 drops/fishing wiring budget (game_runtime keeps a thin forwarder). The
# catalog + rules arrive injected so the domain layer keeps its no-data-dependency
# contract. Species lookup is starter_species_entry (the STARTER/FALLBACK split); the
# rng shape is UNCHANGED — exactly one roll_shiny draw at stream index 0 (the lookup
# is rng-free). The empty-catalog warning + shiny_rolled trace live in build_starter_traced.
static func build_starter(catalog, rules, rng: RandomNumberGenerator, get_move: Callable) -> Dictionary:
	var starter = starter_species_entry(catalog)
	var instance: Dictionary = rules.create_pokemon_instance(starter, 5, get_move, rng)
	if not instance.is_empty():
		return instance
	var fallback_id = catalog.get_random_encounter_species(rng)
	if fallback_id.is_empty():
		return {}
	return rules.create_pokemon_instance(catalog.get_species(fallback_id), 5, get_move, rng)


# build_starter + game_runtime's warning/trace (new-game flow slice extraction;
# game_runtime keeps a thin forwarder). EXACT "GameRuntime" source string + wording
# (pin-safe log greps, the species_entry_for precedent); the shiny_rolled odds read
# PokemonRules.shiny_odds so the creation knob is witnessed.
static func build_starter_traced(catalog, rules, rng: RandomNumberGenerator, get_move: Callable, trace_logger) -> Dictionary:
	var starter := build_starter(catalog, rules, rng, get_move)
	if starter.is_empty():
		if trace_logger != null:
			trace_logger.warning("GameRuntime", "Species catalog is empty; starting a new game without a starter.", {})
	elif trace_logger != null:
		trace_logger.emit_event("shiny_rolled", "GameRuntime", {"species_id": str(starter.get("species_id", "")), "is_shiny": bool(starter.get("is_shiny", false)), "odds": PokemonRules.shiny_odds, "origin": "starter"})
	return starter


# The species-entry resolution for generate_wild_encounter, extracted verbatim from
# game_runtime.gd for the Phase 7 Build 1 landmark wiring budget (world-depth.md
# § Implementation shape: at-cap files pay by EXTRACTION FIRST). Both warnings keep the
# exact "GameRuntime" source string + wording (pin-safe for the log greps).
static func species_entry_for(catalog, species_id: String, biome: String, trace_logger) -> Dictionary:
	var species_entry: Dictionary = {}
	if not species_id.is_empty():
		species_entry = catalog.get_species(species_id)
	if species_entry.is_empty():
		species_entry = fallback_species_entry(catalog.species)
		if species_entry.is_empty():
			if trace_logger != null:
				trace_logger.warning("GameRuntime", "Species catalog is empty; skipping the wild encounter.", {"biome": biome})
			return {}
		if trace_logger != null:
			trace_logger.warning("GameRuntime", "Encounter species list was empty; using a fallback species.",
				{"fallback_species_id": str(species_entry.get("species_id", ""))})
	return species_entry


# The grass-stream species pick, extracted from game_runtime._pick_encounter_species for
# the Phase 6 game_runtime budget (the runtime keeps the night-ghost check + a forwarder).
# Rides the injected shared _rng exactly as before; the fallback warning keeps the exact
# "GameRuntime" source string (pin-safe).
static func pick_wild_species(catalog, biome_encounters, biome: String, time_label: String, rng: RandomNumberGenerator, trace_logger) -> String:
	if not biome.is_empty():
		var filtered: Dictionary = biome_encounters.filter_species_ids(catalog.species, biome, time_label)
		if bool(filtered.get("used_fallback", false)) and trace_logger != null:
			trace_logger.warning("GameRuntime", "Biome encounter filter fell back to the full catalog.", {"biome": biome, "reason": str(filtered.get("reason", ""))})
		var ids: Variant = filtered.get("ids", [])
		if ids is Array and not (ids as Array).is_empty():
			return str((ids as Array)[rng.randi_range(0, (ids as Array).size() - 1)])
	return catalog.get_random_encounter_species(rng)
