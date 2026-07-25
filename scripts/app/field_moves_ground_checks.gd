extends Node

# Phase 4 field-move checks, group B — repel / power / charm+attack (spec:
# docs/product-specs/field-moves.md). Companion to field_moves_flow_scenario; group A
# (flash/teleport/ride/fly) lives in field_moves_checks.gd. Same house style: drives
# the field_move_runtime callers through the public runtime seam, asserts a happy
# path AND a refusal per move, seed-pinned + encounters zeroed by the orchestrator,
# failures accumulate in the shared _failures array.
#
# REPEL determinism: the proof is STRUCTURAL, not lucky — repel short-circuits
# game_runtime.generate_wild_encounter BEFORE it consumes any encounter rng, so a
# re-seeded stream that yields encounters with repel OFF yields EXACTLY zero with it
# on (the night_cycle lit-draws-consume-no-rng pattern). The counter rides
# session_state.repel_steps and decays one per overworld step (note_step_taken).
#
# CHARM/ATTACK are HOOKS: they trace + (charm) level-gate a pacify, but the overworld
# Pokemon ENTITIES they target land in Phase 6 — so the checks assert the hook fires
# (a Phase-6 plug-in callable) and the trace is well-formed, never entity behavior.

const FieldMovesParty := preload("res://scripts/runtime/field_moves_party.gd")

const BOULDER_ID := "boulder" # structures.gd literal (app cannot preload domain)
const DAY_MINUTES := 600
const DRAWS := 6

var _ctx: Dictionary = {}
var _runner = null
var _failures: Array = []
var _seed := 0


func setup(ctx: Dictionary, runner, failures: Array, seed: int) -> void:
	_ctx = ctx
	_runner = runner
	_failures = failures
	_seed = seed


# --- REPEL: a seeded encounter that WOULD fire is suppressed for N steps --------

func check_repel() -> void:
	var runtime = _runtime()
	runtime.session.time_of_day_minutes = DAY_MINUTES # daytime: no ghost draws perturb the stream
	var steps := DRAWS
	runtime.session.repel_steps = 0 # CONTROL (repel off): the seeded stream yields encounters
	runtime.seed_for_smoke(_seed)
	_ensure(_draw_nonempty(steps) >= 1, "repel: the seeded control stream produced no encounter (nothing to suppress)")
	var cursor: int = _runner.trace_log_line_count()
	var active: Dictionary = runtime.field_move_runtime.activate_repel(steps)
	_ensure(bool(active.get("ok", false)) and int(active.get("steps", 0)) == steps, "repel: activate_repel did not set %d steps" % steps)
	_ensure(_runner.trace_log_has_since("repel_active", cursor, {"steps": steps}), "repel: no repel_active trace")
	_ensure(runtime.field_move_runtime.repel_suppresses(), "repel: repel_suppresses is false right after activation")
	runtime.seed_for_smoke(_seed) # re-seeded: the SAME stream yields EXACTLY zero while repel is active
	_ensure(_draw_nonempty(steps) == 0, "repel: an encounter fired while repel was active")
	for _i in range(steps): # decay: N overworld steps exhaust the counter
		runtime.note_player_step()
	_ensure(runtime.session.repel_steps == 0 and not runtime.field_move_runtime.repel_suppresses(), "repel: the counter did not decay to zero after %d steps" % steps)
	runtime.seed_for_smoke(_seed)
	_ensure(_draw_nonempty(steps) >= 1, "repel: encounters did not resume after the counter expired")
	var party_before: Array = _runner.swap_party(runtime, ["MACHOP"], FieldMovesParty.PARTY_LEVEL)
	_ensure(not bool(runtime.field_move_runtime.activate_repel(steps).get("ok", true)), "repel: a non-repel party activated repel")
	_runner.restore_party(runtime, party_before)
	runtime.session.repel_steps = 0


# --- POWER: push a movable boulder one tile; refuse with no faced boulder -------

func check_power() -> void:
	var runtime = _runtime()
	var pair := _find_boulder_pair(runtime.session.player_tile)
	if pair.is_empty():
		_failures.append("power: no pushable boulder site within scan"); return
	var from: Vector2i = pair["from"]; var dir: Vector2i = pair["dir"]; var to: Vector2i = from + dir
	_ensure(bool(runtime.field_move_runtime.place_boulder(from).get("ok", false)), "power: place_boulder refused")
	_ensure(_is_boulder(_world().get_tile_logic(from)) and not _world().is_tile_walkable(from), "power: the seeded boulder is not a solid prop")
	var cursor: int = _runner.trace_log_line_count()
	var push: Dictionary = runtime.field_move_runtime.use_power(from, dir)
	_ensure(bool(push.get("ok", false)) and push.get("to") == to, "power: use_power did not push the boulder one tile")
	_ensure(_runner.trace_log_has_since("power_used", cursor, {"from": [from.x, from.y], "to": [to.x, to.y]}), "power: no power_used trace")
	_ensure(not _is_boulder(_world().get_tile_logic(from)) and _world().is_tile_walkable(from), "power: the source tile still holds the boulder")
	_ensure(_is_boulder(_world().get_tile_logic(to)), "power: the destination tile did not receive the boulder")
	cursor = _runner.trace_log_line_count() # refusal: no faced boulder
	_ensure(not bool(runtime.field_move_runtime.use_power(from, dir).get("ok", true)), "power: a push with no faced boulder succeeded")
	_ensure(_runner.trace_log_has_since("field_move_refused", cursor, {"move_id": "power", "reason": "no_boulder"}), "power: no no_boulder refusal trace")
	_runner.save_and_reload(_world(), runtime) # the pushed boulder rides the structures save key
	_ensure(_is_boulder(_world().get_tile_logic(to)), "power: the pushed boulder did not survive the save")


# --- CHARM / ATTACK: Phase-6 hooks fire + trace; no overworld entities yet ------

func check_attack() -> void:
	var fmr = _runtime().field_move_runtime
	var attacked: Array = []
	fmr.overworld_attack_hook = Callable(self, "_record_attack").bind(attacked)
	var cursor: int = _runner.trace_log_line_count() # ATTACK hook fires + traces
	var atk: Dictionary = fmr.use_attack("RATTATA")
	_ensure(bool(atk.get("ok", false)), "attack: use_attack refused with a target")
	_ensure(_runner.trace_log_has_since("overworld_attack", cursor, {"target_species_id": "RATTATA"}), "attack: no overworld_attack trace")
	_ensure(attacked == ["RATTATA"], "attack: the Phase-6 attack hook was not invoked")
	cursor = _runner.trace_log_line_count()
	_ensure(not bool(fmr.use_attack("").get("ok", true)), "attack: an empty target was accepted")
	_ensure(_runner.trace_log_has_since("field_move_refused", cursor, {"move_id": "attack", "reason": "no_target"}), "attack: no no_target refusal trace")
	fmr.overworld_attack_hook = Callable()


func check_charm() -> void:
	var fmr = _runtime().field_move_runtime
	var charmed: Array = []
	fmr.overworld_charm_hook = Callable(self, "_record_charm").bind(charmed)
	# Level-gated pacify: Dedenne is level 50 => pacifies a level-5 mon, not level 999.
	var cursor: int = _runner.trace_log_line_count()
	var low: Dictionary = fmr.use_charm("RATTATA", 5)
	_ensure(bool(low.get("ok", false)) and bool(low.get("pacified", false)), "charm: a level-5 target was not pacified by the level-50 user")
	_ensure(_runner.trace_log_has_since("charm_used", cursor, {"target_species_id": "RATTATA", "level_gate_met": true}), "charm: no charm_used{level_gate_met:true} trace")
	cursor = _runner.trace_log_line_count()
	var high: Dictionary = fmr.use_charm("RATTATA", 999)
	_ensure(bool(high.get("ok", false)) and not bool(high.get("pacified", true)), "charm: a level-999 target was pacified (level gate broken)")
	_ensure(_runner.trace_log_has_since("charm_used", cursor, {"target_species_id": "RATTATA", "level_gate_met": false}), "charm: no charm_used{level_gate_met:false} trace")
	_ensure(charmed.size() == 2, "charm: the Phase-6 charm hook was not invoked per use")
	cursor = _runner.trace_log_line_count()
	_ensure(not bool(fmr.use_charm("", 5).get("ok", true)), "charm: an empty target was accepted")
	_ensure(_runner.trace_log_has_since("field_move_refused", cursor, {"move_id": "charm", "reason": "no_target"}), "charm: no no_target refusal trace")
	fmr.overworld_charm_hook = Callable()


# bind() APPENDS the bound array after the call-time args, so the record is last.
func _record_attack(species_id: String, record: Array) -> void:
	record.append(species_id)


func _record_charm(species_id: String, _pacified: bool, record: Array) -> void:
	record.append(species_id)


# Non-empty wild encounters over `count` seeded draws off the shared runtime rng.
func _draw_nonempty(count: int) -> int:
	var runtime = _runtime()
	var biome = _world().get_tile_biome(runtime.session.player_tile)
	var hits := 0
	for _i in range(count):
		if not runtime.generate_wild_encounter(runtime.session.player_tile, biome).is_empty():
			hits += 1
	return hits


# A boulder site: an open tile `from` with an open destination `from + dir`.
func _find_boulder_pair(center: Vector2i) -> Dictionary:
	for ring in range(2, 30):
		for tile in _runner.ring_around(center, ring):
			if not _open(tile):
				continue
			for dir in [Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT, Vector2i.UP]:
				if _open(tile + dir):
					return {"from": tile, "dir": dir}
	return {}


func _open(tile: Vector2i) -> bool:
	var logic: Dictionary = _world().get_tile_logic(tile)
	return bool(logic.get("walkable", false)) and str(logic.get("prop_path", "")).is_empty() \
		and str(logic.get("structure_id", "")).is_empty()


func _is_boulder(logic: Dictionary) -> bool:
	return str(logic.get("structure_id", "")) == BOULDER_ID


func _ensure(ok: bool, label: String) -> bool:
	if not ok:
		_failures.append(label)
	return ok


func _world() -> Node: return _ctx["world"]
func _player() -> Node: return _ctx["player"]
func _runtime() -> Node: return _ctx["runtime"]
