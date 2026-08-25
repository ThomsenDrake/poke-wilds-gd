extends RefCounted

const SmokeTap := preload("res://scripts/app/smoke_tap.gd")

var _controller: Node
var _dialog: Control
var _tree: SceneTree
var _failures: Array[String] = []


func run(controller: Node, dialog: Control, tree: SceneTree) -> Array[String]:
	_controller = controller
	_dialog = dialog
	_tree = tree
	await _escape_only_cancel_contract()
	return _failures


func _escape_only_cancel_contract() -> void:
	_controller.smoke_set_build_info({"channel": "scenario-escape", "build_id": "scenario-escape",
		"commit_sha": "scenario", "endpoint": "https://feedback.invalid/escape",
		"invite_token": "scenario-token-escape", "tester_id": "T-SCENARIO-ESCAPE"})
	var prior_paused := _tree.paused
	await SmokeTap.tap(_tree, "feedback_report")
	_check(_dialog.visible and _tree.paused, "escape-only check could not open feedback")
	var hint: String = _dialog.smoke_status()
	_check(hint == "Enter: Send   Shift+Enter: New line   Esc: Cancel" and not hint.contains("X"),
		"feedback hint still advertised X cancel")
	await SmokeTap.tap(_tree, "action_b")
	if _dialog.smoke_message().is_empty():
		await _type_x()
	_check(_dialog.visible and _tree.paused and _dialog.smoke_message().contains("x"),
		"X or action_b cancelled feedback or failed to type")
	await SmokeTap.tap_key(_tree, Key.KEY_ESCAPE)
	_check(not _dialog.visible and _tree.paused == prior_paused, "Escape did not restore pause")
	_controller.smoke_set_build_info({})


func _type_x() -> void:
	var press := InputEventKey.new()
	press.keycode = Key.KEY_X
	press.physical_keycode = Key.KEY_X
	press.unicode = 120
	press.pressed = true
	Input.parse_input_event(press)
	await _tree.process_frame
	var release := InputEventKey.new()
	release.keycode = Key.KEY_X
	release.physical_keycode = Key.KEY_X
	release.pressed = false
	Input.parse_input_event(release)
	await _tree.process_frame


func _check(ok: bool, message: String) -> void:
	if not ok:
		_failures.append(message)
