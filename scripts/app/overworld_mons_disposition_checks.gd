extends Node

# Phase-6 disposition TAILS (the overworld_mons_checks split for the app line budget;
# the breed_flow_checks precedent): flee -> despawn after FLEE_STEPS, the irritable
# double-interact warning -> chase, the chase counter under the RIDE gait, and the
# CHASE_RADIUS drop + window re-derivation. Entities are INJECTED into the runtime's
# store (the checks already poke it — the reset_entities precedent) with a species the
# LIVE _disposition_now oracle confirms, so every case is deterministic under the seed.
# Constants MIRROR the domain (app may not preload domain — scenario-contract mirrors).

const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")
const VisualSweepBaselines := preload("res://scripts/app/visual_sweep_baselines.gd")

const DAY_MINUTES := 600
const CELL_SIZE := 8 # mirrors OverworldMons.CELL_SIZE
const FLEE_STEPS := 6 # mirrors OverworldMons.FLEE_STEPS
const CHASE_RADIUS := 8 # mirrors OverworldMons.CHASE_RADIUS
const DESPAWN_CELLS := 3 # mirrors OverworldMons.DESPAWN_CELLS
const ADJACENT := Vector2i(1, 0)
# Slot-presence contract mirrors (OverworldMons): the respot check repositions onto a cell
# with a derivable roamer, since the slice-4 beach spawn can land in an entity-sparse patch.
const SALT_PRESENT := 0x1 # mirrors OverworldMons.SALT_PRESENT
const SPAWN_PRESENT_PCT := 25 # mirrors OverworldMons.SPAWN_PRESENT_PCT
const SLOTS_PER_CELL := 1 # mirrors OverworldMons.SLOTS_PER_CELL
const _K0 := 0x6C62272E07BB0142; const _K1 := 0x62B821756295C58D # mirrors OverworldMons SplitMix
const _K2 := 0x4A5A6B2D0E8F3C97; const _K3 := 0x5851F42D4C957F2D
const _MASK := 0x7FFFFFFFFFFFFFFF

var _ctx: Dictionary = {}
var _runner = SmokeScenarioRunner.new()
var _baselines = VisualSweepBaselines.new()
var _failures: Array = []
var _seed: int = 0
var _next_id := 0


func setup(ctx: Dictionary, runner: SmokeScenarioRunner, failures: Array, seed: int) -> void:
	_ctx = ctx; _runner = runner; _failures = failures; _seed = seed


func run_cases(runtime, mons) -> bool:
	var start := _failures.size() # scoped verdict: the shared array may carry older groups' failures
	if not _craft(runtime, mons):
		return _ensure(false, "disposition: the crafted state failed")
	_run_flee_despawn(runtime, mons)
	_run_irritable_chase(runtime, mons)
	_run_ride_gait_chase(runtime, mons)
	_run_despawn_respot(runtime, mons)
	return _failures.size() == start


# --- flee -> despawn: a TIMID roamer flees an adjacent player and un-materializes ----

func _run_flee_despawn(runtime, mons) -> void:
	_reset(mons)
	var species := _species_for_disposition(runtime, mons, "TIMID")
	if not _ensure(not species.is_empty(), "flee: no TIMID species resolves under the live disposition oracle"):
		return
	var tile: Vector2i = _player().tile_position + ADJACENT
	var entity_id := _inject(mons, species, tile, "TIMID")
	runtime.note_player_step() # step_triggers: an adjacent timid roamer turns fleeing
	if not _ensure(mons._entities.has(entity_id), "flee: the timid roamer vanished before fleeing"):
		return
	_ensure(str(mons._entities[entity_id].get("state", "")) == "fleeing", "flee: the adjacent timid roamer did not flee")
	for _i in range(FLEE_STEPS + 1):
		runtime.note_player_step()
	_ensure(not mons._entities.has(entity_id), "flee: the roamer survived %d steps past FLEE_STEPS=%d (no despawn)" % [FLEE_STEPS + 1, FLEE_STEPS])


# --- irritable double-interact: wary warning, then the lunge (state -> chasing) ------

func _run_irritable_chase(runtime, mons) -> void:
	_reset(mons)
	var species := _species_for_disposition(runtime, mons, "IRRITABLE")
	if not _ensure(not species.is_empty(), "chase: no IRRITABLE species resolves under the live disposition oracle"):
		return
	var tile: Vector2i = _player().tile_position + ADJACENT
	var entity_id := _inject(mons, species, tile, "IRRITABLE")
	var wary: Dictionary = mons.interact(tile)
	_ensure(str(wary.get("reason", "")) == "wary", "chase: the first irritable interact was not the wary warning (%s)" % str(wary.get("reason", "")))
	var cursor: int = _runner.trace_log_line_count()
	var lunge: Dictionary = mons.interact(tile) # inside INTERACT_MEMORY_STEPS: the consecutive interact
	_ensure(str(lunge.get("reason", "")) == "provoked", "chase: the second interact did not provoke (%s)" % str(lunge.get("reason", "")))
	_ensure(mons._entities.has(entity_id) and str(mons._entities[entity_id].get("state", "")) == "chasing", "chase: the provoked irritable never entered the chasing state")
	_ensure(_runner.trace_log_has_since("mon_provoked", cursor, {"cause": "interact"}), "chase: no mon_provoked{cause:interact} trace")


# --- the chase counter holds under the RIDE gait, then drops past CHASE_RADIUS -------

func _run_ride_gait_chase(runtime, mons) -> void:
	_reset(mons)
	var species := _species_for_disposition(runtime, mons, "IRRITABLE")
	if not _ensure(not species.is_empty(), "ride_chase: no IRRITABLE species resolves under the live disposition oracle"):
		return
	var tile: Vector2i = _player().tile_position + ADJACENT
	var entity_id := _inject(mons, species, tile, "IRRITABLE")
	mons.interact(tile)
	mons.interact(tile)
	if not _ensure(mons._entities.has(entity_id) and str(mons._entities[entity_id].get("state", "")) == "chasing", "ride_chase: the provoke never armed a chase"):
		return
	_player()._mounted = true # the ride gait (player_avatar's speed mode)
	_runner.teleport_player(_world(), _player(), runtime, tile + Vector2i(CHASE_RADIUS - 2, 0))
	runtime.note_player_step()
	_ensure(mons._entities.has(entity_id) and str(mons._entities[entity_id].get("state", "")) == "chasing", "ride_chase: the chase dropped INSIDE CHASE_RADIUS=%d under the ride gait" % CHASE_RADIUS)
	_runner.teleport_player(_world(), _player(), runtime, tile + Vector2i(CHASE_RADIUS + 3, 0))
	runtime.note_player_step() # the chaser steps once closer and is still beyond the radius -> drop
	_ensure(mons._entities.has(entity_id) and str(mons._entities[entity_id].get("state", "")) == "idle", "ride_chase: the chase held PAST CHASE_RADIUS=%d (the drop gate broke)" % CHASE_RADIUS)
	_player()._mounted = false


# --- despawn hygiene + window re-derivation: out-of-band gone, back in band re-spawn -

func _run_despawn_respot(runtime, mons) -> void:
	_reset(mons)
	var home: Vector2i = _entity_home(_player().tile_position) # slice-4: the beach spawn can land in an entity-sparse patch; reposition onto a cell with a derivable roamer so re-derivation is observable
	_runner.teleport_player(_world(), _player(), runtime, home)
	var far_tile: Vector2i = home + Vector2i(CELL_SIZE * (DESPAWN_CELLS + 2), 0)
	var entity_id := _inject(mons, "MACHOP", far_tile, "FRIENDLY") # species-neutral: sync_window's distance gate is disposition-blind
	runtime.note_player_step() # sync_window un-materializes anything past DESPAWN_CELLS
	_ensure(not mons._entities.has(entity_id), "respot: an out-of-band entity survived sync_window")
	var live_before: int = mons.live_entities_in(Rect2i(home - Vector2i(16, 16), Vector2i(32, 32))).size()
	var probe = load("res://scripts/runtime/overworld_mons_probe.gd").new()
	var cursor: int = _runner.trace_log_line_count()
	for _i in range(4): # the in-band window re-derives its slots off the step clock
		runtime.note_player_step()
	var live_after: int = mons.live_entities_in(Rect2i(home - Vector2i(16, 16), Vector2i(32, 32))).size()
	# Legitimate deltas (never a re-derivation failure): a timid may flee OUT (traced), and a
	# home cell straddling the audit rect's edge jitters its leashed roamer in/out by at most 2.
	var fled: int = probe.trace_count(cursor, "overworld_mon_despawned", {"reason": "fled"})
	_ensure(live_after >= 1 and live_after >= live_before - 2 - fled, "respot: the window around the player never re-derived live entities (%d -> %d, fled %d)" % [live_before, live_after, fled])


# --- harness: crafted state, injection, the live disposition oracle ------------------

func _craft(runtime, mons) -> bool:
	var spec := {"world_seed": _seed, "time_of_day": DAY_MINUTES, "bag": {}, "party": [["RHYPERIOR", 50], ["CHARIZARD", 50], ["MACHOP", 50], ["CALYREX", 50], ["DEDENNE", 50], ["DRAPION", 50]]}
	var ok := _baselines.craft_state(_ctx, _runner, spec)
	if ok:
		runtime.session.repel_steps = 0
		_reset(mons)
	return ok


func _reset(mons) -> void: # the overworld_mons_checks.reset_entities precedent
	mons._entities.clear(); mons._removed.clear(); mons._nests_found.clear(); mons._pool_cache.clear()
	mons._pending = {}; mons._pending_id = ""; mons._last_battle_was_entity = false
	mons._time_label = ""; mons._faced_tile = Vector2i.MAX; mons._last_interact_id = ""; mons._last_interact_step = -100
	mons.active = true


# Inject a synthetic entity shaped like overworld_mons_sim.new_mon's record; the
# disposition is confirmed against the runtime's LIVE oracle, not the record field.
func _inject(mons, species_id: String, tile: Vector2i, disposition: String) -> String:
	_next_id += 1
	var entity_id := "qa_disp_%d" % _next_id
	var cell := Vector2i(_floor_div(tile.x, CELL_SIZE), _floor_div(tile.y, CELL_SIZE))
	mons._entities[entity_id] = {"id": entity_id, "species_id": species_id, "kind": "mon", "tile": tile, "cell": cell,
		"slot": 0, "disposition": disposition, "state": "idle", "level": 10, "is_shiny": false, "gender": "FEMALE",
		"flee_steps": 0, "pacify_steps": 0, "current_hp": 0, "attack_stages": 0, "swim_only": false}
	return entity_id


# First catalog species whose LIVE disposition (biome + time label + catalog) matches —
# the same oracle interact/step_triggers consult, so the case never rides a stale field.
func _species_for_disposition(runtime, mons, wanted: String) -> String:
	var probe := {"species_id": "", "tile": _player().tile_position + ADJACENT}
	var species_map: Variant = runtime.catalog.species
	var ids: Array = (species_map as Dictionary).keys() if species_map is Dictionary else []
	for species_id in ids:
		probe["species_id"] = str(species_id)
		if mons._disposition_now(probe) == wanted:
			return str(species_id)
	return ""


# The nearest cell (ring-ordered, deterministic) with a derivable roamer slot, its center
# as the return tile; falls back to the start tile when nothing presents within 6 cells.
func _entity_home(start: Vector2i) -> Vector2i:
	var home_cell: Vector2i = Vector2i(_floor_div(start.x, CELL_SIZE), _floor_div(start.y, CELL_SIZE))
	for radius in range(0, 7):
		for cy in range(home_cell.y - radius, home_cell.y + radius + 1):
			for cx in range(home_cell.x - radius, home_cell.x + radius + 1):
				if radius > 0 and maxi(absi(cx - home_cell.x), absi(cy - home_cell.y)) != radius:
					continue
				var cell := Vector2i(cx, cy)
				if _slot_present(cell):
					return cell * CELL_SIZE + Vector2i(CELL_SIZE / 2, CELL_SIZE / 2)
	return start

func _slot_present(cell: Vector2i) -> bool: # mirrors OverworldMons.is_slot_present(cell, slot 0)
	var a := cell.x
	var b := cell.y * maxi(1, SLOTS_PER_CELL) + 0
	return _mix(_seed, a, b, SALT_PRESENT) % 100 < SPAWN_PRESENT_PCT

func _mix(world_seed: int, a: int, b: int, salt: int) -> int: # mirrors OverworldMons._mix SplitMix64
	var h := (world_seed * _K0 + a * _K1 + b * _K2 + salt * _K3) & _MASK
	h = ((h ^ (h >> 30)) * _K0) & _MASK
	h = ((h ^ (h >> 27)) * _K1) & _MASK
	return (h ^ (h >> 31)) & _MASK

func _floor_div(value: int, divisor: int) -> int:
	return int(floor(float(value) / float(divisor)))


func _ensure(ok: bool, label: String) -> bool:
	if not ok:
		_failures.append(label)
	return ok


func _world() -> Node: return _ctx["world"]
func _player() -> Node: return _ctx["player"]
