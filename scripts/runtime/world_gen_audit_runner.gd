extends RefCounted

# World-gen AUDIT runner (runtime facade; spec: bootstrap-and-overworld.md). Builds a FRESH
# WorldGenerator per audit seed — never touches the live _world_gen or the shared _rng stream;
# the audit consumes NO rng, so its findings are a pure function of (code, catalog, seeds) and
# the scenario is deterministic by construction (NOT a double-run consumer). Folds the three
# domain families (world_gen_cohesion / world_gen_spawns / world_gen_dungeons) into ONE
# WorldGenAudit findings dict. Re-exposes the domain consts an app caller needs (app may not
# preload domain — check_architecture — so it reaches them through this runtime module).

const WorldGenerator := preload("res://scripts/domain/world_generator.gd")
const WorldGenAudit := preload("res://scripts/domain/world_gen_audit.gd")
const WorldGenCohesion := preload("res://scripts/domain/world_gen_cohesion.gd")
const WorldGenSpawns := preload("res://scripts/domain/world_gen_spawns.gd")
const WorldGenDungeons := preload("res://scripts/domain/world_gen_dungeons.gd")
# Re-exposed domain statics (the app reaches these here, never via a direct domain preload).
const Landmarks := preload("res://scripts/domain/landmarks.gd")
const LegendaryPlacement := preload("res://scripts/domain/legendary_placement.gd")


static func run_audit(seeds: Array, species: Dictionary, biome_encounters) -> Dictionary:
	var findings := WorldGenAudit.new_findings(seeds, WorldGenAudit.SCAN_RADIUS)
	# Seed-independent: spawn coherence (catalog + biome tables only), folded once.
	WorldGenAudit.fold(findings, "spawns", WorldGenSpawns.audit(species, biome_encounters))
	var tiles_checked := 0
	var lava_windows := 0
	var agg := {"cohesion": {}, "dungeons": {}} # kind -> de-duplicated advisory across seeds
	for seed_value in seeds:
		var seed_int := int(seed_value)
		var gen = WorldGenerator.new()
		gen.setup(seed_int)
		var per_seed := [["cohesion", WorldGenCohesion.audit(gen, seed_int, WorldGenAudit.SCAN_RADIUS)],
			["dungeons", WorldGenDungeons.audit(gen, seed_int)]] # chain frozen at origin (seamless plane)
		for entry in per_seed:
			var goal := str(entry[0])
			var result: Dictionary = entry[1]
			_merge_goal_bucket(findings["goals"][goal], result) # worst-case across seeds (NOT last-seed-wins)
			for failure in result.get("enforcing_failures", []):
				findings["enforcing_failures"].append("[%s] seed %d: %s" % [goal, seed_int, str(failure)])
			_merge_advisory(agg[goal], result.get("advisory", []), seed_int)
			if goal == "cohesion":
				tiles_checked += int(result.get("metrics", {}).get("tiles_scanned", 0))
				lava_windows += int(result.get("enforcing", {}).get("lava_present", 0))
	for goal in agg.keys():
		for kind in (agg[goal] as Dictionary).keys():
			var item: Dictionary = (agg[goal] as Dictionary)[kind]
			item["goal"] = goal
			findings["advisory_findings"].append(item)
			findings["goals"][goal]["advisory"][kind] = item.get("value", null)
	# Cross-seed LAVA presence (ENFORCING): the rare joint tail must appear in most
	# windows — a single cold-climate window may lack it, a threshold/frequency
	# regression drops MANY (world_gen_cohesion.gd's per-seed contract covers the rest).
	findings["goals"]["cohesion"]["enforcing"]["lava_windows"] = lava_windows
	if lava_windows < WorldGenAudit.LAVA_WINDOWS_MIN:
		findings["enforcing_failures"].append("[cohesion] climate_distribution: LAVA present in %d of %d seed windows (< %d — the joint-tail climate regressed; rare LAVA must still appear in most windows)" % [lava_windows, seeds.size(), WorldGenAudit.LAVA_WINDOWS_MIN])
	return WorldGenAudit.finalize(findings, tiles_checked)


# Merge a seed's enforcing/metrics into the goal bucket as the WORST case across all seeds
# (max for scalar counts, union for arrays) — so the bucket reflects every seed, NOT just the
# last one (a plain overwrite dropped 8 of 9 seeds and contradicted the per-seed advisories).
static func _merge_goal_bucket(bucket: Dictionary, result: Dictionary) -> void:
	var enforcing: Dictionary = bucket["enforcing"]
	for k in result.get("enforcing", {}):
		enforcing[k] = _worst(enforcing.get(k, null), (result["enforcing"] as Dictionary)[k])
	var metrics: Dictionary = bucket["metrics"]
	for k in result.get("metrics", {}):
		metrics[k] = _worst(metrics.get(k, null), (result["metrics"] as Dictionary)[k])


static func _worst(cur: Variant, new: Variant) -> Variant:
	if cur == null:
		return new
	if (cur is int or cur is float) and (new is int or new is float):
		return maxi(int(cur), int(new)) if (cur is int and new is int) else maxf(float(cur), float(new))
	if cur is Array and new is Array:
		var union: Array = cur.duplicate()
		for item in new:
			if not union.has(item):
				union.append(item)
		return union
	return new


# De-duplicate a per-seed advisory by kind: `seeds` lists every seed the finding OCCURRED on;
# numeric values fold to the WORST (max); dict/array values keep the FIRST seed's value and
# `value_seed` names which seed the shown value is from (representative — the per-seed detail
# rides the JSON artifact), so a dict-valued finding never masquerades as an all-seed aggregate.
static func _merge_advisory(agg: Dictionary, advisories: Array, seed_value: int) -> void:
	for item in advisories:
		var kind := str(item.get("kind", "finding"))
		if not agg.has(kind):
			var entry: Dictionary = item.duplicate(true)
			entry["seeds"] = [seed_value]
			entry["value_seed"] = seed_value
			agg[kind] = entry
			continue
		var existing: Dictionary = agg[kind]
		(existing["seeds"] as Array).append(seed_value)
		var cur: Variant = existing.get("value", null)
		var new: Variant = item.get("value", null)
		if (cur is int or cur is float) and (new is int or new is float) and float(new) > float(cur):
			existing["value"] = maxi(int(cur), int(new)) if (cur is int and new is int) else maxf(float(cur), float(new))
			existing["value_seed"] = seed_value
