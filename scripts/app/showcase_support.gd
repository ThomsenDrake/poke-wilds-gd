extends RefCounted

# Shared PURE helpers for the showcase capture satellites (extracted so each satellite stays under
# the app-220 wall without duplicating the footprint probe; the beacon/expand extraction precedent).
# NO domain preload — the app layer may not (check_architecture.py's layer table): landmark footprints
# are PROBED off the view's tile logic, the generator mirror that stays deterministic far past the
# synced render window (the visual_sweep_world_depth precedent; NOT get_tile_biome's render cache).

# Spiral from the world origin for the first tile stamped with the resolver's landmark_id, then walk
# the stamp out to its rect. Deterministic in the active world seed; Rect2i() (zero size) on cap
# exhaustion — the caller loud-fails, never a silent skip (miss-002).
static func find_footprint(world: Node, landmark_id: String, cap: int) -> Rect2i:
	for radius in range(cap + 1):
		for cell in spiral_ring(radius):
			if str(world.get_tile_logic(cell).get("landmark_id", "")) == landmark_id:
				return expand_footprint(world, landmark_id, cell)
	return Rect2i()


static func spiral_ring(radius: int) -> Array:
	if radius == 0:
		return [Vector2i.ZERO]
	var cells: Array = []
	for i in range(-radius, radius + 1):
		cells.append_array([Vector2i(i, -radius), Vector2i(i, radius), Vector2i(-radius, i), Vector2i(radius, i)])
	return cells


static func expand_footprint(world: Node, landmark_id: String, hit: Vector2i) -> Rect2i:
	var min_x := hit.x; var max_x := hit.x; var min_y := hit.y; var max_y := hit.y
	while str(world.get_tile_logic(Vector2i(min_x - 1, hit.y)).get("landmark_id", "")) == landmark_id: min_x -= 1
	while str(world.get_tile_logic(Vector2i(max_x + 1, hit.y)).get("landmark_id", "")) == landmark_id: max_x += 1
	while str(world.get_tile_logic(Vector2i(hit.x, min_y - 1)).get("landmark_id", "")) == landmark_id: min_y -= 1
	while str(world.get_tile_logic(Vector2i(hit.x, max_y + 1)).get("landmark_id", "")) == landmark_id: max_y += 1
	return Rect2i(min_x, min_y, max_x - min_x + 1, max_y - min_y + 1)


static func rect_array(fp: Rect2i) -> Array:
	return [fp.position.x, fp.position.y, fp.size.x, fp.size.y]


# Reposition the camera (it parents the player) + sync the visible window + set noon light. The
# teleport snaps the player, so the canonical window is centered exactly on `tile` at capture.
static func teleport(s: Node, tile: Vector2i) -> void:
	s._runner.teleport_player(s._world(), s._player(), s._runtime(), tile)
	s._world().set_time_of_day(720)
	s._world().sync_visible(tile)
