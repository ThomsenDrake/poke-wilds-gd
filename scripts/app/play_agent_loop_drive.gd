extends Node

# Title -> NEW GAME -> creation -> world spawn for play_agent_loop.
# Copied from play_agent_scenario (do not import that script).

const SmokeTap := preload("res://scripts/app/smoke_tap.gd")
const CreationRender := preload("res://scripts/ui/creation_screen_render.gd")
const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")

const PIN := 2026080701
const WORLD_SEED := 2026080702
const STEP_HOLD_FRAMES := 30
const INPUT_ALIASES := {"menu": "start"}

var _ctx: Dictionary = {}
var _runner: SmokeScenarioRunner = SmokeScenarioRunner.new()
var _failures: Array = []


func setup(ctx: Dictionary, runner: SmokeScenarioRunner, failures: Array) -> void:
	_ctx = ctx
	_runner = runner
	_failures = failures


func boot_new_game() -> void:
	var title := _title()
	var creation := _creation()
	var cursor: int = _runner.trace_log_line_count()
	_player().input_enabled = false
	title.begin_boot(true)
	await _tap("action_a")
	if not _expect(not title.get_node("Splash").visible, "splash skip did not run"):
		return
	if not _expect(title.entry_labels() == ["CONTINUE", "NEW GAME"], "title entries %s" % str(title.entry_labels())):
		return
	_expect(_runner.trace_log_has_since("title_shown", cursor, {"has_save": true}), "no title_shown{has_save:true}")
	await _tap("move_down")
	if not _expect(title.entry_row_text(title.selected_entry()) == "NEW GAME", "cursor missed NEW GAME"):
		return
	await _tap("action_a")
	if not _expect(_message_box().is_confirming(), "NEW GAME did not open save-wipe confirm"):
		return
	await _tap("action_a")
	_expect(_runner.trace_log_has_since("title_new_game_chosen", cursor), "no title_new_game_chosen")
	if not _expect(creation.visible and not title.visible, "confirm did not swap title -> creation"):
		return
	var value_label: Label = CreationRender.step_value_label(creation)
	await _tap("move_left")
	if not _expect(CreationRender.seed_edit_active(creation), "move_left did not open seed digit row"):
		return
	for character in str(WORLD_SEED):
		await SmokeTap.tap_digit(get_tree(), int(character))
	await _tap("action_a")
	if not _expect(value_label.text == str(WORLD_SEED), "seed step shows '%s'" % value_label.text):
		return
	await _tap("action_a")
	await _tap("action_a")
	await _tap("action_a")
	if not _expect(creation._name_entry.visible, "Z did not open NameEntry"):
		return
	if not await SmokeTap.flush(get_tree(), "move_right", 27):
		_failures.append("injection: no key event is bound to move_right")
		return
	await _tap("action_a")
	if not _expect(not creation._name_entry.visible, "OK did not close NameEntry"):
		return
	await _tap("action_a")
	await _tap("action_a")
	if not _expect(creation._avatar_picker.visible, "Z did not open AvatarPicker"):
		return
	await _tap("action_a")
	await _tap("action_a")
	if not _expect(CreationRender.step_title_label(creation).text == "Go!", "landed on '%s'" % CreationRender.step_title_label(creation).text):
		return
	var go_cursor: int = _runner.trace_log_line_count()
	await _tap("action_a")
	await get_tree().create_timer(0.9).timeout
	_expect(_runner.trace_log_has_since("creation_confirmed", go_cursor, {"world_seed": WORLD_SEED}), "no creation_confirmed")
	_expect(_runner.trace_log_has_since("world_rebuilt", go_cursor), "no world_rebuilt")
	_player().input_enabled = true


func apply_press(input_name: String) -> void:
	var bound := _bound_input(input_name)
	if not SmokeTap.inject_press(bound):
		_failures.append("injection: no key event is bound to %s" % input_name)
		return
	await get_tree().process_frame
	SmokeTap.inject_release(bound)
	await get_tree().process_frame


func apply_hold(input_name: String) -> void:
	var bound := _bound_input(input_name)
	_player().input_enabled = true
	if not SmokeTap.inject_press(bound):
		_failures.append("injection: no key event is bound to %s" % input_name)
		return
	var started := false
	for _i in range(STEP_HOLD_FRAMES):
		await get_tree().process_frame
		if _player().is_moving():
			started = true
			break
	SmokeTap.inject_release(bound)
	if started:
		await _player().tile_changed


func _bound_input(input_name: String) -> String:
	return str(INPUT_ALIASES.get(input_name, input_name))


func _tap(action: String) -> void:
	await SmokeTap.tap(get_tree(), action)


func _expect(ok: bool, label: String) -> bool:
	if not ok:
		_failures.append(label)
	return ok


func _title() -> Control: return _ctx["title_screen"]
func _creation() -> Control: return _ctx["creation_screen"]
func _message_box() -> Node: return _ctx["message_box"]
func _player() -> Node: return _ctx["player"]
