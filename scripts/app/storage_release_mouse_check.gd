extends Node

# RELEASE-confirm mouse-bypass regression (storage_screen.gd's _on_entry_clicked
# gate; spec: docs/product-specs/storage-and-party.md — the 0.2 destructive-
# action contract). While a "Release X?" confirm is pending the keyboard route
# is gated (storage_screen's _unhandled_input returns early), but the ItemList
# item_clicked route WAS NOT: a click on the still-visible action list executed
# the action — WITHDRAW mutated the box while _confirm_index stayed stale, so
# the keyboard confirm then permanently released a DIFFERENT mon than the one
# it named. This drives the real screen through the real overworld Z seam (the
# field_action_router BOX_ID arm), deposits two mons (M1 = PIKACHU first, M2 =
# ABRA second), opens RELEASE on M1, synthesizes a LEFT mouse press+release on
# the WITHDRAW row while the confirm is pending, then confirms by keyboard: the
# click must mutate NOTHING (no mon_withdrawn since the cursor), the confirm
# must release the mon it named (M1), and the box must keep the survivor (M2).
# Pre-fix red: the click withdraws M1 and the confirm releases M2. FALLBACK if
# headless GUI hit-testing will not deliver item_clicked under this transport
# (witnessed by a storage_mouse_fallback trace): a direct _on_entry_clicked
# call — weaker, but the direct call IS the handler the click invokes, so the
# gate line is still proven. Runs inside storage_flow (the scenario owns the
# accumulated input + the dispatcher save guard); wired as a party_checks group.

const SmokeTap := preload("res://scripts/app/smoke_tap.gd")

var _ctx: Dictionary = {}
var _runner = null # the scenario's SmokeScenarioRunner, injected by run()
var _failures: Array = [] # shared with the scenario
var _tile := Vector2i.ZERO


func run(ctx: Dictionary, runner, failures: Array, tile_c: Vector2i) -> void:
	_ctx = ctx; _runner = runner; _failures = failures; _tile = tile_c
	# Settle one frame: the reorder group's final PROGRAMMATIC menu close set the
	# latch (input-phase closes self-clear on the closing frame's poll, but a
	# programmatic close + an immediately parsed tap would land the press on the
	# latched frame); the next poll resets it before the seam tap flushes.
	await get_tree().process_frame
	var runtime = _runtime()
	var pikachu: int = _idx("PIKACHU")
	if not _ensure(pikachu >= 0 and _idx("ABRA") >= 0, "mouse: precondition: PIKACHU + ABRA are not both in the party"):
		return
	var base_count: int = runtime.storage_runtime.box_snapshot(_tile).size()
	_ensure(bool(runtime.storage_runtime.deposit(_tile, pikachu).get("ok", false)), "mouse: PIKACHU would not enter the box")
	_ensure(bool(runtime.storage_runtime.deposit(_tile, _idx("ABRA")).get("ok", false)), "mouse: ABRA would not enter the box") # party shifted by the first deposit
	var spot: Dictionary = _runner.stand_spot(_world(), _tile)
	if spot.is_empty(): _failures.append("mouse: the box has no walkable stand neighbor"); return
	_runner.teleport_player(_world(), _player(), runtime, spot["from_tile"]); _player().smoke_step(spot["direction"])
	_ensure(_player().facing_tile() == _tile, "mouse: the player does not face the box after the blocked step")
	await SmokeTap.tap(get_tree(), "action_a") # the real seam: the router's BOX_ID arm
	if not _ensure(_screen().visible and not _player().input_enabled, "mouse: injection witness: Z did not open the screen (the Z-route arm is unwired)"):
		return
	await _press("action_a") # browse -> actions (WITHDRAW / RELEASE / SUMMARY / CANCEL)
	await _press("move_down") # RELEASE (row 1)
	await _press("action_a") # -> "Release Pikachu? It will be gone for good."
	if not _ensure(_message_box().is_confirming(), "mouse: injection witness: RELEASE did not open the confirm box"):
		return
	var cursor: int = _runner.trace_log_line_count()
	_click_action_row(0) # the still-visible WITHDRAW row, mid-confirm
	_ensure(not _runner.trace_log_has_since("mon_withdrawn", cursor), "mouse: a click mid-confirm withdrew a mon (the _on_entry_clicked gate is missing)")
	_ensure(runtime.storage_runtime.box_snapshot(_tile).size() == base_count + 2, "mouse: the mid-confirm click mutated the box")
	await _press("action_a") # the keyboard confirm: must release M1, the mon the confirm NAMED
	_ensure(not _runner.trace_log_has_since("mon_withdrawn", cursor), "mouse: the confirm path withdrew a mon")
	_ensure(_runner.trace_log_has_since("mon_released", cursor, {"species_id": "PIKACHU"}), "mouse: the confirm did not release PIKACHU, the mon it named")
	var after: Array = runtime.storage_runtime.box_snapshot(_tile)
	_ensure(after.size() == base_count + 1 and str((after[after.size() - 1] as Dictionary).get("species_id", "")) == "ABRA", "mouse: ABRA did not survive as the box's only addition")
	await _press("action_b") # browse X: the real closed path
	_ensure(not _screen().visible and _player().input_enabled, "mouse: X did not close the screen and re-enable the avatar")


# Synthesizes a left-button press+release on the action list's `row` MID-CONFIRM
# (the assertion target is the _on_entry_clicked mid-confirm gate, which must
# block it). Delivers through the stage-mapped GUI event AND the direct handler
# (the guaranteed witness when GUI hit-testing will not land; never silent).
func _click_action_row(row: int) -> void:
	var screen := _screen()
	var stage_rect: Rect2 = screen.row_rect(row)
	if stage_rect.size == Vector2.ZERO:
		_failures.append("mouse: precondition: row %d has no rect (the action panel is not visible)" % row); return
	# Map the stage-local row to a window point through the screen's GbcStage
	# display (the 160x144 SubViewport texture drawn integer-scaled at an offset).
	var display: TextureRect = screen.get_node("ScreenDisplay")
	var dr := display.get_global_rect()
	var factor := dr.size.x / 160.0
	var at: Vector2 = dr.position + (stage_rect.position + stage_rect.size / 2.0) * factor
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = bool(pressed)
		event.position = at
		event.global_position = at
		Input.parse_input_event(event)
		await get_tree().process_frame
	_runtime().emit_trace("storage_mouse_fallback", "SmokeScenarios", {"reason": "direct _on_entry_clicked call alongside the synthesized GUI event; the mid-confirm gate is the assertion target (item_clicked is gone with the restyle)"})
	_screen()._on_entry_clicked(row, Vector2.ZERO, 1)


# One-frame press+release: drives _unhandled_input; can never fire a Main poll
# (the house injection rule; input_gate's header).
func _press(action: String) -> void:
	SmokeTap.inject_press(action)
	SmokeTap.inject_release(action)
	await get_tree().create_timer(0.08).timeout


func _ensure(ok: bool, label: String) -> bool:
	if not ok:
		_failures.append(label)
	return ok


func _idx(species_id: String) -> int:
	for i in range(_runtime().session.party.size()):
		if str((_runtime().session.party[i] as Dictionary).get("species_id", "")) == species_id:
			return i
	return -1


func _world() -> Node: return _ctx["world"]
func _player() -> Node: return _ctx["player"]
func _runtime() -> Node: return _ctx["runtime"]
func _message_box() -> Node: return _ctx["message_box"]
func _screen() -> Node: return _message_box().get_node_or_null("../StorageScreen")
