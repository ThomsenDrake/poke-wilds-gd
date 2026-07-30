extends Node

# Deterministic landmark driver for the visual sweep (Phase 7 Build 1; spec:
# docs/product-specs/world-depth.md § Smoke validation). STANDALONE satellite: the
# Ruins inner chamber with its glowing statue pair (31) + the Mansion room with the
# statue grid and both doors open (32). Footprints are found by PROBING the view's
# tile logic for the resolver's landmark_id stamp (app never preloads domain — the
# roll is owned below the app, visual_sweep_overworld.gd precedent); the puzzle state
# is CRAFTED through the frozen SessionState seam (never the keying, never played live
# at capture) and the door overlay re-stamps on rebuild. Reconciles ONLY its own shots
# (foreign-shot guard DERIVES from SHOT_REGISTRY). NO rng: byte-stable. The entity
# layer stays INERT and encounter_chance is pinned 0, so no pending seam can arm.

const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")
const VisualSweepBaselines := preload("res://scripts/app/visual_sweep_baselines.gd")
const SnapshotCapture := preload("res://scripts/app/snapshot_capture.gd")
const RenderIntrospection := preload("res://scripts/app/render_introspection.gd")

const DEFAULT_THRESHOLD_PCT := 0.5
const RUINS_ID := "desert_ruins" # public contract strings (trace payloads, spec § Landmarks)
const MANSION_ID := "pkmn_mansion"
const RUINS_INNER_TOKEN := "RUINS_INNER"
const MANSION_TOKEN := "PKMNMANSION"
const SPIRAL_CAP := 80 # anchors ring <=48 from origin + <=~10 search drift (budget 400) + <=8 footprint extent
const CRAFTED_STATE := {"world_seed": 2026072907, "time_of_day": 720, "party": [["MACHOP", 30]], "bag": {}} # seed = landmark_flow pin (spec § Pinned constants)
const RUINS_INNER_PLAYER_LOCAL := Vector2i(7, 5)  # chamber center; statue props (6,4)/(8,4) frame above
const MANSION_ROOM_PLAYER_LOCAL := Vector2i(7, 6) # statue row y7 below, both door tiles y5 above
# Puzzle SOLVED via the seam before the shot (runtime-handoff shape; the resolver's door overlay reads it live).
const CRAFTED_MANSION_STATE := {
	MANSION_ID: {"statues": [true, true, true], "unlocked": true, "key_taken": true}
}
const MANSION_DOOR_LOCALS := {"room_door": Vector2i(7, 5), "sewer_door": Vector2i(4, 5)}
const MANSION_STATUE_LOCALS := [Vector2i(6, 7), Vector2i(7, 7), Vector2i(8, 7)]
const SHOT_RUINS_INTERIOR := "31_ruins_interior.png"
const SHOT_MANSION := "32_mansion.png"

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
	_crafted = CRAFTED_STATE.duplicate(true)
	_mode = str(options.get("mode", VisualSweepBaselines.MODE_COMPARE))
	_threshold_pct = float(options.get("threshold_pct", DEFAULT_THRESHOLD_PCT))
	_base_dir = _baselines.resolve_shot_dir()
	if _base_dir.is_empty():
		_runtime().warn("SmokeScenarios", "World depth sweep found no writable screenshot directory.", {}); return
	_baselines.clear_shots(_base_dir)
	if not _baselines.craft_state(_ctx, _runner, CRAFTED_STATE):
		push_error("World depth sweep could not craft its deterministic state; catalog incomplete."); return
	var previous_window := _baselines.apply_canonical_window_size()
	await _settle(5)
	var saved_chance: float = _player().encounter_chance
	_player().encounter_chance = 0.0 # no grass battles (and no wild-stream draw) during capture
	await _ruins_shot()
	await _mansion_shot()
	_player().encounter_chance = saved_chance
	_baselines.restore_window_size(previous_window)
	_finish()


func _ruins_shot() -> void:
	var footprint := _find_footprint(RUINS_ID)
	if footprint.size == Vector2i.ZERO:
		_failures.append("%s: no %s stamp within spiral cap %d (anchor seam broken)" % [SHOT_RUINS_INTERIOR, RUINS_ID, SPIRAL_CAP]); return
	var tile: Vector2i = footprint.position + RUINS_INNER_PLAYER_LOCAL
	var logic: Dictionary = _world().get_tile_logic(tile)
	if str(logic.get("encounter_token", "")) != RUINS_INNER_TOKEN:
		_failures.append("%s: camera tile %s token '%s' != '%s' (domain layout drift)" % [SHOT_RUINS_INTERIOR, tile, logic.get("encounter_token", ""), RUINS_INNER_TOKEN]); return
	_crafted["ruins_footprint"] = [footprint.position.x, footprint.position.y, footprint.size.x, footprint.size.y]
	_crafted["ruins_inner_tile"] = [tile.x, tile.y]
	_runner.teleport_player(_world(), _player(), _runtime(), tile)
	_world().set_time_of_day(int(CRAFTED_STATE["time_of_day"]))
	_world().sync_visible(tile)
	await _capture(SHOT_RUINS_INTERIOR)


func _mansion_shot() -> void:
	var footprint := _find_footprint(MANSION_ID)
	if footprint.size == Vector2i.ZERO:
		_failures.append("%s: no %s stamp within spiral cap %d (anchor seam broken)" % [SHOT_MANSION, MANSION_ID, SPIRAL_CAP]); return
	var tile: Vector2i = footprint.position + MANSION_ROOM_PLAYER_LOCAL
	var logic: Dictionary = _world().get_tile_logic(tile)
	if str(logic.get("encounter_token", "")) != MANSION_TOKEN or not bool(logic.get("walkable", false)):
		_failures.append("%s: camera tile %s token '%s'/walkable %s unexpected (domain layout drift)" % [SHOT_MANSION, tile, logic.get("encounter_token", ""), logic.get("walkable")]); return
	# Craft the SOLVED puzzle through the frozen seam (never the keying), then rebuild
	# so the resolver's door overlay re-stamps both doors open through the tile cache.
	_runtime().session.set_landmark_state(Vector2i.ZERO, CRAFTED_MANSION_STATE.duplicate(true))
	_world().rebuild(int(CRAFTED_STATE["world_seed"]))
	for door_region in MANSION_DOOR_LOCALS:
		var door_tile: Vector2i = footprint.position + MANSION_DOOR_LOCALS[door_region]
		if not bool(_world().get_tile_logic(door_tile).get("walkable", false)):
			_failures.append("%s: %s at %s stayed sealed after seam-crafted solved state (overlay broken)" % [SHOT_MANSION, door_region, door_tile]); return
	for statue_local in MANSION_STATUE_LOCALS:
		var statue: Dictionary = _world().get_tile_logic(footprint.position + statue_local)
		if bool(statue.get("walkable", true)) or str(statue.get("prop_path", "")) == "":
			_failures.append("%s: statue at local %s lost its solid prop (domain layout drift)" % [SHOT_MANSION, statue_local]); return
	_crafted["mansion_footprint"] = [footprint.position.x, footprint.position.y, footprint.size.x, footprint.size.y]
	_crafted["mansion_room_tile"] = [tile.x, tile.y]
	_crafted["mansion_state"] = (CRAFTED_MANSION_STATE as Dictionary)[MANSION_ID]
	_runner.teleport_player(_world(), _player(), _runtime(), tile)
	_world().set_time_of_day(int(CRAFTED_STATE["time_of_day"]))
	_world().sync_visible(tile)
	await _capture(SHOT_MANSION)


# Footprint discovery: spiral from the world origin (anchors ring around it — domain
# roll, probed through the view) for the first tile with the resolver's landmark_id
# stamp, then walk the stamp out to the rect. Deterministic in the seed; ZERO on cap
# exhaustion (loud-failed by the caller, never silent).
func _find_footprint(landmark_id: String) -> Rect2i:
	for radius in range(SPIRAL_CAP + 1):
		for cell in _spiral_ring(radius):
			if _stamped(cell, landmark_id):
				return _expand_footprint(landmark_id, cell)
	return Rect2i()


func _spiral_ring(radius: int) -> Array:
	if radius == 0:
		return [Vector2i.ZERO]
	var cells: Array = []
	for i in range(-radius, radius + 1):
		cells.append_array([Vector2i(i, -radius), Vector2i(i, radius), Vector2i(-radius, i), Vector2i(radius, i)])
	return cells


func _expand_footprint(landmark_id: String, hit: Vector2i) -> Rect2i:
	var min_x := hit.x
	var max_x := hit.x
	var min_y := hit.y
	var max_y := hit.y
	while _stamped(Vector2i(min_x - 1, hit.y), landmark_id): min_x -= 1
	while _stamped(Vector2i(max_x + 1, hit.y), landmark_id): max_x += 1
	while _stamped(Vector2i(hit.x, min_y - 1), landmark_id): min_y -= 1
	while _stamped(Vector2i(hit.x, max_y + 1), landmark_id): max_y += 1
	return Rect2i(min_x, min_y, max_x - min_x + 1, max_y - min_y + 1)


func _stamped(tile: Vector2i, landmark_id: String) -> bool:
	return str(_world().get_tile_logic(tile).get("landmark_id", "")) == landmark_id


func _finish() -> void:
	if not _failures.is_empty():
		push_error("World depth sweep failed captures: %s" % "; ".join(PackedStringArray(_failures))); return
	if _shots.is_empty():
		_runtime().warn("SmokeScenarios", "World depth sweep captured no shots; nothing verified.", {}); return
	# reconcile updates (copy ONLY this sweep's shots; foreign-shot guard protects the
	# rest) when baselines are missing or mode is update; otherwise it diffs.
	var result: Dictionary = _baselines.reconcile(_shots, _base_dir, _mode, _threshold_pct)
	var per_shot: Dictionary = result.get("per_shot", {})
	var covered := str(result.get("mode", "")) == VisualSweepBaselines.MODE_UPDATE # update copied every shot; compare must have diffed every shot
	for shot in _shots:
		covered = covered or per_shot.has(str(shot))
	result["ok"] = covered and (result.get("errors", []) as Array).is_empty() and (result.get("mismatched", []) as Array).is_empty()
	_report(result)


func _report(result: Dictionary) -> void:
	if not bool(result.get("ok", false)):
		var per_shot: Dictionary = result.get("per_shot", {})
		for shot in result.get("mismatched", []):
			push_error("World depth sweep drift on %s: %s%% of pixels changed (threshold %s%%)." % [shot, per_shot.get(shot, "?"), _threshold_pct])
		for message in result.get("errors", []):
			push_error("World depth sweep diff error: %s" % message)
		if (result.get("mismatched", []) as Array).is_empty() and (result.get("errors", []) as Array).is_empty():
			push_error("World depth sweep reconcile returned not-ok without a named cause (miss-002): %s" % result)
		return
	_runtime().emit_trace("visual_sweep_world_depth_passed", "SmokeScenarios", {
		"shots": _shots, "mode": str(result.get("mode", VisualSweepBaselines.MODE_COMPARE)),
		"auto_update": bool(result.get("auto_update", false)), "compared": int(result.get("compared", 0)),
		"mismatched": result.get("mismatched", []), "max_drift_pct": float(result.get("max_drift_pct", 0.0)),
		"threshold_pct": _threshold_pct, "base_dir": _base_dir, "crafted": _crafted,
		"sidecar_paths": _shots.map(func(shot_name): return "%s/%s%s" % [_base_dir, shot_name, RenderIntrospection.SIDECAR_SUFFIX])
	})


func _capture(filename: String) -> void:
	_message_box().hide_message()
	await _settle(8) # let the render layer reconcile onto logic tiles (byte-stable rest)
	var metadata: Dictionary = RenderIntrospection.collect(_ctx, filename, _crafted)
	var result: Dictionary = await _captures.capture(_runtime(), get_viewport(), filename,
		{"save_path": "%s/%s" % [_base_dir, filename], "metadata": metadata, "rest_probe": Callable(self, "_rest_state")})
	if not result.ok:
		_failures.append("%s: %s (%s)" % [filename, result.kind, result.detail]); return
	_shots.append(filename)


# Capture-rest probe (SnapshotCapture waits + stamps it): the entity layer is INERT so
# it is at rest by construction; an active layer mid-window is a contract break and
# never settles (mirrors visual_sweep_overworld.gd:200). Player done = not mid-step.
func _rest_state() -> Dictionary:
	var at_rest := true
	var scene: Node = get_tree().current_scene
	var layer: Node = scene.get_node_or_null("EntityLayer") if scene != null else null
	var mons: Object = _runtime().get("overworld_mons_runtime")
	if layer != null and mons != null and bool(mons.get("active")):
		at_rest = false
	return {"entities_at_rest": at_rest, "player_lerp_complete": not _player().is_moving()}


func _settle(frames: int) -> void:
	for _i in range(frames):
		await get_tree().process_frame


func _world() -> Node: return _ctx["world"]
func _player() -> Node: return _ctx["player"]
func _runtime() -> Node: return _ctx["runtime"]
func _message_box() -> Node: return _ctx["message_box"]
