extends Node

# Real-F filing for play_agent_loop. Mock transport unless live env is on.

const SmokeTap := preload("res://scripts/app/smoke_tap.gd")
const Checks := preload("res://scripts/app/play_agent_loop_file_checks.gd")

var _mock_status := "sent"
var _mock_reason := "agent_play_dry"
var _mock_issue := 0


func file_feedback(ctx: Dictionary, payload: Dictionary) -> Dictionary:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var message := str(payload.get("message", ""))
	if not Checks.message_ok(message):
		return {"status": "blocked", "reason": "invalid_message", "issue_number": 0}
	var live := Checks.live_requested(payload)
	Checks.release_text_focus(get_tree())
	await get_tree().process_frame
	var controller: Node = ctx["feedback_controller"]
	var dialog: Control = ctx["feedback_dialog"]
	controller.smoke_set_install_id_path(Checks.INSTALL_ID_PATH)
	controller.smoke_set_build_info(Checks.public_stamp(live))
	if not live:
		controller.smoke_set_transport(Callable(self, "_mock_transport"))
	await SmokeTap.tap(get_tree(), "feedback_report")
	if not dialog.visible:
		return {"status": "blocked", "reason": "feedback_not_configured", "issue_number": 0}
	dialog.smoke_set_message(message)
	await SmokeTap.tap_key(get_tree(), KEY_ENTER)
	await get_tree().create_timer(2.1, true, false, true).timeout
	var result := {"status": _mock_status, "reason": _mock_reason, "issue_number": _mock_issue}
	if live:
		result = _live_result(controller, dialog)
	if dialog.visible:
		await SmokeTap.tap_key(get_tree(), KEY_ENTER)
	return result


func _mock_transport(_prepared: Dictionary) -> Dictionary:
	return {"status": _mock_status, "reason": _mock_reason, "issue_number": _mock_issue}


func _live_result(controller: Node, dialog: Control) -> Dictionary:
	var state: Dictionary = controller.smoke_reporter_state()
	var status := "queued"
	if dialog.smoke_result_ready():
		status = str(state.get("last_status", "sent"))
	return {
		"status": status,
		"reason": str(state.get("last_reason", "")),
		"issue_number": int(state.get("issue_number", 0)),
	}
