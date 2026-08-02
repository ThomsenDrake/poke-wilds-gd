extends RefCounted

# Save-stability support EXTRACTED from save_stability_scenario.gd for the app 220-line
# budget (the wild_battle_scenario precedent): the update-mode downshift guard — the golden
# always regenerates as the v4-shape MIGRATION WITNESS (a chained/unrepresentable write is
# REFUSED + traced). The v5 world_chain round-trip sublane RETIRED with world chaining
# (infinite-world slice). Domain access rides the runtime's own preload (the app layer may
# not preload domain directly — check_architecture.gd's layer table).
const SessionState := preload("res://scripts/runtime/session_state.gd")
const SaveMigration := SessionState.SaveMigration
const SaveStore := preload("res://scripts/runtime/save_store.gd")


# The chained-refusal load path (game_runtime.ensure_initialized) rides save_store._preserve,
# which ARMS live-path protection when a preserve rename FAILS — so a following write can NEVER
# clobber the un-preserved chained save (the .corrupt.bak/.newer.bak non-destructive guarantee).
# Verifies BOTH halves: a normal preserve moves a chained save to .chained.bak byte-intact, and a
# preserve-failure (a DIRECTORY squatted on the .chained.bak name) arms _live_path_protected so a
# subsequent write is REFUSED (no clobber). Returns "" on pass, else a named failure (miss-002).
static func chained_refusal_preserve_test(store, write_fixture: Callable, payload: Dictionary) -> String:
	store._live_path_protected = false
	write_fixture.call(payload)
	var preserved: String = store._preserve(".chained.bak")
	if preserved.is_empty():
		return "chained preserve: .chained.bak was not created"
	var kept = JSON.parse_string(FileAccess.get_file_as_string(preserved))
	if not (kept is Dictionary) or str((kept as Dictionary).get("active_chain", "")) != "0,-1":
		return "chained preserve: the original chained content was not kept byte-intact"
	if FileAccess.file_exists(SaveStore.SAVE_PATH):
		return "chained preserve: the live path was not vacated by the preserve"
	# Preserve-failure arms the write refusal (the non-destructive guarantee this slice's refusal relies on).
	write_fixture.call(payload)
	store._live_path_protected = false
	var squat := SaveStore.SAVE_PATH + ".chained.bak"
	if FileAccess.file_exists(squat):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(squat))
	DirAccess.make_dir_absolute(ProjectSettings.globalize_path(squat))
	var failed: String = store._preserve(".chained.bak")
	var issues := ""
	if not failed.is_empty():
		issues += "chained preserve-failure: _preserve reported success over a squatted directory; "
	if not store._live_path_protected:
		issues += "chained preserve-failure: live-path protection was NOT armed on a failed preserve; "
	if store.write_payload({"version": SessionState.SAVE_VERSION}):
		issues += "chained preserve-failure: a write clobbered the un-preserved chained save"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(squat))
	store._live_path_protected = false
	return issues


# Update mode rewrites the witness DOWNSHIFTED to the v4 shape (SaveMigration.downshift), so
# the committed golden stays a v4 MIGRATION WITNESS migrate() has work to do on. An
# unrepresentable write (a chained session that cannot downshift) is REFUSED with a traced
# refusal, never silent — a v6-shaped golden would make migrate() a no-op and green the proof
# forever while proving nothing.
static func update_golden(runtime, canon_a: String, canon_str: Callable, write_golden: Callable, ensure: Callable) -> void:
	var live: Variant = JSON.parse_string(canon_a)
	if not (live is Dictionary) or not SaveMigration.can_downshift(live as Dictionary):
		ensure.call(false, "golden: REFUSED to write an unrepresentable witness — chained worlds cannot downshift to the v4 seat")
		runtime.warn("SaveStabilityScenario", "Golden update refused: the live save carries chained worlds; the witness must stay v4-shaped.", {})
		return
	write_golden.call(canon_str.call(SaveMigration.downshift(live as Dictionary)))
