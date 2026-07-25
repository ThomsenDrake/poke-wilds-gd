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


static func key_template(action: String) -> InputEventKey:
	for event in InputMap.action_get_events(action):
		if event is InputEventKey:
			return event as InputEventKey
	return null
