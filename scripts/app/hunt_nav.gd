extends RefCounted

# Off-fixture steer: untested walkable tiles, overlays, and nearby warp
# stamps. Does not call find_safe_step_direction and does not steer into
# blocking cells.

const ENTRANCE_RADIUS := 8
const STUCK_VISITS := 6


func pick_direction(world, player, _runtime, visited: Dictionary) -> Vector2i:
	var here: Vector2i = player.tile_position
	var goal := _nearby_warp(world, here)
	var best := Vector2i.ZERO
	var best_score := -999999
	for direction in [Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT, Vector2i.UP]:
		var next_tile: Vector2i = here + direction
		if not world.is_tile_walkable(next_tile):
			continue
		var score := _score_tile(world, next_tile, visited, goal)
		if score > best_score:
			best_score = score
			best = direction
	if best != Vector2i.ZERO:
		return best
	return _any_walkable(world, here)


func _score_tile(world, tile: Vector2i, visited: Dictionary, goal: Vector2i) -> int:
	var key := "%d,%d" % [tile.x, tile.y]
	var visits: int = int(visited.get(key, 0))
	var score := 8 - visits * 3
	if world.is_encounter_tile(tile):
		score += 4
	var logic: Dictionary = world.get_tile_logic(tile)
	if not str(logic.get("prop_path", "")).is_empty():
		score += 3
	if not str(logic.get("overlay_path", "")).is_empty():
		score += 2
	if bool(logic.get("warp", false)):
		score += 10
	if goal != Vector2i.ZERO:
		score += 12 - mini(abs(tile.x - goal.x) + abs(tile.y - goal.y), 12)
	if visits >= STUCK_VISITS:
		score -= 8
	return score


func _nearby_warp(world, here: Vector2i) -> Vector2i:
	for y in range(-ENTRANCE_RADIUS, ENTRANCE_RADIUS + 1):
		for x in range(-ENTRANCE_RADIUS, ENTRANCE_RADIUS + 1):
			var tile: Vector2i = here + Vector2i(x, y)
			if bool(world.get_tile_logic(tile).get("warp", false)):
				return tile
	return Vector2i.ZERO


func _any_walkable(world, here: Vector2i) -> Vector2i:
	for direction in [Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT, Vector2i.UP]:
		if world.is_tile_walkable(here + direction):
			return direction
	return Vector2i.ZERO
