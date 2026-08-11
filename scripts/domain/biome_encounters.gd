extends RefCounted

# Biome -> wild encounter filtering. Species-level spawn tables come from the
# catalog's spawn_biomes field (parsed from each species' wilds_data.asm): a
# species whose spawn_biomes lists the biome id spawns there directly. Species
# carrying the TYPE sentinel (or an empty spawn list) defer to the legacy
# type-based matching below, mirroring the source game's "TYPE as the final
# argument" rule. Pure data + pure logic: callers pass the catalog dict so
# this stays free of I/O.
#
# The source spawn_biomes tokens name source-game areas, not this port's world
# biome ids, so direct matching alone wastes most of the table. The alias map
# below translates each plausible source token to the closest world biome id;
# tokens with no honest counterpart (PKMNMANSION, RUINS_*, the "//" artifact)
# stay unmapped PORT-WIDE; filter_species_ids' optional landmark_token scope
# direct-matches them inside footprints ONLY (world-depth.md § dormant tokens —
# aliasing them here would admit e.g. Beldum to every desert tile). Tokens already
# equal to a world biome id (DESERT, FOREST, SAVANNA, SNOW) pass through unchanged.

const TYPE_SENTINEL := "TYPE"

# Species ids barred from every encounter pool regardless of data. EGG is the
# literal egg (its base_stats.asm is a stray Zubat copy, its folder has no
# learnset): it is a breeding artifact, never a wild encounter.
const NEVER_ENCOUNTER_IDS := {"EGG": true}

# The frozen seven (world-depth.md § Legendaries) are STATIC ring-gated stationary
# entities, NEVER a random-pool entry. No legendary has any wilds_data.asm spawn
# line, so the direct + TYPE-sentinel matches above never take one — but they ARE
# battle-viable AND carry the TYPE sentinel, so without this exclusion the type
# fallback (:111) and the full-catalog fallback below (which gates NOTHING else)
# would surface them. This guards BOTH paths (belt-and-suspenders beside the
# no-token fact). The roster is FROZEN in scripts/domain/legendary_placement.gd
# (LEGENDARY_IDS) — keep the two sets in lockstep.
const LEGENDARY_IDS := {"MEWTWO": true, "REGIROCK": true, "REGICE": true, "REGISTEEL": true, "REGIELEKI": true, "REGIDRAGO": true, "REGIGIGAS": true}

# Nocturnal filter (Phase 2 night survival): NIGHT_ONLY species are barred
# from DAY pools — the one wiki-anchored datum is Umbreon (Savanna, night
# only). NIGHT pools include them, and every biome's type set gains GHOST at
# night (ghosts seek the player out everywhere after dark; the night-danger
# system in scripts/runtime/night_system.gd owns the separate unlit hazard).
# The time_of_day label comes from day_phase.gd ("DAY" covers dawn+day+dusk).
const NIGHT_ONLY_IDS := {"UMBREON": true}

# Source wilds_data.asm spawn token -> world biome id (see biome_defs.gd).
const SOURCE_BIOME_ALIASES := {
	"BEACH": "SAND",
	"DEEP_FOREST": "FOREST",
	"GRAVEYARD": "SWAMP",
	"MOUNTAIN": "ROCK",
	"MOUNTAIN_WATER": "WATER",
	"OASIS": "DESERT",
	"OASIS_POND": "WATER",
	"OCEAN": "WATER",
	"OCEAN_FISHING": "WATER",
	"RIVER": "WATER",
	"ROCK_SMASH": "ROCK",
	"SAND_FISHING": "WATER",
	"SAND_PIT": "DESERT",
	"TIDAL_BEACH": "SAND",
	"TIDAL_BEACH_PLATEAU": "SAND",
	"TIDAL_BEACH_ROCKS": "SAND",
	"TIDAL_BEACH_WATER": "WATER",
	"VOLCANO": "LAVA",
	"WOODED_LAKE": "FOREST",
	"WOODED_LAKE_FISHING": "WATER",
	"WOODED_LAKE_WATER": "WATER"
}

const BIOME_TYPES := {
	"WATER": ["WATER"],
	"SAND": ["GROUND", "ROCK", "NORMAL"],
	"PLAINS": ["NORMAL", "GRASS"],
	"GRASSLAND": ["NORMAL", "GRASS", "BUG"],
	"FOREST": ["BUG", "GRASS", "POISON", "FLYING"],
	"SAVANNA": ["NORMAL", "GROUND", "FIGHTING"],
	"DESERT": ["GROUND", "ROCK", "STEEL"],
	"SWAMP": ["POISON", "WATER", "GRASS"],
	"ROCK": ["ROCK", "GROUND", "FIGHTING", "STEEL"],
	"SNOW": ["ICE", "WATER", "FAIRY"],
	"LAVA": ["FIRE", "GROUND", "ROCK"]
}


func encounter_types_for_biome(biome: String) -> Array:
	var types = BIOME_TYPES.get(biome, [])
	if types is Array:
		return (types as Array).duplicate()
	return []


# time_of_day is additive (default "DAY"): legacy callers keep the exact day
# pool, so the filter stays deterministic under seed_for_smoke either way.
# landmark_token (world-depth.md § dormant tokens) is additive too: when non-empty
# (the caller stands inside a landmark footprint) the verbatim source token
# (PKMNMANSION/RUINS_OUTER/RUINS_INNER) direct-matches in addition to the host
# biome's pool; the TYPE-sentinel fallback keeps keying off the HOST biome below.
# Outside every footprint the token is "" and the pool is byte-identical to today.
func filter_species_ids(species_dict: Dictionary, biome: String, time_of_day := "DAY", landmark_token := "") -> Dictionary:
	var is_night := str(time_of_day).to_upper() == "NIGHT"
	var type_set: Dictionary = {}
	for type_name in encounter_types_for_biome(biome):
		type_set[str(type_name)] = true
	if is_night:
		type_set["GHOST"] = true

	var ids: Array = []
	for key in species_dict.keys():
		var entry = species_dict[key]
		if not (entry is Dictionary):
			continue
		if not is_battle_viable(str(key), entry as Dictionary):
			continue
		if not is_night and NIGHT_ONLY_IDS.has(str(key)):
			continue
		var spawn_biomes = _spawn_biomes_of(entry as Dictionary)
		if str(landmark_token) != "" and _spawn_biomes_include(spawn_biomes, str(landmark_token)):
			ids.append(str(key))
		elif _spawn_biomes_include(spawn_biomes, biome):
			ids.append(str(key))
		elif (spawn_biomes.is_empty() or spawn_biomes.has(TYPE_SENTINEL)) and _entry_matches_types(entry as Dictionary, type_set):
			ids.append(str(key))

	if ids.is_empty():
		for key in species_dict.keys():
			# The frozen seven never enter a pool — not even the unguarded fallback
			# (world-depth.md § Legendaries; the only path that could surface one).
			if LEGENDARY_IDS.has(str(key)):
				continue
			ids.append(str(key))
		ids.sort()
		var reason := "no_species_matched_types"
		if type_set.is_empty():
			reason = "no_types_for_biome"
		return {"ids": ids, "used_fallback": true, "reason": reason}

	ids.sort()
	return {"ids": ids, "used_fallback": false, "reason": ""}


func known_biomes() -> Array:
	return BIOME_TYPES.keys()


# Shared sanitizer for authored scope additions. Curated IDs bypass filter_species_ids,
# so landmark/dungeon facades call this before their single deterministic pool draw.
func battle_viable_ids(species_dict: Dictionary, candidates: Array) -> Array:
	var ids: Array = []
	for candidate in candidates:
		var species_id := str(candidate)
		var entry = species_dict.get(species_id, {})
		if entry is Dictionary and is_battle_viable(species_id, entry) and not ids.has(species_id):
			ids.append(species_id)
	ids.sort()
	return ids


# A species must be battle-viable to enter any match path (direct biome hit
# or type fallback): both battle sprites (battle renders 2x2 placeholder
# squares without them), a parsed base_stats block with a real catch rate,
# and a non-empty learnset. The catalog zero-fills missing base_stats.asm
# (CORSOLA_GALARIAN, SHELLOS_EAST/WEST ship sprites + wilds_data only), which
# would otherwise produce uncatchable encounters, and several form folders
# (GMRMIME, the ROTOM appliance forms) ship no evos_attacks.asm at all.
# The deliberate full-catalog fallback below is left untouched (the
# LEGENDARY_IDS skip is its ONLY guard). Public so the night system's ghost
# pool (injected Callable) shares this exact rule.
func is_battle_viable(species_id: String, entry: Dictionary) -> bool:
	if NEVER_ENCOUNTER_IDS.has(species_id):
		return false
	if LEGENDARY_IDS.has(species_id): # statics, never a pool entry (see :28-36)
		return false
	if str(entry.get("front_path", "")) == "" or str(entry.get("back_path", "")) == "":
		return false
	if int(entry.get("catch_rate", 0)) <= 0:
		return false
	var stats = entry.get("base_stats", {})
	if not (stats is Dictionary) or (stats as Dictionary).is_empty():
		return false
	var learnset = entry.get("learnset", [])
	if not (learnset is Array) or (learnset as Array).is_empty():
		return false
	return true


func _spawn_biomes_of(entry: Dictionary) -> Array:
	var raw = entry.get("spawn_biomes", PackedStringArray())
	var biomes: Array = []
	if raw is PackedStringArray or raw is Array:
		for value in raw:
			biomes.append(str(value))
	return biomes


# Direct biome match, with source-area tokens resolved through the alias map.
func _spawn_biomes_include(spawn_biomes: Array, biome: String) -> bool:
	for token in spawn_biomes:
		if str(SOURCE_BIOME_ALIASES.get(str(token), str(token))) == biome:
			return true
	return false


func _entry_matches_types(entry: Dictionary, type_set: Dictionary) -> bool:
	var types = entry.get("types", PackedStringArray())
	for type_name in types:
		if type_set.has(str(type_name)):
			return true
	# Biomes like WATER have a single-type pool; species with a matching
	# primary OR secondary type qualify. Entries missing a types field never
	# match a typed biome, which is intentional so fallback stays observable.
	return false
