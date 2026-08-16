extends RefCounted

# Shared real-input-phase tap injection for the input-leak regression checks
# (input_gate_menu_checks, storage_flow's real Z seam, storage_release_mouse_
# check). A TAP is a press and a release in SEPARATE iterations (press -> the
# consumer iteration completes with just_pressed true -> release later), so
# Input.is_action_just_pressed sees the press exactly once — the shape the
# Main polls fire on. smoke_scenarios._press (press+release in ONE frame)
# drives _unhandled_input but structurally can never fire a poll;
# input_gate_scenario.gd keeps its own copy of these helpers (untouched at
# 220/220), this file shares them with the newer checks.
# Requires Input.use_accumulated_input = true (the caller owns the toggle and
# restores it on every exit): parsed events buffer for the NEXT iteration's
# input phase, so _unhandled_input dispatch and the same-iteration _process
# polls see just_pressed together — the exact frame the input-leak bugs fire
# in. Every caller pairs taps with injection WITNESSES (state changes only
# real delivery can produce) so degraded delivery fails red, never vacuous.

# false: no key event is bound to the action (the caller records a failure).
static func inject_press(action: String) -> bool:
	var template := key_template(action)
	if template == null:
		return false
	var event := InputEventKey.new()
	event.physical_keycode = template.physical_keycode
	event.pressed = true
	Input.parse_input_event(event)
	return true


static func inject_release(action: String) -> void:
	var template := key_template(action)
	if template == null:
		return
	# A fresh event: re-parsing the same object in one frame is engine-rejected.
	var event := InputEventKey.new()
	event.physical_keycode = template.physical_keycode
	event.pressed = false
	Input.parse_input_event(event)


# Press, let the race iteration complete (the polls run with just_pressed
# true), then release in a LATER iteration so the press alone is just-pressed
# on the consumer frame.
static func tap(tree: SceneTree, action: String) -> void:
	inject_press(action)
	await tree.process_frame
	inject_release(action)
	await tree.process_frame


# N presses flush in ONE input phase -> N just_pressed dispatches (the
# input_gate camp-menu / name-grid walk shape), one release afterwards.
# false: no key event is bound to the action (the caller records a failure).
static func flush(tree: SceneTree, action: String, count: int) -> bool:
	for _i in range(count):
		if not inject_press(action):
			return false
	inject_release(action)
	await tree.process_frame
	return true


# One typed digit for a digit row reading unicode 48-57 (gbc_digit_row's
# branch): unicode + matching keycode/physical_keycode, press -> frame -> release.
static func tap_digit(tree: SceneTree, digit: int) -> void:
	var press := InputEventKey.new()
	press.unicode = 48 + digit; press.keycode = 48 + digit; press.physical_keycode = 48 + digit; press.pressed = true
	Input.parse_input_event(press)
	await tree.process_frame
	var release := InputEventKey.new()
	release.unicode = 48 + digit; release.keycode = 48 + digit; release.physical_keycode = 48 + digit; release.pressed = false
	Input.parse_input_event(release)
	await tree.process_frame


static func tap_key(tree: SceneTree, keycode: Key, shifted: bool = false) -> void:
	var press := InputEventKey.new()
	press.keycode = keycode
	press.physical_keycode = keycode
	press.shift_pressed = shifted
	press.pressed = true
	Input.parse_input_event(press)
	await tree.process_frame
	var release := InputEventKey.new()
	release.keycode = keycode
	release.physical_keycode = keycode
	release.shift_pressed = shifted
	release.pressed = false
	Input.parse_input_event(release)
	await tree.process_frame


static func key_template(action: String) -> InputEventKey:
	for event in InputMap.action_get_events(action):
		if event is InputEventKey:
			return event as InputEventKey
	return null
