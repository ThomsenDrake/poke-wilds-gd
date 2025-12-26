extends Node
## BuildManager - Handles structure placement, construction, and removal
## Manages the building system in the overworld

# Signals
signal build_mode_entered()
signal build_mode_exited()
signal structure_placed(structure_id: String, tile: Vector2i)
signal structure_removed(tile: Vector2i)
signal placement_failed(reason: String)
signal preview_updated(tile: Vector2i, valid: bool)

# Build state
var is_build_mode: bool = false
var selected_structure_id: String = ""
var preview_tile: Vector2i = Vector2i.ZERO
var is_preview_valid: bool = false

# References (set by overworld)
var player_ref: Node = null
var tilemap_ref: Node = null
var structures_container: Node2D = null

# Placed structures: Dictionary of Vector2i -> Structure node
var _placed_structures: Dictionary = {}

# Constants
const STRUCTURE_SCENE_PATH := "res://scenes/structures/structure.tscn"


func _ready() -> void:
	print("BuildManager initialized")


## Set references from overworld scene
func set_references(player: Node, tilemap: Node, container: Node2D) -> void:
	player_ref = player
	tilemap_ref = tilemap
	structures_container = container


## Enter build mode with a specific structure
func enter_build_mode(structure_id: String) -> bool:
	var structure := StructureDatabase.get_structure(structure_id)
	if structure == null:
		push_error("BuildManager: Unknown structure ID: ", structure_id)
		return false
	
	if not structure.can_afford(GameManager.player_inventory):
		placement_failed.emit("Not enough materials!")
		return false
	
	selected_structure_id = structure_id
	is_build_mode = true
	
	if player_ref:
		preview_tile = player_ref.get_facing_tile()
		_update_preview()
	
	build_mode_entered.emit()
	return true


## Exit build mode
func exit_build_mode() -> void:
	is_build_mode = false
	selected_structure_id = ""
	is_preview_valid = false
	build_mode_exited.emit()


## Update preview position (called when player moves/turns)
func update_preview_position() -> void:
	if not is_build_mode or player_ref == null:
		return
	
	preview_tile = player_ref.get_facing_tile()
	_update_preview()


## Attempt to place structure at preview position
func place_structure() -> bool:
	if not is_build_mode:
		return false
	
	if not is_preview_valid:
		placement_failed.emit("Can't build here!")
		return false
	
	var structure := StructureDatabase.get_structure(selected_structure_id)
	if structure == null:
		return false
	
	# Check materials again
	if not structure.can_afford(GameManager.player_inventory):
		placement_failed.emit("Not enough materials!")
		return false
	
	# Consume materials
	structure.consume_materials(GameManager.player_inventory)
	
	# Create structure instance
	var structure_node := _create_structure_node(structure, preview_tile)
	if structure_node == null:
		push_error("Failed to create structure node!")
		return false
	
	# Add to container
	if structures_container:
		structures_container.add_child(structure_node)
	
	# Register placement
	_placed_structures[preview_tile] = structure_node
	
	structure_placed.emit(selected_structure_id, preview_tile)
	
	# Update preview for next placement
	_update_preview()
	
	return true


## Remove a structure at tile
func remove_structure(tile: Vector2i) -> bool:
	if not _placed_structures.has(tile):
		return false
	
	var structure_node: Node = _placed_structures[tile]
	var structure_data: StructureData = structure_node.get_meta("structure_data", null)
	
	# Optionally return some materials
	if structure_data:
		for item_id in structure_data.recipe.keys():
			var amount: int = structure_data.recipe[item_id]
			# Return half materials
			var refund := int(ceil(amount * 0.5))
			if refund > 0:
				GameManager.player_inventory.add_item(item_id, refund)
	
	# Remove from world
	structure_node.queue_free()
	_placed_structures.erase(tile)
	
	structure_removed.emit(tile)
	return true


## Check if a tile has a structure
func has_structure_at(tile: Vector2i) -> bool:
	return _placed_structures.has(tile)


## Get structure at tile
func get_structure_at(tile: Vector2i) -> Node:
	return _placed_structures.get(tile)


## Get structure data at tile
func get_structure_data_at(tile: Vector2i) -> StructureData:
	var node: Node = _placed_structures.get(tile)
	if node:
		return node.get_meta("structure_data", null)
	return null


## Check if placement is valid at tile
func can_place_at(structure: StructureData, tile: Vector2i) -> bool:
	# Check if tile already has structure
	if _placed_structures.has(tile):
		return false
	
	# Check multi-tile structures
	for x in range(structure.width):
		for y in range(structure.height):
			var check_tile := tile + Vector2i(x, y)
			if _placed_structures.has(check_tile):
				return false
	
	# Check tilemap requirements
	if tilemap_ref:
		var tile_name: String = tilemap_ref.get_tile_name(tile)
		
		# Check water placement
		if tile_name == "water" or tile_name == "deep_water":
			if not structure.can_place_on_water:
				return false
		
		# Check solid tiles (can't build on trees, rocks)
		if tilemap_ref.is_tile_solid(tile) and not structure.can_place_on_water:
			return false
	
	# Check floor requirement
	if structure.requires_floor:
		# Either needs natural ground or a floor structure
		var has_floor := false
		if tilemap_ref:
			var floor_tile_name: String = tilemap_ref.get_tile_name(tile)
			if floor_tile_name in ["grass", "dirt", "sand", "path"]:
				has_floor = true
		
		# Check for floor structure
		if not has_floor:
			var floor_structure := get_structure_data_at(tile)
			if floor_structure and floor_structure.function == StructureData.Function.WALKABLE:
				has_floor = true
		
		if not has_floor:
			return false
	
	return true


## Update preview validity
func _update_preview() -> void:
	if not is_build_mode:
		return
	
	var structure := StructureDatabase.get_structure(selected_structure_id)
	if structure == null:
		is_preview_valid = false
		return
	
	is_preview_valid = can_place_at(structure, preview_tile)
	preview_updated.emit(preview_tile, is_preview_valid)


## Create a structure node
func _create_structure_node(structure: StructureData, tile: Vector2i) -> Node2D:
	var node := Node2D.new()
	node.name = structure.id + "_" + str(tile.x) + "_" + str(tile.y)
	
	# Position at tile center
	node.position = Vector2(tile.x * 16 + 8, tile.y * 16 + 8)
	
	# Store structure data
	node.set_meta("structure_data", structure)
	node.set_meta("tile_position", tile)
	
	# Create visual representation
	var sprite := Sprite2D.new()
	sprite.name = "Sprite"
	
	# Try to load sprite or use colored rect
	if structure.sprite_path != "" and ResourceLoader.exists(structure.sprite_path):
		sprite.texture = load(structure.sprite_path)
	else:
		# Create a simple colored texture
		var image := Image.create(16 * structure.width, 16 * structure.height, false, Image.FORMAT_RGBA8)
		image.fill(structure.color)
		# Add border
		for x in range(image.get_width()):
			image.set_pixel(x, 0, structure.color.darkened(0.3))
			image.set_pixel(x, image.get_height() - 1, structure.color.darkened(0.3))
		for y in range(image.get_height()):
			image.set_pixel(0, y, structure.color.darkened(0.3))
			image.set_pixel(image.get_width() - 1, y, structure.color.darkened(0.3))
		sprite.texture = ImageTexture.create_from_image(image)
	
	node.add_child(sprite)
	
	# Add to solid group if blocking
	if structure.blocks_movement:
		node.add_to_group("solid")
		node.add_to_group("structures")
	
	# Add collision for interaction
	var area := Area2D.new()
	area.name = "InteractionArea"
	var collision := CollisionShape2D.new()
	var shape := RectangleShape2D.new()
	shape.size = Vector2(16 * structure.width, 16 * structure.height)
	collision.shape = shape
	area.add_child(collision)
	node.add_child(area)
	
	return node


## Interact with structure at tile
func interact_with_structure(tile: Vector2i) -> Dictionary:
	var result := {"success": false, "message": "", "action": ""}
	
	if not _placed_structures.has(tile):
		return result
	
	var structure_node: Node = _placed_structures[tile]
	var structure: StructureData = structure_node.get_meta("structure_data", null)
	
	if structure == null:
		return result
	
	result.success = true
	
	match structure.function:
		StructureData.Function.STORAGE:
			result.action = "open_storage"
			result.message = "Opened " + structure.display_name
		
		StructureData.Function.CRAFTING:
			result.action = "open_crafting"
			result.message = "Using " + structure.display_name
		
		StructureData.Function.HEALING:
			_heal_all_pokemon()
			result.action = "healed"
			result.message = "Your Pokemon were healed!"
		
		StructureData.Function.PC_ACCESS:
			result.action = "open_pc"
			result.message = "Accessing PC..."
		
		StructureData.Function.SLEEP:
			result.action = "sleep"
			result.message = "Rest and save game?"
		
		StructureData.Function.BREEDING:
			result.action = "open_breeding"
			result.message = "Breeding Den"
		
		_:
			result.message = structure.display_name
	
	return result


## Heal all Pokemon in party
func _heal_all_pokemon() -> void:
	for pokemon in GameManager.player_party:
		if pokemon:
			pokemon.current_hp = pokemon.max_hp
			pokemon.status = Pokemon.Status.NONE
			pokemon.status_turns = 0
			# Restore PP
			for i in range(pokemon.move_pp.size()):
				var move := MoveDatabase.get_move(pokemon.move_ids[i])
				if move:
					pokemon.move_pp[i] = move.max_pp


## Get all placed structures (for saving)
func get_placed_structures_data() -> Array[Dictionary]:
	var data: Array[Dictionary] = []
	for tile in _placed_structures.keys():
		var structure: StructureData = _placed_structures[tile].get_meta("structure_data")
		if structure:
			data.append({
				"id": structure.id,
				"x": tile.x,
				"y": tile.y
			})
	return data


## Load placed structures from save data
func load_placed_structures(data: Array) -> void:
	# Clear existing
	for node in _placed_structures.values():
		node.queue_free()
	_placed_structures.clear()
	
	# Load saved
	for entry in data:
		var structure := StructureDatabase.get_structure(entry.get("id", ""))
		var tile := Vector2i(entry.get("x", 0), entry.get("y", 0))
		
		if structure:
			var node := _create_structure_node(structure, tile)
			if node and structures_container:
				structures_container.add_child(node)
				_placed_structures[tile] = node
