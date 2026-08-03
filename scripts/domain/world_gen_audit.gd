extends RefCounted

# World-generation AUDIT harness — shared contract (spec: bootstrap-and-overworld.md;
# the comprehensive world-gen workflow). Pure measurement, NO rng, NO I/O: every result is
# a pure function of (code, catalog, seed) so the audit is deterministic and its findings
# are the regression net for the later world-gen fix slices (blending, stat-aware spawns,
# dungeon sites). Three families fold into ONE findings dict here:
#   world_gen_cohesion.gd  — determinism, biome distribution, adjacency, region fragmentation
#   world_gen_spawns.gd    — type↔biome coherence, BST-by-biome, level-band↔strength
#   world_gen_dungeons.gd  — biome site availability, chunk-hash content density, reachability
# (Infinite-world slice 2 retired the radial ring model's admission/seam/bands/extent checks.)
# Each family returns {enforcing_failures: Array[String], advisory: Array[Dictionary],
# metrics: Dictionary}; the runner folds them via fold() + finalize(). TIER RULE: only
# structural invariants that hold TODAY enforce (red on regression); every gap that needs
# a future fix rides `advisory` (warning-tier, never gates) — see the plan's promotion path.

# --- scan geometry ---
const SCAN_RADIUS := 110 # cohesion disc (Manhattan); ~24.4k tiles
const SITE_SCAN_RADIUS := 96 # dungeon site scan window (a bounded sample of the infinite plane; decoupled from any world extent since the infinite-world slice)
const SITE_SCAN_STRIDE := 2 # site-scan sampling step (keeps the footprint sweep cheap)

# --- spawn disc ---
const SPAWN_DISC := 24 # world_generator.SPAWN_SEARCH_RADIUS — footprints must stay outside

# --- analysis constants ---
const REACH_BUDGET := 5000 # BFS flood budget for spawn/landmark reachability
const SPAWN_REACH_MIN := 12 # mirrors world_invariants.SPAWN_REACH_MIN
const SPECK_THRESHOLD := 8 # a biome region smaller than this is a salt-and-pepper speck
const LAVA_WINDOWS_MIN := 6 # cross-seed LAVA presence contract: the rare joint tail must appear in at least this many of the audit's 9 seed windows (a cold-climate window may legitimately lack it)
const BST_HIGH := 540 # provisional "strong mon" base-stat-total (re-pin when the spawn fix lands)

const BIOMES := ["WATER", "SAND", "PLAINS", "GRASSLAND", "FOREST", "SAVANNA", "DESERT", "SWAMP", "ROCK", "SNOW", "LAVA"]
# The land biomes (WATER/SAND are the elevation bands and never site a dungeon). The
# retired radial TIER_BY_BIOME depth table is gone with the ring model — biomes carry
# no spatial depth under the climate field (infinite-world slice 2).
const LAND_BIOMES := ["PLAINS", "GRASSLAND", "FOREST", "SAVANNA", "DESERT", "SWAMP", "ROCK", "SNOW", "LAVA"]
# Hard-hostile adjacencies a cohesive world should avoid (the blending fix's target contract).
const HOSTILE_PAIRS := [["SNOW", "LAVA"], ["LAVA", "WATER"], ["DESERT", "SNOW"], ["LAVA", "GRASSLAND"], ["SNOW", "SAVANNA"]]
const EXTREME_BIOMES := ["SNOW", "LAVA"] # the quantization-tail biomes whose reachability is the headline measurement

const SCHEMA := "world-gen-audit/1"


# --- findings builder ---

static func new_findings(seeds: Array, scan_radius: int) -> Dictionary:
	return {
		"schema": SCHEMA, "seeds": seeds.duplicate(), "scan_radius": scan_radius, "tiles_checked": 0,
		"goals": {"cohesion": {"enforcing": {}, "advisory": {}, "metrics": {}},
			"spawns": {"enforcing": {}, "advisory": {}, "metrics": {}},
			"dungeons": {"enforcing": {}, "advisory": {}, "metrics": {}}},
		"enforcing_failures": [], "advisory_findings": [],
	}


# Fold one family's result ({enforcing_failures, advisory, metrics}) into the findings.
static func fold(findings: Dictionary, goal: String, result: Dictionary) -> void:
	var bucket: Dictionary = findings["goals"][goal]
	bucket["enforcing"] = result.get("enforcing", {})
	bucket["metrics"] = result.get("metrics", {})
	for failure in result.get("enforcing_failures", []):
		findings["enforcing_failures"].append("[%s] %s" % [goal, str(failure)])
	for item in result.get("advisory", []):
		var entry: Dictionary = item.duplicate(true)
		entry["goal"] = goal
		findings["advisory_findings"].append(entry)
		bucket["advisory"][str(entry.get("kind", "finding"))] = entry.get("value", null)


static func finalize(findings: Dictionary, tiles_checked: int) -> Dictionary:
	findings["tiles_checked"] = tiles_checked
	findings["ok"] = (findings["enforcing_failures"] as Array).is_empty()
	findings["enforcing_failure_count"] = (findings["enforcing_failures"] as Array).size()
	findings["advisory_count"] = (findings["advisory_findings"] as Array).size()
	return findings


# --- geometry helpers (pure) ---

static func ring_of(pos: Vector2i) -> int:
	return absi(pos.x) + absi(pos.y)


# Manhattan disc of all tiles with |x|+|y| <= radius (a bounded sample window of the infinite plane).
static func disc_positions(radius: int) -> Array:
	var positions: Array = []
	for y in range(-radius, radius + 1):
		var span := radius - absi(y)
		for x in range(-span, span + 1):
			positions.append(Vector2i(x, y))
	return positions


# Unordered biome-pair key for adjacency tabulation (SNOW|LAVA == LAVA|SNOW).
static func pair_key(a: String, b: String) -> String:
	return "%s|%s" % [a, b] if a < b else "%s|%s" % [b, a]


static func is_hostile_pair(a: String, b: String) -> bool:
	for pair in HOSTILE_PAIRS:
		if (pair[0] == a and pair[1] == b) or (pair[0] == b and pair[1] == a):
			return true
	return false


# The 9 probe points of a footprint (center + 4 corners + 4 edge midpoints) — mirrors
# landmarks._fits_on_land's 9-probe sampling through the PUBLIC tile-logic seam.
static func footprint_probes(center: Vector2i, size: Vector2i) -> Array:
	var half := size / 2
	var x0 := center.x - half.x; var x1 := center.x + half.x
	var y0 := center.y - half.y; var y1 := center.y + half.y
	var mx := (x0 + x1) / 2; var my := (y0 + y1) / 2
	return [Vector2i(mx, my), Vector2i(x0, y0), Vector2i(x1, y0), Vector2i(x0, y1), Vector2i(x1, y1),
		Vector2i(mx, y0), Vector2i(mx, y1), Vector2i(x0, my), Vector2i(x1, my)]


# "Land" for footprint siting, read off the public tile-logic results (NOT raw noise): not
# WATER (elevation < -0.30) and not an unwalkable smash-gate. CONSERVATIVE PROXY: the public
# seam cannot distinguish an elevation>0.55 rock CLIFF from a ROCK-biome rock PROP (both are
# walkable=false + requires_field_move="smash", identical texture), so BOTH read as non-land
# here, whereas landmarks._fits_on_land (elevation-only; footprints stamp OVER props) counts
# rock props as land — ROCK site counts are therefore a LOWER BOUND (~12% under on measured
# seeds). Cut-gated blocking props (trees) DO count as land (footprints stamp over them).
static func is_land(logic: Dictionary) -> bool:
	if str(logic.get("biome", "")) == "WATER":
		return false
	if str(logic.get("requires_field_move", "")) == "smash" and not bool(logic.get("walkable", false)):
		return false
	return true


# A footprint FITS at center when >= 7 of its 9 probes are land (the landmarks 7-of-9 rule).
static func footprint_fits(gen, center: Vector2i, size: Vector2i) -> bool:
	var land := 0
	for probe in footprint_probes(center, size):
		if is_land(gen.get_tile_logic(probe)):
			land += 1
	return land >= 7


static func key(pos: Vector2i) -> String:
	return "%d,%d" % [pos.x, pos.y]
