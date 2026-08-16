extends Node

const SmokeTap := preload("res://scripts/app/smoke_tap.gd")

# Release-feedback journey: real F input across player-facing screens, text
# focus suppression, pause restoration, and a fully parsed private ZIP through
# the reporter's transport seam. No network or GitHub issue is touched.

var _ctx: Dictionary
var _failures: Array[String] = []
var _transport_checks := false
var _prepared_path := ""
var _transport_calls := 0
const DIALOG_CAPTURE_PATH := "user://feedback-dialog.png"


func run(ctx: Dictionary) -> void:
	_ctx = ctx
	process_mode = Node.PROCESS_MODE_ALWAYS
	await _text_focus_guard()
	await _screen_capture("title", func() -> void: _ctx.title_screen.show_title(), func() -> void: _ctx.title_screen.visible = false)
	await _screen_capture("menu", func() -> void: _ctx.start_menu.show_menu(), func() -> void: _ctx.start_menu.hide_menu())
	await _screen_capture("battle", func() -> void: _ctx.battle_view.visible = true, func() -> void: _ctx.battle_view.visible = false)
	await _submit_overworld()
	if _failures.is_empty():
		_ctx.runtime.emit_trace("feedback_flow_passed", "FeedbackFlowScenario", {
			"screens": ["title", "menu", "battle", "overworld"], "bundle_verified": _transport_checks,
			"dialog_capture": ProjectSettings.globalize_path(DIALOG_CAPTURE_PATH)})
	else:
		_ctx.runtime.emit_trace("feedback_flow_failed", "FeedbackFlowScenario", {"failures": _failures})
		push_error("Feedback flow failed: %s" % "; ".join(_failures))


func _text_focus_guard() -> void:
	var entry := LineEdit.new()
	_ctx.feedback_controller.get_parent().add_child(entry)
	entry.grab_focus()
	await get_tree().process_frame
	await _press("feedback_report")
	_check(not _dialog().visible, "F opened feedback while another text field had focus")
	entry.queue_free()
	await get_tree().process_frame


func _screen_capture(screen: String, open: Callable, close: Callable) -> void:
	open.call()
	await get_tree().process_frame
	await _press("feedback_report")
	_check(_dialog().visible, "F did not open feedback from %s" % screen)
	_check(get_tree().paused, "feedback did not pause from %s" % screen)
	_check(str(_controller().smoke_state().get("capture_screen", "")) == screen, "capture mislabeled %s" % screen)
	await _key(Key.KEY_ESCAPE)
	_check(not get_tree().paused and not _dialog().visible, "cancel did not restore %s" % screen)
	close.call()
	await get_tree().process_frame


func _submit_overworld() -> void:
	_controller().smoke_set_transport(Callable(self, "_offline_transport"))
	await _press("feedback_report")
	_check(_dialog().visible, "F did not open feedback from overworld")
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		var dialog_image := get_viewport().get_texture().get_image()
		if dialog_image != null and not dialog_image.is_empty():
			dialog_image.save_png(DIALOG_CAPTURE_PATH)
	var report_id := str(_controller().smoke_state().get("report_id", ""))
	_dialog().smoke_set_message("a".repeat(1001))
	_check(_dialog().smoke_message().length() == 1000, "report field did not enforce the 1000-character cap")
	_dialog().smoke_set_message("f", 1)
	await _key(Key.KEY_ENTER, true)
	_check(_dialog().smoke_message() == "f\n", "lowercase f or Shift+Enter was not preserved: %s" % JSON.stringify(_dialog().smoke_message()))
	_dialog().smoke_set_message("I walked into a tree and got stuck.")
	await _key(Key.KEY_ENTER)
	await get_tree().create_timer(2.1, true, false, true).timeout
	_check(FileAccess.file_exists(_prepared_path), "offline report was not retained")
	_check(not _dialog().visible and not get_tree().paused, "offline queue did not resume play")
	_controller().smoke_set_transport(Callable(self, "_fake_transport"))
	await _controller().smoke_retry(report_id)
	_check(_transport_checks, "transport did not receive a valid agent bundle")
	_check(_prepared_path.is_empty() or not FileAccess.file_exists(_prepared_path), "sent bundle remained in outbox")
	var calls_after_send := _transport_calls
	await _controller().smoke_retry(report_id)
	_check(_transport_calls == calls_after_send, "completed report was uploaded twice")


func _offline_transport(prepared: Dictionary) -> Dictionary:
	_prepared_path = str(prepared.get("bundle_path", ""))
	return {"status": "queued", "reason": "scenario_offline"}


func _fake_transport(prepared: Dictionary) -> Dictionary:
	_transport_calls += 1
	_prepared_path = str(prepared.get("bundle_path", ""))
	var reader := ZIPReader.new()
	if reader.open(_prepared_path) != OK:
		return {"status": "blocked", "reason": "scenario_zip_open"}
	var names := Array(reader.get_files())
	var report = JSON.parse_string(reader.read_file("report.json").get_string_from_utf8())
	var trace := reader.read_file("trace.jsonl").get_string_from_utf8()
	reader.close()
	_transport_checks = report is Dictionary and report.get("schema_version") == 1 \
		and report.get("message") == "I walked into a tree and got stuck." \
		and _is_canonical_utc_timestamp(str(report.get("created_at_utc", ""))) \
		and names.has("save.json") and names.has("ui-tree.json") and names.has("README.txt") \
		and (DisplayServer.get_name() == "headless" or names.has("screenshot.png")) \
		and report.get("capture", {}).get("screen") == "overworld" \
		and trace.contains("feedback_capture_requested")
	return {"status": "sent", "issue_number": 4321} if _transport_checks else {"status": "blocked", "reason": "scenario_bundle_invalid"}


func _is_canonical_utc_timestamp(value: String) -> bool:
	var pattern := RegEx.new()
	return pattern.compile("^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}Z$") == OK and pattern.search(value) != null


func _press(action: String) -> void:
	await SmokeTap.tap(get_tree(), action)


func _key(keycode: Key, shifted: bool = false) -> void:
	await SmokeTap.tap_key(get_tree(), keycode, shifted)


func _check(ok: bool, message: String) -> void:
	if not ok: _failures.append(message)


func _controller() -> Node: return _ctx.feedback_controller
func _dialog() -> Control: return _ctx.feedback_dialog
