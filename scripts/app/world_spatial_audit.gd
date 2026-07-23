extends RefCounted

# Spatial + movement half of world_consistency_audit: the z-order north/south
# contract for tall props, the player-vs-blocking-prop rect check, and the
# per-tile movement probe (collision agreement). The z-order/rect reads are
# transform-level and synchronous; the movement probe awaits step animations.
# Also hosts the shared helpers the audit's clears AND build lanes both use
# (solid-prop model truth + the texture byte-equality check), extracted so the
# consistency audit stays under its line budget.

const WorldDrawOrder := preload("res://scripts/app/world_draw_order.gd")

const SAMPLE_RADIUS := 20
const MAX_Z_ORDER_PROPS := 6
const TILE := 16
# Model truth independent of the data under test: these props are solid
# structures, so a walkable tile rendering one is a world-data regression.
const SOLID_PROP_PATHS := [
	"res://pokewilds/tiles/tree1.png",
	"res://pokewilds/tiles/swamp/tree13.png",
	"res://pokewilds/tiles/spooky/tree1.png",
	"res://pokewilds/tiles/cactus1.png",
	"res://pokewilds/rock_small1.png",
	"res://pokewilds/tiles/lava_sheet1.png",
]


# Byte-equality of two rendered textures (size + pixel data); null == null.
static func textures_match(a: Texture2D, b: Texture2D) -> bool:
	if a == null or b == null:
		return a == b
	var image_a := a.get_image()
	var image_b := b.get_image()
	if image_a.get_size() != image_b.get_size():
		return false
	return image_a.get_data() == image_b.get_data()


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


# Collision agreement for one tile: step into it from a stand neighbor and
# require the avatar to move iff the tile is expected-walkable. Returns
# {"failures", "movement", "spatial"} so the audit can fold in its counters.
func movement_probe(world, player, runtime, runner, tile: Vector2i) -> Dictionary:
	var result := {"failures": [], "movement": 0, "spatial": 0}
	var spot: Dictionary = runner.stand_spot(world, tile)
	if spot.is_empty():
		return result
	result["movement"] = 1
	runner.teleport_player(world, player, runtime, spot["from_tile"])
	if player._moving:
		await player.tile_changed
	var expected := expected_walkable(world, tile)
	var accepted: bool = player.smoke_step(spot["direction"])
	var moved := false
	if accepted:
		await player.tile_changed
		moved = player.tile_position == tile
	if moved != expected or accepted != expected:
		(result["failures"] as Array).append({"tile": [tile.x, tile.y], "kind": "movement_mismatch",
			"expected_walkable": expected, "moved": moved, "accepted": accepted})
	result["spatial"] = 1
	(result["failures"] as Array).append_array(check_player_rect(world, player))
	return result


# The model's expectation: solid props block no matter what the data says.
func expected_walkable(world, tile: Vector2i) -> bool:
	if str(world.get_tile_logic(tile).get("prop_path", "")) in SOLID_PROP_PATHS:
		return false
	return world.is_tile_walkable(tile)
