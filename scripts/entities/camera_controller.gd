class_name CameraController
extends Camera2D
## Enhanced camera with smooth following, dead zones, look-ahead, and screen shake
## Industry-standard camera system for top-down RPG exploration
## Supports multiple follow modes, adaptive smoothing, and configurable screen shake

# ============================================================================
# ENUMS
# ============================================================================

## Camera follow behavior modes
enum FollowMode {
	CENTERED,     ## Classic centered camera (always follows player exactly)
	FRAMED,       ## Dead zone only - camera moves when player exits zone
	LOOK_AHEAD,   ## Dead zone + predictive offset in movement direction
	CINEMATIC,    ## Extra smooth with larger look-ahead for dramatic feel
	GRID_LOCKED   ## Pokemon-style snap to tile grid (pixel-perfect)
}

# ============================================================================
# EXPORT GROUPS - Organized settings for inspector
# ============================================================================

@export_group("Follow Mode")
## Camera behavior mode - determines how camera tracks the player
@export var follow_mode: FollowMode = FollowMode.LOOK_AHEAD
## Target to follow (auto-detects parent if null)
@export var follow_target: Node2D

@export_group("Dead Zone")
## Enable dead zone - camera stays still until player exits this zone
@export var dead_zone_enabled: bool = true
## Horizontal dead zone margin (0.0-0.5, percentage from screen edge)
@export_range(0.0, 0.5) var horizontal_margin: float = 0.2
## Vertical dead zone margin (0.0-0.5, percentage from screen edge)
@export_range(0.0, 0.5) var vertical_margin: float = 0.15

@export_group("Look-Ahead")
## Enable look-ahead - camera shows more in movement direction
@export var look_ahead_enabled: bool = true
## Distance to look ahead in pixels (48 = 3 tiles)
@export_range(0.0, 200.0) var look_ahead_distance: float = 48.0
## Look-ahead smoothing factor (lower = smoother transitions)
@export_range(0.01, 0.5) var look_ahead_smoothing: float = 0.15
## Minimum velocity to trigger look-ahead
@export var look_ahead_min_velocity: float = 30.0
## Use player facing direction even when idle
@export var look_ahead_on_facing: bool = true

@export_group("Smoothing")
## Smoothing speed when player is idle
@export_range(1.0, 20.0) var smoothing_idle: float = 3.0
## Smoothing speed when player is walking
@export_range(1.0, 20.0) var smoothing_walk: float = 6.0
## Smoothing speed when player is running
@export_range(1.0, 20.0) var smoothing_run: float = 12.0
## Smoothing speed when player is turning
@export_range(1.0, 20.0) var smoothing_turn: float = 4.0

@export_group("Grid Lock")
## Enable grid snapping (for GRID_LOCKED mode)
@export var grid_snap_enabled: bool = false
## Tile size for grid snapping
@export var grid_tile_size: int = 16

@export_group("Screen Shake")
## Enable screen shake effects
@export var shake_enabled: bool = true
## Maximum shake offset in pixels
@export var max_shake_offset: float = 8.0
## Maximum shake rotation in degrees
@export var max_shake_rotation: float = 5.0
## How fast trauma decays (per second)
@export var trauma_decay_rate: float = 2.0

@export_group("Boundaries")
## Enable camera boundaries (prevent showing empty space)
@export var boundaries_enabled: bool = false
## World boundary rectangle
@export var boundary_rect: Rect2 = Rect2()

@export_group("Zoom")
## Speed of zoom interpolation
@export var zoom_speed: float = 10.0

@export_group("Debug")
## Enable debug visualization overlay
@export var debug_draw_enabled: bool = false

# ============================================================================
# INTERNAL STATE
# ============================================================================

# Look-ahead state
var _look_ahead_offset: Vector2 = Vector2.ZERO
var _player_last_direction: Vector2 = Vector2.ZERO
var _current_smoothing: float = 6.0

# Screen shake state
var _trauma: float = 0.0
var _shake_noise: FastNoiseLite
var _noise_y: int = 0

# Zoom state (existing)
var _target_zoom: float = 1.0
var _is_battle_camera: bool = false

# Saved mode for battle transitions
var _saved_follow_mode: FollowMode = FollowMode.LOOK_AHEAD

# ============================================================================
# LIFECYCLE
# ============================================================================

func _ready() -> void:
	# Setup follow target (auto-detect parent if not set)
	_setup_follow_target()
	
	# Apply follow mode settings
	_apply_follow_mode()
	
	# Setup screen shake noise
	_setup_shake()
	
	# Connect to GameManager signals (existing behavior)
	GameManager.camera_zoom_changed.connect(_on_zoom_changed)
	
	# Apply initial zoom from GameManager
	_target_zoom = GameManager.get_camera_zoom()
	zoom = Vector2(_target_zoom, _target_zoom)


func _process(delta: float) -> void:
	# Update zoom (existing behavior)
	_update_zoom(delta)
	
	# Update screen shake
	_update_shake(delta)
	
	# Queue redraw for debug visualization
	if debug_draw_enabled:
		queue_redraw()


func _physics_process(delta: float) -> void:
	# Skip camera following in battle mode
	if _is_battle_camera:
		return
	
	# Skip if no target
	if follow_target == null:
		return
	
	# Update camera position based on follow mode
	_update_camera_follow(delta)


func _draw() -> void:
	if not debug_draw_enabled:
		return
	_draw_debug_overlay()

# ============================================================================
# CAMERA FOLLOWING
# ============================================================================

func _update_camera_follow(delta: float) -> void:
	var target_pos: Vector2 = follow_target.global_position
	
	# Apply grid snapping if in GRID_LOCKED mode
	if grid_snap_enabled and follow_mode == FollowMode.GRID_LOCKED:
		target_pos = _snap_to_grid(target_pos)
		global_position = target_pos
		return
	
	# Calculate look-ahead offset
	if look_ahead_enabled and _should_use_look_ahead():
		target_pos += _calculate_look_ahead_offset(delta)
	
	# Apply boundary constraints
	if boundaries_enabled and boundary_rect.has_area():
		target_pos = _apply_boundary_constraints(target_pos)
	
	# Get adaptive smoothing speed
	_current_smoothing = _get_adaptive_smoothing()
	
	# Apply camera movement
	# Dead zone is handled by Godot's built-in drag margins
	# For non-dead-zone modes, manually smooth position
	if not dead_zone_enabled or follow_mode == FollowMode.CENTERED:
		# Frame-rate independent smoothing formula
		var smooth_factor: float = 1.0 - pow(1.0 / _current_smoothing, delta)
		global_position = global_position.lerp(target_pos, smooth_factor)


func _calculate_look_ahead_offset(delta: float) -> Vector2:
	var target_offset: Vector2 = Vector2.ZERO
	
	# Get player velocity if available
	var velocity: Vector2 = Vector2.ZERO
	if follow_target is CharacterBody2D:
		velocity = follow_target.velocity
	
	# Calculate look-ahead based on velocity
	if velocity.length() > look_ahead_min_velocity:
		target_offset = velocity.normalized() * look_ahead_distance
	elif look_ahead_on_facing:
		# Use facing direction when idle/slow
		var facing_dir: Vector2 = _get_player_facing_direction()
		target_offset = facing_dir * (look_ahead_distance * 0.5)
	
	# Frame-rate independent smoothing for look-ahead transitions
	var smooth_factor: float = 1.0 - pow(look_ahead_smoothing, delta)
	_look_ahead_offset = _look_ahead_offset.lerp(target_offset, smooth_factor)
	
	return _look_ahead_offset


func _get_adaptive_smoothing() -> float:
	if follow_target == null:
		return smoothing_idle
	
	# Check player state
	if follow_target is CharacterBody2D:
		var player: CharacterBody2D = follow_target as CharacterBody2D
		var velocity: Vector2 = player.velocity
		var speed: float = velocity.length()
		
		# Detect turning (significant direction change)
		if speed > 10.0:
			var current_dir: Vector2 = velocity.normalized()
			if _player_last_direction.length() > 0.1:
				var dot: float = current_dir.dot(_player_last_direction)
				if dot < 0.7:  # More than ~45 degree turn
					_player_last_direction = current_dir
					return smoothing_turn
			_player_last_direction = current_dir
		
		# Check if player is running (Player class has is_running property)
		if follow_target.has_method("get") or "is_running" in follow_target:
			var is_running: bool = follow_target.get("is_running") if "is_running" in follow_target else false
			if is_running:
				return smoothing_run
		
		# Walking vs idle
		if speed > 10.0:
			return smoothing_walk
		else:
			return smoothing_idle
	
	return smoothing_walk


func _get_player_facing_direction() -> Vector2:
	# Try to get facing direction from Player class
	if follow_target == null:
		return Vector2.DOWN
	
	# Check if target has facing property (Player.Direction enum)
	if "facing" in follow_target:
		var facing: int = follow_target.facing
		# Player.Direction: DOWN=0, UP=1, LEFT=2, RIGHT=3
		match facing:
			0: return Vector2.DOWN
			1: return Vector2.UP
			2: return Vector2.LEFT
			3: return Vector2.RIGHT
	
	# Fallback to last known direction
	if _player_last_direction.length() > 0.1:
		return _player_last_direction
	
	return Vector2.DOWN


func _snap_to_grid(pos: Vector2) -> Vector2:
	return Vector2(
		floorf(pos.x / grid_tile_size) * grid_tile_size + grid_tile_size / 2.0,
		floorf(pos.y / grid_tile_size) * grid_tile_size + grid_tile_size / 2.0
	)


func _apply_boundary_constraints(pos: Vector2) -> Vector2:
	if not boundaries_enabled or not boundary_rect.has_area():
		return pos
	
	# Calculate half viewport size at current zoom
	var viewport_size: Vector2 = get_viewport_rect().size / zoom
	var half_view: Vector2 = viewport_size / 2.0
	
	# Clamp position to keep viewport within boundaries
	pos.x = clampf(pos.x, boundary_rect.position.x + half_view.x, 
	               boundary_rect.end.x - half_view.x)
	pos.y = clampf(pos.y, boundary_rect.position.y + half_view.y,
	               boundary_rect.end.y - half_view.y)
	
	return pos


func _should_use_look_ahead() -> bool:
	return follow_mode == FollowMode.LOOK_AHEAD or follow_mode == FollowMode.CINEMATIC

# ============================================================================
# SCREEN SHAKE
# ============================================================================

func _setup_shake() -> void:
	_shake_noise = FastNoiseLite.new()
	_shake_noise.seed = randi()
	_shake_noise.frequency = 4.0
	_shake_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX


func _update_shake(delta: float) -> void:
	if not shake_enabled or _trauma <= 0.0:
		offset = Vector2.ZERO
		rotation = 0.0
		return
	
	# Decay trauma over time
	_trauma = maxf(_trauma - trauma_decay_rate * delta, 0.0)
	
	# Calculate shake amount (use trauma^2 for better feel)
	var shake_amount: float = _trauma * _trauma
	
	# Sample noise for smooth, organic shake
	_noise_y += 1
	var noise_x: float = _shake_noise.get_noise_1d(float(_noise_y))
	var noise_y_val: float = _shake_noise.get_noise_1d(float(_noise_y + 100))
	var noise_rot: float = _shake_noise.get_noise_1d(float(_noise_y + 200))
	
	# Apply shake to offset and rotation
	offset = Vector2(
		max_shake_offset * shake_amount * noise_x,
		max_shake_offset * shake_amount * noise_y_val
	)
	rotation_degrees = max_shake_rotation * shake_amount * noise_rot

# ============================================================================
# ZOOM (Existing functionality preserved)
# ============================================================================

func _update_zoom(delta: float) -> void:
	if not is_equal_approx(zoom.x, _target_zoom):
		var new_zoom: float = lerpf(zoom.x, _target_zoom, zoom_speed * delta)
		# Snap to target if very close
		if absf(new_zoom - _target_zoom) < 0.01:
			new_zoom = _target_zoom
		zoom = Vector2(new_zoom, new_zoom)

# ============================================================================
# INPUT HANDLING (Existing functionality preserved)
# ============================================================================

func _unhandled_input(event: InputEvent) -> void:
	# Skip zoom controls if this is a battle camera (fixed zoom)
	if _is_battle_camera:
		return
	
	# Skip if game is not in overworld state
	if GameManager.current_state != GameManager.GameState.OVERWORLD:
		return
	
	# Zoom controls (Q = zoom out, E = zoom in, R = reset)
	if event.is_action_pressed("camera_zoom_in"):
		GameManager.adjust_camera_zoom(GameManager.CAMERA_ZOOM_STEP)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("camera_zoom_out"):
		GameManager.adjust_camera_zoom(-GameManager.CAMERA_ZOOM_STEP)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("camera_zoom_reset"):
		GameManager.reset_camera_zoom()
		get_viewport().set_input_as_handled()
	
	# Fullscreen toggle (F11)
	if event.is_action_pressed("toggle_fullscreen"):
		GameManager.toggle_fullscreen()
		get_viewport().set_input_as_handled()

# ============================================================================
# SETUP HELPERS
# ============================================================================

func _setup_follow_target() -> void:
	if follow_target != null:
		return
	
	# Auto-detect: use parent if it's a Node2D
	var parent: Node = get_parent()
	if parent is Node2D:
		follow_target = parent as Node2D


func _apply_follow_mode() -> void:
	# Configure camera based on selected follow mode
	match follow_mode:
		FollowMode.CENTERED:
			dead_zone_enabled = false
			look_ahead_enabled = false
			grid_snap_enabled = false
			position_smoothing_enabled = true
			position_smoothing_speed = smoothing_walk
		
		FollowMode.FRAMED:
			dead_zone_enabled = true
			look_ahead_enabled = false
			grid_snap_enabled = false
			position_smoothing_enabled = true
			position_smoothing_speed = smoothing_walk
		
		FollowMode.LOOK_AHEAD:
			dead_zone_enabled = true
			look_ahead_enabled = true
			grid_snap_enabled = false
			position_smoothing_enabled = true
			position_smoothing_speed = smoothing_walk
		
		FollowMode.CINEMATIC:
			dead_zone_enabled = true
			look_ahead_enabled = true
			look_ahead_distance = 80.0  # Larger look-ahead
			grid_snap_enabled = false
			position_smoothing_enabled = true
			position_smoothing_speed = 4.0  # Smoother
		
		FollowMode.GRID_LOCKED:
			dead_zone_enabled = false
			look_ahead_enabled = false
			grid_snap_enabled = true
			position_smoothing_enabled = false
	
	# Apply dead zone settings
	_setup_dead_zone()


func _setup_dead_zone() -> void:
	drag_horizontal_enabled = dead_zone_enabled
	drag_vertical_enabled = dead_zone_enabled
	
	if dead_zone_enabled:
		drag_left_margin = horizontal_margin
		drag_right_margin = horizontal_margin
		drag_top_margin = vertical_margin
		drag_bottom_margin = vertical_margin

# ============================================================================
# DEBUG VISUALIZATION
# ============================================================================

func _draw_debug_overlay() -> void:
	# Draw dead zone rectangle
	if dead_zone_enabled:
		var viewport_size: Vector2 = get_viewport_rect().size / zoom
		var dead_zone_width: float = viewport_size.x * (1.0 - horizontal_margin * 2)
		var dead_zone_height: float = viewport_size.y * (1.0 - vertical_margin * 2)
		var dead_zone_rect: Rect2 = Rect2(
			-dead_zone_width / 2.0,
			-dead_zone_height / 2.0,
			dead_zone_width,
			dead_zone_height
		)
		draw_rect(dead_zone_rect, Color.YELLOW, false, 2.0)
	
	# Draw look-ahead target
	if look_ahead_enabled and follow_target != null:
		var target_local: Vector2 = to_local(follow_target.global_position + _look_ahead_offset)
		draw_circle(target_local, 4.0, Color.CYAN)
		draw_line(Vector2.ZERO, target_local, Color.CYAN, 1.0)
	
	# Draw boundaries
	if boundaries_enabled and boundary_rect.has_area():
		var boundary_local: Rect2 = Rect2(
			to_local(boundary_rect.position),
			boundary_rect.size
		)
		draw_rect(boundary_local, Color.RED, false, 2.0)
	
	# Draw camera info text
	var info_text: String = "Mode: %s | Smoothing: %.1f" % [
		FollowMode.keys()[follow_mode],
		_current_smoothing
	]
	if _trauma > 0:
		info_text += " | Trauma: %.2f" % _trauma
	draw_string(ThemeDB.fallback_font, Vector2(-100, -80), info_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color.WHITE)

# ============================================================================
# PUBLIC API
# ============================================================================

## Add screen shake trauma (0.0 to 1.0)
## Higher values = stronger shake, decays over time
func add_trauma(amount: float) -> void:
	if shake_enabled:
		_trauma = minf(_trauma + amount, 1.0)


## Light screen shake (footsteps, small impacts)
func shake_light() -> void:
	add_trauma(0.3)


## Medium screen shake (hits, attacks)
func shake_medium() -> void:
	add_trauma(0.6)


## Heavy screen shake (explosions, boss attacks)
func shake_heavy() -> void:
	add_trauma(1.0)


## Change follow mode at runtime
func set_follow_mode(mode: FollowMode) -> void:
	follow_mode = mode
	_apply_follow_mode()


## Set world boundaries for camera limits
func set_boundaries(rect: Rect2) -> void:
	boundary_rect = rect
	boundaries_enabled = rect.has_area()


## Clear world boundaries
func clear_boundaries() -> void:
	boundaries_enabled = false
	boundary_rect = Rect2()


## Reset camera position instantly (useful after teleporting player)
func reset_camera_position() -> void:
	if follow_target != null:
		reset_smoothing()
		global_position = follow_target.global_position
		_look_ahead_offset = Vector2.ZERO
		_player_last_direction = Vector2.ZERO
		offset = Vector2.ZERO
		rotation = 0.0
		_trauma = 0.0


## Set zoom immediately without interpolation
func set_zoom_immediate(new_zoom: float) -> void:
	_target_zoom = new_zoom
	zoom = Vector2(new_zoom, new_zoom)


## Enable/disable battle mode (fixed zoom, centered camera)
func set_battle_mode(enabled: bool, fixed_zoom: float = 1.0) -> void:
	_is_battle_camera = enabled
	if enabled:
		# Save current mode and switch to centered for battle
		_saved_follow_mode = follow_mode
		set_follow_mode(FollowMode.CENTERED)
		set_zoom_immediate(fixed_zoom)
		# Disable shake during battle UI (can be re-enabled per attack)
		_trauma = 0.0
	else:
		# Restore previous follow mode
		set_follow_mode(_saved_follow_mode)


## Handle zoom change from GameManager (for overworld cameras)
func _on_zoom_changed(new_zoom: float) -> void:
	if not _is_battle_camera:
		_target_zoom = new_zoom

# ============================================================================
# VISIBILITY HELPERS (Existing functionality preserved)
# ============================================================================

## Get the visible rectangle in world coordinates
func get_visible_rect() -> Rect2:
	var viewport_size: Vector2 = get_viewport_rect().size
	var world_size: Vector2 = viewport_size / zoom
	var top_left: Vector2 = global_position - world_size / 2.0
	return Rect2(top_left, world_size)


## Get the visible tile bounds
func get_visible_tiles() -> Rect2i:
	var rect: Rect2 = get_visible_rect()
	var tile_size: int = GameManager.TILE_SIZE
	return Rect2i(
		int(rect.position.x) / tile_size,
		int(rect.position.y) / tile_size,
		int(rect.size.x) / tile_size + 2,  # +2 for partial tiles on edges
		int(rect.size.y) / tile_size + 2
	)


## Check if a world position is currently visible
func is_position_visible(world_pos: Vector2) -> bool:
	return get_visible_rect().has_point(world_pos)


## Check if a tile position is currently visible
func is_tile_visible(tile_pos: Vector2i) -> bool:
	var world_pos: Vector2 = Vector2(tile_pos) * GameManager.TILE_SIZE
	return get_visible_rect().grow(float(GameManager.TILE_SIZE)).has_point(world_pos)
