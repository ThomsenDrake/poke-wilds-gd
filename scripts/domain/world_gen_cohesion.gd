extends RefCounted

# World-generation AUDIT — cohesion family. Measures biome COHESION over ONE cached
# Manhattan disc scan: determinism (two same-seed generators agree tile-for-tile),
# ring admission (the depth gradient holds by construction), hostile adjacency, the
# geometric ring-seam, region fragmentation, and the per-ring biome histogram with
# extreme-biome reach. Pure + deterministic: NO rng, NO I/O; every number is a
# function of the live WorldGenerator (already setup(seed) by the caller) plus the
# scan radius. TIER RULE: only structural invariants that HOLD TODAY enforce (red on
# regression) — determinism and ring admission. Every gap that needs a future fix
# (hostile seams, fragmentation, the LAVA-never-generates headline) rides `advisory`
# and never gates. Contract + helpers: world_gen_audit.gd.

const WorldGenAudit := preload("res://scripts/domain/world_gen_audit.gd")

# The admission gradient, mirrored from world_generator._ring_candidates so the
# enforce checks track the same thresholds the generator enforces by construction.
const INNER_ALLOWED := ["WATER", "SAND", "PLAINS", "GRASSLAND"]
const MIDDLE_BANNED := ["DESERT", "SWAMP", "ROCK", "SNOW", "LAVA"]
const OUTER_BANNED := ["SNOW", "LAVA"]
# Admission ring -> control ring (no candidate-set change there) for the seam diff.
const SEAM_CONTROLS := {10: 20, 28: 40, 60: 80}
const CARDINAL := [Vector2i.RIGHT, Vector2i.DOWN] # half the 4-hood; avoids double counting
const ORTHO := [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]
const DIAG := [Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1)]


static func audit(gen, seed: int, scan_radius: int) -> Dictionary:
	var scan := _scan(gen, scan_radius)
	var enforcing := {}
	var enforcing_failures: Array = []
	var advisory: Array = []

	_check_determinism(gen, seed, scan, enforcing, enforcing_failures)
	_check_ring_admission(scan, enforcing, enforcing_failures)
	_tabulate_adjacency(scan, advisory)
	_measure_ring_seam(scan, scan_radius, advisory)
	_measure_regions(scan, advisory)
	_measure_histogram(scan, advisory)

	return {
		"enforcing": enforcing,
		"enforcing_failures": enforcing_failures,
		"advisory": advisory,
		"metrics": {"tiles_scanned": (scan["positions"] as Array).size(), "biomes_present": scan["biomes_present"]},
	}


# One pass over the disc: cache biome / walkable / field-move per tile keyed by
# WorldGenAudit.key(pos). Every metric below reads this cache — no per-metric re-scan.
static func _scan(gen, radius: int) -> Dictionary:
	var positions := WorldGenAudit.disc_positions(radius)
	var biome := {}
	var walk := {}
	var rfm := {}
	var present := {}
	for pos in positions:
		var logic: Dictionary = gen.get_tile_logic(pos)
		var b := str(logic.get("biome", ""))
		var k := WorldGenAudit.key(pos)
		biome[k] = b
		walk[k] = bool(logic.get("walkable", false))
		rfm[k] = str(logic.get("requires_field_move", ""))
		present[b] = true
	var biomes_present: Array = present.keys()
	biomes_present.sort()
	return {"positions": positions, "biome": biome, "walk": walk, "rfm": rfm, "biomes_present": biomes_present}


# ENFORCE: two independently-built, like-wired generators from the same seed must
# agree on biome + walkable + field-move for every disc tile (world_invariants.gd).
static func _check_determinism(gen, seed: int, scan: Dictionary, enforcing: Dictionary, failures: Array) -> void:
	var gen2 = gen.get_script().new()
	gen2.setup(seed)
	gen2.landmark_resolver = gen.landmark_resolver # wiring, not setup state
	var biome: Dictionary = scan["biome"]
	var walk: Dictionary = scan["walk"]
	var rfm: Dictionary = scan["rfm"]
	var mismatches := 0
	for pos in scan["positions"]:
		var b: Dictionary = gen2.get_tile_logic(pos)
		var k := WorldGenAudit.key(pos)
		if str(b.get("biome", "")) != str(biome.get(k, "")) \
				or bool(b.get("walkable", false)) != bool(walk.get(k, false)) \
				or str(b.get("requires_field_move", "")) != str(rfm.get(k, "")):
			mismatches += 1
	enforcing["determinism_mismatches"] = mismatches
	if mismatches > 0:
		failures.append("determinism_mismatch: %d tiles differ between two same-seed generators" % mismatches)


# ENFORCE: the depth-admission gradient — inner safe biomes only, mid hazards kept
# out, far extremes kept out. Holds by construction today (mirrors world_invariants).
static func _check_ring_admission(scan: Dictionary, enforcing: Dictionary, failures: Array) -> void:
	var biome: Dictionary = scan["biome"]
	var violations := 0
	for pos in scan["positions"]:
		var b := str(biome.get(WorldGenAudit.key(pos), ""))
		var ring := WorldGenAudit.ring_of(pos)
		if ring < WorldGenAudit.RING_INNER and not INNER_ALLOWED.has(b):
			violations += 1
		elif ring < WorldGenAudit.RING_MIDDLE and MIDDLE_BANNED.has(b):
			violations += 1
		elif ring < WorldGenAudit.RING_OUTER and OUTER_BANNED.has(b):
			violations += 1
	enforcing["ring_admission_violations"] = violations
	if violations > 0:
		failures.append("ring_admission_violation: %d tiles break the depth-admission gradient" % violations)


# ADVISORY: tabulate unordered unequal adjacent (4-neighbor) biome pairs; count the
# hard-hostile ones the blending fix targets, plus the top-5 most common transitions.
static func _tabulate_adjacency(scan: Dictionary, advisory: Array) -> void:
	var biome: Dictionary = scan["biome"]
	var pair_counts := {}
	var hostile := 0
	for pos in scan["positions"]:
		var a := str(biome.get(WorldGenAudit.key(pos), ""))
		for dir in CARDINAL:
			var nb := str(biome.get(WorldGenAudit.key(pos + dir), ""))
			if a == "" or nb == "" or a == nb:
				continue
			var pk := WorldGenAudit.pair_key(a, nb)
			pair_counts[pk] = int(pair_counts.get(pk, 0)) + 1
			if WorldGenAudit.is_hostile_pair(a, nb):
				hostile += 1
	advisory.append({"kind": "hostile_adjacency_count", "value": hostile,
		"detail": "%d adjacent biome edges are hard-hostile (the blending fix's target)." % hostile})
	advisory.append({"kind": "top_adjacency_pairs", "value": _top_pairs(pair_counts, 5),
		"detail": "Five most common unequal adjacent biome pairs over the disc."})


static func _top_pairs(counts: Dictionary, n: int) -> Dictionary:
	var entries: Array = []
	for pk in counts:
		entries.append([pk, int(counts[pk])])
	entries.sort_custom(func(x, y): return int(x[1]) > int(y[1]))
	var out := {}
	for i in range(mini(n, entries.size())):
		out[entries[i][0]] = entries[i][1]
	return out


# ADVISORY: the geometric quantization seam. At an admission ring the candidate set
# changes, so biome churn ACROSS the contour (radial) spikes relative to ALONG it
# (tangential); subtract a control ring's same quantity to isolate the seam signal.
static func _measure_ring_seam(scan: Dictionary, scan_radius: int, advisory: Array) -> void:
	var result := {}
	for ring in SEAM_CONTROLS:
		var seam_ring := _seam(scan, int(ring), scan_radius)
		var seam_control := _seam(scan, int(SEAM_CONTROLS[ring]), scan_radius)
		result[int(ring)] = snapped(seam_ring - seam_control, 0.001)
	advisory.append({"kind": "ring_seam", "value": result,
		"detail": "Radial-vs-tangential biome churn at each admission ring minus its control; a spike marks the geometric quantization seam."})


# Returns (across change-rate) - (along change-rate) for one contour. On the L1
# diamond no two 4-adjacent tiles share a ring, so radial = orthogonal neighbors
# (ring +/-1) and tangential = diagonal neighbors that stay on the same ring.
static func _seam(scan: Dictionary, ring: int, scan_radius: int) -> float:
	var biome: Dictionary = scan["biome"]
	var across_edges := 0
	var across_changes := 0
	var along_edges := 0
	var along_changes := 0
	for pos in _contour(ring, scan_radius):
		var b := str(biome.get(WorldGenAudit.key(pos), ""))
		if b == "":
			continue
		for dir in ORTHO:
			var nb := str(biome.get(WorldGenAudit.key(pos + dir), ""))
			if nb == "":
				continue
			across_edges += 1
			if nb != b:
				across_changes += 1
		for dir in DIAG:
			if WorldGenAudit.ring_of(pos + dir) != ring:
				continue
			var nb := str(biome.get(WorldGenAudit.key(pos + dir), ""))
			if nb == "":
				continue
			along_edges += 1
			if nb != b:
				along_changes += 1
	var across_rate := float(across_changes) / float(across_edges) if across_edges > 0 else 0.0
	var along_rate := float(along_changes) / float(along_edges) if along_edges > 0 else 0.0
	return across_rate - along_rate


# The L1 contour (all tiles with |x|+|y| == ring) inside the scan disc.
static func _contour(ring: int, scan_radius: int) -> Array:
	var tiles: Array = []
	if ring > scan_radius:
		return tiles
	if ring == 0:
		return [Vector2i.ZERO]
	for y in range(-ring, ring + 1):
		var x := ring - absi(y)
		tiles.append(Vector2i(x, y))
		if x != 0:
			tiles.append(Vector2i(-x, y))
	return tiles


# ADVISORY: flood-fill connected same-biome regions (4-neighbor); count regions and
# specks (region size < SPECK_THRESHOLD) — the fragmentation the blending fix smooths.
static func _measure_regions(scan: Dictionary, advisory: Array) -> void:
	var stats := _flood_regions(scan)
	advisory.append({"kind": "region_count", "value": stats["region_count"],
		"detail": "Connected same-biome regions (4-neighbor) over the disc."})
	advisory.append({"kind": "speck_count", "value": stats["speck_count"],
		"detail": "Regions smaller than %d tiles — salt-and-pepper fragmentation." % WorldGenAudit.SPECK_THRESHOLD})


static func _flood_regions(scan: Dictionary) -> Dictionary:
	var biome: Dictionary = scan["biome"]
	var visited := {}
	var region_count := 0
	var speck_count := 0
	for start in scan["positions"]:
		var sk := WorldGenAudit.key(start)
		if visited.has(sk):
			continue
		var target := str(biome.get(sk, ""))
		region_count += 1
		var size := 0
		var frontier: Array = [start]
		visited[sk] = true
		while not frontier.is_empty():
			var current: Vector2i = frontier.pop_back()
			size += 1
			for dir in ORTHO:
				var next: Vector2i = current + dir
				var nk := WorldGenAudit.key(next)
				if visited.has(nk) or str(biome.get(nk, "")) != target:
					continue
				visited[nk] = true
				frontier.append(next)
		if size < WorldGenAudit.SPECK_THRESHOLD:
			speck_count += 1
	return {"region_count": region_count, "speck_count": speck_count}


# DATA/ADVISORY: per-ring-band biome histogram, plus first-ring + total count for
# each EXTREME biome. LAVA total is expected 0 today — the headline gap, advisory.
static func _measure_histogram(scan: Dictionary, advisory: Array) -> void:
	var biome: Dictionary = scan["biome"]
	var histogram := {}
	var extreme := {}
	for b in WorldGenAudit.EXTREME_BIOMES:
		extreme[b] = {"first_ring": -1, "count": 0}
	for pos in scan["positions"]:
		var b := str(biome.get(WorldGenAudit.key(pos), ""))
		if b == "":
			continue
		var ring := WorldGenAudit.ring_of(pos)
		var band := _ring_band(ring)
		if not histogram.has(band):
			histogram[band] = {}
		(histogram[band] as Dictionary)[b] = int((histogram[band] as Dictionary).get(b, 0)) + 1
		if extreme.has(b):
			var entry: Dictionary = extreme[b]
			entry["count"] = int(entry["count"]) + 1
			if int(entry["first_ring"]) < 0 or ring < int(entry["first_ring"]):
				entry["first_ring"] = ring
	advisory.append({"kind": "ring_histogram", "value": histogram,
		"detail": "Tiles per biome in each ring band (0-9, 10-27, 28-59, 60+)."})
	var lava_count := int((extreme.get("LAVA", {}) as Dictionary).get("count", 0))
	advisory.append({"kind": "extreme_reach", "value": extreme,
		"detail": "First ring + total count for SNOW/LAVA; LAVA count %d => the headline gap (LAVA never generates on origin)." % lava_count})


static func _ring_band(ring: int) -> String:
	if ring < WorldGenAudit.RING_INNER:
		return "0-9"
	if ring < WorldGenAudit.RING_MIDDLE:
		return "10-27"
	if ring < WorldGenAudit.RING_OUTER:
		return "28-59"
	return "60+"
