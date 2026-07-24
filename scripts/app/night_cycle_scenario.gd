extends Node

# Night-danger scenario (Phase 2 night survival; spec:
# docs/product-specs/camping-crafting-survival.md). Proves the night loop on the
# seed-pinned shared rng: unlit night draws spawn Ghosts (night_hazard_spawned);
# a lit campfire, an extinguish-then-relight contrast, a torch and a Flash-capable
# (Fire) party member each zero the hazards; a shadow battle blocks retreat exactly
# once (retreat_blocked) then ends by victory; dawn clears the hazard; and the
# nocturnal filter + clock-boundary proofs ride night_cycle_checks.gd (the
# placement_flow -> placement_flow_demolition split pattern). Deterministic: ghost
# rolls ride runtime._rng, placements are cleared for a crafted dark start, and
# the dispatcher's save guard restores the real save.

const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")
const NightCycleChecks := preload("res://scripts/app/night_cycle_checks.gd")

const SEED := 2026072303
const DRAWS := 40
const NIGHT_MINUTES := 1380
const DAY_MINUTES := 600
const FAR_OFFSET := Vector2i(12, 12) # beyond LIGHT_RADIUS (4) of every placed light

var _ctx: Dictionary = {}
var _runner = SmokeScenarioRunner.new()
var _checks = NightCycleChecks.new()
var _failures: Array = []


func run(ctx: Dictionary) -> void:
	_ctx = ctx
	_checks.setup(ctx, _runner, _failures)
	await get_tree().create_timer(0.2).timeout
	var runtime = _runtime()
	runtime.seed_for_smoke(SEED)
	var saved_chance: float = _player().encounter_chance
	_player().encounter_chance = 0.0
	var party_before: Array = _runner.swap_party(runtime, ["MACHOP"], 30) # FIGHTING: Build-capable, no Flash light
	# Crafted dark state: no placed light anywhere (a loaded save may carry one;
	# in-memory only — the save guard restores the file).
	runtime._world_gen.clear_placements()
	runtime.session.time_of_day_minutes = NIGHT_MINUTES
	var dark_ghosts := _draw_ghosts("dark", true)
	var lit_clean := _check_campfire_phases()
	var torch_clean := _check_torch()
	var flash_clean := _check_flash()
	var shadow_blocked := _check_shadow_battle()
	var dawn_clean := _check_dawn()
	var umbreon_night := _checks.check_nocturnal_filter()
	var boundary_ok := _checks.check_boundaries()
	if _failures.is_empty():
		runtime.emit_trace("night_cycle_passed", "SmokeScenarios", {"dark_ghosts": dark_ghosts,
			"lit_clean": lit_clean, "torch_clean": torch_clean, "flash_clean": flash_clean,
			"shadow_blocked": shadow_blocked, "dawn_clean": dawn_clean,
			"umbreon_night": umbreon_night, "boundary_ok": boundary_ok})
	else:
		runtime.emit_trace("night_cycle_failed", "SmokeScenarios", {"failures": _failures})
		runtime.warn("NightCycleScenario", "Night cycle failed: %s." % "; ".join(PackedStringArray(_failures)), {})
	_runner.restore_party(runtime, party_before)
	_player().encounter_chance = saved_chance


# DRAWS encounter draws since a fresh cursor; returns the night_hazard_spawned
# count. expect=false fails on ANY hazard (lit/dawn draws consume no ghost rng,
# so a clean run is structural, not lucky).
func _draw_ghosts(label: String, expect_hazard: bool) -> int:
	if not _failures.is_empty():
		return 0
	var runtime = _runtime()
	var cursor := _runner.trace_log_line_count()
	var biome = _world().get_tile_biome(runtime.session.player_tile)
	for _i in range(DRAWS):
		runtime.generate_wild_encounter(runtime.session.player_tile, biome)
	var hazards := _checks.count_since("night_hazard_spawned", cursor)
	if expect_hazard and hazards == 0:
		_failures.append("%s: %d draws spawned no shadow Ghost" % [label, DRAWS])
	elif not expect_hazard and hazards != 0:
		_failures.append("%s: %d hazard draws where none may happen" % [label, hazards])
	return hazards


# Lit campfire adjacent to the player kills the hazard; extinguishing (additive
# "lit": false field) restarts it; relighting (field erased) clears it again.
# Left extinguished so the torch + Flash checks run against a dark campfire.
func _check_campfire_phases() -> bool:
	if not _failures.is_empty():
		return false
	var runtime = _runtime()
	runtime.session.add_item("log", 4)
	runtime.session.add_item("dry_soil", 2)
	var fire_tile := _find_open_tile(runtime.session.player_tile)
	var placed: Dictionary = runtime.build_runtime.try_place(fire_tile, "campfire", {}) if fire_tile != Vector2i.ZERO else {"ok": false, "reason": "no_site"}
	if not bool(placed.get("ok", false)):
		_failures.append("lit: campfire refused (%s)" % str(placed.get("reason", "")))
		return false
	_draw_ghosts("lit", false)
	var entry: Dictionary = runtime._world_gen._placements[fire_tile]
	# Presentation: the stamped sprite frame must follow the lit field, so an
	# extinguished fire reads unlit (world_overrides.apply_placement threads it).
	var lit_region: Variant = runtime._world_gen.get_tile_logic(fire_tile).get("prop_region")
	entry["lit"] = false
	if runtime._world_gen.get_tile_logic(fire_tile).get("prop_region") == lit_region:
		_failures.append("sprite: an extinguished campfire still stamps the lit frame")
	_draw_ghosts("extinguished", true)
	entry.erase("lit")
	if runtime._world_gen.get_tile_logic(fire_tile).get("prop_region") != lit_region:
		_failures.append("sprite: relighting did not restore the lit frame")
	_draw_ghosts("relit", false)
	entry["lit"] = false
	return _failures.is_empty()


# The always-lit torch (campfire extinguished) clears the dark on its own.
func _check_torch() -> bool:
	if not _failures.is_empty():
		return false
	var runtime = _runtime()
	runtime.session.add_item("log", 1)
	runtime.session.add_item("dry_soil", 1)
	var torch_tile := _find_open_tile(runtime.session.player_tile)
	var placed: Dictionary = runtime.build_runtime.try_place(torch_tile, "torch", {}) if torch_tile != Vector2i.ZERO else {"ok": false, "reason": "no_site"}
	if not bool(placed.get("ok", false)):
		_failures.append("torch: placement refused (%s)" % str(placed.get("reason", "")))
		return false
	_draw_ghosts("torch", false)
	return _failures.is_empty()


# Beyond every placed light, a Fire-type (CHARMANDER; AUTO_TYPES flash->FIRE) is
# passive light on its own; swapping back to MACHOP darkens the tile again.
func _check_flash() -> bool:
	if not _failures.is_empty():
		return false
	var runtime = _runtime()
	_runner.teleport_player(_world(), _player(), runtime, runtime.session.player_tile + FAR_OFFSET)
	_draw_ghosts("dark-again", true) # sanity: the moved player stands in the dark
	if not _failures.is_empty():
		return false
	_runner.swap_party(runtime, ["CHARMANDER"], 30)
	_draw_ghosts("flash", false)
	_runner.swap_party(runtime, ["MACHOP"], 30)
	return _failures.is_empty()


# A hazard draw started while pending is a shadow battle: retreat is blocked for
# its whole duration (retreat_blocked traced exactly once), then victory ends it.
func _check_shadow_battle() -> bool:
	if not _failures.is_empty():
		return false
	var runtime = _runtime()
	var ghost: Dictionary = _draw_until_shadow()
	if ghost.is_empty():
		_failures.append("shadow: no hazard draw within 400 attempts")
		return false
	var cursor := _runner.trace_log_line_count()
	runtime.start_wild_battle(ghost)
	var escape: Dictionary = runtime.run_from_battle()
	if bool(escape.get("finished", true)) or str(escape.get("outcome", "")) == "escaped":
		_failures.append("shadow: retreat escaped a shadow battle (%s)" % str(escape))
	elif not _runner.trace_log_has_since("retreat_blocked", cursor, {"species_id": str(ghost.get("species_id", ""))}):
		_failures.append("shadow: no retreat_blocked trace")
	elif _checks.count_since("retreat_blocked", cursor) != 1:
		_failures.append("shadow: retreat_blocked traced more than once")
	elif bool(runtime.run_from_battle().get("finished", true)):
		_failures.append("shadow: the second retreat attempt got away")
	else:
		_checks.finish_by_victory(cursor)
	return _failures.is_empty()


func _check_dawn() -> bool:
	if not _failures.is_empty():
		return false
	_runtime().session.time_of_day_minutes = DAY_MINUTES
	_draw_ghosts("dawn", false)
	return _failures.is_empty()


# Draws until a hazard trace lands (the pending-shadow mark), returning that mon.
func _draw_until_shadow() -> Dictionary:
	var runtime = _runtime()
	var biome = _world().get_tile_biome(runtime.session.player_tile)
	for _i in range(400):
		var cursor := _runner.trace_log_line_count()
		var mon: Dictionary = runtime.generate_wild_encounter(runtime.session.player_tile, biome)
		if _checks.count_since("night_hazard_spawned", cursor) > 0 and not mon.is_empty():
			return mon
	return {}


func _find_open_tile(center: Vector2i) -> Vector2i:
	for ring in range(1, 9):
		for tile in _runner.ring_around(center, ring):
			var logic: Dictionary = _world().get_tile_logic(tile)
			if bool(logic.get("walkable", false)) and str(logic.get("prop_path", "")).is_empty() \
				and str(logic.get("structure_id", "")).is_empty():
				return tile
	return Vector2i.ZERO


func _world() -> Node: return _ctx["world"]
func _player() -> Node: return _ctx["player"]
func _runtime() -> Node: return _ctx["runtime"]
