extends RefCounted

# File, diff, and state-crafting plumbing for VisualSweep
# (scripts/app/visual_sweep.gd): crafts the deterministic session state,
# finds a writable shots directory, clears stale captures, syncs the
# committed baselines in update mode, and shells out to tools/visual_diff.py
# in compare mode so the scenario and CI share one diff implementation. Kept
# tree-free; the sweep node owns scene driving and capture timing.

const PREFERRED_SHOT_DIR := "res://.godot-smoke/shots"
const FALLBACK_SHOT_DIR := "user://visual_shots"
const BASELINE_DIR := "res://docs/generated/visual-baselines"
const DIFF_TOOL := "res://tools/visual_diff.py"
const PYTHON_BIN := "python3"

const MODE_COMPARE := "compare"
const MODE_UPDATE := "update"


# Crafts fixed session state so every run renders identical frames: written
# as a save payload (the dispatcher's save-guard restores the real save) and
# applied through the same normalization path as a boot-time load. The spawn
# tile comes from GameRuntime's generator for the fixed seed, mirroring
# new-game spawn selection. Returns false when a species id is unknown.
func craft_state(ctx: Dictionary, runner, spec: Dictionary) -> bool:
	var runtime = ctx["runtime"]
	var move_lookup = Callable(runtime.catalog, "get_move")
	var party: Array = []
	for entry_spec in spec["party"]:
		var entry: Dictionary = runtime.catalog.get_species(str(entry_spec[0]))
		if entry.is_empty():
			return false
		party.append(runtime.pokemon_rules.create_pokemon_instance(entry, int(entry_spec[1]), move_lookup))
	var spawn: Vector2i = runtime._world_gen.find_walkable_spawn(int(spec["world_seed"]))
	var payload := {
		"version": 2, "world_seed": spec["world_seed"],
		"player_x": spawn.x, "player_y": spawn.y,
		"party": party, "bag": spec["bag"].duplicate(),
		"time_of_day_minutes": spec["time_of_day"], "total_steps": 0,
		"unlocked_field_moves": []
	}
	runtime.save_store.write_payload(payload)
	var normalized: Array = []
	for mon in party:
		normalized.append(runtime.pokemon_rules.normalize_loaded_mon(mon))
	runtime.session.apply_loaded_state(payload, normalized)
	ctx["world"].rebuild(int(spec["world_seed"]))
	runner.teleport_player(ctx["world"], ctx["player"], runtime, spawn)
	ctx["world"].set_time_of_day(int(spec["time_of_day"]))
	ctx["message_box"].hide_message()
	return true


# First lead-party move with power and PP left; falls back to the first slot.
func damaging_move_id(runtime) -> String:
	var party: Array = runtime.get_party_snapshot()
	if not party.is_empty():
		var moves: Array = party[0].get("moves", [])
		for i in range(moves.size()):
			var move: Dictionary = moves[i]
			if int(move.get("power", 0)) > 0 and int(move.get("pp", 0)) > 0:
				return "move_%d" % i
	return "move_0"


# Runs the reconcile and reports: push_error per drift/error and no trace on
# failure, one visual_sweep_passed trace on success.
func report(runtime, shots: Array, base_dir: String, mode: String, threshold_pct: float) -> void:
	var result: Dictionary = reconcile(shots, base_dir, mode, threshold_pct)
	if not bool(result.get("ok", false)):
		var per_shot: Dictionary = result.get("per_shot", {})
		for shot in result.get("mismatched", []):
			push_error("Visual sweep drift on %s: %s%% of pixels changed (threshold %s%%)." % [shot, per_shot.get(shot, "?"), threshold_pct])
		for message in result.get("errors", []):
			push_error("Visual sweep diff error: %s" % message)
		return
	runtime.emit_trace("visual_sweep_passed", "SmokeScenarios", {
		"shots": shots,
		"compared": int(result.get("compared", 0)),
		"mismatched": result.get("mismatched", []),
		"max_drift_pct": float(result.get("max_drift_pct", 0.0)),
		"mode": str(result.get("mode", mode)),
		"auto_update": bool(result.get("auto_update", false)),
		"updated": result.get("updated", []),
		"pruned": result.get("pruned", []),
		"threshold_pct": threshold_pct,
		"base_dir": base_dir
	})


# Compare mode: diff captures against baselines via tools/visual_diff.py.
# Update mode — or compare mode with any baseline missing (first run): copy
# the captures over the baselines and prune entries without a current shot.
# Result keys: ok, mode, auto_update, compared, mismatched, max_drift_pct,
# per_shot, errors, plus updated/pruned on update passes.
func reconcile(shots: Array, shot_dir: String, mode: String, threshold_pct: float) -> Dictionary:
	if mode == MODE_UPDATE or not _missing_baselines(shots).is_empty():
		return _update_baselines(shots, shot_dir, mode != MODE_UPDATE)
	return _compare_with_baselines(shot_dir, threshold_pct)


# First directory that accepts a write probe, "" when neither does.
func resolve_shot_dir() -> String:
	for candidate in [PREFERRED_SHOT_DIR, FALLBACK_SHOT_DIR]:
		if DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(candidate)) != OK:
			continue
		var probe := "%s/.write_probe" % candidate
		var file := FileAccess.open(probe, FileAccess.WRITE)
		if file == null:
			continue
		file.close()
		DirAccess.remove_absolute(ProjectSettings.globalize_path(probe))
		return candidate
	return ""


# Removes stale PNGs so only this run's captures get diffed and copied.
func clear_shots(shot_dir: String) -> void:
	var dir := DirAccess.open(ProjectSettings.globalize_path(shot_dir))
	if dir == null:
		return
	for filename in dir.get_files():
		if filename.ends_with(".png"):
			dir.remove(filename)


func _missing_baselines(shots: Array) -> Array:
	var missing: Array = []
	for shot in shots:
		if not FileAccess.file_exists("%s/%s" % [BASELINE_DIR, str(shot)]):
			missing.append(shot)
	return missing


func _update_baselines(shots: Array, shot_dir: String, auto_update: bool) -> Dictionary:
	if DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(BASELINE_DIR)) != OK:
		return {"ok": false, "errors": ["baseline directory is not writable: %s" % BASELINE_DIR]}
	var updated: Array = []
	for shot in shots:
		var shot_name := str(shot)
		var err := DirAccess.copy_absolute(
			ProjectSettings.globalize_path("%s/%s" % [shot_dir, shot_name]),
			ProjectSettings.globalize_path("%s/%s" % [BASELINE_DIR, shot_name]))
		if err != OK:
			return {"ok": false, "errors": ["could not copy %s into the baseline directory (err %d)" % [shot_name, err]]}
		updated.append(shot_name)
	var pruned: Array = []
	var dir := DirAccess.open(ProjectSettings.globalize_path(BASELINE_DIR))
	if dir != null:
		for filename in dir.get_files():
			if filename.ends_with(".png") and not shots.has(filename):
				dir.remove(filename)
				pruned.append(filename)
	return {
		"ok": true,
		"mode": MODE_UPDATE,
		"auto_update": auto_update,
		"updated": updated,
		"pruned": pruned,
		"compared": 0,
		"mismatched": [],
		"max_drift_pct": 0.0
	}


# Blocking run of the stdlib differ; stdout carries one JSON verdict line.
func _compare_with_baselines(shot_dir: String, threshold_pct: float) -> Dictionary:
	var output: Array = []
	var args := PackedStringArray([
		ProjectSettings.globalize_path(DIFF_TOOL),
		"--shots-dir", ProjectSettings.globalize_path(shot_dir),
		"--baseline-dir", ProjectSettings.globalize_path(BASELINE_DIR),
		"--threshold-pct", str(threshold_pct)])
	var exit_code: int = OS.execute(PYTHON_BIN, args, output)
	var parsed = JSON.parse_string("".join(output))
	if not (parsed is Dictionary):
		return {"ok": false, "errors": ["visual_diff.py gave no JSON verdict (exit %d); is %s on PATH?" % [exit_code, PYTHON_BIN]]}
	var verdict: Dictionary = parsed
	verdict["ok"] = exit_code == 0 and bool(verdict.get("ok", false))
	verdict["mode"] = MODE_COMPARE
	verdict["auto_update"] = false
	return verdict


# Animations play asynchronously after a response; captures must wait them out.
func await_battle_idle(tree: SceneTree, view: Node) -> void:
	for _i in range(240):
		if not view.visible or not view.is_animating():
			break
		await tree.process_frame
	await tree.process_frame
