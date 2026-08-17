extends Node

const FeedbackBundle := preload("res://scripts/runtime/feedback_bundle.gd")
const FeedbackOutbox := preload("res://scripts/runtime/feedback_outbox.gd")

const RETRY_SECONDS := [30.0, 120.0, 600.0, 3600.0]

var _bundle := FeedbackBundle.new()
var _outbox := FeedbackOutbox.new()
var _http: HTTPRequest
var _retry_timer: Timer
var _retry_index := 0
var _busy := false
var _transport_override: Callable


func _ready() -> void:
	name = "FeedbackReporter"
	process_mode = Node.PROCESS_MODE_ALWAYS
	_http = HTTPRequest.new()
	_http.process_mode = Node.PROCESS_MODE_ALWAYS
	_http.timeout = 15.0
	add_child(_http)
	_retry_timer = Timer.new()
	_retry_timer.one_shot = true
	_retry_timer.process_mode = Node.PROCESS_MODE_ALWAYS
	_retry_timer.timeout.connect(retry_pending)
	add_child(_retry_timer)
	call_deferred("retry_pending")


func submit(message: String, capture: Dictionary, runtime: Node) -> Dictionary:
	var report_id := str(capture.get("report_id", ""))
	var staging_path := _outbox.staging_bundle_path(report_id)
	var built := _bundle.build(message, capture, staging_path)
	if not bool(built.get("ok", false)):
		_outbox.discard_staging(staging_path)
		runtime.emit_trace("feedback_report_failed", "FeedbackReporter", {
			"report_id": report_id, "reason": built.get("error", "bundle_failed")})
		return {"status": "unsaved", "reason": built.get("error", "bundle_failed")}
	var prepared := _outbox.commit(staging_path, built["metadata"], built["build"])
	if not bool(prepared.get("ok", false)):
		runtime.emit_trace("feedback_report_failed", "FeedbackReporter", {
			"report_id": report_id, "reason": prepared.get("error", "outbox_failed")})
		return {"status": "unsaved", "reason": prepared.get("error", "outbox_failed")}
	var owns_upload := not _busy
	var result: Dictionary
	if owns_upload:
		_busy = true
		result = await _upload(prepared)
	else:
		result = {"status": "queued", "reason": "upload_in_progress"}
	if result.get("status") == "sent":
		_outbox.remove(prepared)
		runtime.emit_trace("feedback_report_sent", "FeedbackReporter", {
			"report_id": capture["report_id"], "issue_number": result.get("issue_number", 0)})
	else:
		runtime.emit_trace("feedback_report_queued" if result.get("status") == "queued" else "feedback_report_failed",
			"FeedbackReporter", {"report_id": capture["report_id"], "reason": result.get("reason", "upload_failed")})
		if result.get("status") != "queued":
			_outbox.mark_blocked(prepared, str(result.get("reason", "upload_failed")))
	if owns_upload:
		_busy = false
		_reconcile_retry_schedule()
	return result


func _upload(prepared: Dictionary) -> Dictionary:
	if _transport_override.is_valid():
		return await _transport_override.call(prepared)
	var build: Dictionary = prepared.get("build", {})
	var endpoint := str(build.get("endpoint", "")).strip_edges()
	var token := str(build.get("invite_token", ""))
	if endpoint.is_empty() or token.is_empty():
		return {"status": "queued", "reason": "feedback_not_configured"}
	var metadata_json := JSON.stringify(prepared["metadata"])
	var bundle_bytes := FileAccess.get_file_as_bytes(prepared["bundle_path"])
	var boundary := "----PokeWildsFeedback" + str(prepared["metadata"]["report_id"]).replace("-", "")
	var body := PackedByteArray()
	_append_text(body, "--%s\r\nContent-Disposition: form-data; name=\"metadata\"\r\nContent-Type: application/json\r\n\r\n%s\r\n" % [boundary, metadata_json])
	_append_text(body, "--%s\r\nContent-Disposition: form-data; name=\"bundle\"; filename=\"report.zip\"\r\nContent-Type: application/zip\r\n\r\n" % boundary)
	body.append_array(bundle_bytes)
	_append_text(body, "\r\n--%s--\r\n" % boundary)
	var headers := PackedStringArray(["Authorization: Bearer " + token,
		"Content-Type: multipart/form-data; boundary=" + boundary, "Accept: application/json"])
	var request_error := _http.request_raw(endpoint.trim_suffix("/") + "/v1/reports", headers,
		HTTPClient.METHOD_POST, body)
	if request_error != OK:
		return {"status": "queued", "reason": "request_start_failed"}
	var response: Array = await _http.request_completed
	if int(response[0]) != HTTPRequest.RESULT_SUCCESS:
		return {"status": "queued", "reason": "transport_%d" % int(response[0])}
	var code := int(response[1])
	var parsed = JSON.parse_string((response[3] as PackedByteArray).get_string_from_utf8())
	if code == 200 or code == 201:
		if parsed is Dictionary and bool(parsed.get("ok", false)) \
				and str(parsed.get("report_id", "")) == str(prepared["metadata"].get("report_id", "")) \
				and int(parsed.get("issue_number", 0)) > 0:
			return {"status": "sent", "issue_number": int(parsed["issue_number"])}
		return {"status": "queued", "reason": "invalid_success_response"}
	if code == 202 or code == 408 or code == 429 or code >= 500 or code == 0:
		return {"status": "queued", "reason": "http_%d" % code}
	return {"status": "blocked", "reason": "http_%d" % code}


func retry_pending(only_report_id: String = "") -> void:
	if _busy:
		# A one-shot timer is already stopped when its timeout callback runs.
		# Re-arm it so the active upload owner cannot strand queued work.
		_schedule_retry()
		return
	_busy = true
	var build := _bundle.load_build_info()
	for prepared in _outbox.pending(build, only_report_id):
		var report_id := str(prepared["metadata"].get("report_id", ""))
		var result: Dictionary = await _upload(prepared)
		if result.get("status") == "sent":
			_outbox.remove(prepared)
			var runtime := get_node_or_null("/root/GameRuntime")
			if runtime != null:
				runtime.emit_trace("feedback_report_sent", "FeedbackReporter", {
					"report_id": report_id, "issue_number": result.get("issue_number", 0), "retried": true})
		elif result.get("status") == "queued":
			break
		else:
			_outbox.mark_blocked(prepared, str(result.get("reason", "upload_failed")))
	_busy = false
	_reconcile_retry_schedule()


func _reconcile_retry_schedule() -> void:
	# Freshly rescan after the final await. A submit may have committed another
	# report while this upload owned the shared HTTPRequest.
	if _outbox.pending(_bundle.load_build_info()).is_empty():
		_retry_index = 0
		_retry_timer.stop()
	else:
		_schedule_retry()


func _schedule_retry() -> void:
	if _retry_timer == null or not _retry_timer.is_stopped():
		return
	_retry_timer.start(RETRY_SECONDS[mini(_retry_index, RETRY_SECONDS.size() - 1)])
	_retry_index = mini(_retry_index + 1, RETRY_SECONDS.size() - 1)


func set_transport_for_smoke(transport: Callable) -> void:
	if OS.has_feature("editor"):
		_transport_override = transport


func set_install_id_path_for_smoke(path: String) -> void:
	if OS.has_feature("editor"):
		_bundle.set_install_id_path_for_smoke(path)


func set_build_info_for_smoke(build: Dictionary) -> void:
	if OS.has_feature("editor"):
		_bundle.set_build_info_for_smoke(build)


func state_for_smoke() -> Dictionary:
	if not OS.has_feature("editor"):
		return {}
	return {"busy": _busy, "retry_scheduled": _retry_timer != null and not _retry_timer.is_stopped()}


func _append_text(bytes: PackedByteArray, value: String) -> void:
	bytes.append_array(value.to_utf8_buffer())
