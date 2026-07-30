extends Node

# Shiny odds scenario (Phase 5; spec: docs/product-specs/breeding-shinies-
# drops-fishing.md). Verifies the 1/256 shiny draw STATISTICALLY but SEEDED —
# deterministic, never flaky: DRAWS wild creations on the pinned shared _rng
# yield a shiny count EQUAL to the exact precomputed expectation for the pinned
# seed (a pure function of (code, save, seed) — no tolerance band; EXPECTED was
# calibrated on SEED and drift fails LOUD with the observed count), every
# instance carries a well-formed is_shiny, shiny_rolled fires once per EGG
# creation (the breeding runtime's emission seam) with the odds denominator in
# the payload, and the user-adjustable-odds hook from the original FAQ is
# proven (set_shiny_odds(2) on a reseeded window flips the rate to the exact
# 1/2 expectation, then the odds are restored). Egg shinies roll at lay time,
# visible pre-hatch (breed_flow proves the payload surfaces).

const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")
const Phase5 := preload("res://scripts/runtime/phase5_support.gd")
const Sites := preload("res://scripts/runtime/phase5_sites.gd")

const SEED := 2026072604
const DRAWS := 1024 # 4 x the 256 denominator
const EXPECTED := 2 # calibrated shiny count for SEED (pinned; drift fails loud). Re-calibrated
# 6 -> 2 (2026-07-29) when the scenario gained new_game + the spawn teleport: the starter
# build shifts the pinned stream offset; the count stayed stable across repeated seeded runs.
const HOOK_DRAWS := 64
const EXPECTED_HOOK := 31 # calibrated count for odds=2 on SEED + 999
const EGG_CAP_STEPS := 6000

var _ctx: Dictionary = {}
var _runner = SmokeScenarioRunner.new()
var _failures: Array = []


func run(ctx: Dictionary) -> void:
	_ctx = ctx
	await get_tree().create_timer(0.2).timeout
	var runtime = _runtime()
	runtime.seed_for_smoke(SEED)
	runtime.new_game() # self-contained: world + spawn derive from the PINNED seed (the breed_flow
	# precedent; the double-run lane needs a pure function of (code, seed) — the boot world is
	# wall-clock, so under the lane's --fresh-save runs the 1024 draws diverged per process)
	_world().rebuild(runtime.get_world_seed()) # mirror main.gd:_sync_world_from_runtime: new_game reseeds the authoritative generator but never the view
	_runner.teleport_player(_world(), _player(), runtime, runtime.session.player_tile) # sync the
	# avatar to the pinned spawn (the node lags the session reseed) — the draws read the tile's
	# biome, so the trace is byte-stable only once the tile is the pinned one
	var saved_chance: float = _player().encounter_chance
	_player().encounter_chance = 0.0
	runtime.session.repel_steps = 0
	var party_before: Array = _runner.swap_party(runtime, ["MACHOP", "RATTATA"], 10)
	var problem := Phase5.contract_problem(runtime)
	if not problem.is_empty():
		_failures.append(problem)
	var shinies := 0
	var malformed := 0
	if _failures.is_empty():
		var cursor := _runner.trace_log_line_count()
		var biome: String = _world().get_tile_biome(_player().tile_position)
		for _i in range(DRAWS):
			var mon: Dictionary = runtime.generate_wild_encounter(_player().tile_position, biome)
			var flag: Variant = mon.get("is_shiny", null)
			if not (flag is bool):
				malformed += 1
			elif bool(flag):
				shinies += 1
		_ensure(malformed == 0, "shape: %d of %d instances carry a malformed is_shiny" % [malformed, DRAWS])
		if shinies != EXPECTED:
			_failures.append("odds: %d shinies in %d draws, pinned expectation %d (re-calibrate only via a seeded re-run)" % [shinies, DRAWS, EXPECTED])
		# shiny_rolled fires on EVERY wild creation (the GameRuntime emission).
		var wild_rolls := _trace_count(cursor, "shiny_rolled", {"origin": "wild", "is_shiny": true})
		_ensure(wild_rolls == shinies, "trace: %d shiny_rolled{origin:wild,is_shiny:true} vs %d shiny instances" % [wild_rolls, shinies])
	if _failures.is_empty():
		_check_egg_emission(runtime)
	var odds_hook_ok := false
	if _failures.is_empty():
		odds_hook_ok = _check_odds_hook(runtime)
	if _failures.is_empty():
		runtime.emit_trace("shiny_odds_passed", "SmokeScenarios", {"draws": DRAWS, "shinies": shinies,
			"expected": EXPECTED, "odds_hook_ok": odds_hook_ok, "seed": SEED})
	else:
		runtime.emit_trace("shiny_odds_failed", "SmokeScenarios", {"failures": _failures, "shinies": shinies, "seed": SEED})
		push_error("ShinyOddsScenario failed: %s" % "; ".join(PackedStringArray(_failures)))
		runtime.warn("ShinyOddsScenario", "Shiny odds failed.", {})
	Phase5.set_shiny_odds(runtime, 256) # restore even on a failed hook window
	_runner.restore_party(runtime, party_before)
	_player().encounter_chance = saved_chance
	_player().input_enabled = true


# shiny_rolled fires on EVERY egg creation (the breeding runtime's emission
# seam) with the odds denominator in the payload — one trace per egg_laid.
func _check_egg_emission(runtime) -> void:
	Sites.grant_pen_materials(runtime)
	var center := Sites.find_pen_site(_world(), _player().tile_position, 160)
	if center == Vector2i.ZERO:
		_ensure(false, "egg-trace: no pen site within 160 rings")
		return
	_runner.teleport_player(_world(), _player(), runtime, center) # sync the render window to the
	# pinned site BEFORE building — build-time biome reads follow the synced window, so a remote
	# build under a wall-clock-synced window is non-deterministic (the double-run lane caught it)
	if not bool(Sites.build_pen(runtime, center).get("ok", false)):
		_ensure(false, "egg-trace: the pen build was refused")
		return
	Phase5.invalidate_pen_cache(runtime)
	var anchor := Phase5.pen_key_for(runtime, center)
	if anchor.is_empty():
		_ensure(false, "egg-trace: the breeding runtime detects no pen")
		return
	var pair: Dictionary = Phase5.gendered_instances(runtime, "EEVEE", 10, ["female", "male"])
	if pair.size() != 2:
		_ensure(false, "egg-trace: no male+female EEVEE within 128 creations")
		return
	runtime.session.party.append(pair["female"])
	runtime.session.party.append(pair["male"])
	_runner.teleport_player(_world(), _player(), runtime, center)
	for _i in range(2):
		var deposit: Dictionary = Phase5.pasture_deposit(runtime, 2)
		if not bool(deposit.get("ok", false)):
			_ensure(false, "egg-trace: deposit refused (%s)" % str(deposit.get("reason", "")))
			Sites.demolish_pen(runtime, center)
			return
	if not Phase5.poke_pasture_happiness(runtime, anchor, 255):
		_ensure(false, "egg-trace: happiness poke found no penned mons")
	var cursor := _runner.trace_log_line_count()
	var egg: Dictionary = Phase5.wait_for_pen_egg(runtime, anchor, EGG_CAP_STEPS, 60)
	var ok := _ensure(not egg.is_empty(), "egg-trace: no egg within %d steps" % EGG_CAP_STEPS)
	var laid := _trace_count(cursor, "egg_laid", {})
	var rolled := _trace_count(cursor, "shiny_rolled", {"origin": "egg"})
	ok = _ensure(laid >= 1 and rolled == laid, "egg-trace: %d shiny_rolled{origin:egg} vs %d egg_laid" % [rolled, laid]) and ok
	_ensure(_runner.trace_log_has_since("shiny_rolled", cursor, {"odds": 256}), "egg-trace: shiny_rolled payload lacks the 1/256 denominator")
	Sites.demolish_pen(runtime, center)


# The adjustable-odds hook (original FAQ): odds 2 -> exactly half of a reseeded
# window shines, then the default is restored. A missing hook is a named red.
func _check_odds_hook(runtime) -> bool:
	if not Phase5.set_shiny_odds(runtime, 2):
		return _ensure(false, "hook: no set_shiny_odds seam is wired (the user-adjustable FAQ hook)")
	runtime.seed_for_smoke(SEED + 999)
	var biome: String = _world().get_tile_biome(_player().tile_position)
	var shinies := 0
	for _i in range(HOOK_DRAWS):
		var mon: Dictionary = runtime.generate_wild_encounter(_player().tile_position, biome)
		if bool(mon.get("is_shiny", false)):
			shinies += 1
	Phase5.set_shiny_odds(runtime, 256)
	if shinies != EXPECTED_HOOK:
		return _ensure(false, "hook: %d shinies in %d draws at odds 2, pinned expectation %d" % [shinies, HOOK_DRAWS, EXPECTED_HOOK])
	return true


# Trace events at/after from_line whose payload matches every key of `match`.
func _trace_count(from_line: int, event_name: String, match: Dictionary) -> int:
	var count := 0
	var lines := _trace_lines()
	var normalized: Dictionary = JSON.parse_string(JSON.stringify(match)) if not match.is_empty() else {}
	for index in range(maxi(from_line, 0), lines.size()):
		var parsed = JSON.parse_string(lines[index])
		if not (parsed is Dictionary) or str((parsed as Dictionary).get("event", "")) != event_name:
			continue
		var payload: Variant = (parsed as Dictionary).get("payload", {})
		var hit := true
		for key in normalized.keys():
			if not (payload is Dictionary) or (payload as Dictionary).get(key) != normalized[key]:
				hit = false
		if hit:
			count += 1
	return count


func _trace_lines() -> PackedStringArray:
	if not FileAccess.file_exists(SmokeScenarioRunner.TRACE_LOG_PATH):
		return PackedStringArray()
	var file := FileAccess.open(SmokeScenarioRunner.TRACE_LOG_PATH, FileAccess.READ)
	if file == null:
		return PackedStringArray()
	var text := file.get_as_text()
	file.close()
	return text.split("\n", false)


func _ensure(ok: bool, label: String) -> bool:
	if not ok:
		_failures.append(label)
	return ok


func _world() -> Node: return _ctx["world"]
func _player() -> Node: return _ctx["player"]
func _runtime() -> Node: return _ctx["runtime"]
