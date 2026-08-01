extends Node

# Showcase capture driver (NOT a baseline sweep): crafts the coolest locales deterministically and
# saves evocative frames to docs/generated/showcase/NN_name.png + a small crafted-state sidecar.
# Deliberately OUTSIDE the baseline gate machinery: NO SHOT_REGISTRY entry, NO reconcile()/visual_diff,
# NO docs/generated/visual-baselines writes (the foreign-shot prune only protects registry numbers, so
# an unregistered shot there would be deleted by the next sweep update). Reuses the proven capture
# helper (SnapshotCapture) + the world-depth satellites' pure framing math (WorldDepthExpand). Each
# locale's craft rides the existing frozen seams; the per-locale work lives in showcase_* satellites
# extracted at the app-220 wall (the beacon/expand precedent). WINDOWED-ONLY: the headless display
# server renders no pixels (SnapshotCapture.classify -> "headless", no PNG written).

const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")
const VisualSweepBaselines := preload("res://scripts/app/visual_sweep_baselines.gd")
const SnapshotCapture := preload("res://scripts/app/snapshot_capture.gd")
const WorldDepthExpand := preload("res://scripts/app/visual_sweep_world_depth_expand.gd") # pure framing math + rest probe + entity toggle
const ShowcaseLandmarks := preload("res://scripts/app/showcase_landmarks.gd")
const ShowcaseGuardian := preload("res://scripts/app/showcase_guardian.gd")
const ShowcaseBeacon := preload("res://scripts/app/showcase_beacon.gd")
const ShowcasePen := preload("res://scripts/app/showcase_pen.gd")
const ShowcaseChained := preload("res://scripts/app/showcase_chained.gd")

const SHOWCASE_DIR := "res://docs/generated/showcase"
const ORIGIN_SEED := 2026072907 # the world_depth landmark pin (spec § Pinned constants)
const TOD_NOON := 720
const ORIGIN_SPEC := {"world_seed": ORIGIN_SEED, "time_of_day": TOD_NOON, "party": [["MACHOP", 30]], "bag": {}}
const SHOT_VISTA := "08_biome_vista.png"

var _ctx: Dictionary = {}
var _runner = SmokeScenarioRunner.new()
var _baselines = VisualSweepBaselines.new()
var _captures = SnapshotCapture.new()
var _base_dir := ""
var _shots: Array = []
var _failures: Array = []
var _rest_sample := {} # two-sample rest-probe cache (WorldDepthExpand.rest_state rides this node)


func run(ctx: Dictionary) -> void:
	_ctx = ctx
	_base_dir = _resolve_showcase_dir()
	if _base_dir.is_empty():
		_runtime().warn("ShowcaseCapture", "No writable showcase directory; nothing captured.", {}); return
	var previous_window := _baselines.apply_canonical_window_size()
	await _settle(5)
	var saved_chance: float = _player().encounter_chance
	_player().encounter_chance = 0.0 # no grass battles (and no wild-stream draw) during any capture
	# Phase A — the ORIGIN world (seed 2026072907): spawn vista + the landmark family + the ruins
	# guardian + the edge beacons. One craft; each satellite repositions the camera per locale.
	if _craft(ORIGIN_SPEC):
		await _vista_shot()
		await ShowcaseLandmarks.run(self) # mansion solved (01) + sewer (02) + ruins exterior (03) + heart tower (05)
		await ShowcaseGuardian.run(self) # ruins underground DUSCLOPS (04)
		await ShowcaseBeacon.run(self) # world edge + teleport beacons (06)
	else:
		_failures.append("origin craft failed: catalog incomplete (party species missing)")
	# Phase B — the PEN world (seed 2026072605): a fenced pasture with EEVEEs + a ground egg.
	await ShowcasePen.run(self) # 07
	# Phase C — a CHAINED world (derived off the origin root): a different overworld + a stationary
	# legendary in its ring (LAVA-four preferred via a bounded chain search, SNOW Regi fallback).
	await ShowcaseChained.run(self) # 09 + 10
	_player().encounter_chance = saved_chance
	_baselines.restore_window_size(previous_window)
	_finish()


# Crafts fixed session state through the proven baseline helper (save payload + boot-load
# normalization). The dispatcher's save guard + run_playtests' --fresh-save disk sibling protect the
# user's real save. False = unknown species id (loud-failed by the caller, never a silent skip).
func _craft(spec: Dictionary) -> bool:
	return _baselines.craft_state(_ctx, _runner, spec)


# (08) Origin spawn meadow vista: craft_state parked the avatar on find_walkable_spawn; frame that
# pristine biome at noon. A clean wide-open landscape shot, distinct from the landmark interiors.
func _vista_shot() -> void:
	var spawn: Vector2i = _player().tile_position
	var logic: Dictionary = _world().get_tile_logic(spawn)
	if not bool(logic.get("walkable", false)):
		_failures.append("%s: spawn tile %s not walkable (find_walkable_spawn seam broken)" % [SHOT_VISTA, spawn]); return
	_world().set_time_of_day(TOD_NOON)
	_world().sync_visible(spawn)
	await _capture(SHOT_VISTA, {"locale": "origin spawn meadow", "seed": ORIGIN_SEED,
		"camera_tile": [spawn.x, spawn.y], "biome": str(logic.get("biome", "")), "crafted": ORIGIN_SPEC})


# Shared capture: hide any message box, settle, then SnapshotCapture (frame_post_draw readback guard
# + validity oracle + rest probe). Writes docs/generated/showcase/NN_name.png + the canonical sidecar
# (SnapshotCapture injects shot/window/validity; the caller supplies locale/seed/crafted). A failed
# frame is a LOUD named miss (miss-002), never a silent skip.
func _capture(filename: String, metadata: Dictionary) -> void:
	_message_box().hide_message()
	await _settle(8) # let the render/entity layer reconcile onto logic tiles (byte-stable rest)
	metadata["palette_regions"] = metadata.get("palette_regions", {})
	var result: Dictionary = await _captures.capture(_runtime(), get_viewport(), filename,
		{"save_path": "%s/%s" % [_base_dir, filename], "metadata": metadata,
		"rest_probe": Callable(WorldDepthExpand, "rest_state").bind(self)})
	if not bool(result.get("ok", false)):
		_failures.append("%s: %s (%s)" % [filename, str(result.get("kind", "")), str(result.get("detail", ""))]); return
	_shots.append(filename)


func _resolve_showcase_dir() -> String:
	if DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SHOWCASE_DIR)) != OK:
		return ""
	return SHOWCASE_DIR


func _finish() -> void:
	if not _failures.is_empty():
		var detail := "; ".join(PackedStringArray(_failures))
		push_error("Showcase capture missed %d locale frame(s) (miss-002): %s" % [_failures.size(), detail])
		_runtime().emit_trace("showcase_capture_failed", "ShowcaseCapture", {"missed": _failures, "captured": _shots, "base_dir": _base_dir})
		return
	if _shots.is_empty():
		push_error("Showcase capture saved no frames (miss-002): the craft or capture path is broken.")
		_runtime().emit_trace("showcase_capture_failed", "ShowcaseCapture", {"missed": ["no frames captured"], "captured": [], "base_dir": _base_dir})
		return
	_runtime().emit_trace("showcase_capture_passed", "ShowcaseCapture", {"shots": _shots, "base_dir": _base_dir,
		"sidecar_paths": _shots.map(func(shot): return "%s/%s.sidecar.json" % [_base_dir, shot])})


func _settle(frames: int) -> void:
	for _i in range(frames):
		await get_tree().process_frame


func _world() -> Node: return _ctx["world"]
func _player() -> Node: return _ctx["player"]
func _runtime() -> Node: return _ctx["runtime"]
func _message_box() -> Node: return _ctx["message_box"]
