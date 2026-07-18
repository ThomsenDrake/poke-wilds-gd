extends RefCounted

# Pure-text parsers for the per-species data files under
# pokewilds/pokemon/pokemon/<slug>/. Malformed input yields partial or empty
# results instead of an error, so the catalog can count failures per species.

const TYPE_VOCAB := {
	"NORMAL": true, "FIRE": true, "WATER": true, "GRASS": true, "ELECTRIC": true,
	"ICE": true, "FIGHTING": true, "POISON": true, "GROUND": true, "FLYING": true,
	"PSYCHIC": true, "BUG": true, "ROCK": true, "GHOST": true, "DRAGON": true,
	"DARK": true, "STEEL": true, "FAIRY": true
}

# Fixed order of the 15 field-move db lines in wilds_data.asm.
const FIELD_MOVE_ORDER: PackedStringArray = [
	"dig", "power", "cut", "smash", "surf", "flash", "build", "charm",
	"repel", "attack", "teleport", "headbutt", "ride", "fly", "paint"
]

# Fixed order of the 4 overworld-property db lines in wilds_data.asm.
const OVERWORLD_BEHAVIOR_ORDER: PackedStringArray = ["swim_only", "flee", "lunge", "aggression"]


# Parses base_stats.asm. Returns {} when the species declaration, the stat
# line, or the type line is missing; every other field degrades to a default.
static func parse_base_stats(text: String) -> Dictionary:
	if text.is_empty():
		return {}

	var species_id := ""
	var dex_number := 0
	var base_stats := {}
	var types := PackedStringArray()
	var catch_rate := 0
	var base_exp := 0
	var growth_rate := ""
	var gender_ratio := ""
	var egg_groups := PackedStringArray()
	var tmhm := PackedStringArray()

	var stats_re := RegEx.new()
	stats_re.compile("^db\\s+(\\d+)\\s*,\\s*(\\d+)\\s*,\\s*(\\d+)\\s*,\\s*(\\d+)\\s*,\\s*(\\d+)\\s*,\\s*(\\d+)(?:\\s|;|,|$)")
	var pair_re := RegEx.new()
	pair_re.compile("^db\\s+([A-Z_]+)\\s*,\\s*([A-Z_]+)")
	var int_re := RegEx.new()
	int_re.compile("^db\\s+(\\d+)")
	var token_re := RegEx.new()
	token_re.compile("^db\\s+([A-Z0-9_]+)")

	for raw_line in text.split("\n"):
		var line := raw_line.strip_edges()
		if line.is_empty():
			continue

		# Species declaration is the first db line (`db BULBASAUR ; 1`).
		# Variants: no dex comment, punctuation names (`db MR. MIME`).
		if species_id.is_empty() and base_stats.is_empty() and types.is_empty() and line.begins_with("db"):
			var decl := line.substr(2).strip_edges()
			if not decl.is_empty() and not decl.contains(","):
				var comment := ""
				var semi := decl.find(";")
				if semi >= 0:
					comment = decl.substr(semi + 1).strip_edges()
					decl = decl.substr(0, semi).strip_edges()
				if not decl.is_empty() and not decl.is_valid_int():
					species_id = sanitize_species_id(decl)
					if comment.is_valid_int():
						dex_number = int(comment)
					continue

		if base_stats.is_empty():
			var stats_match := stats_re.search(line)
			if stats_match != null:
				base_stats = {
					"hp": int(stats_match.get_string(1)), "atk": int(stats_match.get_string(2)),
					"def": int(stats_match.get_string(3)), "spe": int(stats_match.get_string(4)),
					"sat": int(stats_match.get_string(5)), "sdf": int(stats_match.get_string(6))
				}
				continue

		if types.is_empty():
			var pair_match := pair_re.search(line)
			if pair_match != null and TYPE_VOCAB.has(pair_match.get_string(1)) and TYPE_VOCAB.has(pair_match.get_string(2)):
				types = PackedStringArray([pair_match.get_string(1), pair_match.get_string(2)])
				continue

		# Comment spelling differs between the two file generations
		# ("; catch rate" / ";catch rate", "; base exp" / ";exp rate").
		if catch_rate == 0 and line.contains("catch rate"):
			var catch_match := int_re.search(line)
			if catch_match != null:
				catch_rate = int(catch_match.get_string(1))
				continue

		if base_exp == 0 and line.contains("exp"):
			var exp_match := int_re.search(line)
			if exp_match != null:
				base_exp = int(exp_match.get_string(1))
				continue

		if gender_ratio.is_empty():
			var gender_match := token_re.search(line)
			if gender_match != null and gender_match.get_string(1).begins_with("GENDER_"):
				gender_ratio = gender_match.get_string(1)
				continue

		# Growth constant is GROWTH_-prefixed in newer files only.
		if growth_rate.is_empty() and line.contains("growth"):
			var growth_match := token_re.search(line)
			if growth_match != null:
				growth_rate = growth_match.get_string(1).trim_prefix("GROWTH_")
				continue

		if egg_groups.is_empty() and line.begins_with("dn EGG_"):
			for group in _csv_tail(line, 3).split(",", false):
				var group_name := group.strip_edges().trim_prefix("EGG_")
				if not group_name.is_empty():
					egg_groups.append(group_name)
			continue

		# The tm/hm learnset is a single (never wrapped) tmhm line.
		if tmhm.is_empty() and line.begins_with("tmhm "):
			for move_name in _csv_tail(line, 5).split(",", false):
				var move_id := move_name.strip_edges()
				if not move_id.is_empty():
					tmhm.append(move_id)

	if species_id.is_empty() or base_stats.is_empty() or types.is_empty():
		return {}

	return {
		"species_id": species_id, "dex_number": dex_number, "base_stats": base_stats,
		"types": types, "catch_rate": catch_rate, "base_exp": base_exp,
		"growth_rate": growth_rate, "gender_ratio": gender_ratio,
		"egg_groups": egg_groups, "tmhm": tmhm
	}


# Parses the evolution block of evos_attacks.asm, which sits above the
# level-up learnset and ends at `db 0 ; no more evolutions`. Line shape:
# `db EVOLVE_<METHOD>, <param|empty>, <TARGET>`.
static func parse_evolutions(text: String) -> Array:
	var evolutions: Array = []
	if text.is_empty():
		return evolutions

	for raw_line in text.split("\n"):
		var line := raw_line.strip_edges()
		if line.contains("no more evolutions") or line.contains("no more level-up moves"):
			break
		if not line.begins_with("db EVOLVE_"):
			continue
		var body := line.substr(3).strip_edges()
		var semi := body.find(";")
		if semi >= 0:
			body = body.substr(0, semi).strip_edges()
		var parts := body.split(",")
		if parts.size() < 2:
			continue
		var method := parts[0].strip_edges().trim_prefix("EVOLVE_")
		var target := sanitize_species_id(parts[parts.size() - 1].strip_edges())
		if target.is_empty():
			continue
		var param = null
		if parts.size() >= 3:
			var raw_param := parts[1].strip_edges()
			if not raw_param.is_empty():
				param = _evolution_param(raw_param)
		evolutions.append({"method": method, "param": param, "target": target})
	return evolutions


# Parses wilds_data.asm. Missing sections degrade to empty/zero defaults.
static func parse_wilds_data(text: String) -> Dictionary:
	var result := {
		"dex_number": 0, "dex_entry": "", "weight_kg": 0.0, "height_m": 0.0,
		"spawn_biomes": PackedStringArray(), "field_moves": {}, "overworld_behavior": {}
	}
	if text.is_empty():
		return result

	var number_re := RegEx.new()
	number_re.compile("^db\\s+(-?\\d+(?:\\.\\d+)?)")

	var lines := text.split("\n")
	var index := 0
	while index < lines.size():
		var line := lines[index].strip_edges()
		if line.contains("; Dex number"):
			result["dex_number"] = int(_leading_number(line, number_re))
		elif line.contains("; Dex entry"):
			result["dex_entry"] = _bracket_text(lines, index)
		elif line.contains("; Weight in kg"):
			result["weight_kg"] = _leading_number(line, number_re)
		elif line.contains("; Height in meters"):
			result["height_m"] = _leading_number(line, number_re)
		elif line.contains("; Spawning biomes"):
			result["spawn_biomes"] = _db_word_list(line)
		elif line.contains("Field moves"):
			result["field_moves"] = _ordered_db_ints(lines, index + 1, FIELD_MOVE_ORDER, number_re)
		elif line.contains("Overworld properties"):
			result["overworld_behavior"] = _ordered_db_ints(lines, index + 1, OVERWORLD_BEHAVIOR_ORDER, number_re)
		index += 1
	return result


# wilds_data.asm is Windows-1252/ISO-8859 encoded (e.g. the é in "Pokémon"),
# which FileAccess.get_as_text() would mangle as invalid UTF-8. Decode high
# bytes as Latin-1 so dex entries survive intact.
static func read_latin1_text(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var bytes := file.get_buffer(file.get_length())
	file.close()
	if bytes.size() >= 3 and bytes[0] == 0xEF and bytes[1] == 0xBB and bytes[2] == 0xBF:
		return bytes.get_string_from_utf8()
	var out := PackedByteArray()
	for byte in bytes:
		if byte < 0x80:
			out.append(byte)
		else:
			out.append(0xC0 | (byte >> 6))
			out.append(0x80 | (byte & 0x3F))
	return out.get_string_from_utf8()


# Normalizes a species constant (BULBASAUR, HO-OH, MR. MIME, NIDORAN{) to a
# dictionary-safe id: uppercase alphanumerics with any other run collapsed
# to a single underscore, no leading/trailing separators.
static func sanitize_species_id(raw: String) -> String:
	var id := ""
	var pending_separator := false
	for i in raw.length():
		var character := raw.substr(i, 1).to_upper()
		var is_alnum := (character >= "A" and character <= "Z") or (character >= "0" and character <= "9")
		if is_alnum:
			if pending_separator and not id.is_empty():
				id += "_"
			id += character
			pending_separator = false
		else:
			pending_separator = true
	return id


static func _evolution_param(raw: String) -> Variant:
	if raw.is_valid_int():
		return int(raw)
	if raw.begins_with("TR_"):
		return raw.substr(3)
	return raw


static func _leading_number(line: String, number_re: RegEx) -> float:
	var match := number_re.search(line)
	if match == null:
		return 0.0
	return float(match.get_string(1))


# Returns the text after `skip` leading characters with its comment cut off.
static func _csv_tail(line: String, skip: int) -> String:
	var body := line.substr(skip).strip_edges()
	var semi := body.find(";")
	if semi >= 0:
		body = body.substr(0, semi).strip_edges()
	return body


# Extracts the <...> dex entry text starting at lines[start]; tolerates the
# closing bracket landing on a later line.
static func _bracket_text(lines: PackedStringArray, start: int) -> String:
	var text := lines[start]
	var guard := 0
	while text.find("<") >= 0 and (text.find(">") < 0 or text.find(">") < text.find("<")) and start + guard + 1 < lines.size() and guard < 8:
		guard += 1
		text += " " + lines[start + guard]
	var open := text.find("<")
	var close := text.find(">", open)
	if open < 0 or close < 0:
		return ""
	return text.substr(open + 1, close - open - 1).strip_edges()


# Splits `db FOREST SAVANNA ; comment` into word tokens, keeping source
# tokens (including the TYPE sentinel and duplicates) verbatim.
static func _db_word_list(line: String) -> PackedStringArray:
	var words := PackedStringArray()
	if not line.begins_with("db"):
		return words
	for word in _csv_tail(line, 2).split(" ", false):
		var token := word.strip_edges()
		if not token.is_empty():
			words.append(token)
	return words


# Collects order.size() numeric db lines from lines[start] onward and maps
# them, in fixed order, onto the given keys.
static func _ordered_db_ints(lines: PackedStringArray, start: int, order: PackedStringArray, number_re: RegEx) -> Dictionary:
	var values := {}
	var slot := 0
	var cursor := start
	while cursor < lines.size() and slot < order.size():
		var line := lines[cursor].strip_edges()
		if line.begins_with("db"):
			var match := number_re.search(line)
			if match != null:
				values[order[slot]] = int(float(match.get_string(1)))
				slot += 1
		cursor += 1
	return values
