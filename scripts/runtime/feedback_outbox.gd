extends RefCounted

# Durable ownership for feedback ZIP/private-route/metadata entries. Metadata
# is the final commit marker, so retry never observes a torn set.

const OUTBOX_DIR := "user://feedback_outbox"
const TMP_SUFFIX := ".tmp"
const ROUTE_SUFFIX := ".route"


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
	var route_path := _route_path(report_id)
	if not _rename(staging_path, bundle_path):
		return {"ok": false, "error": "outbox_bundle_commit_failed"}
	if not _atomic_write_json(route_path, _private_route(metadata, build)):
		_preserve(bundle_path, "%s/%s.orphan.zip" % [OUTBOX_DIR, report_id])
		return {"ok": false, "error": "outbox_route_commit_failed"}
	if not _atomic_write_json(metadata_path, metadata):
		_preserve(bundle_path, "%s/%s.orphan.zip" % [OUTBOX_DIR, report_id])
		_remove(route_path)
		return {"ok": false, "error": "outbox_metadata_commit_failed"}
	return {"ok": true, "bundle_path": bundle_path, "metadata_path": metadata_path,
		"route_path": route_path, "metadata": metadata, "build": build}


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
			_remove(_route_path(report_id))
			continue
		var prepared_build := build
		var route_path := _route_path(report_id)
		if FileAccess.file_exists(route_path):
			prepared_build = _read_json(route_path)
			if not _route_matches(prepared_build, parsed):
				_quarantine(report_id, "corrupt")
				continue
		elif not _route_matches(build, parsed):
			# Legacy entries have no private route. Never try or block one under a
			# different tester/cohort; a matching older package can still recover it.
			continue
		result.append({"ok": true, "metadata": parsed, "metadata_path": metadata_path,
			"route_path": route_path, "bundle_path": bundle_path, "build": prepared_build})
	return result


func mark_blocked(prepared: Dictionary, reason: String) -> bool:
	var path := str(prepared.get("metadata_path", ""))
	if path.is_empty():
		return false
	var metadata: Dictionary = prepared.get("metadata", {}).duplicate(true)
	metadata["upload_status"] = "blocked"
	metadata["upload_error"] = reason
	var marked := _atomic_write_json(path, metadata)
	if marked:
		_remove(str(prepared.get("route_path", "")))
	return marked


func remove(prepared: Dictionary) -> void:
	_remove(str(prepared.get("bundle_path", "")))
	_remove(str(prepared.get("metadata_path", "")))
	_remove(str(prepared.get("route_path", "")))


func discard_staging(path: String) -> void:
	_remove(path)


func _atomic_write_json(path: String, value: Dictionary) -> bool:
	var temporary := path + TMP_SUFFIX
	_remove(temporary)
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return false
	var wrote := file.store_string(JSON.stringify(value, "  ") + "\n")
	file.flush()
	var write_error := file.get_error()
	file.close()
	if not wrote or write_error != OK:
		_remove(temporary)
		return false
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
	_remove(_route_path(report_id))


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
		elif filename.ends_with(ROUTE_SUFFIX + TMP_SUFFIX):
			var report_id := filename.trim_suffix(ROUTE_SUFFIX + TMP_SUFFIX)
			if _is_report_id(report_id):
				_remove("%s/%s" % [OUTBOX_DIR, filename])
		elif filename.ends_with(ROUTE_SUFFIX):
			var report_id := filename.trim_suffix(ROUTE_SUFFIX)
			if _is_report_id(report_id) and (not FileAccess.file_exists(_metadata_path(report_id)) \
					or not FileAccess.file_exists(_bundle_path(report_id))):
				_remove(_route_path(report_id))
	for filename in filenames:
		if not filename.ends_with(".zip") or filename.ends_with(".orphan.zip") \
				or filename.ends_with(".corrupt.zip") or filename.ends_with(".incomplete.zip"):
			continue
		var report_id := filename.trim_suffix(".zip")
		if _is_report_id(report_id) and not FileAccess.file_exists(_metadata_path(report_id)):
			_preserve(_bundle_path(report_id), "%s/%s.orphan.zip" % [OUTBOX_DIR, report_id])
			_remove(_route_path(report_id))


func _private_route(metadata: Dictionary, build: Dictionary) -> Dictionary:
	return {"endpoint": str(build.get("endpoint", "")),
		"invite_token": str(build.get("invite_token", "")),
		"tester_id": str(metadata.get("tester_id", "")),
		"channel": str(metadata.get("build", {}).get("channel", ""))}


func _route_matches(route: Dictionary, metadata: Dictionary) -> bool:
	return route.has_all(["endpoint", "invite_token", "tester_id", "channel"]) \
		and route.get("endpoint") is String and route.get("invite_token") is String \
		and route.get("tester_id") is String and route.get("channel") is String \
		and str(route.get("tester_id", "")) == str(metadata.get("tester_id", "")) \
		and str(route.get("channel", "")) == str(metadata.get("build", {}).get("channel", ""))


func _is_report_id(value: String) -> bool:
	var pattern := RegEx.new()
	return pattern.compile("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$") == OK \
		and pattern.search(value) != null


func _bundle_path(report_id: String) -> String:
	return "%s/%s.zip" % [OUTBOX_DIR, report_id]


func _metadata_path(report_id: String) -> String:
	return "%s/%s.json" % [OUTBOX_DIR, report_id]


func _route_path(report_id: String) -> String:
	return "%s/%s%s" % [OUTBOX_DIR, report_id, ROUTE_SUFFIX]


func _rename(source: String, destination: String) -> bool:
	return DirAccess.rename_absolute(ProjectSettings.globalize_path(source),
		ProjectSettings.globalize_path(destination)) == OK


func _preserve(source: String, destination: String) -> void:
	if FileAccess.file_exists(source):
		_rename(source, destination)


func _remove(path: String) -> void:
	if not path.is_empty() and FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
