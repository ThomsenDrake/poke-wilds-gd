extends RefCounted

# Phase 7 Build 3 — PURE world-chain domain (world-depth.md § World chaining, § Pinned
# constants; faithful loop fresh-faq.md:182-188). The port's noise plane is UNBOUNDED
# today, so chaining first gives it an EXTENT: WORLD_RADIUS := 96 Manhattan (FLAGGED
# invention #6 — beyond the ring-60 SNOW/LAVA band so every distance-gated system (rings,
# level_from_distance, NEST_MIN_RING, the legendary gate) sits INSIDE the playable disc).
#
# Per-world seed = a pure SplitMix hash of (root_seed, chain coords) — origin returns
# root_seed UNMIXED (the FROZEN identity world_seed_for(root,(0,0)) == root: the golden
# byte-proof + every existing save's terrain anchor — NOT user-tunable). NO
# RandomNumberGenerator anywhere: world-depth.md § Determinism (check_repo_contracts.py's
# world_depth_rng_issues bans a construction in this file); root_seed is drawn ONCE at
# new_game from the shared _rng and every world thereafter is a pure function of it.

const OverworldMons := preload("res://scripts/domain/overworld_mons.gd") # _mix SplitMix shape (same layer; the legendary_placement.gd:132 precedent)
const WorldGenerator := preload("res://scripts/domain/world_generator.gd") # entry-tile walkability (domain -> domain; pure, resolver-unset base logic)

const WORLD_RADIUS := 96 # Manhattan extent; edge beyond ring-60 (flagged #6)
const TELEPORT_EDGE_MARGIN := 8 # edge-proximity teleport suppression band (manhattan >= 96 - 8 refuses; flagged #12 — the FAQ :190 numbers are invention)
const ENTRY_TILE_BUDGET := 200 # bounded entry-tile search (FAQ :208-210 bounded generation)
const SALT_WORLD := 0x21 # distinct odd mix salt continuing overworld_mons.gd:71-80's 0x1..0x13 sequence (per-world seed; origin stays unmixed)

# The four crossing directions (screen-north = -y, the port's map convention).
const DIRECTIONS := [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]


# chain == (0,0) -> root_seed ITSELF (origin terrain is EXACTLY the v4 world); any other
# chain -> _mix(root, cx, cy, SALT_WORLD) & 0x7fffffff (explicit constants + 63-bit masks,
# NO engine hash() — reproducibility: (root_seed, crossing script) fixes the whole chain).
static func world_seed_for(root_seed: int, chain: Vector2i) -> int:
	if chain == Vector2i.ZERO:
		return int(root_seed)
	return OverworldMons._mix(int(root_seed), chain.x, chain.y, SALT_WORLD) & 0x7fffffff


# Relative/grid chain coords: crossing North from (cx,cy) enters (cx,cy-1); the FAQ's
# "Surf/Fly back the same direction(s)" is direction INVERSION on this grid.
static func adjacent_chain(chain: Vector2i, direction: Vector2i) -> Vector2i:
	return chain + direction


static func is_cardinal(direction: Vector2i) -> bool:
	return DIRECTIONS.has(direction)


static func distance(tile: Vector2i) -> int:
	return absi(tile.x) + absi(tile.y)


# Past the playable disc (manhattan >= WORLD_RADIUS): a step landing here LEAVES the world.
static func is_outside(tile: Vector2i) -> bool:
	return distance(tile) >= WORLD_RADIUS


# Standing at the farthest edge (manhattan >= WORLD_RADIUS - 1): the crossing precondition.
static func at_edge(tile: Vector2i) -> bool:
	return distance(tile) >= WORLD_RADIUS - 1


# Edge-proximity teleport suppression (fresh-faq.md:190 "move away from the edge a bit
# before trying again"; the numbers are flagged invention #12): Teleport can't skip the
# chain mechanic. use_teleport/use_fly refuse "edge_suppressed" on this predicate.
static func teleport_suppressed_at(tile: Vector2i) -> bool:
	return distance(tile) >= WORLD_RADIUS - TELEPORT_EDGE_MARGIN


# A way-stone registered inside the suppression band IS a Teleport Beacon (beacon vs
# way-stone distinguished by EDGE PROXIMITY, not a separate structure — flagged #12).
# beacon_placed fires only for these; an inland stone keeps waystone_registered only.
static func is_beacon_tile(tile: Vector2i) -> bool:
	return teleport_suppressed_at(tile)


# Crossing deposit (FLAGGED tile choice #6): crossing North lands the player on the SOUTH
# edge of the new world (the half-diamond OPPOSITE the travel direction), on a seed-derived
# walkable tile at distance WORLD_RADIUS - 2, so the return crossing is immediately
# available; a surf crossing seeks a water-adjacent walkable tile. Bounded by
# ENTRY_TILE_BUDGET probes (the opposite half-ring holds 2 * (WORLD_RADIUS - 2) + 1 tiles,
# inside the budget, so the whole half-ring is swept). Pure: a private generator instance
# with NO landmark resolver (base terrain only — footprints never steer the deposit).
static func entry_tile_for(world_seed: int, from_direction: Vector2i, surf_cross: bool = false) -> Vector2i:
	var travel := from_direction if is_cardinal(from_direction) else Vector2i.UP
	var candidates := _edge_half_ring(travel)
	if candidates.is_empty():
		return Vector2i.ZERO
	var start := int(OverworldMons._mix(int(world_seed), travel.x, travel.y, SALT_WORLD) % candidates.size())
	var generator = WorldGenerator.new()
	generator.setup(int(world_seed))
	var first_walkable := Vector2i.MAX
	for i in range(mini(candidates.size(), ENTRY_TILE_BUDGET)):
		var tile: Vector2i = candidates[(start + i) % candidates.size()]
		if not bool(generator.get_tile_logic(tile).get("walkable", false)):
			continue
		if first_walkable == Vector2i.MAX:
			first_walkable = tile
		if not surf_cross or _water_adjacent(generator, tile):
			return tile
	# Budget-exhausted (or no water-adjacent walkable): relax surf adjacency, then position —
	# never crash; the deposit stays in-extent at distance WORLD_RADIUS - 2 (documented).
	if first_walkable != Vector2i.MAX:
		return first_walkable
	return candidates[start]


# The half of the manhattan ring at distance WORLD_RADIUS - 2 OPPOSITE the travel
# direction (dot(tile, travel) <= 0): travel North (0,-1) -> the y >= 0 (south) edge.
# Deterministic order: x ascending, +y before -y (the filter leaves one point per x).
static func _edge_half_ring(travel: Vector2i) -> Array:
	var ring := WORLD_RADIUS - 2
	var tiles: Array = []
	for x in range(-ring, ring + 1):
		for y_sign in [1, -1]:
			var y := (ring - absi(x)) * int(y_sign)
			var tile := Vector2i(x, y)
			if tile.x * travel.x + tile.y * travel.y > 0:
				continue # same-direction half: the edge the player LEFT from
			if tiles.is_empty() or tiles[tiles.size() - 1] != tile:
				tiles.append(tile)
	return tiles


# True when a cardinal neighbor reads as WATER (the generator's surf gate — a surf deposit
# puts the player beside crossable water, matching "surf-crossing seeks water-adjacent").
static func _water_adjacent(generator: RefCounted, tile: Vector2i) -> bool:
	for direction in DIRECTIONS:
		if str(generator.get_tile_logic(tile + direction).get("requires_field_move", "")) == "surf":
			return true
	return false
