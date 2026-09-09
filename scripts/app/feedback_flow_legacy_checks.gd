extends RefCounted

const UpdateIdentity := preload("res://scripts/runtime/update_identity.gd")
const SmokeTap := preload("res://scripts/app/smoke_tap.gd")
const IDENTITY_PATH := "user://feedback-flow-legacy-identity.json"
const FRIEND := {"endpoint": "https://feedback.invalid/legacy", "invite_token": "legacy-fixture-token",
	"tester_id": "LEGACY-FIXTURE", "channel": "friends-fixture", "identity_kind": "friend"}
const PUBLIC := {"endpoint": "", "invite_token": "", "tester_id": "PUBLIC-ALPHA", "channel": "public",
	"feedback_mode": "public", "feedback_endpoint": "https://feedback.invalid/public"}

var _controller: Node
var _report_id := ""
var _calls := 0
var _send := false
var _failures: Array[String] = []


func run(controller: Node, dialog: Control, tree: SceneTree) -> Array[String]:
	_controller = controller
	var prior_identity_path := UpdateIdentity.path()
	UpdateIdentity.set_path_for_smoke(IDENTITY_PATH)
	var wrong_friend := FRIEND.duplicate(true)
	wrong_friend["tester_id"] = "OTHER-FIXTURE"
	_persist(wrong_friend)
	controller.smoke_set_build_info(FRIEND)
	controller.smoke_set_transport(Callable(self, "_transport"))
	await SmokeTap.tap(tree, "feedback_report")
	_report_id = str(controller.smoke_state().get("report_id", ""))
	dialog.smoke_set_message("A queued report must survive upgrading to a public alpha.")
	await SmokeTap.tap_key(tree, Key.KEY_ENTER)
	_check(dialog.visible and dialog.smoke_result_ready(), "legacy fixture did not queue")
	await SmokeTap.tap_key(tree, Key.KEY_ESCAPE)
	var stem := "user://feedback_outbox/" + _report_id
	controller.smoke_set_build_info(PUBLIC)
	await controller.smoke_retry(_report_id)
	_check(_calls == 2 and FileAccess.file_exists(stem + ".route"), "persisted identity overrode explicit legacy route")
	_check(DirAccess.remove_absolute(ProjectSettings.globalize_path(stem + ".route")) == OK,
		"could not prepare route-less legacy fixture")
	await controller.smoke_retry(_report_id)
	_check(_calls == 2 and FileAccess.file_exists(stem + ".json"), "mismatched identity uploaded a route-less report")
	_persist(FRIEND)
	_send = true
	await controller.smoke_retry(_report_id)
	_check(_calls == 3 and not FileAccess.file_exists(stem + ".json") and not FileAccess.file_exists(stem + ".zip"),
		"public upgrade stranded a matching route-less legacy report")
	await controller.smoke_retry(_report_id)
	_check(_calls == 3, "completed legacy report uploaded again")
	UpdateIdentity.set_path_for_smoke(prior_identity_path)
	for path in [IDENTITY_PATH, IDENTITY_PATH + ".tmp", stem + ".json", stem + ".zip", stem + ".route"]:
		if FileAccess.file_exists(path): DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	return _failures


func _persist(identity: Dictionary) -> void:
	if FileAccess.file_exists(IDENTITY_PATH): DirAccess.remove_absolute(ProjectSettings.globalize_path(IDENTITY_PATH))
	_check(UpdateIdentity.persist_from(identity), "legacy identity fixture did not persist")


func _transport(prepared: Dictionary) -> Dictionary:
	if prepared.get("metadata", {}).get("report_id") != _report_id:
		return {"status": "queued", "reason": "scenario_foreign_report"}
	_calls += 1
	var build: Dictionary = prepared.get("build", {})
	var details: Dictionary = _controller.smoke_request_details(build)
	_check(details.get("endpoint") == FRIEND["endpoint"] and build.get("tester_id") == FRIEND["tester_id"],
		"legacy report was rerouted during public upgrade")
	_check((details.get("headers", PackedStringArray()) as PackedStringArray).has("Authorization: Bearer " + FRIEND["invite_token"]),
		"legacy report lost its saved authorization")
	return {"status": "sent" if _send else "queued", "issue_number": 4321, "reason": "scenario_offline"}


func _check(ok: bool, message: String) -> void:
	if not ok: _failures.append(message)
