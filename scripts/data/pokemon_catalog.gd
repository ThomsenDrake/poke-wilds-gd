extends RefCounted

const SPECIES_ROOT := "res://pokewilds/pokemon/pokemon"
const MOVES_FILE := "res://pokewilds/pokemon/moves.asm"
const MOVE_CATEGORY_FILE := "res://pokewilds/pokemon/spec_phys_lookup.txt"
const MOVE_NAMES_FILE := "res://pokewilds/i18n/attack.properties"
const SPECIES_NAMES_FILE := "res://pokewilds/i18n/pokemondisplayname.properties"
const ITEM_NAMES_FILE := "res://pokewilds/i18n/item.properties"
const ITEM_DESCRIPTIONS_FILE := "res://pokewilds/i18n/itemdescription.properties"
const FIELD_MOVE_NAMES_FILE := "res://pokewilds/i18n/fieldmove.properties"

const SpeciesFileParser := preload("res://scripts/data/species_file_parser.gd")
const MoveFileParser := preload("res://scripts/data/move_file_parser.gd")

# Runtime-defined supplements for bag-referenced item ids the source i18n
# files never list (the source game hardcodes them, so item.properties and
# itemdescription.properties have no entry). Anything the bag/battle systems
# can hand out must resolve here; keyed by the lowercase bag id.
const RUNTIME_ITEM_SUPPLEMENTS := {
	"potion": {
		"display_name": "Potion",
		"description": "Restores 20 HP."
	}
}

var moves: Dictionary = {}
var species: Dictionary = {}
var items: Dictionary = {}
var encounter_species: Array = []

var _species_names: Dictionary = {}
var _move_names: Dictionary = {}
var _field_move_names: Dictionary = {}
var _loaded = false
var _trace = null


func setup(trace_logger) -> void:
	_trace = trace_logger


func load_all() -> void:
	if _loaded:
		return

	_species_names = _parse_properties_file(SPECIES_NAMES_FILE)
	_move_names = _parse_properties_file(MOVE_NAMES_FILE)
	_field_move_names = _parse_properties_file(FIELD_MOVE_NAMES_FILE)
	moves = MoveFileParser.parse_moves(
		_read_text_file(MOVES_FILE),
		_move_names,
		MoveFileParser.parse_move_categories(_read_text_file(MOVE_CATEGORY_FILE))
	)
	items = _build_items()
	_apply_runtime_item_supplements()
	_parse_species_directory()
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


func _parse_species_directory() -> void:
	var dir := DirAccess.open(SPECIES_ROOT)
	if dir == null:
		_warn("PokemonCatalog", "Could not open species root.", {"path": SPECIES_ROOT})
		return

	var folder_names: Array = []
	dir.list_dir_begin()
	while true:
		var entry := dir.get_next()
		if entry.is_empty():
			break
		if entry.begins_with("."):
			continue
		if dir.current_is_dir():
			folder_names.append(entry)
	dir.list_dir_end()
	folder_names.sort()

	var parsed := 0
	var skipped := 0
	for folder_name_variant in folder_names:
		if _load_species_folder(str(folder_name_variant)):
			parsed += 1
		else:
			skipped += 1

	_warn("PokemonCatalog", "Species catalog load complete.", {
		"parsed": parsed,
		"skipped": skipped,
		"moves": moves.size(),
		"items": items.size()
	})


func _load_species_folder(folder_name: String) -> bool:
	var base_path := "%s/%s" % [SPECIES_ROOT, folder_name]
	var front_path := "%s/front.png" % base_path
	var back_path := "%s/back.png" % base_path
	var overworld_path := "%s/overworld.png" % base_path
	var base_stats_path := "%s/base_stats.asm" % base_path
	var evos_attacks_path := "%s/evos_attacks.asm" % base_path
	var wilds_data_path := "%s/wilds_data.asm" % base_path

	var base_data := {}
	if FileAccess.file_exists(base_stats_path):
		base_data = SpeciesFileParser.parse_base_stats(_read_text_file(base_stats_path))

	var wilds_data := {}
	if FileAccess.file_exists(wilds_data_path):
		wilds_data = SpeciesFileParser.parse_wilds_data(SpeciesFileParser.read_latin1_text(wilds_data_path))

	if base_data.is_empty() and wilds_data.is_empty():
		if FileAccess.file_exists(base_stats_path) or FileAccess.file_exists(wilds_data_path):
			_warn("PokemonCatalog", "Failed to parse species data files.", {"path": base_path})
		return false

	var slug := folder_name.to_lower()
	# The dict key is always the folder-derived id: a few source files declare
	# a wrong or ambiguous constant (kleavor declares KLEFKI, ursaluna declares
	# URSARING, nidoran_f/m both declare NIDORAN), which would otherwise drop
	# species through key collisions. Folder names are unique by construction.
	var species_id := folder_name.to_upper()

	var learnset := _parse_learnset_file(evos_attacks_path)
	var evolutions: Array = []
	if FileAccess.file_exists(evos_attacks_path):
		evolutions = SpeciesFileParser.parse_evolutions(_read_text_file(evos_attacks_path))

	var dex_number := int(wilds_data.get("dex_number", 0))
	if dex_number <= 0:
		dex_number = int(base_data.get("dex_number", 0))

	var has_front := FileAccess.file_exists(front_path)
	var has_back := FileAccess.file_exists(back_path)
	species[species_id] = {
		"species_id": species_id,
		"slug": slug,
		"display_name": str(_species_names.get(slug, _humanize_slug(slug))),
		"dex_number": dex_number,
		"types": base_data.get("types", PackedStringArray(["NORMAL", "NORMAL"])),
		"base_stats": base_data.get("base_stats", {}),
		"learnset": learnset,
		"evolutions": evolutions,
		"catch_rate": int(base_data.get("catch_rate", 0)),
		"base_exp": int(base_data.get("base_exp", 0)),
		"growth_rate": str(base_data.get("growth_rate", "")),
		"gender_ratio": str(base_data.get("gender_ratio", "")),
		"egg_groups": base_data.get("egg_groups", PackedStringArray()),
		"tmhm": base_data.get("tmhm", PackedStringArray()),
		"spawn_biomes": wilds_data.get("spawn_biomes", PackedStringArray()),
		"field_moves": wilds_data.get("field_moves", {}),
		"overworld_behavior": wilds_data.get("overworld_behavior", {}),
		"dex_entry": str(wilds_data.get("dex_entry", "")),
		"weight_kg": float(wilds_data.get("weight_kg", 0.0)),
		"height_m": float(wilds_data.get("height_m", 0.0)),
		"front_path": front_path if has_front else "",
		"back_path": back_path if has_back else "",
		"overworld_path": overworld_path if FileAccess.file_exists(overworld_path) else ""
	}

	# Wild encounters require battle-viable species: battle sprites, real base
	# stats, a catch rate, and a learnset. Everything else stays lookup-only.
	if has_front and has_back and int(base_data.get("catch_rate", 0)) > 0 \
			and not (base_data.get("base_stats", {}) as Dictionary).is_empty() \
			and not learnset.is_empty() \
			and species_id != "EGG":
		encounter_species.append(species_id)
	return true


func _build_items() -> Dictionary:
	var catalog := {}
	var names := _parse_properties_file(ITEM_NAMES_FILE)
	var descriptions := _parse_properties_file(ITEM_DESCRIPTIONS_FILE)
	var ids := {}
	for key in names.keys():
		ids[key] = true
	for key in descriptions.keys():
		ids[key] = true
	for key_variant in ids.keys():
		var key := str(key_variant)
		var item_id := key.to_upper()
		catalog[item_id] = {
			"item_id": item_id,
			"display_name": str(names.get(key, _humanize_slug(key))),
			"description": str(descriptions.get(key, ""))
		}
	return catalog


# Merges RUNTIME_ITEM_SUPPLEMENTS into the parsed item catalog without
# overwriting any id the source i18n does define.
func _apply_runtime_item_supplements() -> void:
	for key_variant in RUNTIME_ITEM_SUPPLEMENTS.keys():
		var key := str(key_variant)
		var item_id := key.to_upper()
		if items.has(item_id):
			continue
		var supplement: Dictionary = RUNTIME_ITEM_SUPPLEMENTS[key]
		items[item_id] = {
			"item_id": item_id,
			"display_name": str(supplement.get("display_name", _humanize_slug(key))),
			"description": str(supplement.get("description", ""))
		}


func _parse_learnset_file(path: String) -> Array:
	if not FileAccess.file_exists(path):
		return []

	var text = _read_text_file(path)
	var move_re = RegEx.new()
	move_re.compile("^\\s*db\\s+([0-9]+)\\s*,\\s*([A-Z0-9_]+)")

	var learnset: Array = []
	for raw_line_variant in text.split("\n"):
		var raw_line = str(raw_line_variant)
		var stripped = raw_line.strip_edges()
		if stripped.contains("no more level-up moves"):
			break

		var move_match = move_re.search(raw_line)
		if move_match == null:
			continue
		var level = int(move_match.get_string(1))
		if level <= 0:
			continue
		learnset.append({"level": level, "move_id": move_match.get_string(2)})
	return learnset


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
