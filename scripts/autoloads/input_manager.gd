extends Node
## InputManager - GBC-style input handling
## Maps keyboard/controller input to classic Pokemon controls

# Input Actions (matching GBC controls)
enum GBCButton {
	UP,
	DOWN,
	LEFT,
	RIGHT,
	A,      # Confirm/Interact
	B,      # Cancel/Run
	START,  # Menu
	SELECT  # Secondary menu
}

# Signals
signal button_pressed(button: GBCButton)
signal button_released(button: GBCButton)
signal direction_changed(direction: Vector2i)

# Input state tracking
var _button_states: Dictionary = {}
var _button_just_pressed: Dictionary = {}
var _button_just_released: Dictionary = {}
var current_direction: Vector2i = Vector2i.ZERO
var _previous_direction: Vector2i = Vector2i.ZERO
var _last_logged_direction: Vector2i = Vector2i.ZERO  # For logging changes

# Input blocking (for cutscenes, transitions)
var input_blocked: bool = false

# Repeat delay for held buttons (for menu navigation)
var _hold_timers: Dictionary = {}
const HOLD_DELAY := 0.4  # Initial delay before repeat
const HOLD_REPEAT := 0.1  # Repeat interval


func _ready() -> void:
	# Initialize button states
	for button in GBCButton.values():
		_button_states[button] = false
		_button_just_pressed[button] = false
		_button_just_released[button] = false
		_hold_timers[button] = 0.0
	
	# Set up input map if not already configured
	_setup_input_map()


func _setup_input_map() -> void:
	# Only add if not already defined
	var mappings := {
		"move_up": [KEY_UP, KEY_W],
		"move_down": [KEY_DOWN, KEY_S],
		"move_left": [KEY_LEFT, KEY_A],
		"move_right": [KEY_RIGHT, KEY_D],
		"button_a": [KEY_Z, KEY_SPACE],
		"button_b": [KEY_X, KEY_ESCAPE],
		"button_start": [KEY_ENTER],
		"button_select": [KEY_BACKSPACE]
	}
	
	for action_name in mappings:
		if not InputMap.has_action(action_name):
			InputMap.add_action(action_name)
			for key in mappings[action_name]:
				var event := InputEventKey.new()
				event.keycode = key
				InputMap.action_add_event(action_name, event)


func _process(delta: float) -> void:
	if input_blocked:
		_clear_all_states()
		return
	
	# Reset just pressed/released states
	for button in GBCButton.values():
		_button_just_pressed[button] = false
		_button_just_released[button] = false
	
	# Update button states
	_update_button(GBCButton.UP, "move_up", delta)
	_update_button(GBCButton.DOWN, "move_down", delta)
	_update_button(GBCButton.LEFT, "move_left", delta)
	_update_button(GBCButton.RIGHT, "move_right", delta)
	_update_button(GBCButton.A, "button_a", delta)
	_update_button(GBCButton.B, "button_b", delta)
	_update_button(GBCButton.START, "button_start", delta)
	_update_button(GBCButton.SELECT, "button_select", delta)
	
	# Calculate raw direction (before diagonal prevention)
	var raw_direction := Vector2i.ZERO
	if is_held(GBCButton.UP):
		raw_direction.y -= 1
	if is_held(GBCButton.DOWN):
		raw_direction.y += 1
	if is_held(GBCButton.LEFT):
		raw_direction.x -= 1
	if is_held(GBCButton.RIGHT):
		raw_direction.x += 1
	
	# Calculate direction (4-directional only, vertical priority like classic Pokemon)
	_previous_direction = current_direction
	current_direction = Vector2i.ZERO
	
	# Only allow one direction at a time - vertical takes priority over horizontal
	if is_held(GBCButton.UP):
		current_direction.y = -1
	elif is_held(GBCButton.DOWN):
		current_direction.y = 1
	elif is_held(GBCButton.LEFT):
		current_direction.x = -1
	elif is_held(GBCButton.RIGHT):
		current_direction.x = 1
	
	# Log direction input when it changes or diagonal is detected
	var diagonal_detected := (raw_direction.x != 0 and raw_direction.y != 0)
	if current_direction != _last_logged_direction or diagonal_detected:
		if current_direction != Vector2i.ZERO or diagonal_detected:
			GameLogger.log_input_direction(raw_direction, current_direction, run_held())
		_last_logged_direction = current_direction
	
	# Emit direction change signal
	if current_direction != _previous_direction:
		direction_changed.emit(current_direction)


func _update_button(button: GBCButton, action: String, delta: float) -> void:
	var was_pressed: bool = _button_states[button]
	var is_pressed: bool = Input.is_action_pressed(action)
	
	_button_states[button] = is_pressed
	
	if is_pressed and not was_pressed:
		_button_just_pressed[button] = true
		_hold_timers[button] = 0.0
		button_pressed.emit(button)
	elif not is_pressed and was_pressed:
		_button_just_released[button] = true
		button_released.emit(button)
	elif is_pressed:
		_hold_timers[button] += delta


func _clear_all_states() -> void:
	for button in GBCButton.values():
		_button_states[button] = false
		_button_just_pressed[button] = false
		_button_just_released[button] = false
	current_direction = Vector2i.ZERO


# Public API
func is_pressed(button: GBCButton) -> bool:
	"""Returns true on the frame the button was pressed"""
	return _button_just_pressed.get(button, false)


func is_released(button: GBCButton) -> bool:
	"""Returns true on the frame the button was released"""
	return _button_just_released.get(button, false)


func is_held(button: GBCButton) -> bool:
	"""Returns true while the button is held down"""
	return _button_states.get(button, false)


func is_held_with_repeat(button: GBCButton) -> bool:
	"""Returns true on press and after hold delay, then at repeat interval"""
	if is_pressed(button):
		return true
	
	if is_held(button):
		var timer: float = _hold_timers.get(button, 0.0)
		if timer >= HOLD_DELAY:
			# Check if we're at a repeat interval
			var repeat_time := timer - HOLD_DELAY
			var repeat_count := int(repeat_time / HOLD_REPEAT)
			var prev_repeat_count := int((repeat_time - get_process_delta_time()) / HOLD_REPEAT)
			return repeat_count > prev_repeat_count
	
	return false


func get_direction() -> Vector2i:
	"""Returns the current direction input as a Vector2i"""
	return current_direction


func get_direction_name() -> String:
	"""Returns the direction as a string (for animations)"""
	if current_direction.y < 0:
		return "up"
	elif current_direction.y > 0:
		return "down"
	elif current_direction.x < 0:
		return "left"
	elif current_direction.x > 0:
		return "right"
	return ""


func has_direction_input() -> bool:
	"""Returns true if any direction is pressed"""
	return current_direction != Vector2i.ZERO


func block_input() -> void:
	input_blocked = true
	_clear_all_states()


func unblock_input() -> void:
	input_blocked = false


# Shorthand functions for common checks
func confirm_pressed() -> bool:
	return is_pressed(GBCButton.A)


func cancel_pressed() -> bool:
	return is_pressed(GBCButton.B)


func menu_pressed() -> bool:
	return is_pressed(GBCButton.START)


func run_held() -> bool:
	return is_held(GBCButton.B)
