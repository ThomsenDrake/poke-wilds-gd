extends RefCounted

# Shared title → NEW GAME → creation → GO climb-out. play_agent keeps the
# one held-key step and quit; hunt_soak continues after the same climb.

const SmokeTap := preload("res://scripts/app/smoke_tap.gd")
const CreationRender := preload("res://scripts/ui/creation_screen_render.gd")

const PIN := 2026080701
const WORLD_SEED := 2026080702


func drive(host: Node, ctx: Dictionary, runner, failures: Array) -> void:
	var tree: SceneTree = host.get_tree()
	var title: Control = ctx["title_screen"]
	var creation: Control = ctx["creation_screen"]
	var message_box: Node = ctx["message_box"]
	var cursor: int = runner.trace_log_line_count()
	title.begin_boot(true)
	await SmokeTap.tap(tree, "action_a")
	if not _expect(failures, not title.get_node("Splash").visible, "injection witness: the splash skip did not run"):
		return
	if not _expect(failures, title.entry_labels() == ["CONTINUE", "NEW GAME"], "the with-save entries %s != [CONTINUE, NEW GAME]" % str(title.entry_labels())):
		return
	_expect(failures, runner.trace_log_has_since("title_shown", cursor, {"has_save": true}), "no title_shown{has_save:true} trace since begin_boot")
	await SmokeTap.tap(tree, "move_down")
	if not _expect(failures, title.entry_row_text(title.selected_entry()) == "NEW GAME", "the cursor did not land on NEW GAME"):
		return
	await SmokeTap.tap(tree, "action_a")
	if not _expect(failures, message_box.is_confirming(), "injection witness: NEW GAME did not open the save-wipe confirm"):
		return
	await SmokeTap.tap(tree, "action_a")
	_expect(failures, runner.trace_log_has_since("title_new_game_chosen", cursor), "no title_new_game_chosen trace after the confirmed NEW GAME")
	if not _expect(failures, creation.visible and not title.visible, "injection witness: the confirm did not swap title -> creation"):
		return
	var value_label: Label = CreationRender.step_value_label(creation)
	await SmokeTap.tap(tree, "move_left")
	if not _expect(failures, CreationRender.seed_edit_active(creation), "injection witness: move_left did not open the seed digit row"):
		return
	for character in str(WORLD_SEED):
		await SmokeTap.tap_digit(tree, int(character))
	await SmokeTap.tap(tree, "action_a")
	if not _expect(failures, value_label.text == str(WORLD_SEED), "the seed step shows '%s', not the typed %d" % [value_label.text, WORLD_SEED]):
		return
	await SmokeTap.tap(tree, "action_a")
	await SmokeTap.tap(tree, "action_a")
	await SmokeTap.tap(tree, "action_a")
	if not _expect(failures, creation._name_entry.visible, "injection witness: Z did not open the NameEntry grid"):
		return
	if not await SmokeTap.flush(tree, "move_right", 27):
		failures.append("injection: no key event is bound to move_right")
		return
	await SmokeTap.tap(tree, "action_a")
	if not _expect(failures, not creation._name_entry.visible, "injection witness: OK did not close the NameEntry grid"):
		return
	await SmokeTap.tap(tree, "action_a")
	await SmokeTap.tap(tree, "action_a")
	if not _expect(failures, creation._avatar_picker.visible, "injection witness: Z did not open the AvatarPicker"):
		return
	await SmokeTap.tap(tree, "action_a")
	await SmokeTap.tap(tree, "action_a")
	if not _expect(failures, CreationRender.step_title_label(creation).text == "Go!", "the flow landed on '%s', not the GO step" % CreationRender.step_title_label(creation).text):
		return
	var go_cursor: int = runner.trace_log_line_count()
	await SmokeTap.tap(tree, "action_a")
	await tree.create_timer(0.9).timeout
	_expect(failures, runner.trace_log_has_since("creation_confirmed", go_cursor, {"world_seed": WORLD_SEED}), "no creation_confirmed{world_seed:%d} since the GO press" % WORLD_SEED)
	_expect(failures, runner.trace_log_has_since("world_rebuilt", go_cursor), "no world_rebuilt since the GO press (main._enter_world did not run)")


func _expect(failures: Array, ok: bool, label: String) -> bool:
	if not ok:
		failures.append(label)
	return ok
