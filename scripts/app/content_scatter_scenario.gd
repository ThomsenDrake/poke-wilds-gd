extends Node

# Content-scatter scenario (infinite-world slice 3; spec: world-depth.md — successor
# infinite-world.md in slice 5). Witnesses the chunk-hash scattering beyond the origin
# core, self-pinned seed_for_smoke(SEED) -> new_game -> rebuild: (1) ORIGIN-CORE
# PRESERVATION — landmarks_in_world still returns EXACTLY the three byte-frozen origin
# anchors (scatter never pollutes the core); (2) SCATTER DISCOVERY — at least one
# scattered landmark instance derives beyond the core, its instance key parses; (3)
# PER-INSTANCE STATE — crafting a scattered mansion's puzzle through the frozen seam
# opens ITS doors while the origin mansion stays sealed (independent keys, never a
# whole-dict clobber). The repeating-lair lifecycle lane is RETIRED with the lairs
# (legendary-dungeon slice: the frozen seven move into warp-entered dungeons).
# NOT a double-run consumer (the origin pins ride
# the lane); deterministic by construction (pure _mix + FastNoiseLite).

const LandmarkRuntime := preload("res://scripts/runtime/landmark_runtime.gd")
const Landmarks := LandmarkRuntime.Landmarks
const LandmarkScatter := LandmarkRuntime.LandmarkScatter
const ContentScatter := LandmarkRuntime.ContentScatter

const SEED := 2026080301
const DAY_MINUTES := 600
const SCAN_RADII := [31, 63, 95] # expanding chunk-radius scan: the scan widens until a scattered mansion instance lands beyond the core
const SEWER_DOOR_LOCAL := Vector2i(4, 5) # landmark_flow's constant: the mansion sewer door local

var _ctx: Dictionary = {}
var _failures: Array = []
var _oks: Dictionary = {}

func run(ctx: Dictionary) -> void:
	_ctx = ctx
	await get_tree().create_timer(0.2).timeout
	var runtime = _runtime()
	runtime.seed_for_smoke(SEED)
	runtime.new_game()
	_world().rebuild(runtime.get_world_seed())
	runtime.session.time_of_day_minutes = DAY_MINUTES
	var found: Dictionary = _scan(runtime.get_world_seed())
	_oks["origin_ok"] = _prove_origin_core(runtime)
	if _failures.is_empty(): _oks["scatter_ok"] = _prove_scatter(runtime, found)
	else: _failures.append("skipped: scatter (cascaded from an origin red)")
	if _failures.is_empty():
		var payload: Dictionary = _oks.duplicate(); payload["pin"] = SEED; payload["seed"] = runtime.get_world_seed()
		runtime.emit_trace("content_scatter_passed", "SmokeScenarios", payload)
	else:
		runtime.emit_trace("content_scatter_failed", "SmokeScenarios", {"failures": _failures, "seed": SEED})
		push_error("ContentScatterScenario failed: %s" % "; ".join(PackedStringArray(_failures)))

# The three origin anchors are byte-frozen AND the scatter never pollutes the core:
# landmarks_in_world returns exactly the origin three (the scenario/audit contract).
func _prove_origin_core(runtime) -> bool:
	var start: int = _failures.size()
	var seed: int = runtime.get_world_seed()
	var origin: Array = Landmarks.landmarks_in_world(seed, Vector2i.ZERO)
	_ensure(origin.size() == 3, "origin: landmarks_in_world returned %d entries (the origin core must stay exactly three)" % origin.size())
	for landmark in origin:
		var lid := str(landmark.get("landmark_id", ""))
		var derived: Vector2i = Landmarks.anchor_for(seed, Vector2i.ZERO, lid)
		_ensure(landmark.get("anchor", Vector2i.MAX) == derived, "origin: %s anchor drifted from the byte-frozen derivation" % lid)
	return _failures.size() == start

# Scatter discovery + per-instance state: find a scattered mansion beyond the core, craft
# ITS puzzle through the frozen seam, and prove the origin mansion stays sealed.
func _prove_scatter(runtime, found: Dictionary) -> bool:
	var start: int = _failures.size()
	var seed: int = runtime.get_world_seed()
	var mansion: Dictionary = found.get("mansion", {})
	if mansion.is_empty():
		return _ensure(false, "scatter: no scattered mansion instance within the chunk scan (density/derivation regression)")
	var parsed := ContentScatter.parse_instance_key(str(mansion.get("instance_key", "")))
	if not _ensure(not parsed.is_empty() and parsed["id"] == Landmarks.MANSION_ID, "scatter: the instance key %s did not parse to a mansion" % str(mansion.get("instance_key", ""))):
		return false
	var origin_mansion := {}
	for landmark in Landmarks.landmarks_in_world(seed, Vector2i.ZERO):
		if str(landmark.get("landmark_id", "")) == Landmarks.MANSION_ID:
			origin_mansion = landmark
	var state := {"statues": [true, true, true], "unlocked": true, "key_taken": true}
	var all: Dictionary = runtime.session.landmark_state_for(Vector2i.ZERO)
	all[str(mansion["instance_key"])] = state
	runtime.session.set_landmark_state(Vector2i.ZERO, all) # the frozen seam MERGES by key (never a whole-dict replace)
	_ensure(runtime.session.landmark_state_for(Vector2i.ZERO).size() == 1, "scatter: crafting the scattered mansion leaked state into a sibling instance")
	var scattered_door: Dictionary = _world().get_tile_logic((mansion["footprint"] as Rect2i).position + SEWER_DOOR_LOCAL)
	_ensure(bool(scattered_door.get("walkable", false)), "scatter: the crafted mansion's sewer door stayed sealed (per-instance state resolution broken)")
	if not origin_mansion.is_empty():
		var origin_door: Dictionary = _world().get_tile_logic((origin_mansion["footprint"] as Rect2i).position + SEWER_DOOR_LOCAL)
		_ensure(not bool(origin_door.get("walkable", false)), "scatter: the origin mansion's door opened from a scattered instance's state (keying collision)")
	return _failures.size() == start

# The chunk scan: a scattered mansion instance beyond the origin core (chunk-center
# ring > 96, the scatter gate), over EXPANDING radii until the goal lands.
func _scan(seed: int) -> Dictionary:
	var out := {"mansion": {}}
	var seen := {}
	for rmax in SCAN_RADII:
		for cy in range(-int(rmax), int(rmax) + 1):
			for cx in range(-int(rmax), int(rmax) + 1):
				var chunk := Vector2i(cx, cy)
				if seen.has(chunk):
					continue
				seen[chunk] = true
				var center := chunk * ContentScatter.CONTENT_CHUNK + Vector2i(ContentScatter.CONTENT_CHUNK / 2, ContentScatter.CONTENT_CHUNK / 2)
				if ContentScatter.ring_of(center) <= 96:
					continue
				var instance := LandmarkScatter.instance_for_chunk(seed, chunk)
				if not instance.is_empty() and str(instance.get("landmark_id", "")) == Landmarks.MANSION_ID:
					out["mansion"] = instance
		if not (out["mansion"] as Dictionary).is_empty():
			return out # the goal landed at this radius
	return out

func _ensure(ok: bool, label: String) -> bool:
	if not ok:
		_failures.append(label)
	return ok

func _world() -> Node: return _ctx["world"]
func _runtime() -> Node: return _ctx["runtime"]
