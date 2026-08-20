extends RefCounted

const ENTRY_UPDATE := "UPDATE"
const ENTRY_CONTINUE := "CONTINUE"
const ENTRY_NEW_GAME := "NEW GAME"
const CONFIRM_TEXT := "Download and install the latest build? Your save stays on this computer."
const FAIL_TEXT := "Update failed. Your current game is unchanged."

var _available := false
var _awaiting := false
var _working := false
var _host: Control
var _runtime: Node
var _box: Node


func setup(host: Control, runtime: Node, box: Node) -> void:
	_host = host
	_runtime = runtime
	_box = box
	if runtime != null and runtime.has_signal("availability_changed"):
		runtime.availability_changed.connect(_on_availability)


func persist_and_maybe_check() -> void:
	if _runtime == null:
		return
	if not _runtime.persist_identity():
		return
	if _runtime.should_check():
		_runtime.start_check()


func labels(has_save: bool) -> Array:
	var rows: Array = []
	if _available:
		rows.append(ENTRY_UPDATE)
	if has_save:
		rows.append(ENTRY_CONTINUE)
	rows.append(ENTRY_NEW_GAME)
	return rows


func is_awaiting() -> bool:
	return _awaiting or _working


func try_activate(text: String) -> bool:
	if text != ENTRY_UPDATE:
		return false
	if _box == null or not _box.has_method("show_confirm"):
		return true
	_awaiting = true
	_box.call("show_confirm", CONFIRM_TEXT)
	return true


func on_confirmed() -> bool:
	if not _awaiting:
		return false
	_awaiting = false
	_begin_apply()
	return true


func on_cancelled() -> bool:
	if not _awaiting:
		return false
	_awaiting = false
	return true


func smoke_set_available(available: bool) -> void:
	_available = available


func _on_availability(available: bool) -> void:
	_available = available
	if _host != null and _host.has_method("refresh_entries"):
		_host.call("refresh_entries")


func _begin_apply() -> void:
	if _runtime == null or _working:
		return
	_working = true
	if _box != null and _box.has_method("show_message"):
		_box.call("show_message", "Downloading update…", 0.0)
	var result: Dictionary = await _runtime.apply_available()
	_working = false
	if bool(result.get("ok", false)):
		if _box != null and _box.has_method("hide_message"):
			_box.call("hide_message")
	elif _box != null and _box.has_method("show_message"):
		_box.call("show_message", FAIL_TEXT, 2.0)
