extends RefCounted

const Redactor := preload("res://scripts/core/feedback_redactor.gd")
const BoundedJsonl := preload("res://scripts/core/bounded_jsonl.gd")
const UpdateIdentity := preload("res://scripts/runtime/update_identity.gd")

const BUILD_INFO_PATH := "res://generated/playtest_build.json"
const INSTALL_ID_PATH := "user://feedback_install_id.txt"
const INSTALL_ID_TMP_SUFFIX := ".tmp"
const MAX_BUNDLE_BYTES := 16 * 1024 * 1024
const MAX_UNCOMPRESSED_BYTES := 24 * 1024 * 1024
const ENGINE_LOG_LIMIT := 2 * 1024 * 1024

var _install_id_path := INSTALL_ID_PATH
var _build_info_override: Dictionary = {}


func build(message: String, capture: Dictionary, bundle_path: String) -> Dictionary:
	var report_id := str(capture.get("report_id", ""))
	if report_id.is_empty():
		return {"ok": false, "error": "missing_report_id"}
	var safe_message := Redactor.sanitize_message(message)
	if safe_message.is_empty():
		return {"ok": false, "error": "invalid_message"}
	for field in ["save", "runtime", "game", "trace_slice", "engine_slice"]:
		if not capture.has(field):
			return {"ok": false, "error": "missing_capture_%s" % field}
	var build := load_build_info()
	var install := _install_id()
	if not bool(install.get("ok", false)):
		return {"ok": false, "error": install.get("error", "install_id_write_failed")}
	var trace_slice: Dictionary = capture["trace_slice"]
	var engine_slice: Dictionary = capture["engine_slice"]
	var artifacts: Dictionary = {}
	artifacts["trace.jsonl"] = trace_slice.get("bytes", PackedByteArray())
	artifacts["engine.log"] = engine_slice.get("bytes", PackedByteArray())
	artifacts["save.json"] = _json_bytes(capture["save"])
	artifacts["ui-tree.json"] = _json_bytes(capture.get("ui_tree", {}))
	var screenshot: PackedByteArray = capture.get("screenshot", PackedByteArray())
	if not screenshot.is_empty():
		artifacts["screenshot.png"] = screenshot
	artifacts["README.txt"] = ("Playtest feedback bundle v1. Start with report.json, then correlate " +
		"trace.jsonl, ui-tree.json, screenshot.png, save.json, and engine.log.\n").to_utf8_buffer()
	var truncated_paths := {"trace.jsonl": bool(trace_slice.get("truncated", false)),
		"engine.log": bool(engine_slice.get("truncated", false))}
	var manifest := {
		"schema_version": 1,
		"report_id": report_id,
		"created_at_utc": _canonical_utc_timestamp(),
		"message": safe_message,
		"tester_id": str(build.get("tester_id", "UNASSIGNED")),
		"install_id": install["value"],
		"build": _public_build(build),
		"runtime": capture["runtime"],
		"game": capture["game"],
		"capture": {"screenshot_available": not screenshot.is_empty(),
			"screen": str(capture.get("screen", "unknown"))},
		"artifacts": _artifact_manifest(artifacts, truncated_paths),
	}
	artifacts["report.json"] = _json_bytes(manifest)
	var zip_error := _write_zip(bundle_path, artifacts)
	if not zip_error.is_empty():
		return {"ok": false, "error": zip_error}
	var reduction_error := _reduce_to_limit(bundle_path, artifacts, manifest, truncated_paths)
	if not reduction_error.is_empty():
		return {"ok": false, "error": reduction_error}
	var bundle_bytes := FileAccess.get_file_as_bytes(bundle_path)
	var metadata := {
		"schema_version": 1, "report_id": report_id,
		"message": safe_message, "tester_id": manifest["tester_id"],
		"install_id": manifest["install_id"], "build": manifest["build"],
		"runtime": manifest["runtime"], "game": manifest["game"], "capture": manifest["capture"],
		"bundle_sha256": Redactor.sha256_hex(bundle_bytes), "bundle_bytes": bundle_bytes.size(),
	}
	return {"ok": true, "metadata": metadata, "build": build}


func load_embedded_build_info() -> Dictionary:
	if OS.has_feature("editor") and not _build_info_override.is_empty():
		return _build_info_override.duplicate(true)
	var embedded := {"channel": "development", "build_id": "local", "commit_sha": "unknown",
		"endpoint": "", "invite_token": "", "tester_id": "UNASSIGNED"}
	if FileAccess.file_exists(BUILD_INFO_PATH):
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(BUILD_INFO_PATH))
		if parsed is Dictionary:
			embedded = parsed
	return embedded


func load_build_info() -> Dictionary:
	if OS.has_feature("editor") and not _build_info_override.is_empty():
		return _build_info_override.duplicate(true)
	return UpdateIdentity.merge(load_embedded_build_info())


static func engine_log_slice() -> Dictionary:
	return _engine_log_slice_at("user://logs/godot.log", ENGINE_LOG_LIMIT)


static func _engine_log_slice_at(path: String, limit_bytes: int) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"bytes": PackedByteArray(), "source_bytes": 0, "truncated": false}
	var source_bytes := file.get_length()
	var start := maxi(0, source_bytes - limit_bytes)
	file.seek(maxi(0, start - 1))
	var bytes := file.get_buffer(source_bytes if start == 0 else mini(source_bytes, limit_bytes + 1))
	file.close()
	if start > 0:
		var first_newline := 0
		while first_newline < bytes.size() and bytes[first_newline] != 10:
			first_newline += 1
		bytes = bytes.slice(first_newline + 1) if first_newline < bytes.size() else PackedByteArray()
	var text := Redactor.sanitize_text(bytes.get_string_from_utf8())
	return {"bytes": text.to_utf8_buffer(), "source_bytes": source_bytes,
		"truncated": source_bytes > limit_bytes}


func _write_zip(path: String, artifacts: Dictionary) -> String:
	var packer := ZIPPacker.new()
	if packer.open(path) != OK:
		return "zip_open_failed"
	var paths := artifacts.keys()
	paths.sort()
	for artifact_path in paths:
		if packer.start_file(str(artifact_path)) != OK:
			return _close_zip_after_error(packer, "zip_entry_failed")
		var write_error := packer.write_file(artifacts[artifact_path])
		var entry_close_error := packer.close_file()
		if write_error != OK:
			var reason := "zip_write_failed"
			if entry_close_error != OK:
				reason = "zip_write_and_entry_close_failed"
			return _close_zip_after_error(packer, reason)
		if entry_close_error != OK:
			return _close_zip_after_error(packer, "zip_entry_close_failed")
	if packer.close() != OK:
		return "zip_close_failed"
	return ""


func _close_zip_after_error(packer: ZIPPacker, reason: String) -> String:
	return reason if packer.close() == OK else reason + "_and_zip_close_failed"


func _reduce_to_limit(path: String, artifacts: Dictionary, manifest: Dictionary,
		truncated_paths: Dictionary) -> String:
	while FileAccess.get_file_as_bytes(path).size() > MAX_BUNDLE_BYTES \
			or _uncompressed_size(artifacts) > MAX_UNCOMPRESSED_BYTES:
		var engine: PackedByteArray = artifacts["engine.log"]
		if not engine.is_empty():
			# The log is already newest-tail ordered, so removing from its front
			# discards the oldest diagnostics first.
			artifacts["engine.log"] = engine.slice(mini(engine.size(), maxi(64 * 1024, engine.size() / 2)))
			truncated_paths["engine.log"] = true
		else:
			var trace: PackedByteArray = artifacts["trace.jsonl"]
			if trace.size() <= 64 * 1024:
				return "bundle_too_large"
			artifacts["trace.jsonl"] = _reduce_trace_middle(trace, maxi(64 * 1024, trace.size() / 2))
			truncated_paths["trace.jsonl"] = true
		manifest["artifacts"] = _artifact_manifest(artifacts, truncated_paths)
		artifacts["report.json"] = _json_bytes(manifest)
		var error := _write_zip(path, artifacts)
		if not error.is_empty():
			return error
	return ""


func _uncompressed_size(artifacts: Dictionary) -> int:
	var total := 0
	for value in artifacts.values():
		var bytes: PackedByteArray = value
		total += bytes.size()
	return total


func _reduce_trace_middle(bytes: PackedByteArray, limit: int) -> PackedByteArray:
	var marker := (JSON.stringify({"event": "feedback_trace_truncated",
		"ts_msec": Time.get_ticks_msec(), "source": "FeedbackBundle",
		"payload": {"reason": "bundle_size_limit"}}) + "\n").to_utf8_buffer()
	var prefix_size := mini(bytes.size(), maxi(16 * 1024, limit / 4))
	var prefix := BoundedJsonl.complete_prefix(bytes.slice(0, prefix_size))
	var tail_size := maxi(0, limit - prefix.size() - marker.size())
	return BoundedJsonl.join(prefix, marker,
		bytes.slice(maxi(prefix_size, bytes.size() - tail_size)))


func _artifact_manifest(artifacts: Dictionary, truncated_paths: Dictionary) -> Array:
	var result: Array = []
	var paths := artifacts.keys()
	paths.sort()
	for path in paths:
		if path == "report.json":
			continue
		var bytes: PackedByteArray = artifacts[path]
		result.append({"path": path, "bytes": bytes.size(),
			"sha256": Redactor.sha256_hex(bytes), "truncated": bool(truncated_paths.get(path, false))})
	return result


func _install_id() -> Dictionary:
	if FileAccess.file_exists(_install_id_path):
		var stored := FileAccess.get_file_as_string(_install_id_path).strip_edges()
		if _is_install_id(stored):
			return {"ok": true, "value": stored}
	var value := Redactor.random_token(16)
	var temporary := _install_id_path + INSTALL_ID_TMP_SUFFIX
	if FileAccess.file_exists(temporary):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(temporary))
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return {"ok": false, "error": "install_id_write_failed"}
	var wrote := file.store_string(value + "\n")
	file.flush()
	var write_error := file.get_error()
	file.close()
	if not wrote or write_error != OK:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(temporary))
		return {"ok": false, "error": "install_id_write_failed"}
	var rename_error := DirAccess.rename_absolute(ProjectSettings.globalize_path(temporary),
		ProjectSettings.globalize_path(_install_id_path))
	if rename_error != OK:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(temporary))
		return {"ok": false, "error": "install_id_replace_failed"}
	return {"ok": true, "value": value}


func _is_install_id(value: String) -> bool:
	var pattern := RegEx.new()
	return pattern.compile("^[0-9a-f]{32}$") == OK and pattern.search(value) != null


func set_install_id_path_for_smoke(path: String) -> void:
	if OS.has_feature("editor"):
		_install_id_path = INSTALL_ID_PATH if path.is_empty() else path


func set_build_info_for_smoke(build: Dictionary) -> void:
	if OS.has_feature("editor"):
		_build_info_override = build.duplicate(true)


static func _canonical_utc_timestamp() -> String:
	var timestamp := Time.get_datetime_string_from_system(true, true).strip_edges().replace(" ", "T")
	while timestamp.ends_with("Z"):
		timestamp = timestamp.left(timestamp.length() - 1)
	return timestamp + "Z"


func _public_build(build: Dictionary) -> Dictionary:
	return {"version": str(build.get("version", "0.0.0")),
		"commit_sha": str(build.get("commit_sha", "unknown")),
		"build_id": str(build.get("build_id", "local")), "channel": str(build.get("channel", "development"))}


func _json_bytes(value: Variant) -> PackedByteArray:
	return (JSON.stringify(value, "  ") + "\n").to_utf8_buffer()
