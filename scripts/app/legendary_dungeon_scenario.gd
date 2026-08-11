extends Node

# Legendary-dungeon scenario (the legendary-dungeon slice; spec: docs/product-specs/
# world-depth.md § Legendaries). The DUNGEON LOOP gate, self-pinned seed_for_smoke(SEED)
# -> new_game -> rebuild (the legendary_spawn precedent — the same SEED so the anchor
# derivation is byte-identical and all seven entrances resolve under the climate field).
# Lanes (the checks split into legendary_dungeon_checks.gd at the app-220 wall):
#   (a) entrances stamp at exactly the seven pinned anchors (the SAME sibling-exclusion
#       derivation as legendary_spawn's anchor pin — the resolver serves a warp+dungeon_id
#       entrance cell on each anchor) with pairwise-DISTINCT warp tiles;
#   (b) warp ROUND-TRIP on REGISTEEL through REAL avatar steps (smoke_step -> tile_changed
#       -> main.gd's mid-step re-home): entrance warp -> dungeon spawn (active_area set,
#       dungeon_entered), exit tile -> back on the entrance warp (active_area cleared,
#       dungeon_exited{reason: exit});
#   (c) the chamber legendary stands on the dungeon-local chamber tile and NOT in the
#       overworld (no retired "legendary_0,0:*" boot static);
#   (d)+(f) catch REGIROCK (checks file): tablet_claimed fires EXACTLY once, the removal
#       key lands in legendary_removals, re-entry finds the chamber empty forever;
#   (e) KO REGICE (checks file): NO tablet, legendary_kos logs the key at total_steps, the
#       re-entry suppresses while the cooldown runs and the chamber re-stands FRESH only
#       after REGI_RESTAND_STEPS (advanced synthetically);
#   (g) the Regigigas SEAL ladder (checks file): 0..4 tablets refuse with
#       dungeon_entry_refused + the shrinking missing list, all five open the warp, and
#       the tablets are NEVER consumed;
#   (h) overworld sim SUPPRESSION: with mons.active forced ON, note_player_step inside a
#       dungeon spawns nothing at dungeon-local coords (the in_dungeon gate);
#   (i) in-dungeon field-action refusals (checks file): teleport/fly trace
#       field_move_refused{reason: in_dungeon}, build traces structure_refused{in_dungeon},
#       harvest/dig refuse message-only ("The cave walls resist the move.");
#   (j) legendary_kos + active_area survive the to_save_payload/apply_into round-trip into
#       a FRESH session (the roundtrip_removal precedent).
# Emits the registry pair legendary_dungeon_passed/legendary_dungeon_failed (miss-002).

const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")
const OverworldMonsRuntime := preload("res://scripts/runtime/overworld_mons_runtime.gd")
const DungeonRuntime := preload("res://scripts/runtime/dungeon_runtime.gd") # rides its domain preloads (the layer table; the legendary_spawn precedent)
const LegendarySpawnChecks := preload("res://scripts/app/legendary_spawn_checks.gd") # the anchor-set pin (the same derivation, the same seed)
const LegendaryDungeonChecks := preload("res://scripts/app/legendary_dungeon_checks.gd")
const LegendaryDungeonJourneyChecks := preload("res://scripts/app/legendary_dungeon_journey_checks.gd")
const LegendaryPlacement := OverworldMonsRuntime.LegendaryPlacement
const DungeonMaps := DungeonRuntime.DungeonMaps

const SEED := 2026073001 # the legendary_spawn pin: the derived world seed anchors all seven
const ROUNDTRIP_SPECIES := "REGISTEEL" # the real-step warp lane (untouched by the battle lanes)
const CATCH_SPECIES := "REGIROCK" # lanes (d)+(f): the catch -> tablet -> gone-forever proof
const KO_SPECIES := "REGICE" # lanes (e)/(h)/(i)/(j): the tablet-Regi KO re-stand valve

var _ctx: Dictionary = {}
var _runner = SmokeScenarioRunner.new()
var _failures: Array = []
var _oks: Dictionary = {}

func run(ctx: Dictionary) -> void:
	_ctx = ctx
	await get_tree().create_timer(0.2).timeout
	var runtime = _runtime()
	runtime.seed_for_smoke(SEED) # BEFORE new_game: pins the root_seed draw too (the legendary_spawn precedent)
	runtime.new_game()
	_world().rebuild(runtime.get_world_seed())
	var party_before: Array = _runner.swap_party(runtime, ["RHYPERIOR", "MACHAMP"], 100) # outlevels the ring band; survives the provoked counter
	var saved_chance: float = _player().encounter_chance; _player().encounter_chance = 0.0 # every battle rides the pending seam, never a step trigger
	var mons_active_before: bool = runtime.overworld_mons_runtime.active
	# The battle latch goes on AFTER the warp lane: _smoke_set_battle(true) also clears
	# player.input_enabled (main.gd), which freezes the in-flight step tween and starves
	# the tile_changed await — the real-step round-trip must run with input live.
	_oks["entrance_ok"] = _prove_entrances(runtime)
	if _failures.is_empty(): _oks["warp_ok"] = await _prove_warp_roundtrip(runtime)
	else: _failures.append("skipped: warp (cascaded from an entrance red)")
	if _failures.is_empty(): _oks["contact_ok"] = await LegendaryDungeonJourneyChecks.contact_battle_proof(runtime, ROUNDTRIP_SPECIES, _player(), _world(), _ctx["battle_view"], _runner, _failures)
	else: _failures.append("skipped: contact (cascaded from an earlier red)")
	if _failures.is_empty(): _oks["load_ok"] = LegendaryDungeonJourneyChecks.loaded_position_proof(runtime, ROUNDTRIP_SPECIES, _player(), _world(), _runner, _failures)
	else: _failures.append("skipped: load (cascaded from an earlier red)")
	if _failures.is_empty(): _oks["interact_ok"] = await LegendaryDungeonJourneyChecks.provoked_interact_proof(runtime, ROUNDTRIP_SPECIES, _player(), _world(), _ctx["battle_view"], _runner, _failures)
	else: _failures.append("skipped: interact (cascaded from an earlier red)")
	_call("set_battle", [true]) # latch main._in_battle: battles stay on the DIRECT seam (the legendary_spawn driver precedent)
	if _failures.is_empty(): _oks["catch_ok"] = LegendaryDungeonChecks.catch_persists_proof(runtime, CATCH_SPECIES, _player(), _world(), _runner, _failures)
	else: _failures.append("skipped: catch (cascaded from an earlier red)")
	if _failures.is_empty(): _oks["ko_valve_ok"] = LegendaryDungeonChecks.ko_valve_proof(runtime, KO_SPECIES, _player(), _world(), _runner, _failures)
	else: _failures.append("skipped: ko_valve (cascaded from an earlier red)")
	if _failures.is_empty(): _oks["suppression_ok"] = _prove_suppression(runtime) # runs INSIDE the KO lane's re-entered dungeon
	else: _failures.append("skipped: suppression (cascaded from an earlier red)")
	if _failures.is_empty(): _oks["refusal_ok"] = LegendaryDungeonChecks.in_dungeon_refusals(runtime, _runner, _failures)
	else: _failures.append("skipped: refusals (cascaded from an earlier red)")
	if _failures.is_empty(): _oks["roundtrip_ok"] = LegendaryDungeonChecks.save_roundtrip_proof(runtime, KO_SPECIES, _failures)
	else: _failures.append("skipped: roundtrip (cascaded from an earlier red)")
	if _failures.is_empty(): _oks["seal_ok"] = LegendaryDungeonChecks.seal_ladder_proof(runtime, _runner, _failures) # LAST: it strips + re-grants the five tablets
	else: _failures.append("skipped: seal (cascaded from an earlier red)")
	if _failures.is_empty():
		var payload: Dictionary = _oks.duplicate(); payload["pin"] = SEED; payload["seed"] = runtime.get_world_seed()
		runtime.emit_trace("legendary_dungeon_passed", "SmokeScenarios", payload)
	else:
		runtime.emit_trace("legendary_dungeon_failed", "SmokeScenarios", {"failures": _failures, "seed": SEED})
		push_error("LegendaryDungeonScenario failed: %s" % "; ".join(PackedStringArray(_failures)))
		runtime.warn("LegendaryDungeonScenario", "Legendary dungeon failed.", {})
	_call("set_battle", [false]) # also re-enables player input (main.gd's _smoke_set_battle)
	_runner.restore_party(runtime, party_before)
	_player().encounter_chance = saved_chance; _player().input_enabled = true
	runtime.overworld_mons_runtime.active = mons_active_before
	if runtime.dungeon_runtime.in_dungeon(): runtime.dungeon_runtime.exit_dungeon() # leave the session overworld-clean for the harness tail
	runtime.save_game()

# (a) The seven entrances stamp at the pinned anchors with DISTINCT warp tiles: the resolver
# serves the warp entrance cell (warp flag + dungeon_id) on every anchored species' anchor.
func _prove_entrances(runtime) -> bool:
	var start: int = _failures.size()
	var seed: int = runtime.get_world_seed()
	var scope_issues: Dictionary = DungeonMaps.DungeonLayouts.validate_encounter_scopes(runtime.catalog.species, Callable(runtime._biome_encounters, "is_battle_viable"))
	for dungeon_id in DungeonMaps.DUNGEON_IDS:
		for issue in scope_issues.get(dungeon_id, []):
			_ensure(false, "encounter_scope: %s: %s" % [dungeon_id, str(issue)])
	var expected: Dictionary = LegendarySpawnChecks.expected_anchor_set(seed) # the sibling-exclusion chain — the sim's exact source
	var anchored: Array = [] # DERIVED partition (the legendary_spawn precedent): feeding the pin
	var absent: Array = [] # constants would make the partition check vacuous and let a NO_ANCHOR species slip the loop below
	for species in LegendaryPlacement.LEGENDARY_IDS:
		var entry: Dictionary = expected.get(str(species), {})
		if entry.get("tile", LegendaryPlacement.NO_ANCHOR) == LegendaryPlacement.NO_ANCHOR: absent.append(str(species))
		else: anchored.append(str(species))
	var pin := LegendarySpawnChecks.anchor_set_pin(anchored, absent, seed) # all seven anchor under this seed (the climate field generates LAVA)
	_ensure(pin == "", pin)
	var warps: Dictionary = {}
	for species in LegendaryPlacement.LEGENDARY_IDS:
		var sid := str(species)
		var anchor: Vector2i = expected.get(sid, {}).get("tile", LegendaryPlacement.NO_ANCHOR)
		if anchor == LegendaryPlacement.NO_ANCHOR:
			continue # the derived-partition pin above already red-flagged the species
		var cell: Dictionary = DungeonMaps.entrance_cell_for(seed, anchor)
		if _ensure(bool(cell.get("warp", false)) and str(cell.get("dungeon_id", "")) == DungeonMaps.dungeon_for_species(sid), "entrance: %s anchor %s lacks its warp entrance cell (%s)" % [sid, str(anchor), str(cell)]):
			if _ensure(not warps.has(anchor), "entrance: %s shares its warp tile %s with %s (the sibling-exclusion chain regressed)" % [sid, str(anchor), str(warps.get(anchor, ""))]):
				warps[anchor] = sid
		var live: Dictionary = _world().get_tile_logic(anchor) # the LIVE resolver stamp (the render path), not just the pure derivation
		_ensure(bool(live.get("walkable", false)) and bool(live.get("dungeon_warp", false)) and str(live.get("dungeon_id", "")) == DungeonMaps.dungeon_for_species(sid), "entrance: %s live tile logic at %s lost its warp stamp (%s)" % [sid, str(anchor), str(live)])
	return _failures.size() == start

# (b)+(c) The REAL-step warp round-trip on REGISTEEL: approach the facade from the south floor
# tile (local (2,3), walkable), step UP onto the warp (the anchor), land on the dungeon spawn
# with active_area set + the chamber entity stamped on the chamber tile (and NO overworld
# static), then step DOWN onto the exit tile and land back on the entrance warp, cleared.
func _prove_warp_roundtrip(runtime) -> bool:
	var start: int = _failures.size()
	var dungeon_id := DungeonMaps.dungeon_for_species(ROUNDTRIP_SPECIES)
	var anchor: Vector2i = DungeonMaps.entrance_anchor_for(runtime.get_world_seed(), ROUNDTRIP_SPECIES)
	if not _ensure(anchor != LegendaryPlacement.NO_ANCHOR, "warp: %s resolved NO_ANCHOR" % ROUNDTRIP_SPECIES): return false
	_runner.teleport_player(_world(), _player(), runtime, anchor + Vector2i(0, 1)) # the facade approach floor (local (2,3) '.')
	var cursor: int = _runner.trace_log_line_count()
	if not _ensure(_player().smoke_step(Vector2i.UP), "warp: the step onto the %s entrance warp refused to start" % dungeon_id): return false
	await _player().tile_changed
	await get_tree().process_frame # main's mid-step re-home + view re-anchor settle
	var spawn: Vector2i = DungeonMaps.spawn_tile_for(dungeon_id)
	_ensure(str(runtime.session.active_area) == dungeon_id, "warp: active_area %s != %s after the entrance step" % [str(runtime.session.active_area), dungeon_id])
	_ensure(runtime.session.player_tile == spawn and _player().tile_position == spawn, "warp: the player landed on %s/%s, not the dungeon spawn %s" % [str(runtime.session.player_tile), str(_player().tile_position), str(spawn)])
	_ensure(_runner.trace_log_has_since("dungeon_entered", cursor, {"dungeon_id": dungeon_id, "species_id": ROUNDTRIP_SPECIES}), "warp: no dungeon_entered{dungeon_registeel} off the entrance step")
	var mons = runtime.overworld_mons_runtime
	var chamber: Dictionary = mons._entities.get("legendary_%s" % dungeon_id, {})
	_ensure(not chamber.is_empty() and chamber.get("tile", Vector2i.MAX) == DungeonMaps.chamber_tile_for(dungeon_id), "warp: the chamber entity did not stamp on the chamber tile (%s)" % str(chamber.get("tile", "?")))
	_ensure(str(chamber.get("dungeon_id", "")) == dungeon_id, "warp: the chamber entity's dungeon_id %s != %s" % [str(chamber.get("dungeon_id", "")), dungeon_id])
	_ensure(not mons._entities.has("legendary_0,0:%s" % ROUNDTRIP_SPECIES), "warp: %s still stamps an OVERWORLD static (the retired boot stamp)" % ROUNDTRIP_SPECIES)
	_ensure(mons.live_entities_in(Rect2i(anchor - Vector2i(2, 2), Vector2i(5, 5))).is_empty(), "warp: live entities linger at the overworld anchor %s after the warp" % str(anchor))
	var exit_tile: Vector2i = DungeonMaps.exit_tile_for(dungeon_id)
	var step_dir: Vector2i = exit_tile - runtime.session.player_tile
	if not _ensure(step_dir.length_squared() == 1, "warp: the exit tile %s is not one step from the spawn %s" % [str(exit_tile), str(runtime.session.player_tile)]): return _failures.size() == start
	cursor = _runner.trace_log_line_count()
	if not _ensure(_player().smoke_step(step_dir), "warp: the step onto the %s exit tile refused to start" % dungeon_id): return _failures.size() == start
	await _player().tile_changed
	await get_tree().process_frame
	_ensure(str(runtime.session.active_area) == "", "warp: active_area %s did not clear on the exit step" % str(runtime.session.active_area))
	_ensure(runtime.session.player_tile == anchor and _player().tile_position == anchor, "warp: the exit re-landed the player on %s/%s, not the entrance warp %s" % [str(runtime.session.player_tile), str(_player().tile_position), str(anchor)])
	_ensure(_runner.trace_log_has_since("dungeon_exited", cursor, {"dungeon_id": dungeon_id, "reason": "exit"}), "warp: no dungeon_exited{reason: exit} off the exit step")
	return _failures.size() == start

# (h) Overworld sim suppression: with the sim FORCED ON, note_player_step at dungeon-local
# coords spawns/moves NOTHING (the in_dungeon gate) — the chamber entity stays the only one.
# The landmark gate rides the same lane: dungeon-local steps must fire NO landmark events.
func _prove_suppression(runtime) -> bool:
	var start: int = _failures.size()
	var mons = runtime.overworld_mons_runtime
	if not _ensure(runtime.dungeon_runtime.in_dungeon(), "suppression: the lane must run inside a dungeon (active_area empty)"): return false
	mons.active = true # the gate must hold even with the sim ON (restored in run())
	var cursor: int = _runner.trace_log_line_count()
	var before: Array = mons._entities.keys()
	for _i in range(8):
		runtime.session.total_steps += 1
		mons.note_player_step(int(runtime.session.total_steps), runtime.session.player_tile, "DAY")
		runtime.landmark_runtime.note_player_step(runtime.session.player_tile) # the BLOCKER regression: a dungeon-LOCAL step must never reach the overworld landmark state
	_ensure(mons._entities.keys() == before, "suppression: the overworld sim spawned/moved entities at dungeon-local coords (%s -> %s)" % [str(before), str(mons._entities.keys())])
	_ensure(not _runner.trace_log_has_since("landmark_entered", cursor, {}), "suppression: landmark_entered fired off a dungeon-local step (the landmark gate regressed)")
	_ensure(not _runner.trace_log_has_since("landmark_entity_spawned", cursor, {}), "suppression: landmark_entity_spawned fired off a dungeon-local step (the landmark gate regressed)")
	mons.active = false
	return _failures.size() == start

func _ensure(ok: bool, label: String) -> bool:
	if not ok:
		_failures.append(label)
	return ok

func _call(key: String, args: Array = []) -> void:
	var callable: Callable = _ctx.get(key, Callable())
	if callable.is_valid(): callable.callv(args)

func _world() -> Node: return _ctx["world"]
func _player() -> Node: return _ctx["player"]
func _runtime() -> Node: return _ctx["runtime"]
