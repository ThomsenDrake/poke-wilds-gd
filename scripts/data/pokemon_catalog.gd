extends RefCounted

# Runtime source-data catalog. Since the PokeAPI catalog migration the
# species/move/item data is AUTHORING-TIME generated: tools/import_pokeapi.py
# turns a pinned PokeAPI/api-data checkout (plus the vendored assets/source
# tree's wilds_data.asm custom fields and sprite presence) into the three
# committed JSON documents below, and this loader reads them verbatim. The
# dictionary schema, species ids, and every public API are identical to the
# former ASM-walk loader, so domain/runtime/ui consumers are untouched; boot
# is three JSON reads instead of a 990-folder parse walk. Regenerate with
# `python3 tools/import_pokeapi.py` (freshness gate: `--check`).

const SPECIES_FILE := "res://assets/data/catalog/species.json"
const MOVES_FILE := "res://assets/data/catalog/moves.json"
const ITEMS_FILE := "res://assets/data/catalog/items.json"
# Field-move display names are NOT part of the JSON migration: they still come
# from the vendored i18n properties at runtime.
const FIELD_MOVE_NAMES_FILE := "res://assets/source/i18n/fieldmove.properties"

var moves: Dictionary = {}
var species: Dictionary = {}
var items: Dictionary = {}
var encounter_species: Array = []

var _field_move_names: Dictionary = {}
var _loaded = false
var _trace = null


func setup(trace_logger) -> void:
	_trace = trace_logger


func load_all() -> void:
	if _loaded:
		return

	_field_move_names = _parse_properties_file(FIELD_MOVE_NAMES_FILE)
	moves = _normalize_moves(_read_json_object(MOVES_FILE))
	items = _normalize_items(_read_json_object(ITEMS_FILE))
	# Species ids are re-sorted inside _load_species for encounter determinism; moves/items are NOT re-sorted — runtime lookup is exact-key and sidecar/meta keys make re-sorting lossy.
	_load_species(_read_json_object(SPECIES_FILE))
	_loaded = true


func get_species(species_id: String) -> Dictionary:
	var id = species_id.strip_edges().to_upper()
	if species.has(id):
		return species[id]
	return {}


func get_move(move_id: String) -> Dictionary:
	var id = move_id.strip_edges().to_upper()
	if moves.has(id):
		return moves[id]
	return {}


func get_item(item_id: String) -> Dictionary:
	var id = item_id.strip_edges().to_upper()
	if items.has(id):
		return items[id]
	return {}


func get_field_move_name(field_move_id: String) -> String:
	var id = field_move_id.strip_edges().to_lower()
	if _field_move_names.has(id):
		return str(_field_move_names[id])
	return _humanize_slug(id)


func get_random_encounter_species(rng: RandomNumberGenerator) -> String:
	if encounter_species.is_empty():
		return ""
	var index = rng.randi_range(0, encounter_species.size() - 1)
	return str(encounter_species[index])


# Builds the species dictionary from the generated catalog, iterating keys in
# sorted order so encounter_species is byte-identical across runs (encounter
# RNG depends on it). The sort rides the LOWERCASE form of each id: the ASM
# walk sorted lowercase folder names before uppercasing them into ids, and
# ASCII case ordering differs around "_" (0x5F sorts below lowercase letters
# but above uppercase ones — "nidoran_f" vs "nidorina" flips), so sorting the
# uppercase ids directly would NOT reproduce today's encounter order.
func _load_species(catalog: Dictionary) -> void:
	var parsed := 0
	var skipped := 0
	var ids: Array = catalog.keys()
	ids.sort_custom(func(a, b): return str(a).to_lower() < str(b).to_lower())
	for id_variant in ids:
		var species_id := str(id_variant)
		var raw = catalog[id_variant]
		if raw is not Dictionary:
			_warn("PokemonCatalog", "Skipping malformed species catalog entry.", {"path": SPECIES_FILE, "species_id": species_id})
			skipped += 1
			continue
		var entry := _normalize_species_entry(species_id, raw)
		species[species_id] = entry
		parsed += 1
		# Wild encounters require battle-viable species: battle sprites, real
		# base stats, a catch rate, and a learnset. Everything else stays
		# lookup-only.
		if not str(entry["front_path"]).is_empty() and not str(entry["back_path"]).is_empty() \
				and int(entry["catch_rate"]) > 0 \
				and not (entry["base_stats"] as Dictionary).is_empty() \
				and not (entry["learnset"] as Array).is_empty() \
				and species_id != "EGG":
			encounter_species.append(species_id)

	_warn("PokemonCatalog", "Species catalog load complete.", {
		"parsed": parsed,
		"skipped": skipped,
		"moves": moves.size(),
		"items": items.size()
	})


# JSON.parse_string types are not guaranteed, so entries start as a deep
# duplicate of the raw object — the same duplicate-then-re-pin pattern as
# moves/items, so future additive generator fields ride along instead of being
# silently dropped — with the known fields re-pinned in place to the exact
# types the ASM parsers produced (int stats/levels, float weight/height,
# PackedStringArray word lists). The additive fields the ASM path never had
# (held_items, abilities) pass through untouched, as do the precomputed sprite
# path strings (no per-species FileAccess checks — that is the boot-speed win).
func _normalize_species_entry(species_id: String, raw: Dictionary) -> Dictionary:
	var entry: Dictionary = raw.duplicate(true)
	var slug := str(entry.get("slug", species_id.to_lower()))
	entry["species_id"] = species_id
	entry["slug"] = slug
	entry["display_name"] = str(entry.get("display_name", _humanize_slug(slug)))
	entry["dex_number"] = int(entry.get("dex_number", 0))
	entry["types"] = _to_packed_string_array(entry.get("types"), PackedStringArray(["NORMAL", "NORMAL"]))
	entry["base_stats"] = _normalize_base_stats(entry.get("base_stats", {}))
	entry["learnset"] = _normalize_learnset(entry.get("learnset", []))
	entry["evolutions"] = _normalize_evolutions(entry.get("evolutions", []))
	entry["catch_rate"] = int(entry.get("catch_rate", 0))
	entry["base_exp"] = int(entry.get("base_exp", 0))
	entry["growth_rate"] = str(entry.get("growth_rate", ""))
	entry["gender_ratio"] = str(entry.get("gender_ratio", ""))
	entry["egg_groups"] = _to_packed_string_array(entry.get("egg_groups"), PackedStringArray())
	entry["egg_moves"] = _to_packed_string_array(entry.get("egg_moves"), PackedStringArray())
	entry["tmhm"] = _to_packed_string_array(entry.get("tmhm"), PackedStringArray())
	entry["spawn_biomes"] = _to_packed_string_array(entry.get("spawn_biomes"), PackedStringArray())
	entry["field_moves"] = entry.get("field_moves", {})
	entry["overworld_behavior"] = entry.get("overworld_behavior", {})
	entry["dex_entry"] = str(entry.get("dex_entry", ""))
	entry["weight_kg"] = float(entry.get("weight_kg", 0.0))
	entry["height_m"] = float(entry.get("height_m", 0.0))
	entry["front_path"] = str(entry.get("front_path", ""))
	entry["back_path"] = str(entry.get("back_path", ""))
	entry["overworld_path"] = str(entry.get("overworld_path", ""))
	entry["shiny_overworld_path"] = str(entry.get("shiny_overworld_path", ""))
	entry["held_items"] = entry.get("held_items", [])
	entry["abilities"] = entry.get("abilities", [])
	return entry


func _normalize_base_stats(raw) -> Dictionary:
	var stats: Dictionary = {}
	if raw is Dictionary:
		for key_variant in (raw as Dictionary).keys():
			stats[str(key_variant)] = int(raw[key_variant])
	return stats


# Writer sorts by level and guarantees level >= 1 (import_pokeapi.py), so
# malformed rows are NOT dropped here — they survive to surface generator
# regressions instead of being silently swallowed by the loader.
func _normalize_learnset(raw) -> Array:
	var learnset: Array = []
	if raw is not Array:
		return learnset
	for entry_variant in (raw as Array):
		if entry_variant is not Dictionary:
			continue
		var entry: Dictionary = entry_variant
		learnset.append({"level": int(entry.get("level", 0)), "move_id": str(entry.get("move_id", ""))})
	return learnset


func _normalize_evolutions(raw) -> Array:
	var evolutions: Array = []
	if raw is not Array:
		return evolutions
	for evo_variant in (raw as Array):
		if evo_variant is not Dictionary:
			continue
		var evo: Dictionary = evo_variant
		evolutions.append({
			"method": str(evo.get("method", "")),
			"param": _normalize_evolution_param(evo.get("param")),
			"target": str(evo.get("target", ""))
		})
	return evolutions


# param stays a Variant exactly as the ASM parser produced it: an int level for
# EVOLVE_LEVEL, a string for TR_/item params (pokemon_rules reads both). JSON
# numbers arrive as float and are coerced back to int; the writer emits bare
# strings only for flavor words, so everything else passes through untouched.
func _normalize_evolution_param(value):
	if value is float:
		return int(value)
	return value


# Move entries pass through (power/accuracy/pp/effect_chance arrive as JSON
# ints); only the id/display fields are re-pinned. priority/target/ailment are
# additive and ride along untouched.
func _normalize_moves(raw_moves: Dictionary) -> Dictionary:
	var catalog: Dictionary = {}
	for key_variant in raw_moves.keys():
		var move_id := str(key_variant).to_upper()
		var raw = raw_moves[key_variant]
		if raw is not Dictionary:
			continue
		var entry: Dictionary = (raw as Dictionary).duplicate()
		entry["move_id"] = move_id
		entry["display_name"] = str(entry.get("display_name", _humanize_slug(move_id.to_lower())))
		catalog[move_id] = entry
	return catalog


# Item entries pass through with only the id/display fields re-pinned and cost
# coerced to int; pocket/category ride along untouched.
func _normalize_items(raw_items: Dictionary) -> Dictionary:
	var catalog: Dictionary = {}
	for key_variant in raw_items.keys():
		var item_id := str(key_variant).to_upper()
		var raw = raw_items[key_variant]
		if raw is not Dictionary:
			continue
		var entry: Dictionary = (raw as Dictionary).duplicate()
		entry["item_id"] = item_id
		entry["display_name"] = str(entry.get("display_name", _humanize_slug(item_id.to_lower())))
		entry["description"] = str(entry.get("description", ""))
		if entry.has("cost"):
			entry["cost"] = int(entry["cost"])
		catalog[item_id] = entry
	return catalog


# Reads one generated catalog document. Fail-soft exactly like the ASM walk: a
# missing/unparseable file warns with the path payload and yields an empty
# dict, never an error. Quiet parse (the save_store.gd precedent) so a bad
# read emits no spurious engine "ERROR: Parse JSON failed" stderr line — the
# refusal is traced here, never swallowed, never doubled by engine noise.
func _read_json_object(path: String) -> Dictionary:
	var path_used := path
	var file: FileAccess = null
	if FileAccess.file_exists(path_used):
		file = FileAccess.open(path_used, FileAccess.READ)
	if file == null:
		_warn("PokemonCatalog", "Could not open catalog file.", {"path": path_used})
		return {}
	var text = file.get_as_text()
	file.close()
	var json = JSON.new()
	if json.parse(text) != OK or not (json.data is Dictionary):
		_warn("PokemonCatalog", "Failed to parse catalog file.", {"path": path_used})
		return {}
	return json.data


# JSON arrays arrive as plain Array; the ASM parsers produced PackedStringArray
# and consumers (biome filters, egg-group pairing, tmhm checks) rely on it.
func _to_packed_string_array(value, fallback: PackedStringArray) -> PackedStringArray:
	if value is not Array:
		return fallback
	var result := PackedStringArray()
	for item_variant in (value as Array):
		result.append(str(item_variant))
	return result


func _parse_properties_file(path: String) -> Dictionary:
	var entries: Dictionary = {}
	for raw_line_variant in _read_text_file(path).split("\n"):
		var raw_line = str(raw_line_variant).strip_edges()
		if raw_line.is_empty() or raw_line.begins_with("#"):
			continue
		var sep = raw_line.find("=")
		if sep <= 0:
			continue
		var key = raw_line.substr(0, sep).strip_edges().to_lower()
		var value = raw_line.substr(sep + 1, raw_line.length() - sep - 1).strip_edges()
		entries[key] = value
	return entries


func _read_text_file(path: String) -> String:
	var file = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var text = file.get_as_text()
	file.close()
	return text


func _humanize_slug(slug: String) -> String:
	var spaced = slug.replace("_", " ")
	if spaced.is_empty():
		return slug
	return spaced.capitalize()


func _warn(source: String, message: String, payload: Dictionary) -> void:
	if _trace != null:
		_trace.warning(source, message, payload)
