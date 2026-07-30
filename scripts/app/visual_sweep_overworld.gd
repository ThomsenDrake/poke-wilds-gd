extends Node

# Deterministic overworld-mon driver for the visual sweep (Phase 6; spec: docs/product-specs/
# overworld-pokemon.md § Smoke validation). STANDALONE: a seeded walk band with live roamers (22),
# a seeded nest — ring + eggs + Alpha guardian (23), and night×entities×tint at tod=0 (30; the
# main sweep's 04_night is entity-inert). Reconciles ONLY its own shots (shared _foreign_shot guard
# DERIVES from SHOT_REGISTRY; update never prunes). NO rng in the capture path: byte-stable; entities opted IN, captures WAIT on the entity-rest + player-lerp probe (sidecar-stamped).

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
const SHOT_NIGHT_ROAMERS := "30_night_roamers.png"

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
	await _night_roamers_shot()
	_set_entities_active(saved_active)
	_player().encounter_chance = saved_chance
	_baselines.restore_window_size(previous_window)
	_finish()


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


func _night_roamers_shot() -> void:
	_crafted["night_tile"] = [_player().tile_position.x, _player().tile_position.y]
	_world().set_time_of_day(0)
	_world().sync_visible(_player().tile_position)
	await _capture(SHOT_NIGHT_ROAMERS)


# Runtime nest finder (domain roll owned below the app): first nest cell in range, else ZERO.
func _find_nest_center() -> Vector2i:
	var runtime := _runtime()
	var mons: Object = runtime.get("overworld_mons_runtime") if runtime != null and "overworld_mons_runtime" in runtime else null
	if mons == null or not mons.has_method("find_nest_center_near"):
		return Vector2i.ZERO
	var result: Variant = mons.call("find_nest_center_near", _player().tile_position, NEST_SCAN_RADIUS)
	return result if result is Vector2i else Vector2i.ZERO


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
	# Update (or missing baselines) copies ONLY this sweep's shots; reconcile then compares.
	if _mode == VisualSweepBaselines.MODE_UPDATE or not _missing_baselines().is_empty():
		var errors := _copy_baselines()
		if not errors.is_empty():
			push_error("Overworld sweep baseline update failed: %s" % "; ".join(PackedStringArray(errors)))
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
			push_error("Overworld sweep drift on %s: %s%% of pixels changed (threshold %s%%)." % [shot, per_shot.get(shot, "?"), _threshold_pct])
		for message in result.get("errors", []):
			push_error("Overworld sweep diff error: %s" % message)
		_runtime().emit_trace("visual_sweep_overworld_failed", "SmokeScenarios", {"mismatched": result.get("mismatched", []), "per_shot_pct": per_shot, "errors": result.get("errors", []), "threshold_pct": _threshold_pct}) # miss-002 loudness: drift names its shots + percentages in the trace, never stderr-only
		return
	_runtime().emit_trace("visual_sweep_overworld_passed", "SmokeScenarios", {
		"shots": _shots, "mode": str(result.get("mode", VisualSweepBaselines.MODE_COMPARE)),
		"auto_update": _baselines_copied, "compared": int(result.get("compared", 0)),
		"mismatched": result.get("mismatched", []), "max_drift_pct": float(result.get("max_drift_pct", 0.0)),
		"threshold_pct": _threshold_pct, "base_dir": _base_dir, "crafted": _crafted,
		"sidecar_paths": _shots.map(func(shot_name): return "%s/%s%s" % [_base_dir, shot_name, RenderIntrospection.SIDECAR_SUFFIX])
	})


func _missing_baselines() -> Array:
	return _shots.filter(func(shot): return not FileAccess.file_exists("%s/%s" % [VisualSweepBaselines.BASELINE_DIR, str(shot)]))


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
		{"save_path": "%s/%s" % [_base_dir, filename], "metadata": metadata, "rest_probe": Callable(self, "_rest_state")})
	if not result.ok:
		_failures.append("%s: %s (%s)" % [filename, result.kind, result.detail])
		return
	_shots.append(filename)


# Capture-rest probe (SnapshotCapture waits + stamps it): entities at rest = two identical
# position samples; player done = not mid-step; inactive layer = rest (nothing can move).
var _rest_sample := {}

func _rest_state() -> Dictionary:
	var at_rest := true
	var scene: Node = get_tree().current_scene
	var layer: Node = scene.get_node_or_null("EntityLayer") if scene != null else null
	# "active" lives on the RUNTIME, never the layer: Node.get of a missing property is Nil, and Godot 4.6 has no bool(Nil) constructor (the 600s rest-probe crash).
	var mons: Object = _runtime().get("overworld_mons_runtime")
	if layer != null and mons != null and bool(mons.get("active")):
		var nodes: Dictionary = layer.get("_entity_nodes")
		var sample := {}
		for id in nodes:
			var sprite: Sprite2D = (nodes[id] as Dictionary).get("sprite")
			if sprite != null:
				sample[id] = sprite.position
		at_rest = not _rest_sample.is_empty() and sample == _rest_sample
		_rest_sample = sample
	return {"entities_at_rest": at_rest, "player_lerp_complete": not _player().is_moving()}


func _settle(frames: int) -> void:
	for _i in range(frames):
		await get_tree().process_frame


func _world() -> Node: return _ctx["world"]
func _player() -> Node: return _ctx["player"]
func _runtime() -> Node: return _ctx["runtime"]
func _message_box() -> Node: return _ctx["message_box"]
