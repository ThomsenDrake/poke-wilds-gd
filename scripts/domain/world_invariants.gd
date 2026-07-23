extends RefCounted

# World-generator invariant checks, split out of world_generator.gd (which was
# at its 320-line ceiling) so the placement map could be added there without
# overflowing the budget. validate_invariants is the same deterministic-diff +
# biome-ring + spawn-reachability audit the consistency audit and sweep rely on;
# it now runs over a passed generator instead of over `self`, calling back into
# the generator's public seam (setup / get_tile_logic / find_walkable_spawn /
# reachable_walkable_count) so generation logic stays single-sourced there.

# Distance bands the ring rules below enforce (inner safe biomes, mid hazards
# kept out, far extremes kept out). Moved here with validate_invariants because
# nothing in the generator's hot path reads them.
const RING_INNER := 10
const RING_MIDDLE := 28
const RING_OUTER := 60
const SPAWN_REACH_BUDGET := 64
const SPAWN_REACH_MIN := 12


# Cross-checks a generator's determinism, biome rings and spawn reachability for
# a seed. gen is a live WorldGenerator instance; a second one is built from its
# script to prove two independent setups agree tile-for-tile.
static func validate_invariants(gen, seed_value: int) -> Dictionary:
	gen.setup(seed_value)
	var failures: Array = []
	var gen2 = gen.get_script().new()
	gen2.setup(seed_value)

	for pos in _invariant_sample_positions():
		var a = gen.get_tile_logic(pos)
		var b = gen2.get_tile_logic(pos)
		if str(a["biome"]) != str(b["biome"]) or bool(a["walkable"]) != bool(b["walkable"]) or str(a["requires_field_move"]) != str(b["requires_field_move"]):
			failures.append("determinism_mismatch @ %d,%d" % [pos.x, pos.y])

	for pos in _invariant_sample_positions():
		var distance = abs(pos.x) + abs(pos.y)
		var biome = str(gen.get_tile_logic(pos)["biome"])
		if distance < RING_INNER and not _biome_in(biome, ["WATER", "SAND", "PLAINS", "GRASSLAND"]):
			failures.append("ring_inner_violation @ %d,%d (%s)" % [pos.x, pos.y, biome])
		if distance < RING_MIDDLE and _biome_in(biome, ["DESERT", "SWAMP", "ROCK", "SNOW", "LAVA"]):
			failures.append("ring_middle_violation @ %d,%d (%s)" % [pos.x, pos.y, biome])
		if distance < RING_OUTER and _biome_in(biome, ["SNOW", "LAVA"]):
			failures.append("ring_outer_violation @ %d,%d (%s)" % [pos.x, pos.y, biome])

	var spawn = gen.find_walkable_spawn(seed_value)
	if not bool(gen.get_tile_logic(spawn)["walkable"]):
		failures.append("spawn_not_walkable @ %d,%d" % [spawn.x, spawn.y])
	var reachable = gen.reachable_walkable_count(spawn, SPAWN_REACH_BUDGET)
	if reachable < SPAWN_REACH_MIN:
		failures.append("spawn_reach_too_small %d (< %d)" % [reachable, SPAWN_REACH_MIN])

	return {
		"ok": failures.is_empty(),
		"failures": failures,
		"spawn": [spawn.x, spawn.y],
		"reachable": reachable,
		"seed": seed_value
	}


static func _invariant_sample_positions() -> Array:
	var positions: Array = []
	for y in range(-70, 71, 14):
		for x in range(-70, 71, 14):
			positions.append(Vector2i(x, y))
	return positions


static func _biome_in(biome: String, allowed: Array) -> bool:
	return allowed.has(biome)
