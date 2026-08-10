extends RefCounted

# Title + creation baseline shots of the main visual sweep (37-41; restyle
# slice wave 0, design §4.2): rides the MAIN sweep — no satellite family — so
# the captures inherit the sweep's CRAFTED_STATE sidecar metadata and the
# sweep-global shot_seq through the sweep's own _capture callable (no
# hand-crafted metadata, no second world; the RED-tier sidecar seed-equality
# gate stays green by construction). Runs right after _menu_shots() as a
# static run(sweep) that reaches into the sweep node for the shared plumbing
# (the visual_sweep_world_depth_expand precedent).
#
# The drive mirrors new_game_flow: begin_boot + a REAL splash-skip tap + the
# entry list, then open_screen + Z/X/arrow step navigation + the name/avatar
# overlays — every navigation press is a real input-phase SmokeTap. It NEVER
# confirms GO (no creation_confirmed, no session_created, no session/save
# mutation): the name overlay confirms an EMPTY name — the documented fallback
# branch — only to advance to the avatar step, and the avatar picker is
# X-cancelled, never Z-confirmed. The avatar is parked and accumulated input
# is on for the drive (new_game_flow's posture); EVERY exit path restores
# both, hides both screens, and leaves the sweep's canonical state untouched.

const SmokeTap := preload("res://scripts/app/smoke_tap.gd")
const CreationRender := preload("res://scripts/ui/creation_screen_render.gd") # the step-label seams live here (creation_screen.gd's 220-wall extraction)

const SHOT_SPLASH := "37_title_splash.png"
const SHOT_ENTRIES := "38_title_entries.png"
const SHOT_SEED := "39_creation_seed.png"
const SHOT_NAME := "40_creation_name.png"
const SHOT_AVATAR := "41_creation_avatar.png"
const WITH_SAVE_ENTRIES := ["CONTINUE", "NEW GAME"] # begin_boot(true): the fuller entry list


# Runs the five title/creation shots on the sweep node. Loud-fails into
# sweep._failures (never silent) when a screen seam or a navigation witness
# breaks; every exit path restores the drive state.
static func run(sweep: Node) -> void:
	var title: Control = sweep._ctx["title_screen"]
	var creation: Control = sweep._ctx["creation_screen"]
	var player: Node = sweep._ctx["player"]
	var saved_avatar_input: bool = player.input_enabled
	player.input_enabled = false # the avatar polls movement in _process; the screens must own the injected keys
	Input.use_accumulated_input = true # SmokeTap's contract; the caller owns the toggle (new_game_flow precedent)
	var start: int = sweep._failures.size()
	await _title_shots(sweep, title)
	if sweep._failures.size() == start:
		await _creation_shots(sweep, creation)
	_restore(title, creation, player, saved_avatar_input)


# 37 + 38: the splash card, then the with-save entry list behind it.
static func _title_shots(sweep: Node, title: Control) -> void:
	var tree: SceneTree = sweep.get_tree()
	title.begin_boot(true) # the with-save splash/entries (the fuller shot; matches the crafted save state)
	if not _witness(sweep, SHOT_SPLASH, title.visible and title.get_node("Splash").visible,
			"begin_boot did not raise the splash card"):
		return
	await sweep._capture(SHOT_SPLASH)
	await SmokeTap.tap(tree, "action_a") # the new_game_flow splash skip: any action press lands the title
	if not _witness(sweep, SHOT_ENTRIES,
			title.get_node("EntryPanel").visible and title.entry_labels() == WITH_SAVE_ENTRIES,
			"the splash skip did not raise the with-save entry list"):
		return
	await sweep._capture(SHOT_ENTRIES)
	title.hide_screen() # the public hide: the creation shots start from a clean screen


# 39-41: the SEED step, the name grid overlay, the avatar picker overlay. Step
# navigation is the new_game_flow tap sequence minus the GO confirm.
static func _creation_shots(sweep: Node, creation: Control) -> void:
	var tree: SceneTree = sweep.get_tree()
	creation.open_screen() # the real seam main.gd wires; lands on the SEED step
	if not _witness(sweep, SHOT_SEED,
			CreationRender.step_title_label(creation).text == "WORLD SEED" and CreationRender.step_value_label(creation).text == "RANDOM",
			"open_screen did not land on the WORLD SEED/RANDOM step"):
		return
	await sweep._capture(SHOT_SEED)
	await SmokeTap.tap(tree, "action_a") # SEED -> SHINY
	await SmokeTap.tap(tree, "action_a") # SHINY -> NAME
	if not _witness(sweep, SHOT_NAME, CreationRender.step_title_label(creation).text == "NAME",
			"the step navigation did not land on the NAME step"):
		return
	await SmokeTap.tap(tree, "action_a") # Z opens the name grid keyboard (cursor starts on A)
	var entry: Control = creation._name_entry
	if not _witness(sweep, SHOT_NAME, entry.visible, "Z did not open the NameEntry grid"):
		return
	await sweep._capture(SHOT_NAME)
	# Walk the grid A(0) -> OK(27): down x3 (0 -> 21), right x6 (21 -> 27). OK
	# confirms the EMPTY name — the documented fallback branch — only to advance.
	for _i in range(3):
		await SmokeTap.tap(tree, "move_down")
	for _i in range(6):
		await SmokeTap.tap(tree, "move_right")
	await SmokeTap.tap(tree, "action_a") # OK closes the grid; the step's next Z advances
	if not _witness(sweep, SHOT_AVATAR, not entry.visible, "OK did not close the NameEntry grid"):
		return
	await SmokeTap.tap(tree, "action_a") # NAME -> AVATAR
	if not _witness(sweep, SHOT_AVATAR, CreationRender.step_title_label(creation).text == "PLAYER",
			"the step navigation did not land on the AVATAR step"):
		return
	await SmokeTap.tap(tree, "action_a") # Z opens the avatar picker (cursor 0: the sorted first set)
	var picker: Control = creation._avatar_picker
	if not _witness(sweep, SHOT_AVATAR, picker.visible, "Z did not open the AvatarPicker grid"):
		return
	await sweep._capture(SHOT_AVATAR)
	await SmokeTap.tap(tree, "action_b") # X cancels the picker: nothing is chosen, nothing mutates


# EVERY exit path: both screens hidden, accumulated input off, avatar restored.
static func _restore(title: Control, creation: Control, player: Node, saved_avatar_input: bool) -> void:
	creation.close_screen() # guarded hides: safe on every exit path
	title.hide_screen()
	Input.use_accumulated_input = false
	player.input_enabled = saved_avatar_input


# Appends a shot-labeled failure (the day_menu loud-fail shape); returns ok for witness early-returns.
static func _witness(sweep: Node, shot: String, ok: bool, label: String) -> bool:
	if not ok:
		sweep._failures.append("%s: %s" % [shot, label])
	return ok
