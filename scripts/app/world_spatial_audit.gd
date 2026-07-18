extends RefCounted

# Spatial half of world_consistency_audit: the z-order north/south contract
# for tall props plus the player-vs-blocking-prop rect check. Synchronous —
# every read is transform-level (positions, z_index, y-sort flags), so no
# frame waits are needed.

const WorldDrawOrder := preload("res://scripts/app/world_draw_order.gd")

const SAMPLE_RADIUS := 20
const MAX_Z_ORDER_PROPS := 6
const TILE := 16


# North of a tall prop its canopy must draw over the player; south, the
# player must draw over the prop. Returns {"failures": Array, "checked": int}.
func audit_z_order(world, player, runtime, center: Vector2i, runner) -> Dictionary:
	var failures: Array = []
	var checked := 0
	var props := 0
	for radius in range(1, SAMPLE_RADIUS + 1):
		for tile in runner.ring_around(center, radius):
			var logic: Dictionary = world.get_tile_logic(tile)
			if bool(logic.get("walkable", true)) or str(logic.get("prop_path", "")).is_empty():
				continue
			world.sync_visible(tile)
			var sprite: Sprite2D = world.get_prop_sprite(tile)
			if sprite == null or sprite.texture == null or sprite.texture.get_height() <= TILE:
				continue
			props += 1
			checked += 1
			runner.teleport_player(world, player, runtime, tile + Vector2i.UP)
			if not WorldDrawOrder.draws_over(sprite, _player_sprite(player)):
				failures.append({"tile": [tile.x, tile.y], "kind": "z_order_north"})
			runner.teleport_player(world, player, runtime, tile + Vector2i.DOWN)
			if not WorldDrawOrder.draws_over(_player_sprite(player), sprite):
				failures.append({"tile": [tile.x, tile.y], "kind": "z_order_south"})
			if props >= MAX_Z_ORDER_PROPS:
				return {"failures": failures, "checked": checked}
	return {"failures": failures, "checked": checked}


# The player's rect must never overlap a blocking prop's solid tile rect.
func check_player_rect(world, player) -> Array:
	var failures: Array = []
	var rect: Rect2 = player.world_rect()
	for offset in [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]:
		var tile: Vector2i = player.tile_position + offset
		var logic: Dictionary = world.get_tile_logic(tile)
		if bool(logic.get("walkable", true)) or str(logic.get("prop_path", "")).is_empty():
			continue
		if rect.intersects(Rect2(world.map_to_world(tile), Vector2(TILE, TILE))):
			failures.append({"tile": [tile.x, tile.y], "kind": "player_prop_overlap"})
	return failures


func _player_sprite(player) -> CanvasItem:
	return player.get_node("AnimatedSprite2D")
