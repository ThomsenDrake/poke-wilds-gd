extends Node
## GameLogger - Comprehensive event logging system for debugging
## Logs all game events to sequential .log files
## Configure via Project Settings > PokeWilds > Logging
## Or environment variables: POKE_WILDS_LOGGING, POKE_WILDS_LOG_VERBOSITY

# Project Settings paths (visible in Editor UI under Project Settings > PokeWilds)
const SETTING_LOGGING_ENABLED := "poke_wilds/logging/enabled"
const SETTING_VERBOSITY := "poke_wilds/logging/verbosity"

# Environment variable fallbacks
const ENV_LOGGING := "POKE_WILDS_LOGGING"
const ENV_VERBOSITY := "POKE_WILDS_LOG_VERBOSITY"
const LOG_DIR := "user://logs/"
const MAX_LOG_FILES := 50

# Log file management
var _log_file: FileAccess = null
var _log_path: String = ""
var _session_start_time: float = 0.0
var _frame_count: int = 0
var _logging_enabled: bool = false

# Verbosity levels
enum Verbosity {
	MINIMAL,  # Only errors, blocked movements, battle events
	NORMAL,   # All gameplay events (input, movement, spawns)
	VERBOSE   # Everything including sprite updates, position every frame
}
var _verbosity: Verbosity = Verbosity.NORMAL

# Log categories for filtering
enum Category {
	SYSTEM,      # Engine/initialization events
	INPUT,       # Player input (key presses, mouse)
	MOVEMENT,    # Player/entity movement
	COLLISION,   # Collision detection events
	ANIMATION,   # Animation state changes
	SPAWN,       # Entity spawning/despawning
	INTERACTION, # Player interactions (A button, etc.)
	BATTLE,      # Battle system events
	ITEM,        # Item usage
	POKEMON,     # Pokemon-related events
	UI,          # UI events
	ERROR,       # Errors and warnings
	DEBUG        # General debug info
}

# Performance tracking
var _event_counts: Dictionary = {}
var _last_log_time: float = 0.0


func _ready() -> void:
	# Register project settings (visible in Project Settings > PokeWilds > Logging)
	_register_project_settings()
	
	# Check Project Settings first, then fall back to environment variables
	_logging_enabled = _get_logging_enabled()
	
	if not _logging_enabled:
		print("GameLogger: Logging disabled (enable in Project Settings > PokeWilds > Logging)")
		return
	
	# Get verbosity from Project Settings or environment
	_verbosity = _get_verbosity()
	
	# Initialize session
	_session_start_time = Time.get_ticks_msec() / 1000.0
	_create_log_file()
	
	if _log_file:
		# Clean up old logs first
		_cleanup_old_logs()
		
		# Write session header info
		log_event(Category.SYSTEM, "Session started")
		log_event(Category.SYSTEM, "Godot version: " + Engine.get_version_info().string)
		log_event(Category.SYSTEM, "OS: " + OS.get_name())
		log_event(Category.SYSTEM, "Verbosity: " + Verbosity.keys()[_verbosity])
		log_event(Category.SYSTEM, "Viewport: %dx%d" % [
			ProjectSettings.get_setting("display/window/size/viewport_width"),
			ProjectSettings.get_setting("display/window/size/viewport_height")
		])
		log_event(Category.SYSTEM, "Log file: " + _log_path)
		print("GameLogger: Initialized (%s) - Logging to %s" % [Verbosity.keys()[_verbosity], _log_path])


func _process(_delta: float) -> void:
	_frame_count += 1


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		_close_log()


func _create_log_file() -> void:
	"""Create a new sequential log file"""
	# Ensure logs directory exists (use DirAccess.open for user:// paths)
	var dir := DirAccess.open("user://")
	if dir and not dir.dir_exists("logs"):
		var err := dir.make_dir("logs")
		if err != OK:
			push_error("GameLogger: Failed to create logs directory: " + str(err))
			return
	
	# Find next available log number
	var log_number := _get_next_log_number(LOG_DIR)
	var timestamp := Time.get_datetime_string_from_system().replace(":", "-")
	_log_path = LOG_DIR + "session_%04d_%s.log" % [log_number, timestamp]
	
	_log_file = FileAccess.open(_log_path, FileAccess.WRITE)
	
	if _log_file == null:
		push_error("Failed to create log file: " + _log_path)
		_logging_enabled = false
		return
	
	# Write header
	_log_file.store_line("=".repeat(80))
	_log_file.store_line("PokeWilds GD - Session Log #%04d" % log_number)
	_log_file.store_line("Started: " + timestamp)
	_log_file.store_line("=".repeat(80))
	_log_file.store_line("")
	_log_file.flush()


func _get_next_log_number(logs_dir: String) -> int:
	"""Find the next available log number"""
	var highest := 0
	var dir := DirAccess.open(logs_dir)
	
	if dir:
		dir.list_dir_begin()
		var file_name := dir.get_next()
		
		while file_name != "":
			if file_name.begins_with("session_") and file_name.ends_with(".log"):
				# Extract number from "session_0001_timestamp.log"
				var parts := file_name.split("_")
				if parts.size() >= 2:
					var num_str := parts[1]
					var num := num_str.to_int()
					if num > highest:
						highest = num
			file_name = dir.get_next()
		
		dir.list_dir_end()
	
	return highest + 1


func _cleanup_old_logs() -> void:
	"""Remove old log files, keeping only the last MAX_LOG_FILES"""
	var dir := DirAccess.open(LOG_DIR)
	if not dir:
		return
	
	# Collect all log files
	var log_files: Array[String] = []
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if file_name.ends_with(".log"):
			log_files.append(file_name)
		file_name = dir.get_next()
	dir.list_dir_end()
	
	# If we have too many, delete the oldest ones
	if log_files.size() <= MAX_LOG_FILES:
		return
	
	# Sort alphabetically (session_0001 < session_0002, etc.)
	log_files.sort()
	
	# Delete oldest files
	var to_delete := log_files.size() - MAX_LOG_FILES
	for i in range(to_delete):
		var path := LOG_DIR + log_files[i]
		var err := DirAccess.remove_absolute(path)
		if err == OK:
			print("GameLogger: Cleaned up old log: ", log_files[i])
		else:
			push_warning("GameLogger: Failed to delete old log: ", log_files[i])


func _register_project_settings() -> void:
	"""Register custom project settings for logging configuration"""
	# Register logging enabled setting
	if not ProjectSettings.has_setting(SETTING_LOGGING_ENABLED):
		ProjectSettings.set_setting(SETTING_LOGGING_ENABLED, false)
	ProjectSettings.set_initial_value(SETTING_LOGGING_ENABLED, false)
	ProjectSettings.add_property_info({
		"name": SETTING_LOGGING_ENABLED,
		"type": TYPE_BOOL,
		"hint": PROPERTY_HINT_NONE,
		"hint_string": "Enable debug logging to user://logs/"
	})
	
	# Register verbosity setting (0=MINIMAL, 1=NORMAL, 2=VERBOSE)
	if not ProjectSettings.has_setting(SETTING_VERBOSITY):
		ProjectSettings.set_setting(SETTING_VERBOSITY, 1)  # Default to NORMAL
	ProjectSettings.set_initial_value(SETTING_VERBOSITY, 1)
	ProjectSettings.add_property_info({
		"name": SETTING_VERBOSITY,
		"type": TYPE_INT,
		"hint": PROPERTY_HINT_ENUM,
		"hint_string": "Minimal,Normal,Verbose"
	})


func _get_logging_enabled() -> bool:
	"""Get logging enabled state from Project Settings or environment variable"""
	# Project Settings takes priority
	if ProjectSettings.has_setting(SETTING_LOGGING_ENABLED):
		var setting: bool = ProjectSettings.get_setting(SETTING_LOGGING_ENABLED, false)
		if setting:
			return true
	
	# Fall back to environment variable
	var env_val := OS.get_environment(ENV_LOGGING)
	return env_val == "1" or env_val.to_lower() == "true"


func _get_verbosity() -> Verbosity:
	"""Get verbosity level from Project Settings or environment variable"""
	# Check environment variable first (allows runtime override)
	var env_verbosity := OS.get_environment(ENV_VERBOSITY)
	if env_verbosity != "":
		match env_verbosity.to_lower():
			"minimal", "0": return Verbosity.MINIMAL
			"verbose", "2": return Verbosity.VERBOSE
			_: return Verbosity.NORMAL
	
	# Fall back to Project Settings
	if ProjectSettings.has_setting(SETTING_VERBOSITY):
		var setting: int = ProjectSettings.get_setting(SETTING_VERBOSITY, 1)
		match setting:
			0: return Verbosity.MINIMAL
			2: return Verbosity.VERBOSE
			_: return Verbosity.NORMAL
	
	return Verbosity.NORMAL


func _close_log() -> void:
	"""Close the log file gracefully"""
	if _log_file:
		var session_duration := Time.get_ticks_msec() / 1000.0 - _session_start_time
		
		_log_file.store_line("")
		_log_file.store_line("=".repeat(80))
		_log_file.store_line("Session ended")
		_log_file.store_line("Duration: %.2f seconds" % session_duration)
		_log_file.store_line("Total frames: %d" % _frame_count)
		_log_file.store_line("Average FPS: %.1f" % (_frame_count / session_duration if session_duration > 0 else 0))
		_log_file.store_line("")
		_log_file.store_line("Event counts by category:")
		for category in _event_counts:
			_log_file.store_line("  %s: %d" % [Category.keys()[category], _event_counts[category]])
		_log_file.store_line("=".repeat(80))
		
		_log_file.close()
		_log_file = null
		print("GameLogger: Session log saved to ", _log_path)


## Log an event with category, message, and optional data
func log_event(category: Category, message: String, data: Dictionary = {}) -> void:
	if not _logging_enabled or _log_file == null:
		return
	
	var timestamp := Time.get_ticks_msec() / 1000.0 - _session_start_time
	var delta := timestamp - _last_log_time
	_last_log_time = timestamp
	
	# Track event counts
	_event_counts[category] = _event_counts.get(category, 0) + 1
	
	# Format: [12.345s +0.016s] [CATEGORY] Message
	var line := "[%7.3fs +%.3fs] [%-12s] %s" % [timestamp, delta, Category.keys()[category], message]
	
	# Append data if provided
	if not data.is_empty():
		var data_str := JSON.stringify(data)
		line += " | " + data_str
	
	_log_file.store_line(line)
	_log_file.flush()  # Ensure data is written immediately


## Log player input event
func log_input(action: String, pressed: bool, extra_data: Dictionary = {}) -> void:
	var state := "pressed" if pressed else "released"
	var data := extra_data.duplicate()
	data["action"] = action
	data["state"] = state
	log_event(Category.INPUT, "%s %s" % [action, state], data)


## Log movement event with position and direction
func log_movement(entity: String, position: Vector2, direction: Vector2 = Vector2.ZERO, extra_data: Dictionary = {}) -> void:
	var data := extra_data.duplicate()
	data["entity"] = entity
	data["pos_x"] = snappedf(position.x, 0.01)
	data["pos_y"] = snappedf(position.y, 0.01)
	if direction != Vector2.ZERO:
		data["dir_x"] = direction.x
		data["dir_y"] = direction.y
		data["dir_length"] = snappedf(direction.length(), 0.01)
	
	var msg := "%s moved to (%.2f, %.2f)" % [entity, position.x, position.y]
	if direction != Vector2.ZERO:
		msg += " dir=(%.2f, %.2f)" % [direction.x, direction.y]
	
	log_event(Category.MOVEMENT, msg, data)


## Log collision event
func log_collision(entity: String, collider: String, position: Vector2, extra_data: Dictionary = {}) -> void:
	var data := extra_data.duplicate()
	data["entity"] = entity
	data["collider"] = collider
	data["pos_x"] = snappedf(position.x, 0.01)
	data["pos_y"] = snappedf(position.y, 0.01)
	
	log_event(Category.COLLISION, "%s collided with %s at (%.2f, %.2f)" % [entity, collider, position.x, position.y], data)


## Log animation state change
func log_animation(entity: String, anim_name: String, extra_data: Dictionary = {}) -> void:
	var data := extra_data.duplicate()
	data["entity"] = entity
	data["animation"] = anim_name
	
	log_event(Category.ANIMATION, "%s: %s" % [entity, anim_name], data)


## Log entity spawn/despawn
func log_spawn(entity: String, spawned: bool, position: Vector2 = Vector2.ZERO, extra_data: Dictionary = {}) -> void:
	var data := extra_data.duplicate()
	data["entity"] = entity
	data["spawned"] = spawned
	if position != Vector2.ZERO:
		data["pos_x"] = snappedf(position.x, 0.01)
		data["pos_y"] = snappedf(position.y, 0.01)
	
	var action := "spawned" if spawned else "despawned"
	var msg := "%s %s" % [entity, action]
	if position != Vector2.ZERO:
		msg += " at (%.2f, %.2f)" % [position.x, position.y]
	
	log_event(Category.SPAWN, msg, data)


## Log interaction event
func log_interaction(entity: String, target: String, extra_data: Dictionary = {}) -> void:
	var data := extra_data.duplicate()
	data["entity"] = entity
	data["target"] = target
	
	log_event(Category.INTERACTION, "%s interacted with %s" % [entity, target], data)


## Log battle event
func log_battle(event_type: String, extra_data: Dictionary = {}) -> void:
	log_event(Category.BATTLE, event_type, extra_data)


## Log item usage
func log_item(item_name: String, action: String, extra_data: Dictionary = {}) -> void:
	var data := extra_data.duplicate()
	data["item"] = item_name
	data["action"] = action
	
	log_event(Category.ITEM, "%s: %s" % [item_name, action], data)


## Log Pokemon-related event
func log_pokemon(event_type: String, pokemon_name: String, extra_data: Dictionary = {}) -> void:
	var data := extra_data.duplicate()
	data["pokemon"] = pokemon_name
	
	log_event(Category.POKEMON, "%s: %s" % [event_type, pokemon_name], data)


## Log UI event
func log_ui(event_type: String, extra_data: Dictionary = {}) -> void:
	log_event(Category.UI, event_type, extra_data)


## Log error or warning
func log_error(message: String, extra_data: Dictionary = {}) -> void:
	log_event(Category.ERROR, message, extra_data)


## Log generic debug info
func log_debug(message: String, extra_data: Dictionary = {}) -> void:
	log_event(Category.DEBUG, message, extra_data)


## Get current session log path
func get_log_path() -> String:
	return _log_path


## Check if logging is enabled
func is_logging() -> bool:
	return _logging_enabled


## Get current verbosity level
func get_verbosity() -> Verbosity:
	return _verbosity


# ============ Specialized Logging Methods for Bug Tracking ============

## Log grid-based movement attempt and result
func log_movement_grid(entity: String, from_tile: Vector2i, to_tile: Vector2i, direction: String, succeeded: bool) -> void:
	# In minimal mode, only log failures
	if _verbosity == Verbosity.MINIMAL and succeeded:
		return
	
	var data := {
		"from_x": from_tile.x, "from_y": from_tile.y,
		"to_x": to_tile.x, "to_y": to_tile.y,
		"direction": direction,
		"succeeded": succeeded
	}
	var result := "OK" if succeeded else "BLOCKED"
	var msg := "%s: (%d,%d)->(%d,%d) %s %s" % [
		entity, from_tile.x, from_tile.y, to_tile.x, to_tile.y, direction, result
	]
	log_event(Category.MOVEMENT, msg, data)


## Log directional input with raw and final values (for diagonal detection)
func log_input_direction(raw_dir: Vector2i, final_dir: Vector2i, run_held: bool) -> void:
	if _verbosity == Verbosity.MINIMAL:
		return
	
	var diagonal_detected := (raw_dir.x != 0 and raw_dir.y != 0)
	var data := {
		"raw_x": raw_dir.x, "raw_y": raw_dir.y,
		"final_x": final_dir.x, "final_y": final_dir.y,
		"run": run_held,
		"diagonal": diagonal_detected
	}
	var msg := "raw=(%d,%d) final=(%d,%d) run=%s" % [
		raw_dir.x, raw_dir.y, final_dir.x, final_dir.y, run_held
	]
	if diagonal_detected:
		msg += " [DIAGONAL DETECTED]"
	log_event(Category.INPUT, msg, data)


## Log tile collision check details
func log_tile_collision(entity: String, tile: Vector2i, tile_type: String, is_solid: bool, blocked: bool) -> void:
	var data := {
		"tile_x": tile.x, "tile_y": tile.y,
		"type": tile_type,
		"solid": is_solid,
		"blocked": blocked
	}
	var result := "BLOCKED" if blocked else "OK"
	var msg := "%s: tile=(%d,%d) type=%s solid=%s -> %s" % [
		entity, tile.x, tile.y, tile_type, is_solid, result
	]
	log_event(Category.COLLISION, msg, data)


## Log sprite/animation state change (verbose only)
func log_sprite_state(entity: String, animation: String, frame: int, direction: String) -> void:
	if _verbosity != Verbosity.VERBOSE:
		return
	
	var data := {
		"animation": animation,
		"frame": frame,
		"facing": direction
	}
	var msg := "%s: anim=%s frame=%d facing=%s" % [entity, animation, frame, direction]
	log_event(Category.ANIMATION, msg, data)


## Log position update (verbose only, for frame-by-frame tracking)
func log_position_update(entity: String, grid_pos: Vector2i, world_pos: Vector2) -> void:
	if _verbosity != Verbosity.VERBOSE:
		return
	
	var data := {
		"grid_x": grid_pos.x, "grid_y": grid_pos.y,
		"world_x": snappedf(world_pos.x, 0.01),
		"world_y": snappedf(world_pos.y, 0.01)
	}
	var msg := "%s: grid=(%d,%d) world=(%.1f,%.1f)" % [
		entity, grid_pos.x, grid_pos.y, world_pos.x, world_pos.y
	]
	log_event(Category.MOVEMENT, msg, data)
