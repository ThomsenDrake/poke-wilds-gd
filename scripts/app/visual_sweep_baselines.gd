extends RefCounted

# File, diff, and state-crafting plumbing for VisualSweep: crafts the session
# state, finds a writable shots dir, clears stale captures, syncs the committed
# baselines (update mode) or shells out to tools/visual_diff.py (compare mode).
# The baseline dir is SHARED with visual_sweep_camping (its 15-17 shots).

const RenderIntrospection := preload("res://scripts/app/render_introspection.gd")
const RegistrySupport := preload("res://scripts/app/visual_sweep_registry_support.gd") # R3 registry helpers (app-220 extraction)

const PREFERRED_SHOT_DIR := "res://.godot-smoke/shots"
const FALLBACK_SHOT_DIR := "user://visual_shots"
const BASELINE_DIR := "res://docs/generated/visual-baselines"
const DIFF_TOOL := "res://tools/visual_diff.py"
const PYTHON_BIN := "python3"

const MODE_COMPARE := "compare"
const MODE_UPDATE := "update"

# Canonical capture window so baselines stay window-size-stable.
const CANONICAL_WINDOW_SIZE := Vector2i(1152, 648)

# Single-sourced shot numbering (check_repo_contracts parses this literal): per-sweep
# number ranges + per-sweep crafted seeds + retired holes. The satellite foreign-shot
# guards DERIVE from it via _foreign_shot, never hand-listed prefixes. "main" owns the
# battle-reserved 09-12 + build 13-14 inside its range; 17 is camping-reserved but was
# never committed -- the sole whitelisted numbering gap.
const SHOT_REGISTRY := {
	"main": {"range": [1, 14], "extra": [24, 25, 28, 29, 37, 38, 39, 40, 41], "seed": 20260717}, # 37-41 title/creation (restyle wave 0)
	"camping": {"range": [15, 16], "seed": 20260723},
	"storage": {"range": [18, 19], "seed": 2026072404},
	"pokemon": {"range": [20, 21], "seed": 2026072605},
	"overworld": {"range": [22, 23], "extra": [30], "seed": 2026072722},
	"fishing": {"range": [26, 27], "seed": 2026072804},
	"world_depth": {"range": [31, 32], "extra": [34, 44, 45], "seed": 2026072907}, # 33 (beacons) retired with world chaining; 44/45 the legendary-dungeon frames
	"farfield": {"range": [42, 42], "seed": 2026072908}, # Track A.3; 43 (the far-lair shot) retired with the lairs (legendary-dungeon slice)
	"retired": [17, 33, 35, 36, 43], # 35/36 (chained world) + 33 (beacons) retired with world chaining; 43 (far lair) retired with the lairs
}


# Every shot number a sweep owns: its range (inclusive) plus any extras.
static func shot_numbers(sweep: String) -> Array:
	var entry: Dictionary = SHOT_REGISTRY.get(sweep, {})
	var numbers: Array = []
	var bounds: Array = entry.get("range", [])
	if bounds.size() == 2:
		for number in range(int(bounds[0]), int(bounds[1]) + 1):
			numbers.append(number)
	numbers.append_array(entry.get("extra", []))
	return numbers


# R3 registry helpers live in visual_sweep_registry_support.gd (extracted at the app-220 wall); these
# thin forwarders keep the six satellite call sites unchanged (the dict arg avoids a preload cycle).
static func registry_seed(sweep: String) -> int:
	return RegistrySupport.registry_seed_for(SHOT_REGISTRY, sweep)


func crafted_state(sweep: String, base: Dictionary) -> Dictionary:
	return RegistrySupport.crafted_state_for(SHOT_REGISTRY, sweep, base)


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
	var spec_seed: int = int(spec["world_seed"])
	RegistrySupport.pin_craft_world(runtime, spec_seed) # before spawn: session seed + empty mutations
	var spawn: Vector2i = runtime._world_gen.find_walkable_spawn(spec_seed)
	var payload := {
		"version": 2, "world_seed": spec_seed,
		"player_x": spawn.x, "player_y": spawn.y,
		"party": party, "bag": spec["bag"].duplicate(),
		"time_of_day_minutes": spec["time_of_day"], "total_steps": 0,
		"unlocked_field_moves": []
	}
	runtime.save_store.write_payload(payload)
	var normalized := party.map(func(m): return runtime.pokemon_rules.normalize_loaded_mon(m))
	runtime.session.apply_loaded_state(payload, normalized)
	ctx["world"].rebuild(spec_seed)
	runner.teleport_player(ctx["world"], ctx["player"], runtime, spawn)
	ctx["world"].set_time_of_day(int(spec["time_of_day"]))
	ctx["message_box"].hide_message()
	return true


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


# Baselines the shared dir holds for OTHER sweeps (derived from SHOT_REGISTRY, MAIN
# INCLUDED: a satellite update must never prune main's 01-14, and main's own update
# carries its live shots in `shots` so its stale-shot prune only loses registry-deleted
# numbers; retired holes stay protected forever): the prune guard keeps each sweep's
# update from deleting the others, the report guard from failing on them.
static func _foreign_shot(name: String) -> bool:
	var number := int(str(name).get_slice("_", 0))
	for sweep in SHOT_REGISTRY:
		if SHOT_REGISTRY[sweep] is Array: # retired holes (bare number list)
			if (SHOT_REGISTRY[sweep] as Array).has(number):
				return true
			continue
		if shot_numbers(sweep).has(number):
			return true
	return false


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


# Shared battle-quiesce wait (display_matrix + the main sweep's battle shots).
func await_battle_idle(tree: SceneTree, view: Node) -> void:
	for _i in range(360):
		if not view.visible or not view.is_animating():
			break
		await tree.process_frame
	await tree.process_frame
