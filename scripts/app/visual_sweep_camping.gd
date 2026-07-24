extends Node

# Deterministic camping-state driver for the visual sweep (Phase 2 camping
# slice; spec: docs/product-specs/camping-crafting-survival.md). Dispatched
# STANDALONE from qa_scenarios (visual_sweep.gd is at budget): stamps a lit
# campfire + torch beside the fixed spawn at midnight for the night-glow shot
# and opens the CampMenu over a deterministic bag for the craft-menu shot,
# then reconciles ONLY its own shots against the committed baselines — the
# update pass copies its captures WITHOUT pruning other sweeps' baselines (the
# main sweep owns the full-set prune). Determinism contract: every state is
# crafted, never rolled — seed 20260723, midnight clock, fixed party/bag,
# first-open-site ring scan — so bytes change only with an explicit baseline
# update. Shot numbers continue after 14_build_ghost; 09-12 are RESERVED for
# battle shots (check_repo_contracts sidecar canary contract). Shots needing an
# unwired Phase 2 surface skip gracefully, never a push_error.

const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")
const VisualSweepBaselines := preload("res://scripts/app/visual_sweep_baselines.gd")
const SnapshotCapture := preload("res://scripts/app/snapshot_capture.gd")
const RenderIntrospection := preload("res://scripts/app/render_introspection.gd")

const SITE_RADIUS := 12
const DEFAULT_THRESHOLD_PCT := 0.5
const CRAFTED_STATE := {
	"world_seed": 20260723,
	"time_of_day": 0, # midnight: the same bound as the main sweep's 04_night
	"party": [["DECIDUEYE", 20], ["CHIKORITA", 5]],
	"bag": {"magnet": 2, "hard_shell": 2, "silky_thread": 3, "soft_feather": 3, "log": 5}
}
const SHOT_NIGHT := "15_camp_night_lit.png"
const SHOT_MENU := "16_craft_menu.png"

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
		_runtime().warn("SmokeScenarios", "Camping sweep found no writable screenshot directory.", {})
		return
	_baselines.clear_shots(_base_dir)
	if not _baselines.craft_state(_ctx, _runner, CRAFTED_STATE):
		push_error("Camping sweep could not craft its deterministic state; species catalog incomplete.")
		return
	var previous_window := _baselines.apply_canonical_window_size()
	await _settle(5)
	var saved_chance: float = _player().encounter_chance
	_player().encounter_chance = 0.0
	var party_before: Array = _runner.swap_party(_runtime(), ["MACHOP"])
	await _camp_night_shot()
	await _craft_menu_shot()
	_runner.restore_party(_runtime(), party_before)
	_player().encounter_chance = saved_chance
	_baselines.restore_window_size(previous_window)
	_finish()


# Lit campfire + torch near the spawn at midnight: warm static glow over the
# night tint. The grants fund BOTH placements exactly: +5 log / +3 dry_soil
# leaves the spec's shot-16 bag (log 5) after campfire (4/2) + torch (1/1).
func _camp_night_shot() -> void:
	var runtime = _runtime()
	runtime.session.add_item("log", 5)
	runtime.session.add_item("dry_soil", 3)
	var site := _find_open_site(_player().tile_position)
	if site.is_empty():
		runtime.warn("VisualSweepCamping", "No open campsite pair near spawn; night-glow shot skipped.", {"seed": runtime.get_world_seed()})
		return
	var fire_tile: Vector2i = site["fire"]
	var torch_result: Dictionary = runtime.build_runtime.try_place(site["torch"], "torch", {})
	if not bool(torch_result.get("ok", false)):
		runtime.warn("VisualSweepCamping", "Torch placement refused; stamped the glow shot without it.", {"reason": str(torch_result.get("reason", ""))})
	var fire_result: Dictionary = runtime.build_runtime.try_place(fire_tile, "campfire", {})
	if not bool(fire_result.get("ok", false)):
		# The site scan guarantees open, funded tiles: a refusal is a real bug.
		push_error("visual_sweep_camping: campfire refused at %s (%s); the glow shot would be wrong" % [str(fire_tile), str(fire_result.get("reason", ""))])
		return
	# Frame the fire from the south; the bump into it turns the avatar to face it.
	_runner.teleport_player(_world(), _player(), runtime, fire_tile + Vector2i(0, 1))
	_player().smoke_step(Vector2i.UP)
	_world().set_time_of_day(0)
	_world().sync_visible(_player().tile_position)
	await _capture(SHOT_NIGHT)


func _craft_menu_shot() -> void:
	var menu := _message_box().get_node_or_null("../CampMenu")
	if menu == null or not menu.has_method("open_menu"):
		_runtime().warn("VisualSweepCamping", "CampMenu node missing; craft-menu shot skipped.", {})
		return
	if _runtime().get("crafting_runtime") == null:
		_runtime().warn("VisualSweepCamping", "Crafting runtime not wired; craft-menu shot skipped.", {})
		return
	menu.open_menu(_player().facing_tile(), "campfire")
	await _capture(SHOT_MENU)
	menu.close_menu()


# First open-tile pair in ring order around `center`; never south of the fire.
func _find_open_site(center: Vector2i) -> Dictionary:
	for radius in range(1, SITE_RADIUS + 1):
		for tile in _runner.ring_around(center, radius):
			for offset in [Vector2i.RIGHT, Vector2i.LEFT, Vector2i.UP]:
				if _open(tile) and _open(tile + offset) and _open(tile + Vector2i(0, 1)):
					return {"fire": tile, "torch": tile + offset}
	return {}


func _open(tile: Vector2i) -> bool:
	var logic: Dictionary = _world().get_tile_logic(tile)
	return bool(logic.get("walkable", false)) and str(logic.get("prop_path", "")).is_empty() \
		and str(logic.get("structure_id", "")).is_empty()


func _finish() -> void:
	if not _failures.is_empty():
		push_error("Camping sweep failed captures: %s" % "; ".join(PackedStringArray(_failures)))
		return
	if _shots.is_empty():
		_runtime().warn("SmokeScenarios", "Camping sweep captured no shots; nothing verified.", {})
		return
	# Update pass (or a first run with missing baselines) copies ONLY this
	# sweep's shots + sidecars into the shared baseline dir — never prunes
	# other sweeps' baselines; the shared reconcile then runs compare-mode
	# over the shots dir, which holds exactly this run's captures.
	if _mode == VisualSweepBaselines.MODE_UPDATE or not _missing_baselines().is_empty():
		var errors := _copy_baselines()
		if not errors.is_empty():
			push_error("Camping sweep baseline update failed: %s" % "; ".join(PackedStringArray(errors)))
			return
		_baselines_copied = true
	var result: Dictionary = _baselines.reconcile(_shots, _base_dir, VisualSweepBaselines.MODE_COMPARE, _threshold_pct)
	# The shared differ contracts the WHOLE baseline dir — the main sweep's
	# baselines always trip its uncaptured flag here; rescope to THIS sweep:
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
			push_error("Camping sweep drift on %s: %s%% of pixels changed (threshold %s%%)." % [shot, per_shot.get(shot, "?"), _threshold_pct])
		for message in result.get("errors", []):
			push_error("Camping sweep diff error: %s" % message)
		return
	_runtime().emit_trace("visual_sweep_camping_passed", "SmokeScenarios", {
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
# also holds the main sweep's shots).
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
