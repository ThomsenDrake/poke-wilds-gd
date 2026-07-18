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
# stay unmapped and simply never direct-match. Tokens already equal to a world
# biome id (DESERT, FOREST, SAVANNA, SNOW) pass through unchanged.

const TYPE_SENTINEL := "TYPE"

# Species ids barred from every encounter pool regardless of data. EGG is the
# literal egg (its base_stats.asm is a stray Zubat copy, its folder has no
# learnset): it is a breeding artifact, never a wild encounter.
const NEVER_ENCOUNTER_IDS := {"EGG": true}

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


func filter_species_ids(species_dict: Dictionary, biome: String) -> Dictionary:
	var type_set: Dictionary = {}
	for type_name in encounter_types_for_biome(biome):
		type_set[str(type_name)] = true

	var ids: Array = []
	for key in species_dict.keys():
		var entry = species_dict[key]
		if not (entry is Dictionary):
			continue
		if not _entry_is_battle_viable(str(key), entry as Dictionary):
			continue
		var spawn_biomes = _spawn_biomes_of(entry as Dictionary)
		if _spawn_biomes_include(spawn_biomes, biome):
			ids.append(str(key))
		elif (spawn_biomes.is_empty() or spawn_biomes.has(TYPE_SENTINEL)) and _entry_matches_types(entry as Dictionary, type_set):
			ids.append(str(key))

	if ids.is_empty():
		for key in species_dict.keys():
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


# A species must be battle-viable to enter any match path (direct biome hit
# or type fallback): both battle sprites (battle renders 2x2 placeholder
# squares without them), a parsed base_stats block with a real catch rate,
# and a non-empty learnset. The catalog zero-fills missing base_stats.asm
# (CORSOLA_GALARIAN, SHELLOS_EAST/WEST ship sprites + wilds_data only), which
# would otherwise produce uncatchable encounters, and several form folders
# (GMRMIME, the ROTOM appliance forms) ship no evos_attacks.asm at all.
# The deliberate full-catalog fallback below is left untouched.
func _entry_is_battle_viable(species_id: String, entry: Dictionary) -> bool:
	if NEVER_ENCOUNTER_IDS.has(species_id):
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
