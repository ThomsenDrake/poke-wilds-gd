extends RefCounted

# App-layer input routing extracted from main.gd so the scene script stays
# under its line budget. Owns the InputMap action set — movement, confirm/
# cancel (action_a/action_b), run modifier, and the start/menu toggle — plus
# the per-frame polls that forward "start" to Main's menu handler and
# "action_a" to Main's context action. Movement and confirm/cancel reach
# their other consumers (player avatar, UI screens) directly through these
# actions; only the menu toggle and context action are routed here.

const ACTION_BINDINGS := {
	"move_up": [Key.KEY_UP, Key.KEY_W],
	"move_down": [Key.KEY_DOWN, Key.KEY_S],
	"move_left": [Key.KEY_LEFT, Key.KEY_A],
	"move_right": [Key.KEY_RIGHT, Key.KEY_D],
	"action_a": [Key.KEY_Z],
	# X is deliberately shared between two actions in mutually exclusive input
	# contexts: `action_b` (cancel) is consumed ONLY by UI screens (start menu,
	# party/bag, battle) through _unhandled_input + set_input_as_handled, and
	# only while a screen is visible; `run` is polled ONLY during overworld
	# movement (player_avatar reads is_action_pressed while input_enabled). In
	# the overworld no UI consumes action_b (hidden screens return early); in
	# menus/battles the avatar is not moving (input_enabled = false). UI screens
	# read action_b via is_action_just_pressed, so holding X to run cannot
	# spuriously cancel a freshly opened menu. The shared physical key never
	# collides, so no rebind is needed.
	"action_b": [Key.KEY_X],
	"run": [Key.KEY_X],
	"start": [Key.KEY_ENTER],
}

var _on_menu_toggle: Callable
var _on_context_action: Callable


# The context action callable is optional so single-argument construction
# (menu toggle only) keeps working.
func _init(on_menu_toggle: Callable, on_context_action: Callable = Callable()) -> void:
	_on_menu_toggle = on_menu_toggle
	_on_context_action = on_context_action


# Idempotent: existing actions and key events are left untouched.
func configure_input_map() -> void:
	for action_name in ACTION_BINDINGS:
		_ensure_action(action_name, ACTION_BINDINGS[action_name])


# Called from Main._process so the menu toggle keeps its original polling
# order relative to the rest of the scene tree.
func poll_menu_toggle() -> void:
	if Input.is_action_just_pressed("start"):
		_on_menu_toggle.call()


# Called from Main._process with Main's overworld-idle state (not in a menu,
# battle, or step animation) so the context route can only fire while the
# player is free to act in the overworld.
func poll_context_action(overworld_idle: bool) -> void:
	if not overworld_idle or not _on_context_action.is_valid():
		return
	if Input.is_action_just_pressed("action_a"):
		_on_context_action.call()


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
