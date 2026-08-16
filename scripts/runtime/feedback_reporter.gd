extends Node

const FeedbackBundle := preload("res://scripts/runtime/feedback_bundle.gd")

const RETRY_SECONDS := [30.0, 120.0, 600.0, 3600.0]

var _bundle := FeedbackBundle.new()
var _http: HTTPRequest
var _retry_timer: Timer
var _retry_index := 0
var _busy := false
var transport_override: Callable


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
	_retry_timer.timeout.connect(_retry_pending)
	add_child(_retry_timer)
	call_deferred("_retry_pending")


func submit(message: String, capture: Dictionary, runtime: Node) -> Dictionary:
	var prepared := _bundle.prepare(message, capture, runtime)
	if not bool(prepared.get("ok", false)):
		runtime.emit_trace("feedback_report_failed", "FeedbackReporter", {
			"report_id": capture.get("report_id", ""), "reason": prepared.get("error", "bundle_failed")})
		return {"status": "blocked", "reason": prepared.get("error", "bundle_failed")}
	var result: Dictionary = await _upload(prepared)
	if result.get("status") == "sent":
		_delete_prepared(prepared)
		runtime.emit_trace("feedback_report_sent", "FeedbackReporter", {
			"report_id": capture["report_id"], "issue_number": result.get("issue_number", 0)})
	else:
		runtime.emit_trace("feedback_report_queued" if result.get("status") == "queued" else "feedback_report_failed",
			"FeedbackReporter", {"report_id": capture["report_id"], "reason": result.get("reason", "upload_failed")})
		if result.get("status") == "queued":
			_schedule_retry()
		else:
			_mark_blocked(prepared, str(result.get("reason", "upload_failed")))
	return result


func _upload(prepared: Dictionary) -> Dictionary:
	if transport_override.is_valid():
		return transport_override.call(prepared)
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
	if code == 202 or code == 429 or code >= 500 or code == 0:
		return {"status": "queued", "reason": "http_%d" % code}
	return {"status": "blocked", "reason": "http_%d" % code}


func _retry_pending(only_report_id: String = "") -> void:
	if _busy:
		return
	_busy = true
	var dir := DirAccess.open(FeedbackBundle.OUTBOX_DIR)
	if dir != null:
		for filename in dir.get_files():
			if not filename.ends_with(".json"):
				continue
			if not only_report_id.is_empty() and filename != only_report_id + ".json":
				continue
			var metadata_path := "%s/%s" % [FeedbackBundle.OUTBOX_DIR, filename]
			var parsed = JSON.parse_string(FileAccess.get_file_as_string(metadata_path))
			if not parsed is Dictionary:
				continue
			if str(parsed.get("upload_status", "")) == "blocked":
				continue
			var report_id := filename.trim_suffix(".json")
			var prepared := {"ok": true, "metadata": parsed, "metadata_path": metadata_path,
				"bundle_path": "%s/%s.zip" % [FeedbackBundle.OUTBOX_DIR, report_id],
				"build": _bundle.load_build_info()}
			if not FileAccess.file_exists(prepared["bundle_path"]):
				continue
			var result: Dictionary = await _upload(prepared)
			if result.get("status") == "sent":
				_delete_prepared(prepared)
				_retry_index = 0
				_retry_timer.stop()
				var runtime := get_node_or_null("/root/GameRuntime")
				if runtime != null:
					runtime.emit_trace("feedback_report_sent", "FeedbackReporter", {
						"report_id": report_id, "issue_number": result.get("issue_number", 0), "retried": true})
			elif result.get("status") == "queued":
				_schedule_retry()
				break
			else:
				_mark_blocked(prepared, str(result.get("reason", "upload_failed")))
	_busy = false


func _schedule_retry() -> void:
	if _retry_timer == null or not _retry_timer.is_stopped():
		return
	_retry_timer.start(RETRY_SECONDS[mini(_retry_index, RETRY_SECONDS.size() - 1)])
	_retry_index = mini(_retry_index + 1, RETRY_SECONDS.size() - 1)


func _delete_prepared(prepared: Dictionary) -> void:
	for key in ["bundle_path", "metadata_path"]:
		var path := str(prepared.get(key, ""))
		if not path.is_empty() and FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _mark_blocked(prepared: Dictionary, reason: String) -> void:
	var path := str(prepared.get("metadata_path", ""))
	if path.is_empty():
		return
	var metadata: Dictionary = prepared.get("metadata", {}).duplicate(true)
	metadata["upload_status"] = "blocked"
	metadata["upload_error"] = reason
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(metadata, "  ") + "\n")
		file.close()


func _append_text(bytes: PackedByteArray, value: String) -> void:
	bytes.append_array(value.to_utf8_buffer())
