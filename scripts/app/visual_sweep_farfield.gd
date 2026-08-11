extends Node

# Far-field infinite-world visual sweep (Track A.3): distant scattered landmark
# (42). The legendary-lair shot (43) is RETIRED with the repeating lairs
# (legendary-dungeon slice): 43 rides the SHOT_REGISTRY retired list (prune-protected
# forever) and its committed baselines are deleted. Seed single-sourced from
# SHOT_REGISTRY["farfield"] (2026072908). Windowed-only; no puzzle/removal
# mutation — craft_state + teleport + sync_visible only. Retired holes
# 17/33/35/36/43 stay unused.

const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")
const VisualSweepBaselines := preload("res://scripts/app/visual_sweep_baselines.gd")
const SnapshotCapture := preload("res://scripts/app/snapshot_capture.gd")
const RenderIntrospection := preload("res://scripts/app/render_introspection.gd")
const LandmarkRuntime := preload("res://scripts/runtime/landmark_runtime.gd")
const LandmarkScatter := LandmarkRuntime.LandmarkScatter
const ContentScatter := LandmarkRuntime.ContentScatter

const DEFAULT_THRESHOLD_PCT := 0.5
const CRAFTED_STATE := {"world_seed": 2026072908, "time_of_day": 720, "party": [["MACHOP", 30]], "bag": {}}
const SHOT_LANDMARK := "42_far_landmark.png"
const SCAN_RADII := [31, 63, 95] # content_scatter_scenario expanding chunk-radius precedent
const ORIGIN_CORE_RING := 96

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


func run_sweep(ctx: Dictionary, options: Dictionary = {}) -> void:
	_ctx = ctx
	_crafted = _baselines.crafted_state("farfield", CRAFTED_STATE)
	_mode = str(options.get("mode", VisualSweepBaselines.MODE_COMPARE))
	_threshold_pct = float(options.get("threshold_pct", DEFAULT_THRESHOLD_PCT))
	_base_dir = _baselines.resolve_shot_dir()
	if _base_dir.is_empty():
		_runtime().warn("SmokeScenarios", "Farfield sweep found no writable screenshot directory.", {}); return
	_baselines.clear_shots(_base_dir)
	if not _baselines.craft_state(_ctx, _runner, _crafted):
		push_error("Farfield sweep could not craft its deterministic state; catalog incomplete."); return
	var previous_window := _baselines.apply_canonical_window_size()
	await _settle(5)
	var saved_chance: float = _player().encounter_chance
	_player().encounter_chance = 0.0
	var found := _scan(int(_crafted.get("world_seed", 0)))
	await _landmark_shot(found)
	_player().encounter_chance = saved_chance
	_baselines.restore_window_size(previous_window)
	_finish()


func _landmark_shot(found: Dictionary) -> void:
	var instance: Dictionary = found.get("landmark", {})
	if instance.is_empty():
		_failures.append("%s: no scattered landmark beyond origin core within scan" % SHOT_LANDMARK); return
	var footprint: Rect2i = instance.get("footprint", Rect2i())
	if footprint.size == Vector2i.ZERO:
		_failures.append("%s: scattered landmark missing footprint" % SHOT_LANDMARK); return
	var tile: Vector2i = footprint.position + Vector2i(footprint.size.x / 2, footprint.size.y / 2)
	_crafted["far_landmark"] = {"id": str(instance.get("landmark_id", "")), "tile": [tile.x, tile.y],
		"instance_key": str(instance.get("instance_key", ""))}
	_runner.teleport_player(_world(), _player(), _runtime(), tile)
	_world().set_time_of_day(int(CRAFTED_STATE["time_of_day"]))
	_world().sync_visible(tile)
	await _capture(SHOT_LANDMARK)


func _scan(seed: int) -> Dictionary:
	var out := {"landmark": {}}
	var seen := {}
	for rmax in SCAN_RADII:
		for cy in range(-int(rmax), int(rmax) + 1):
			for cx in range(-int(rmax), int(rmax) + 1):
				var chunk := Vector2i(cx, cy)
				if seen.has(chunk):
					continue
				seen[chunk] = true
				var center := chunk * ContentScatter.CONTENT_CHUNK + Vector2i(ContentScatter.CONTENT_CHUNK / 2, ContentScatter.CONTENT_CHUNK / 2)
				if ContentScatter.ring_of(center) <= ORIGIN_CORE_RING:
					continue
				if (out["landmark"] as Dictionary).is_empty():
					var instance := LandmarkScatter.instance_for_chunk(seed, chunk)
					if not instance.is_empty():
						out["landmark"] = instance
		if not (out["landmark"] as Dictionary).is_empty():
			return out
	return out


func _finish() -> void:
	if not _failures.is_empty():
		push_error("Farfield sweep failed captures: %s" % "; ".join(PackedStringArray(_failures))); return
	if _shots.is_empty():
		_runtime().warn("SmokeScenarios", "Farfield sweep captured no shots; nothing verified.", {}); return
	if _mode == VisualSweepBaselines.MODE_UPDATE or not _missing_baselines().is_empty():
		var errors := _copy_baselines()
		if not errors.is_empty():
			push_error("Farfield sweep baseline update failed: %s" % "; ".join(PackedStringArray(errors))); return
	var result: Dictionary = _baselines.reconcile(_shots, _base_dir, VisualSweepBaselines.MODE_COMPARE, _threshold_pct)
	var per_shot: Dictionary = result.get("per_shot", {})
	var compared_all := not _shots.is_empty()
	for shot in _shots:
		compared_all = compared_all and per_shot.has(str(shot))
	result["ok"] = compared_all and (result.get("errors", []) as Array).is_empty() and (result.get("mismatched", []) as Array).is_empty()
	if not bool(result.get("ok", false)):
		for shot in result.get("mismatched", []):
			push_error("Farfield sweep drift on %s: %s%% of pixels changed." % [shot, per_shot.get(shot, "?")])
		for message in result.get("errors", []):
			push_error("Farfield sweep diff error: %s" % message)
		_runtime().emit_trace("visual_sweep_farfield_failed", "SmokeScenarios",
			{"mismatched": result.get("mismatched", []), "errors": result.get("errors", [])})
		return
	_runtime().emit_trace("visual_sweep_farfield_passed", "SmokeScenarios", {
		"shots": _shots, "mode": str(result.get("mode", VisualSweepBaselines.MODE_COMPARE)),
		"compared": int(result.get("compared", 0)), "crafted": _crafted, "base_dir": _base_dir,
		"sidecar_paths": _shots.map(func(s): return "%s/%s%s" % [_base_dir, s, RenderIntrospection.SIDECAR_SUFFIX])
	})


func _missing_baselines() -> Array:
	return _shots.filter(func(shot): return not FileAccess.file_exists("%s/%s" % [VisualSweepBaselines.BASELINE_DIR, str(shot)]))


func _copy_baselines() -> Array:
	var errors: Array = []
	if DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(VisualSweepBaselines.BASELINE_DIR)) != OK:
		return ["baseline directory is not writable"]
	for shot in _shots:
		var shot_name := str(shot)
		var err := DirAccess.copy_absolute(ProjectSettings.globalize_path("%s/%s" % [_base_dir, shot_name]),
			ProjectSettings.globalize_path("%s/%s" % [VisualSweepBaselines.BASELINE_DIR, shot_name]))
		if err != OK:
			errors.append("could not copy %s (err %d)" % [shot_name, err]); continue
		if not RenderIntrospection.copy_sidecar(_base_dir, shot_name, VisualSweepBaselines.BASELINE_DIR):
			errors.append("could not copy sidecar for %s" % shot_name)
	return errors


func _capture(filename: String) -> void:
	_message_box().hide_message()
	await _settle(8)
	var metadata: Dictionary = RenderIntrospection.collect(_ctx, filename, _crafted)
	var result: Dictionary = await _captures.capture(_runtime(), get_viewport(), filename,
		{"save_path": "%s/%s" % [_base_dir, filename], "metadata": metadata})
	if not result.ok:
		_failures.append("%s: %s (%s)" % [filename, result.kind, result.detail]); return
	_shots.append(filename)


func _settle(frames: int) -> void:
	for _i in range(frames):
		await get_tree().process_frame


func _world() -> Node: return _ctx["world"]
func _player() -> Node: return _ctx["player"]
func _runtime() -> Node: return _ctx["runtime"]
func _message_box() -> Node: return _ctx["message_box"]
