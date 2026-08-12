extends Node

# New-game flow gate (title_flow slice; spec: docs/product-specs/bootstrap-and-
# overworld.md). Drives the REAL title/creation screens end-to-end through the
# player-boot seam — TitleScreen.begin_boot(has_save), never main-internal
# state (scenario boots bypass the title; main_smoke_context carries the two
# screens): splash skip, the no-save/save entry lists, CONTINUE, then NEW GAME
# -> the save-wipe confirm -> the creation steps -> world + persistence
# witnesses (design §7 parts 4-6 live in new_game_flow_checks.gd, the
# input_gate_menu_checks extraction precedent). The pause-menu NEW GAME path is
# NOT re-driven here: menu_save + input_gate part D own it.
#
# Determinism posture (the seed_choice precedent; NOT a double-run consumer):
# SELF-PINNED — seed_for_smoke(PIN) BEFORE driving creation, so the ONE
# pinned-stream draw (the starter shiny roll at stream index 0) lands on PIN;
# the custom WORLD_SEED skips the world-seed draw, so nothing else rides the
# shared stream. Deterministic by construction; verify_all stays untouched.
#
# Every driving tap is a REAL input-phase event (SmokeTap.inject_press/
# inject_release + the caller-owned Input.use_accumulated_input, the
# input_gate precedent) and carries an injection WITNESS — state only real
# delivery can produce — so a degraded tap fails red, never vacuous. miss-002
# loudness: EVERY non-pass branch emits new_game_flow_failed{failures, seed}
# AND push_error(...); the pass emits new_game_flow_passed.

const SmokeTap := preload("res://scripts/app/smoke_tap.gd")
const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")
const NewGameFlowChecks := preload("res://scripts/app/new_game_flow_checks.gd")
const NewGameDungeonJourneyChecks := preload("res://scripts/app/new_game_dungeon_journey_checks.gd")

const PIN := 2026080601 # seed_for_smoke pin: the starter shiny draw rides this stream
const WORLD_SEED := 2026080001 # dual-contract pin: beach spawn + all seven DungeonMaps entrances
const NAME := "ASH" # non-default on purpose: proves the name grid + persistence
const AVATAR := "kris" # non-default on purpose (sorted AVATARS index 11): proves the swap end-to-end
const ODDS := 64 # non-default: proves the shiny ladder + the load-path odds re-apply

var _ctx: Dictionary = {}
var _runner = SmokeScenarioRunner.new()
var _failures: Array = []
var _oks: Dictionary = {}

func run(ctx: Dictionary) -> void:
	_ctx = ctx
	await get_tree().create_timer(0.2).timeout
	var runtime = _runtime()
	Input.use_accumulated_input = true # caller-owned toggle; _restore clears it on EVERY exit path
	_player().input_enabled = false # the avatar polls movement in _process; the screens must own the injected keys
	runtime.seed_for_smoke(PIN) # BEFORE creation: the starter shiny draw is the ONE pinned-stream consumer
	await _part_1_splash_skip()
	if _failures.is_empty():
		await _part_2_entries_without_save()
		if _failures.is_empty():
			await _part_3_continue()
			if _failures.is_empty():
				var checks := NewGameFlowChecks.new() # parts 4-6 (the app budget split)
				add_child(checks)
				await checks.run(_ctx, _runner, _failures, _oks)
				if _failures.is_empty():
					var dungeon_checks := NewGameDungeonJourneyChecks.new()
					add_child(dungeon_checks)
					await dungeon_checks.run(_ctx, _runner, _failures, _oks)
	if _failures.is_empty():
		var payload: Dictionary = _oks.duplicate()
		payload["pin"] = PIN; payload["seed"] = PIN; payload["world_seed"] = WORLD_SEED
		runtime.emit_trace("new_game_flow_passed", "SmokeScenarios", payload)
	else:
		runtime.emit_trace("new_game_flow_failed", "SmokeScenarios", {"failures": _failures, "seed": PIN})
		push_error("NewGameFlowScenario failed: %s" % "; ".join(PackedStringArray(_failures)))
	_restore()

# Part 1 — splash skip: begin_boot raises the card; ANY action press lands the title.
func _part_1_splash_skip() -> void:
	var title := _title()
	var cursor := _runner.trace_log_line_count()
	title.begin_boot(false)
	if not _expect(title.visible and title.get_node("Splash").visible, "1: begin_boot did not raise the splash card"):
		return
	if not _expect(_runner.trace_log_has_since("splash_shown", cursor), "1: no splash_shown trace after begin_boot"):
		return
	await SmokeTap.tap(get_tree(), "action_a")
	_expect(not title.get_node("Splash").visible, "1: injection witness: the tap did not hide the splash card")
	_expect(title.get_node("EntryPanel").visible, "1: injection witness: the title entries did not come up behind the splash")
	_expect(_runner.trace_log_has_since("splash_closed", cursor, {"reason": "key"}), "1: no splash_closed{reason:key} trace since the skip tap")

# Part 2 — entries without a save: exactly [NEW GAME]; title_shown{has_save:false}.
func _part_2_entries_without_save() -> void:
	var title := _title()
	title.hide_screen() # the public hide between parts: every part starts from a clean screen
	var cursor := _runner.trace_log_line_count()
	title.begin_boot(false)
	await SmokeTap.tap(get_tree(), "action_a") # splash skip
	if not _expect(not title.get_node("Splash").visible, "2: injection witness: the splash skip did not run"):
		return
	_expect(_entry_labels(title) == ["NEW GAME"], "2: the no-save entries %s != [NEW GAME]" % str(_entry_labels(title)))
	_expect(_runner.trace_log_has_since("title_shown", cursor, {"has_save": false}), "2: no title_shown{has_save:false} trace")

# Part 3 — entries with a save + CONTINUE: the cursor starts on CONTINUE and Z
# enters the world (main._enter_world ran — only real delivery enables the avatar).
func _part_3_continue() -> void:
	var title := _title()
	title.hide_screen()
	var cursor := _runner.trace_log_line_count()
	title.begin_boot(true)
	await SmokeTap.tap(get_tree(), "action_a") # splash skip
	if not _expect(not title.get_node("Splash").visible, "3: injection witness: the splash skip did not run"):
		return
	_expect(_entry_labels(title) == ["CONTINUE", "NEW GAME"], "3: the with-save entries %s != [CONTINUE, NEW GAME]" % str(_entry_labels(title)))
	_expect(_runner.trace_log_has_since("title_shown", cursor, {"has_save": true}), "3: no title_shown{has_save:true} trace")
	_expect(title.entry_row_text(title.selected_entry()) == "CONTINUE", "3: the cursor did not start on CONTINUE")
	var party_before := _party_ids()
	await SmokeTap.tap(get_tree(), "action_a") # CONTINUE
	_expect(_runner.trace_log_has_since("title_continued", cursor), "3: no title_continued trace")
	_expect(not title.visible, "3: CONTINUE left the title visible")
	_expect(_player().input_enabled, "3: injection witness: CONTINUE did not enable the avatar (main._enter_world did not run)")
	_expect(_party_ids() == party_before, "3: the party changed across CONTINUE")
	_player().input_enabled = false # the avatar must stay parked while part 4 drives the screens

func _restore() -> void: # EVERY exit path: accumulated input off, avatar drivable, screens hidden
	Input.use_accumulated_input = false
	_player().input_enabled = true
	_title().hide_screen()
	_creation().close_screen()

func _entry_labels(title) -> Array: # restyle seam: the old EntryPanel/Entries ItemList reads (design §3.1)
	return title.entry_labels()

func _party_ids() -> Array:
	var ids: Array = []
	for mon in _runtime().session.party:
		ids.append(str((mon as Dictionary).get("species_id", "")))
	return ids

func _expect(ok: bool, label: String) -> bool: # appends a labeled failure; returns ok for witness early-returns
	if not ok:
		_failures.append(label)
	return ok

func _title() -> Control: return _ctx["title_screen"]
func _creation() -> Control: return _ctx["creation_screen"]
func _player() -> Node: return _ctx["player"]
func _runtime() -> Node: return _ctx["runtime"]
