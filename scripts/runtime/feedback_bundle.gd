extends RefCounted

const Redactor := preload("res://scripts/core/feedback_redactor.gd")

const BUILD_INFO_PATH := "res://generated/playtest_build.json"
const OUTBOX_DIR := "user://feedback_outbox"
const MAX_BUNDLE_BYTES := 16 * 1024 * 1024
const ENGINE_LOG_LIMIT := 2 * 1024 * 1024


func prepare(message: String, capture: Dictionary, runtime: Node) -> Dictionary:
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
		"install_id": _install_id(),
		"build": _public_build(build),
		"runtime": capture["runtime"],
		"game": capture["game"],
		"capture": {"screenshot_available": not screenshot.is_empty(),
			"screen": str(capture.get("screen", "unknown"))},
		"artifacts": _artifact_manifest(artifacts, truncated_paths),
	}
	artifacts["report.json"] = _json_bytes(manifest)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTBOX_DIR))
	var bundle_path := "%s/%s.zip" % [OUTBOX_DIR, report_id]
	var zip_error := _write_zip(bundle_path, artifacts)
	if not zip_error.is_empty():
		return {"ok": false, "error": zip_error}
	var reduction_error := _reduce_to_limit(bundle_path, artifacts, manifest, truncated_paths)
	if not reduction_error.is_empty():
		return {"ok": false, "error": reduction_error, "bundle_path": bundle_path}
	var bundle_bytes := FileAccess.get_file_as_bytes(bundle_path)
	var metadata := {
		"schema_version": 1, "report_id": report_id,
		"message": safe_message, "tester_id": manifest["tester_id"],
		"install_id": manifest["install_id"], "build": manifest["build"],
		"runtime": manifest["runtime"], "game": manifest["game"], "capture": manifest["capture"],
		"bundle_sha256": Redactor.sha256_hex(bundle_bytes), "bundle_bytes": bundle_bytes.size(),
	}
	var metadata_path := "%s/%s.json" % [OUTBOX_DIR, report_id]
	var sidecar := FileAccess.open(metadata_path, FileAccess.WRITE)
	if sidecar == null:
		return {"ok": false, "error": "metadata_write_failed"}
	sidecar.store_string(JSON.stringify(metadata, "  ") + "\n")
	sidecar.close()
	return {"ok": true, "bundle_path": bundle_path, "metadata_path": metadata_path,
		"metadata": metadata, "build": build}


func load_build_info() -> Dictionary:
	if not FileAccess.file_exists(BUILD_INFO_PATH):
		return {"channel": "development", "build_id": "local", "commit_sha": "unknown",
			"endpoint": "", "invite_token": "", "tester_id": "UNASSIGNED"}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(BUILD_INFO_PATH))
	return parsed if parsed is Dictionary else {}


static func engine_log_slice() -> Dictionary:
	var path := "user://logs/godot.log"
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"bytes": PackedByteArray(), "source_bytes": 0, "truncated": false}
	var source_bytes := file.get_length()
	file.seek(maxi(0, source_bytes - ENGINE_LOG_LIMIT))
	var text := Redactor.sanitize_text(file.get_buffer(mini(source_bytes, ENGINE_LOG_LIMIT)).get_string_from_utf8())
	file.close()
	return {"bytes": text.to_utf8_buffer(), "source_bytes": source_bytes,
		"truncated": source_bytes > ENGINE_LOG_LIMIT}


func _write_zip(path: String, artifacts: Dictionary) -> String:
	var packer := ZIPPacker.new()
	if packer.open(path) != OK:
		return "zip_open_failed"
	var paths := artifacts.keys()
	paths.sort()
	for artifact_path in paths:
		if packer.start_file(str(artifact_path)) != OK:
			packer.close()
			return "zip_entry_failed"
		packer.write_file(artifacts[artifact_path])
		packer.close_file()
	packer.close()
	return ""


func _reduce_to_limit(path: String, artifacts: Dictionary, manifest: Dictionary,
		truncated_paths: Dictionary) -> String:
	while FileAccess.get_file_as_bytes(path).size() > MAX_BUNDLE_BYTES:
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


func _reduce_trace_middle(bytes: PackedByteArray, limit: int) -> PackedByteArray:
	var marker := (JSON.stringify({"event": "feedback_trace_truncated", "source": "FeedbackBundle",
		"payload": {"reason": "bundle_size_limit"}}) + "\n").to_utf8_buffer()
	var prefix_size := mini(bytes.size(), maxi(16 * 1024, limit / 4))
	var prefix := _complete_jsonl_prefix(bytes.slice(0, prefix_size))
	var tail_size := maxi(0, limit - prefix.size() - marker.size())
	var tail := _complete_jsonl_tail(bytes.slice(maxi(prefix_size, bytes.size() - tail_size)))
	var result := prefix
	result.append_array(marker)
	result.append_array(tail)
	return result


static func _complete_jsonl_prefix(bytes: PackedByteArray) -> PackedByteArray:
	var last_newline := -1
	for index in bytes.size():
		if bytes[index] == 10:
			last_newline = index
	return bytes.slice(0, last_newline + 1) if last_newline >= 0 else PackedByteArray()


static func _complete_jsonl_tail(bytes: PackedByteArray) -> PackedByteArray:
	var start := 0
	while start < bytes.size() and bytes[start] != 10:
		start += 1
	if start < bytes.size():
		start += 1
	return _complete_jsonl_prefix(bytes.slice(start))


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


func _install_id() -> String:
	const PATH := "user://feedback_install_id.txt"
	if FileAccess.file_exists(PATH):
		return FileAccess.get_file_as_string(PATH).strip_edges()
	var value := Redactor.random_token(16)
	var file := FileAccess.open(PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(value + "\n")
		file.close()
	return value


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
