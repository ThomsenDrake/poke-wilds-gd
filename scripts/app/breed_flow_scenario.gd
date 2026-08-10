extends Node

# Breed flow scenario (Phase 5; spec: docs/product-specs/breeding-shinies-drops-fishing.md).
# Earned-material fence ring, compatible EEVEE pair penned on basic ground, seeded cadence
# laying a VISIBLE egg hatched on the step clock into a level-5 child. Ditto / UNBREEDABLE /
# WRONG-GROUP / stone / save ride breed_flow_checks.gd; FLYING / WATER habitat pens ride
# breed_flow_habitat_checks.gd (app split).

const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")
const Phase5 := preload("res://scripts/runtime/phase5_support.gd")
const Sites := preload("res://scripts/runtime/phase5_sites.gd")
const BreedFlowChecks := preload("res://scripts/app/breed_flow_checks.gd")
const BreedFlowHabitatChecks := preload("res://scripts/app/breed_flow_habitat_checks.gd")

const SEED := 2026072601
const PAIR_LEVEL := 30
const EGG_MOVE_ID := "WISH" # EEVEE egg move in both the vendored egg_moves.asm and the generated catalog (CHARM aged out with the PokeAPI canon — catalog-parity `egg-move-churn`); the father passes it
const PEN_SCAN_RADIUS := 160
const LAY_STEP_CAP := 6000
const LAY_BATCH := 60
const HATCH_STEPS := 2688; const DAY_MINUTES := 600 # DEFAULT_STEPS_TO_HATCH (2560) + headroom

var _ctx: Dictionary = {}
var _runner = SmokeScenarioRunner.new()
var _failures: Array = []
var _oks: Dictionary = {}
var _pen_center := Vector2i.ZERO
var _anchor := ""


func run(ctx: Dictionary) -> void:
	_ctx = ctx
	await get_tree().create_timer(0.2).timeout
	var runtime = _runtime()
	runtime.seed_for_smoke(SEED)
	runtime.new_game() # self-contained: the world + spawn derive from the PINNED seed (boot-save dependence was the headless flying-site failure; the double-run lane needs a pure function of (code, seed))
	_world().rebuild(runtime.get_world_seed()) # the view owns its own generator: re-seed it or every far _world() logic read answers from the BOOT world (the _fresh_game precedent)
	_runner.resync_player_tile(_world(), _player(), runtime) # new_game moves the SESSION tile, never the player NODE: without this the pen-site scan starts from the boot save's leftover tile and the lane diverges (the entity-soak hermeticity precedent; the 2026-08-09 double-run red)
	runtime.session.time_of_day_minutes = DAY_MINUTES
	# Spawn is the world origin (open water in the radial seed world): relocate to the nearest BUILDABLE tree pen site so the harvest/pen/habitat witnesses find terrain (siting validated the stand ring walkable, so +3 needs no re-check).
	var tree_site := Sites.find_feature_pen_site(runtime._world_gen, _player().tile_position, 600, "tree")
	if tree_site != Vector2i.ZERO: _runner.teleport_player(_world(), _player(), runtime, tree_site + Vector2i(3, 0))
	var saved_chance: float = _player().encounter_chance; _player().encounter_chance = 0.0
	var party_before: Array = _runner.swap_party(runtime, ["MACHOP", "CALYREX", "RHYPERIOR"], PAIR_LEVEL) # build + cut + dig capability for the resolver witnesses
	_witness_base(runtime)
	if _failures.is_empty():
		_earn_and_grant_materials(runtime); _build_the_pen(runtime)
	if _failures.is_empty():
		_oks["pair_ok"] = _pen_eevee_pair(runtime)
	if _failures.is_empty():
		_oks["egg_ok"] = _await_and_check_egg(runtime)
	if _failures.is_empty():
		_oks["hatch_ok"] = _collect_and_hatch(runtime)
	if _failures.is_empty():
		var checks := BreedFlowChecks.new(); add_child(checks); checks.setup(_ctx, _runner, _failures, _pen_center, _anchor)
		_oks["ditto_ok"] = checks.run_ditto_case(runtime)
		_oks["unbreedable_ok"] = checks.run_unbreedable_case(runtime)
		_oks["wrong_group_ok"] = checks.run_wrong_group_case(runtime)
		var habitat_checks := BreedFlowHabitatChecks.new(); add_child(habitat_checks); habitat_checks.setup(_ctx, _runner, _failures)
		_oks["flying_ok"] = habitat_checks.run_flying_case(runtime); _oks["water_ok"] = habitat_checks.run_water_case(runtime)
		_oks["egg_cap_ok"] = habitat_checks.run_egg_cap_case(runtime)
		_oks["stone_ok"] = checks.run_stone_case(runtime)
		_oks["save_ok"] = checks.run_save_case(runtime)
	if _failures.is_empty():
		var payload: Dictionary = _oks.duplicate(); payload["seed"] = SEED
		runtime.emit_trace("breed_flow_passed", "SmokeScenarios", payload)
	else:
		runtime.emit_trace("breed_flow_failed", "SmokeScenarios", {"failures": _failures, "seed": SEED})
		push_error("BreedFlowScenario failed: %s" % "; ".join(PackedStringArray(_failures)))
		runtime.warn("BreedFlowScenario", "Breed flow failed.", {})
	if _pen_center != Vector2i.ZERO: Sites.demolish_pen(runtime, _pen_center)
	_runner.restore_party(runtime, party_before)
	_player().encounter_chance = saved_chance; _player().input_enabled = true
	runtime.session.repel_steps = 0; runtime.session.time_of_day_minutes = DAY_MINUTES


func _witness_base(runtime) -> void:
	for species_id in ["MACHOP", "CALYREX", "EEVEE", "DITTO", "MAGNEMITE"]:
		if runtime.catalog.get_species(species_id).is_empty(): _failures.append("fixture: %s does not resolve in the catalog" % species_id)
	var problem := Phase5.contract_problem(runtime)
	if not problem.is_empty(): _failures.append(problem)
	if runtime.catalog.get_move(EGG_MOVE_ID).is_empty():
		_failures.append("fixture: move %s does not resolve in the catalog" % EGG_MOVE_ID)
		return
	var egg_moves: Variant = runtime.catalog.get_species("EEVEE").get("egg_moves", [])
	if not ((egg_moves is Array or egg_moves is PackedStringArray) and EGG_MOVE_ID in egg_moves):
		_failures.append("data: EEVEE egg_moves lacks %s (egg_moves.asm unparsed?)" % EGG_MOVE_ID)


# Earn via the real resolver (traces prove the harvest seam) + top up (build_house pattern).
func _earn_and_grant_materials(runtime) -> void:
	if not _failures.is_empty():
		return
	var cursor := _runner.trace_log_line_count()
	for action in ["cut", "cut", "cut", "cut", "cut", "cut", "dig", "dig", "dig", "dig", "dig", "dig"]:
		var target: Dictionary = _runner.find_harvest_target(_world(), _player().tile_position, 40, action)
		if not target.is_empty():
			runtime.harvest_tile(target["tile"])
	_ensure(_runner.trace_log_has_since("field_move_used", cursor, {"move_id": "cut", "yield": "log"}), "harvest: no field_move_used{cut,log} trace")
	_ensure(_runner.trace_log_has_since("field_move_used", cursor, {"move_id": "dig"}), "harvest: no field_move_used{dig} trace")
	Sites.grant_pen_materials(runtime)
	runtime.session.add_item("hard_stone", 64) # desert-band fence rings cost the hard_stone SHELL, which grant_pen_materials never provides (the save_stability precedent)


func _build_the_pen(runtime) -> void:
	if not _failures.is_empty():
		return
	_pen_center = Sites.find_pen_site(_world(), _player().tile_position, PEN_SCAN_RADIUS)
	if _pen_center == Vector2i.ZERO:
		_failures.append("site: no grass-free placeable 5x5 within %d rings" % PEN_SCAN_RADIUS)
		return
	var built: Dictionary = Sites.build_pen(runtime, _pen_center)
	if not bool(built.get("ok", false)):
		_failures.append("pen: %s" % str(built.get("reason", "")))
		return
	Phase5.invalidate_pen_cache(runtime)
	_anchor = Phase5.pen_key_for(runtime, _pen_center)
	if _anchor.is_empty():
		_failures.append("pen: the breeding runtime detects no pen at the fenced ring")


# Deterministic EEVEE pair (Ditto held for checks); father gets the egg move.
func _pen_eevee_pair(runtime) -> bool:
	var pair: Dictionary = Phase5.gendered_instances(runtime, "EEVEE", PAIR_LEVEL, ["female", "male"])
	if pair.size() != 2:
		return _ensure(false, "pair: no male+female EEVEE within 128 creations")
	var ditto: Dictionary = runtime.pokemon_rules.create_pokemon_instance(runtime.catalog.get_species("DITTO"), PAIR_LEVEL, Callable(runtime.catalog, "get_move"), runtime._rng)
	var father: Dictionary = pair["male"]
	father["moves"] = runtime.pokemon_rules.build_move_set([EGG_MOVE_ID], Callable(runtime.catalog, "get_move"))
	runtime.session.party = [runtime.session.party[0], runtime.session.party[1], pair["female"], father, ditto]
	_runner.teleport_player(_world(), _player(), runtime, _pen_center)
	for want_gender in ["female", "male"]:
		var index := _party_eevee_index(runtime, want_gender)
		if index < 0:
			return _ensure(false, "deposit: no %s EEVEE in the party" % want_gender)
		var result: Dictionary = Phase5.pasture_deposit(runtime, index)
		if not bool(result.get("ok", false)):
			return _ensure(false, "deposit: %s EEVEE refused (%s)" % [want_gender, str(result.get("reason", ""))])
	return _ensure(Phase5.poke_pasture_happiness(runtime, _anchor, 255), "deposit: happiness poke found no penned mons under anchor %s" % _anchor)


func _await_and_check_egg(runtime) -> bool:
	var cursor := _runner.trace_log_line_count()
	var egg: Dictionary = Phase5.wait_for_pen_egg(runtime, _anchor, LAY_STEP_CAP, LAY_BATCH)
	if egg.is_empty():
		return _ensure(false, "lay: no egg in the pen within %d steps" % LAY_STEP_CAP)
	if not _runner.trace_log_has_since("egg_laid", cursor):
		return _ensure(false, "lay: no egg_laid trace")
	var top: Dictionary = egg.get("egg", {})
	var payload: Dictionary = top.get("egg", {})
	var ok := _ensure(str(payload.get("species_id", "")) == "EEVEE", "egg: child species %s != EEVEE (mother's species rule)" % str(payload.get("species_id", "")))
	ok = _ensure(["male", "female"].has(str(payload.get("gender", ""))), "egg: gender %s not visible pre-hatch" % str(payload.get("gender", ""))) and ok
	ok = _ensure((payload.get("moves", []) as Array).has(EGG_MOVE_ID), "egg: father's egg move %s not inherited" % EGG_MOVE_ID) and ok
	ok = _ensure(top.get("is_shiny", null) != null and payload.get("is_shiny", null) != null, "egg: shiny status not visible pre-hatch") and ok
	return _ensure(bool(top.get("is_shiny", false)) == bool(payload.get("is_shiny", false)), "egg: top-level and payload shiny flags disagree") and ok


# Fence-Z pickup, the pair withdrawn (a carried egg can never be dropped, so it
# hatches alone in the party — no surplus egg pile), then the step clock: the
# egg_hatched trace + the child (level 5, the egg move, the pre-hatch shiny
# flag). Leaves the pen empty for the checks groups.
func _collect_and_hatch(runtime) -> bool:
	var spot: Dictionary = Sites.pen_stand_spot(_world(), _pen_center)
	if spot.is_empty():
		return _ensure(false, "hatch: no stand spot beside the pen")
	var egg_shiny := bool(_last_egg_top(runtime).get("is_shiny", false))
	var pickup: Dictionary = Phase5.pasture_interact(runtime, spot["stand"], spot["faced"])
	if not bool(pickup.get("ok", false)):
		return _ensure(false, "hatch: egg pickup refused (%s)" % str(pickup.get("reason", "")))
	if not _party_has_egg(runtime):
		return _ensure(false, "hatch: the taken egg is not in the party")
	for _i in range(2): # no ground eggs remain, so interact withdraws the pair
		Phase5.pasture_interact(runtime, spot["stand"], spot["faced"])
	var cursor := _runner.trace_log_line_count()
	Phase5.pen_tick(runtime, HATCH_STEPS)
	if not _runner.trace_log_has_since("egg_hatched", cursor):
		return _ensure(false, "hatch: no egg_hatched trace within the step budget")
	if _party_has_egg(runtime):
		return _ensure(false, "hatch: an egg still rides the party after hatching")
	var child := _party_species(runtime, "EEVEE")
	var ok := _ensure(not child.is_empty(), "hatch: no EEVEE child in the party")
	ok = _ensure(int(child.get("level", 0)) == 5, "hatch: child level %d != 5" % int(child.get("level", 0))) and ok
	ok = _ensure(bool(child.get("is_shiny", false)) == egg_shiny, "hatch: shiny flag did not survive the hatch") and ok
	var move_ids: Array = []
	for move in child.get("moves", []):
		move_ids.append(str((move as Dictionary).get("move_id", "")))
	return _ensure(move_ids.has(EGG_MOVE_ID), "hatch: the hatched child lost the egg move %s" % EGG_MOVE_ID) and ok


func _last_egg_top(runtime) -> Dictionary:
	var egg: Dictionary = Phase5.first_pen_egg(runtime, _anchor)
	return egg.get("egg", {}) if not egg.is_empty() else {}

func _party_eevee_index(runtime, want_gender: String) -> int:
	for i in range(runtime.session.party.size()):
		var mon: Dictionary = runtime.session.party[i]
		if str(mon.get("species_id", "")) == "EEVEE" and str(mon.get("gender", "")) == want_gender: return i
	return -1


func _party_has_egg(runtime) -> bool:
	for mon in runtime.session.party:
		if mon is Dictionary and bool((mon as Dictionary).get("is_egg", false)): return true
	return false


func _party_species(runtime, species_id: String) -> Dictionary:
	for mon in runtime.session.party:
		if mon is Dictionary and str((mon as Dictionary).get("species_id", "")) == species_id and not bool((mon as Dictionary).get("is_egg", false)): return mon
	return {}


func _ensure(ok: bool, label: String) -> bool:
	if not ok: _failures.append(label)
	return ok


func _world() -> Node: return _ctx["world"]
func _player() -> Node: return _ctx["player"]
func _runtime() -> Node: return _ctx["runtime"]
