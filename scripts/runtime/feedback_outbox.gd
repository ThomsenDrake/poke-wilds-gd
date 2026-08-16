extends RefCounted

# Durable ownership for paired feedback ZIP/metadata entries. The metadata
# sidecar is the commit marker: it is renamed into place only after the ZIP is
# complete, so retry never observes a torn pair.

const OUTBOX_DIR := "user://feedback_outbox"
const TMP_SUFFIX := ".tmp"


func staging_bundle_path(report_id: String) -> String:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTBOX_DIR))
	var path := "%s/%s.zip%s" % [OUTBOX_DIR, report_id, TMP_SUFFIX]
	_remove(path)
	return path


func commit(staging_path: String, metadata: Dictionary, build: Dictionary) -> Dictionary:
	var report_id := str(metadata.get("report_id", ""))
	if report_id.is_empty() or not FileAccess.file_exists(staging_path):
		return {"ok": false, "error": "outbox_staging_missing"}
	var bundle_path := _bundle_path(report_id)
	var metadata_path := _metadata_path(report_id)
	if not _rename(staging_path, bundle_path):
		return {"ok": false, "error": "outbox_bundle_commit_failed"}
	if not _atomic_write_json(metadata_path, metadata):
		_preserve(bundle_path, "%s/%s.orphan.zip" % [OUTBOX_DIR, report_id])
		return {"ok": false, "error": "outbox_metadata_commit_failed"}
	return {"ok": true, "bundle_path": bundle_path, "metadata_path": metadata_path,
		"metadata": metadata, "build": build}


func pending(build: Dictionary, only_report_id: String = "") -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var dir := DirAccess.open(OUTBOX_DIR)
	if dir == null:
		return result
	var filenames := dir.get_files()
	_recover_incomplete(filenames)
	for filename in filenames:
		if not filename.ends_with(".json") or filename.ends_with(".corrupt.json"):
			continue
		var report_id := filename.trim_suffix(".json")
		if not _is_report_id(report_id):
			continue
		if not only_report_id.is_empty() and report_id != only_report_id:
			continue
		var metadata_path := _metadata_path(report_id)
		var parsed := _read_json(metadata_path)
		if parsed.is_empty():
			_quarantine(report_id, "corrupt")
			continue
		if str(parsed.get("upload_status", "")) == "blocked":
			continue
		var bundle_path := _bundle_path(report_id)
		if not FileAccess.file_exists(bundle_path):
			_preserve(metadata_path, "%s/%s.orphan.json" % [OUTBOX_DIR, report_id])
			continue
		result.append({"ok": true, "metadata": parsed, "metadata_path": metadata_path,
			"bundle_path": bundle_path, "build": build})
	return result


func mark_blocked(prepared: Dictionary, reason: String) -> bool:
	var path := str(prepared.get("metadata_path", ""))
	if path.is_empty():
		return false
	var metadata: Dictionary = prepared.get("metadata", {}).duplicate(true)
	metadata["upload_status"] = "blocked"
	metadata["upload_error"] = reason
	return _atomic_write_json(path, metadata)


func remove(prepared: Dictionary) -> void:
	_remove(str(prepared.get("bundle_path", "")))
	_remove(str(prepared.get("metadata_path", "")))


func discard_staging(path: String) -> void:
	_remove(path)


func _atomic_write_json(path: String, value: Dictionary) -> bool:
	var temporary := path + TMP_SUFFIX
	_remove(temporary)
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(value, "  ") + "\n")
	file.flush()
	file.close()
	if not _rename(temporary, path):
		_remove(temporary)
		return false
	return true


func _read_json(path: String) -> Dictionary:
	var parser := JSON.new()
	if parser.parse(FileAccess.get_file_as_string(path)) != OK or not parser.data is Dictionary:
		return {}
	return parser.data


func _quarantine(report_id: String, suffix: String) -> void:
	_preserve(_metadata_path(report_id), "%s/%s.%s.json" % [OUTBOX_DIR, report_id, suffix])
	_preserve(_bundle_path(report_id), "%s/%s.%s.zip" % [OUTBOX_DIR, report_id, suffix])


func _recover_incomplete(filenames: PackedStringArray) -> void:
	for filename in filenames:
		if filename.ends_with(".zip.tmp"):
			var report_id := filename.trim_suffix(".zip.tmp")
			if _is_report_id(report_id):
				_preserve("%s/%s" % [OUTBOX_DIR, filename],
					"%s/%s.incomplete.zip" % [OUTBOX_DIR, report_id])
		elif filename.ends_with(".json.tmp"):
			var report_id := filename.trim_suffix(".json.tmp")
			if _is_report_id(report_id):
				_preserve("%s/%s" % [OUTBOX_DIR, filename],
					"%s/%s.incomplete.json" % [OUTBOX_DIR, report_id])
	for filename in filenames:
		if not filename.ends_with(".zip") or filename.ends_with(".orphan.zip") \
				or filename.ends_with(".corrupt.zip") or filename.ends_with(".incomplete.zip"):
			continue
		var report_id := filename.trim_suffix(".zip")
		if _is_report_id(report_id) and not FileAccess.file_exists(_metadata_path(report_id)):
			_preserve(_bundle_path(report_id), "%s/%s.orphan.zip" % [OUTBOX_DIR, report_id])


func _is_report_id(value: String) -> bool:
	var pattern := RegEx.new()
	return pattern.compile("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$") == OK \
		and pattern.search(value) != null


func _bundle_path(report_id: String) -> String:
	return "%s/%s.zip" % [OUTBOX_DIR, report_id]


func _metadata_path(report_id: String) -> String:
	return "%s/%s.json" % [OUTBOX_DIR, report_id]


func _rename(source: String, destination: String) -> bool:
	return DirAccess.rename_absolute(ProjectSettings.globalize_path(source),
		ProjectSettings.globalize_path(destination)) == OK


func _preserve(source: String, destination: String) -> void:
	if FileAccess.file_exists(source):
		_rename(source, destination)


func _remove(path: String) -> void:
	if not path.is_empty() and FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
