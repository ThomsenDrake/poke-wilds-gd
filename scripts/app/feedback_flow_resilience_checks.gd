extends RefCounted

class QuietRuntime:
	extends Node
	var events: Array[String] = []
	func emit_trace(event: String, _source: String, _payload: Dictionary) -> void: events.append(event)

const Redactor := preload("res://scripts/core/feedback_redactor.gd")
const TraceLogger := preload("res://scripts/core/trace_logger.gd")
const FeedbackBundle := preload("res://scripts/runtime/feedback_bundle.gd")
const SmokeTap := preload("res://scripts/app/smoke_tap.gd")
const StampChecks := preload("res://scripts/app/feedback_flow_stamp_checks.gd")
const OUTBOX_DIR := "user://feedback_outbox"
const ENGINE_TAIL_TEST_PATH := "user://feedback-flow-engine-tail.log"

var _controller: Node
var _dialog: Control
var _tree: SceneTree
var _failures: Array[String] = []
var _transport_calls := 0
var _sent_cleanup_calls := 0


func run(controller: Node, dialog: Control, tree: SceneTree) -> Array[String]:
	_controller = controller
	_dialog = dialog
	_tree = tree
	_result_copy_contract()
	_redaction_contract()
	_trace_truncation_contract()
	_engine_log_tail_contract()
	_failures.append_array(await StampChecks.new().run(_controller, _dialog, _tree))
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
	await _sent_cleanup_contract()
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


func _sent_cleanup_contract() -> void:
	_controller.smoke_set_build_info({"channel": "scenario-sent", "build_id": "scenario-sent",
		"commit_sha": "scenario", "endpoint": "https://feedback.invalid/sent",
		"invite_token": "scenario-token-sent", "tester_id": "T-SCENARIO-SENT"})
	_controller.smoke_set_transport(func(_prepared: Dictionary) -> Dictionary:
		_sent_cleanup_calls += 1
		return {"status": "sent", "issue_number": 4321})
	_controller.smoke_set_remove_failure(func(path: String) -> bool: return path.ends_with(".zip"))
	await SmokeTap.tap(_tree, "feedback_report")
	var report_id := str(_controller.smoke_state().get("report_id", ""))
	var quiet_runtime := QuietRuntime.new()
	var result: Dictionary = await _controller.smoke_submit("Sent cleanup must be durable.", quiet_runtime)
	await SmokeTap.tap_key(_tree, Key.KEY_ESCAPE)
	_controller.smoke_set_remove_failure(Callable())
	var stem := "%s/%s" % [OUTBOX_DIR, report_id]
	_check(result.get("status") == "sent_cleanup_failed" and result.get("reason") == "sent_cleanup_failed",
		"failed sent cleanup was declared successful")
	_check(FileAccess.file_exists(stem + ".sent-cleanup-failed.json") \
		and FileAccess.file_exists(stem + ".sent-cleanup-failed.zip") \
		and not FileAccess.file_exists(stem + ".route"), "failed sent cleanup was not quarantined")
	var marker = JSON.parse_string(FileAccess.get_file_as_string(stem + ".sent-cleanup-failed.json"))
	_check(marker is Dictionary and marker.get("upload_status") == "sent" \
		and not quiet_runtime.events.has("feedback_report_sent"), "sent terminal state or trace was dishonest")
	quiet_runtime.free()
	await _controller.smoke_retry(report_id)
	_check(_sent_cleanup_calls == 1, "quarantined sent report uploaded again")
	for suffix in [".sent-cleanup-failed.json", ".sent-cleanup-failed.zip"]: _remove(stem + suffix)


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
	for malformed in ["https://relay.invalid:bogus", "https://:443", "https://relay.invalid:"]:
		_check(_controller.smoke_validated_endpoint(malformed).is_empty(), "runtime accepted malformed relay authority")


func _trace_truncation_contract() -> void:
	var logger := TraceLogger.new()
	logger.emit_event("feedback_truncation_probe", "FeedbackFlowResilienceChecks")
	var session_slice := logger.session_log_slice(64)
	_check(bool(session_slice.get("truncated", false)), "trace logger truncation probe did not truncate")
	_check(_has_valid_truncation_marker(session_slice.get("bytes", PackedByteArray()), "TraceLogger"),
		"trace logger truncation marker omitted the canonical trace shape")
	var source_line := (JSON.stringify({"event": "feedback_truncation_probe", "ts_msec": 1,
		"source": "FeedbackFlowResilienceChecks", "payload": {}}) + "\n")
	var reduced := FeedbackBundle.new()._reduce_trace_middle(
		source_line.repeat(2048).to_utf8_buffer(), 64 * 1024)
	_check(_has_valid_truncation_marker(reduced, "FeedbackBundle"),
		"bundle-size truncation marker omitted the canonical trace shape")


func _has_valid_truncation_marker(bytes: PackedByteArray, source: String) -> bool:
	for line in bytes.get_string_from_utf8().split("\n", false):
		var record = JSON.parse_string(line)
		if record is Dictionary and record.get("event") == "feedback_trace_truncated" \
				and record.get("source") == source:
			return record.has("ts_msec") and int(record.get("ts_msec", -1)) >= 0 \
				and record.get("payload") is Dictionary
	return false


func _engine_log_tail_contract() -> void:
	_remove(ENGINE_TAIL_TEST_PATH)
	var sensitive_line := "Authorization: Bearer SENSITIVE-FRAGMENT\n"
	var safe_line := "safe diagnostic\n"
	var prefix := "older diagnostic\n"
	var file := FileAccess.open(ENGINE_TAIL_TEST_PATH, FileAccess.WRITE)
	_check(file != null, "engine-log tail check could not create its fixture")
	if file == null:
		return
	_check(file.store_string(prefix + sensitive_line + safe_line),
		"engine-log tail check could not write its fixture")
	file.close()
	var limit := sensitive_line.length() - "Authorization: Bearer ".length() + safe_line.length()
	var sliced := FeedbackBundle._engine_log_slice_at(ENGINE_TAIL_TEST_PATH, limit)
	var sliced_bytes: PackedByteArray = sliced.get("bytes", PackedByteArray())
	var text := sliced_bytes.get_string_from_utf8()
	_check(bool(sliced.get("truncated", false)) and text == safe_line,
		"engine-log tail retained a partial pre-redaction line")
	_remove(ENGINE_TAIL_TEST_PATH)


func _result_copy_contract() -> void:
	_check(_controller.smoke_result_message({"status": "unsaved"}) ==
		"Report could not be saved—please try again or tell Drake.",
		"unsaved bundle failure claimed a local copy existed")
	_check(_controller.smoke_result_message({"status": "blocked"}) ==
		"Saved on this computer—please let Drake know.",
		"retained blocked bundle did not identify the local copy")
	_check(_controller.smoke_result_message({"status": "sent_cleanup_failed", "issue_number": 4321}).begins_with("Report #4321 sent"),
		"remote success with local cleanup failure hid the issue number")


func _remove(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _check(ok: bool, message: String) -> void:
	if not ok:
		_failures.append(message)
