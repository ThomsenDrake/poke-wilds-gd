extends RefCounted

# Showcase WORLD-EDGE beacon frame (NOT a baseline): two registered Teleport Beacons (edge-band
# way-stones) at the manhattan edge, with the multi-beacon SELECTOR open when the scene is wired
# (world-depth.md § Teleport Beacons). A beacon IS a way-stone in the suppression band (WorldChain.
# is_beacon_tile); the registry (world_chain_runtime.beacon_tiles) reads the live placements, so
# placing two way-stones in the edge band IS registering beacons. Beacons go on the RUNTIME world_gen
# (the registry's source) + a rebuild mirrors them onto the view. Bounded edge-band search, NO rng.
# Reaches into the driver node for the shared capture plumbing (the beacon/expand precedent).

const WAYSTONE_ID := "way_stone" # public contract string (structures.gd WAYSTONE_ID)
const BEACON_RING_MIN := 88 # WORLD_RADIUS(96) - TELEPORT_EDGE_MARGIN(8): the edge band
const BEACON_RING_MAX := 94 # inside the hard edge (WORLD_RADIUS - 2) so terrain frames the beacons
const CLUSTER_RADIUS := 4 # chebyshev spread of the two beacons around the player anchor
const SELECTOR_PATH := "UI/BeaconSelector" # Main.tscn beacon-picker node (field_move_actions precedent)
const SHOT := "06_world_edge_beacon.png"


static func run(s: Node) -> void:
	var cluster := _find_cluster(s)
	if cluster.is_empty():
		s._failures.append("%s: no walkable edge-band cluster within ring %d-%d (anchor seam broken)" % [SHOT, BEACON_RING_MIN, BEACON_RING_MAX]); return
	var anchor: Vector2i = cluster[0]
	var world_gen: RefCounted = s._runtime()._world_gen
	var step := 1
	for beacon_index in [1, 2]:
		world_gen.add_placement(Vector2i(cluster[beacon_index]), WAYSTONE_ID, "showcase", step)
		step += 1
	s._world().rebuild(int(s._runtime().get_world_seed())) # mirror the placements onto the view
	var beacons: Array = s._runtime().world_chain_runtime.beacon_tiles()
	if beacons.size() < 2:
		s._failures.append("%s: only %d beacon(s) registered after placement (beacon registry seam broken)" % [SHOT, beacons.size()]); return
	# Best-effort overlay: the beacons + the world edge are the shot; the selector is context, so its
	# absence degrades to a clean edge frame (recorded), never a skipped locale.
	var selector_open := _open_selector(s, beacons)
	s._runner.teleport_player(s._world(), s._player(), s._runtime(), anchor)
	s._world().set_time_of_day(720)
	s._world().sync_visible(anchor)
	await s._capture(SHOT, {"locale": "World edge with two Teleport Beacons",
		"seed": s._runtime().get_world_seed(), "camera_tile": [anchor.x, anchor.y],
		"beacon_tiles": beacons.map(func(tile): return [tile.x, tile.y]), "selector_open": selector_open,
		"chain": "0,0", "world_radius": 96})
	if selector_open:
		_close_selector(s) # the selector is a separate overlay from the message box; close it for later shots


static func _close_selector(s: Node) -> void:
	var scene: Node = s.get_tree().current_scene
	var selector: Node = scene.get_node_or_null(SELECTOR_PATH) if scene != null else null
	if selector != null and selector.has_method("close_selector"):
		selector.close_selector()


# Bounded edge-band search: the manhattan ring at each distance 88-94 (deterministic order), filtered
# to open ground, then the first anchor with >=2 open-ground beacons within CLUSTER_RADIUS. Empty on
# exhaustion (loud-failed by the caller). Pure in the seed; NO rng.
static func _find_cluster(s: Node) -> Array:
	var eligible: Array = []
	var seen: Dictionary = {}
	for dist in range(BEACON_RING_MIN, BEACON_RING_MAX + 1):
		for x in range(-dist, dist + 1):
			for y_sign in [1, -1]:
				var tile := Vector2i(x, (dist - absi(x)) * int(y_sign))
				if seen.has(tile):
					continue
				seen[tile] = true
				if _is_open_ground(s, tile):
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


# can_place_on-eligible off the VIEW's logic: open ground the way-stone renders cleanly on (walkable,
# no prop/structure/landmark). The app never preloads domain.
static func _is_open_ground(s: Node, tile: Vector2i) -> bool:
	var logic: Dictionary = s._world().get_tile_logic(tile)
	return bool(logic.get("walkable", false)) and str(logic.get("prop_path", "")) == "" \
		and str(logic.get("structure_id", "")) == "" and str(logic.get("landmark_id", "")) == ""


# Opens the scene's BeaconSelector with registration-ordered rows; resolve is an empty Callable (the
# capture never Z-selects). False when the node is absent (selector context unavailable this checkout).
static func _open_selector(s: Node, beacons: Array) -> bool:
	var scene: Node = s._runtime().get_tree().current_scene
	var selector: Node = scene.get_node_or_null(SELECTOR_PATH) if scene != null else null
	if selector == null or not selector.has_method("open_selector"):
		return false
	var rows: Array = []
	for i in range(beacons.size()):
		var tile: Vector2i = beacons[i]
		rows.append({"label": "Beacon %d — (%d, %d)" % [i + 1, tile.x, tile.y], "tile": tile})
	selector.open_selector("TELEPORT BEACONS", rows, Callable())
	return true
