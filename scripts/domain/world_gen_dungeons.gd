extends RefCounted

# World-generation AUDIT family — DUNGEONS (spec: infinite-world.md; world-depth.md
# § Landmarks / § Legendaries). Pure measurement of biome SITE availability, spawn-disc
# exclusion and spawn/landmark reachability. NO rng, NO I/O: a pure deterministic function
# of a live WorldGenerator `gen` (setup(seed)) + the int `seed` (chain frozen at origin —
# the seamless infinite plane retired chaining).
#
# TIER RULE: only structural invariants that HOLD TODAY ride `enforcing_failures` (red on
# regression): the spawn flood reaching a minimum region. Every gap that needs a FUTURE fix
# rides `advisory` and NEVER gates: LAVA site availability (LAVA never generates on origin),
# legendary NO_ANCHOR (the LAVA four on origin), spawn-disc intrusion, and the gen-time
# landmark reachability gate (spec §19(c), unimplemented).

const WorldGenAudit := preload("res://scripts/domain/world_gen_audit.gd")
const Landmarks := preload("res://scripts/domain/landmarks.gd")
const LegendaryPlacement := preload("res://scripts/domain/legendary_placement.gd")


# --- public entry -----------------------------------------------------------------
static func audit(gen, seed: int) -> Dictionary:
	var enforcing: Dictionary = {}
	var failures: Array = []
	var advisory: Array = []

	# (1) ADVISORY site availability: stride-scan the audit window for a representative footprint
	# (RUINS_SIZE) per land biome; LAVA never generates on origin => zero LAVA-dungeon sites.
	var site_size: Vector2i = Landmarks.RUINS_SIZE
	var sites := _site_scan(gen, site_size)
	advisory.append({"kind": "site_availability", "value": sites.duplicate(),
		"detail": "Audit-window centers (stride %d) whose biome fits a %dx%d dungeon footprint (conservative: ROCK counts rock props as non-land, so ROCK is a lower bound — see WorldGenAudit.is_land)." % [WorldGenAudit.SITE_SCAN_STRIDE, site_size.x, site_size.y]})
	if int(sites.get("LAVA", 0)) == 0:
		advisory.append({"kind": "lava_site_gap", "value": 0,
			"detail": "LAVA never generates on origin => zero LAVA-dungeon sites (the headline gap; a future fix makes LAVA generate in deep rings)."})

	# Landmarks placed in this world (all three host; chain frozen at origin).
	var landmarks := Landmarks.landmarks_in_world(seed, Vector2i.ZERO)

	# (2) ADVISORY legendary anchors: the LAVA four resolve NO_ANCHOR (LAVA never generates).
	var legend := _legendary_anchors(seed)
	advisory.append({"kind": "legendary_no_anchor", "value": legend["no_anchor"],
		"detail": "Legendary species whose affinity biome never generates in this world resolve NO_ANCHOR (the LAVA four on origin)."})

	# (4) ADVISORY spawn_disc_exclusion: a landmark footprint CAN intrude within SPAWN_DISC of
	# origin (measured: the ring-34 Ruins reach manhattan <=24 on some seeds — its footprint's
	# inner edge lands inside the spawn disc). This is a placement gap for the dungeon-placement
	# fix slice (add a gen-time spawn-disc exclusion); NOT gated today (the world does not yet
	# guarantee it). The count stays in `enforcing` as an informational metric.
	var in_disc := 0
	for landmark in landmarks:
		var footprint: Rect2i = landmark.get("footprint", Rect2i())
		if _footprint_touches_disc(footprint, WorldGenAudit.SPAWN_DISC):
			in_disc += 1
	enforcing["footprints_in_spawn_disc"] = in_disc
	if in_disc > 0:
		advisory.append({"kind": "spawn_disc_intrusion", "value": in_disc,
			"detail": "%d landmark footprint(s) intrude within manhattan %d of origin on this seed (spawn-disc exclusion is not guaranteed by world gen — the dungeon slice adds a placement-time gate)." % [in_disc, WorldGenAudit.SPAWN_DISC]})

	# (5) ENFORCE spawn_reach: the spawn flood reaches a minimum walkable region.
	var spawn: Vector2i = gen.find_walkable_spawn(seed)
	var reachable := int(gen.reachable_walkable_count(spawn, WorldGenAudit.REACH_BUDGET))
	enforcing["spawn_reachable"] = reachable
	if reachable < WorldGenAudit.SPAWN_REACH_MIN:
		failures.append("spawn_reach: spawn flood reached %d walkable tiles (< %d)" % [reachable, WorldGenAudit.SPAWN_REACH_MIN])

	# (6) ADVISORY landmark reachability: the gen-time gate (spec §19(c)) is UNIMPLEMENTED, so every
	# landmark reports not_verified — the public seam exposes no visited set to confirm a footprint.
	var reachability := {}
	for landmark in landmarks:
		reachability[str(landmark.get("landmark_id", ""))] = "not_verified"
	advisory.append({"kind": "landmark_reachability", "value": reachability,
		"detail": "gen-time reachability gate is unimplemented (spec §19(c)); footprint reachability from spawn is not verified."})

	var metrics := {
		"landmarks_placed": landmarks.size(),
		"legendaries_anchored": int(legend["anchored"]),
		"legendaries_no_anchor": (legend["no_anchor"] as Array).size(),
	}
	return {"enforcing": enforcing, "enforcing_failures": failures, "advisory": advisory, "metrics": metrics}


# --- helpers (pure) ---------------------------------------------------------------

# The land biomes (depth-tier >= 0): WATER/SAND are elevation-driven (tier -1) and never site a dungeon.
static func _land_biomes() -> Array:
	var biomes: Array = []
	for biome in WorldGenAudit.BIOMES:
		if WorldGenAudit.depth_tier(str(biome)) >= 0:
			biomes.append(str(biome))
	return biomes


# Stride-scan the playable disc (manhattan < SITE_SCAN_RADIUS): count centers per land biome whose
# biome matches AND whose representative footprint fits (>=7 of 9 probes land). Bounded by the stride.
static func _site_scan(gen, size: Vector2i) -> Dictionary:
	var counts := {}
	for biome in _land_biomes():
		counts[biome] = 0
	var radius := WorldGenAudit.SITE_SCAN_RADIUS
	var stride := WorldGenAudit.SITE_SCAN_STRIDE
	var y := -(radius - 1)
	while y < radius:
		var span := (radius - 1) - absi(y)
		var x := -span
		while x <= span:
			var center := Vector2i(x, y)
			var biome := str(gen.get_tile_logic(center).get("biome", ""))
			if counts.has(biome) and WorldGenAudit.footprint_fits(gen, center, size):
				counts[biome] = int(counts[biome]) + 1
			x += stride
		y += stride
	return counts


# True when any tile of the footprint rect lies within `radius` manhattan of origin (ring <= radius).
static func _footprint_touches_disc(footprint: Rect2i, radius: int) -> bool:
	for tile in _footprint_tiles(footprint):
		if WorldGenAudit.ring_of(tile) <= radius:
			return true
	return false


# Enumerate every tile of a footprint rect (bounded: footprints are <= 15x11).
static func _footprint_tiles(footprint: Rect2i) -> Array:
	var tiles: Array = []
	var x0 := footprint.position.x
	var y0 := footprint.position.y
	for y in range(y0, y0 + footprint.size.y):
		for x in range(x0, x0 + footprint.size.x):
			tiles.append(Vector2i(x, y))
	return tiles


# Legendary anchor outcomes on the infinite plane (chain frozen at origin): the anchored
# count + the NO_ANCHOR set (the LAVA four, whose affinity biome never generates on origin).
static func _legendary_anchors(seed: int) -> Dictionary:
	var no_anchor: Array = []
	var anchored := 0
	for species in LegendaryPlacement.LEGENDARY_IDS:
		var anchor := LegendaryPlacement.anchor_for(seed, Vector2i.ZERO, str(species))
		if anchor == LegendaryPlacement.NO_ANCHOR:
			no_anchor.append(str(species))
			continue
		anchored += 1
	return {"no_anchor": no_anchor, "anchored": anchored}
