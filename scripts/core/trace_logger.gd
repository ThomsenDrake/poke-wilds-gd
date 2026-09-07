extends RefCounted

const BoundedJsonl := preload("res://scripts/core/bounded_jsonl.gd")
const LOG_DIR := "user://logs"
const LOG_PATH := "%s/agent_trace.jsonl" % LOG_DIR

var _session_start_offset := -1
var _log_path := LOG_PATH
var _cursor_start_offset := -1
var _history_line_count := -1
var _cursor_observed_size := 0
var _cursor_anchor := PackedByteArray()
var _cursor_reset_pending := false


func _init(log_path: String = LOG_PATH) -> void:
	_log_path = log_path


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
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_log_path.get_base_dir()))
	var mode = FileAccess.READ_WRITE if FileAccess.file_exists(_log_path) else FileAccess.WRITE
	var file = FileAccess.open(_log_path, mode)
	if file == null:
		return
	if mode == FileAccess.READ_WRITE:
		file.seek_end()
	if _session_start_offset < 0:
		_session_start_offset = file.get_position()
	if file.get_length() < _cursor_observed_size:
		_cursor_reset_pending = true
	if _cursor_start_offset < 0:
		_cursor_start_offset = file.get_position()
		_cursor_anchor = line.to_utf8_buffer().slice(0, 64)
	file.store_line(line)
	_cursor_observed_size = file.get_position()
	file.close()


# Returns this process's trace slice only. The append-only log intentionally
# survives launches, so feedback bundles join at the byte offset captured by
# the first event from this TraceLogger instance. Oversized sessions retain a
# small prefix, an explicit JSONL gap record, and the newest complete tail.
func session_log_slice(limit_bytes: int = 5 * 1024 * 1024) -> Dictionary:
	var file := FileAccess.open(_log_path, FileAccess.READ)
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
	var prefix := BoundedJsonl.complete_prefix(file.get_buffer(prefix_size))
	var gap := (JSON.stringify({"event": "feedback_trace_truncated",
		"ts_msec": Time.get_ticks_msec(), "source": "TraceLogger",
		"payload": {"omitted_bytes": source_bytes - limit_bytes}}) + "\n").to_utf8_buffer()
	var tail_size := maxi(0, limit_bytes - prefix.size() - gap.size())
	file.seek(maxi(_session_start_offset + prefix.size(), end - tail_size))
	var tail := BoundedJsonl.complete_tail(file.get_buffer(tail_size))
	file.close()
	var bytes := prefix
	bytes.append_array(gap)
	bytes.append_array(tail)
	return {"bytes": bytes, "source_bytes": source_bytes, "truncated": true}


# Editor-legibility mirror for addons/agent_trace: with no debugger attached
# (headless, scenario, and export runs) the guard makes this a strict no-op,
# so print + file behavior stays byte-identical to the pre-hook logger.
func _send_to_debugger(line: String) -> void:
	if not EngineDebugger.is_active():
		return
	EngineDebugger.send_message("agent_trace:event", [line])


# Absolute nonempty-line cursors retain compatibility with raw JSONL readers.
# Only the current session is decoded on the usual path; history is counted once.
func trace_log_line_count() -> int:
	var snapshot := _cursor_snapshot()
	return read_log_lines_since(_log_path).size() if snapshot.is_empty() else int(snapshot["first_line"]) + snapshot["lines"].size()


func trace_log_lines_since(from_line: int) -> PackedStringArray:
	var snapshot := _cursor_snapshot()
	if not snapshot.is_empty() and from_line >= int(snapshot["first_line"]):
		return (snapshot["lines"] as PackedStringArray).slice(from_line - int(snapshot["first_line"]))
	return read_log_lines_since(_log_path, from_line)


static func read_log_lines_since(path: String, from_line: int = 0) -> PackedStringArray:
	if not FileAccess.file_exists(path):
		return PackedStringArray()
	return FileAccess.get_file_as_string(path).split("\n", false).slice(maxi(0, from_line))


func _cursor_snapshot() -> Dictionary:
	var file := FileAccess.open(_log_path, FileAccess.READ)
	if file == null or _cursor_start_offset < 0:
		return {}
	var end := file.get_length()
	var reset := _cursor_reset_pending or end < _cursor_observed_size or end < _cursor_start_offset
	if not reset and not _cursor_anchor.is_empty():
		file.seek(_cursor_start_offset)
		reset = file.get_buffer(_cursor_anchor.size()) != _cursor_anchor
	if reset:
		_cursor_start_offset = 0
		_history_line_count = 0
		_cursor_anchor = PackedByteArray()
		_cursor_reset_pending = false
	_cursor_observed_size = end
	# A historical unterminated line joins the first emitted record; use the exact
	# full-file fallback instead of treating that joined record as a new line.
	if _cursor_start_offset > 0:
		file.seek(_cursor_start_offset - 1)
		if file.get_8() != 10:
			file.close()
			return {}
	if _cursor_anchor.is_empty():
		file.seek(_cursor_start_offset)
		_cursor_anchor = file.get_buffer(mini(64, end - _cursor_start_offset))
	if _history_line_count < 0:
		_history_line_count = _count_nonempty_prefix(file, _cursor_start_offset)
	file.seek(_cursor_start_offset)
	var lines := file.get_buffer(end - _cursor_start_offset).get_string_from_utf8().split("\n", false)
	file.close()
	return {"first_line": _history_line_count, "lines": lines}


static func _count_nonempty_prefix(file: FileAccess, end: int) -> int:
	file.seek(0)
	var count := 0
	var pending := false
	while file.get_position() < end:
		var bytes := file.get_buffer(mini(1024 * 1024, end - file.get_position()))
		if bytes.is_empty(): break
		var start := 0
		while start < bytes.size():
			var newline := bytes.find(10, start) # native byte search; never loop over history bytes in GDScript
			if newline < 0:
				pending = true
				break
			if pending or newline > start: count += 1
			pending = false
			start = newline + 1
	return count + int(pending)
