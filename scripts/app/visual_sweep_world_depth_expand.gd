extends RefCounted

# Phase 7 R11 — the UNSHOT origin-world world_depth state + the shared capture helpers, extracted
# at the app-220 wall (the beacon-shot precedent: a static run(sweep) that reaches into the sweep
# node for the shared plumbing). The origin satellite (visual_sweep_world_depth) captures (34) the
# Heart Tower footprint/interior here — the largest landmark, dedicated tileset, zero prior pixel
# coverage — mirroring 31/32's footprint-probe + tile-prop assert pattern (the tower has NO encounter
# token, so it asserts landmark_id + region + the rendered wall/decor props). The CHAINED world + the
# legendary GUARDIAN shots live in the SEPARATE visual_sweep_world_chain satellite because R3's run-
# playtests sidecar gate (_sidecar_seed_equality_violations: "exactly one deterministic world across
# the fresh set") forbids a derived world_seed sharing a run with the origin shots. This file also
# hosts the shared helpers the chained satellite reuses: set_entities_active + the two-sample
# rest_state probe (the origin sweep's _rest_state was lifted here so the sweep stays at its wall)
# and the pure legendary-framing math. NO rng.

const WorldDepthOracle := preload("res://scripts/app/visual_sweep_world_depth_oracle.gd")

const TOWER_ID := "heart_tower" # public contract string (landmarks.gd TOWER_ID)
const LEGENDARY_KIND := "legendary" # overworld_mons_sim new_legendary kind/render_kind
const GUARDIAN_RING_MIN := 60 # LegendaryPlacement.LEGENDARY_RING_MIN — the distance gate the guardian shot names
const LEGENDARY_SCAN_HALF := 140 # covers the anchor budget's ring band (60..134) around a center
const GUARDIAN_PLAYER_OFFSET := Vector2i(9, 0) # manhattan 9 > GUARDIAN_SPOT_RADIUS(8) (Manhattan sight): out of sight AND on-screen (a (0,9) offset is 432px up — off the 648px window)
const SHOT_TOWER := "34_heart_tower.png"


# Runs the origin satellite's appended shot (the heart tower) on the sweep node, after the beacon
# shot. Loud-fails (never silent) when the anchor seam breaks.
static func run(sweep: Node) -> void:
	await _tower_shot(sweep)


# (34) Heart Tower: probe the footprint, stand in the base chamber, assert the rendered tileset.
static func _tower_shot(sweep: Node) -> void:
	var footprint: Rect2i = sweep._find_footprint(TOWER_ID)
	if footprint.size == Vector2i.ZERO:
		sweep._failures.append("%s: no %s stamp within the spiral cap (anchor seam broken)" % [SHOT_TOWER, TOWER_ID]); return
	var player_tile: Vector2i = footprint.position + WorldDepthOracle.TOWER_PLAYER_LOCAL
	var logic: Dictionary = sweep._world().get_tile_logic(player_tile)
	if str(logic.get("landmark_id", "")) != TOWER_ID or not bool(logic.get("walkable", false)):
		sweep._failures.append("%s: chamber tile %s landmark/walkable unexpected (domain layout drift)" % [SHOT_TOWER, player_tile]); return
	# The dedicated tileset actually renders: the centered decor + the wall mid-points are solid props.
	for local in WorldDepthOracle.TOWER_INK_LOCALS:
		var tile_logic: Dictionary = sweep._world().get_tile_logic(footprint.position + local)
		if str(tile_logic.get("prop_path", "")) == "" or bool(tile_logic.get("walkable", true)):
			sweep._failures.append("%s: tower prop at local %s lost its solid tileset sprite (render drift)" % [SHOT_TOWER, local]); return
	sweep._crafted["tower_footprint"] = [footprint.position.x, footprint.position.y, footprint.size.x, footprint.size.y]
	sweep._crafted["tower_room_tile"] = [player_tile.x, player_tile.y]
	sweep._runner.teleport_player(sweep._world(), sweep._player(), sweep._runtime(), player_tile)
	sweep._world().set_time_of_day(int(sweep._crafted["time_of_day"]))
	sweep._world().sync_visible(player_tile)
	sweep._pending_oracle = WorldDepthOracle.static_region(SHOT_TOWER, sweep._crafted, player_tile)
	await sweep._capture(SHOT_TOWER)


# Opt the entity layer in/out (the overworld-sweep precedent); returns the prior flag so a shot can
# restore it. Shared with the chained satellite (the guardian shot opts in for its capture).
static func set_entities_active(node: Node, active: bool) -> bool:
	var mons: Object = node._runtime().get("overworld_mons_runtime")
	if mons == null or not ("active" in mons):
		return false
	var previous: bool = bool(mons.get("active"))
	mons.set("active", active)
	return previous


# Capture-rest probe (SnapshotCapture waits + stamps it), bound as Callable(...).bind(node). Two-
# sample sprite-position equality when the layer is ACTIVE (so an opted-in legendary guardian at
# rest settles byte-stable, mirroring visual_sweep_overworld.gd:200); an INERT layer is at rest by
# construction (the origin shots). Player done = not mid-step. The sample cache rides the bound node.
static func rest_state(node: Node) -> Dictionary:
	var at_rest := true
	var scene: Node = node.get_tree().current_scene
	var layer: Node = scene.get_node_or_null("EntityLayer") if scene != null else null
	var mons: Object = node._runtime().get("overworld_mons_runtime")
	if layer != null and mons != null and bool(mons.get("active")):
		var nodes: Dictionary = layer.get("_entity_nodes")
		var sample := {}
		for id in nodes:
			var sprite: Sprite2D = (nodes[id] as Dictionary).get("sprite")
			if sprite != null:
				sample[id] = sprite.position
		at_rest = not node._rest_sample.is_empty() and sample == node._rest_sample
		node._rest_sample = sample
	return {"entities_at_rest": at_rest, "player_lerp_complete": not node._player().is_moving()}


# First legendary at/above the ring gate inside the scan box (deterministic: the runtime's
# _live_list order is the sorted-entity order, so the pick is seed-stable). Empty when none resolved.
static func pick_legendary(mons: Object, center: Vector2i, half: int, ring_min: int) -> Dictionary:
	var box := Rect2i(center.x - half, center.y - half, 2 * half + 1, 2 * half + 1)
	for entity in mons.live_entities_in(box):
		var record := entity as Dictionary
		if str(record.get("kind", "")) != LEGENDARY_KIND:
			continue
		if int(record.get("ring", 0)) >= ring_min:
			return record
	return {}


# The camera tile nearest `want` the player can stand on (tiny chebyshev spiral; bounded so a
# pathological band never loops). Vector2i.MAX on exhaustion (loud-failed by the caller).
static func walkable_near(world: Node, want: Vector2i) -> Vector2i:
	for radius in range(5):
		for dx in range(-radius, radius + 1):
			for dy in range(-radius, radius + 1):
				if maxi(absi(dx), absi(dy)) != radius and radius > 0:
					continue
				var tile := want + Vector2i(dx, dy)
				if bool(world.get_tile_logic(tile).get("walkable", false)):
					return tile
	return Vector2i.MAX


# The tile rect the canonical window shows around the camera tile (TILE_PX 48 -> +-12 / +-6 tiles),
# padded one cell so a guardian straddling the frame edge still counts as in-view ink.
static func screen_tile_rect(player_tile: Vector2i) -> Rect2i:
	return Rect2i(player_tile.x - 13, player_tile.y - 7, 27, 15)
