extends RefCounted

# World-generation AUDIT family — DUNGEONS (spec: world-depth.md § Landmarks /
# § Legendaries; the successor infinite-world.md lands in slice 5). Pure measurement of biome SITE availability, spawn-disc
# exclusion and spawn/landmark reachability. NO rng, NO I/O: a pure deterministic function
# of a live WorldGenerator `gen` (setup(seed)) + the int `seed` (chain frozen at origin —
# the seamless infinite plane retired chaining).
#
# TIER RULE: only structural invariants that HOLD TODAY ride `enforcing_failures` (red on
# regression): the spawn flood reaching a minimum region. Every gap that needs a FUTURE fix
# rides `advisory` and NEVER gates: spawn-disc intrusion and the gen-time landmark
# reachability gate (spec §19(c), unimplemented). (Infinite-world slice 2: LAVA now
# GENERATES under the climate field, so the LAVA-site and legendary NO_ANCHOR gaps
# closed — both stay measured as advisories so a threshold regression re-opens them LOUDLY.)

const WorldGenAudit := preload("res://scripts/domain/world_gen_audit.gd")
const ContentScatter := preload("res://scripts/domain/content_scatter.gd") # the chunk rolls (slice 3)
const LandmarkScatter := preload("res://scripts/domain/landmark_scatter.gd") # the scattered-instance derivation (slice 3)
const Landmarks := preload("res://scripts/domain/landmarks.gd")
const LegendaryPlacement := preload("res://scripts/domain/legendary_placement.gd")


# --- public entry -----------------------------------------------------------------
static func audit(gen, seed: int) -> Dictionary:
	var enforcing: Dictionary = {}
	var failures: Array = []
	var advisory: Array = []

	# (1) ADVISORY site availability: stride-scan the audit window for a representative footprint
	# (RUINS_SIZE) per land biome. LAVA generates under the climate field (slice 2), so the
	# LAVA-site count is now expected nonzero-but-rare; a zero count re-flags the gap LOUDLY.
	var site_size: Vector2i = Landmarks.RUINS_SIZE
	var sites := _site_scan(gen, site_size)
	advisory.append({"kind": "site_availability", "value": sites.duplicate(),
		"detail": "Audit-window centers (stride %d) whose biome fits a %dx%d dungeon footprint (conservative: ROCK counts rock props as non-land, so ROCK is a lower bound — see WorldGenAudit.is_land)." % [WorldGenAudit.SITE_SCAN_STRIDE, site_size.x, site_size.y]})
	if int(sites.get("LAVA", 0)) == 0:
		advisory.append({"kind": "lava_site_gap", "value": 0,
			"detail": "zero LAVA-dungeon sites in the window — the climate field should make LAVA generate (a threshold/frequency regression re-opened the retired radial gap)."})

	# Landmarks placed in this world (all three host; chain frozen at origin).
	var landmarks := Landmarks.landmarks_in_world(seed, Vector2i.ZERO)

	# (2) ADVISORY legendary anchors: species whose reach box lacks an affinity pocket
	# resolve NO_ANCHOR (under the climate field the SNOW three always resolve and the
	# LAVA four resolve on most seeds; a nonempty list flags an anchor-scan regression).
	var legend := _legendary_anchors(seed)
	advisory.append({"kind": "legendary_no_anchor", "value": legend["no_anchor"],
		"detail": "Legendary species resolving NO_ANCHOR on this seed (the reach box lacks an affinity pocket; rare under the climate field)."})

	# (1b) ADVISORY content density (infinite-world slice 3): the chunk-hash scattering,
	# measured over the chunks whose centers sit BEYOND the origin core out to ring ~512 —
	# scattered landmark instances, legendary lairs (per affinity biome), and dungeon-site
	# rolls (present + footprint-fitting). The regression net for the future dungeon slice.
	advisory.append({"kind": "content_density", "value": _content_density(gen, seed),
		"detail": "Scattered landmarks / legendary lairs / dungeon sites across the beyond-core chunk sample (the infinite plane's content rates)."})

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
		var fp: Rect2i = landmark.get("footprint", Rect2i())
		var ikey := ContentScatter.instance_key(str(landmark.get("landmark_id", "")), fp.position + fp.size / 2)
		reachability[ikey] = "not_verified" # per-instance key (slice 3: repeating ids never collapse)
	advisory.append({"kind": "landmark_reachability", "value": reachability,
		"detail": "gen-time reachability gate is unimplemented (spec §19(c)); footprint reachability from spawn is not verified."})

	var metrics := {
		"landmarks_placed": landmarks.size(),
		"legendaries_anchored": int(legend["anchored"]),
		"legendaries_no_anchor": (legend["no_anchor"] as Array).size(),
	}
	return {"enforcing": enforcing, "enforcing_failures": failures, "advisory": advisory, "metrics": metrics}


# --- helpers (pure) ---------------------------------------------------------------

# The beyond-core chunk sample for the density metric: chunk centers with Manhattan ring in
# (ORIGIN_CORE_RADIUS, 512] — bounded, never the plane.
static func _content_density(gen, seed: int) -> Dictionary:
	var landmarks_found: Array = []
	var lairs := 0
	var sites_present := 0
	var sites_fit := 0
	var chunks_sampled := 0
	for cy in range(-8, 9):
		for cx in range(-8, 9):
			var chunk := Vector2i(cx, cy)
			var ring := ContentScatter.ring_of(ContentScatter.chunk_center(chunk))
			if ring <= ContentScatter.ORIGIN_CORE_RADIUS or ring > 512:
				continue
			chunks_sampled += 1
			var instance := LandmarkScatter.instance_for_chunk(seed, chunk)
			if not instance.is_empty():
				landmarks_found.append(str(instance.get("instance_key", "")))
			if ContentScatter.dungeon_site_present(seed, chunk):
				sites_present += 1
				if WorldGenAudit.footprint_fits(gen, ContentScatter.dungeon_site_center(seed, chunk), Landmarks.RUINS_SIZE):
					sites_fit += 1
			for species_id in LegendaryPlacement.LEGENDARY_IDS:
				if LegendaryPlacement.lair_for_chunk(seed, chunk, str(species_id)) != LegendaryPlacement.NO_ANCHOR:
					lairs += 1
	return {"chunks": chunks_sampled, "landmarks": landmarks_found.size(), "landmark_keys": landmarks_found,
		"lairs": lairs, "dungeon_sites": sites_present, "dungeon_sites_fit": sites_fit}


# The land biomes: WATER/SAND are the elevation bands and never site a dungeon.
static func _land_biomes() -> Array:
	return WorldGenAudit.LAND_BIOMES.duplicate()


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
# count + the NO_ANCHOR set (a species resolves NO_ANCHOR when its reach box lacks an
# affinity pocket — the SNOW three always anchor; the LAVA four anchor on most seeds).
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
