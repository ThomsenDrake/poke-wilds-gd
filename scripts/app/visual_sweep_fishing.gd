extends Node

# Deterministic fishing driver for the visual sweep (shots 26-27; spec: docs/
# product-specs/breeding-shinies-drops-fishing.md). STANDALONE (camping/storage/
# overworld pattern): the Old Rod crafts through the REAL resolver, a Beach water
# tile is ring-scanned from spawn, and casts run through fishing_runtime — which
# SHARES game_runtime._rng — under the frozen seed 2026072804. 26 captures a
# no-bite cast message, 27 the bite message; the pending-encounter seam is
# disarmed AT capture (take_pending_encounter) so no battle starts and no later
# step inherits an armed hook. Reconciles ONLY its own shots; the shared
# _foreign_shot guard (SHOT_REGISTRY-derived) keeps other sweeps' prunes honest.

const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")
const VisualSweepBaselines := preload("res://scripts/app/visual_sweep_baselines.gd")
const SnapshotCapture := preload("res://scripts/app/snapshot_capture.gd")
const RenderIntrospection := preload("res://scripts/app/render_introspection.gd")
const Phase5 := preload("res://scripts/runtime/phase5_support.gd")
const Sites := preload("res://scripts/runtime/phase5_sites.gd")

const DEFAULT_THRESHOLD_PCT := 0.5
const CRAFTED_STATE := {
	"world_seed": 2026072804, # the fishing satellite's frozen date-shaped seed
	"time_of_day": 720,
	"party": [["MACHOP", 30]],
	"bag": {}
}
const SEED := 2026072804
const SHOT_CAST := "26_fishing_cast.png"
const SHOT_BITE := "27_fishing_bite.png"
const WATER_SCAN_RADIUS := 40
const CAST_CAP := 40 # seeded casts allowed to land both states (loud fail past this)
const MESSAGE_HOLD_SECONDS := 60.0 # auto-hide far beyond the capture; manual hide after

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
	_crafted = CRAFTED_STATE.duplicate(true)
	_mode = str(options.get("mode", VisualSweepBaselines.MODE_COMPARE))
	_threshold_pct = float(options.get("threshold_pct", DEFAULT_THRESHOLD_PCT))
	_base_dir = _baselines.resolve_shot_dir()
	if _base_dir.is_empty():
		_runtime().warn("SmokeScenarios", "Fishing sweep found no writable screenshot directory.", {}); return
	_baselines.clear_shots(_base_dir)
	if not _baselines.craft_state(_ctx, _runner, CRAFTED_STATE):
		_emit_failed(["craft_state: deterministic state could not be crafted (catalog incomplete)"])
		push_error("Fishing sweep could not craft its deterministic state; catalog incomplete."); return
	var previous_window := _baselines.apply_canonical_window_size()
	await _settle(5)
	var saved_chance: float = _player().encounter_chance
	_player().encounter_chance = 0.0 # no grass battles (and no wild-stream draw) during capture
	await _fishing_shots()
	_player().encounter_chance = saved_chance
	_baselines.restore_window_size(previous_window)
	_finish()


# Grant rod materials (drain-then-grant, craft_flow pattern) -> craft old_rod at
# a campfire station through crafting_runtime -> ring-scan a Beach water tile ->
# seeded casts until BOTH states land: first no-bite cast -> 26, first hook -> 27.
func _fishing_shots() -> void:
	var runtime := _runtime()
	var problem := Phase5.contract_problem(runtime)
	if not problem.is_empty():
		_failures.append("%s: %s" % [SHOT_CAST, problem]); return
	Sites.grant_rod_materials(runtime)
	var craft: Dictionary = runtime.crafting_runtime.craft("old_rod", "campfire")
	if not bool(craft.get("ok", false)):
		_failures.append("%s: old_rod craft refused (%s)" % [SHOT_CAST, str(craft.get("reason", ""))]); return
	var water := _find_beach_water()
	if water.is_empty():
		_failures.append("%s: no Beach water tile within %d rings of spawn (seed %d)" % [SHOT_CAST, WATER_SCAN_RADIUS, SEED]); return
	_runner.teleport_player(_world(), _player(), runtime, water["stand"])
	_crafted["water_tile"] = [int((water["tile"] as Vector2i).x), int((water["tile"] as Vector2i).y)]
	_crafted["stand_tile"] = [int((water["stand"] as Vector2i).x), int((water["stand"] as Vector2i).y)]
	runtime.seed_for_smoke(SEED) # pins the shared rng every fishing draw consumes
	var fishing_rt: Object = Phase5.fishing_rt(runtime)
	var cast_done := false
	var bite_done := false
	for _cast in range(CAST_CAP):
		if cast_done and bite_done:
			break
		var result: Dictionary = Phase5.cast_rod(runtime, water["tile"])
		if bool(result.get("ok", false)):
			var pending: Dictionary = fishing_rt.call("take_pending_encounter") # disarm the seam AT capture
			if not bite_done:
				_crafted["bite_species"] = str(result.get("species_id", ""))
				_crafted["pending_disarmed"] = not pending.is_empty()
				_message_box().show_message(str(result.get("message", "")), MESSAGE_HOLD_SECONDS)
				await _capture(SHOT_BITE)
				bite_done = true
			continue
		if str(result.get("reason", "")) != "no_bite":
			_failures.append("%s: cast refused (%s)" % [SHOT_CAST, str(result.get("reason", ""))]); return
		if not cast_done:
			_message_box().show_message(str(result.get("message", "")), MESSAGE_HOLD_SECONDS)
			await _capture(SHOT_CAST)
			cast_done = true
	if not cast_done:
		_failures.append("%s: %d seeded casts produced no no-bite cast" % [SHOT_CAST, CAST_CAP])
	if not bite_done:
		_failures.append("%s: no hook within %d seeded casts" % [SHOT_BITE, CAST_CAP])
	if not (fishing_rt.call("take_pending_encounter") as Dictionary).is_empty():
		_failures.append("fishing seam: a pending encounter was left armed after the shots")


# First WATER tile ringed outward from spawn with a walkable SAND stand tile (the beach:
# biome_defs names the shore biome SAND; there is no BEACH biome id).
func _find_beach_water() -> Dictionary:
	var center: Vector2i = _player().tile_position
	for ring in range(1, WATER_SCAN_RADIUS + 1):
		for tile in _runner.ring_around(center, ring):
			if str(_world().get_tile_logic(tile).get("biome", "")) != "WATER":
				continue
			for direction in [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]:
				var stand: Vector2i = tile + direction
				if str(_world().get_tile_logic(stand).get("biome", "")) == "SAND" and _world().is_tile_walkable(stand):
					return {"tile": tile, "stand": stand}
	return {}


func _finish() -> void:
	if not _failures.is_empty():
		_emit_failed(_failures)
		push_error("Fishing sweep failed captures: %s" % "; ".join(PackedStringArray(_failures))); return
	if _shots.is_empty():
		_runtime().warn("SmokeScenarios", "Fishing sweep captured no shots; nothing verified.", {}); return
	# Update (or first run, missing baselines) copies ONLY this sweep's shots +
	# sidecars (never prunes); reconcile then compares this run's captures.
	if _mode == VisualSweepBaselines.MODE_UPDATE or not _missing_baselines().is_empty():
		var errors := _copy_baselines()
		if not errors.is_empty():
			push_error("Fishing sweep baseline update failed: %s" % "; ".join(PackedStringArray(errors)))
			return
		_baselines_copied = true
	var result: Dictionary = _baselines.reconcile(_shots, _base_dir, VisualSweepBaselines.MODE_COMPARE, _threshold_pct)
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
			push_error("Fishing sweep drift on %s: %s%% of pixels changed (threshold %s%%)." % [shot, per_shot.get(shot, "?"), _threshold_pct])
		for message in result.get("errors", []):
			push_error("Fishing sweep diff error: %s" % message)
		var reasons: Array = (result.get("mismatched", []) as Array).map(func(shot): return "drift on %s: %s%% of pixels changed (threshold %s%%)" % [shot, per_shot.get(shot, "?"), _threshold_pct])
		reasons.append_array((result.get("errors", []) as Array).map(func(message): return "diff error: %s" % message))
		_emit_failed(reasons)
		return
	_runtime().emit_trace("visual_sweep_fishing_passed", "SmokeScenarios", {
		"shots": _shots, "mode": str(result.get("mode", VisualSweepBaselines.MODE_COMPARE)),
		"auto_update": _baselines_copied, "compared": int(result.get("compared", 0)),
		"mismatched": result.get("mismatched", []), "max_drift_pct": float(result.get("max_drift_pct", 0.0)),
		"threshold_pct": _threshold_pct, "base_dir": _base_dir, "crafted": _crafted,
		"sidecar_paths": _shots.map(func(shot_name): return "%s/%s%s" % [_base_dir, shot_name, RenderIntrospection.SIDECAR_SUFFIX])
	})


func _missing_baselines() -> Array:
	return _shots.filter(func(shot): return not FileAccess.file_exists("%s/%s" % [VisualSweepBaselines.BASELINE_DIR, str(shot)]))


# Copies captures + sidecars over the committed baselines; never prunes (each sweep owns its prune).
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
	# The message IS the shot: no hide before capture (shown with a 60s hold).
	await _settle(6)
	var metadata: Dictionary = RenderIntrospection.collect(_ctx, filename, _crafted)
	var result: Dictionary = await _captures.capture(_runtime(), get_viewport(), filename,
		{"save_path": "%s/%s" % [_base_dir, filename], "metadata": metadata})
	_message_box().hide_message()
	if not result.ok:
		_failures.append("%s: %s (%s)" % [filename, result.kind, result.detail]); return
	_shots.append(filename)


func _settle(frames: int) -> void:
	for _i in range(frames):
		await get_tree().process_frame


func _emit_failed(reasons: Array) -> void: # symmetric failure marker (miss-002): every failed terminus names its causes
	_runtime().emit_trace("visual_sweep_fishing_failed", "SmokeScenarios", {"reasons": reasons, "seed": SEED, "crafted": _crafted})


func _world() -> Node: return _ctx["world"]
func _player() -> Node: return _ctx["player"]
func _runtime() -> Node: return _ctx["runtime"]
func _message_box() -> Node: return _ctx["message_box"]
