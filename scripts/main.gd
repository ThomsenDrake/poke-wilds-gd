extends Node2D
## Main scene - Entry point for the game
## Handles scene transitions and game flow

# Scene paths
const SCENE_TITLE := "res://scenes/menus/title_screen.tscn"
const SCENE_OVERWORLD := "res://scenes/overworld/overworld.tscn"
const SCENE_BATTLE := "res://scenes/battle/battle.tscn"

# Current loaded scene
var _current_scene: Node = null
var _battle_scene: Node = null
var _transition_in_progress: bool = false


func _ready() -> void:
	# Connect to GameManager signals
	GameManager.game_state_changed.connect(_on_game_state_changed)
	
	# Load the overworld scene
	_load_overworld()
	
	print("Main scene ready - PokeWilds GD initialized!")
	print("Controls: Arrow keys/WASD to move, hold B (X) to run, A (Z) to interact")
	print("Debug: F1 = info, F2 = data layer, F3 = player, F4 = tiles")


func _load_overworld() -> void:
	"""Load the overworld scene"""
	if ResourceLoader.exists(SCENE_OVERWORLD):
		_load_scene(SCENE_OVERWORLD)
	else:
		# Fallback to test scene if overworld doesn't exist yet
		push_warning("Overworld scene not found, using test scene")
		_create_test_scene()


func _create_test_scene() -> void:
	"""Creates a simple test scene for initial development"""
	# Create a colored background to show viewport is working
	var bg := ColorRect.new()
	bg.color = Color(0.2, 0.4, 0.2)  # Dark green
	bg.size = Vector2(GameManager.SCREEN_WIDTH, GameManager.SCREEN_HEIGHT)
	add_child(bg)
	
	# Create a simple test label
	var label := Label.new()
	label.text = "PokeWilds GD"
	label.position = Vector2(GameManager.SCREEN_WIDTH * 0.25, GameManager.SCREEN_HEIGHT * 0.15)
	label.add_theme_font_size_override("font_size", 8)
	add_child(label)
	
	# Create a test sprite that moves with input
	var test_sprite := _create_test_sprite()
	add_child(test_sprite)
	
	# Set game state
	GameManager.change_state(GameManager.GameState.OVERWORLD)


func _create_test_sprite() -> Node2D:
	"""Creates a simple test sprite that responds to input"""
	var sprite := Sprite2D.new()
	sprite.name = "TestPlayer"
	sprite.position = Vector2(GameManager.SCREEN_WIDTH / 2, GameManager.SCREEN_HEIGHT / 2)  # Center of viewport
	
	# Create a simple colored square as placeholder
	var image := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	image.fill(Color.WHITE)
	# Draw a simple face pattern
	for x in range(16):
		for y in range(16):
			if x == 0 or x == 15 or y == 0 or y == 15:
				image.set_pixel(x, y, Color.BLACK)  # Border
			elif (x == 4 or x == 11) and y == 5:
				image.set_pixel(x, y, Color.BLACK)  # Eyes
			elif y == 10 and x >= 4 and x <= 11:
				image.set_pixel(x, y, Color.BLACK)  # Mouth
	
	var texture := ImageTexture.create_from_image(image)
	sprite.texture = texture
	
	# Attach movement script
	var script := GDScript.new()
	script.source_code = """
extends Sprite2D

const MOVE_SPEED := 2.0
const TILE_SIZE := 16

var _target_position: Vector2
var _is_moving: bool = false

func _ready() -> void:
	_target_position = position

func _process(delta: float) -> void:
	if _is_moving:
		# Move towards target
		position = position.move_toward(_target_position, MOVE_SPEED)
		if position.distance_to(_target_position) < 0.1:
			position = _target_position
			_is_moving = false
	else:
		# Check for input
		var direction := InputManager.get_direction()
		if direction != Vector2i.ZERO:
			_target_position = position + Vector2(direction.x * TILE_SIZE, direction.y * TILE_SIZE)
			_is_moving = true
"""
	sprite.set_script(script)
	
	return sprite


func _on_game_state_changed(old_state: GameManager.GameState, new_state: GameManager.GameState) -> void:
	print("Main: State changed from ", GameManager.GameState.keys()[old_state], " to ", GameManager.GameState.keys()[new_state])
	
	# Handle scene transitions based on state
	match new_state:
		GameManager.GameState.TITLE_SCREEN:
			_load_scene(SCENE_TITLE)
		GameManager.GameState.OVERWORLD:
			# Return to overworld after battle
			if old_state == GameManager.GameState.BATTLE:
				_unload_battle_scene()
		GameManager.GameState.BATTLE:
			# Load battle scene overlay
			_load_battle_scene()


func _load_scene(scene_path: String) -> void:
	if _transition_in_progress:
		return
	
	if not ResourceLoader.exists(scene_path):
		push_error("Scene does not exist: " + scene_path)
		return
	
	_transition_in_progress = true
	
	# Remove current scene
	if _current_scene != null:
		_current_scene.queue_free()
		_current_scene = null
	
	# Load new scene
	var scene_resource := load(scene_path) as PackedScene
	if scene_resource == null:
		push_error("Failed to load scene: " + scene_path)
		_transition_in_progress = false
		return
	
	_current_scene = scene_resource.instantiate()
	add_child(_current_scene)
	
	_transition_in_progress = false


func _load_battle_scene() -> void:
	"""Load battle scene as overlay (keeps overworld in background)"""
	if _battle_scene != null:
		return  # Already loaded
	
	if not ResourceLoader.exists(SCENE_BATTLE):
		push_error("Battle scene does not exist: " + SCENE_BATTLE)
		return
	
	# Hide overworld (optional - could keep visible for effect)
	if _current_scene:
		_current_scene.visible = false
	
	# Load battle scene
	var battle_resource := load(SCENE_BATTLE) as PackedScene
	if battle_resource == null:
		push_error("Failed to load battle scene")
		return
	
	_battle_scene = battle_resource.instantiate()
	add_child(_battle_scene)
	
	print("Battle scene loaded")


func _unload_battle_scene() -> void:
	"""Unload battle scene and return to overworld"""
	if _battle_scene != null:
		_battle_scene.queue_free()
		_battle_scene = null
	
	# Show overworld again
	if _current_scene:
		_current_scene.visible = true
	
	print("Battle scene unloaded, returning to overworld")


func _process(_delta: float) -> void:
	# Debug: Press F1 to print debug info
	if Input.is_key_pressed(KEY_F1):
		_print_debug_info()


func _print_debug_info() -> void:
	print("=== Debug Info ===")
	print("Game State: ", GameManager.GameState.keys()[GameManager.current_state])
	print("Time: ", GameManager.get_time_string())
	print("Time of Day: ", GameManager.TimeOfDay.keys()[GameManager.time_of_day])
	print("Input Direction: ", InputManager.get_direction())
	print("==================")


func _input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed):
		return
	
	match event.keycode:
		KEY_F2:
			_test_data_layer()
		KEY_F3:
			_print_player_info()
		KEY_F4:
			_print_tile_info()


func _test_data_layer() -> void:
	"""Test the Phase 2 data layer implementation"""
	print("\n=== DATA LAYER TEST ===")
	
	# Test TypeChart
	print("\n-- TypeChart Tests --")
	var fire_vs_grass := TypeChart.get_effectiveness(TypeChart.Type.FIRE, TypeChart.Type.GRASS)
	print("Fire vs Grass: ", fire_vs_grass, "x (expected 2.0)")
	var water_vs_fire := TypeChart.get_effectiveness(TypeChart.Type.WATER, TypeChart.Type.FIRE)
	print("Water vs Fire: ", water_vs_fire, "x (expected 2.0)")
	var normal_vs_ghost := TypeChart.get_effectiveness(TypeChart.Type.NORMAL, TypeChart.Type.GHOST)
	print("Normal vs Ghost: ", normal_vs_ghost, "x (expected 0.0)")
	var electric_vs_water_flying := TypeChart.get_effectiveness_against(TypeChart.Type.ELECTRIC, [TypeChart.Type.WATER, TypeChart.Type.FLYING])
	print("Electric vs Water/Flying: ", electric_vs_water_flying, "x (expected 4.0)")
	
	# Test SpeciesDatabase
	print("\n-- SpeciesDatabase Tests --")
	print("Species count: ", SpeciesDatabase.get_species_count())
	var bulbasaur := SpeciesDatabase.get_species("BULBASAUR")
	if bulbasaur:
		print("Bulbasaur found - BST: ", bulbasaur.get_base_stat_total())
		print("  Types: ", TypeChart.type_to_string(bulbasaur.type1), "/", TypeChart.type_to_string(bulbasaur.type2) if bulbasaur.type2 >= 0 else "None")
		print("  Field moves: ", bulbasaur.get_field_moves())
	
	var pikachu := SpeciesDatabase.get_species("PIKACHU")
	if pikachu:
		print("Pikachu found - BST: ", pikachu.get_base_stat_total())
		print("  Default moves at Lv10: ", pikachu.get_default_moves(10))
	
	# Test MoveDatabase
	print("\n-- MoveDatabase Tests --")
	print("Move count: ", MoveDatabase.get_move_count())
	var tackle := MoveDatabase.get_move("TACKLE")
	if tackle:
		print("Tackle: Power=", tackle.power, ", Accuracy=", tackle.accuracy, ", Type=", TypeChart.type_to_string(tackle.type))
	var flamethrower := MoveDatabase.get_move("FLAMETHROWER")
	if flamethrower:
		print("Flamethrower: Power=", flamethrower.power, ", Effect=", MoveData.Effect.keys()[flamethrower.effect], ", Chance=", flamethrower.effect_chance, "%")
	print("HM moves: ", MoveDatabase.get_hm_moves().size())
	
	# Test Pokemon creation
	print("\n-- Pokemon Creation Test --")
	var wild_bulbasaur := SpeciesDatabase.create_pokemon("BULBASAUR", 10)
	if wild_bulbasaur:
		print("Created wild Bulbasaur Lv", wild_bulbasaur.level)
		print("  HP: ", wild_bulbasaur.current_hp, "/", wild_bulbasaur.max_hp)
		print("  Stats: Atk=", wild_bulbasaur.max_attack, " Def=", wild_bulbasaur.max_defense, " Spd=", wild_bulbasaur.max_speed)
		print("  IVs: HP=", wild_bulbasaur.iv_hp, " Atk=", wild_bulbasaur.iv_attack, " Def=", wild_bulbasaur.iv_defense)
		print("  Moves: ", wild_bulbasaur.move_ids)
		print("  Gender: ", wild_bulbasaur.gender, ", Shiny: ", wild_bulbasaur.is_shiny)
	
	# Test type effectiveness against Pokemon
	if wild_bulbasaur:
		var types := bulbasaur.get_types()
		var fire_effectiveness := TypeChart.get_effectiveness_against(TypeChart.Type.FIRE, types)
		var water_effectiveness := TypeChart.get_effectiveness_against(TypeChart.Type.WATER, types)
		print("  Fire vs this Bulbasaur: ", fire_effectiveness, "x")
		print("  Water vs this Bulbasaur: ", water_effectiveness, "x")
	
	print("\n=== DATA LAYER TEST COMPLETE ===")


func _print_player_info() -> void:
	"""Print player movement debug info"""
	print("\n=== PLAYER INFO ===")
	
	if _current_scene == null:
		print("No scene loaded")
		return
	
	var player := _current_scene.get_node_or_null("Player")
	if player == null:
		print("No player found in scene")
		return
	
	print("Grid Position: ", player.grid_position)
	print("World Position: ", player.position)
	print("Facing: ", Player.Direction.keys()[player.facing])
	print("Is Moving: ", player.is_moving)
	print("Is Running: ", player.is_running)
	print("Can Move: ", player.can_move)
	print("===================")


func _print_tile_info() -> void:
	"""Print tile information at player position"""
	print("\n=== TILE INFO ===")
	
	if _current_scene == null:
		print("No scene loaded")
		return
	
	var player := _current_scene.get_node_or_null("Player")
	if player == null:
		print("No player found")
		return
	
	var tilemap_mgr = _current_scene.get_node_or_null("TileMapManager")
	if tilemap_mgr == null:
		# Try to get it from the overworld
		tilemap_mgr = _current_scene.tilemap_manager if _current_scene.has_method("get") else null
	
	if tilemap_mgr == null:
		print("No TileMapManager found")
		return
	
	var pos: Vector2i = player.grid_position
	var facing_pos: Vector2i = player.get_facing_tile()
	
	print("Player Tile: ", pos, " = ", tilemap_mgr.get_tile_name(pos))
	print("  Solid: ", tilemap_mgr.is_tile_solid(pos))
	print("  Encounter: ", tilemap_mgr.is_encounter_tile(pos))
	print("  Swimmable: ", tilemap_mgr.is_tile_swimmable(pos))
	
	print("Facing Tile: ", facing_pos, " = ", tilemap_mgr.get_tile_name(facing_pos))
	print("  Solid: ", tilemap_mgr.is_tile_solid(facing_pos))
	
	# Show surrounding tiles
	print("Nearby Tiles:")
	for dy in range(-2, 3):
		var row := "  "
		for dx in range(-2, 3):
			var check_pos := pos + Vector2i(dx, dy)
			var tile_name: String = tilemap_mgr.get_tile_name(check_pos)
			var tile_char: String = tile_name[0].to_upper() if tile_name.length() > 0 else "?"
			if dx == 0 and dy == 0:
				row += "[" + tile_char + "]"
			else:
				row += " " + tile_char + " "
		print(row)
	
	print("=================")
