extends RefCounted

class QuietRuntime:
	extends Node
	var events: Array[String] = []
	func emit_trace(event: String, _source: String, _payload: Dictionary) -> void: events.append(event)

const SmokeTap := preload("res://scripts/app/smoke_tap.gd")
const OUTBOX_DIR := "user://feedback_outbox"

var _controller: Node
var _dialog: Control
var _tree: SceneTree
var _failures: Array[String] = []
var _unexpected_transport_calls := 0


func run(controller: Node, dialog: Control, tree: SceneTree) -> Array[String]:
	_controller = controller
	_dialog = dialog
	_tree = tree
	await _public_stamp_contract()
	await _invite_without_endpoint_contract()
	return _failures


func _public_stamp_contract() -> void:
	_controller.smoke_set_build_info({"channel": "public", "build_id": "public",
		"commit_sha": "public", "endpoint": "", "invite_token": "", "tester_id": "UNASSIGNED"})
	_controller.smoke_set_transport(Callable(self, "_unexpected_transport"))
	await SmokeTap.tap(_tree, "feedback_report")
	_check(not _dialog.visible, "public stamp opened feedback")
	_check(str(_controller.smoke_state().get("report_id", "")) == "",
		"public stamp captured a report")
	_check(_unexpected_transport_calls == 0, "public stamp reached the upload transport")


func _invite_without_endpoint_contract() -> void:
	_controller.smoke_set_build_info({"channel": "scenario-misconfig", "build_id": "scenario-misconfig",
		"commit_sha": "scenario", "endpoint": "", "invite_token": "scenario-token-misconfig",
		"tester_id": "T-SCENARIO-MISCONFIG"})
	_controller.smoke_set_transport(Callable(self, "_unexpected_transport"))
	await SmokeTap.tap(_tree, "feedback_report")
	_check(_dialog.visible, "invite-without-endpoint check could not open feedback")
	var report_id := str(_controller.smoke_state().get("report_id", ""))
	var quiet_runtime := QuietRuntime.new()
	var result: Dictionary = await _controller.smoke_submit(
		"This build has no relay configuration.", quiet_runtime)
	quiet_runtime.free()
	_check(result.get("status") == "unsaved" and result.get("reason") == "feedback_not_configured",
		"invite-without-endpoint did not return the truthful unsaved result")
	await SmokeTap.tap_key(_tree, Key.KEY_ESCAPE)
	var stem := "%s/%s" % [OUTBOX_DIR, report_id]
	_check(_unexpected_transport_calls == 0, "invite-without-endpoint reached the upload transport")
	_check(not FileAccess.file_exists(stem + ".json") and not FileAccess.file_exists(stem + ".zip") \
		and not FileAccess.file_exists(stem + ".zip.tmp") \
		and not FileAccess.file_exists(stem + ".route"),
		"invite-without-endpoint committed a permanently unsendable outbox entry")


func _unexpected_transport(_prepared: Dictionary) -> Dictionary:
	_unexpected_transport_calls += 1
	return {"status": "queued", "reason": "unexpected_transport"}


func _check(ok: bool, message: String) -> void:
	if not ok:
		_failures.append(message)
