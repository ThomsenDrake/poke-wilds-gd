extends Node2D
## Overworld - Main overworld scene controller
## Manages the overworld map, player, NPCs, and wild Pokemon encounters

# Signals
signal encounter_started(pokemon_data: Dictionary)
signal warp_triggered(destination: String, spawn_point: String)

# Node references
@onready var player: Player = $Player
@onready var camera: Camera2D = $Player/Camera2D  # Uses CameraController script
var tilemap_manager: TileMapManager = null  # Created in _ready if not present

# World generation
var world_generator: WorldGenerator

# State
var current_map_id: String = ""
var is_indoor: bool = false
var encounter_enabled: bool = true

# UI
var _start_menu: StartMenu = null
var _message_label: Label = null
var _build_preview: Sprite2D = null

# Structures
var _structures_container: Node2D = null

# Pokemon
var _pokemon_container: Node2D = null
var _breeding_menu: BreedingMenu = null

# Encounter tracking
var _steps_since_encounter: int = 0
const MIN_STEPS_BETWEEN_ENCOUNTERS := 4
const BASE_ENCOUNTER_RATE := 10  # 1 in 10 chance per step in tall grass


func _ready() -> void:
	# Initialize world generator with seed from GameManager
	world_generator = WorldGenerator.new(GameManager.current_seed)
	
	# Setup TileMapManager - try to get from scene first
	tilemap_manager = get_node_or_null("TileMapManager") as TileMapManager
	if tilemap_manager:
		tilemap_manager.initialize(world_generator)
	else:
		# Create TileMapManager if not in scene
		_create_tilemap_manager()
	
	# Connect player signals
	if player:
		player.step_completed.connect(_on_player_step_completed)
		player.interaction_requested.connect(_on_player_interaction)
		
		# Find a spawn point and place player
		var spawn := world_generator.find_spawn_point()
		player.teleport_to(spawn)
		print("Player spawned at: ", spawn)
	
	# Camera setup is handled by CameraController script
	# Zoom controls: Q = zoom out, E = zoom in, R = reset, F11 = fullscreen
	if camera:
		print("Camera ready with zoom controls (Q/E/R) and fullscreen (F11)")
	
	# Initial chunk load
	if tilemap_manager and player:
		tilemap_manager.update_chunks(player.position)
	
	# Connect to battle end signal
	BattleManager.battle_ended.connect(_on_battle_ended)
	
	# Setup FieldMoveManager references
	FieldMoveManager.set_references(player, tilemap_manager, world_generator)
	FieldMoveManager.message_shown.connect(_on_field_move_message)
	FieldMoveManager.surf_started.connect(_on_surf_started)
	FieldMoveManager.surf_ended.connect(_on_surf_ended)
	
	# Create message label for field move messages
	_create_message_label()
	
	# Create structures container
	_create_structures_container()
	
	# Setup BuildManager references
	BuildManager.set_references(player, tilemap_manager, _structures_container)
	BuildManager.preview_updated.connect(_on_build_preview_updated)
	BuildManager.structure_placed.connect(_on_structure_placed)
	BuildManager.placement_failed.connect(_on_placement_failed)
	
	# Create build preview sprite
	_create_build_preview()
	
	# Create Pokemon container
	_create_pokemon_container()
	
	# Setup HabitatManager for wild Pokemon spawning
	HabitatManager.set_references(player, tilemap_manager, _pokemon_container)
	
	# Setup RanchManager for ranch Pokemon
	RanchManager.set_container(_pokemon_container)
	
	# Add player to group for OverworldPokemon to find
	if player:
		player.add_to_group("player")
	
	# Set game state
	GameManager.change_state(GameManager.GameState.OVERWORLD)
	
	print("Overworld ready - Seed: ", world_generator.world_seed)


func _create_tilemap_manager() -> void:
	"""Create TileMapManager programmatically"""
	tilemap_manager = TileMapManager.new()
	tilemap_manager.name = "TileMapManager"
	add_child(tilemap_manager)
	move_child(tilemap_manager, 0)  # Put behind player
	tilemap_manager.initialize(world_generator)
	
	# Create a basic tileset for rendering
	_setup_tileset()


func _setup_tileset() -> void:
	"""Setup tileset using actual tile textures from assets/sprites/tiles/"""
	var tileset := TileSet.new()
	tileset.tile_size = Vector2i(16, 16)
	
	var atlas := TileSetAtlasSource.new()
	atlas.texture_region_size = Vector2i(16, 16)
	
	# Tile layout in atlas (8 columns x 2 rows = 128x32):
	# Row 0: grass, tallgrass, water, deep_water, sand, dirt, tree_bottom, rock
	# Row 1: flower, path, tree_top, (unused...)
	const TILE_PATH := "res://assets/sprites/tiles/"
	var tile_sources := {
		Vector2i(0, 0): "grass1.png",
		Vector2i(1, 0): "tallgrass.png",
		Vector2i(2, 0): "water2.png",      # Will use left 16x16 of 32x16
		Vector2i(3, 0): "water2.png",      # Deep water - same for now, tinted
		Vector2i(4, 0): "sand1.png",
		Vector2i(5, 0): "ground1.png",     # Dirt
		Vector2i(6, 0): "tree1.png",       # Tree bottom (trunk) - bottom 16x16
		Vector2i(7, 0): "rock5.png",
		Vector2i(0, 1): "flower1.png",
		Vector2i(1, 1): "path1.png",
		Vector2i(2, 1): "tree1.png",       # Tree top (foliage) - top 16x16
	}
	
	# Create combined atlas image (128x32 = 8 tiles wide, 2 tall)
	var atlas_image := Image.create(128, 32, false, Image.FORMAT_RGBA8)
	atlas_image.fill(Color(0, 0, 0, 0))  # Transparent background
	
	for coord in tile_sources:
		var filename: String = tile_sources[coord]
		var source_texture := load(TILE_PATH + filename) as Texture2D
		if source_texture == null:
			push_warning("Could not load tile: " + filename)
			continue
		
		var source_image := source_texture.get_image()
		var dest_x: int = int(coord.x) * 16
		var dest_y: int = int(coord.y) * 16
		
		# Handle special cases
		var src_rect := Rect2i(0, 0, 16, 16)
		if filename == "tree1.png" and coord == Vector2i(6, 0):
			# Tree bottom (trunk) - use bottom 16x16 of 16x32
			src_rect = Rect2i(0, 16, 16, 16)
		elif filename == "tree1.png" and coord == Vector2i(2, 1):
			# Tree top (foliage) - use top 16x16 of 16x32
			src_rect = Rect2i(0, 0, 16, 16)
		elif filename == "water2.png":
			# Water is 32x16 - use left 16x16
			src_rect = Rect2i(0, 0, 16, 16)
			# For deep water (3,0), darken it
			if coord == Vector2i(3, 0):
				var water_image := source_image.get_region(src_rect)
				for px in range(16):
					for py in range(16):
						var c := water_image.get_pixel(px, py)
						water_image.set_pixel(px, py, c.darkened(0.3))
				atlas_image.blit_rect(water_image, Rect2i(0, 0, 16, 16), Vector2i(dest_x, dest_y))
				continue
		
		# Blit the tile to atlas
		atlas_image.blit_rect(source_image, src_rect, Vector2i(dest_x, dest_y))
	
	var atlas_texture := ImageTexture.create_from_image(atlas_image)
	atlas.texture = atlas_texture
	
	# Create tile definitions in atlas
	for coord in tile_sources:
		atlas.create_tile(coord)
	
	tileset.add_source(atlas, 0)
	
	# Apply tileset to all layers
	if tilemap_manager.ground_layer:
		tilemap_manager.ground_layer.tile_set = tileset
	if tilemap_manager.decoration_layer:
		tilemap_manager.decoration_layer.tile_set = tileset
	if tilemap_manager.collision_layer:
		tilemap_manager.collision_layer.tile_set = tileset
	
	print("Tileset loaded with ", tile_sources.size(), " tile types")


func _process(_delta: float) -> void:
	# Update chunks based on player position
	if tilemap_manager and player:
		tilemap_manager.update_chunks(player.position)


func _on_player_step_completed(direction: Player.Direction) -> void:
	"""Called when player finishes a step"""
	_steps_since_encounter += 1
	
	# Check if surfing ended (stepped onto land)
	if FieldMoveManager.is_surfing:
		FieldMoveManager.check_surf_end(player.grid_position)
	
	# Check for encounter on this tile
	if encounter_enabled and _should_trigger_encounter():
		_trigger_wild_encounter()


func _should_trigger_encounter() -> bool:
	"""Determine if a wild encounter should trigger"""
	if _steps_since_encounter < MIN_STEPS_BETWEEN_ENCOUNTERS:
		return false
	
	# Check if player is on encounter tile
	if tilemap_manager:
		if not tilemap_manager.is_encounter_tile(player.grid_position):
			return false
	
	# Roll for encounter
	var roll := randi() % BASE_ENCOUNTER_RATE
	return roll == 0


func _trigger_wild_encounter() -> void:
	"""Start a wild Pokemon encounter"""
	_steps_since_encounter = 0
	
	# Freeze player
	if player:
		player.can_move = false
	
	# Get tile type for encounter context
	var tile_name := "grass"
	if tilemap_manager:
		tile_name = tilemap_manager.get_tile_name(player.grid_position)
	
	# Generate encounter data
	var species_id := _get_random_wild_pokemon(tile_name)
	var level := _get_encounter_level()
	
	print("Wild encounter! ", species_id, " Lv.", level, " (", tile_name, ")")
	
	# Create wild Pokemon
	var wild_pokemon := SpeciesDatabase.create_pokemon(species_id, level)
	if wild_pokemon == null:
		# Fallback if species not found
		wild_pokemon = SpeciesDatabase.create_pokemon("BULBASAUR", level)
	
	if wild_pokemon == null:
		push_error("Failed to create wild Pokemon!")
		player.can_move = true
		return
	
	# Ensure player has a party
	_ensure_player_party()
	
	# Emit signal for main scene to handle transition
	var encounter_data := {
		"type": "wild",
		"species": species_id,
		"level": level,
		"tile": tile_name,
		"pokemon": wild_pokemon
	}
	
	encounter_started.emit(encounter_data)
	
	# Change game state to battle - main.gd will handle the scene transition
	GameManager.change_state(GameManager.GameState.BATTLE)
	
	# Start the battle via BattleManager
	BattleManager.start_wild_battle(GameManager.player_party, wild_pokemon)


func _get_random_wild_pokemon(tile_type: String) -> String:
	"""Get a random Pokemon species based on terrain"""
	var pokemon: Array
	
	match tile_type:
		"tall_grass":
			pokemon = ["BULBASAUR", "ODDISH", "BELLSPROUT", "CATERPIE", "WEEDLE"]
		"water", "deep_water":
			pokemon = ["SQUIRTLE", "MAGIKARP", "GOLDEEN", "PSYDUCK"]
		_:
			pokemon = ["RATTATA", "PIDGEY", "SPEAROW"]
	
	return pokemon[randi() % pokemon.size()]


func _get_encounter_level() -> int:
	"""Get level for wild encounter based on distance from spawn"""
	var dist := Vector2(player.grid_position).length()
	var base_level := 3 + int(dist / 20)
	var variance := randi() % 3
	return clampi(base_level + variance, 2, 50)


func _ensure_player_party() -> void:
	"""Ensure player has at least one Pokemon in party for battles"""
	if GameManager.player_party.is_empty():
		# Create a starter Pokemon for the player
		var starter := SpeciesDatabase.create_pokemon("PIKACHU", 10)
		if starter:
			starter.nickname = "PIKACHU"
			GameManager.player_party.append(starter)
			print("Created starter Pokemon: ", starter.get_display_name(), " Lv", starter.level)
		else:
			push_error("Failed to create starter Pokemon!")


func _on_player_interaction(facing_tile: Vector2i) -> void:
	"""Handle player pressing A button"""
	# Check for structure interaction first
	if BuildManager.has_structure_at(facing_tile):
		var result := BuildManager.interact_with_structure(facing_tile)
		if result.success:
			_handle_structure_interaction(result)
			return
	
	if tilemap_manager:
		var tile_name := tilemap_manager.get_tile_name(facing_tile)
		print("Interacting with: ", tile_name, " at ", facing_tile)
		
		# Tree interaction (potential headbutt encounter)
		if tile_name == "tree":
			print("  -> It's a tree! (Headbutt would work here)")
		# Rock interaction (potential rock smash)
		elif tile_name == "rock":
			print("  -> It's a rock! (Rock Smash would work here)")
		# Water interaction
		elif tile_name == "water" or tile_name == "deep_water":
			print("  -> It's water! (Need Surf to cross)")


func _input(event: InputEvent) -> void:
	# Handle build mode input
	if BuildManager.is_build_mode:
		if event.is_action_pressed("button_a"):
			BuildManager.place_structure()
		elif event.is_action_pressed("button_b"):
			exit_build_mode()
		elif event.is_action_pressed("move_up") or event.is_action_pressed("move_down") or \
			 event.is_action_pressed("move_left") or event.is_action_pressed("move_right"):
			# Update preview when player changes direction
			if player:
				# Let player turn in place during build mode
				var dir := InputManager.get_direction()
				if dir != Vector2i.ZERO:
					var new_facing := player._direction_from_vector(dir)
					if new_facing != player.facing:
						player._face_direction(new_facing)
						BuildManager.update_preview_position()
		return
	
	# Start menu
	if event.is_action_pressed("button_start") and GameManager.current_state == GameManager.GameState.OVERWORLD:
		_open_start_menu()


func _open_start_menu() -> void:
	"""Open the start menu"""
	if _start_menu == null:
		_create_start_menu()
	
	if _start_menu:
		_start_menu.open()
		if player:
			player.can_move = false


func _create_start_menu() -> void:
	"""Create the start menu if it doesn't exist"""
	_start_menu = StartMenu.new()
	_start_menu.name = "StartMenu"
	_start_menu.menu_closed.connect(_on_start_menu_closed)
	_start_menu.field_move_requested.connect(_on_field_move_from_menu)
	_start_menu.build_requested.connect(_on_build_from_menu)
	add_child(_start_menu)


func _on_build_from_menu(structure_id: String) -> void:
	"""Handle build request from menu"""
	enter_build_mode(structure_id)


func _handle_structure_interaction(result: Dictionary) -> void:
	"""Handle interaction with a structure"""
	_show_message(result.message)
	
	match result.action:
		"open_pc":
			# Open PC menu
			if _start_menu == null:
				_create_start_menu()
			_start_menu.pc_menu.open()
		"healed":
			# Pokemon healed message already shown
			pass
		"sleep":
			# TODO: Implement save and rest
			pass
		"open_breeding":
			# Open breeding menu
			_open_breeding_menu(player.get_facing_tile())
		_:
			pass


func _on_field_move_from_menu(pokemon: Pokemon, move_name: String) -> void:
	"""Handle field move requested from party menu"""
	use_field_move(pokemon, move_name)


func _on_start_menu_closed() -> void:
	"""Handle start menu closing"""
	if player:
		player.can_move = true


func _on_battle_ended(result: String, data: Dictionary) -> void:
	"""Handle battle ending - return control to player"""
	print("Battle ended: ", result)
	
	# Handle different battle results
	match result:
		"victory":
			print("Player won the battle!")
		"fled":
			print("Player fled from battle!")
		"defeat":
			print("Player lost the battle!")
			# In PokeWilds, defeat might have different consequences
		"caught":
			# Add caught Pokemon to party or PC
			var caught_pokemon: Pokemon = data.get("pokemon")
			if caught_pokemon:
				if GameManager.can_add_to_party():
					GameManager.add_pokemon_to_party(caught_pokemon)
					print("Added ", caught_pokemon.get_display_name(), " to party!")
				else:
					GameManager.add_pokemon_to_pc(caught_pokemon)
					print("Party full! ", caught_pokemon.get_display_name(), " sent to PC!")
	
	# Return to overworld state
	GameManager.change_state(GameManager.GameState.OVERWORLD)
	
	# Re-enable player movement
	if player:
		player.can_move = true


## Teleport player to a specific tile
func teleport_player(tile: Vector2i) -> void:
	if player:
		player.teleport_to(tile)
		if tilemap_manager:
			tilemap_manager.update_chunks(player.position)


## Warp to another map
func warp_to(map_id: String, spawn_point: String) -> void:
	warp_triggered.emit(map_id, spawn_point)


## Create message label for field move feedback
func _create_message_label() -> void:
	var vp_width := GameManager.BASE_VIEWPORT_WIDTH
	var vp_height := GameManager.BASE_VIEWPORT_HEIGHT
	
	_message_label = Label.new()
	_message_label.name = "MessageLabel"
	_message_label.position = Vector2(4, vp_height - 24)  # 24px from bottom
	_message_label.size = Vector2(vp_width - 8, 20)
	_message_label.add_theme_font_size_override("font_size", 8)
	_message_label.add_theme_color_override("font_color", Color.WHITE)
	_message_label.add_theme_color_override("font_shadow_color", Color.BLACK)
	_message_label.add_theme_constant_override("shadow_offset_x", 1)
	_message_label.add_theme_constant_override("shadow_offset_y", 1)
	_message_label.visible = false
	
	# Add a background
	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.7)
	bg.size = Vector2(vp_width, 24)
	bg.position = Vector2(0, vp_height - 26)
	bg.name = "MessageBG"
	bg.visible = false
	
	# Add to a CanvasLayer so it's always on top
	var ui_layer := CanvasLayer.new()
	ui_layer.name = "UILayer"
	ui_layer.add_child(bg)
	ui_layer.add_child(_message_label)
	add_child(ui_layer)


## Show a message from field moves
func _on_field_move_message(message: String) -> void:
	if _message_label:
		_message_label.text = message
		_message_label.visible = true
		var bg := get_node_or_null("UILayer/MessageBG")
		if bg:
			bg.visible = true
		
		# Auto-hide after delay
		await get_tree().create_timer(1.5).timeout
		_message_label.visible = false
		if bg:
			bg.visible = false


## Handle surf started
func _on_surf_started(_pokemon: Pokemon) -> void:
	print("Surfing started!")
	# Disable random encounters on water?
	# Or enable water-specific encounters


## Handle surf ended
func _on_surf_ended() -> void:
	print("Surfing ended!")


## Use a field move from party menu
func use_field_move(pokemon: Pokemon, move_name: String) -> void:
	var move := FieldMoveManager.get_move_from_string(move_name)
	var target_tile := player.get_facing_tile() if player else Vector2i.ZERO
	
	# Freeze player during move
	if player:
		player.can_move = false
	
	var result = await FieldMoveManager.use_field_move(pokemon, move, target_tile)
	
	print("Field move result: ", result)
	
	# Re-enable player
	if player:
		player.can_move = true


# ============ Building System ============

## Create structures container
func _create_structures_container() -> void:
	_structures_container = Node2D.new()
	_structures_container.name = "Structures"
	add_child(_structures_container)
	# Move behind player but above tilemap
	move_child(_structures_container, 1)


## Create build preview sprite
func _create_build_preview() -> void:
	_build_preview = Sprite2D.new()
	_build_preview.name = "BuildPreview"
	_build_preview.visible = false
	_build_preview.modulate = Color(1, 1, 1, 0.5)
	add_child(_build_preview)


## Handle build preview update
func _on_build_preview_updated(tile: Vector2i, valid: bool) -> void:
	if _build_preview == null:
		return
	
	var structure := StructureDatabase.get_structure(BuildManager.selected_structure_id)
	if structure == null:
		_build_preview.visible = false
		return
	
	# Update preview position
	_build_preview.position = Vector2(tile.x * 16 + 8, tile.y * 16 + 8)
	_build_preview.visible = true
	
	# Update preview texture
	var size := Vector2(16 * structure.width, 16 * structure.height)
	var image := Image.create(int(size.x), int(size.y), false, Image.FORMAT_RGBA8)
	image.fill(structure.color)
	_build_preview.texture = ImageTexture.create_from_image(image)
	
	# Color based on validity
	if valid:
		_build_preview.modulate = Color(0.5, 1, 0.5, 0.6)  # Green tint
	else:
		_build_preview.modulate = Color(1, 0.5, 0.5, 0.6)  # Red tint


## Handle structure placed
func _on_structure_placed(structure_id: String, tile: Vector2i) -> void:
	print("Structure placed: ", structure_id, " at ", tile)
	_show_message("Built " + structure_id + "!")


## Handle placement failed
func _on_placement_failed(reason: String) -> void:
	_show_message(reason)


## Show a temporary message
func _show_message(message: String) -> void:
	if _message_label:
		_message_label.text = message
		_message_label.visible = true
		var bg := get_node_or_null("UILayer/MessageBG")
		if bg:
			bg.visible = true
		
		# Auto-hide
		await get_tree().create_timer(1.5).timeout
		_message_label.visible = false
		if bg:
			bg.visible = false


## Enter build mode from menu
func enter_build_mode(structure_id: String) -> void:
	if BuildManager.enter_build_mode(structure_id):
		if player:
			player.can_move = false


## Exit build mode
func exit_build_mode() -> void:
	BuildManager.exit_build_mode()
	_build_preview.visible = false
	if player:
		player.can_move = true


## Check if player can move to a tile
func can_move_to(tile: Vector2i, is_surfing: bool = false) -> bool:
	# Check for structures blocking movement
	if BuildManager.has_structure_at(tile):
		var structure := BuildManager.get_structure_data_at(tile)
		if structure and structure.blocks_movement:
			return false
	
	if tilemap_manager:
		if is_surfing:
			# When surfing, can move on water but not on land (except to exit)
			return tilemap_manager.is_tile_swimmable(tile) or not tilemap_manager.is_tile_solid(tile)
		else:
			return not tilemap_manager.is_tile_solid(tile)
	return true


# ============ Pokemon System ============

## Create Pokemon container
func _create_pokemon_container() -> void:
	_pokemon_container = Node2D.new()
	_pokemon_container.name = "Pokemon"
	add_child(_pokemon_container)
	# Place above structures
	move_child(_pokemon_container, 2)


## Open breeding menu for a breeding den
func _open_breeding_menu(den_tile: Vector2i) -> void:
	if _breeding_menu == null:
		_breeding_menu = BreedingMenu.new()
		_breeding_menu.name = "BreedingMenu"
		_breeding_menu.menu_closed.connect(_on_breeding_menu_closed)
		
		# Add to UI layer
		var ui_layer := get_node_or_null("UILayer")
		if ui_layer:
			ui_layer.add_child(_breeding_menu)
		else:
			add_child(_breeding_menu)
	
	# Register the den if not already
	BreedingManager.register_den(den_tile)
	
	if player:
		player.can_move = false
	
	_breeding_menu.open(den_tile)


func _on_breeding_menu_closed() -> void:
	"""Handle breeding menu closing"""
	if player:
		player.can_move = true
