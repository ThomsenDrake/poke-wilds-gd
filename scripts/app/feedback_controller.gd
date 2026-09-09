extends Node

const FeedbackReporter := preload("res://scripts/runtime/feedback_reporter.gd")
const PerformanceMonitors := preload("res://scripts/runtime/performance_monitors.gd")
const UiTreeDumpWriter := preload("res://scripts/app/ui_tree_dump_writer.gd")
const Redactor := preload("res://scripts/core/feedback_redactor.gd")
const FeedbackBundle := preload("res://scripts/runtime/feedback_bundle.gd")
const FeedbackSnapshot := preload("res://scripts/runtime/feedback_snapshot.gd")

@export var dialog_path: NodePath

var _dialog: Control
var _reporter: Node
var _capture: Dictionary = {}
var _previous_paused := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_dialog = get_node(dialog_path)
	_dialog.submitted.connect(_on_submitted)
	_dialog.cancelled.connect(_on_cancelled)
	_reporter = FeedbackReporter.new()
	add_child(_reporter)


func _input(event: InputEvent) -> void:
	if _dialog.visible or not event.is_action_pressed("feedback_report"):
		return
	var focus := get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit:
		return
	if _feedback_disabled():
		return
	_begin_capture()
	get_viewport().set_input_as_handled()


func _feedback_disabled() -> bool:
	var embed: Dictionary = _reporter.embedded_build_info()
	return embed.get("feedback_mode", "") != "public" and str(embed.get("invite_token", "")).strip_edges().is_empty() \
		and str(embed.get("endpoint", "")).strip_edges().is_empty()


func _begin_capture() -> void:
	var runtime := get_node("/root/GameRuntime")
	var report_id := _new_report_id()
	var screen := PerformanceMonitors.screen_label_for(runtime)
	var screenshot := PackedByteArray()
	if DisplayServer.get_name() != "headless":
		var texture := get_viewport().get_texture()
		var image := texture.get_image() if texture != null else null
		if image != null and not image.is_empty():
			screenshot = image.save_png_to_buffer()
	var snapshot := FeedbackSnapshot.capture(runtime, screen)
	var ui_tree := _capture_ui_tree(screen)
	runtime.emit_trace("feedback_capture_requested", "FeedbackController", {
		"report_id": report_id, "screen": screen, "screenshot_available": not screenshot.is_empty()})
	_capture = {"report_id": report_id, "screen": screen, "screenshot": screenshot,
		"ui_tree": ui_tree, "save": snapshot["save"], "runtime": snapshot["runtime"],
		"game": snapshot["game"], "trace_slice": runtime.trace.session_log_slice(),
		"engine_slice": FeedbackBundle.engine_log_slice()}
	_previous_paused = get_tree().paused
	get_tree().paused = true
	_dialog.open_dialog()


func _capture_ui_tree(screen: String) -> Dictionary:
	var ui := get_node_or_null("../UI")
	if ui == null:
		return {"screen": screen, "cursor": {}, "node_count": 0, "nodes": []}
	# UI is the common CanvasLayer parent. Snapshotting it includes every visible
	# sibling root (for example a MessageBox over a still-visible menu) while the
	# writer's full-chain visibility filter excludes hidden screens and the
	# not-yet-open feedback dialog.
	return UiTreeDumpWriter.snapshot_screen(screen, ui, {})


func _on_submitted(message: String) -> void:
	_dialog.show_sending()
	var result: Dictionary = await _reporter.submit(message, _capture, get_node("/root/GameRuntime"))
	_dialog.show_result(_result_message(result))


func _on_cancelled() -> void:
	_close_and_resume()


func _close_and_resume() -> void:
	_dialog.close_dialog()
	get_tree().paused = _previous_paused
	_capture = {}


func _new_report_id() -> String:
	var raw := Redactor.random_token(16)
	return "%s-%s-%s-%s-%s" % [raw.substr(0, 8), raw.substr(8, 4), raw.substr(12, 4),
		raw.substr(16, 4), raw.substr(20, 12)]


func _result_message(result: Dictionary) -> String:
	match str(result.get("status", "unsaved")):
		"sent": return "Report #%d sent. Thank you!" % int(result.get("issue_number", 0))
		"sent_cleanup_failed": return "Report #%d sent, but local cleanup failed—please tell Drake." % int(result.get("issue_number", 0))
		"queued": return "Saved — delivery is pending. It will retry automatically."
		"blocked": return "Report was not accepted (%s). A copy is saved on this computer." % str(result.get("reason", "rejected"))
		_:
			if str(result.get("reason", "")).begins_with("feedback_"):
				return "Feedback is unavailable in this build. Please install the latest alpha."
			return "Report could not be saved—please try again or tell Drake."


# One explicit editor-only seam for feedback_flow; production behavior stays
# observable through signals/traces instead of scenario access to private nodes.
func smoke_state() -> Dictionary:
	if not OS.has_feature("editor"):
		return {}
	var paths: Array = []
	for entry in _capture.get("ui_tree", {}).get("nodes", []):
		paths.append(str(entry.get("path", "")))
	return {"dialog_visible": _dialog.visible, "capture_screen": _capture.get("screen", ""),
		"report_id": _capture.get("report_id", ""), "capture_ui_paths": paths}


func smoke_set_transport(transport: Callable) -> void:
	if OS.has_feature("editor"):
		_reporter.set_transport_for_smoke(transport)


func smoke_set_install_id_path(path: String) -> void:
	if OS.has_feature("editor"):
		_reporter.set_install_id_path_for_smoke(path)


func smoke_set_build_info(build: Dictionary) -> void:
	if OS.has_feature("editor"):
		_reporter.set_build_info_for_smoke(build)


func smoke_set_remove_failure(failure: Callable) -> void:
	if OS.has_feature("editor"):
		_reporter.set_remove_failure_for_smoke(failure)


func smoke_reporter_state() -> Dictionary:
	return _reporter.state_for_smoke() if OS.has_feature("editor") else {}


func smoke_validated_endpoint(value: String) -> String:
	return _reporter.validated_endpoint_for_smoke(value) if OS.has_feature("editor") else ""


func smoke_result_message(result: Dictionary) -> String:
	return _result_message(result) if OS.has_feature("editor") else ""


func smoke_submit(message: String, runtime: Node) -> Dictionary:
	return await _reporter.submit(message, _capture, runtime) if OS.has_feature("editor") else {}


func smoke_retry(report_id: String) -> void:
	if OS.has_feature("editor"):
		await _reporter.retry_pending(report_id)


func smoke_request_details(build: Dictionary) -> Dictionary:
	return _reporter.request_details_for_smoke(build) if OS.has_feature("editor") else {}


func smoke_response_reason(code: int, parsed: Variant) -> String:
	return _reporter.response_reason_for_smoke(code, parsed) if OS.has_feature("editor") else ""
