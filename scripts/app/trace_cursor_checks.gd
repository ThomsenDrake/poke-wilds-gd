extends RefCounted

const TraceLogger := preload("res://scripts/core/trace_logger.gd")
const FIXTURE_PATH := "user://trace-cursor-fixture.jsonl"
var _failures: Array[String] = []


func run() -> Array[String]:
	# Cross the 1 MiB history-scan boundary, including empty lines, CR and UTF-8.
	var prior := (JSON.stringify({"event": "prior", "payload": "é"}) + "\n\n").repeat(40000) + "\r\n"
	_write(prior)
	var logger := TraceLogger.new(FIXTURE_PATH)
	_check(logger.trace_log_line_count() == prior.split("\n", false).size(), "pre-session cursor fallback changed line numbering")
	logger.emit_event("trace_cursor_first", "TraceCursorChecks")
	var cursor := logger.trace_log_line_count()
	_check(cursor == prior.split("\n", false).size() + 1, "session cursor is not an absolute nonempty-line count")
	logger.emit_event("trace_cursor_append", "TraceCursorChecks")
	var appended := logger.trace_log_lines_since(cursor)
	_check(appended.size() == 1 and JSON.parse_string(appended[0]).get("event") == "trace_cursor_append",
		"session append was lost or historical events leaked into a cursor suffix")
	_check(logger.trace_log_lines_since(cursor - 3) == _raw_lines().slice(cursor - 3),
		"before-session cursor fallback did not preserve raw-reader compatibility")
	# Exact oracle reads must never use feedback's separately capped trace slice.
	var large_line := JSON.stringify({"event": "large_fixture", "payload": "x".repeat(2048)}) + "\n"
	_append(large_line.repeat(3000))
	_check(bool(logger.session_log_slice(128).get("truncated", false)), "bounded feedback fixture did not truncate")
	_check(logger.trace_log_lines_since(cursor).size() == 3001 and logger.trace_log_line_count() == cursor + 3001,
		"oracle trace read capped or dropped a large current session")
	# The same logger notices truncation before appending, even before a cursor read.
	_write("")
	logger.emit_event("trace_cursor_reset", "TraceCursorChecks")
	_check(logger.trace_log_line_count() == 1 and logger.trace_log_lines_since(0) == _raw_lines(),
		"truncated log retained stale historical offsets")
	_check(logger.trace_log_lines_since(cursor).is_empty(), "old absolute cursor was silently reinterpreted after reset")
	# A replacement can grow past the previous end; the session anchor detects it.
	_write(prior)
	_check(logger.trace_log_line_count() == _raw_lines().size() and logger.trace_log_lines_since(0) == _raw_lines(),
		"larger replaced log retained a stale session anchor")
	_write("unterminated prior text")
	var joined := TraceLogger.new(FIXTURE_PATH)
	joined.emit_event("trace_cursor_joined", "TraceCursorChecks")
	_check(joined.trace_log_line_count() == 1 and joined.trace_log_lines_since(0) == _raw_lines(),
		"unterminated history was incorrectly counted as a separate line")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(FIXTURE_PATH))
	return _failures


func _write(text: String) -> void:
	var file := FileAccess.open(FIXTURE_PATH, FileAccess.WRITE)
	_check(file != null, "trace cursor fixture could not be opened")
	if file != null:
		_check(file.store_string(text), "trace cursor fixture could not be written")
		file.close()


func _append(text: String) -> void:
	var file := FileAccess.open(FIXTURE_PATH, FileAccess.READ_WRITE)
	_check(file != null, "trace cursor fixture could not be appended")
	if file != null:
		file.seek_end()
		_check(file.store_string(text), "trace cursor fixture append failed")
		file.close()


func _raw_lines() -> PackedStringArray:
	return FileAccess.get_file_as_string(FIXTURE_PATH).split("\n", false)


func _check(ok: bool, message: String) -> void:
	if not ok: _failures.append(message)
