extends RefCounted

const LOG_DIR := "user://logs"
const LOG_PATH := "%s/agent_trace.jsonl" % LOG_DIR

var _session_start_offset := -1


func emit_event(event_name: String, source: String, payload: Dictionary = {}) -> void:
	var record = {
		"event": event_name,
		"ts_msec": Time.get_ticks_msec(),
		"source": source,
		"payload": payload
	}
	var line = JSON.stringify(record)
	print(line)
	_append_line(line)
	_send_to_debugger(line)


func warning(source: String, message: String, payload: Dictionary = {}) -> void:
	var merged = payload.duplicate(true)
	merged["message"] = message
	emit_event("warning", source, merged)


func _append_line(line: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(LOG_DIR))
	var mode = FileAccess.READ_WRITE if FileAccess.file_exists(LOG_PATH) else FileAccess.WRITE
	var file = FileAccess.open(LOG_PATH, mode)
	if file == null:
		return
	if mode == FileAccess.READ_WRITE:
		file.seek_end()
	if _session_start_offset < 0:
		_session_start_offset = file.get_position()
	file.store_line(line)
	file.close()


# Returns this process's trace slice only. The append-only log intentionally
# survives launches, so feedback bundles join at the byte offset captured by
# the first event from this TraceLogger instance. Oversized sessions retain a
# small prefix, an explicit JSONL gap record, and the newest complete tail.
func session_log_slice(limit_bytes: int = 5 * 1024 * 1024) -> Dictionary:
	var file := FileAccess.open(LOG_PATH, FileAccess.READ)
	if file == null or _session_start_offset < 0:
		return {"bytes": PackedByteArray(), "source_bytes": 0, "truncated": false}
	var end := file.get_length()
	var source_bytes := maxi(0, end - _session_start_offset)
	file.seek(_session_start_offset)
	if source_bytes <= limit_bytes:
		var complete := file.get_buffer(source_bytes)
		file.close()
		return {"bytes": complete, "source_bytes": source_bytes, "truncated": false}
	var prefix_size := mini(256 * 1024, limit_bytes / 4)
	var prefix := _complete_jsonl_prefix(file.get_buffer(prefix_size))
	var gap := (JSON.stringify({"event": "feedback_trace_truncated", "source": "TraceLogger", "payload": {
		"omitted_bytes": source_bytes - limit_bytes}}) + "\n").to_utf8_buffer()
	var tail_size := maxi(0, limit_bytes - prefix.size() - gap.size())
	file.seek(maxi(_session_start_offset + prefix.size(), end - tail_size))
	var tail := _complete_jsonl_tail(file.get_buffer(tail_size))
	file.close()
	var bytes := prefix
	bytes.append_array(gap)
	bytes.append_array(tail)
	return {"bytes": bytes, "source_bytes": source_bytes, "truncated": true}


func _complete_jsonl_prefix(bytes: PackedByteArray) -> PackedByteArray:
	var last_newline := -1
	for index in bytes.size():
		if bytes[index] == 10:
			last_newline = index
	return bytes.slice(0, last_newline + 1) if last_newline >= 0 else PackedByteArray()


func _complete_jsonl_tail(bytes: PackedByteArray) -> PackedByteArray:
	var start := 0
	while start < bytes.size() and bytes[start] != 10:
		start += 1
	if start < bytes.size():
		start += 1
	return _complete_jsonl_prefix(bytes.slice(start))


# Editor-legibility mirror for addons/agent_trace: with no debugger attached
# (headless, scenario, and export runs) the guard makes this a strict no-op,
# so print + file behavior stays byte-identical to the pre-hook logger.
func _send_to_debugger(line: String) -> void:
	if not EngineDebugger.is_active():
		return
	EngineDebugger.send_message("agent_trace:event", [line])
