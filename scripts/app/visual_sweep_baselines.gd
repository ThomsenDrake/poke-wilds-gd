extends RefCounted

# File, diff, and state-crafting plumbing for VisualSweep: crafts the session
# state, finds a writable shots dir, clears stale captures, syncs the committed
# baselines (update mode) or shells out to tools/visual_diff.py (compare mode).
# The baseline dir is SHARED with visual_sweep_camping (its 15-17 shots).

const RenderIntrospection := preload("res://scripts/app/render_introspection.gd")

const PREFERRED_SHOT_DIR := "res://.godot-smoke/shots"
const FALLBACK_SHOT_DIR := "user://visual_shots"
const BASELINE_DIR := "res://docs/generated/visual-baselines"
const DIFF_TOOL := "res://tools/visual_diff.py"
const PYTHON_BIN := "python3"

const MODE_COMPARE := "compare"
const MODE_UPDATE := "update"

# Canonical capture window so baselines stay window-size-stable.
const CANONICAL_WINDOW_SIZE := Vector2i(1152, 648)


# Resizes to CANONICAL_WINDOW_SIZE, returning the prior size (headless: no-op).
func apply_canonical_window_size() -> Vector2i:
	var previous := DisplayServer.window_get_size()
	if DisplayServer.get_name() != "headless":
		DisplayServer.window_set_size(CANONICAL_WINDOW_SIZE)
	return previous


func restore_window_size(previous: Vector2i) -> void:
	if DisplayServer.get_name() != "headless" and previous.x > 0 and previous.y > 0:
		DisplayServer.window_set_size(previous)


# Crafts fixed session state (save payload + boot-load normalization; the
# dispatcher's save-guard restores the real save). False = unknown species id.
func craft_state(ctx: Dictionary, runner, spec: Dictionary) -> bool:
	var runtime = ctx["runtime"]
	var party: Array = []
	for entry_spec in spec["party"]:
		var entry: Dictionary = runtime.catalog.get_species(str(entry_spec[0]))
		if entry.is_empty():
			return false
		party.append(runtime.pokemon_rules.create_pokemon_instance(entry, int(entry_spec[1]), Callable(runtime.catalog, "get_move")))
	var spawn: Vector2i = runtime._world_gen.find_walkable_spawn(int(spec["world_seed"]))
	var payload := {
		"version": 2, "world_seed": spec["world_seed"],
		"player_x": spawn.x, "player_y": spawn.y,
		"party": party, "bag": spec["bag"].duplicate(),
		"time_of_day_minutes": spec["time_of_day"], "total_steps": 0,
		"unlocked_field_moves": []
	}
	runtime.save_store.write_payload(payload)
	var normalized := party.map(func(m): return runtime.pokemon_rules.normalize_loaded_mon(m))
	runtime.session.apply_loaded_state(payload, normalized)
	# Wipe leftover clears+placements so the crafted world is a pure function of the seed.
	runtime._world_gen.clear_overrides()
	runtime._world_gen.clear_placements()
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


# Reconcile + report: push_error per drift/error/lost shot, else visual_sweep_passed.
func report(runtime, shots: Array, base_dir: String, mode: String, threshold_pct: float, dup_checked: int = 0, invalid: int = 0) -> void:
	var result: Dictionary = reconcile(shots, base_dir, mode, threshold_pct)
	# The baseline dir is shared with visual_sweep_camping: its 15-17 baselines
	# never have captures in THIS sweep, so their uncaptured flag is not a failure
	# (symmetric mirror of the camping sweep rescoping ours). Own lost shots stay loud.
	var lost: Array = []
	for shot in result.get("uncaptured_baselines", []):
		if not _foreign_shot(str(shot)):
			lost.append(str(shot))
	if not bool(result.get("ok", false)) and lost.is_empty() and (result.get("mismatched", []) as Array).is_empty() and (result.get("errors", []) as Array).is_empty():
		result["ok"] = true # the differ tripped only on the other sweep's baselines
	if not bool(result.get("ok", false)):
		var per_shot: Dictionary = result.get("per_shot", {})
		for shot in result.get("mismatched", []):
			push_error("Visual sweep drift on %s: %s%% of pixels changed (threshold %s%%)." % [shot, per_shot.get(shot, "?"), threshold_pct])
		for message in result.get("errors", []):
			push_error("Visual sweep diff error: %s" % message)
		for shot in lost:
			push_error("Visual sweep lost a shot: baseline %s has no capture this run." % shot)
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
		"foreign_uncaptured": result.get("uncaptured_baselines", []),
		"base_dir": base_dir,
		"window": [CANONICAL_WINDOW_SIZE.x, CANONICAL_WINDOW_SIZE.y],
		"dup_checked": dup_checked,
		"invalid_captures": invalid,
		"sidecar_paths": shots.map(func(shot_name): return "%s/%s%s" % [base_dir, shot_name, RenderIntrospection.SIDECAR_SUFFIX])
	})


# Compare: diff vs baselines via tools/visual_diff.py. Update (or any baseline
# missing): copy captures over the baselines, pruning stale entries. Keys: ok,
# mode, auto_update, compared, mismatched, max_drift_pct, per_shot, errors.
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


# Removes stale PNGs + sidecars so only this run's captures get diffed/copied.
func clear_shots(shot_dir: String) -> void:
	var dir := DirAccess.open(ProjectSettings.globalize_path(shot_dir))
	if dir == null:
		return
	for filename in dir.get_files():
		if filename.ends_with(".png") or filename.ends_with(RenderIntrospection.SIDECAR_SUFFIX):
			dir.remove(filename)


func _missing_baselines(shots: Array) -> Array:
	var missing: Array = []
	for shot in shots:
		if not FileAccess.file_exists("%s/%s" % [BASELINE_DIR, str(shot)]):
			missing.append(shot)
	return missing


# Baselines the shared dir holds for the OTHER sweep (camping owns 15-17;
# numbering contract: 09-12 battle-reserved, 13-14 build, 15-17 camping).
static func _foreign_shot(name: String) -> bool:
	return name.begins_with("15_") or name.begins_with("16_") or name.begins_with("17_")


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
		# Copy failed after the PNG advanced: fail rather than strand a stale sidecar.
		if not RenderIntrospection.copy_sidecar(shot_dir, shot_name, BASELINE_DIR):
			return {"ok": false, "errors": ["could not copy the sidecar for %s into the baseline directory (PNG/sidecar desync)" % shot_name]}
		updated.append(shot_name)
	var pruned: Array = []
	var dir := DirAccess.open(ProjectSettings.globalize_path(BASELINE_DIR))
	if dir != null:
		for filename in dir.get_files():
			if filename.ends_with(".png") and not shots.has(filename) and not _foreign_shot(filename):
				dir.remove(filename)
				pruned.append(filename)
	pruned.append_array(RenderIntrospection.prune_sidecars(BASELINE_DIR, shots, _foreign_shot))
	return {
		"ok": true, "mode": MODE_UPDATE, "auto_update": auto_update,
		"updated": updated, "pruned": pruned, "compared": 0,
		"mismatched": [], "max_drift_pct": 0.0
	}


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


func await_battle_idle(tree: SceneTree, view: Node) -> void:
	for _i in range(240):
		if not view.visible or not view.is_animating():
			break
		await tree.process_frame
	await tree.process_frame
