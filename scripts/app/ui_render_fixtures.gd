extends RefCounted

# Worst-case catalog fixtures for the UI audits + sweeps (extracted from
# ui_render_model.gd for the app line budget). Every fixture is catalog-anchored:
# worst names/counts come from the loaded data, never from hardcoded literals, so
# the audit inputs track the dataset they police.


static func worst_snapshot(catalog) -> Dictionary:
	var species := worst_entry(catalog.species.values(), "display_name")
	var move := worst_entry(catalog.moves.values(), "display_name")
	var typed := worst_typed_move(catalog)
	var moves := []
	for source in [typed, move, move, move]:
		moves.append({"move_id": str(source.get("move_id", "")), "name": str(source.get("display_name", "")),
			"type": str(source.get("type", "NORMAL")), "pp": int(source.get("pp", 20)), "max_pp": int(source.get("pp", 20))})
	var mon := {"name": str(species.get("display_name", "?")), "level": 100, "current_hp": 100, "max_hp": 100,
		"status": "PSN", "back_path": "", "front_path": "", "moves": moves}
	var message := "%s used PECK!" % str(species.get("display_name", "?")).get_slice(" ", 0).to_upper()
	return {"player_mon": mon, "enemy_mon": mon, "bag": {"poke_ball": 99, "potion": 99}, "message": message}


static func worst_party(species: Dictionary) -> Array:
	var party := []
	for i in range(6):
		party.append({"name": str(species.get("display_name", "Pokemon")), "species_id": str(species.get("species_id", "")),
			"moves": [], "level": 100, "current_hp": 100, "max_hp": 100, "status": "PSN" if i % 2 == 0 else "", "exp": 0,
			"types": species.get("types", PackedStringArray(["NORMAL"])), "stats": {"atk": 100, "def": 100, "spe": 100, "sat": 100, "sdf": 100}})
	return party


static func worst_bag(catalog) -> Array:
	var items: Array = catalog.items.values()
	items.sort_custom(func(a, b): return str(a.get("display_name", "")).length() > str(b.get("display_name", "")).length())
	var bag := []
	for i in range(mini(6, items.size())):
		bag.append({"item_id": str(items[i].get("item_id", "")), "count": 99})
	return bag

static func bag_names(catalog) -> Array: # worst_bag's display names (the menu audit's bag contains check)
	var names := []
	for entry in worst_bag(catalog):
		var item: Dictionary = catalog.get_item(str(entry.get("item_id", "")))
		if not item.is_empty(): names.append(str(item.get("display_name", "")).capitalize())
	return names


static func worst_entry(entries: Array, field: String) -> Dictionary:
	var best: Dictionary = {}
	for entry in entries:
		if entry is Dictionary and str((entry as Dictionary).get(field, "")).length() > str(best.get(field, "")).length():
			best = entry
	return best


static func worst_typed_move(catalog) -> Dictionary:
	var best: Dictionary = {}
	for move in catalog.moves.values():
		if str(move.get("type", "")).length() > str(best.get("type", "")).length():
			best = move
	return best
