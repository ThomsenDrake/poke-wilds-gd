extends Node

# Live-play target for tools/commandcode_play_agent.py (Track C.2): the agent
# writes the smoke request and launches the WINDOWED subprocess (the
# run_playtests windowed transport, never DAP), and THIS scenario does the
# driving in-engine — title -> NEW GAME -> creation (typed seed digits) -> GO
# -> world spawn -> one REAL overworld step (a held injected direction key read
# by the avatar's _process poll, never smoke_step) -> the bag snapshot -> a
# pixel readback so snapshot_captured is earned. Windowed-only like
# temporal_flow (real input phases + a renderer). Self-pinned (seed_for_smoke
# BEFORE driving creation — the starter shiny draw is the ONE pinned-stream
# consumer; the custom WORLD_SEED skips the world-seed draw, the new_game_flow
# precedent). Runs inside the dispatcher's save backup/restore guard (no
# playtest_ prefix), so the user's save is never touched — the old DAP drive's
# --user-dir isolation claim is GONE. Every tap is a REAL input-phase event
# (SmokeTap + the caller-owned Input.use_accumulated_input) with an injection
# witness, so degraded delivery fails red, never vacuous. miss-002 loudness:
# play_agent_passed / play_agent_failed + push_error.

const SmokeTap := preload("res://scripts/app/smoke_tap.gd")
const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")
const SnapshotCapture := preload("res://scripts/app/snapshot_capture.gd")

const PIN := 2026080701 # seed_for_smoke pin: the starter shiny draw rides this stream
const WORLD_SEED := 2026080702 # typed into the creation seed digit row (no RANDOM ambiguity)
const STEP_HOLD_FRAMES := 30 # bound on waiting for the held direction key to start a step

var _ctx: Dictionary = {}
var _runner = SmokeScenarioRunner.new()
var _failures: Array = []

func run(ctx: Dictionary) -> void:
	_ctx = ctx
	if DisplayServer.get_name() == "headless":
		_failures.append("play_agent scenario requires a windowed transport (real window + input phases)")
		_finish()
		return
	await get_tree().create_timer(0.2).timeout
	Input.use_accumulated_input = true # caller-owned toggle; _restore clears it on every exit path
	_player().input_enabled = false # the screens must own the injected keys (the new_game_flow precedent)
	_runtime().seed_for_smoke(PIN)
	await _drive_creation()
	if _failures.is_empty():
		await _drive_overworld_step()
	if _failures.is_empty():
		_check_inventory()
	if _failures.is_empty():
		await _capture_snapshot()
	_restore()
	_finish()

# Title -> NEW GAME -> save-wipe confirm -> creation steps -> GO (the part-4
# seam of new_game_flow_checks, with NAME/AVATAR kept at their defaults via
# the empty OK confirm / the cursor-cell-0 confirm).
func _drive_creation() -> void:
	var title := _title()
	var creation := _creation()
	var cursor := _runner.trace_log_line_count()
	title.begin_boot(true) # has_save: NEW GAME rides the real save-wipe confirm gate
	await _tap("action_a") # splash skip
	if not _expect(not title.get_node("Splash").visible, "injection witness: the splash skip did not run"):
		return
	if not _expect(title.entry_labels() == ["CONTINUE", "NEW GAME"], "the with-save entries %s != [CONTINUE, NEW GAME]" % str(title.entry_labels())):
		return
	_expect(_runner.trace_log_has_since("title_shown", cursor, {"has_save": true}), "no title_shown{has_save:true} trace since begin_boot")
	await _tap("move_down") # CONTINUE -> NEW GAME
	if not _expect(title.entry_row_text(title.selected_entry()) == "NEW GAME", "the cursor did not land on NEW GAME"):
		return
	await _tap("action_a") # NEW GAME -> the MessageBox save-wipe confirm
	if not _expect(_message_box().is_confirming(), "injection witness: NEW GAME did not open the save-wipe confirm"):
		return
	await _tap("action_a") # the confirm answer runs the title -> creation swap
	_expect(_runner.trace_log_has_since("title_new_game_chosen", cursor), "no title_new_game_chosen trace after the confirmed NEW GAME")
	if not _expect(creation.visible and not title.visible, "injection witness: the confirm did not swap title -> creation"):
		return
	var value_label: Label = creation.step_value_label()
	await _tap("move_left") # RANDOM -> the in-stage seed digit row
	if not _expect(creation.seed_edit_active(), "injection witness: move_left did not open the seed digit row"):
		return
	for character in str(WORLD_SEED): # unicode digit events (the digit row reads unicode 48-57)
		await _tap_digit(int(character))
	await _tap("action_a") # the digit row's Z commit stores the typed seed
	if not _expect(value_label.text == str(WORLD_SEED), "the seed step shows '%s', not the typed %d" % [value_label.text, WORLD_SEED]):
		return
	await _tap("action_a") # SEED -> SHINY (the 1/256 default stands)
	await _tap("action_a") # SHINY -> NAME
	await _tap("action_a") # NAME opens the NameEntry grid
	if not _expect(creation._name_entry.visible, "injection witness: Z did not open the NameEntry grid"):
		return
	await _flush("move_right", 27) # cell 0 (A) -> cell 27 (OK); the empty confirm keeps DEFAULT_PLAYER_NAME
	await _tap("action_a") # OK confirms back to the step
	if not _expect(not creation._name_entry.visible, "injection witness: OK did not close the NameEntry grid"):
		return
	await _tap("action_a") # NAME -> AVATAR (the overlay is done)
	await _tap("action_a") # AVATAR opens the picker
	if not _expect(creation._avatar_picker.visible, "injection witness: Z did not open the AvatarPicker"):
		return
	await _tap("action_a") # confirm the default avatar (cursor cell 0)
	await _tap("action_a") # AVATAR -> GO
	if not _expect(creation.step_title_label().text == "Go!", "the flow landed on '%s', not the GO step" % creation.step_title_label().text):
		return
	var go_cursor := _runner.trace_log_line_count()
	await _tap("action_a") # GO -> the generating beat -> creation_confirmed
	await get_tree().create_timer(0.9).timeout # the 0.6s GenTimer beat + headroom
	_expect(_runner.trace_log_has_since("creation_confirmed", go_cursor, {"world_seed": WORLD_SEED}), "no creation_confirmed{world_seed:%d} since the GO press" % WORLD_SEED)
	_expect(_runner.trace_log_has_since("world_rebuilt", go_cursor), "no world_rebuilt since the GO press (main._enter_world did not run)")

# One REAL overworld step: the held direction key rides the avatar's
# Input.is_action_pressed poll in _process — the player-facing movement path.
func _drive_overworld_step() -> void:
	var player := _player()
	var direction := _runner.find_safe_step_direction(_world(), player, _runtime())
	if not _expect(direction != Vector2i.ZERO, "no safe overworld step from the spawn tile"):
		return
	var action := _direction_action(direction)
	var from_tile: Vector2i = player.tile_position
	if not SmokeTap.inject_press(action):
		_failures.append("injection: no key event is bound to %s" % action)
		return
	var started := false
	for _i in range(STEP_HOLD_FRAMES):
		await get_tree().process_frame
		if player.is_moving():
			started = true
			break
	SmokeTap.inject_release(action)
	if not _expect(started, "injection witness: the held %s press never started a step" % action):
		return
	await player.tile_changed
	var landed: Vector2i = player.tile_position
	player.input_enabled = false
	if _expect(landed == from_tile + direction, "the step landed on %s, not %s" % [str(landed), str(from_tile + direction)]):
		_runtime().emit_trace("overworld_step", "SmokeScenarios", {"tile": [landed.x, landed.y], "from_tile": [from_tile.x, from_tile.y], "steps": 1})

# Bag witness off the runtime's real snapshot seam (the save shape), emitted
# pass OR fail so the lane can never greenwash a skipped check.
func _check_inventory() -> void:
	var snapshot: Array = _runtime().session.get_bag_snapshot()
	var ok := not snapshot.is_empty()
	_runtime().emit_trace("inventory_checked", "SmokeScenarios", {"items": snapshot, "item_count": snapshot.size(), "ok": ok})
	_expect(ok, "the starting bag snapshot is empty (the creation defaults did not land)")

# One real pixel readback (no PNG write — the trace carries the window stamp),
# so the report's snapshot_captured is earned, never faked. An invalid verdict
# rides capture_invalid (quarantine-tier), never the pass marker.
func _capture_snapshot() -> void:
	await SnapshotCapture.new().capture(_runtime(), _ctx["viewport"], "play_agent")

func _finish() -> void:
	if _failures.is_empty():
		_runtime().emit_trace("play_agent_passed", "SmokeScenarios", {"pin": PIN, "world_seed": WORLD_SEED})
	else:
		_runtime().emit_trace("play_agent_failed", "SmokeScenarios", {"failures": _failures, "seed": PIN})
		push_error("PlayAgentScenario failed: %s" % "; ".join(PackedStringArray(_failures)))

func _restore() -> void: # EVERY exit path: accumulated input off, avatar drivable, screens hidden
	Input.use_accumulated_input = false
	_player().input_enabled = true
	_title().hide_screen()
	_creation().close_screen()

func _tap(action: String) -> void:
	await SmokeTap.tap(get_tree(), action)

# N presses flush in ONE input phase -> N just_pressed dispatches (the
# new_game_flow_checks name-grid flush shape), one release afterwards.
func _flush(action: String, count: int) -> void:
	for _i in range(count):
		if not SmokeTap.inject_press(action):
			_failures.append("injection: no key event is bound to %s" % action)
			return
	SmokeTap.inject_release(action)
	await get_tree().process_frame

# One typed digit for the seed digit row: unicode + matching keycode/physical_keycode
# (gbc_digit_row's branch reads unicode 48-57), press -> frame -> release.
func _tap_digit(digit: int) -> void:
	var press := InputEventKey.new()
	press.unicode = 48 + digit; press.keycode = 48 + digit; press.physical_keycode = 48 + digit; press.pressed = true
	Input.parse_input_event(press)
	await get_tree().process_frame
	var release := InputEventKey.new()
	release.unicode = 48 + digit; release.keycode = 48 + digit; release.physical_keycode = 48 + digit; release.pressed = false
	Input.parse_input_event(release)
	await get_tree().process_frame

static func _direction_action(direction: Vector2i) -> String:
	match direction:
		Vector2i.UP: return "move_up"
		Vector2i.DOWN: return "move_down"
		Vector2i.LEFT: return "move_left"
		_: return "move_right"

func _expect(ok: bool, label: String) -> bool: # appends a labeled failure; returns ok for witness early-returns
	if not ok:
		_failures.append(label)
	return ok

func _title() -> Control: return _ctx["title_screen"]
func _creation() -> Control: return _ctx["creation_screen"]
func _message_box() -> Node: return _ctx["message_box"]
func _world() -> Node: return _ctx["world"]
func _player() -> Node: return _ctx["player"]
func _runtime() -> Node: return _ctx["runtime"]
