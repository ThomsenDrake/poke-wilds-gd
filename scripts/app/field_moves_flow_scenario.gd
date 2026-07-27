extends Node

# Field-moves flow scenario (Phase 4; spec: docs/product-specs/field-moves.md).
# Proves the EIGHT Phase-4 field moves that previously had capability rules but ZERO
# runtime callers, driven by the all-field-moves playtest party (FieldMovesParty) and
# the field_move_runtime callers through the public runtime seam. cut/dig/smash/surf/
# build already have live callers (harvest_flow / placement_flow / the world_view surf
# gate) and are re-asserted there, not here.
#
# Determinism: seed_for_smoke pins both runtime rngs (the house convention); repel's
# suppression is proven STRUCTURALLY (a re-seeded stream that yields encounters with
# repel off yields exactly zero with it on). Encounters are zeroed on the avatar; the
# dispatcher's save guard restores the real save (in-memory crafted state — cleared
# placements, a registered way stone, a pushed boulder — dies with the app at quit).
#
# First act is the precondition WITNESS (FieldMovesParty.verify): the fixture must
# cover all 13 ported moves against the LIVE catalog, so any catalog/AUTO_TYPES drift
# fails LOUD instead of vacuously passing on a silently-short party. Per-move checks
# live in field_moves_checks.gd (flash/teleport/ride/fly) + field_moves_ground_checks.gd
# (repel/power/charm+attack) + field_moves_dig_checks.gd (Phase 5 dig acquisition:
# Beach pool faithful / divergent pool pinned / PLAINS control); each asserts a happy
# path AND a refusal.

const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")
const FieldMovesParty := preload("res://scripts/runtime/field_moves_party.gd")
const FieldMovesChecks := preload("res://scripts/app/field_moves_checks.gd")
const FieldMovesGroundChecks := preload("res://scripts/app/field_moves_ground_checks.gd")
const FieldMovesDigChecks := preload("res://scripts/app/field_moves_dig_checks.gd")

const SEED := 2026072501
const DAY_MINUTES := 600

var _ctx: Dictionary = {}
var _runner = SmokeScenarioRunner.new()
var _failures: Array = []
var _oks: Dictionary = {}


func run(ctx: Dictionary) -> void:
	_ctx = ctx
	await get_tree().create_timer(0.2).timeout
	var runtime = _runtime()
	runtime.seed_for_smoke(SEED)
	var saved_chance: float = _player().encounter_chance
	_player().encounter_chance = 0.0
	var party_before: Array = FieldMovesParty.swap_in(runtime)
	for problem in FieldMovesParty.verify(runtime):
		_failures.append("fixture: %s" % problem)
	var checks_a := FieldMovesChecks.new(); add_child(checks_a); checks_a.setup(_ctx, _runner, _failures, SEED)
	var checks_b := FieldMovesGroundChecks.new(); add_child(checks_b); checks_b.setup(_ctx, _runner, _failures, SEED)
	var checks_c := FieldMovesDigChecks.new(); add_child(checks_c); checks_c.setup(_ctx, _runner, _failures)
	var plan := [[checks_a, "check_flash", "flash_ok"], [checks_a, "check_teleport_waystone", "teleport_ok"],
		[checks_a, "check_ride", "ride_ok"], [checks_a, "check_fly", "fly_ok"],
		[checks_b, "check_repel", "repel_ok"], [checks_b, "check_power", "power_ok"],
		[checks_b, "check_attack", "attack_ok"], [checks_b, "check_charm", "charm_ok"],
		[checks_c, "check_dig_acquisition", "dig_acquisition_ok"]] # LAST: its step shifts sit downstream of every other check
	for entry in plan:
		if not _failures.is_empty():
			break
		var mark := _failures.size()
		await (entry[0] as Node).call(str(entry[1]))
		_oks[str(entry[2])] = _failures.size() == mark
	if _failures.is_empty():
		var payload: Dictionary = _oks.duplicate(); payload["seed"] = SEED
		runtime.emit_trace("field_moves_passed", "SmokeScenarios", payload)
	else:
		runtime.emit_trace("field_moves_failed", "SmokeScenarios", {"failures": _failures, "seed": SEED})
		push_error("FieldMovesFlowScenario failed: %s" % "; ".join(PackedStringArray(_failures)))
		runtime.warn("FieldMovesFlowScenario", "Field moves flow failed.", {})
	FieldMovesParty.restore(runtime, party_before)
	_player().encounter_chance = saved_chance
	_player().input_enabled = true
	runtime.session.repel_steps = 0
	runtime.session.time_of_day_minutes = DAY_MINUTES
	runtime.night_system.set_active_flash(false)


func _world() -> Node: return _ctx["world"]
func _player() -> Node: return _ctx["player"]
func _runtime() -> Node: return _ctx["runtime"]
