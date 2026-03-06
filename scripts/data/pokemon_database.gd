extends RefCounted

const SPECIES_ROOT := "res://pokewilds/pokemon/pokemon"
const MOVES_FILE := "res://pokewilds/pokemon/moves.asm"
const MOVE_CATEGORY_FILE := "res://pokewilds/pokemon/spec_phys_lookup.txt"
const MOVE_NAMES_FILE := "res://pokewilds/i18n/attack.properties"
const SPECIES_NAMES_FILE := "res://pokewilds/i18n/pokemondisplayname.properties"

var moves: Dictionary = {}
var species: Dictionary = {}
var encounter_species: Array = []

var _species_names: Dictionary = {}
var _move_names: Dictionary = {}
var _move_categories: Dictionary = {}
var _loaded = false


func load_all() -> void:
	if _loaded:
		return

	_species_names = _parse_properties_file(SPECIES_NAMES_FILE)
	_move_names = _parse_properties_file(MOVE_NAMES_FILE)
	_move_categories = _parse_move_category_file(MOVE_CATEGORY_FILE)
	moves = _parse_moves_file(MOVES_FILE)
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


func get_random_encounter_species(rng: RandomNumberGenerator) -> String:
	if encounter_species.is_empty():
		return ""
	var index = rng.randi_range(0, encounter_species.size() - 1)
	return str(encounter_species[index])


func _parse_species_directory() -> void:
	var dir = DirAccess.open(SPECIES_ROOT)
	if dir == null:
		push_warning("Could not open species root: %s" % SPECIES_ROOT)
		return

	var folder_names: Array = []
	dir.list_dir_begin()
	while true:
		var entry = dir.get_next()
		if entry.is_empty():
			break
		if entry.begins_with("."):
			continue
		if dir.current_is_dir():
			folder_names.append(entry)
	dir.list_dir_end()
	folder_names.sort()

	for folder_name_variant in folder_names:
		var folder_name = str(folder_name_variant)
		var base_path = "%s/%s" % [SPECIES_ROOT, folder_name]
		var front_path = "%s/front.png" % base_path
		var back_path = "%s/back.png" % base_path
		var base_stats_path = "%s/base_stats.asm" % base_path
		var learnset_path = "%s/evos_attacks.asm" % base_path

		if not ResourceLoader.exists(front_path) or not ResourceLoader.exists(back_path):
			continue
		if not FileAccess.file_exists(base_stats_path):
			continue

		var base_stats_data = _parse_base_stats_file(base_stats_path)
		if base_stats_data.is_empty():
			continue

		var species_id = str(base_stats_data.get("species_id", folder_name.to_upper()))
		var slug = folder_name.to_lower()
		var display_name = str(_species_names.get(slug, _humanize_slug(slug)))
		var learnset = _parse_learnset_file(learnset_path)

		var entry = {
			"species_id": species_id,
			"slug": slug,
			"display_name": display_name,
			"dex_number": int(base_stats_data.get("dex_number", 0)),
			"types": base_stats_data.get("types", PackedStringArray(["NORMAL", "NORMAL"])),
			"base_stats": base_stats_data.get("base_stats", {}),
			"learnset": learnset,
			"front_path": front_path,
			"back_path": back_path
		}
		species[species_id] = entry
		encounter_species.append(species_id)


func _parse_base_stats_file(path: String) -> Dictionary:
	var text = _read_text_file(path)
	if text.is_empty():
		return {}

	var species_re = RegEx.new()
	species_re.compile("^\\s*db\\s+([A-Z0-9_]+)\\s*;\\s*([0-9]+)")

	var stats_re = RegEx.new()
	stats_re.compile("^\\s*db\\s+([0-9]+)\\s*,\\s*([0-9]+)\\s*,\\s*([0-9]+)\\s*,\\s*([0-9]+)\\s*,\\s*([0-9]+)\\s*,\\s*([0-9]+)")

	var types_re = RegEx.new()
	types_re.compile("^\\s*db\\s+([A-Z_]+)\\s*,\\s*([A-Z_]+)\\s*;.*type")

	var species_id = ""
	var dex_number = 0
	var base_stats: Dictionary = {}
	var types = PackedStringArray()

	var lines = text.split("\n")
	for raw_line_variant in lines:
		var raw_line = str(raw_line_variant)

		if species_id.is_empty():
			var species_match = species_re.search(raw_line)
			if species_match != null:
				species_id = species_match.get_string(1)
				dex_number = int(species_match.get_string(2))
				continue

		if base_stats.is_empty():
			var stats_match = stats_re.search(raw_line)
			if stats_match != null:
				base_stats = {
					"hp": int(stats_match.get_string(1)),
					"atk": int(stats_match.get_string(2)),
					"def": int(stats_match.get_string(3)),
					"spe": int(stats_match.get_string(4)),
					"sat": int(stats_match.get_string(5)),
					"sdf": int(stats_match.get_string(6))
				}
				continue

		if types.is_empty():
			var type_match = types_re.search(raw_line)
			if type_match != null:
				types = PackedStringArray([type_match.get_string(1), type_match.get_string(2)])

	if species_id.is_empty() or base_stats.is_empty() or types.is_empty():
		return {}

	return {
		"species_id": species_id,
		"dex_number": dex_number,
		"base_stats": base_stats,
		"types": types
	}


func _parse_learnset_file(path: String) -> Array:
	if not FileAccess.file_exists(path):
		return []

	var text = _read_text_file(path)
	var move_re = RegEx.new()
	move_re.compile("^\\s*db\\s+([0-9]+)\\s*,\\s*([A-Z0-9_]+)")

	var learnset: Array = []
	var lines = text.split("\n")
	for raw_line_variant in lines:
		var raw_line = str(raw_line_variant)
		var stripped = raw_line.strip_edges()
		if stripped.contains("no more level-up moves"):
			break

		var move_match = move_re.search(raw_line)
		if move_match == null:
			continue

		var level = int(move_match.get_string(1))
		var move_id = move_match.get_string(2)
		if level <= 0:
			continue
		learnset.append({"level": level, "move_id": move_id})

	return learnset


func _parse_moves_file(path: String) -> Dictionary:
	var text = _read_text_file(path)
	var entries: Dictionary = {}

	var move_re = RegEx.new()
	move_re.compile("^\\s*move\\s+([A-Z0-9_]+)\\s*,\\s*([A-Z0-9_]+)\\s*,\\s*([0-9]+)\\s*,\\s*([A-Z_]+)\\s*,\\s*([0-9]+)\\s*,\\s*([0-9]+)\\s*,\\s*([0-9]+)")

	var lines = text.split("\n")
	for raw_line_variant in lines:
		var raw_line = str(raw_line_variant)
		var match = move_re.search(raw_line)
		if match == null:
			continue

		var move_id = match.get_string(1)
		var power = int(match.get_string(3))
		var move_key = move_id.to_lower()
		var display_name = str(_move_names.get(move_key, _humanize_slug(move_key)))
		var category = str(_move_categories.get(move_id, "PHYSICAL"))
		if power <= 0:
			category = "STATUS"

		entries[move_id] = {
			"move_id": move_id,
			"display_name": display_name,
			"effect": match.get_string(2),
			"power": power,
			"type": match.get_string(4),
			"accuracy": int(match.get_string(5)),
			"pp": int(match.get_string(6)),
			"effect_chance": int(match.get_string(7)),
			"category": category
		}

	return entries


func _parse_move_category_file(path: String) -> Dictionary:
	var text = _read_text_file(path)
	var entries: Dictionary = {}
	var lines = text.split("\n")
	for raw_line_variant in lines:
		var raw_line = str(raw_line_variant).strip_edges()
		if raw_line.is_empty():
			continue
		var parts = raw_line.split(",", false, 2)
		if parts.size() < 2:
			continue
		var move_id = str(parts[0]).strip_edges().to_upper()
		var category = str(parts[1]).strip_edges().to_upper()
		entries[move_id] = category
	return entries


func _parse_properties_file(path: String) -> Dictionary:
	var text = _read_text_file(path)
	var entries: Dictionary = {}
	var lines = text.split("\n")
	for raw_line_variant in lines:
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
