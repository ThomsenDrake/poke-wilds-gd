extends RefCounted

const LOG_DIR := "user://logs"
const LOG_PATH := "%s/agent_trace.jsonl" % LOG_DIR


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
	file.store_line(line)
	file.close()
