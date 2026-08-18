extends Node
const SmokeTap := preload("res://scripts/app/smoke_tap.gd")
const ResilienceChecks := preload("res://scripts/app/feedback_flow_resilience_checks.gd")

# Release-feedback journey: real F input across player-facing screens, text
# focus suppression, pause restoration, and a fully parsed private ZIP through
# the reporter's transport seam. No network or GitHub issue is touched.

var _ctx: Dictionary
var _failures: Array[String] = []
var _transport_checks := false
var _prepared_path := ""
var _transport_calls := 0
var _hold_retry_upload := true
var _expected_routes := {}
const DIALOG_CAPTURE_PATH := "user://feedback-dialog.png"
const INSTALL_ID_TEST_PATH := "user://feedback-flow-install-id.txt"


func run(ctx: Dictionary) -> void:
	_ctx = ctx
	process_mode = Node.PROCESS_MODE_ALWAYS
	await _text_focus_guard()
	await _screen_capture("title", func() -> void: _ctx.title_screen.show_title(), func() -> void: _ctx.title_screen.visible = false)
	await _screen_capture("menu", Callable(self, "_open_menu_with_overlay"),
		Callable(self, "_close_menu_with_overlay"), ["StartMenu", "MessageBox"])
	for overlay in [["storage", "StorageScreen"], ["camp", "CampMenu"], ["waystone", "WayStoneSelector"]]:
		await _screen_capture(overlay[0], func() -> void: _set_overlay(overlay[1], true),
			func() -> void: _set_overlay(overlay[1], false), [overlay[1]])
	await _screen_capture("battle", func() -> void: _ctx.battle_view.visible = true, func() -> void: _ctx.battle_view.visible = false)
	await _submit_overworld()
	_failures.append_array(await ResilienceChecks.new().run(_controller(), _dialog(), get_tree()))
	if _failures.is_empty():
		_ctx.runtime.emit_trace("feedback_flow_passed", "FeedbackFlowScenario", {
			"screens": ["title", "menu", "storage", "camp", "waystone", "battle", "overworld"], "bundle_verified": _transport_checks,
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
func _screen_capture(screen: String, open: Callable, close: Callable, expected_ui_roots: Array[String] = []) -> void:
	open.call()
	await get_tree().process_frame
	await _press("feedback_report")
	_check(_dialog().visible, "F did not open feedback from %s" % screen)
	_check(get_tree().paused, "feedback did not pause from %s" % screen)
	_check(str(_controller().smoke_state().get("capture_screen", "")) == screen, "capture mislabeled %s" % screen)
	var paths: Array = _controller().smoke_state().get("capture_ui_paths", [])
	for expected_root in expected_ui_roots:
		_check(_has_ui_root(paths, expected_root), "capture omitted visible %s root from %s" % [expected_root, screen])
	await _key(Key.KEY_ESCAPE)
	_check(not get_tree().paused and not _dialog().visible, "cancel did not restore %s" % screen)
	close.call()
	await get_tree().process_frame
func _open_menu_with_overlay() -> void:
	_ctx.start_menu.show_menu()
	_ctx.message_box.show_message("Visible overlay", 10.0)
func _close_menu_with_overlay() -> void:
	_ctx.message_box.hide_message()
	_ctx.start_menu.hide_menu()
func _set_overlay(node_name: String, shown: bool) -> void:
	_controller().get_node("../UI/" + node_name).visible = shown
func _submit_overworld() -> void:
	_seed_malformed_install_id()
	_controller().smoke_set_install_id_path(INSTALL_ID_TEST_PATH)
	var first_build := _scenario_build("a")
	_controller().smoke_set_build_info(first_build)
	_controller().smoke_set_transport(Callable(self, "_offline_transport"))
	await _press("feedback_report")
	_check(_dialog().visible, "F did not open feedback from overworld")
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		var dialog_image := get_viewport().get_texture().get_image()
		if dialog_image != null and not dialog_image.is_empty():
			dialog_image.save_png(DIALOG_CAPTURE_PATH)
	var report_id := str(_controller().smoke_state().get("report_id", ""))
	_expected_routes[report_id] = first_build
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
	var first_path := _prepared_path
	var first_route := first_path.trim_suffix(".zip") + ".route"
	var second_build := _scenario_build("b")
	_controller().smoke_set_build_info(second_build)
	_controller().smoke_set_transport(Callable(self, "_race_transport"))
	_controller().smoke_retry(report_id)
	await get_tree().process_frame
	_check(_transport_calls == 1, "queued retry did not begin")
	await _press("feedback_report")
	var second_report_id := str(_controller().smoke_state().get("report_id", ""))
	_expected_routes[second_report_id] = second_build
	_dialog().smoke_set_message("I walked into a tree and got stuck.")
	await _key(Key.KEY_ENTER)
	await get_tree().create_timer(2.1, true, false, true).timeout
	var second_path := "user://feedback_outbox/%s.zip" % second_report_id
	var second_route := second_path.trim_suffix(".zip") + ".route"
	_check(_transport_calls == 1, "concurrent submit reused the active HTTP transport")
	_check(FileAccess.file_exists(second_path), "concurrent report was not retained")
	_hold_retry_upload = false
	await _wait_for_reporter_idle()
	_check(_transport_checks, "transport did not receive a valid agent bundle")
	_check(FileAccess.file_exists(first_path) and FileAccess.file_exists(second_path),
		"queued retry or concurrent report disappeared before the fresh scan")
	_check(bool(_controller().smoke_reporter_state().get("retry_scheduled", false)),
		"concurrent report was left without a retry timer")
	await _controller().smoke_retry("")
	_check(_transport_calls == 3, "queued old route stranded a later independent report")
	_check(FileAccess.file_exists(first_path) and not FileAccess.file_exists(second_path),
		"fresh scan did not retain queued A and send independent B")
	_check(not FileAccess.file_exists(second_route), "concurrent report retained its private route")
	await _controller().smoke_retry(report_id)
	_check(_transport_calls == 4 and not FileAccess.file_exists(first_path),
		"older queued report did not send on its later retry")
	_check(not FileAccess.file_exists(first_route), "sent retry retained its private route")
	var calls_after_send := _transport_calls
	await _controller().smoke_retry(report_id)
	_check(_transport_calls == calls_after_send, "completed report was uploaded twice")
	_check(FileAccess.file_exists(INSTALL_ID_TEST_PATH) \
		and _is_install_id(FileAccess.get_file_as_string(INSTALL_ID_TEST_PATH).strip_edges()),
		"malformed persisted install ID was not regenerated")
	_controller().smoke_set_build_info({})
	_cleanup_install_id_test()

func _offline_transport(prepared: Dictionary) -> Dictionary:
	_prepared_path = str(prepared.get("bundle_path", ""))
	return {"status": "queued", "reason": "scenario_offline"}

func _race_transport(prepared: Dictionary) -> Dictionary:
	_transport_calls += 1
	_prepared_path = str(prepared.get("bundle_path", ""))
	var reader := ZIPReader.new()
	if reader.open(_prepared_path) != OK:
		return {"status": "blocked", "reason": "scenario_zip_open"}
	var names := Array(reader.get_files())
	var report = JSON.parse_string(reader.read_file("report.json").get_string_from_utf8())
	var trace := reader.read_file("trace.jsonl").get_string_from_utf8()
	reader.close()
	var expected: Dictionary = _expected_routes.get(str(prepared.get("metadata", {}).get("report_id", "")), {})
	var build: Dictionary = prepared.get("build", {})
	var valid: bool = report is Dictionary and report.get("schema_version") == 1 \
		and report.get("message") == "I walked into a tree and got stuck." \
		and _is_install_id(str(report.get("install_id", ""))) \
		and _is_canonical_utc_timestamp(str(report.get("created_at_utc", ""))) \
		and names.has("save.json") and names.has("ui-tree.json") and names.has("README.txt") \
		and (DisplayServer.get_name() == "headless" or names.has("screenshot.png")) \
		and report.get("capture", {}).get("screen") == "overworld" \
		and trace.contains("feedback_capture_requested") \
		and build.get("endpoint") == expected.get("endpoint") \
		and build.get("invite_token") == expected.get("invite_token") \
		and build.get("tester_id") == expected.get("tester_id") \
		and build.get("channel") == expected.get("channel")
	_transport_checks = valid if _transport_calls == 1 else _transport_checks and valid
	if _transport_calls == 1:
		while _hold_retry_upload:
			await get_tree().process_frame
	if _transport_calls <= 2:
		return {"status": "queued", "reason": "scenario_route_wait"}
	return {"status": "sent", "issue_number": 4321} if _transport_checks else {"status": "blocked", "reason": "scenario_bundle_invalid"}

func _scenario_build(suffix: String) -> Dictionary:
	return {"channel": "scenario-" + suffix, "build_id": "scenario-" + suffix,
		"commit_sha": "scenario", "endpoint": "https://feedback.invalid/" + suffix,
		"invite_token": "scenario-token-" + suffix, "tester_id": "T-SCENARIO-" + suffix.to_upper()}

func _wait_for_reporter_idle() -> void:
	for _frame in 120:
		if not bool(_controller().smoke_reporter_state().get("busy", false)):
			return
		await get_tree().process_frame
	_check(false, "retry upload did not release its owner lock")

func _is_canonical_utc_timestamp(value: String) -> bool:
	var pattern := RegEx.new()
	return pattern.compile("^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}Z$") == OK and pattern.search(value) != null

func _is_install_id(value: String) -> bool:
	var pattern := RegEx.new()
	return pattern.compile("^[0-9a-f]{32}$") == OK and pattern.search(value) != null

func _seed_malformed_install_id() -> void:
	_cleanup_install_id_test()
	var file := FileAccess.open(INSTALL_ID_TEST_PATH, FileAccess.WRITE)
	_check(file != null, "could not seed malformed install ID")
	if file != null:
		_check(file.store_string("truncated\n"), "could not write malformed install ID")
		file.close()
func _cleanup_install_id_test() -> void:
	_controller().smoke_set_install_id_path("")
	for path in [INSTALL_ID_TEST_PATH, INSTALL_ID_TEST_PATH + ".tmp"]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
func _has_ui_root(paths: Array, root: String) -> bool:
	for path in paths:
		if str(path) == root or str(path).begins_with(root + "/"):
			return true
	return false
func _press(action: String) -> void:
	await SmokeTap.tap(get_tree(), action)
func _key(keycode: Key, shifted: bool = false) -> void:
	await SmokeTap.tap_key(get_tree(), keycode, shifted)
func _check(ok: bool, message: String) -> void:
	if not ok: _failures.append(message)
func _controller() -> Node: return _ctx.feedback_controller
func _dialog() -> Control: return _ctx.feedback_dialog
