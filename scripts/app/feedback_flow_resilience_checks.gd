extends RefCounted

const Redactor := preload("res://scripts/core/feedback_redactor.gd")
const SmokeTap := preload("res://scripts/app/smoke_tap.gd")
const OUTBOX_DIR := "user://feedback_outbox"

var _controller: Node
var _dialog: Control
var _tree: SceneTree
var _failures: Array[String] = []
var _transport_calls := 0


func run(controller: Node, dialog: Control, tree: SceneTree) -> Array[String]:
	_controller = controller
	_dialog = dialog
	_tree = tree
	_result_copy_contract()
	_redaction_contract()
	_controller.smoke_set_build_info({"channel": "scenario-blocked", "build_id": "scenario-blocked",
		"commit_sha": "scenario", "endpoint": "https://feedback.invalid/blocked",
		"invite_token": "scenario-token-blocked", "tester_id": "T-SCENARIO-BLOCKED"})
	_controller.smoke_set_transport(Callable(self, "_queue_transport"))
	await SmokeTap.tap(_tree, "feedback_report")
	_check(_dialog.visible, "blocked-write check could not open feedback")
	var report_id := str(_controller.smoke_state().get("report_id", ""))
	_dialog.smoke_set_message("A permanent rejection must stop retrying.")
	await SmokeTap.tap_key(_tree, Key.KEY_ENTER)
	await _tree.create_timer(2.1, true, false, true).timeout
	var stem := "%s/%s" % [OUTBOX_DIR, report_id]
	_check(_transport_calls == 1 and FileAccess.file_exists(stem + ".json"),
		"blocked-write check did not queue its initial report")
	_controller.smoke_set_transport(Callable(self, "_blocked_transport"))
	await _controller.smoke_retry(report_id)
	_check(_transport_calls == 2, "blocked-write check did not run its permanent retry")
	_check(not FileAccess.file_exists(stem + ".json") and not FileAccess.file_exists(stem + ".zip"),
		"failed blocked-state write left an active retry pair")
	_check(FileAccess.file_exists(stem + ".blocked-write-failed.json")
		and FileAccess.file_exists(stem + ".blocked-write-failed.zip"),
		"failed blocked-state write did not preserve a quarantined pair")
	_check(not FileAccess.file_exists(stem + ".route"), "blocked quarantine retained its private route")
	await _controller.smoke_retry(report_id)
	_check(_transport_calls == 2, "quarantined permanent rejection uploaded again")
	_controller.smoke_set_build_info({})
	for suffix in [".blocked-write-failed.json", ".blocked-write-failed.zip"]:
		_remove(stem + suffix)
	return _failures


func _queue_transport(_prepared: Dictionary) -> Dictionary:
	_transport_calls += 1
	return {"status": "queued", "reason": "scenario_offline"}


func _blocked_transport(prepared: Dictionary) -> Dictionary:
	_transport_calls += 1
	# Make mark_blocked fail without making the real pair unwritable; the fallback
	# must discover and quarantine the pair from its committed report identity.
	prepared["metadata_path"] = ""
	return {"status": "blocked", "reason": "scenario_permanent"}


func _redaction_contract() -> void:
	var previous := OS.get_environment("USERNAME")
	OS.set_environment("USERNAME", "a")
	var ordinary := Redactor.sanitize_message("I walked into a tree and got stuck.")
	OS.set_environment("USERNAME", previous)
	_check(ordinary == "I walked into a tree and got stuck.",
		"short machine username corrupted ordinary report text")
	var identity := Redactor.sanitize_text("username=a path=%ssave.json" %
		ProjectSettings.globalize_path("user://"))
	_check(identity.contains("username=[REDACTED_MACHINE]")
		and (identity.contains("$HOME") or identity.contains("$USER_DATA/")),
		"semantic machine identity or path was not redacted")
	_check(_controller.smoke_validated_endpoint("http://feedback.invalid").is_empty(),
		"runtime accepted an unsafe embedded endpoint")
	_check(_controller.smoke_validated_endpoint("https://feedback.invalid/") == "https://feedback.invalid",
		"runtime rejected or failed to normalize a legitimate HTTPS endpoint")


func _result_copy_contract() -> void:
	_check(_controller.smoke_result_message({"status": "unsaved"}) ==
		"Report could not be saved—please try again or tell Drake.",
		"unsaved bundle failure claimed a local copy existed")
	_check(_controller.smoke_result_message({"status": "blocked"}) ==
		"Saved on this computer—please let Drake know.",
		"retained blocked bundle did not identify the local copy")


func _remove(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _check(ok: bool, message: String) -> void:
	if not ok:
		_failures.append(message)
