extends Node

# Legendary spawn scenario (Phase 7 Build 2 + the legendary-dungeon slice; spec:
# docs/product-specs/world-depth.md § Legendaries). The climate-anchored spawn proof,
# self-pinned seed_for_smoke(SEED) -> new_game -> rebuild (the breed_flow precedent; joins
# the double-run lane — the derivation is pure _mix, NO rng). (1) ANCHORS — each frozen
# species anchors at ring >= LEGENDARY_RING_MIN in its affinity biome; the OVERWORLD entity
# stamp is RETIRED (the dungeon slice): the anchor now stamps the ENTRANCE warp cell
# (DungeonMaps.entrance_cell_for — warp flag + dungeon_id, resolver biome == affinity) and
# NO legendary_0,0:* entity exists at boot. The partition stays PINNED to the exact derived
# set under SEED (anchor_set_pin); the NO_ANCHOR negative proof rides the synthetic reach-1
# witness. (2) EXCLUSION — no legendary in any pool (DAY+NIGHT filter, the forced
# full-catalog fallback, the is_battle_viable TYPE-fallback guard + the curated pin).
# (3) WHITE-OUT — the chamber legendary (MEWTWO's dungeon): the provoked +3, the
# battle-start trace (dungeon_id on the payload), the defeat dumps the player to the
# campsite OUTSIDE the dungeon, the whittle persists across the re-entry re-stamp, the
# rematch carries the +3. (4) KO — REGIGIGAS (both-outcomes-permanent; a tablet Regi's KO
# rides the re-stand valve into legendary_kos instead): the five-tablet SEAL refuses first
# (dungeon_entry_refused), the KO writes legendary_removals, the re-entry re-stamp
# suppresses, an untouched dungeon still stamps. Battles ride the DIRECT seam under the
# set_battle latch; play_battle_track rides a verbatim MIMIC of main.gd:92 (latch-bypassed;
# music_track_selected + a grep pin make it observable).

const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")
const OverworldMonsRuntime := preload("res://scripts/runtime/overworld_mons_runtime.gd")
const DungeonRuntime := preload("res://scripts/runtime/dungeon_runtime.gd") # rides its domain preloads (the layer table; the landmark_flow precedent)
const LegendarySpawnChecks := preload("res://scripts/app/legendary_spawn_checks.gd") # the hardened proofs extracted at the app 220 budget wall
const LegendarySpawnBattleChecks := preload("res://scripts/app/legendary_spawn_battle_checks.gd") # the chamber-battle proofs (the second extraction at the wall)
# Domain access rides the runtime's own preload (the layer table; the landmark_flow precedent).
const LegendaryPlacement := OverworldMonsRuntime.LegendaryPlacement
const DungeonMaps := DungeonRuntime.DungeonMaps

const SEED := 2026073001
const DAY_MINUTES := 600
const KO_SUBJECT := "REGIGIGAS" # both-outcomes-permanent (a tablet Regi's KO rides the re-stand valve); MEWTWO stays the white-out subject

var _ctx: Dictionary = {}
var _runner = SmokeScenarioRunner.new()
var _failures: Array = []
var _oks: Dictionary = {}
var _anchored: Array = [] # species anchored at ring >= LEGENDARY_RING_MIN in the affinity biome (all seven under the climate field)
var _lava_absent: Array = [] # NO_ANCHOR species on this seed (EMPTY under the climate field; the synthetic reach-1 witness covers the negative proof)

func run(ctx: Dictionary) -> void:
	_ctx = ctx
	await get_tree().create_timer(0.2).timeout
	var runtime = _runtime()
	runtime.seed_for_smoke(SEED) # BEFORE new_game: pins the root_seed draw too (breed_flow precedent; the double-run lane reds without it)
	runtime.new_game()
	_world().rebuild(runtime.get_world_seed()) # the view owns its own generator (the breed_flow precedent)
	runtime.session.time_of_day_minutes = DAY_MINUTES
	var party_before: Array = _runner.swap_party(runtime, ["RHYPERIOR", "MACHAMP"], 100) # outlevels the ring band; survives the provoked counter
	var saved_chance: float = _player().encounter_chance; _player().encounter_chance = 0.0 # every battle rides the pending seam, never a step trigger
	_call("set_battle", [true]) # latch main._in_battle: the presentation bridge early-returns, so every forced battle stays on the DIRECT seam (smoke-battle driver precedent)
	_oks["anchor_ok"] = _prove_anchors(runtime)
	if _failures.is_empty(): _oks["exclusion_ok"] = _prove_exclusion(runtime)
	else: _failures.append("skipped: exclusion (cascaded from an anchor red)")
	if _failures.is_empty(): _oks["whiteout_ok"] = _prove_whiteout(runtime, str(_anchored[0]))
	else: _failures.append("skipped: whiteout (cascaded from an earlier red)")
	if _failures.is_empty(): _oks["ko_ok"] = _prove_ko(runtime, KO_SUBJECT)
	else: _failures.append("skipped: ko (cascaded from an earlier red)")
	if _failures.is_empty():
		var payload: Dictionary = _oks.duplicate(); payload["pin"] = SEED; payload["seed"] = runtime.get_world_seed(); payload["anchored"] = _anchored; payload["lava_absent"] = _lava_absent
		runtime.emit_trace("legendary_spawn_passed", "SmokeScenarios", payload)
	else:
		runtime.emit_trace("legendary_spawn_failed", "SmokeScenarios", {"failures": _failures, "seed": SEED})
		push_error("LegendarySpawnScenario failed: %s" % "; ".join(PackedStringArray(_failures)))
		runtime.warn("LegendarySpawnScenario", "Legendary spawn failed.", {})
	_call("set_battle", [false])
	_runner.restore_party(runtime, party_before)
	_player().encounter_chance = saved_chance; _player().input_enabled = true
	runtime.session.time_of_day_minutes = DAY_MINUTES

# Every frozen species derives off the LIVE seed (NEVER hardcoded tiles): an anchor resolves ->
# the ENTRANCE warp cell stamps on that tile (warp flag + dungeon_id; the overworld entity stamp
# is RETIRED — the chamber stamp moved into the dungeon); NO_ANCHOR -> NO entrance. The expected
# set derives through legendaries_for_world (the entrance derivation's exact source).
func _prove_anchors(runtime) -> bool:
	var start: int = _failures.size()
	var seed: int = runtime.get_world_seed()
	var entities: Dictionary = runtime.overworld_mons_runtime._entities
	var expected: Dictionary = LegendarySpawnChecks.expected_anchor_set(seed) # the sim's exact source set (the sibling-exclusion chain)
	for species in LegendaryPlacement.LEGENDARY_IDS:
		var sid := str(species)
		var anchor: Vector2i = expected.get(sid, {}).get("tile", LegendaryPlacement.NO_ANCHOR)
		if anchor == LegendaryPlacement.NO_ANCHOR:
			_lava_absent.append(sid) # contract-legal; the payload witnesses it (the header's empirical flag)
			continue
		var ring := LegendaryPlacement.ring_of(anchor)
		_ensure(ring >= LegendaryPlacement.LEGENDARY_RING_MIN, "anchor: %s anchored at ring %d (< %d)" % [sid, ring, LegendaryPlacement.LEGENDARY_RING_MIN])
		_ensure(_world().get_tile_biome(anchor) == LegendaryPlacement.affinity_for(sid), "anchor: %s tile %s resolver biome %s != affinity %s" % [sid, str(anchor), str(_world().get_tile_biome(anchor)), LegendaryPlacement.affinity_for(sid)])
		var cell: Dictionary = DungeonMaps.entrance_cell_for(seed, anchor)
		if _ensure(bool(cell.get("warp", false)), "anchor: %s anchored at %s but no entrance warp cell stamps there" % [sid, str(anchor)]):
			_ensure(str(cell.get("dungeon_id", "")) == DungeonMaps.dungeon_for_species(sid), "anchor: %s entrance dungeon %s != %s" % [sid, str(cell.get("dungeon_id", "")), DungeonMaps.dungeon_for_species(sid)])
			_ensure(not entities.has("legendary_0,0:%s" % sid), "anchor: %s still stamps an OVERWORLD entity (the retired stamp_legendaries)" % sid)
			_anchored.append(sid)
	var labels := [LegendarySpawnChecks.anchor_set_pin(_anchored, _lava_absent, seed), LegendarySpawnChecks.synthetic_no_anchor_witness(seed)] # the EXACT derived set + distinctness + the reach-1 NO_ANCHOR witness (vacuous naturally once all seven anchor)
	return _ensure(str(labels[0]) == "", str(labels[0])) and _ensure(str(labels[1]) == "", str(labels[1])) and _failures.size() == start

# The never-encounter exclusion on EVERY pool path: the per-biome DAY+NIGHT filter, the forced
# full-catalog fallback (a typeless biome — the ONLY path that could surface one, biome_encounters.gd:124-131),
# and the is_battle_viable TYPE-fallback guard (:121) the night-ghost pool shares (none of the seven is GHOST).
func _prove_exclusion(runtime) -> bool:
	var start: int = _failures.size()
	var filter = runtime._biome_encounters
	var catalog: Dictionary = runtime.catalog.species
	for biome in filter.known_biomes():
		for time_label in ["DAY", "NIGHT"]:
			var ids: Array = filter.filter_species_ids(catalog, str(biome), time_label).get("ids", [])
			for species in LegendaryPlacement.LEGENDARY_IDS:
				if ids.has(str(species)):
					_failures.append("exclusion: %s leaked into the %s/%s pool" % [str(species), str(biome), time_label])
	var fallback: Dictionary = filter.filter_species_ids(catalog, "__no_such_biome__", "DAY")
	_ensure(bool(fallback.get("used_fallback", false)), "exclusion: the typeless-biome probe never reached the full-catalog fallback")
	for species in LegendaryPlacement.LEGENDARY_IDS:
		var sid := str(species)
		if (fallback.get("ids", []) as Array).has(sid):
			_failures.append("exclusion: %s leaked through the full-catalog fallback" % sid)
		if filter.is_battle_viable(sid, runtime.catalog.get_species(sid)):
			_failures.append("exclusion: %s passes is_battle_viable (the TYPE-fallback guard the night-ghost pool shares)" % sid)
	LegendarySpawnChecks.curated_exclusion_pin(runtime, _failures); return _failures.size() == start # R6: the curated/extra_ids path the per-biome scan cannot see

# The chamber-legendary battle proofs (white-out whittle persistence; the KO removal + the
# Regigigas seal) live in legendary_spawn_battle_checks.gd — extracted at the app 220 wall
# (the legendary_spawn_checks.gd precedent). These wrappers keep the run() driver readable.
func _prove_whiteout(runtime, species_id: String) -> bool:
	var start: int = _failures.size()
	LegendarySpawnBattleChecks.whiteout_proof(runtime, species_id, _player(), _world(), _ctx["music_router"], _runner, _failures)
	return _failures.size() == start

func _prove_ko(runtime, species_id: String) -> bool:
	var start: int = _failures.size()
	LegendarySpawnBattleChecks.ko_proof(runtime, species_id, _anchored, _player(), _world(), _runner, _failures)
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
