extends RefCounted

# World-generator invariant checks, split out of world_generator.gd (which was
# at its 320-line ceiling) so the placement map could be added there without
# overflowing the budget. validate_invariants is the same deterministic-diff +
# biome-band + spawn-reachability audit the consistency audit and sweep rely on;
# it now runs over a passed generator instead of over `self`, calling back into
# the generator's public seam (setup / get_tile_logic / find_walkable_spawn /
# reachable_walkable_count) so generation logic stays single-sourced there.
#
# Infinite-world slice 2: the RING ADMISSION rules (inner/middle/outer distance
# bands) RETIRED with the radial biome model — biomes are climate-field derived
# (BiomeField), so SNOW/LAVA/DESERT legitimately appear at any distance. What
# stays load-bearing and is pinned here instead: the ELEVATION-BAND contract
# (WATER/SAND/ROCK come from elevation alone — coastlines, the beach band the
# slice-4 spawn rides, and mountains are model-invariant) + the closed biome set.

const BiomeField := preload("res://scripts/domain/biome_field.gd")

const SPAWN_REACH_BUDGET := 64
const SPAWN_REACH_MIN := 12


# Cross-checks a generator's determinism, elevation-band contract and spawn
# reachability for a seed. gen is a live WorldGenerator instance; a second one is
# built from its script to prove two independent setups agree tile-for-tile.
static func validate_invariants(gen, seed_value: int) -> Dictionary:
	gen.setup(seed_value)
	var failures: Array = []
	var gen2 = gen.get_script().new()
	gen2.setup(seed_value)
	# The landmark resolver is WIRING, not setup state: the invariant compares two
	# LIKE-WIRED generators, so the seam rides both (outside every footprint the
	# resolver is a no-op; inside, both stamp the identical footprint logic).
	gen2.landmark_resolver = gen.landmark_resolver

	for pos in _invariant_sample_positions():
		var a = gen.get_tile_logic(pos)
		var b = gen2.get_tile_logic(pos)
		if str(a["biome"]) != str(b["biome"]) or bool(a["walkable"]) != bool(b["walkable"]) or str(a["requires_field_move"]) != str(b["requires_field_move"]):
			failures.append("determinism_mismatch @ %d,%d" % [pos.x, pos.y])

	# Elevation-band contract (BiomeField): WATER/SAND/ROCK are elevation-driven in
	# EVERY biome model — the beach band + coastlines + mountains must never drift
	# with a climate-table edit. Also pins the closed 11-biome set.
	var channels := BiomeField.make_channels(seed_value)
	for pos in _invariant_sample_positions():
		var biome = str(gen.get_tile_logic(pos)["biome"])
		if not BiomeField.KNOWN_BIOMES.has(biome):
			failures.append("unknown_biome @ %d,%d (%s)" % [pos.x, pos.y, biome])
			continue
		var e := BiomeField.elevation_from(channels, pos)
		if e < BiomeField.WATER_ELEVATION and biome != "WATER":
			failures.append("band_violation @ %d,%d (e %.3f < %.2f but %s != WATER)" % [pos.x, pos.y, e, BiomeField.WATER_ELEVATION, biome])
		elif e < BiomeField.SAND_ELEVATION and biome != "SAND" and e >= BiomeField.WATER_ELEVATION:
			failures.append("band_violation @ %d,%d (e %.3f in beach band but %s != SAND)" % [pos.x, pos.y, e, biome])
		elif e >= BiomeField.ROCK_BIOME_ELEVATION and biome != "ROCK":
			failures.append("band_violation @ %d,%d (e %.3f >= %.2f but %s != ROCK)" % [pos.x, pos.y, e, BiomeField.ROCK_BIOME_ELEVATION, biome])
		elif e >= BiomeField.SAND_ELEVATION and e < BiomeField.ROCK_BIOME_ELEVATION and ["WATER", "SAND", "ROCK"].has(biome):
			failures.append("band_violation @ %d,%d (e %.3f inland but %s is an elevation band)" % [pos.x, pos.y, e, biome])

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
