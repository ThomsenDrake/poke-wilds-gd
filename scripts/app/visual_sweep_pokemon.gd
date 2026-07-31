extends Node

# Deterministic pokemon-state driver for the visual sweep (Phase 5; spec:
# docs/product-specs/breeding-shinies-drops-fishing.md). STANDALONE from
# qa_scenarios (camping / storage pattern): a fenced pen holding a ground egg
# at noon (20), then a battle against a FORCED-SHINY wild mon — the FAQ odds
# hook pinned to 1/2 under a reseed (21). Reconciles ONLY its own shots: the
# update pass copies captures WITHOUT pruning other sweeps' baselines (the
# main sweep owns the full-set prune, guarded by the shared _foreign_shot set,
# extended to 20_ / 21_). Every state is crafted, never rolled (seed
# 2026072605, noon, fixed materials, deterministic female+male EEVEE pair +
# seeded cadence; the shiny hunt reseeds). Shots continue after storage's 18-19.

const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")
const VisualSweepBaselines := preload("res://scripts/app/visual_sweep_baselines.gd")
const SnapshotCapture := preload("res://scripts/app/snapshot_capture.gd")
const RenderIntrospection := preload("res://scripts/app/render_introspection.gd")
const Phase5 := preload("res://scripts/runtime/phase5_support.gd")
const Sites := preload("res://scripts/runtime/phase5_sites.gd")

const SITE_RADIUS := 160
const DEFAULT_THRESHOLD_PCT := 0.5
const CRAFTED_STATE := {
	"world_seed": 2026072605,
	"time_of_day": 720, # noon
	"party": [["MACHOP", 30]],
	"bag": {"log": 16, "dry_soil": 16} # the fence ring (16 fences) prices exactly this
}
const SHOT_EGG := "20_egg_in_pen.png"
const SHOT_SHINY := "21_shiny_battle.png"
const SHINY_SEED := 2026072606
const EGG_CAP_STEPS := 6000

var _ctx: Dictionary = {}
var _crafted: Dictionary = {}
var _runner = SmokeScenarioRunner.new()
var _baselines = VisualSweepBaselines.new()
var _captures = SnapshotCapture.new()
var _base_dir := ""
var _mode := VisualSweepBaselines.MODE_COMPARE
var _threshold_pct := DEFAULT_THRESHOLD_PCT
var _shots: Array = []
var _failures: Array = []
var _baselines_copied := false


func run_sweep(ctx: Dictionary, options: Dictionary = {}) -> void:
	_ctx = ctx
	_crafted = _baselines.crafted_state("pokemon", CRAFTED_STATE) # R3: world_seed single-sourced from SHOT_REGISTRY
	_mode = str(options.get("mode", VisualSweepBaselines.MODE_COMPARE))
	_threshold_pct = float(options.get("threshold_pct", DEFAULT_THRESHOLD_PCT))
	_base_dir = _baselines.resolve_shot_dir()
	if _base_dir.is_empty():
		_runtime().warn("SmokeScenarios", "Pokemon sweep found no writable screenshot directory.", {}); return
	_baselines.clear_shots(_base_dir)
	if not _baselines.craft_state(_ctx, _runner, _crafted):
		push_error("Pokemon sweep could not craft its deterministic state; catalog incomplete."); return
	var previous_window := _baselines.apply_canonical_window_size()
	await _settle(5)
	var saved_chance: float = _player().encounter_chance
	_player().encounter_chance = 0.0
	await _egg_in_pen_shot()
	await _shiny_battle_shot()
	_player().encounter_chance = saved_chance
	_baselines.restore_window_size(previous_window)
	_finish()


# Fenced pen near spawn at noon with a ground egg (deterministic EEVEE pair,
# happiness poked, seeded cadence).
func _egg_in_pen_shot() -> void:
	var runtime = _runtime()
	var center := Sites.find_pen_site(_world(), _player().tile_position, SITE_RADIUS)
	if center == Vector2i.ZERO or not bool(Sites.build_pen(runtime, center).get("ok", false)):
		runtime.warn("VisualSweepPokemon", "No pen site near spawn; egg shot skipped.", {}); return
	Phase5.invalidate_pen_cache(runtime)
	var anchor := Phase5.pen_key_for(runtime, center)
	var pair: Dictionary = Phase5.gendered_instances(runtime, "EEVEE", 30, ["female", "male"])
	if anchor.is_empty() or pair.size() != 2:
		runtime.warn("VisualSweepPokemon", "No pen/pair for the egg shot; skipped.", {}); return
	runtime.session.party.append(pair["female"])
	runtime.session.party.append(pair["male"])
	_runner.teleport_player(_world(), _player(), runtime, center)
	for _i in range(2): # the just-appended mons (last slot each time)
		Phase5.pasture_deposit(runtime, runtime.session.party.size() - 1)
	Phase5.poke_pasture_happiness(runtime, anchor, 255)
	var egg: Dictionary = Phase5.wait_for_pen_egg(runtime, anchor, EGG_CAP_STEPS, 60)
	if egg.is_empty():
		runtime.warn("VisualSweepPokemon", "The seeded cadence laid no egg; egg shot skipped.", {}); return
	_crafted["egg_tile"] = [int(egg["tile"].x), int(egg["tile"].y)]
	_crafted["egg_is_shiny"] = bool((egg.get("egg", {}) as Dictionary).get("is_shiny", false))
	# Face the pen from one tile outside its ring (the gate-side view).
	var spot: Dictionary = Sites.pen_stand_spot(_world(), center)
	if not spot.is_empty():
		_runner.teleport_player(_world(), _player(), runtime, spot["stand"])
		_player().smoke_step(spot["faced"] - spot["stand"]) # blocked by the fence, turns the avatar
	_world().set_time_of_day(int(CRAFTED_STATE["time_of_day"]))
	_world().sync_visible(_player().tile_position)
	await _capture(SHOT_EGG)


# A wild battle against a FORCED shiny (odds hook 1/2, reseeded).
func _shiny_battle_shot() -> void:
	var runtime = _runtime()
	if not Phase5.set_shiny_odds(runtime, 2):
		runtime.warn("VisualSweepPokemon", "No shiny-odds hook; shiny battle shot skipped.", {}); return
	runtime.seed_for_smoke(SHINY_SEED)
	var biome: String = _world().get_tile_biome(_player().tile_position)
	var shiny := {}
	for _i in range(64):
		var mon: Dictionary = runtime.generate_wild_encounter(_player().tile_position, biome)
		if bool(mon.get("is_shiny", false)):
			shiny = mon
			break
	Phase5.set_shiny_odds(runtime, 256)
	if shiny.is_empty():
		runtime.warn("VisualSweepPokemon", "No shiny within 64 draws; shiny battle shot skipped.", {}); return
	_crafted["shiny_species_id"] = str(shiny.get("species_id", ""))
	_call("set_battle", [true])
	_message_box().hide_message()
	_music_router().play_battle_track("wild")
	_battle_view().start_wild_battle(shiny)
	await _capture(SHOT_SHINY)
	_call("set_battle", [false])
	_runner.resync_player_tile(_world(), _player(), runtime)


func _finish() -> void:
	if not _failures.is_empty():
		push_error("Pokemon sweep failed captures: %s" % "; ".join(PackedStringArray(_failures))); return
	if _shots.is_empty():
		_runtime().warn("SmokeScenarios", "Pokemon sweep captured no shots; nothing verified.", {}); return
	# Update (or first run, missing baselines) copies ONLY this sweep's shots +
	# sidecars (never prunes); reconcile then compares this run's captures.
	if _mode == VisualSweepBaselines.MODE_UPDATE or not _missing_baselines().is_empty():
		var errors := _copy_baselines()
		if not errors.is_empty():
			push_error("Pokemon sweep baseline update failed: %s" % "; ".join(PackedStringArray(errors)))
			return
		_baselines_copied = true
	var result: Dictionary = _baselines.reconcile(_shots, _base_dir, VisualSweepBaselines.MODE_COMPARE, _threshold_pct)
	# Rescope the shared differ's whole-dir uncaptured flag to THIS sweep.
	var per_shot: Dictionary = result.get("per_shot", {})
	var compared_all := not _shots.is_empty()
	for shot in _shots:
		compared_all = compared_all and per_shot.has(str(shot))
	result["ok"] = compared_all and (result.get("errors", []) as Array).is_empty() and (result.get("mismatched", []) as Array).is_empty()
	_report(result)


func _report(result: Dictionary) -> void:
	if not bool(result.get("ok", false)):
		var per_shot: Dictionary = result.get("per_shot", {})
		for shot in result.get("mismatched", []):
			push_error("Pokemon sweep drift on %s: %s%% of pixels changed (threshold %s%%)." % [shot, per_shot.get(shot, "?"), _threshold_pct])
		for message in result.get("errors", []):
			push_error("Pokemon sweep diff error: %s" % message)
		_runtime().emit_trace("visual_sweep_pokemon_failed", "SmokeScenarios", {"mismatched": result.get("mismatched", []), "per_shot_pct": per_shot, "errors": result.get("errors", []), "threshold_pct": _threshold_pct}) # miss-002 loudness: drift names its shots + percentages in the trace, never stderr-only
		return
	_runtime().emit_trace("visual_sweep_pokemon_passed", "SmokeScenarios", {
		"shots": _shots, "mode": str(result.get("mode", VisualSweepBaselines.MODE_COMPARE)),
		"auto_update": _baselines_copied, "compared": int(result.get("compared", 0)),
		"mismatched": result.get("mismatched", []), "max_drift_pct": float(result.get("max_drift_pct", 0.0)),
		"threshold_pct": _threshold_pct, "base_dir": _base_dir, "crafted": _crafted,
		"sidecar_paths": _shots.map(func(shot_name): return "%s/%s%s" % [_base_dir, shot_name, RenderIntrospection.SIDECAR_SUFFIX])
	})


func _missing_baselines() -> Array:
	var missing: Array = []
	for shot in _shots:
		if not FileAccess.file_exists("%s/%s" % [VisualSweepBaselines.BASELINE_DIR, str(shot)]): missing.append(shot)
	return missing


# Copies captures + sidecars over the committed baselines; never prunes.
func _copy_baselines() -> Array:
	var errors: Array = []
	if DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(VisualSweepBaselines.BASELINE_DIR)) != OK: return ["baseline directory is not writable"]
	for shot in _shots:
		var shot_name := str(shot)
		var err := DirAccess.copy_absolute(
			ProjectSettings.globalize_path("%s/%s" % [_base_dir, shot_name]),
			ProjectSettings.globalize_path("%s/%s" % [VisualSweepBaselines.BASELINE_DIR, shot_name]))
		if err != OK:
			errors.append("could not copy %s into the baseline directory (err %d)" % [shot_name, err]); continue
		if not RenderIntrospection.copy_sidecar(_base_dir, shot_name, VisualSweepBaselines.BASELINE_DIR):
			errors.append("could not copy the sidecar for %s (PNG/sidecar desync)" % shot_name)
	return errors


func _capture(filename: String) -> void:
	_message_box().hide_message()
	await _settle(2)
	var metadata: Dictionary = RenderIntrospection.collect(_ctx, filename, _crafted)
	var result: Dictionary = await _captures.capture(_runtime(), get_viewport(), filename,
		{"save_path": "%s/%s" % [_base_dir, filename], "metadata": metadata})
	if not result.ok:
		_failures.append("%s: %s (%s)" % [filename, result.kind, result.detail])
		return
	_shots.append(filename)


func _settle(frames: int) -> void:
	for _i in range(frames):
		await get_tree().process_frame


func _call(key: String, args: Array = []) -> void:
	var callable: Callable = _ctx.get(key, Callable())
	if callable.is_valid():
		callable.callv(args)


func _world() -> Node: return _ctx["world"]
func _player() -> Node: return _ctx["player"]
func _runtime() -> Node: return _ctx["runtime"]
func _battle_view() -> Node: return _ctx["battle_view"]
func _message_box() -> Node: return _ctx["message_box"]
func _music_router() -> Object: return _ctx["music_router"]
