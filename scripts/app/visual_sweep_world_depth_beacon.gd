extends RefCounted

# Phase 7 Build 3 — the 33_beacon shot EXTRACTED from visual_sweep_world_depth.gd (app-220
# wall; check_architecture.py SCRIPT_LIMITS). The plan's reserved beacon shot: a world EDGE
# with two registered way-stone beacons + the multi-beacon SELECTOR open (world-depth.md
# § Teleport Beacons; fresh-faq.md:178-192). Deterministic: the sweep's seed-crafted world,
# beacons placed by a BOUNDED edge-band search (NO rng), the selector opened through the scene
# node. Reaches into the sweep node for the shared capture plumbing (_world/_player/_runtime/
# _runner/_capture/_crafted/_failures) — the documented-reach precedent (beacon_selector.gd's
# _input_router reach; ui/beacon_selector header). A beacon IS a way-stone (Structures.
# WAYSTONE_ID); the registry (world_chain_runtime.beacon_tiles) reads the live placements
# filtered by structure_id, so placing way-stones in the edge band IS registering beacons.

const SHOT := "33_beacon.png"
const WAYSTONE_ID := "way_stone" # public contract string (structures.gd WAYSTONE_ID)
const BEACON_RING_MIN := 88 # WORLD_RADIUS(96) - TELEPORT_EDGE_MARGIN(8): the edge band (world_chain.gd)
const BEACON_RING_MAX := 94 # inside the hard edge (WORLD_RADIUS - 2) so terrain frames the beacons
const CLUSTER_RADIUS := 4 # chebyshev spread of the two beacons around the player anchor
const SELECTOR_PATH := "UI/BeaconSelector" # Main.tscn beacon-picker node (field_move_actions precedent)
const WorldDepthOracle := preload("res://scripts/app/visual_sweep_world_depth_oracle.gd") # R4 regional pixel oracle


# Crafts + captures the shot on the sweep node. Beacons are placed on the RUNTIME world_gen
# (the registry's source), then a rebuild mirrors them onto the view; the selector lists the
# registry's beacon_tiles in registration order. Loud-fails (never silent) on a missing
# cluster or selector node — the shot REQUIRES the edge + the selector context.
static func run(sweep: Node) -> void:
	var cluster := _find_cluster(sweep)
	if cluster.is_empty():
		sweep._failures.append("%s: no walkable edge-band cluster within ring %d-%d (anchor seam broken)" % [SHOT, BEACON_RING_MIN, BEACON_RING_MAX]); return
	var anchor: Vector2i = cluster[0]
	var world_gen: RefCounted = sweep._runtime()._world_gen
	var step := 1
	for beacon_index in [1, 2]:
		world_gen.add_placement(Vector2i(cluster[beacon_index]), WAYSTONE_ID, "visual_sweep", step)
		step += 1
	sweep._world().rebuild(int(sweep._crafted["world_seed"])) # mirror the placements onto the view (the mansion-shot precedent)
	var beacons: Array = sweep._runtime().world_chain_runtime.beacon_tiles()
	if not _open_selector(sweep, beacons):
		sweep._failures.append("%s: BeaconSelector scene node absent (%s); selector context required" % [SHOT, SELECTOR_PATH]); return
	sweep._runner.teleport_player(sweep._world(), sweep._player(), sweep._runtime(), anchor)
	sweep._world().set_time_of_day(int(sweep._crafted["time_of_day"]))
	sweep._world().sync_visible(anchor)
	sweep._crafted["beacon_anchor"] = [anchor.x, anchor.y]
	sweep._crafted["beacon_tiles"] = beacons.map(func(tile): return [tile.x, tile.y])
	sweep._crafted["beacon_chain"] = "0,0"
	sweep._pending_oracle = WorldDepthOracle.static_region(SHOT, sweep._crafted, anchor) # R4: beacon way-stone pixel gate
	await sweep._capture(SHOT)
	_close_selector(sweep) # the selector is a SEPARATE overlay from the message box; close it so later shots (34/35) are clean


# The selector overlay (opened above) is NOT the message box, so hide_message() won't dismiss it.
# Close it after the beacon shot so the following captures don't carry the picker (33 owns the open UI).
static func _close_selector(sweep: Node) -> void:
	var scene: Node = sweep.get_tree().current_scene
	var selector: Node = scene.get_node_or_null(SELECTOR_PATH) if scene != null else null
	if selector != null and selector.has_method("close_selector"):
		selector.close_selector()


# Bounded edge-band search: the full manhattan ring at each distance 88-94 (deterministic
# order), filtered to open ground, then the first anchor with >=2 open-ground beacons within
# CLUSTER_RADIUS. Empty on exhaustion (loud-failed by the caller). Pure in the seed; NO rng.
static func _find_cluster(sweep: Node) -> Array:
	var eligible: Array = []
	var seen: Dictionary = {}
	for dist in range(BEACON_RING_MIN, BEACON_RING_MAX + 1):
		for x in range(-dist, dist + 1):
			for y_sign in [1, -1]:
				var tile := Vector2i(x, (dist - absi(x)) * int(y_sign))
				if seen.has(tile):
					continue
				seen[tile] = true
				if _is_open_ground(sweep, tile):
					eligible.append(tile)
	for anchor in eligible:
		var neighbors: Array = []
		for other in eligible:
			if other != anchor and maxi(absi(other.x - anchor.x), absi(other.y - anchor.y)) <= CLUSTER_RADIUS:
				neighbors.append(other)
				if neighbors.size() >= 2:
					break
		if neighbors.size() >= 2:
			return [anchor, neighbors[0], neighbors[1]]
	return []


# can_place_on-eligible off the VIEW's logic (structures.gd shape): open ground the way-stone
# renders cleanly on (walkable, no prop/structure/landmark). App never preloads domain.
static func _is_open_ground(sweep: Node, tile: Vector2i) -> bool:
	var logic: Dictionary = sweep._world().get_tile_logic(tile)
	return bool(logic.get("walkable", false)) and str(logic.get("prop_path", "")) == "" \
		and str(logic.get("structure_id", "")) == "" and str(logic.get("landmark_id", "")) == ""


# Opens the scene's BeaconSelector with registration-ordered rows (field_move_actions._rows
# wording); resolve is an empty Callable — the capture never Z-selects. False when the node
# is absent (an older/headless host), loud-failed by the caller.
static func _open_selector(sweep: Node, beacons: Array) -> bool:
	var scene: Node = sweep._runtime().get_tree().current_scene
	var selector: Node = scene.get_node_or_null(SELECTOR_PATH) if scene != null else null
	if selector == null or not selector.has_method("open_selector"):
		return false
	var rows: Array = []
	for i in range(beacons.size()):
		var tile: Vector2i = beacons[i]
		rows.append({"label": "Beacon %d — (%d, %d)" % [i + 1, tile.x, tile.y], "tile": tile})
	selector.open_selector("TELEPORT BEACONS", rows, Callable())
	return true
