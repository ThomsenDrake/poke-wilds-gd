extends RefCounted

# Wild-encounter level + fallback-species selection, extracted verbatim from
# game_runtime.gd (level_from_distance + _fallback_species_entry) so the
# runtime holds its 320-line budget while the night-survival wiring lands.
# Pure domain: the shared rng is injected so seed_for_smoke pins the draws
# exactly as before (same instance, same stream, same order).

const FALLBACK_SPECIES_ID := "CHIKORITA"


# Levels scale with Manhattan distance from the world origin: a 1-in-24-tile
# gradient plus 0-3 jitter, clamped to 2-80.
static func level_from_distance(tile_pos: Vector2i, rng: RandomNumberGenerator) -> int:
	var distance = abs(tile_pos.x) + abs(tile_pos.y)
	return clampi(2 + int(distance / 24) + rng.randi_range(0, 3), 2, 80)


# The starter species, or the first non-empty catalog entry when the starter
# is missing; {} only for an empty catalog (the caller warns then).
static func fallback_species_entry(species_dict: Dictionary) -> Dictionary:
	var starter = species_dict.get(FALLBACK_SPECIES_ID, {})
	if starter is Dictionary and not (starter as Dictionary).is_empty():
		return starter
	for species_entry in species_dict.values():
		if species_entry is Dictionary and not (species_entry as Dictionary).is_empty():
			return species_entry
	return {}


# Starter construction, extracted verbatim from game_runtime.gd's _build_starter for
# the Phase 5 drops/fishing wiring budget (game_runtime keeps a thin forwarder). The
# catalog + rules arrive injected so the domain layer keeps its no-data-dependency
# contract; the empty-catalog warning stays with the caller.
static func build_starter(catalog, rules, rng: RandomNumberGenerator, get_move: Callable) -> Dictionary:
	var starter = fallback_species_entry(catalog.species)
	var instance: Dictionary = rules.create_pokemon_instance(starter, 5, get_move, rng)
	if not instance.is_empty():
		return instance
	var fallback_id = catalog.get_random_encounter_species(rng)
	if fallback_id.is_empty():
		return {}
	return rules.create_pokemon_instance(catalog.get_species(fallback_id), 5, get_move, rng)


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
