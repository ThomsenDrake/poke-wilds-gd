extends Node

# Deterministic storage-state driver for the visual sweep (Phase 3; spec:
# docs/product-specs/storage-and-party.md). Dispatched STANDALONE from
# qa_scenarios (visual_sweep.gd is at budget; the camping-sweep pattern): stamps
# a storage box beside the fixed spawn at noon for the overworld shot and opens
# the StorageScreen over a deterministic box+party for the screen shot, then
# reconciles ONLY its own shots — the update pass copies its captures WITHOUT
# pruning other sweeps' baselines (the main sweep owns the full-set prune,
# guarded by the shared _foreign_shot set). Determinism: every state is crafted,
# never rolled (seed 2026072404, noon clock, fixed party/bag, first-open-site
# ring scan, fixed-level mons), so bytes change only with an explicit baseline
# update. Shot numbers continue after camping's 15-17 (09-12 stay
# battle-reserved per the sidecar canary contract). A missing StorageScreen node
# skips gracefully, never a push_error.

const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")
const VisualSweepBaselines := preload("res://scripts/app/visual_sweep_baselines.gd")
const SnapshotCapture := preload("res://scripts/app/snapshot_capture.gd")
const RenderIntrospection := preload("res://scripts/app/render_introspection.gd")

const SITE_RADIUS := 12
const DEFAULT_THRESHOLD_PCT := 0.5
const CRAFTED_STATE := {
	"world_seed": 2026072404,
	"time_of_day": 720, # noon
	"party": [["DECIDUEYE", 20], ["CHIKORITA", 5]],
	"bag": {"log": 4} # the box costs 2 Log; the spare keeps the sidecar honest
}
const SHOT_BOX := "18_storage_box.png"
const SHOT_SCREEN := "19_storage_screen.png"
# Neither mon can Cut, so the witness guard can never refuse the screen-shot deposit.
const SCREEN_PARTY := ["MACHOP", "ABRA"]

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
var _box_tile := Vector2i.ZERO


func run_sweep(ctx: Dictionary, options: Dictionary = {}) -> void:
	_ctx = ctx
	_crafted = CRAFTED_STATE.duplicate(true)
	_mode = str(options.get("mode", VisualSweepBaselines.MODE_COMPARE))
	_threshold_pct = float(options.get("threshold_pct", DEFAULT_THRESHOLD_PCT))
	_base_dir = _baselines.resolve_shot_dir()
	if _base_dir.is_empty():
		_runtime().warn("SmokeScenarios", "Storage sweep found no writable screenshot directory.", {})
		return
	_baselines.clear_shots(_base_dir)
	if not _baselines.craft_state(_ctx, _runner, CRAFTED_STATE):
		push_error("Storage sweep could not craft its deterministic state; species catalog incomplete.")
		return
	var previous_window := _baselines.apply_canonical_window_size()
	await _settle(5)
	var saved_chance: float = _player().encounter_chance
	_player().encounter_chance = 0.0
	var party_before: Array = _runner.swap_party(_runtime(), ["MACHOP"]) # Build-capable for the placement
	await _storage_box_shot()
	_runner.restore_party(_runtime(), party_before)
	await _storage_screen_shot()
	_player().encounter_chance = saved_chance
	_baselines.restore_window_size(previous_window)
	_finish()


# A placed storage box near the spawn at noon; the bump into it turns the avatar
# to face it. The site scan guarantees an open tile: a refusal is a real bug.
func _storage_box_shot() -> void:
	var runtime = _runtime()
	var site := _find_open_site(_player().tile_position)
	if site == Vector2i.ZERO:
		runtime.warn("VisualSweepStorage", "No open tile near spawn; storage-box shot skipped.", {"seed": runtime.get_world_seed()})
		return
	var result: Dictionary = runtime.build_runtime.try_place(site, "storage_box", {})
	if not bool(result.get("ok", false)):
		push_error("visual_sweep_storage: storage box refused at %s (%s); the shot would be wrong" % [str(site), str(result.get("reason", ""))])
		return
	_box_tile = site
	_crafted["box_tile"] = [site.x, site.y]
	_runner.teleport_player(_world(), _player(), runtime, site + Vector2i(0, 1))
	_player().smoke_step(Vector2i.UP)
	_world().set_time_of_day(int(CRAFTED_STATE["time_of_day"]))
	_world().sync_visible(_player().tile_position)
	await _capture(SHOT_BOX)


# The StorageScreen over a deterministic box (one ABRA) + party (one MACHOP).
func _storage_screen_shot() -> void:
	var runtime = _runtime()
	var screen := _message_box().get_node_or_null("../StorageScreen")
	if _box_tile == Vector2i.ZERO or screen == null or not screen.has_method("open_screen"):
		runtime.warn("VisualSweepStorage", "No box/StorageScreen for the screen shot; skipped.", {})
		return
	var crafted_party: Array = runtime.session.party
	_runner.swap_party(runtime, SCREEN_PARTY)
	var deposited: Dictionary = runtime.storage_runtime.deposit(_box_tile, 1) # ABRA -> box; MACHOP stays
	if not bool(deposited.get("ok", false)):
		push_error("visual_sweep_storage: screen-shot deposit refused (%s)" % str(deposited.get("reason", "")))
	else:
		_crafted["box_contents"] = ["ABRA"]; _crafted["party_shown"] = ["MACHOP"]
		screen.open_screen(_box_tile)
		await _capture(SHOT_SCREEN)
		screen.close_screen()
	runtime.session.party = crafted_party # the swap's throwaway SCREEN_PARTY mons never ride the save guard


# First open tile in ring order around `center` (walkable, no prop, no placement).
func _find_open_site(center: Vector2i) -> Vector2i:
	for radius in range(1, SITE_RADIUS + 1):
		for tile in _runner.ring_around(center, radius):
			var logic: Dictionary = _world().get_tile_logic(tile)
			if bool(logic.get("walkable", false)) and str(logic.get("prop_path", "")).is_empty() \
				and str(logic.get("structure_id", "")).is_empty():
				return tile
	return Vector2i.ZERO


func _finish() -> void:
	if not _failures.is_empty():
		push_error("Storage sweep failed captures: %s" % "; ".join(PackedStringArray(_failures)))
		return
	if _shots.is_empty():
		_runtime().warn("SmokeScenarios", "Storage sweep captured no shots; nothing verified.", {})
		return
	# Update pass (or a first run with missing baselines) copies ONLY this
	# sweep's shots + sidecars into the shared baseline dir — never prunes other
	# sweeps' baselines; the shared reconcile then runs compare-mode over the
	# shots dir, which holds exactly this run's captures.
	if _mode == VisualSweepBaselines.MODE_UPDATE or not _missing_baselines().is_empty():
		var errors := _copy_baselines()
		if not errors.is_empty():
			push_error("Storage sweep baseline update failed: %s" % "; ".join(PackedStringArray(errors)))
			return
		_baselines_copied = true
	var result: Dictionary = _baselines.reconcile(_shots, _base_dir, VisualSweepBaselines.MODE_COMPARE, _threshold_pct)
	# The shared differ contracts the WHOLE baseline dir — the other sweeps'
	# baselines always trip its uncaptured flag here; rescope to THIS sweep.
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
			push_error("Storage sweep drift on %s: %s%% of pixels changed (threshold %s%%)." % [shot, per_shot.get(shot, "?"), _threshold_pct])
		for message in result.get("errors", []):
			push_error("Storage sweep diff error: %s" % message)
		return
	_runtime().emit_trace("visual_sweep_storage_passed", "SmokeScenarios", {
		"shots": _shots, "mode": str(result.get("mode", VisualSweepBaselines.MODE_COMPARE)),
		"auto_update": _baselines_copied, "compared": int(result.get("compared", 0)),
		"mismatched": result.get("mismatched", []), "max_drift_pct": float(result.get("max_drift_pct", 0.0)),
		"threshold_pct": _threshold_pct, "base_dir": _base_dir, "crafted": _crafted,
		"sidecar_paths": _shots.map(func(shot_name): return "%s/%s%s" % [_base_dir, shot_name, RenderIntrospection.SIDECAR_SUFFIX])
	})


func _missing_baselines() -> Array:
	var missing: Array = []
	for shot in _shots:
		if not FileAccess.file_exists("%s/%s" % [VisualSweepBaselines.BASELINE_DIR, str(shot)]):
			missing.append(shot)
	return missing


# Copies this sweep's captures + sidecars over the committed baselines; unlike
# VisualSweepBaselines' update path it NEVER prunes (the shared baseline dir
# also holds the main + camping sweeps' shots).
func _copy_baselines() -> Array:
	var errors: Array = []
	if DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(VisualSweepBaselines.BASELINE_DIR)) != OK:
		return ["baseline directory is not writable: %s" % VisualSweepBaselines.BASELINE_DIR]
	for shot in _shots:
		var shot_name := str(shot)
		var err := DirAccess.copy_absolute(
			ProjectSettings.globalize_path("%s/%s" % [_base_dir, shot_name]),
			ProjectSettings.globalize_path("%s/%s" % [VisualSweepBaselines.BASELINE_DIR, shot_name]))
		if err != OK:
			errors.append("could not copy %s into the baseline directory (err %d)" % [shot_name, err])
			continue
		if not RenderIntrospection.copy_sidecar(_base_dir, shot_name, VisualSweepBaselines.BASELINE_DIR):
			errors.append("could not copy the sidecar for %s into the baseline directory (PNG/sidecar desync)" % shot_name)
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


func _world() -> Node: return _ctx["world"]
func _player() -> Node: return _ctx["player"]
func _runtime() -> Node: return _ctx["runtime"]
func _message_box() -> Node: return _ctx["message_box"]
