extends RefCounted

class QuietRuntime:
	extends Node
	var events: Array[String] = []
	func emit_trace(event: String, _source: String, _payload: Dictionary) -> void: events.append(event)

const FeedbackBundle := preload("res://scripts/runtime/feedback_bundle.gd")
const UpdateIdentity := preload("res://scripts/runtime/update_identity.gd")
const SmokeTap := preload("res://scripts/app/smoke_tap.gd")
const OUTBOX_DIR := "user://feedback_outbox"

var _controller: Node
var _dialog: Control
var _tree: SceneTree
var _failures: Array[String] = []
var _unexpected_transport_calls := 0
var _public_report_id := ""
var _public_calls := 0
var _public_result := "queued"


func run(controller: Node, dialog: Control, tree: SceneTree) -> Array[String]:
	_controller = controller
	_dialog = dialog
	_tree = tree
	await _public_stamp_contract()
	await _invite_without_endpoint_contract()
	await _public_alpha_contract()
	_safe_errors_contract()
	return _failures


func _public_stamp_contract() -> void:
	_controller.smoke_set_build_info({"channel": "public", "build_id": "public",
		"commit_sha": "public", "endpoint": "", "invite_token": "", "tester_id": "UNASSIGNED"})
	_controller.smoke_set_transport(Callable(self, "_unexpected_transport"))
	await SmokeTap.tap(_tree, "feedback_report")
	_check(not _dialog.visible, "public stamp opened feedback")
	_check(not _tree.paused, "public stamp paused the tree")
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


func _public_build() -> Dictionary:
	return {"channel": "public", "version": "alpha", "build_id": "public-alpha",
		"commit_sha": "abcdef0", "endpoint": "", "invite_token": "", "tester_id": "PUBLIC-ALPHA",
		"feedback_mode": "public", "feedback_endpoint": "https://feedback.invalid/public"}


func _public_alpha_contract() -> void:
	var build := _public_build()
	var friend := {"endpoint": "https://feedback.invalid/old", "invite_token": "old-friend",
		"tester_id": "OLD-FRIEND", "channel": "friends-1", "identity_kind": "friend"}
	var resolved := FeedbackBundle.resolve_feedback_build(build, friend)
	_check(resolved == build, "public feedback restored a stale friend route")
	_check(UpdateIdentity.merge(build, friend).get("endpoint", "") == "", "public feedback enabled the updater")
	var legacy: Dictionary = _controller.smoke_request_details(friend)
	_check((legacy.get("headers", PackedStringArray()) as PackedStringArray).has("Authorization: Bearer old-friend"),
		"legacy invited request lost authorization")
	_controller.smoke_set_build_info(build)
	_controller.smoke_set_transport(Callable(self, "_public_transport"))
	await SmokeTap.tap(_tree, "feedback_report")
	_check(_dialog.visible and _tree.paused, "public alpha did not open feedback")
	_public_report_id = str(_controller.smoke_state().get("report_id", ""))
	await _type_x(false)
	await _type_x(true)
	_check(_dialog.visible and _dialog.smoke_message() == "xX", "typing x/X cancelled or lost text")
	await SmokeTap.tap_key(_tree, Key.KEY_ENTER, true)
	_check(_dialog.smoke_message() == "xX\n", "public report lost Shift+Enter")
	await SmokeTap.tap_key(_tree, Key.KEY_ENTER)
	await _tree.create_timer(2.1, true, false, true).timeout
	_check(_dialog.visible and _dialog.smoke_result_ready() and _tree.paused, "public result was not retained")
	await SmokeTap.tap_key(_tree, Key.KEY_ESCAPE)
	_check(not _dialog.visible and not _tree.paused, "public result acknowledgement did not resume")
	var stem := "%s/%s" % [OUTBOX_DIR, _public_report_id]
	var route = JSON.parse_string(FileAccess.get_file_as_string(stem + ".route"))
	_check(route is Dictionary and route.get("feedback_mode") == "public" \
		and route.get("feedback_endpoint") == build["feedback_endpoint"] and route.get("invite_token") == "",
		"public outbox did not preserve its credential-free route")
	_controller.smoke_set_build_info(friend)
	_public_result = "sent"
	await _controller.smoke_retry(_public_report_id)
	_check(_public_calls == 2 and not FileAccess.file_exists(stem + ".json") \
		and not FileAccess.file_exists(stem + ".zip") and not FileAccess.file_exists(stem + ".route"),
		"public retry did not use its saved route and clear its outbox")
	_controller.smoke_set_build_info(build)
	_public_result = "blocked"
	await SmokeTap.tap(_tree, "feedback_report")
	_public_report_id = str(_controller.smoke_state().get("report_id", ""))
	var quiet_runtime := QuietRuntime.new()
	_dialog.show_sending()
	var rejected: Dictionary = await _controller.smoke_submit("The report must explain permanent rejection.", quiet_runtime)
	_dialog.show_result(_controller.smoke_result_message(rejected))
	quiet_runtime.free()
	_check(_dialog.visible and _dialog.smoke_result_ready(), "public rejection result disappeared")
	await SmokeTap.tap_key(_tree, Key.KEY_ENTER)
	stem = "%s/%s" % [OUTBOX_DIR, _public_report_id]
	var metadata = JSON.parse_string(FileAccess.get_file_as_string(stem + ".json"))
	_check(metadata is Dictionary and metadata.get("upload_status") == "blocked" \
		and metadata.get("upload_error") == "http_400:invalid_message", "public rejection was not terminal")
	await _controller.smoke_retry(_public_report_id)
	_check(_public_calls == 3, "blocked public report retried")
	for suffix in [".json", ".zip", ".route"]:
		if FileAccess.file_exists(stem + suffix): DirAccess.remove_absolute(ProjectSettings.globalize_path(stem + suffix))
	var invalid := build.duplicate(true)
	invalid["feedback_endpoint"] = "http://feedback.invalid"
	_check(_controller.smoke_request_details(invalid).get("error") == "feedback_endpoint_invalid", "public HTTP endpoint accepted")
	invalid = build.duplicate(true)
	invalid["channel"] = "friends-1"
	_check(_controller.smoke_request_details(invalid).get("error") == "feedback_configuration_invalid", "public friend channel accepted")


func _public_transport(prepared: Dictionary) -> Dictionary:
	if prepared.get("metadata", {}).get("report_id") != _public_report_id:
		return {"status": "queued", "reason": "scenario_foreign_report"}
	_public_calls += 1
	var details: Dictionary = _controller.smoke_request_details(prepared.get("build", {}))
	var headers: PackedStringArray = details.get("headers", PackedStringArray())
	_check(details.get("endpoint") == _public_build()["feedback_endpoint"] and details.get("error") == "",
		"public transport used the wrong route")
	_check(headers.has("User-Agent: PokeWilds-feedback/1.0"), "public upload omitted application user agent")
	for header in headers: _check(not header.to_lower().begins_with("authorization:"), "public upload included authorization")
	_check(prepared.get("metadata", {}).get("tester_id") == "PUBLIC-ALPHA", "public report used a friend tester")
	return {"status": _public_result, "reason": "http_400:invalid_message" if _public_result == "blocked" else "scenario_offline", "issue_number": 4321}


func _type_x(shifted: bool) -> void:
	var press := InputEventKey.new()
	press.keycode = Key.KEY_X
	press.physical_keycode = Key.KEY_X
	press.unicode = 88 if shifted else 120
	press.shift_pressed = shifted
	press.pressed = true
	Input.parse_input_event(press)
	await _tree.process_frame
	var release := press.duplicate() as InputEventKey
	release.pressed = false
	Input.parse_input_event(release)
	await _tree.process_frame


func _safe_errors_contract() -> void:
	_check(_controller.smoke_response_reason(403, {"error": "invalid_invite_token"}) == "http_403:invalid_invite_token",
		"relay error identifier was discarded")
	for value in ["<html>blocked</html>", "sensitive value", "x".repeat(65)]:
		_check(_controller.smoke_response_reason(403, {"error": value}) == "http_403", "unsafe relay error text escaped")
