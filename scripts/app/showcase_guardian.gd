extends RefCounted

# Showcase RUINS-UNDERGROUND guardian frame (NOT a baseline): the AGGRESSIVE DUSCLOPS that
# materializes on the underground floor when the player steps into the ruins spawn band (landmark_
# runtime._ensure_ruins_guardian; wiki-overworld-encounters.md:270 always-aggressive). It rides the
# Phase-6 stationary-entity seam through the runtime's documented dicts — there is NO public spawn
# API. The entity layer must be ACTIVE to render (the dispatcher holds it false for non-entity
# scenarios), so this opts in, spawns the guardian via note_player_step, frames it out of its
# Manhattan-8 sight (the proven (9,0) offset + walkable_near so it stays at rest), captures with the
# two-sample rest probe for a byte-stable sprite, then restores the prior activation flag. NO rng.

const ShowcaseSupport := preload("res://scripts/app/showcase_support.gd")
const WorldDepthExpand := preload("res://scripts/app/visual_sweep_world_depth_expand.gd") # entity toggle + rest probe + walkable_near

const RUINS_ID := "desert_ruins"
const SPIRAL_CAP := 80
const GUARD_LOCAL := Vector2i(10, 5) # landmark_runtime.UNDERGROUND_GUARD_LOCAL (the guardian floor cell)
const GUARDIAN_OFFSET := Vector2i(9, 0) # manhattan 9 > sight 8: out of aggro sight AND on-screen
const SHOT := "04_ruins_guardian.png"


static func run(s: Node) -> void:
	var fp := ShowcaseSupport.find_footprint(s._world(), RUINS_ID, SPIRAL_CAP)
	if fp.size == Vector2i.ZERO:
		s._failures.append("%s: no %s stamp within spiral cap %d (anchor seam broken)" % [SHOT, RUINS_ID, SPIRAL_CAP]); return
	var mons: Object = s._runtime().get("overworld_mons_runtime")
	if mons == null or not ("active" in mons):
		s._failures.append("%s: overworld_mons_runtime.active absent (entity seam broken)" % SHOT); return
	var guard_tile: Vector2i = fp.position + GUARD_LOCAL
	var saved_active: bool = WorldDepthExpand.set_entities_active(s, true) # opt in so the layer renders the guardian
	var cursor: int = s._runner.trace_log_line_count()
	s._runner.teleport_player(s._world(), s._player(), s._runtime(), guard_tile)
	s._runtime().note_player_step() # fires _ensure_ruins_guardian in the spawn band -> landmark_entity_spawned{DUSCLOPS}
	if not s._runner.trace_log_has_since("landmark_entity_spawned", cursor, {"landmark_id": RUINS_ID}):
		WorldDepthExpand.set_entities_active(s, saved_active)
		s._failures.append("%s: no landmark_entity_spawned under the guard band (guardian seam broken)" % SHOT); return
	# Frame the guardian at rest: prefer 9 tiles east (out of Manhattan-8 sight), DUSCLOPS on-screen
	# left. When the chamber does not extend east (the east point is wall), fall back to a manhattan
	# ring around the guardian for any on-screen walkable floor beyond sight. The driver's two-sample
	# rest probe is the real guard: an aggroed/moving DUSCLOPS fails the capture loudly, never a bad frame.
	var camera := WorldDepthExpand.walkable_near(s._world(), guard_tile + GUARDIAN_OFFSET)
	if camera == Vector2i.MAX:
		camera = _camera_ring_out_of_sight(s._world(), guard_tile)
	if camera == Vector2i.MAX:
		WorldDepthExpand.set_entities_active(s, saved_active)
		s._failures.append("%s: no walkable camera tile out of sight near %s (framing broken)" % [SHOT, guard_tile]); return
	ShowcaseSupport.teleport(s, camera)
	await s._capture(SHOT, {"locale": "Desert Ruins underground — AGGRESSIVE DUSCLOPS guardian",
		"seed": s._runtime().get_world_seed(), "camera_tile": [camera.x, camera.y],
		"guardian_tile": [guard_tile.x, guard_tile.y], "guardian_species": "DUSCLOPS",
		"disposition": "aggressive", "footprint": ShowcaseSupport.rect_array(fp)})
	WorldDepthExpand.set_entities_active(s, saved_active)


# Walkable camera tile on a manhattan ring around the guardian: distance 9..18 keeps it beyond the
# Manhattan-8 aggro sight, and the |dx|<=12 / |dy|<=6 filter keeps the guardian inside the canonical
# +-13/+-7 frame (screen_tile_rect). Iterating each ring from dx=+-dist (dy=0) outward biases toward
# the most horizontal — best-centered — tile first. Vector2i.MAX when the chamber floor never leaves
# the guardian's sight (loud-failed by the caller).
static func _camera_ring_out_of_sight(world: Node, guard: Vector2i) -> Vector2i:
	for dist in range(9, 19):
		for dx in range(-dist, dist + 1):
			var dy := dist - absi(dx)
			for sgn in [1, -1]:
				var tile := guard + Vector2i(dx, dy * sgn)
				if absi(tile.x - guard.x) > 12 or absi(tile.y - guard.y) > 6:
					continue
				if bool(world.get_tile_logic(tile).get("walkable", false)):
					return tile
	return Vector2i.MAX
