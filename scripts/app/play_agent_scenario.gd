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
const PlayAgentClimb := preload("res://scripts/app/play_agent_climb.gd")

const PIN := PlayAgentClimb.PIN
const WORLD_SEED := PlayAgentClimb.WORLD_SEED
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
	await PlayAgentClimb.new().drive(self, _ctx, _runner, _failures)
	if _failures.is_empty():
		await _drive_overworld_step()
	if _failures.is_empty():
		_check_inventory()
	if _failures.is_empty():
		await _capture_snapshot()
	_restore()
	_finish()

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
func _world() -> Node: return _ctx["world"]
func _player() -> Node: return _ctx["player"]
func _runtime() -> Node: return _ctx["runtime"]
