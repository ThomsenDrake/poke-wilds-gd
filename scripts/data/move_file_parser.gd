extends RefCounted

# Parsers for the shared move data files: pokewilds/pokemon/moves.asm (move
# stats) and pokewilds/pokemon/spec_phys_lookup.txt (category overrides).
# Moved out of pokemon_catalog.gd unchanged to keep the facade under budget.

static func parse_moves(text: String, move_names: Dictionary, move_categories: Dictionary) -> Dictionary:
	var entries: Dictionary = {}
	var move_re := RegEx.new()
	move_re.compile("^\\s*move\\s+([A-Z0-9_]+)\\s*,\\s*([A-Z0-9_]+)\\s*,\\s*([0-9]+)\\s*,\\s*([A-Z_]+)\\s*,\\s*([0-9]+)\\s*,\\s*([0-9]+)\\s*,\\s*([0-9]+)")

	for raw_line in text.split("\n"):
		var match := move_re.search(raw_line)
		if match == null:
			continue

		var move_id := match.get_string(1)
		var power := int(match.get_string(3))
		var move_key := move_id.to_lower()
		var display_name := str(move_names.get(move_key, _humanize(move_key)))
		var category := str(move_categories.get(move_id, "PHYSICAL"))
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


static func parse_move_categories(text: String) -> Dictionary:
	var entries: Dictionary = {}
	for raw_line in text.split("\n"):
		var line := raw_line.strip_edges()
		if line.is_empty():
			continue
		var parts := line.split(",", false, 2)
		if parts.size() < 2:
			continue
		entries[parts[0].strip_edges().to_upper()] = parts[1].strip_edges().to_upper()
	return entries


static func _humanize(slug: String) -> String:
	var spaced := slug.replace("_", " ")
	if spaced.is_empty():
		return slug
	return spaced.capitalize()
