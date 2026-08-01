extends RefCounted

# Showcase CHAINED-WORLD frames (NOT baselines): a non-origin overworld (09) and a stationary
# legendary standing in its ring (10). The derived world is entered through the PRODUCTION crossing
# (world_chain_runtime.try_cross_edge: step north OFF the farthest edge — the world_chain_checks
# precedent), which swaps the chain identity, derives + binds world_seed_for(root,(0,-1)) off
# session.root_seed, re-stamps the legendaries, traces world_chained. NEVER a manual seam swap (the
# raw 63-bit SplitMix mix is NOT a seed; world_seed_for masks to 31 bits). The legendary shot PREFERS
# a LAVA-affinity four (MEWTWO/REGIROCK/REGISTEEL/REGIDRAGO) via a bounded northward chain search —
# origin generates ZERO LAVA tiles, so a LAVA ring needs a chained world — and falls back to the
# committed SNOW REGICE in a fresh (0,-1) when no searched world anchors one. The legendary is framed
# out of its Manhattan-8 sight (the proven (9,0) offset + walkable_near) with the driver's rest probe
# for a byte-stable sprite. NO rng on any path; 09 inert framing, 10 active.

const ShowcaseSupport := preload("res://scripts/app/showcase_support.gd")
const WorldDepthExpand := preload("res://scripts/app/visual_sweep_world_depth_expand.gd") # entity toggle + walkable_near

const TOWER_ID := "heart_tower" # re-anchors in EVERY world (spec § Landmarks) — the chained frame's anchor
const ORIGIN_SPEC := {"world_seed": 2026072907, "time_of_day": 720, "party": [["MACHOP", 30]], "bag": {}}
const CHAIN := Vector2i(0, -1)
const TOWER_CHAMBER_LOCAL := Vector2i(4, 4)
const GUARDIAN_OFFSET := Vector2i(9, 0) # manhattan 9 > sight 8: out of aggro AND on-screen
const LEGENDARY_SCAN_HALF := 140
const LEGENDARY_RING_MIN := 60
const CHAIN_SEARCH_CAP := 8 # search (0,-1)..(0,-8) for a LAVA legendary before the SNOW fallback
const EDGE_TILE := Vector2i(0, -95) # farthest north edge: manhattan WORLD_RADIUS - 1
const SHOT_CHAINED := "09_chained_world.png"
const SHOT_LEGENDARY := "10_legendary_ring.png"


static func run(s: Node) -> void:
	if not s._craft(ORIGIN_SPEC):
		s._failures.append("chained craft failed: catalog incomplete (party species missing)"); return
	var cross: Dictionary = _cross_north(s)
	if not bool(cross.get("ok", false)):
		s._failures.append("%s: crossing refused (%s); edge seam broken" % [SHOT_CHAINED, str(cross.get("reason", ""))]); return
	s._world().rebuild(int(cross.get("world_seed"))) # the crossing mutates the generator; the caller repositions the view
	await _chained_shot(s, cross)
	await _legendary_shot(s)


# (09) A VISIBLY DIFFERENT overworld: frame an OUTDOOR vista of the derived world from its spawn (a
# different noise plane than origin). The Heart Tower re-anchors in EVERY world off the derived seed,
# so probing its footprint (and asserting the chamber is enterable) is the deterministic proof this is
# a re-derived world, not the origin's anchors — recorded in the sidecar beside the vista frame.
static func _chained_shot(s: Node, cross: Dictionary) -> void:
	var fp := ShowcaseSupport.find_footprint(s._world(), TOWER_ID, 80)
	if fp.size == Vector2i.ZERO:
		s._failures.append("%s: no %s stamp in the chained world %d (any-world anchor seam broken)" % [SHOT_CHAINED, TOWER_ID, int(cross.get("world_seed", 0))]); return
	var chamber: Vector2i = fp.position + TOWER_CHAMBER_LOCAL
	var chamber_logic: Dictionary = s._world().get_tile_logic(chamber)
	if str(chamber_logic.get("landmark_id", "")) != TOWER_ID or not bool(chamber_logic.get("walkable", false)):
		s._failures.append("%s: re-anchored tower chamber %s landmark/walkable unexpected (derived layout drift)" % [SHOT_CHAINED, chamber]); return
	var spawn: Vector2i = s._runtime()._world_gen.find_walkable_spawn(int(cross.get("world_seed", 0)))
	if not bool(s._world().get_tile_logic(spawn).get("walkable", false)):
		s._failures.append("%s: chained spawn %s not walkable (find_walkable_spawn seam broken)" % [SHOT_CHAINED, spawn]); return
	ShowcaseSupport.teleport(s, spawn)
	await s._capture(SHOT_CHAINED, {"locale": "Chained world (0,-1) — a visibly different overworld (derived noise plane)",
		"seed": int(cross.get("world_seed", 0)), "root_seed": int(ORIGIN_SPEC["world_seed"]), "chain": [CHAIN.x, CHAIN.y],
		"camera_tile": [spawn.x, spawn.y], "biome": str(s._world().get_tile_logic(spawn).get("biome", "")),
		"reanchored_tower_footprint": ShowcaseSupport.rect_array(fp), "reanchored_tower_chamber": [chamber.x, chamber.y],
		"newly_generated": bool(cross.get("newly_generated", false))})


# (10) A stationary legendary in its ring: search (0,-1)..(0,-cap) for a LAVA-affinity four; fall
# back to the committed SNOW REGICE in a fresh (0,-1) when none anchors. Framed out of sight at rest.
static func _legendary_shot(s: Node) -> void:
	var mons: Object = s._runtime().get("overworld_mons_runtime")
	if mons == null or not mons.has_method("stamp_legendaries"):
		s._failures.append("%s: overworld_mons_runtime.stamp_legendaries absent (legendary seam broken)" % SHOT_LEGENDARY); return
	var saved_active: bool = WorldDepthExpand.set_entities_active(s, true) # opt in so the layer renders the static
	var target: Dictionary = _search_lava(s, mons)
	var lava := not target.is_empty()
	if target.is_empty(): # guaranteed fallback: a fresh (0,-1) anchors the committed SNOW REGICE at ring 60
		if not s._craft(ORIGIN_SPEC):
			WorldDepthExpand.set_entities_active(s, saved_active)
			s._failures.append("%s: fallback origin re-craft failed" % SHOT_LEGENDARY); return
		var cross: Dictionary = _cross_north(s)
		if not bool(cross.get("ok", false)):
			WorldDepthExpand.set_entities_active(s, saved_active)
			s._failures.append("%s: fallback crossing refused (%s)" % [SHOT_LEGENDARY, str(cross.get("reason", ""))]); return
		s._world().rebuild(int(cross.get("world_seed")))
		mons.stamp_legendaries()
		target = _legendary_with_biome(mons, "", LEGENDARY_RING_MIN)
	if target.is_empty():
		WorldDepthExpand.set_entities_active(s, saved_active)
		s._failures.append("%s: no ring>=%d legendary in the chained world (legendary anchor seam broken)" % [SHOT_LEGENDARY, LEGENDARY_RING_MIN]); return
	var legendary_tile: Vector2i = target.get("tile", Vector2i.MAX)
	var camera := WorldDepthExpand.walkable_near(s._world(), legendary_tile + GUARDIAN_OFFSET)
	if camera == Vector2i.MAX:
		WorldDepthExpand.set_entities_active(s, saved_active)
		s._failures.append("%s: no walkable camera tile near the legendary %s (framing broken)" % [SHOT_LEGENDARY, legendary_tile]); return
	ShowcaseSupport.teleport(s, camera)
	await s._capture(SHOT_LEGENDARY, {"locale": "Stationary legendary at rest in its ring",
		"seed": s._runtime().get_world_seed(), "chain": str(s._runtime().session.active_chain), "lava_affinity": lava,
		"species_id": str(target.get("species_id", "")), "biome": str(target.get("biome", "")),
		"ring": int(target.get("ring", 0)), "legendary_tile": [legendary_tile.x, legendary_tile.y],
		"camera_tile": [camera.x, camera.y]})
	WorldDepthExpand.set_entities_active(s, saved_active)


# Northward chain search for a LAVA-affinity legendary: we enter at (0,-1); each further crossing
# steps north off the edge again (re-anchor the edge tile, cross, rebuild, re-stamp). First world
# whose stamped set holds a LAVA legendary wins; {} when the cap exhausts (the SNOW fallback runs).
static func _search_lava(s: Node, mons: Object) -> Dictionary:
	for k in range(1, CHAIN_SEARCH_CAP + 1):
		if k > 1:
			var cross: Dictionary = _cross_north(s)
			if not bool(cross.get("ok", false)):
				return {}
			s._world().rebuild(int(cross.get("world_seed")))
		mons.stamp_legendaries()
		var lava := _legendary_with_biome(mons, "LAVA", LEGENDARY_RING_MIN)
		if not lava.is_empty():
			return lava
	return {}


static func _legendary_with_biome(mons: Object, biome: String, ring_min: int) -> Dictionary:
	var box := Rect2i(-LEGENDARY_SCAN_HALF, -LEGENDARY_SCAN_HALF, 2 * LEGENDARY_SCAN_HALF + 1, 2 * LEGENDARY_SCAN_HALF + 1)
	for entity in mons.live_entities_in(box):
		var record := entity as Dictionary
		if str(record.get("kind", "")) != "legendary" or int(record.get("ring", 0)) < ring_min:
			continue
		if biome.is_empty() or str(record.get("biome", "")) == biome:
			return record
	return {}


# The production crossing: step north OFF the farthest edge. try_cross_edge reads session.player_tile
# (at_edge + the step leaving the disc), swaps the chain identity, derives the seed off session.root_
# seed, re-stamps legendaries, traces world_chained. Returns {ok, chain, world_seed, newly_generated}.
static func _cross_north(s: Node) -> Dictionary:
	s._runtime().session.player_tile = EDGE_TILE
	s._player().set_tile_position(EDGE_TILE)
	return s._runtime().world_chain_runtime.try_cross_edge(Vector2i.UP, "fly")
