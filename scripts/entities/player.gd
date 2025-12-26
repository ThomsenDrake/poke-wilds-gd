class_name Player
extends CharacterBody2D
## Player - Main player character with grid-based movement
## Handles movement, animation, and interaction with the overworld

# Movement constants
const TILE_SIZE := 16
const WALK_SPEED := 64.0          # Pixels per second (4 tiles/sec)
const RUN_SPEED := 128.0          # Pixels per second (8 tiles/sec)
const STEP_DURATION := 0.25       # Seconds per tile when walking
const RUN_STEP_DURATION := 0.125  # Seconds per tile when running

# Animation constants
const ANIM_IDLE_DOWN := "idle_down"
const ANIM_IDLE_UP := "idle_up"
const ANIM_IDLE_LEFT := "idle_left"
const ANIM_IDLE_RIGHT := "idle_right"
const ANIM_WALK_DOWN := "walk_down"
const ANIM_WALK_UP := "walk_up"
const ANIM_WALK_LEFT := "walk_left"
const ANIM_WALK_RIGHT := "walk_right"

# Direction enum
enum Direction { DOWN, UP, LEFT, RIGHT }

# Signals
signal step_started(direction: Direction)
signal step_completed(direction: Direction)
signal interaction_requested(facing_tile: Vector2i)

# Node references
@onready var sprite: AnimatedSprite2D = $Sprite
@onready var collision_shape: CollisionShape2D = $CollisionShape
@onready var interaction_raycast: RayCast2D = $InteractionRay

# Animation state for UP/DOWN walk (uses flip_h toggle)
var _walk_frame: int = 0
var _walk_timer: float = 0.0
const WALK_FRAME_TIME := 0.125  # Time per walk frame

# State
var facing: Direction = Direction.DOWN
var is_moving: bool = false
var is_running: bool = false
var is_surfing: bool = false
var can_move: bool = true
var grid_position: Vector2i = Vector2i.ZERO  # Current tile position

# Movement
var _move_direction: Vector2i = Vector2i.ZERO
var _target_position: Vector2 = Vector2.ZERO
var _step_timer: float = 0.0
var _step_frame: int = 0  # 0 or 1 for walk cycle

# Input buffering for responsive controls
var _buffered_direction: Vector2i = Vector2i.ZERO
var _input_buffer_time: float = 0.0
const INPUT_BUFFER_DURATION := 0.1


func _ready() -> void:
	# Initialize position on grid (use floori for proper negative coordinate handling)
	grid_position = Vector2i(floori(position.x / TILE_SIZE), floori(position.y / TILE_SIZE))
	position = Vector2(grid_position.x * TILE_SIZE + TILE_SIZE / 2, 
					   grid_position.y * TILE_SIZE + TILE_SIZE / 2)
	_target_position = position
	
	# Setup raycast for interactions
	if interaction_raycast:
		interaction_raycast.enabled = true
		_update_raycast_direction()
	
	# Play initial idle animation
	_play_idle_animation()


func _physics_process(delta: float) -> void:
	if not can_move:
		return
	
	# Handle input buffering
	if _input_buffer_time > 0:
		_input_buffer_time -= delta
	
	# Check for running (hold B button)
	is_running = InputManager.run_held()
	
	if is_moving:
		_process_movement(delta)
		_update_walk_animation(delta)
	else:
		_check_movement_input()


func _update_walk_animation(delta: float) -> void:
	# Only need manual frame control for UP/DOWN (flip_h toggle)
	# LEFT/RIGHT use built-in 2-frame animation
	if facing != Direction.UP and facing != Direction.DOWN:
		return
	
	var frame_time := WALK_FRAME_TIME / 2.0 if is_running else WALK_FRAME_TIME
	_walk_timer += delta
	if _walk_timer >= frame_time:
		_walk_timer = 0.0
		_walk_frame = 1 - _walk_frame  # Toggle between 0 and 1
		sprite.flip_h = (_walk_frame == 1)


func _process_movement(delta: float) -> void:
	var speed := RUN_SPEED if is_running else WALK_SPEED
	var step_time := RUN_STEP_DURATION if is_running else STEP_DURATION
	
	# Move towards target
	var move_vec := (_target_position - position).normalized() * speed * delta
	
	# Check if we've reached or passed the target
	if position.distance_to(_target_position) <= move_vec.length():
		# Snap to target
		position = _target_position
		# Use floori() for proper negative coordinate handling (int() truncates toward zero)
		grid_position = Vector2i(floori(position.x / TILE_SIZE), floori(position.y / TILE_SIZE))
		is_moving = false
		
		# Log position update (verbose only)
		GameLogger.log_position_update("Player", grid_position, position)
		
		step_completed.emit(facing)
		
		# Check for buffered input for continuous movement
		if _buffered_direction != Vector2i.ZERO and _input_buffer_time > 0:
			_try_move(_buffered_direction)
			_buffered_direction = Vector2i.ZERO
		else:
			_play_idle_animation()
	else:
		position += move_vec
		
		# Update walk animation frame
		_step_timer += delta
		if _step_timer >= step_time / 2:
			_step_timer = 0.0
			_step_frame = 1 - _step_frame  # Toggle between 0 and 1


func _check_movement_input() -> void:
	var input_dir := InputManager.get_direction()
	
	if input_dir != Vector2i.ZERO:
		# Buffer the input
		_buffered_direction = input_dir
		_input_buffer_time = INPUT_BUFFER_DURATION
		
		_try_move(input_dir)
	else:
		# No input - check for turning in place
		var raw_dir := _get_raw_direction_input()
		if raw_dir != Vector2i.ZERO:
			_face_direction(_direction_from_vector(raw_dir))


func _try_move(direction: Vector2i) -> void:
	# Update facing direction (don't play idle - we're about to move or hit a wall)
	var new_facing := _direction_from_vector(direction)
	if new_facing != facing:
		_face_direction(new_facing, false)  # Don't play idle animation yet
	
	# Check if we can move to the target tile
	var target_tile := grid_position + direction
	var dir_name := _direction_to_string(facing)
	
	if _can_move_to(target_tile):
		# Log successful movement
		GameLogger.log_movement_grid("Player", grid_position, target_tile, dir_name, true)
		_start_move(direction)
	else:
		# Log blocked movement - NOW play idle since we're not moving
		_play_idle_animation()
		GameLogger.log_movement_grid("Player", grid_position, target_tile, dir_name, false)
		GameLogger.log_debug("Movement blocked: Player at (%d,%d) -> (%d,%d) %s" % [
			grid_position.x, grid_position.y, target_tile.x, target_tile.y, dir_name
		])


func _start_move(direction: Vector2i) -> void:
	_move_direction = direction
	_target_position = Vector2(
		(grid_position.x + direction.x) * TILE_SIZE + TILE_SIZE / 2,
		(grid_position.y + direction.y) * TILE_SIZE + TILE_SIZE / 2
	)
	is_moving = true
	_step_timer = 0.0
	
	_play_walk_animation()
	step_started.emit(facing)


func _can_move_to(tile: Vector2i) -> bool:
	# Use raycast to check for entity collisions (NPCs, etc.)
	if interaction_raycast:
		_update_raycast_direction()
		interaction_raycast.force_raycast_update()
		if interaction_raycast.is_colliding():
			var collider := interaction_raycast.get_collider()
			# Check if it's a blocking collision
			if collider and collider.is_in_group("solid"):
				var collider_name: String = str(collider.name) if collider else "unknown"
				GameLogger.log_tile_collision("Player", tile, "entity:" + collider_name, true, true)
				return false
	
	# Check tilemap collision via parent overworld
	var parent := get_parent()
	if parent and parent.has_method("can_move_to"):
		var can_move: bool = parent.can_move_to(tile, is_surfing)
		
		# Log collision details if blocked
		if not can_move:
			var tile_type := "unknown"
			var is_solid := true
			if parent.tilemap_manager:
				tile_type = parent.tilemap_manager.get_tile_name(tile)
				is_solid = parent.tilemap_manager.is_tile_solid(tile)
			GameLogger.log_tile_collision("Player", tile, tile_type, is_solid, true)
		
		return can_move
	
	return true


func _face_direction(new_direction: Direction, play_idle: bool = true) -> void:
	facing = new_direction
	_update_raycast_direction()
	if play_idle:
		_play_idle_animation()


func _update_raycast_direction() -> void:
	if not interaction_raycast:
		return
	
	match facing:
		Direction.DOWN:
			interaction_raycast.target_position = Vector2(0, TILE_SIZE)
		Direction.UP:
			interaction_raycast.target_position = Vector2(0, -TILE_SIZE)
		Direction.LEFT:
			interaction_raycast.target_position = Vector2(-TILE_SIZE, 0)
		Direction.RIGHT:
			interaction_raycast.target_position = Vector2(TILE_SIZE, 0)


func _direction_from_vector(vec: Vector2i) -> Direction:
	if vec.y > 0:
		return Direction.DOWN
	elif vec.y < 0:
		return Direction.UP
	elif vec.x < 0:
		return Direction.LEFT
	elif vec.x > 0:
		return Direction.RIGHT
	return facing  # No change


func _direction_to_string(dir: Direction) -> String:
	match dir:
		Direction.UP: return "UP"
		Direction.DOWN: return "DOWN"
		Direction.LEFT: return "LEFT"
		Direction.RIGHT: return "RIGHT"
	return "UNKNOWN"


func _get_raw_direction_input() -> Vector2i:
	var dir := Vector2i.ZERO
	# Match InputManager priority: UP before DOWN, LEFT before RIGHT
	if Input.is_action_pressed("move_up"):
		dir.y = -1
	elif Input.is_action_pressed("move_down"):
		dir.y = 1
	elif Input.is_action_pressed("move_left"):
		dir.x = -1
	elif Input.is_action_pressed("move_right"):
		dir.x = 1
	return dir


func _play_idle_animation() -> void:
	if not sprite:
		return
	
	var anim_name := ""
	match facing:
		Direction.DOWN:
			anim_name = "idle_down"
		Direction.UP:
			anim_name = "idle_up"
		Direction.LEFT:
			anim_name = "idle_left"
		Direction.RIGHT:
			anim_name = "idle_right"
	
	sprite.flip_h = false  # Reset flip when idle
	if sprite.animation != anim_name:
		sprite.play(anim_name)


func _play_walk_animation() -> void:
	if not sprite:
		return
	
	var anim_name := ""
	match facing:
		Direction.DOWN:
			anim_name = "walk_down"
		Direction.UP:
			anim_name = "walk_up"
		Direction.LEFT:
			anim_name = "walk_left"
		Direction.RIGHT:
			anim_name = "walk_right"
	
	# Reset flip_h state for UP/DOWN walk animation
	if facing == Direction.UP or facing == Direction.DOWN:
		_walk_frame = 0
		_walk_timer = 0.0
		sprite.flip_h = false
	
	# Set animation speed based on running
	sprite.speed_scale = 2.0 if is_running else 1.0
	
	if sprite.animation != anim_name:
		sprite.play(anim_name)


## Called when A button is pressed - check for interaction
func _input(event: InputEvent) -> void:
	if event.is_action_pressed("button_a") and not is_moving:
		_try_interact()


func _try_interact() -> void:
	if interaction_raycast:
		interaction_raycast.force_raycast_update()
		if interaction_raycast.is_colliding():
			var collider := interaction_raycast.get_collider()
			if collider and collider.has_method("interact"):
				collider.interact(self)
				return
	
	# Emit signal for other systems to handle
	var facing_tile := grid_position + _get_facing_offset()
	interaction_requested.emit(facing_tile)


func _get_facing_offset() -> Vector2i:
	match facing:
		Direction.DOWN:
			return Vector2i(0, 1)
		Direction.UP:
			return Vector2i(0, -1)
		Direction.LEFT:
			return Vector2i(-1, 0)
		Direction.RIGHT:
			return Vector2i(1, 0)
	return Vector2i.ZERO


## Teleport player to a grid position
func teleport_to(tile: Vector2i) -> void:
	grid_position = tile
	position = Vector2(tile.x * TILE_SIZE + TILE_SIZE / 2, 
					   tile.y * TILE_SIZE + TILE_SIZE / 2)
	_target_position = position
	is_moving = false


## Get the tile the player is facing
func get_facing_tile() -> Vector2i:
	return grid_position + _get_facing_offset()


## Freeze/unfreeze player movement (for cutscenes, menus, etc.)
func set_movement_enabled(enabled: bool) -> void:
	can_move = enabled
	if not enabled and is_moving:
		# Finish current movement
		pass


## Get direction as a normalized vector
func get_facing_vector() -> Vector2:
	match facing:
		Direction.DOWN:
			return Vector2.DOWN
		Direction.UP:
			return Vector2.UP
		Direction.LEFT:
			return Vector2.LEFT
		Direction.RIGHT:
			return Vector2.RIGHT
	return Vector2.DOWN


## Set surfing state - changes sprite and movement behavior
func set_surfing(surfing: bool) -> void:
	is_surfing = surfing
	
	# Visual feedback - tint the sprite blue when surfing
	if sprite:
		if surfing:
			sprite.modulate = Color(0.7, 0.8, 1.0)  # Blue tint
		else:
			sprite.modulate = Color.WHITE
	
	# Could swap to a surfing sprite here if we had one
	# sprite.animation = "surf_down" etc.
