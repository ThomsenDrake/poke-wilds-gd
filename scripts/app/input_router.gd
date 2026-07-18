extends RefCounted

# App-layer input routing extracted from main.gd so the scene script stays
# under its line budget. Owns the InputMap action set — movement, confirm/
# cancel (action_a/action_b), run modifier, and the start/menu toggle — plus
# the per-frame poll that forwards "start" to Main's menu handler. Movement
# and confirm/cancel reach their consumers (player avatar, UI screens)
# directly through these actions; only the menu toggle is routed here.

const ACTION_BINDINGS := {
	"move_up": [Key.KEY_UP, Key.KEY_W],
	"move_down": [Key.KEY_DOWN, Key.KEY_S],
	"move_left": [Key.KEY_LEFT, Key.KEY_A],
	"move_right": [Key.KEY_RIGHT, Key.KEY_D],
	"action_a": [Key.KEY_Z],
	"action_b": [Key.KEY_X],
	"run": [Key.KEY_X],
	"start": [Key.KEY_ENTER],
}

var _on_menu_toggle: Callable


func _init(on_menu_toggle: Callable) -> void:
	_on_menu_toggle = on_menu_toggle


# Idempotent: existing actions and key events are left untouched.
func configure_input_map() -> void:
	for action_name in ACTION_BINDINGS:
		_ensure_action(action_name, ACTION_BINDINGS[action_name])


# Called from Main._process so the menu toggle keeps its original polling
# order relative to the rest of the scene tree.
func poll_menu_toggle() -> void:
	if Input.is_action_just_pressed("start"):
		_on_menu_toggle.call()


func _ensure_action(action_name: StringName, keys: Array) -> void:
	if not InputMap.has_action(action_name):
		InputMap.add_action(action_name)
	var existing_events = InputMap.action_get_events(action_name)
	for keycode in keys:
		if _has_key_event(existing_events, keycode):
			continue
		var key_event = InputEventKey.new()
		key_event.physical_keycode = keycode
		InputMap.action_add_event(action_name, key_event)


func _has_key_event(events: Array, keycode: Key) -> bool:
	for event in events:
		if event is InputEventKey and event.physical_keycode == keycode:
			return true
	return false
