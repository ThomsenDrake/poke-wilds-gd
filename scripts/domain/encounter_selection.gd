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
