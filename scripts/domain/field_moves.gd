extends RefCounted

# Per-mon field-move capability (spec section 1): species flag 1 always able,
# flag 2 force-unable, otherwise the move's auto-ability type decides.

const AUTO_TYPES := {"cut": "GRASS", "dig": "GROUND", "power": "ELECTRIC", "smash": "ROCK", "flash": "FIRE", "build": "FIGHTING", "charm": "FAIRY", "repel": "POISON", "attack": "DARK", "teleport": "PSYCHIC"}


static func can_perform(mon: Dictionary, move_id: String, get_species: Callable) -> bool:
	var id := move_id.strip_edges().to_lower()
	var species: Dictionary = get_species.call(str(mon.get("species_id", "")))
	var flags: Dictionary = species.get("field_moves", {})
	var flag := int(flags.get(id, 0))
	if flag == 2:
		return false
	if flag == 1:
		return true
	if id == "surf":
		return _is_final_water(species)
	var auto := str(AUTO_TYPES.get(id, ""))
	return not auto.is_empty() and (species.get("types", PackedStringArray()) as PackedStringArray).has(auto)


static func _is_final_water(species: Dictionary) -> bool:
	return (species.get("types", PackedStringArray()) as PackedStringArray).has("WATER") and (species.get("evolutions", []) as Array).is_empty()
