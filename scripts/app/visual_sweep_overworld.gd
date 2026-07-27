extends Node

# Deterministic overworld-mon driver for the visual sweep (Phase 6; spec: docs/product-specs/
# overworld-pokemon.md § Smoke validation). STANDALONE (camping / storage / pokemon pattern): a
# seeded walk band with live roamers mid-window (22), then a seeded nest — ground ring + two wild
# eggs + the stationary Alpha guardian (23). Reconciles ONLY its own shots: the update pass copies
# captures WITHOUT pruning other sweeps' baselines (the shared _foreign_shot guard learns 22_ / 23_).
# Shots CONTINUE after 21_shiny_battle (the leading 09-12 stay battle-reserved by the sidecar
# canary contract). NO rng in the capture path: entities are pure step functions of
# (world_seed, total_steps, slot) and the walk is a fixed safe-step script on a seeded world, so
# every shot is byte-stable. The subsystem is opted IN for this sweep (smoke_scenario_runner's
# activation opt-out skips the opt-in set), and run_sweep sets it active defensively regardless.

const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")
const VisualSweepBaselines := preload("res://scripts/app/visual_sweep_baselines.gd")
const SnapshotCapture := preload("res://scripts/app/snapshot_capture.gd")
const RenderIntrospection := preload("res://scripts/app/render_introspection.gd")

const DEFAULT_THRESHOLD_PCT := 0.5
const WALK_STEPS := 10 # deterministic safe-step band so roamers materialize + roam mid-window
const NEST_SCAN_RADIUS := 40 # tiles ringed outward from spawn looking for a nest cell
const CRAFTED_STATE := {
	"world_seed": 2026072722,
	"time_of_day": 720, # noon
	"party": [["MACHOP", 30]],
	"bag": {}
}
const SHOT_ROAMING := "22_roaming_mons.png"
const SHOT_NEST := "23_nest_alpha.png"

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
var _nest_skipped := false


func run_sweep(ctx: Dictionary, options: Dictionary = {}) -> void:
	_ctx = ctx
	_crafted = CRAFTED_STATE.duplicate(true)
	_mode = str(options.get("mode", VisualSweepBaselines.MODE_COMPARE))
	_threshold_pct = float(options.get("threshold_pct", DEFAULT_THRESHOLD_PCT))
	_base_dir = _baselines.resolve_shot_dir()
	if _base_dir.is_empty():
		_runtime().warn("SmokeScenarios", "Overworld sweep found no writable screenshot directory.", {}); return
	_baselines.clear_shots(_base_dir)
	if not _baselines.craft_state(_ctx, _runner, CRAFTED_STATE):
		push_error("Overworld sweep could not craft its deterministic state; catalog incomplete."); return
	var previous_window := _baselines.apply_canonical_window_size()
	await _settle(5)
	var saved_chance: float = _player().encounter_chance
	_player().encounter_chance = 0.0 # no grass battles (and no wild-stream draw) during capture
	var saved_active: bool = _set_entities_active(true) # opt in for the shots; restored after
	await _roaming_shot()
	await _nest_shot()
	_set_entities_active(saved_active)
	_player().encounter_chance = saved_chance
	_baselines.restore_window_size(previous_window)
	_finish()


# A seeded walk band from spawn with live roamers mid-window, honoring the y-sort depth contract.
func _roaming_shot() -> void:
	for _i in range(WALK_STEPS):
		var direction: Vector2i = _runner.find_safe_step_direction(_world(), _player(), _runtime())
		if direction == Vector2i.ZERO:
			break
		if _player().smoke_step(direction):
			await _player().tile_changed
	_crafted["roaming_tile"] = [_player().tile_position.x, _player().tile_position.y]
	_world().set_time_of_day(int(CRAFTED_STATE["time_of_day"]))
	_world().sync_visible(_player().tile_position)
	await _capture(SHOT_ROAMING)


# A seeded nest: ask the runtime for a nest cell's center (it owns the domain nest roll + the
# Manhattan-from-origin ring), then stand on it so the guardian + eggs + ground ring materialize.
func _nest_shot() -> void:
	var center := _find_nest_center()
	if center == Vector2i.ZERO:
		_nest_skipped = true; _runtime().warn("VisualSweepOverworld", "No nest cell near spawn; nest shot skipped.", {}); return
	_runner.teleport_player(_world(), _player(), _runtime(), center)
	_runtime().note_player_step() # re-derive the window at the nest so the guardian+eggs materialize (never band-luck from the roaming shot)
	_crafted["nest_tile"] = [center.x, center.y]
	_world().set_time_of_day(int(CRAFTED_STATE["time_of_day"]))
	_world().sync_visible(_player().tile_position)
	await _capture(SHOT_NEST)


# The runtime's deterministic nest finder (overworld_mons_runtime owns the domain roll; app may not
# reach domain directly): the center tile of the first nest cell ringed outward from spawn, or
# Vector2i.ZERO when none lies in range (the shot is skipped, never faked; cell centers are never
# (0,0), so ZERO is a safe sentinel).
func _find_nest_center() -> Vector2i:
	var runtime := _runtime()
	var mons: Object = runtime.get("overworld_mons_runtime") if runtime != null and "overworld_mons_runtime" in runtime else null
	if mons == null or not mons.has_method("find_nest_center_near"):
		return Vector2i.ZERO
	var result: Variant = mons.call("find_nest_center_near", _player().tile_position, NEST_SCAN_RADIUS)
	return result if result is Vector2i else Vector2i.ZERO


# Read/set the subsystem activation gate off the runtime (the runtime is RefCounted, so use the
# Object get/set API; a missing runtime/var is a no-op, so the sweep degrades to entity-free shots
# rather than crashing before the runtime lane lands).
func _set_entities_active(active: bool) -> bool:
	var runtime := _runtime()
	var mons: Object = runtime.get("overworld_mons_runtime") if runtime != null and "overworld_mons_runtime" in runtime else null
	if mons == null or not ("active" in mons):
		return false
	var previous: bool = bool(mons.get("active"))
	mons.set("active", active)
	return previous


func _finish() -> void:
	if not _failures.is_empty():
		push_error("Overworld sweep failed captures: %s" % "; ".join(PackedStringArray(_failures))); return
	if _shots.is_empty():
		_runtime().warn("SmokeScenarios", "Overworld sweep captured no shots; nothing verified.", {}); return
	if _nest_skipped and FileAccess.file_exists("%s/%s" % [VisualSweepBaselines.BASELINE_DIR, SHOT_NEST]):
		push_error("Overworld sweep skipped the nest shot but a %s baseline exists on disk; refusing a silent partial pass." % SHOT_NEST); return
	# Update (or first run, missing baselines) copies ONLY this sweep's shots + sidecars (never
	# prunes); reconcile then compares this run's captures.
	if _mode == VisualSweepBaselines.MODE_UPDATE or not _missing_baselines().is_empty():
		var errors := _copy_baselines()
		if not errors.is_empty():
			push_error("Overworld sweep baseline update failed: %s" % "; ".join(PackedStringArray(errors)))
			return
		_baselines_copied = true
	var result: Dictionary = _baselines.reconcile(_shots, _base_dir, VisualSweepBaselines.MODE_COMPARE, _threshold_pct)
	# Rescope the shared differ's whole-dir uncaptured flag to THIS sweep (the pokemon precedent).
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
			push_error("Overworld sweep drift on %s: %s%% of pixels changed (threshold %s%%)." % [shot, per_shot.get(shot, "?"), _threshold_pct])
		for message in result.get("errors", []):
			push_error("Overworld sweep diff error: %s" % message)
		return
	_runtime().emit_trace("visual_sweep_overworld_passed", "SmokeScenarios", {
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
	_message_box().hide_message()
	await _settle(8) # let the entity layer reconcile + lerp-snap onto logic tiles (byte-stable rest)
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


func _world() -> Node: return _ctx["world"]
func _player() -> Node: return _ctx["player"]
func _runtime() -> Node: return _ctx["runtime"]
func _message_box() -> Node: return _ctx["message_box"]
