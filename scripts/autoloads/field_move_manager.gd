extends Node
## FieldMoveManager - Handles field move execution in the overworld
## Manages CUT, SURF, DIG, FLY, ROCK_SMASH, STRENGTH, etc.

# Signals
signal field_move_started(move_name: String, pokemon: Pokemon)
signal field_move_completed(move_name: String, success: bool, result: Dictionary)
signal surf_started(pokemon: Pokemon)
signal surf_ended()
signal message_shown(message: String)

# Field move types
enum FieldMove {
	CUT,
	DIG,
	BUILD,
	SURF,
	FLY,
	FLASH,
	ROCK_SMASH,
	STRENGTH,
	WATERFALL,
	HEADBUTT,
	HARVEST
}

# Current state
var is_surfing: bool = false
var surf_pokemon: Pokemon = null
var is_using_move: bool = false

# References (set by overworld)
var player_ref: Node = null
var tilemap_ref: Node = null
var world_generator_ref: RefCounted = null


func _ready() -> void:
	print("FieldMoveManager initialized")


## Set references from overworld scene
func set_references(player: Node, tilemap: Node, world_gen: RefCounted = null) -> void:
	player_ref = player
	tilemap_ref = tilemap
	world_generator_ref = world_gen


## Check if a Pokemon can use a specific field move
func can_use_field_move(pokemon: Pokemon, move: FieldMove) -> bool:
	if pokemon == null or pokemon.is_fainted():
		return false
	
	var species := pokemon.get_species()
	if species == null:
		return false
	
	match move:
		FieldMove.CUT: return species.can_cut
		FieldMove.DIG: return species.can_dig
		FieldMove.BUILD: return species.can_build
		FieldMove.SURF: return species.can_surf
		FieldMove.FLY: return species.can_fly
		FieldMove.FLASH: return species.can_flash
		FieldMove.ROCK_SMASH: return species.can_rock_smash
		FieldMove.STRENGTH: return species.can_strength
		FieldMove.WATERFALL: return species.can_waterfall
		FieldMove.HEADBUTT: return species.can_headbutt
		FieldMove.HARVEST: return species.can_harvest
		_: return false


## Get all party Pokemon that can use a field move
func get_pokemon_for_move(move: FieldMove) -> Array[Pokemon]:
	var result: Array[Pokemon] = []
	for pokemon in GameManager.player_party:
		if can_use_field_move(pokemon, move):
			result.append(pokemon)
	return result


## Check if any party Pokemon can use a field move
func party_has_field_move(move: FieldMove) -> bool:
	return not get_pokemon_for_move(move).is_empty()


## Get available field moves for a Pokemon
func get_available_moves(pokemon: Pokemon) -> Array[FieldMove]:
	var moves: Array[FieldMove] = []
	for move in FieldMove.values():
		if can_use_field_move(pokemon, move):
			moves.append(move)
	return moves


## Get field move name for display
func get_move_name(move: FieldMove) -> String:
	match move:
		FieldMove.CUT: return "Cut"
		FieldMove.DIG: return "Dig"
		FieldMove.BUILD: return "Build"
		FieldMove.SURF: return "Surf"
		FieldMove.FLY: return "Fly"
		FieldMove.FLASH: return "Flash"
		FieldMove.ROCK_SMASH: return "Rock Smash"
		FieldMove.STRENGTH: return "Strength"
		FieldMove.WATERFALL: return "Waterfall"
		FieldMove.HEADBUTT: return "Headbutt"
		FieldMove.HARVEST: return "Harvest"
		_: return "???"


## Execute a field move
func use_field_move(pokemon: Pokemon, move: FieldMove, target_tile: Vector2i = Vector2i.ZERO) -> Dictionary:
	if is_using_move:
		return {"success": false, "message": "Already using a move!"}
	
	if not can_use_field_move(pokemon, move):
		return {"success": false, "message": pokemon.get_display_name() + " can't use that!"}
	
	is_using_move = true
	field_move_started.emit(get_move_name(move), pokemon)
	
	var result: Dictionary
	
	match move:
		FieldMove.CUT:
			result = await _execute_cut(pokemon, target_tile)
		FieldMove.SURF:
			result = await _execute_surf(pokemon)
		FieldMove.ROCK_SMASH:
			result = await _execute_rock_smash(pokemon, target_tile)
		FieldMove.DIG:
			result = await _execute_dig(pokemon, target_tile)
		FieldMove.HEADBUTT:
			result = await _execute_headbutt(pokemon, target_tile)
		FieldMove.STRENGTH:
			result = await _execute_strength(pokemon, target_tile)
		FieldMove.FLY:
			result = await _execute_fly(pokemon)
		FieldMove.FLASH:
			result = await _execute_flash(pokemon)
		FieldMove.HARVEST:
			result = await _execute_harvest(pokemon)
		_:
			result = {"success": false, "message": "Move not implemented yet!"}
	
	is_using_move = false
	field_move_completed.emit(get_move_name(move), result.success, result)
	
	return result


# ============ Field Move Implementations ============

## CUT - Chop down trees to get wood
func _execute_cut(pokemon: Pokemon, target_tile: Vector2i) -> Dictionary:
	if tilemap_ref == null:
		return {"success": false, "message": "No tilemap reference!"}
	
	# Check if target tile is a tree
	var tile_name: String = tilemap_ref.get_tile_name(target_tile)
	if tile_name != "tree":
		return {"success": false, "message": "Nothing to cut here!"}
	
	# Show message
	message_shown.emit(pokemon.get_display_name() + " used CUT!")
	await get_tree().create_timer(0.5).timeout
	
	# Remove the tree tile
	tilemap_ref.set_tile(target_tile, "grass")
	
	# Give player wood
	var wood_amount := randi_range(1, 3)
	GameManager.player_inventory.add_item("WOOD", wood_amount)
	
	message_shown.emit("Got " + str(wood_amount) + " Wood!")
	await get_tree().create_timer(0.5).timeout
	
	return {
		"success": true,
		"message": "Cut the tree!",
		"items": {"WOOD": wood_amount}
	}


## SURF - Ride on water
func _execute_surf(pokemon: Pokemon) -> Dictionary:
	if player_ref == null or tilemap_ref == null:
		return {"success": false, "message": "Missing references!"}
	
	if is_surfing:
		# End surfing
		return _end_surf()
	
	# Check if facing water
	var facing_tile: Vector2i = player_ref.get_facing_tile()
	var tile_name: String = tilemap_ref.get_tile_name(facing_tile)
	
	if tile_name != "water" and tile_name != "deep_water":
		return {"success": false, "message": "Can't surf here!"}
	
	# Start surfing
	message_shown.emit(pokemon.get_display_name() + " used SURF!")
	await get_tree().create_timer(0.5).timeout
	
	is_surfing = true
	surf_pokemon = pokemon
	
	# Move player onto water
	player_ref.teleport_to(facing_tile)
	player_ref.set_surfing(true)
	
	surf_started.emit(pokemon)
	
	return {
		"success": true,
		"message": "Started surfing!",
		"surfing": true
	}


func _end_surf() -> Dictionary:
	if not is_surfing:
		return {"success": false, "message": "Not surfing!"}
	
	# Check if facing land
	var facing_tile: Vector2i = player_ref.get_facing_tile()
	var tile_name: String = tilemap_ref.get_tile_name(facing_tile)
	
	if tile_name == "water" or tile_name == "deep_water":
		return {"success": false, "message": "Can't get off here!"}
	
	if tilemap_ref.is_tile_solid(facing_tile):
		return {"success": false, "message": "Can't get off here!"}
	
	# End surfing
	player_ref.teleport_to(facing_tile)
	player_ref.set_surfing(false)
	
	is_surfing = false
	surf_pokemon = null
	
	surf_ended.emit()
	
	return {
		"success": true,
		"message": "Stopped surfing!",
		"surfing": false
	}


## Check if player should auto-end surf (reaching land)
func check_surf_end(current_tile: Vector2i) -> void:
	if not is_surfing:
		return
	
	var tile_name: String = tilemap_ref.get_tile_name(current_tile)
	if tile_name != "water" and tile_name != "deep_water":
		# Stepped onto land
		is_surfing = false
		surf_pokemon = null
		player_ref.set_surfing(false)
		surf_ended.emit()


## ROCK_SMASH - Break rocks for items
func _execute_rock_smash(pokemon: Pokemon, target_tile: Vector2i) -> Dictionary:
	if tilemap_ref == null:
		return {"success": false, "message": "No tilemap reference!"}
	
	var tile_name: String = tilemap_ref.get_tile_name(target_tile)
	if tile_name != "rock":
		return {"success": false, "message": "Nothing to smash here!"}
	
	message_shown.emit(pokemon.get_display_name() + " used ROCK SMASH!")
	await get_tree().create_timer(0.5).timeout
	
	# Remove the rock
	tilemap_ref.set_tile(target_tile, "dirt")
	
	# Give player stone (and maybe fossils/items)
	var stone_amount := randi_range(1, 2)
	GameManager.player_inventory.add_item("STONE", stone_amount)
	
	message_shown.emit("Got " + str(stone_amount) + " Stone!")
	await get_tree().create_timer(0.5).timeout
	
	# Small chance of wild Pokemon encounter
	if randi() % 10 == 0:
		# TODO: Trigger rock Pokemon encounter (Geodude, etc.)
		pass
	
	return {
		"success": true,
		"message": "Smashed the rock!",
		"items": {"STONE": stone_amount}
	}


## DIG - Create or enter tunnels
func _execute_dig(pokemon: Pokemon, target_tile: Vector2i) -> Dictionary:
	message_shown.emit(pokemon.get_display_name() + " used DIG!")
	await get_tree().create_timer(0.5).timeout
	
	# For now, just escape from caves or return to last visited spot
	# Full tunnel system would require more infrastructure
	
	message_shown.emit("Dug an escape tunnel!")
	await get_tree().create_timer(0.5).timeout
	
	return {
		"success": true,
		"message": "Escaped using DIG!",
		"escaped": true
	}


## HEADBUTT - Shake trees for Pokemon
func _execute_headbutt(pokemon: Pokemon, target_tile: Vector2i) -> Dictionary:
	if tilemap_ref == null:
		return {"success": false, "message": "No tilemap reference!"}
	
	var tile_name: String = tilemap_ref.get_tile_name(target_tile)
	if tile_name != "tree":
		return {"success": false, "message": "Nothing to headbutt here!"}
	
	message_shown.emit(pokemon.get_display_name() + " used HEADBUTT!")
	await get_tree().create_timer(0.5).timeout
	
	# Chance of Pokemon falling out
	if randi() % 3 == 0:
		message_shown.emit("A Pokemon fell out!")
		await get_tree().create_timer(0.3).timeout
		
		# TODO: Trigger headbutt encounter (Pineco, Heracross, etc.)
		return {
			"success": true,
			"message": "Found a Pokemon!",
			"encounter": true
		}
	else:
		message_shown.emit("Nothing fell out...")
		await get_tree().create_timer(0.3).timeout
		
		return {
			"success": true,
			"message": "Nothing happened.",
			"encounter": false
		}


## STRENGTH - Push boulders
func _execute_strength(pokemon: Pokemon, target_tile: Vector2i) -> Dictionary:
	if tilemap_ref == null or player_ref == null:
		return {"success": false, "message": "Missing references!"}
	
	var tile_name: String = tilemap_ref.get_tile_name(target_tile)
	if tile_name != "rock":
		return {"success": false, "message": "Nothing to push here!"}
	
	# Check if boulder can be pushed (tile behind it is empty)
	var push_direction: Vector2i = target_tile - player_ref.grid_position
	var destination: Vector2i = target_tile + push_direction
	
	if tilemap_ref.is_tile_solid(destination):
		return {"success": false, "message": "Can't push it that way!"}
	
	var dest_tile: String = tilemap_ref.get_tile_name(destination)
	if dest_tile == "water" or dest_tile == "deep_water":
		# Boulder falls into water
		message_shown.emit(pokemon.get_display_name() + " used STRENGTH!")
		await get_tree().create_timer(0.3).timeout
		
		tilemap_ref.set_tile(target_tile, "dirt")
		# Water tile stays as water (boulder sinks)
		
		message_shown.emit("The boulder fell into the water!")
		await get_tree().create_timer(0.3).timeout
		
		return {"success": true, "message": "Boulder pushed into water!"}
	
	message_shown.emit(pokemon.get_display_name() + " used STRENGTH!")
	await get_tree().create_timer(0.3).timeout
	
	# Move the boulder
	tilemap_ref.set_tile(target_tile, "dirt")
	tilemap_ref.set_tile(destination, "rock")
	
	return {
		"success": true,
		"message": "Pushed the boulder!"
	}


## FLY - Fast travel
func _execute_fly(pokemon: Pokemon) -> Dictionary:
	message_shown.emit(pokemon.get_display_name() + " used FLY!")
	await get_tree().create_timer(0.5).timeout
	
	# For now, just return to spawn
	# Full fly system would need visited locations tracking
	
	if player_ref and world_generator_ref:
		var spawn: Vector2i = world_generator_ref.find_spawn_point()
		player_ref.teleport_to(spawn)
		
		message_shown.emit("Flew back to the starting area!")
		await get_tree().create_timer(0.5).timeout
		
		return {
			"success": true,
			"message": "Flew to destination!",
			"destination": spawn
		}
	
	return {"success": false, "message": "Can't fly right now!"}


## FLASH - Light up dark areas
func _execute_flash(pokemon: Pokemon) -> Dictionary:
	message_shown.emit(pokemon.get_display_name() + " used FLASH!")
	await get_tree().create_timer(0.5).timeout
	
	message_shown.emit("The area became brighter!")
	await get_tree().create_timer(0.3).timeout
	
	# TODO: Implement darkness/light system
	
	return {
		"success": true,
		"message": "Lit up the area!"
	}


## HARVEST - Gather resources from Pokemon
func _execute_harvest(pokemon: Pokemon) -> Dictionary:
	var species := pokemon.get_species()
	if species == null or species.harvestables.is_empty():
		return {"success": false, "message": "Nothing to harvest!"}
	
	message_shown.emit(pokemon.get_display_name() + " gathered resources!")
	await get_tree().create_timer(0.5).timeout
	
	# Give random harvestable item
	var item_id: String = species.harvestables[randi() % species.harvestables.size()]
	GameManager.player_inventory.add_item(item_id, 1)
	
	var item := ItemDatabase.get_item(item_id)
	var item_name := item.display_name if item else item_id
	
	message_shown.emit("Got " + item_name + "!")
	await get_tree().create_timer(0.3).timeout
	
	return {
		"success": true,
		"message": "Harvested " + item_name,
		"items": {item_id: 1}
	}


## Get field move from string (for UI)
func get_move_from_string(move_name: String) -> FieldMove:
	match move_name.to_upper():
		"CUT": return FieldMove.CUT
		"DIG": return FieldMove.DIG
		"BUILD": return FieldMove.BUILD
		"SURF": return FieldMove.SURF
		"FLY": return FieldMove.FLY
		"FLASH": return FieldMove.FLASH
		"ROCK_SMASH", "ROCK SMASH": return FieldMove.ROCK_SMASH
		"STRENGTH": return FieldMove.STRENGTH
		"WATERFALL": return FieldMove.WATERFALL
		"HEADBUTT": return FieldMove.HEADBUTT
		"HARVEST": return FieldMove.HARVEST
		_: return FieldMove.CUT  # Default
