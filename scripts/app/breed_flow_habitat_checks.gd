extends Node

# The FLYING / WATER habitat-pen groups of breed_flow (the Major-1 proof; spec:
# docs/product-specs/breeding-shinies-drops-fishing.md). Real PokeWilds pens are
# built AROUND a tree/pond: the interior flood excludes the solid/unwalkable
# feature tile, but the ONE shared ring scan (HabitatDrops.pen_habitat_tags) the
# unified lay gate rides catches it — so a FLYING pair (PIDGEY, needs "tree") or
# a WATER pair (MAGIKARP, needs "deep_water") lays where the OLD interior-only
# scan never saw the tag. Water also carries a domain-layer proof (synthesized
# tile logics through the SAME scan + types_satisfied) so the gate stays proven
# when the seeded world offers no pond pen site — that runtime case then skips
# NAMED ("skipped_no_water_site"), never silent. New cases ride the shared _rng
# in fixed order, so the seeded stream stays byte-stable across double-runs.

const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")
const Phase5 := preload("res://scripts/runtime/phase5_support.gd")
const Sites := preload("res://scripts/runtime/phase5_sites.gd")

const PAIR_LEVEL := 30
const SITE_SCAN_RADIUS := 160
const LAY_STEP_CAP := 6000
const LAY_BATCH := 60

var _ctx: Dictionary = {}
var _runner = SmokeScenarioRunner.new()
var _failures: Array = []


func setup(ctx: Dictionary, runner: SmokeScenarioRunner, failures: Array) -> void:
	_ctx = ctx
	_runner = runner
	_failures = failures


# PIDGEY (NORMAL/FLYING) pair in a pen built around a tree prop: the ring scan
# yields "tree", the unified gate passes, an egg lands.
func run_flying_case(runtime) -> bool:
	if not _failures.is_empty():
		return false
	var center := Sites.find_feature_pen_site(_world(), _player().tile_position, SITE_SCAN_RADIUS, "tree")
	if center == Vector2i.ZERO:
		return _ensure(false, "flying: no tree-centered pen site within %d rings" % SITE_SCAN_RADIUS)
	return _pen_pair_case(runtime, center, "PIDGEY", "flying")


# MAGIKARP (WATER/WATER) pair in a pen built around a pond tile — the runtime
# proof when the seeded world offers a site, ALWAYS plus the domain proof.
func run_water_case(runtime) -> Variant:
	if not _failures.is_empty():
		return false
	var domain_ok := _domain_water_proof(runtime)
	var center := Sites.find_feature_pen_site(_world(), _player().tile_position, SITE_SCAN_RADIUS, "water")
	if center == Vector2i.ZERO:
		runtime.warn("BreedFlowHabitatChecks", "No pond pen site in the seeded world; water rode the domain proof only.", {"site": "water"})
		return "skipped_no_water_site" if domain_ok else false
	return _pen_pair_case(runtime, center, "MAGIKARP", "water") and domain_ok


# Build a pen around `center` (a solid/unwalkable feature tile; the flood keeps
# the 8 walkable neighbors), pen a happy female+male pair, and ride the species-
# tagged egg_laid trace — then empty the pen + demolish, leaving no trace.
func _pen_pair_case(runtime, center: Vector2i, species_id: String, label: String) -> bool:
	Sites.grant_pen_materials(runtime) # drain-then-grant an exact ring (the main pen spent the earlier grant)
	var built: Dictionary = Sites.build_pen(runtime, center)
	if not bool(built.get("ok", false)):
		return _ensure(false, "%s: pen build refused (%s)" % [label, str(built.get("reason", ""))])
	Phase5.invalidate_pen_cache(runtime)
	# Query an interior NEIGHBOR (the solid feature center is never in the flood).
	var anchor := Phase5.pen_key_for(runtime, center + Vector2i.RIGHT)
	if anchor.is_empty():
		return _ensure(false, "%s: the breeding runtime detects no pen around the feature tile" % label)
	var pair: Dictionary = Phase5.gendered_instances(runtime, species_id, PAIR_LEVEL, ["female", "male"])
	if pair.size() != 2:
		return _ensure(false, "%s: no male+female %s within 128 creations" % [label, species_id])
	runtime.session.party = [runtime.session.party[0], runtime.session.party[1], pair["female"], pair["male"]]
	_runner.teleport_player(_world(), _player(), runtime, center) # solid center; the interior edge tiles lie one step out
	for _i in range(2):
		var result: Dictionary = Phase5.pasture_deposit(runtime, 2)
		if not bool(result.get("ok", false)):
			return _ensure(false, "%s: %s deposit refused (%s)" % [label, species_id, str(result.get("reason", ""))])
	if not Phase5.poke_pasture_happiness(runtime, anchor, 255):
		return _ensure(false, "%s: happiness poke found no penned mons" % label)
	var cursor := _runner.trace_log_line_count()
	var egg: Dictionary = Phase5.wait_for_pen_egg(runtime, anchor, LAY_STEP_CAP, LAY_BATCH)
	var ok := _ensure(not egg.is_empty() and _runner.trace_log_has_since("egg_laid", cursor, {"species_id": species_id}),
		"%s: no %s egg_laid within %d steps (the ring-scan gate)" % [label, species_id, LAY_STEP_CAP])
	var spot: Dictionary = Sites.pen_stand_spot(_world(), center)
	if not spot.is_empty():
		for _i in range(3): # the ground egg (if any) picks up first, then the pair
			Phase5.pasture_interact(runtime, spot["stand"], spot["faced"])
	Sites.demolish_pen(runtime, center)
	Phase5.invalidate_pen_cache(runtime)
	if not spot.is_empty(): # never strand the player on the solid feature tile
		_runner.teleport_player(_world(), _player(), runtime, spot["stand"])
	return ok


# The gate proven at the domain layer with synthesized tile logics: a pond tile
# (WATER, unwalkable) one step inside the interior -> "deep_water" via the SHARED
# scan -> MAGIKARP satisfied; the identical interior with NO pond tile is NOT
# satisfied (the control that keeps the proof from going vacuous). No rng.
func _domain_water_proof(runtime) -> bool:
	var domain = Phase5.habitat_drops_domain(runtime)
	if domain == null:
		return _ensure(false, "water(domain): the habitat_drops domain module is missing")
	var interior: Array = []
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			if dx != 0 or dy != 0:
				interior.append(Vector2i(dx, dy))
	var wet_logic := func(tile: Vector2i) -> Dictionary:
		return {"biome": "WATER", "walkable": false} if tile == Vector2i.ZERO else {"biome": "PLAINS", "walkable": true}
	var dry_logic := func(_tile: Vector2i) -> Dictionary:
		return {"biome": "PLAINS", "walkable": true}
	var types := PackedStringArray(["WATER", "WATER"])
	var wet_tags: Dictionary = _tags(domain.call("pen_habitat_tags", interior, wet_logic))
	var dry_tags: Dictionary = _tags(domain.call("pen_habitat_tags", interior, dry_logic))
	var ok := _ensure(bool(wet_tags.get("deep_water", false)), "water(domain): the ring scan missed a pond tile one step inside the interior")
	ok = _ensure(bool(domain.call("types_satisfied", types, "MAGIKARP", wet_tags)), "water(domain): MAGIKARP unsatisfied with deep_water present") and ok
	return _ensure(not bool(domain.call("types_satisfied", types, "MAGIKARP", dry_tags)), "water(domain): MAGIKARP satisfied with NO water tile (vacuous proof)") and ok


func _tags(value: Variant) -> Dictionary:
	return value if value is Dictionary else {}


func _ensure(ok: bool, label: String) -> bool:
	if not ok:
		_failures.append(label)
	return ok


func _world() -> Node: return _ctx["world"]
func _player() -> Node: return _ctx["player"]
