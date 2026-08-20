extends Node

const SmokeTap := preload("res://scripts/app/smoke_tap.gd")
const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")
const Checks := preload("res://scripts/app/update_flow_checks.gd")

var _ctx: Dictionary
var _runner = SmokeScenarioRunner.new()
var _failures: Array = []
var _download_error := ""
var _apply_error := ""
var _hold_download := false
var _applied := false
var _relaunched := false


func run(ctx: Dictionary) -> void:
	_ctx = ctx
	Input.use_accumulated_input = true
	var title = _ctx.title_screen
	var updater: Node = title.smoke_updater()
	updater.smoke_set_transport(Callable(self, "_transport"))
	updater.smoke_set_applier(Callable(self, "_apply"))
	updater.smoke_set_relauncher(Callable(self, "_relaunch"))
	Checks.reset_user_state()
	Checks.expect_skip(_failures, updater)
	title.show_title()
	Checks.expect_default_rows(_failures, title, bool(_ctx.runtime.has_loaded_save()))
	var kept: String = str(title.entry_row_text(title.selected_entry()))
	updater.smoke_set_latest(Checks.shared_latest())
	title.smoke_set_update_available(true)
	Checks.expect_update_row(_failures, title, bool(_ctx.runtime.has_loaded_save()))
	Checks.expect_selection_kept(_failures, title, kept)
	_ctx.runtime.emit_trace("update_available", "UpdateRuntime", {"build_id": "playtest-newbuild", "os": "linux"})
	title.select_entry(0)
	await SmokeTap.tap(get_tree(), "action_a")
	_check(_ctx.message_box.is_confirming(), "UPDATE did not open a confirm")
	await SmokeTap.tap(get_tree(), "action_b")
	_check(not _ctx.message_box.is_confirming(), "UPDATE cancel left the confirm open")
	_check(title.visible, "UPDATE cancel hid the title")
	_download_error = "hash_mismatch"
	_hold_download = true
	var refuse_from := _runner.trace_log_line_count()
	title.select_entry(0)
	await SmokeTap.tap(get_tree(), "action_a")
	await SmokeTap.tap(get_tree(), "action_a")
	await _wait_until(func(): return _ctx.message_box.is_holding())
	_check(_ctx.message_box.is_holding(), "download toast hid while UPDATE still held title input")
	_hold_download = false
	await _wait_until(func(): return _runner.trace_log_has_since("update_apply_refused", refuse_from), 60)
	await get_tree().process_frame
	_check(not _applied, "hash mismatch still applied")
	_check(_runner.trace_log_has_since("update_apply_refused", refuse_from), "hash mismatch did not trace update_apply_refused")
	Checks.expect_download_cleared(_failures)
	_download_error = ""
	_apply_error = "write_failed"
	var apply_refuse_from := _runner.trace_log_line_count()
	title.select_entry(0)
	await SmokeTap.tap(get_tree(), "action_a")
	await SmokeTap.tap(get_tree(), "action_a")
	await _wait_until(func(): return _runner.trace_log_has_since("update_apply_refused", apply_refuse_from), 60)
	_check(not _applied, "apply refuse still applied")
	Checks.expect_download_cleared(_failures)
	_apply_error = ""
	title.select_entry(0)
	await SmokeTap.tap(get_tree(), "action_a")
	await SmokeTap.tap(get_tree(), "action_a")
	await _wait_until(func(): return _applied and _relaunched, 40)
	_check(_applied and _relaunched, "successful UPDATE did not apply and relaunch")
	_check(not updater.latest_build().is_empty(), "shared latest was not staged on the updater")
	Checks.expect_identity_persist_refuse(_failures, updater)
	Checks.persist_friend(_failures)
	Checks.expect_shared_channel(_failures, updater)
	Checks.expect_embedded_update_endpoint(_failures, updater)
	Checks.expect_os_gate(_failures, updater)
	Checks.expect_no_downgrade(_failures, updater)
	Checks.expect_staging_cleared(_failures)
	Checks.apply_linux_fixture(_failures)
	Checks.apply_windows_fixture(_failures)
	Input.use_accumulated_input = false
	if _failures.is_empty():
		_ctx.runtime.emit_trace("update_flow_passed", "UpdateFlowScenario", {
			"update_row": true, "hash_refused": true, "identity_persisted": true})
	else:
		_ctx.runtime.emit_trace("update_flow_failed", "UpdateFlowScenario", {"failures": _failures})
		push_error("Update flow failed: %s" % "; ".join(_failures))


func _transport(kind: String, _build = null, dest: String = "") -> Dictionary:
	if kind == "latest":
		return Checks.shared_latest()
	for _i in range(30):
		if not _hold_download:
			break
		await get_tree().process_frame
	if _download_error == "hash_mismatch":
		var file := FileAccess.open(dest, FileAccess.WRITE)
		file.store_buffer(Checks.hash_mismatch_payload())
		file.close()
		return {"ok": true, "path": dest}
	var good := FileAccess.open(dest, FileAccess.WRITE)
	good.store_buffer(PackedByteArray([7, 7, 7, 7]))
	good.close()
	return {"ok": true, "path": dest, "verified": true}


func _apply(_os_name: String, _artifact: String, _target: String) -> Dictionary:
	if not _apply_error.is_empty():
		return {"ok": false, "error": _apply_error}
	_applied = true
	return {"ok": true}


func _relaunch() -> void:
	_relaunched = true


func _wait_until(check: Callable, frames: int = 20) -> void:
	for _i in range(frames):
		if check.call():
			return
		await get_tree().process_frame


func _check(ok: bool, reason: String) -> void:
	if not ok:
		_failures.append(reason)
