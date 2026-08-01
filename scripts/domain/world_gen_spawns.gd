extends RefCounted

# World-generation AUDIT harness — spawn family (world_gen_audit.gd is the shared
# contract). Measures the wild-encounter pools biome_encounters.gd actually serves:
# type<->biome coherence, BST<->depth gating, and level-band<->strength. PURE and
# deterministic — NO rng, NO I/O: every number is a function of (catalog, biome
# tables) alone, so the audit is a regression net for the later spawn-fix slices.
# TIER RULE: enforcing_failures hold ONLY the leak invariant that is GREEN today
# (the fallback gates legendaries + EGG); the gaps that need future fixes — the
# full-catalog fallback itself, disjoint-typed fallback members, un-gated BST,
# low-level reach of strong mons — all ride `advisory` and never gate.

const WorldGenAudit := preload("res://scripts/domain/world_gen_audit.gd")
# Class-level tables of the live filter (BIOME_TYPES, the source alias map, the frozen
# legendary/never-encounter sets). Reading them through the preloaded class — not the
# injected instance — keeps every helper callable without a live object while pinning
# the exact same tables the live filter uses.
const BiomeEncounters := preload("res://scripts/domain/biome_encounters.gd")

const TIMES := ["DAY", "NIGHT"]
const LEVEL_MAX_AT_RING_0 := 5 # analytic top of the ring-0 band: clampi(2+0/24,2,80)+3
const _BST_STAT_KEYS := ["hp", "atk", "def", "spe", "sat", "sdf"]


# Public entry. `species` is the catalog species dict (id -> entry); `biome_encounters`
# is a live scripts/domain/biome_encounters.gd instance. Returns the audit result dict:
# {enforcing, enforcing_failures, advisory, metrics}.
static func audit(species: Dictionary, biome_encounters) -> Dictionary:
	var enforcing: Dictionary = {}
	var failures: Array = []
	var advisory: Array = []
	var pool_memo: Dictionary = {}
	var pools_by_biome: Dictionary = {}

	var leak_count := 0
	var day_fallback_biomes: Array = []
	for biome in WorldGenAudit.BIOMES:
		var day_pool: Dictionary = _pool_for(pool_memo, pools_by_biome, species, biome_encounters, biome, "DAY")
		var night_pool: Dictionary = _pool_for(pool_memo, pools_by_biome, species, biome_encounters, biome, "NIGHT")
		if bool(day_pool.get("used_fallback", false)):
			day_fallback_biomes.append(biome)
		for time in TIMES:
			var pool: Dictionary = day_pool if time == "DAY" else night_pool
			for species_id in (pool.get("ids", []) as Array):
				if _is_banned(species_id):
					leak_count += 1
					failures.append("%s/%s: pool contains %s (legendary/egg leak)" % [biome, time, species_id])

	enforcing["pool_leaks"] = leak_count
	enforcing["biomes_with_fallback"] = day_fallback_biomes.size()

	_add_fallback_disjoint(advisory, species, pools_by_biome, day_fallback_biomes)
	_add_bst_depth(advisory, species, biome_encounters, pools_by_biome)
	_add_level_band(advisory, species, biome_encounters, pools_by_biome)

	return {
		"enforcing": enforcing,
		"enforcing_failures": failures,
		"advisory": advisory,
		"metrics": _metrics(species, biome_encounters),
	}


# --- helpers ---

# Base-stat total: sum of the six base_stats (0 for any missing stat or block). BST is
# computed nowhere in the codebase today; this is the audit's first producer of it.
static func bst_of(entry: Dictionary) -> int:
	var total := 0
	var stats: Variant = entry.get("base_stats", {})
	if not (stats is Dictionary):
		return 0
	for stat_key in _BST_STAT_KEYS:
		total += int((stats as Dictionary).get(stat_key, 0))
	return total


# Nearest-rank percentile over an ascending-sorted int array (empty -> 0).
static func _percentile(sorted: Array, fraction: float) -> int:
	if sorted.is_empty():
		return 0
	var idx := clampi(ceili(fraction * float(sorted.size())) - 1, 0, sorted.size() - 1)
	return int(sorted[idx])


static func _types_of(entry: Dictionary) -> Array:
	var result: Array = []
	var types: Variant = entry.get("types", PackedStringArray())
	if types is Array or types is PackedStringArray:
		for type_name in types:
			result.append(str(type_name))
	return result


static func _types_overlap(entry: Dictionary, biome: String) -> bool:
	var biome_types: Variant = BiomeEncounters.BIOME_TYPES.get(biome, [])
	if not (biome_types is Array):
		return false
	for type_name in _types_of(entry):
		if (biome_types as Array).has(type_name):
			return true
	return false


# A species entry's spawn line DIRECTLY sources this biome (verbatim id or through
# SOURCE_BIOME_ALIASES) — mirroring biome_encounters._spawn_biomes_include. True means
# the mon is an authored resident, not a full-catalog-fallback drifter.
static func _has_direct_match(entry: Dictionary, biome: String) -> bool:
	var raw: Variant = entry.get("spawn_biomes", PackedStringArray())
	if not (raw is Array or raw is PackedStringArray):
		return false
	for token in raw:
		if str(BiomeEncounters.SOURCE_BIOME_ALIASES.get(str(token), str(token))) == biome:
			return true
	return false


static func _is_banned(species_id: String) -> bool:
	return BiomeEncounters.LEGENDARY_IDS.has(species_id) or BiomeEncounters.NEVER_ENCOUNTER_IDS.has(species_id)


# Memoized pool fetch: 11 biomes x 2 times, and the fallback/depth passes reuse the DAY
# results — one filter call per (biome, time), cached. Also records each biome's DAY
# pool in pools_by_biome for the downstream advisories.
static func _pool_for(memo: Dictionary, pools_by_biome: Dictionary, species: Dictionary, biome_encounters, biome: String, time: String) -> Dictionary:
	var memo_key := "%s/%s" % [biome, time]
	if memo.has(memo_key):
		return memo[memo_key]
	var pool: Dictionary = biome_encounters.filter_species_ids(species, biome, time)
	memo[memo_key] = pool
	if time == "DAY":
		pools_by_biome[biome] = pool
	return pool


# ADVISORY fallback_disjoint: among the biomes whose DAY pool used the full-catalog
# fallback, the ids that have ZERO type overlap with the biome AND no direct spawn-line
# match — i.e. they entered ONLY via the unguarded fallback with a disjoint type.
static func _add_fallback_disjoint(advisory: Array, species: Dictionary, pools_by_biome: Dictionary, fallback_biomes: Array) -> void:
	if fallback_biomes.is_empty():
		return
	var disjoint: Dictionary = {}
	for biome in fallback_biomes:
		var pool: Dictionary = pools_by_biome.get(biome, {})
		var ids: Array = []
		for species_id in (pool.get("ids", []) as Array):
			var entry: Variant = species.get(species_id, {})
			if not (entry is Dictionary):
				continue
			if not _types_overlap(entry as Dictionary, biome) and not _has_direct_match(entry as Dictionary, biome):
				ids.append(species_id)
		if not ids.is_empty():
			disjoint[biome] = ids
	if disjoint.is_empty():
		return
	advisory.append({
		"kind": "fallback_disjoint",
		"value": disjoint,
		"detail": "%d fallback biome(s) admit mons whose types never overlap the biome and whose spawn line never sources it." % disjoint.size(),
	})


# ADVISORY bst_depth: per depth tier, the BST distribution (min/p10/median/p90/max) of
# its biomes' DAY-pool members, plus every BST_HIGH(540)+ mon in a tier-0 (ring<10)
# biome pool. Flags the missing stats<->depth gating.
static func _add_bst_depth(advisory: Array, species: Dictionary, biome_encounters, pools_by_biome: Dictionary) -> void:
	var tier_bsts: Dictionary = {}
	var high_in_tier0: Array = []
	var seen_high: Dictionary = {}
	for biome in WorldGenAudit.BIOMES:
		var tier := WorldGenAudit.depth_tier(biome)
		if tier < 0: # WATER/SAND are elevation-driven, not depth-tiered
			continue
		var pool: Dictionary = pools_by_biome.get(biome, {})
		for species_id in (pool.get("ids", []) as Array):
			var entry: Variant = species.get(species_id, {})
			if not (entry is Dictionary) or not biome_encounters.is_battle_viable(species_id, entry as Dictionary):
				continue
			var bst := bst_of(entry as Dictionary)
			if not tier_bsts.has(tier):
				tier_bsts[tier] = []
			(tier_bsts[tier] as Array).append(bst)
			if tier == 0 and bst >= WorldGenAudit.BST_HIGH and not seen_high.has(species_id):
				seen_high[species_id] = true
				high_in_tier0.append(species_id)
	var stats: Dictionary = {}
	for tier_key in tier_bsts.keys():
		var values: Array = (tier_bsts[tier_key] as Array).duplicate()
		values.sort()
		stats[tier_key] = {
			"min": _percentile(values, 0.0),
			"p10": _percentile(values, 0.1),
			"median": _percentile(values, 0.5),
			"p90": _percentile(values, 0.9),
			"max": _percentile(values, 1.0),
		}
	high_in_tier0.sort()
	advisory.append({
		"kind": "bst_depth",
		"value": {"tier": stats, "high_in_tier0": high_in_tier0},
		"detail": "%d high-BST (>= %d) mon(s) sit in tier-0 shallow biome pools => no stats<->depth gating today." % [high_in_tier0.size(), WorldGenAudit.BST_HIGH],
	})


# ADVISORY level_band_strength: the analytic ring-0 level band tops out at level
# LEVEL_MAX_AT_RING_0 (=5; encounter_selection.level_from_distance minus its rng jitter
# is clampi(2+d/24,2,80), +3 at most), so any BST_HIGH mon in a tier-0/1 pool is
# reachable at level 2-5. Lists them — encounter level ignores strength today.
static func _add_level_band(advisory: Array, species: Dictionary, biome_encounters, pools_by_biome: Dictionary) -> void:
	var reachable: Array = []
	var seen: Dictionary = {}
	for biome in WorldGenAudit.BIOMES:
		var tier := WorldGenAudit.depth_tier(biome)
		if tier < 0 or tier > 1:
			continue
		var pool: Dictionary = pools_by_biome.get(biome, {})
		for species_id in (pool.get("ids", []) as Array):
			if seen.has(species_id):
				continue
			var entry: Variant = species.get(species_id, {})
			if not (entry is Dictionary) or not biome_encounters.is_battle_viable(species_id, entry as Dictionary):
				continue
			if bst_of(entry as Dictionary) >= WorldGenAudit.BST_HIGH:
				seen[species_id] = true
				reachable.append(species_id)
	reachable.sort()
	advisory.append({
		"kind": "level_band_strength",
		"value": reachable,
		"detail": "%d high-BST mon(s) in tier-0/1 pools are reachable at level 2-%d (ring-0 band) => encounter level ignores strength today." % [reachable.size(), LEVEL_MAX_AT_RING_0],
	})


static func _metrics(species: Dictionary, biome_encounters) -> Dictionary:
	var viable_bsts: Array = []
	for species_id in species.keys():
		var entry: Variant = species.get(species_id, {})
		if entry is Dictionary and biome_encounters.is_battle_viable(str(species_id), entry as Dictionary):
			viable_bsts.append(bst_of(entry as Dictionary))
	viable_bsts.sort()
	var bst_range: Array = [0, 0]
	if not viable_bsts.is_empty():
		bst_range = [int(viable_bsts[0]), int(viable_bsts[viable_bsts.size() - 1])]
	return {
		"species_count": species.size(),
		"biomes_analyzed": WorldGenAudit.BIOMES.size(),
		"bst_range": bst_range,
	}
