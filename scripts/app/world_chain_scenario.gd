extends Node

# World chain scenario (Phase 7 Build 3; spec: docs/product-specs/world-depth.md
# § World chaining + § Save v5, § Smoke validation). FIXED seed 2026072913 (spec
# § Pinned constants; seed_for_smoke BEFORE new_game — the save_stability precedent:
# exactly one root_seed draw, or the double-run lane reds on world_chained{world_seed}).
# The faithful loop (fresh-faq.md:182-188): surf PAST the WORLD_RADIUS edge into
# (0,-1), surf back the same direction; Teleport CANNOT cross worlds but beacons
# build close to the edge. PROOFS: (1) cross OUT + BACK on the fixed seed -> both
# worlds' entity-set + tile-logic fingerprint re-derive BYTE-IDENTICALLY across the
# IN-SCENARIO double run (re-pinned seed, the rng_joint_pin precedent); (2) the
# pure-hash witness world_seed == world_seed_for(root, (0,-1)); (3) the CONTROL —
# N generate_wild_encounter draws with landmark scope INERT re-pin the identical
# sequence (the shared _rng is provably unperturbed by the swap); (4) per-world
# override persistence — a built fence + campsite SURVIVE crossing + return + save
# (NOT erased nor reset, :184); (5) the legendary RE-STAMP witnessed — the chained
# world ships the re-derived stationary set (REGICE on its SNOW ring), neither
# origin-stale nor absent; (6) landmark-state INDEPENDENCE — solving the chained
# Mansion leaves origin's locked (each world's state rides the frozen seam); (7) the
# beacon deltas — edge-band registration fires beacon_placed, use_teleport refuses
# edge_suppressed AT the edge, the selector warps inland, a cross-world target
# refuses; (8) the v5 chained-world save round-trip. The crossing sequence + the
# proofs ride world_chain_checks.gd + world_chain_persist_checks.gd (the two-part
# app-budget split — world_depth_checks.gd is FULL). Joins the double-run lane (the
# NINTH consumer; self-pinned — stamping + anchors are pure _mix, NO rng). miss-002:
# symmetric markers; a red NAMES its cause.

const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")
const WorldChainChecks := preload("res://scripts/app/world_chain_checks.gd")
const WorldChainPersistChecks := preload("res://scripts/app/world_chain_persist_checks.gd")
const WorldChainCrossChecks := preload("res://scripts/app/world_chain_cross_checks.gd") # R8: the cross-method duality (deposit/fly/second-cardinal/fly-suppression), extracted at the app 220 wall
const FieldMovesParty := preload("res://scripts/runtime/field_moves_party.gd")

const SEED := 2026072913
const DAY_MINUTES := 600 # DAY pools for the control draws (nocturnal ghosts never perturb them)

var _ctx: Dictionary = {}
var _runner = SmokeScenarioRunner.new()
var _failures: Array = []
var _oks: Dictionary = {}
var _checks = null
var _persist = null
var _crossm = null


func run(ctx: Dictionary) -> void:
	_ctx = ctx
	await get_tree().create_timer(0.2).timeout
	var runtime = _runtime()
	var saved_chance: float = _player().encounter_chance; _player().encounter_chance = 0.0 # every crossing rides try_cross_edge directly, never a step trigger
	var party_before: Array = FieldMovesParty.swap_in(runtime) # Surf (Rhyperior) + Fly (Charizard) + Teleport (Calyrex) — the canonical all-field-moves fixture
	_checks = WorldChainChecks.new(); add_child(_checks); _checks.setup(_ctx, _runner, _failures)
	_persist = WorldChainPersistChecks.new(); add_child(_persist); _persist.setup(_ctx, _runner, _failures, _checks)
	_crossm = WorldChainCrossChecks.new(); add_child(_crossm); _crossm.setup(_ctx, _runner, _failures, _checks)
	_ensure(FieldMovesParty.verify(runtime).is_empty(), "party: the all-field-moves fixture failed verification (%s)" % str(FieldMovesParty.verify(runtime)))
	FieldMovesParty.restore(runtime, party_before) # the witness is done: each _script half re-swaps AFTER new_game (its party.clear would wipe a pre-script swap)
	var cases := {}
	if _failures.is_empty():
		var run_a: Dictionary = _script(runtime)
		var run_b: Dictionary = _script(runtime) # the IN-SCENARIO double run: re-pinned seed, byte-identical worlds
		cases = run_a.get("cases", {}) if run_a.get("cases", {}) is Dictionary else {}
		var fp_a: Dictionary = run_a.get("fp", {}); var fp_b: Dictionary = run_b.get("fp", {})
		var fp_ok: bool = not fp_a.is_empty() and fp_a == fp_b
		if not fp_ok:
			_failures.append("derive: the in-scenario double-run fingerprint diverged (run A != run B — both worlds must re-derive byte-identically; A keys %s, B keys %s)" % [str(fp_a.keys()), str(fp_b.keys())])
		var derive_ok: bool = fp_ok and bool(_checks.derived_witness_ok)
		_ensure(derive_ok or not fp_ok, "derive: the pure-hash witness world_seed == world_seed_for(root, (0,-1)) broke")
		_oks["cross_ok"] = bool(cases.get("refusal_ok", false)) and bool(cases.get("first_cross_ok", false)) and bool(cases.get("avatar_ok", false)) # refusal + scripted cross + the production step trigger
		_oks["derive_ok"] = derive_ok
		_oks["legendary_ok"] = bool(cases.get("legendary_ok", false))
		_oks["landmark_ok"] = bool(cases.get("hosting_ok", false)) and bool(cases.get("puzzle_ok", false)) # footprint hosting + state independence
		_oks["persist_ok"] = bool(cases.get("origin_edit_ok", false)) and bool(cases.get("chained_edit_ok", false)) and bool(cases.get("return_ok", false)) and bool(_persist.chained_stood)
		_oks["beacon_ok"] = bool(cases.get("beacon_ok", false)) and bool(cases.get("crossworld_ok", false))
		_oks["save_ok"] = bool(cases.get("save_ok", false))
		_oks["control_ok"] = bool(cases.get("control_ok", false)) # extra witness beside the spec's eight payload keys
		_oks["cross_method_ok"] = bool(cases.get("deposit_ok", false)) and bool(cases.get("fly_ok", false)) and bool(cases.get("cardinal_ok", false)) and bool(cases.get("fly_suppress_ok", false)) # R8: the cross-method duality
	if _failures.is_empty():
		var payload: Dictionary = _oks.duplicate(); payload["seed"] = SEED
		runtime.emit_trace("world_chain_passed", "SmokeScenarios", payload)
	else:
		runtime.emit_trace("world_chain_failed", "SmokeScenarios", {"failures": _failures, "seed": SEED})
		push_error("WorldChainScenario failed: %s" % "; ".join(PackedStringArray(_failures)))
		runtime.warn("SmokeScenarios", "World chain scenario failed.", {})
	FieldMovesParty.restore(runtime, party_before)
	_player().encounter_chance = saved_chance; _player().input_enabled = true
	runtime.session.time_of_day_minutes = DAY_MINUTES
	runtime.overworld_mons_runtime.take_pending_encounter() # never leave an armed seam for the dispatcher's teardown


# One full chain script (identical both halves): seed pin -> new_game -> cross OUT
# (surf north) -> chained-world proofs -> cross BACK (surf south) -> re-cross -> the
# v5 round trip -> final return -> the cross-world ban + the CONTROL. Returns the
# per-checkpoint world fingerprints (the derive_ok compare) + the case booleans.
func _script(runtime) -> Dictionary:
	_checks.begin_run(); _persist.begin_run()
	runtime.seed_for_smoke(SEED) # BEFORE new_game: pins the root_seed draw (the double-run lane reds without it)
	runtime.new_game()
	FieldMovesParty.swap_in(runtime) # AFTER new_game: reset_for_new_game's party.clear wiped any pre-script swap (the 280x structure_refused{not_capable} red)
	_world().rebuild(runtime.get_world_seed()) # the view owns its own generator (the breed_flow precedent)
	runtime.session.time_of_day_minutes = DAY_MINUTES
	runtime.landmark_runtime._visited.clear(); runtime.landmark_runtime._loot_taken.clear() # the runtime's session-scoped one-shots survive new_game (landmark_flow precedent)
	var root: int = int(runtime.session.root_seed)
	var cases := {}
	var fp := {"origin": _checks.world_fingerprint(runtime)} # BEFORE any edit: the pure-derived origin plane
	_step(runtime, cases, "refusal_ok", Callable(_checks, "run_refusal_case"))
	_step(runtime, cases, "origin_edit_ok", Callable(_checks, "run_origin_edit_case"))
	_step(runtime, cases, "first_cross_ok", func(rt): return _checks.run_first_cross_case(rt, root))
	if _failures.is_empty():
		fp["chained"] = _checks.world_fingerprint(runtime) # BEFORE the chained edits: pure-derived terrain + the re-stamp
	_step(runtime, cases, "legendary_ok", Callable(_checks, "run_legendary_case"))
	_step(runtime, cases, "hosting_ok", Callable(_checks, "run_landmark_hosting_case"))
	_step(runtime, cases, "chained_edit_ok", Callable(_persist, "run_chained_edit_case"))
	_step(runtime, cases, "puzzle_ok", Callable(_persist, "run_puzzle_independence_case"))
	_step(runtime, cases, "beacon_ok", Callable(_persist, "run_beacon_case"))
	_step(runtime, cases, "return_ok", Callable(_persist, "run_return_persist_case"))
	if _failures.is_empty():
		fp["origin_returned"] = _checks.world_fingerprint(runtime) # the archived edits re-applied: still byte-stable
	_step(runtime, cases, "save_ok", Callable(_persist, "run_save_case"))
	_step(runtime, cases, "crossworld_ok", Callable(_persist, "run_crossworld_case"))
	_step(runtime, cases, "control_ok", Callable(_persist, "run_control_case"))
	_step(runtime, cases, "avatar_ok", Callable(_checks, "run_avatar_cross_case"))
	# R8: the cross-method duality (deposit geometry, the production-gate fly cross + its
	# surf-refused negative control, a second cardinal, use_fly's edge_suppressed sibling
	# gate). Runs AFTER the fingerprint is captured + avatar_ok returns to origin, so the
	# extra crosses never perturb the double-run fingerprint or the persistence cases.
	_step(runtime, cases, "deposit_ok", Callable(_crossm, "run_deposit_case"))
	_step(runtime, cases, "fly_ok", Callable(_crossm, "run_fly_cross_case"))
	_step(runtime, cases, "cardinal_ok", Callable(_crossm, "run_cardinal_cross_case"))
	_step(runtime, cases, "fly_suppress_ok", Callable(_crossm, "run_fly_suppression_case"))
	return {"fp": fp, "cases": cases}


# Cascade guard (the landmark_flow precedent): a red upstream SKIPS the downstream
# case with a NAMED skip entry instead of piling garbage reds on a torn state.
func _step(runtime, cases: Dictionary, key: String, callable: Callable) -> void:
	if _failures.is_empty():
		cases[key] = bool(callable.call(runtime))
	else:
		cases[key] = false
		_failures.append("skipped: %s (cascaded from an earlier red)" % key)


func _ensure(ok: bool, label: String) -> bool:
	if not ok:
		_failures.append(label)
	return ok


func _world() -> Node: return _ctx["world"]
func _player() -> Node: return _ctx["player"]
func _runtime() -> Node: return _ctx["runtime"]
