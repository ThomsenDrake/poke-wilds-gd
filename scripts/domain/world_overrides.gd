extends RefCounted

# Sparse per-tile overrides layered over the deterministic world (spec:
# docs/superpowers/specs/2026-07-18-harvest-and-world-mutation-design.md).
# Entries are {kind: "cleared"|"dug", by: "cut"|"dig"|"smash", step: int} and
# are applied at the WorldGenerator.get_tile_logic boundary, so every reader
# (render, traversal, encounters, audits) sees post-override logic.

const MAX_OVERRIDES := 10000
const KINDS := ["cleared", "dug"]
const ACTIONS := ["cut", "dig", "smash"]


static func make_entry(kind: String, by: String, step: int) -> Dictionary:
	return {"kind": kind, "by": by, "step": step}


static func is_valid_entry(override: Dictionary) -> bool:
	return KINDS.has(str(override.get("kind", ""))) and ACTIONS.has(str(override.get("by", "")))


static func apply(logic: Dictionary, override: Dictionary) -> Dictionary:
	var out := logic.duplicate(true)
	out["walkable"] = true
	out["prop_path"] = ""
	out["prop_region"] = null
	out["block_reason"] = ""
	out["requires_field_move"] = ""
	out["mutated"] = true
	out["override_kind"] = str(override.get("kind", ""))
	out["override_by"] = str(override.get("by", ""))
	if str(override.get("kind", "")) == "dug":
		out["encounter"] = false
		out["tall_grass_path"] = ""
		out["tall_grass_key_color"] = ""
	return out


static func put(map: Dictionary, tile: Vector2i, entry: Dictionary) -> bool:
	if not is_valid_entry(entry):
		return false
	if not map.has(tile) and map.size() >= MAX_OVERRIDES:
		push_warning("world override cap reached (%d entries); refusing %s" % [MAX_OVERRIDES, tile])
		return false
	map[tile] = entry
	return true


static func merge_save(map: Dictionary, saved: Dictionary) -> void:
	for key in saved.keys():
		var parts := str(key).split(",")
		var entry: Variant = saved[key]
		if parts.size() != 2 or not parts[0].is_valid_int() or not parts[1].is_valid_int():
			continue
		if not (entry is Dictionary) or not is_valid_entry(entry):
			continue
		var valid_entry: Dictionary = entry
		if not put(map, Vector2i(parts[0].to_int(), parts[1].to_int()), valid_entry.duplicate(true)):
			return


static func to_save(map: Dictionary) -> Dictionary:
	var out := {}
	for tile: Vector2i in map.keys():
		var entry: Dictionary = map[tile]
		out["%d,%d" % [tile.x, tile.y]] = entry.duplicate(true)
	return out
