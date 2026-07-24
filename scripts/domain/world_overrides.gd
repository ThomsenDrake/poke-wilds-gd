extends RefCounted

# Sparse per-tile mutations layered over the deterministic world. Two entry
# kinds share this map type and one 10k cap (see the building placement spec,
# docs/product-specs/building-and-placement.md):
#   * clears  {kind:"cleared"|"dug", by:"cut"|"dig"|"smash", step:int} from the
#     harvest slice, applied so the tile reads as open ground;
#   * placed  {kind:"placed", structure_id, by:"build", step:int} from the build
#     loop, applied so the tile renders + collides as the structure (occupancy
#     from structures.gd).
# Both apply at the single WorldGenerator.get_tile_logic boundary, so render,
# traversal, encounters and audits see one post-mutation truth. The two kinds
# stay in SEPARATE maps on the live generator (and in two save keys) because a
# tile can be cleared and then built on, and demolition (build_runtime's
# try_demolish, via world_generator.remove_placement) reverts it to cleared
# ground, not respawn the tree; but the merged view mirror loads both
# into one map, which is why is_valid_entry/apply branch on kind.

const Structures := preload("res://scripts/domain/structures.gd")

const MAX_OVERRIDES := 10000
const KINDS := ["cleared", "dug"]
const PLACED_KIND := "placed"
const ACTIONS := ["cut", "dig", "smash"]


static func make_entry(kind: String, by: String, step: int) -> Dictionary:
	return {"kind": kind, "by": by, "step": step}


static func make_placement(structure_id: String, by: String, step: int, gate: bool = false) -> Dictionary:
	var entry := {"kind": PLACED_KIND, "structure_id": structure_id, "by": by, "step": step}
	if gate:
		entry["gate"] = true
	return entry


# Clears-only validity (the harvest kinds). Kept distinct from is_valid_entry so
# the placements map never accepts a clear and vice versa at the source level.
static func _is_clear_entry(override: Dictionary) -> bool:
	return KINDS.has(str(override.get("kind", ""))) and ACTIONS.has(str(override.get("by", "")))


static func is_valid_placement(placement: Dictionary) -> bool:
	return str(placement.get("kind", "")) == PLACED_KIND \
		and Structures.is_valid(str(placement.get("structure_id", "")))


# The branching validator the view mirror relies on: a merged dict carries both
# kinds through one map, so a single is_valid_entry must accept either.
static func is_valid_entry(override: Dictionary) -> bool:
	if str(override.get("kind", "")) == PLACED_KIND:
		return is_valid_placement(override)
	return _is_clear_entry(override)


# Stamps a clear (open ground) over the tile logic; unchanged harvest behavior.
static func _apply_clear(logic: Dictionary, override: Dictionary) -> Dictionary:
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


# Stamps a placed structure over the tile logic: occupancy + sprite come from
# structures.gd, the tile is mutated and encounter-free, and any tall-grass
# overlay is cleared so the structure owns the tile visually.
static func apply_placement(logic: Dictionary, placement: Dictionary) -> Dictionary:
	var structure_id := str(placement.get("structure_id", ""))
	var biome := str(logic.get("biome", ""))
	var gate := bool(placement.get("gate", false))
	var out := logic.duplicate(true)
	out["walkable"] = Structures.is_walkable(structure_id)
	out["prop_path"] = Structures.sprite_path_for(structure_id, biome, gate)
	out["prop_region"] = Structures.sprite_region_for(structure_id, biome, gate, Structures.placement_is_lit(placement))
	out["block_reason"] = Structures.block_reason(structure_id)
	out["requires_field_move"] = ""
	out["encounter"] = false
	out["tall_grass_path"] = ""
	out["tall_grass_key_color"] = ""
	out["mutated"] = true
	out["override_kind"] = PLACED_KIND
	out["override_by"] = str(placement.get("by", ""))
	out["structure_id"] = structure_id
	return out


# Branch on kind so the single boundary (and the view's merged map) routes a
# placed entry to structure behavior and a clear to open-ground behavior.
static func apply(logic: Dictionary, override: Dictionary) -> Dictionary:
	if str(override.get("kind", "")) == PLACED_KIND:
		return apply_placement(logic, override)
	return _apply_clear(logic, override)


# Stores one clears entry; sibling_size is the live size of the placements map
# so the shared MAX_OVERRIDES cap counts both kinds (an in-place update of an
# existing key never counts against the cap).
static func put(map: Dictionary, tile: Vector2i, entry: Dictionary, sibling_size: int = 0) -> bool:
	if not _is_clear_entry(entry):
		return false
	return _put_with_cap(map, tile, entry, sibling_size)


# Stores one placement entry against the clears map's size for the shared cap.
static func put_placement(map: Dictionary, tile: Vector2i, entry: Dictionary, clears_size: int = 0) -> bool:
	if not is_valid_placement(entry):
		return false
	return _put_with_cap(map, tile, entry, clears_size)


static func _put_with_cap(map: Dictionary, tile: Vector2i, entry: Dictionary, sibling_size: int) -> bool:
	if not map.has(tile) and map.size() + sibling_size >= MAX_OVERRIDES:
		push_warning("world mutation cap reached (%d entries); refusing %s" % [MAX_OVERRIDES, tile])
		return false
	map[tile] = entry
	return true


# Loads a save map into one mutations map. Uses the branching is_valid_entry so
# the view mirror can load a merged clears+placements dict into a single map; a
# well-formed clears key only carries clears, so the live clears map stays pure
# in normal play. Stops at the first cap refusal (save order is merge order).
static func merge_save(map: Dictionary, saved: Dictionary, sibling_size: int = 0) -> void:
	for key in saved.keys():
		var parts := str(key).split(",")
		var entry: Variant = saved[key]
		if parts.size() != 2 or not parts[0].is_valid_int() or not parts[1].is_valid_int():
			continue
		if not (entry is Dictionary) or not is_valid_entry(entry):
			continue
		if not _put_with_cap(map, Vector2i(parts[0].to_int(), parts[1].to_int()), (entry as Dictionary).duplicate(true), sibling_size):
			return


# Loads a placements save map; only placed entries pass, keeping the live
# placements map pure even if a corrupt structures key mixes kinds in.
static func merge_placements(map: Dictionary, saved: Dictionary, clears_size: int = 0) -> void:
	for key in saved.keys():
		var parts := str(key).split(",")
		var entry: Variant = saved[key]
		if parts.size() != 2 or not parts[0].is_valid_int() or not parts[1].is_valid_int():
			continue
		if not (entry is Dictionary) or not is_valid_placement(entry):
			continue
		if not _put_with_cap(map, Vector2i(parts[0].to_int(), parts[1].to_int()), (entry as Dictionary).duplicate(true), clears_size):
			return


static func to_save(map: Dictionary) -> Dictionary:
	var out := {}
	for tile: Vector2i in map.keys():
		var entry: Dictionary = map[tile]
		out["%d,%d" % [tile.x, tile.y]] = entry.duplicate(true)
	return out
