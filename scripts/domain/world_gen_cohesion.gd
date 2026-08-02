extends RefCounted

# World-generation AUDIT — cohesion family. Measures biome COHESION over ONE cached
# Manhattan disc scan: determinism (two same-seed generators agree tile-for-tile),
# the biome-distribution contract (every biome generates — the climate model's
# delivering invariant), hostile adjacency, region fragmentation, and the whole-disc
# biome histogram with extreme-biome presence. Pure + deterministic: NO rng, NO I/O;
# every number is a function of the live WorldGenerator (already setup(seed) by the
# caller) plus the scan radius. TIER RULE: only structural invariants that HOLD TODAY
# enforce (red on regression) — determinism and the biome distribution. Every gap
# that needs a future fix (hostile seams, fragmentation) rides `advisory` and never
# gates. Contract + helpers: world_gen_audit.gd.
#
# Infinite-world slice 2: the ring-admission check, the ring-seam measurement, and
# the per-ring histogram bands RETIRED with the radial biome model (biomes are
# climate-field derived, so a single 110-disc reads as ONE climate region — presence
# is measured over a wide stride-sampled window instead, where many regions land).

const WorldGenAudit := preload("res://scripts/domain/world_gen_audit.gd")
const BiomeField := preload("res://scripts/domain/biome_field.gd")

const CARDINAL := [Vector2i.RIGHT, Vector2i.DOWN] # half the 4-hood; avoids double counting
const ORTHO := [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]
# The distribution window: a single 110-disc reads ~one climate region (the fields
# correlate at ~150-250 tiles), so presence is measured over a radius-400 disc at
# stride 4 (20,201 samples spanning ~20 climate regions — the joint LAVA tail lands).
const DISTRIBUTION_RADIUS := 400
const DISTRIBUTION_STRIDE := 4


static func audit(gen, seed: int, scan_radius: int) -> Dictionary:
	var scan := _scan(gen, scan_radius)
	var enforcing := {}
	var enforcing_failures: Array = []
	var advisory: Array = []

	_check_determinism(gen, seed, scan, enforcing, enforcing_failures)
	_check_biome_distribution(gen, enforcing, enforcing_failures)
	_tabulate_adjacency(scan, advisory)
	_measure_regions(scan, advisory)
	_measure_distribution(scan, advisory)

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


# ENFORCE: the climate model's delivering contract — over the wide distribution
# window the ten COMMON biomes generate per-seed (WATER/SAND/ROCK by elevation,
# PLAINS/GRASSLAND/FOREST/SAVANNA/DESERT/SWAMP/SNOW by the field; a threshold or
# frequency edit that kills a common biome reds here). LAVA is the RARE joint tail:
# a cold-climate window legitimately lacks it, so per-seed LAVA absence is NOT a
# failure — the presence contract is the runner's cross-seed window count
# (world_gen_audit_runner; LAVA_WINDOWS_MIN in world_gen_audit.gd), reported here
# as the lava_present metric.
static func _check_biome_distribution(gen, enforcing: Dictionary, failures: Array) -> void:
	var present := {}
	for pos in WorldGenAudit.disc_positions(DISTRIBUTION_RADIUS):
		if pos.x % DISTRIBUTION_STRIDE != 0 or pos.y % DISTRIBUTION_STRIDE != 0:
			continue
		present[str(gen.get_tile_logic(pos).get("biome", ""))] = true
	var missing: Array = []
	for biome in BiomeField.KNOWN_BIOMES:
		if biome == "LAVA":
			continue # the rare joint tail rides the cross-seed contract (header)
		if not present.has(biome):
			missing.append(biome)
	enforcing["biomes_missing"] = missing.size()
	enforcing["lava_present"] = 1 if present.has("LAVA") else 0
	if not missing.is_empty():
		failures.append("biome_distribution: %s missing from a %d-radius stride-%d window (the climate field must generate every common biome)" % [str(missing), DISTRIBUTION_RADIUS, DISTRIBUTION_STRIDE])


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


# DATA/ADVISORY: whole-disc biome histogram (no ring bands — retired with the radial
# model) + extreme-biome presence counts. LAVA is rare-but-nonzero by design (the
# climate joint tail; the retired radial gap); the ENFORCING presence contract rides
# the wide window above — this histogram is the local texture reading.
static func _measure_distribution(scan: Dictionary, advisory: Array) -> void:
	var counts := {}
	for pos in scan["positions"]:
		var b := str(scan["biome"].get(WorldGenAudit.key(pos), ""))
		if b == "":
			continue
		counts[b] = int(counts.get(b, 0)) + 1
	advisory.append({"kind": "biome_distribution", "value": counts,
		"detail": "Tiles per biome over the whole disc (no ring bands — the radial model is retired)."})
	var extreme := {}
	for b in WorldGenAudit.EXTREME_BIOMES:
		extreme[b] = int(counts.get(b, 0))
	advisory.append({"kind": "extreme_presence", "value": extreme,
		"detail": "SNOW/LAVA tile counts over the disc; LAVA %d — rare-but-nonzero under the climate joint tail (the retired radial quantization gap)." % int(counts.get("LAVA", 0))})
