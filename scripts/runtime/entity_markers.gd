extends RefCounted

# Phase 7 Build 2 — EXTRACTED from entity_layer.gd at the 320 wall (world-depth.md
# § Implementation shape :189 "EXTRACT a node-sync helper" FIRST, then the legendary
# render): the GENERATED marker nodes (nest ring + alpha badge — DIVERGENCE #1: generated
# textures, no submodule art) + their cached textures. Byte-identical pixels, node names,
# offsets and z to the pre-extraction layer; entity_layer keeps the lifecycle dict
# (_nest_nodes) + composes the entity sprites around these markers.

const OverworldMons := preload("res://scripts/domain/overworld_mons.gd") # cell_center ONLY

const TILE_SIZE := 16

var _nest_ring: Texture2D = null
var _alpha_badge: Texture2D = null


# The woven ground ring under a nest cell (generated; DIVERGENCE #1); a z -1 ground
# feature, sorting under every z-0 entity (pen ground-eggs are z 0). The caller parents
# it (add_child inside) + owns the lifecycle; legendaries NEVER get one (guardian-only).
func nest_sprite(parent: Node2D, cell: Vector2i) -> Sprite2D:
	var sprite := Sprite2D.new()
	sprite.name = "Nest_%d_%d" % [cell.x, cell.y]
	sprite.centered = false
	sprite.texture = nest_ring_texture()
	sprite.z_index = -1
	sprite.position = _map_to_world(OverworldMons.cell_center(cell))
	parent.add_child(sprite)
	return sprite


# A red diamond badge over the guardian's head — NOT a palette swap (a tint would read
# as a shiny, :230). Idempotent (one marker per sprite).
func attach_alpha_marker(sprite: Sprite2D) -> void:
	if sprite.get_node_or_null("AlphaMarker") != null:
		return
	var marker := Sprite2D.new()
	marker.name = "AlphaMarker"
	marker.centered = false
	marker.texture = alpha_badge_texture()
	marker.position = Vector2(4, -22) # above the mon's head (parent origin is the feet)
	sprite.add_child(marker)


func nest_ring_texture() -> Texture2D:
	if _nest_ring != null:
		return _nest_ring
	var image := Image.create(TILE_SIZE, TILE_SIZE, false, Image.FORMAT_RGBA8)
	# A woven ground ring (generated; DIVERGENCE #1), hollow-centered, distinct from the pen egg.
	var light := Color(0.55, 0.40, 0.22)
	var dark := Color(0.40, 0.28, 0.15)
	for x in range(TILE_SIZE):
		for y in range(TILE_SIZE):
			var dx := float(x) - 7.5
			var dy := float(y) - 7.5
			var dist := sqrt(dx * dx + dy * dy)
			if dist <= 7.0 and dist >= 4.0:
				image.set_pixel(x, y, light if (x + y) % 2 == 0 else dark)
	_nest_ring = ImageTexture.create_from_image(image)
	return _nest_ring


func alpha_badge_texture() -> Texture2D:
	if _alpha_badge != null:
		return _alpha_badge
	var image := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	for x in range(8):
		for y in range(8):
			var diamond := absi(x - 3) + absi(y - 3)
			if diamond <= 2:
				image.set_pixel(x, y, Color(0.86, 0.16, 0.16))
			elif diamond == 3:
				image.set_pixel(x, y, Color.WHITE) # 1px outline so the badge reads on any mon
	_alpha_badge = ImageTexture.create_from_image(image)
	return _alpha_badge


func _map_to_world(map_pos: Vector2i) -> Vector2:
	return Vector2(map_pos.x * TILE_SIZE, map_pos.y * TILE_SIZE)
