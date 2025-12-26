class_name OverworldPokemon
extends CharacterBody2D
## OverworldPokemon - Pokemon that appears in the overworld
## Can be wild roaming Pokemon, ranch Pokemon, or follower Pokemon

# Behavior types
enum Behavior {
	IDLE,           # Stands still
	WANDER,         # Random movement
	FOLLOW_PLAYER,  # Follows the player
	PATROL,         # Moves between points
	FLEE,           # Runs from player
	APPROACH        # Approaches player
}

# Pokemon type in overworld
enum OverworldType {
	WILD,           # Wild roaming Pokemon (can be battled/caught)
	RANCH,          # Pokemon living at player's base
	FOLLOWER,       # Pokemon following the player
	BREEDING        # Pokemon in breeding den
}

# Signals
signal interacted(pokemon: OverworldPokemon)
signal touched_player(pokemon: OverworldPokemon)

# Constants
const TILE_SIZE := 16
const WANDER_SPEED := 32.0
const FOLLOW_SPEED := 64.0

# Pokemon data
var pokemon_data: Pokemon = null
var overworld_type: OverworldType = OverworldType.WILD
var behavior: Behavior = Behavior.WANDER

# Movement
var grid_position: Vector2i = Vector2i.ZERO
var target_position: Vector2 = Vector2.ZERO
var is_moving: bool = false
var facing_direction: Vector2i = Vector2i.DOWN
var movement_speed: float = WANDER_SPEED

# Behavior state
var wander_timer: float = 0.0
var wander_interval: float = 2.0  # Seconds between wander moves
var follow_target: Node2D = null
var home_position: Vector2i = Vector2i.ZERO  # For ranch Pokemon

# Visual
var sprite: Sprite2D = null
var shadow: Sprite2D = null

# Animation
var _anim_timer: float = 0.0
const ANIM_FRAME_TIME := 0.15  # Seconds per frame

# Interaction
var can_interact: bool = true
var interaction_cooldown: float = 0.0


func _ready() -> void:
	# Create visual components
	_create_visuals()
	
	# Create collision area for player detection
	_create_collision_area()
	
	# Initialize position
	grid_position = Vector2i(int(position.x / TILE_SIZE), int(position.y / TILE_SIZE))
	position = Vector2(grid_position.x * TILE_SIZE + TILE_SIZE / 2,
					   grid_position.y * TILE_SIZE + TILE_SIZE / 2)
	target_position = position
	home_position = grid_position
	
	# Add to groups
	add_to_group("overworld_pokemon")
	if overworld_type == OverworldType.WILD:
		add_to_group("wild_pokemon")
	elif overworld_type == OverworldType.RANCH:
		add_to_group("ranch_pokemon")


func _create_collision_area() -> void:
	"""Create Area2D for detecting player collision"""
	var area := Area2D.new()
	area.name = "DetectionArea"
	area.collision_layer = 0  # Don't collide with anything
	area.collision_mask = 1   # Detect layer 1 (player)
	
	var shape := CollisionShape2D.new()
	shape.name = "CollisionShape"
	var circle := CircleShape2D.new()
	circle.radius = 6.0  # Slightly smaller than tile
	shape.shape = circle
	area.add_child(shape)
	
	# Connect the body entered signal
	area.body_entered.connect(_on_body_entered)
	
	add_child(area)


func _create_visuals() -> void:
	# Shadow
	shadow = Sprite2D.new()
	shadow.name = "Shadow"
	shadow.position = Vector2(0, 4)
	shadow.modulate = Color(0, 0, 0, 0.3)
	var shadow_image := Image.create(12, 6, false, Image.FORMAT_RGBA8)
	shadow_image.fill(Color.WHITE)
	shadow.texture = ImageTexture.create_from_image(shadow_image)
	add_child(shadow)
	
	# Main sprite
	sprite = Sprite2D.new()
	sprite.name = "Sprite"
	add_child(sprite)
	
	# Update sprite from Pokemon data
	_update_sprite()


func _update_sprite() -> void:
	if sprite == null:
		return
	
	# Try to load Pokemon sprite, otherwise create placeholder
	if pokemon_data:
		var species := pokemon_data.get_species()
		if species and species.sprite_front != "" and ResourceLoader.exists(species.sprite_front):
			var texture := load(species.sprite_front) as Texture2D
			if texture:
				sprite.texture = texture
				# Calculate vframes from texture dimensions (vertical spritesheet)
				# Frames are square, so vframes = height / width
				var frame_size := texture.get_width()
				sprite.vframes = texture.get_height() / frame_size
				sprite.hframes = 1
				sprite.frame = 0  # Start at first frame
				sprite.scale = Vector2(0.5, 0.5)  # Scale down battle sprites for overworld
				return
	
	# Create placeholder colored square based on species
	var color := Color(0.8, 0.5, 0.5)  # Default pink
	if pokemon_data:
		var species := pokemon_data.get_species()
		if species:
			# Color based on primary type
			color = _get_type_color(species.type1)
	
	var image := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	image.fill(color)
	# Add simple face
	image.set_pixel(5, 5, Color.BLACK)
	image.set_pixel(10, 5, Color.BLACK)
	for x in range(6, 11):
		image.set_pixel(x, 10, Color.BLACK)
	sprite.texture = ImageTexture.create_from_image(image)


func _get_type_color(type_id: int) -> Color:
	# Return color based on Pokemon type
	match type_id:
		0: return Color(0.66, 0.66, 0.47)  # Normal
		1: return Color(0.76, 0.38, 0.27)  # Fire
		2: return Color(0.39, 0.56, 0.94)  # Water
		3: return Color(0.95, 0.77, 0.16)  # Electric
		4: return Color(0.47, 0.78, 0.30)  # Grass
		5: return Color(0.58, 0.85, 0.84)  # Ice
		6: return Color(0.76, 0.25, 0.16)  # Fighting
		7: return Color(0.63, 0.25, 0.63)  # Poison
		8: return Color(0.88, 0.75, 0.40)  # Ground
		9: return Color(0.66, 0.56, 0.95)  # Flying
		10: return Color(0.98, 0.33, 0.52)  # Psychic
		11: return Color(0.66, 0.72, 0.18)  # Bug
		12: return Color(0.72, 0.63, 0.21)  # Rock
		13: return Color(0.44, 0.34, 0.60)  # Ghost
		14: return Color(0.44, 0.22, 0.78)  # Dragon
		15: return Color(0.44, 0.34, 0.29)  # Dark
		16: return Color(0.72, 0.72, 0.82)  # Steel
		17: return Color(0.93, 0.60, 0.67)  # Fairy
		_: return Color(0.7, 0.7, 0.7)


func _physics_process(delta: float) -> void:
	# Update interaction cooldown
	if interaction_cooldown > 0:
		interaction_cooldown -= delta
	
	# Animate sprite
	_update_animation(delta)
	
	# Handle movement
	if is_moving:
		_process_movement(delta)
	else:
		_process_behavior(delta)


func _update_animation(delta: float) -> void:
	if sprite == null or sprite.vframes <= 1:
		return
	
	_anim_timer += delta
	if _anim_timer >= ANIM_FRAME_TIME:
		_anim_timer -= ANIM_FRAME_TIME
		sprite.frame = (sprite.frame + 1) % sprite.vframes


func _process_movement(delta: float) -> void:
	var move_vec := (target_position - position).normalized() * movement_speed * delta
	
	if position.distance_to(target_position) <= move_vec.length():
		position = target_position
		grid_position = Vector2i(int(position.x / TILE_SIZE), int(position.y / TILE_SIZE))
		is_moving = false
	else:
		position += move_vec


func _process_behavior(delta: float) -> void:
	match behavior:
		Behavior.IDLE:
			pass
		
		Behavior.WANDER:
			wander_timer += delta
			if wander_timer >= wander_interval:
				wander_timer = 0.0
				wander_interval = randf_range(1.5, 4.0)
				_try_wander()
		
		Behavior.FOLLOW_PLAYER:
			if follow_target:
				_try_follow(follow_target.global_position)
		
		Behavior.FLEE:
			if follow_target:
				_try_flee_from(follow_target.global_position)
		
		Behavior.APPROACH:
			if follow_target:
				_try_approach(follow_target.global_position)


func _try_wander() -> void:
	# Don't wander if wild and player is nearby
	if overworld_type == OverworldType.WILD:
		var player := _find_player()
		if player and position.distance_to(player.global_position) < 48:
			return
	
	# Ranch Pokemon stay near home
	if overworld_type == OverworldType.RANCH:
		if grid_position.distance_to(home_position) > 3:
			# Move towards home
			var dir := Vector2(home_position - grid_position).normalized()
			_try_move(Vector2i(signi(int(dir.x)), signi(int(dir.y))))
			return
	
	# Random direction
	var directions := [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]
	var dir: Vector2i = directions[randi() % 4]
	_try_move(dir)


func _try_follow(target_pos: Vector2) -> void:
	var target_tile := Vector2i(int(target_pos.x / TILE_SIZE), int(target_pos.y / TILE_SIZE))
	var diff := target_tile - grid_position
	
	# Stay 1 tile behind
	if diff.length() <= 1:
		return
	
	# Move towards target
	var dir := Vector2i.ZERO
	if abs(diff.x) > abs(diff.y):
		dir.x = signi(diff.x)
	else:
		dir.y = signi(diff.y)
	
	movement_speed = FOLLOW_SPEED
	_try_move(dir)


func _try_approach(target_pos: Vector2) -> void:
	var target_tile := Vector2i(int(target_pos.x / TILE_SIZE), int(target_pos.y / TILE_SIZE))
	var diff := target_tile - grid_position
	
	if diff.length() <= 1:
		# Close enough, trigger interaction
		touched_player.emit(self)
		behavior = Behavior.IDLE
		return
	
	var dir := Vector2i.ZERO
	if abs(diff.x) > abs(diff.y):
		dir.x = signi(diff.x)
	else:
		dir.y = signi(diff.y)
	
	_try_move(dir)


func _try_flee_from(target_pos: Vector2) -> void:
	var target_tile := Vector2i(int(target_pos.x / TILE_SIZE), int(target_pos.y / TILE_SIZE))
	var diff := grid_position - target_tile  # Opposite direction
	
	if diff.length() > 8:
		# Far enough, stop fleeing
		behavior = Behavior.WANDER
		return
	
	var dir := Vector2i.ZERO
	if abs(diff.x) > abs(diff.y):
		dir.x = signi(diff.x)
	else:
		dir.y = signi(diff.y)
	
	movement_speed = FOLLOW_SPEED
	_try_move(dir)


func _try_move(direction: Vector2i) -> void:
	if is_moving or direction == Vector2i.ZERO:
		return
	
	facing_direction = direction
	var target_tile := grid_position + direction
	
	# Check collision (simplified - would need tilemap reference)
	# For now, just move
	target_position = Vector2(target_tile.x * TILE_SIZE + TILE_SIZE / 2,
							  target_tile.y * TILE_SIZE + TILE_SIZE / 2)
	is_moving = true


func _find_player() -> Node2D:
	var players := get_tree().get_nodes_in_group("player")
	if players.size() > 0:
		return players[0]
	return null


func _on_body_entered(body: Node2D) -> void:
	"""Handle collision with another body (likely the player)"""
	if not body.is_in_group("player"):
		return
	
	# Only wild Pokemon trigger battles
	if overworld_type != OverworldType.WILD:
		return
	
	# Cooldown check
	if interaction_cooldown > 0:
		return
	interaction_cooldown = 1.0
	
	print("Wild ", pokemon_data.get_display_name() if pokemon_data else "Pokemon", " touched player!")
	
	# Emit signal for battle
	touched_player.emit(self)
	
	# Trigger battle through HabitatManager or directly
	if pokemon_data:
		_trigger_wild_battle()


func _trigger_wild_battle() -> void:
	"""Trigger a battle with this wild Pokemon"""
	# Freeze the player
	var player_node := _find_player()
	if player_node and player_node.has_method("set_movement_enabled"):
		player_node.set_movement_enabled(false)
	
	# Ensure player has a party
	if GameManager.player_party.is_empty():
		var starter := SpeciesDatabase.create_pokemon("PIKACHU", 10)
		if starter:
			GameManager.player_party.append(starter)
	
	# Change state and start battle
	GameManager.change_state(GameManager.GameState.BATTLE)
	BattleManager.start_wild_battle(GameManager.player_party, pokemon_data)
	
	# Remove this Pokemon from overworld (it's being battled)
	queue_free()


## Initialize with Pokemon data
func setup(pokemon: Pokemon, type: OverworldType = OverworldType.WILD) -> void:
	pokemon_data = pokemon
	overworld_type = type
	
	# Set behavior based on type
	match type:
		OverworldType.WILD:
			behavior = Behavior.WANDER
		OverworldType.RANCH:
			behavior = Behavior.WANDER
		OverworldType.FOLLOWER:
			behavior = Behavior.FOLLOW_PLAYER
			follow_target = _find_player()
		OverworldType.BREEDING:
			behavior = Behavior.IDLE
	
	_update_sprite()


## Called when player interacts
func interact() -> void:
	if not can_interact or interaction_cooldown > 0:
		return
	
	interaction_cooldown = 1.0
	interacted.emit(self)


## Set as player follower
func set_as_follower(player: Node2D) -> void:
	overworld_type = OverworldType.FOLLOWER
	behavior = Behavior.FOLLOW_PLAYER
	follow_target = player
	movement_speed = FOLLOW_SPEED


## Set home position (for ranch Pokemon)
func set_home(tile: Vector2i) -> void:
	home_position = tile


## Get display info
func get_info_string() -> String:
	if pokemon_data:
		return pokemon_data.get_display_name() + " Lv" + str(pokemon_data.level)
	return "???"


## Serialize for saving
func to_dict() -> Dictionary:
	return {
		"pokemon": pokemon_data.to_dict() if pokemon_data else {},
		"type": overworld_type,
		"position": {"x": grid_position.x, "y": grid_position.y},
		"home": {"x": home_position.x, "y": home_position.y}
	}


## Create from saved data
static func from_dict(data: Dictionary) -> OverworldPokemon:
	var owp := OverworldPokemon.new()
	
	var pkmn_data: Dictionary = data.get("pokemon", {})
	if not pkmn_data.is_empty():
		owp.pokemon_data = Pokemon.from_dict(pkmn_data)
		# Need to set species reference
		if owp.pokemon_data:
			var species := SpeciesDatabase.get_species(owp.pokemon_data.species_id)
			if species:
				owp.pokemon_data.set_species(species)
	
	owp.overworld_type = data.get("type", OverworldType.WILD)
	
	var pos: Dictionary = data.get("position", {})
	owp.grid_position = Vector2i(pos.get("x", 0), pos.get("y", 0))
	
	var home: Dictionary = data.get("home", {})
	owp.home_position = Vector2i(home.get("x", 0), home.get("y", 0))
	
	return owp
