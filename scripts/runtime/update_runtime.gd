extends Node

const UpdateManifest := preload("res://scripts/domain/update_manifest.gd")
const UpdateIdentity := preload("res://scripts/runtime/update_identity.gd")
const UpdateApplier := preload("res://scripts/runtime/update_applier.gd")
const FeedbackBundle := preload("res://scripts/runtime/feedback_bundle.gd")

const UPDATES_DIR := "user://updates"
const PENDING_PATH := "user://updates/pending.json"
const APPLIED_PATH := "user://updates/applied.json"
const DOWNLOAD_TIMEOUT := 600.0

signal availability_changed(available: bool)

var _http: HTTPRequest
var _bundle := FeedbackBundle.new()
var _transport: Callable
var _applier: Callable
var _relauncher: Callable
var _force_check := false
var _latest: Dictionary = {}
var _available := false
var _busy := false


func _ready() -> void:
	name = "UpdateRuntime"
	process_mode = Node.PROCESS_MODE_ALWAYS
	_http = HTTPRequest.new()
	_http.process_mode = Node.PROCESS_MODE_ALWAYS
	_http.timeout = DOWNLOAD_TIMEOUT
	_http.max_redirects = 0
	add_child(_http)
	UpdateApplier.cleanup_old(UpdateApplier.install_path())


func persist_identity() -> void:
	UpdateIdentity.persist_from(_bundle.load_build_info())


func should_check() -> bool:
	if FileAccess.file_exists("res://.godot-smoke/scenario.json"):
		return false
	return _force_check or not OS.has_feature("editor")


func is_available() -> bool:
	return _available


func latest_build() -> Dictionary:
	return _latest.duplicate(true)


func update_channel() -> String:
	return UpdateManifest.DEFAULT_CHANNEL


func is_newer_build(latest: Dictionary, current: Dictionary, applied: Dictionary = {}) -> bool:
	return UpdateManifest.is_newer(latest, current, applied)


func is_offerable_build(latest: Dictionary, current: Dictionary, applied: Dictionary,
		os_name: String) -> bool:
	return UpdateManifest.is_offerable(latest, current, applied, os_name)


func start_check() -> void:
	if not should_check() or _busy:
		return
	_run_check()


func _run_check() -> void:
	_busy = true
	_trace("update_check_started", {"channel": update_channel()})
	var latest := await _fetch_latest()
	_busy = false
	_latest = latest
	var os_name := OS.get_name()
	_available = UpdateManifest.is_offerable(latest, _current(), _applied(), os_name)
	if _available:
		_trace("update_available", {"build_id": str(latest.get("build_id", "")),
			"os": UpdateManifest.os_key(os_name)})
	availability_changed.emit(_available)


func apply_available() -> Dictionary:
	if _busy:
		return {"ok": false, "error": "busy"}
	var os_name := OS.get_name()
	var key := UpdateManifest.os_key(os_name)
	var build := UpdateManifest.build_for_os(_latest, os_name)
	if not _available or build.is_empty():
		return {"ok": false, "error": "not_available"}
	_busy = true
	var downloaded := await _download_artifact(build)
	if not bool(downloaded.get("ok", false)):
		_busy = false
		_trace("update_apply_refused", {"reason": str(downloaded.get("error", "download_failed"))})
		return downloaded
	_trace("update_verified", {"sha256": str(build.get("sha256", "")), "bytes": int(build.get("bytes", 0))})
	_trace("update_apply_started", {"os": key, "build_id": str(_latest.get("build_id", ""))})
	var artifact := ProjectSettings.globalize_path(str(downloaded.get("path", "")))
	var applied := _invoke_apply(os_name, artifact, UpdateApplier.install_path())
	if not bool(applied.get("ok", false)):
		_busy = false
		_trace("update_apply_refused", {"reason": str(applied.get("error", "apply_failed"))})
		return applied
	_write_json(APPLIED_PATH, {"build_id": _latest.get("build_id", ""),
		"published_at": _latest.get("published_at", "")})
	_clear_staging()
	_trace("update_relaunching", {"build_id": str(_latest.get("build_id", ""))})
	_relaunch(applied)
	_busy = false
	return {"ok": true}


func _fetch_latest() -> Dictionary:
	if _transport.is_valid():
		var transported = await _transport.call("latest")
		return UpdateManifest.parse(transported)
	var endpoint := _update_endpoint()
	if endpoint.is_empty():
		return {}
	var err := _http.request(endpoint + "/v1/updates/latest?channel=" + update_channel(),
		PackedStringArray(["Accept: application/json"]), HTTPClient.METHOD_GET)
	if err != OK:
		return {}
	var response: Array = await _http.request_completed
	if int(response[0]) != HTTPRequest.RESULT_SUCCESS or int(response[1]) != 200:
		return {}
	return UpdateManifest.parse(JSON.parse_string((response[3] as PackedByteArray).get_string_from_utf8()))


func _download_artifact(build: Dictionary) -> Dictionary:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(UPDATES_DIR))
	var dest := UPDATES_DIR + "/" + str(build.get("filename", "artifact"))
	if _transport.is_valid():
		var transported = await _transport.call("download", build, dest)
		if not transported is Dictionary:
			return {"ok": false, "error": "download_failed"}
		if not bool(transported.get("ok", false)):
			return transported
		if bool(transported.get("verified", false)):
			_write_json(PENDING_PATH, {"path": dest, "sha256": build.get("sha256", ""),
				"build_id": _latest.get("build_id", "")})
			return {"ok": true, "path": dest}
	else:
		_http.download_file = dest
		var err := _http.request(str(build.get("url", "")), PackedStringArray(), HTTPClient.METHOD_GET)
		if err != OK:
			_http.download_file = ""
			return {"ok": false, "error": "request_start_failed"}
		var response: Array = await _http.request_completed
		_http.download_file = ""
		if int(response[0]) != HTTPRequest.RESULT_SUCCESS or int(response[1]) != 200:
			return {"ok": false, "error": "download_failed"}
	if not FileAccess.file_exists(dest):
		return {"ok": false, "error": "pending_missing"}
	if FileAccess.get_sha256(dest) != str(build.get("sha256", "")):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(dest))
		return {"ok": false, "error": "hash_mismatch"}
	_write_json(PENDING_PATH, {"path": dest, "sha256": build.get("sha256", ""),
		"build_id": _latest.get("build_id", "")})
	return {"ok": true, "path": dest}


func _invoke_apply(os_name: String, artifact: String, target: String) -> Dictionary:
	if _applier.is_valid():
		var result = _applier.call(os_name, artifact, target)
		return result if result is Dictionary else {"ok": false, "error": "apply_failed"}
	return UpdateApplier.apply(os_name, artifact, target)


func _relaunch(applied: Dictionary = {}) -> void:
	if _relauncher.is_valid():
		_relauncher.call()
		return
	if UpdateApplier.launch_deferred(applied):
		get_tree().quit()
		return
	OS.set_restart_on_exit(true)
	get_tree().quit()


func _clear_staging() -> void:
	var abs_dir := ProjectSettings.globalize_path(UPDATES_DIR)
	var dir := DirAccess.open(abs_dir)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if name != "." and name != ".." and name != "applied.json":
			DirAccess.remove_absolute(abs_dir.path_join(name))
		name = dir.get_next()


func _update_endpoint() -> String:
	var raw := str(_bundle.load_build_info().get("endpoint", "")).strip_edges().trim_suffix("/")
	if not raw.to_lower().begins_with("https://") or raw.contains("@") or raw.contains("?") \
			or raw.contains("#") or raw.contains("\\"):
		return ""
	return raw


func _current() -> Dictionary:
	return _bundle.load_build_info()


func _applied() -> Dictionary:
	if not FileAccess.file_exists(APPLIED_PATH):
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(APPLIED_PATH))
	return parsed if parsed is Dictionary else {}


func _write_json(path: String, payload: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(payload) + "\n")
	file.close()


func _trace(event_name: String, payload: Dictionary) -> void:
	var runtime := get_node_or_null("/root/GameRuntime")
	if runtime != null:
		runtime.emit_trace(event_name, "UpdateRuntime", payload)


func smoke_set_transport(transport: Callable) -> void:
	if OS.has_feature("editor"):
		_transport = transport


func smoke_set_applier(applier: Callable) -> void:
	if OS.has_feature("editor"):
		_applier = applier


func smoke_set_relauncher(relauncher: Callable) -> void:
	if OS.has_feature("editor"):
		_relauncher = relauncher


func smoke_force_check(enabled: bool) -> void:
	if OS.has_feature("editor"):
		_force_check = enabled


func smoke_set_latest(latest: Dictionary) -> void:
	if not OS.has_feature("editor"):
		return
	_latest = UpdateManifest.parse(latest)
	_available = not _latest.is_empty() and not UpdateManifest.build_for_os(_latest, OS.get_name()).is_empty()
	availability_changed.emit(_available)
