extends Node

# Time-of-day evolution scenario (Phase 2 night survival; spec:
# docs/product-specs/camping-crafting-survival.md). Proves battle_runtime threads
# the real clock into check_level_evolution's context (pokemon_rules stays
# untouched at budget): the gate must discriminate, not just fire. EEVEE
# (happiness 255) carries the contrast — its MORNDAY entry evolves to ESPEON in
# the DAY window and its NITE entry to UMBREON at NIGHT; SNOM carries the literal
# "DAY blocks, NIGHT fires" pair — its only evolution is NITE-gated FROSMOTH, so
# the identical seeded level-up leaves SNOM at DAY (evolved:"") and evolves it at
# NIGHT. Each battle traces evolution_time_gate with the real time_of_day label.
# Deterministic: seed pinned, exp set to exactly one seeded victory from a level,
# enemy pinned to 1 HP; the dispatcher's save guard restores the real save.
#
# DATA NOTE: the design framed the DAY case as "EEVEE stays EEVEE" — the asm data
# disproves that (EEVEE's MORNDAY->ESPEON entry passes in the DAY window since
# "MORNDAY" contains "DAY"), so SNOM is the no-evolve DAY witness instead and
# EEVEE's day ESPEON / night UMBREON split proves the gate both ways.

const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")

const SEED := 2026072304
const DAY_MINUTES := 600
const NIGHT_MINUTES := 1380
const BATTLE_LEVEL := 30

var _ctx: Dictionary = {}
var _runner = SmokeScenarioRunner.new()
var _failures: Array = []
var _gate_events := 0


func run(ctx: Dictionary) -> void:
	_ctx = ctx
	await get_tree().create_timer(0.2).timeout
	var runtime = _runtime()
	runtime.seed_for_smoke(SEED)
	var saved_chance: float = _player().encounter_chance
	_player().encounter_chance = 0.0
	var party_before: Array = runtime.session.party
	# EEVEE day/night: the same happiness-255 setup, two clock windows.
	var day_species := _evolution_probe("EEVEE", DAY_MINUTES, "ESPEON")
	var night_species := _evolution_probe("EEVEE", NIGHT_MINUTES, "UMBREON")
	# SNOM day/night: NITE-only gate — day must NOT evolve, night must.
	var snom_day := _evolution_probe("SNOM", DAY_MINUTES, "")
	var snom_night := _evolution_probe("SNOM", NIGHT_MINUTES, "FROSMOTH")
	if _failures.is_empty():
		runtime.emit_trace("time_evolution_passed", "SmokeScenarios", {"day_species": day_species,
			"night_species": night_species, "snom_day_species": snom_day,
			"snom_night_species": snom_night, "gate_events": _gate_events})
	else:
		runtime.emit_trace("time_evolution_failed", "SmokeScenarios", {"failures": _failures})
		runtime.warn("TimeEvolutionScenario", "Time evolution failed: %s." % "; ".join(PackedStringArray(_failures)), {})
	_runner.restore_party(runtime, party_before)
	_player().encounter_chance = saved_chance


# One proof: a fresh happiness-255 mon, one exp short of a level, wins a seeded
# battle in the given clock window; the species must land on `expect_target`
# ("" = no evolution) and the evolution_time_gate trace must carry the real
# time_of_day label with that exact evolved target. Returns the final species id.
func _evolution_probe(species_id: String, minutes: int, expect_target: String) -> String:
	if not _failures.is_empty():
		return ""
	var runtime = _runtime()
	runtime.session.time_of_day_minutes = minutes
	_prepare_mon(species_id)
	var label: String = runtime.session.time_of_day_label() # runtime surface over day_phase.gd
	var cursor := _runner.trace_log_line_count()
	if not _win_seeded_battle():
		return ""
	var final_id := str(runtime.session.get_party_member(0).get("species_id", ""))
	if final_id != expect_target and not (expect_target.is_empty() and final_id == species_id):
		_failures.append("%s@%s: evolved to '%s', not '%s'" % [species_id, label, final_id, expect_target])
	elif not _runner.trace_log_has_since("evolution_time_gate", cursor,
		{"species_id": species_id, "time_of_day": label, "evolved": expect_target}):
		_failures.append("%s@%s: no evolution_time_gate{%s -> %s} trace" % [species_id, label, label, expect_target])
	else:
		_gate_events += 1
	return final_id


# Fresh mon at BATTLE_LEVEL with happiness 255 and exp exactly one short of the
# next level, so any seeded victory (exp yield >= 1) levels it and fires the gate.
func _prepare_mon(species_id: String) -> void:
	var runtime = _runtime()
	_runner.swap_party(runtime, [species_id], BATTLE_LEVEL)
	var entry: Dictionary = runtime.catalog.get_species(species_id)
	var mon: Dictionary = runtime.session.get_party_member(0)
	mon["happiness"] = 255
	mon["exp"] = runtime.pokemon_rules.experience_for_level(BATTLE_LEVEL + 1, str(entry.get("growth_rate", "MEDIUM_FAST"))) - 1
	var moves: Array = mon.get("moves", [])
	var has_damage := false
	for move in moves:
		if int((move as Dictionary).get("power", 0)) > 0:
			has_damage = true
			break
	if not has_damage: # a status-only learnset would stall the forced win
		mon["moves"] = runtime.pokemon_rules.build_move_set(["TACKLE"], Callable(runtime.catalog, "get_move"))
	runtime.session.set_party_member(0, mon)
	_runner.refill_party_pp(runtime)


# Wild encounter -> battle with the enemy pinned to 1 HP -> a move ROTATION
# until the seeded victory: an immune hit (EEVEE's NORMAL moves never touch the
# Ghosts a night draw can bring in) leaves the 1-HP enemy standing and the
# rotation advances to the next slot. If no slot lands, the enemy's types are
# neutralized — a documented pin (the evolution gate reads levels/happiness and
# drops read the catalog entry, never _enemy_mon, so the pin is inert to
# everything the scenario proves).
func _win_seeded_battle() -> bool:
	var runtime = _runtime()
	var session = runtime.session
	var wild: Dictionary = runtime.generate_wild_encounter(session.player_tile, _world().get_tile_biome(session.player_tile))
	if wild.is_empty():
		_failures.append("battle: could not create a wild encounter")
		return false
	runtime.start_wild_battle(wild)
	var enemy: Dictionary = runtime.battle_runtime._enemy_mon
	enemy["current_hp"] = 1
	var result: Dictionary = _rotate_to_finish(runtime, enemy)
	if str(result.get("outcome", "")) != "victory":
		_failures.append("battle: ended '%s', not victory" % str(result.get("outcome", "")))
		return false
	return true


func _rotate_to_finish(runtime, enemy: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	var moves: Array = runtime.battle_runtime._player_mon.get("moves", [])
	for i in range(moves.size()):
		if int((moves[i] as Dictionary).get("power", 0)) > 0:
			result = runtime.perform_battle_move(i)
			if bool(result.get("finished", false)):
				return result
	enemy["types"] = PackedStringArray(["NORMAL", "NORMAL"]) # immunity pin
	for _i in range(4):
		result = runtime.perform_battle_move(_damaging_move_index(runtime.battle_runtime._player_mon))
		if bool(result.get("finished", false)):
			return result
	return result


func _damaging_move_index(mon: Dictionary) -> int:
	var moves: Array = mon.get("moves", [])
	for i in range(moves.size()):
		if int((moves[i] as Dictionary).get("power", 0)) > 0 and int((moves[i] as Dictionary).get("pp", 0)) > 0:
			return i
	return 0


func _world() -> Node: return _ctx["world"]
func _player() -> Node: return _ctx["player"]
func _runtime() -> Node: return _ctx["runtime"]
