extends Node
# Phase 6 overworld mons gate-scenario check groups, part 1 (spec: docs/product-specs/
# overworld-pokemon.md § Smoke validation; the breed_flow_checks split precedent): the
# DETERMINISM harness (crafted-state + entity reset, the pinned walk script's entity-set
# hash, the unconsumed-stream CONTROL), SPAWN (every one of the 11 biomes yields live
# roamers along band anchors; species ride the live pool of their SPAWN cell's biome; the
# named wiki dispositions resolve off the LIVE catalog via runtime _disposition_now
# probes), and CHARM-RECRUIT (Dedenne pacifies a timid roamer — charm_used{level_gate_met:
# true}; the calm window holds the flee; dialogue Z recruits with the spawn-time rolls;
# the full-party refusal :262). Hostile engage + egg/Alpha ride overworld_mons_battle_
# checks.gd; shared oracles ride overworld_mons_probe.gd. NO domain preloads (app may not
# reach domain) — the runtime's own objects are the oracle.
const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")
const VisualSweepBaselines := preload("res://scripts/app/visual_sweep_baselines.gd")
const OverworldMonsProbe := preload("res://scripts/runtime/overworld_mons_probe.gd")
const DAY_MINUTES := 600
const CONTROL_SEED := 2026072702 # rng pin for the unconsumed-stream CONTROL window
const CONTROL_DRAWS := 8
const CHARM_CALM_STEPS := 12 # mirrors OverworldMons.CHARM_CALM_STEPS (scenario contract)
const ALL_BIOMES := ["WATER", "SAND", "PLAINS", "GRASSLAND", "FOREST", "SAVANNA", "DESERT", "SWAMP", "ROCK", "SNOW", "LAVA"]
const DISPOSITIONS := ["TIMID", "FRIENDLY", "IRRITABLE", "AGGRESSIVE"]
var _ctx: Dictionary = {}
var _runner = SmokeScenarioRunner.new()
var _baselines = VisualSweepBaselines.new()
var probe = OverworldMonsProbe.new()
var _failures: Array = []
var _seed: int = 0
var _anchors: Dictionary = {}
var recruited_species: Array = [] # the save-case witnesses (the party channels persist)
var shiny_ok := true # EVERY-creation contract, scoped per instance build
func setup(ctx: Dictionary, runner: SmokeScenarioRunner, failures: Array, seed: int) -> void:
	_ctx = ctx; _runner = runner; _failures = failures; _seed = seed
func craft(runtime) -> bool: # crafted state + the all-field-moves fixture (Dedenne=Charm, Drapion=Attack/Repel)
	var spec := {"world_seed": _seed, "time_of_day": DAY_MINUTES, "bag": {}, "party": [["RHYPERIOR", 50], ["CHARIZARD", 50], ["MACHOP", 50], ["CALYREX", 50], ["DEDENNE", 50], ["DRAPION", 50]]}
	var ok := _baselines.craft_state(_ctx, _runner, spec)
	if ok:
		runtime.session.repel_steps = 0
		reset_entities(_mons(runtime))
	return ok
func reset_entities(mons) -> void: # a fresh derivation (the transient re-settle, in session)
	mons._entities.clear(); mons._removed.clear(); mons._nests_found.clear(); mons._pool_cache.clear()
	mons._pending = {}; mons._pending_id = ""; mons._last_battle_was_entity = false
	mons._time_label = ""; mons._faced_tile = Vector2i.MAX; mons._last_interact_id = ""; mons._last_interact_step = -100
	mons.active = true
func walk_and_sample(runtime, mons, steps: int) -> Array: # the pinned step script (identical both runs)
	var hashes: Array = []
	var directions := [Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT, Vector2i.UP]
	var tile: Vector2i = _player().tile_position
	for i in range(steps):
		var next_tile: Vector2i = tile + directions[i % 4]
		if _world().is_tile_walkable(next_tile):
			tile = next_tile
			_runner.teleport_player(_world(), _player(), runtime, tile)
		runtime.note_player_step()
		hashes.append(probe.entity_hash(mons, tile, 40))
	return hashes
# CONTROL: N seeded wild draws byte-identical with entities ACTIVE (live store, empty seam)
# vs inert — the shared _rng is provably unconsumed by the subsystem.
func unconsumed_stream_control(runtime, mons) -> bool:
	mons.take_pending_encounter() # a chase-catch may have armed the seam during the walk
	var tile: Vector2i = _player().tile_position
	var biome: String = _world().get_tile_biome(tile)
	runtime.seed_for_smoke(CONTROL_SEED)
	var active_draws := probe.draw_sequence(runtime, tile, biome, CONTROL_DRAWS)
	runtime.seed_for_smoke(CONTROL_SEED)
	mons.active = false
	var inert_draws := probe.draw_sequence(runtime, tile, biome, CONTROL_DRAWS)
	mons.active = true
	runtime.seed_for_smoke(CONTROL_SEED + 1) # leave the stream on a known pin
	return _ensure(active_draws == inert_draws and not active_draws.is_empty(), "determinism: the wild stream differs with entities active vs inert")

# --- SPAWN: every biome shows roaming mons; species in pool; named dispositions ---
func run_spawn_case(runtime) -> bool:
	if not craft(runtime): return _ensure(false, "spawn: crafted state failed")
	var mons := _mons(runtime)
	if _anchors.is_empty():
		_anchors = probe.biome_anchors(_world(), ALL_BIOMES)
	var named := {} # species_id -> [spawn-cell biome, disposition] (natural-spawn witness)
	for biome in ALL_BIOMES:
		var anchor: Vector2i = _anchors.get(biome, Vector2i.MAX)
		if anchor == Vector2i.MAX:
			_ensure(false, "spawn: biome %s not found on the band scan" % biome); continue
		runtime.session.time_of_day_minutes = DAY_MINUTES # the DAY pool label holds for the membership pin
		var roamers := 0
		var band_ring := absi(anchor.x) + absi(anchor.y)
		for k in range(12): # 4 band rings x spread directions: many slot draws along the biome band
			if k % 4 == 0: await get_tree().process_frame # flush the world view's deferred tile frees
			var stand: Vector2i = probe.stand_tile(_world(), probe.band_point(band_ring + 4 + (k % 4) * 8, k), biome)
			if stand == Vector2i.MAX: continue
			_runner.teleport_player(_world(), _player(), runtime, stand)
			runtime.note_player_step()
			for e in probe.live(mons, stand, 24):
				if str(e.get("kind", "")) != "mon": continue
				roamers += 1
				if not str(e.get("disposition", "")) in DISPOSITIONS:
					_failures.append("spawn: %s carries a non-canonical disposition %s" % [str(e.species_id), str(e.get("disposition", ""))])
				var cell_biome: String = str(_world().get_tile_logic(Vector2i(e.cell.x * 8 + 4, e.cell.y * 8 + 4)).get("biome", ""))
				named[str(e.species_id)] = [cell_biome, str(e.get("disposition", ""))]
				var pool: Array = mons.get("_sim").call("pool_for", cell_biome, "DAY")
				if not pool.has(str(e.species_id)):
					_failures.append("spawn: %s outside the %s pool (one-biome-truth drift)" % [str(e.species_id), cell_biome])
		_ensure(roamers >= 1, "spawn: no live roamer at the %s anchor" % biome)
	# Named wiki examples via runtime _disposition_now probes (live catalog) — deterministic
	# regardless of band-spawn luck (a 1/215-pool species can miss any ray scan).
	runtime.session.time_of_day_minutes = DAY_MINUTES
	_ensure_disposition_probe(mons, "PIDGEY", "FOREST", "TIMID")
	_ensure_disposition_probe(mons, "PRIMEAPE", "SAVANNA", "AGGRESSIVE")
	_ensure_disposition_probe(mons, "TAUROS", "SAVANNA", "IRRITABLE")
	_ensure_disposition_probe(mons, "JUMPLUFF", "GRASSLAND", "FRIENDLY")
	# ...and where the named species DID spawn naturally, the stamp must agree too.
	_ensure_named(named, "PIDGEY", "TIMID", "")
	_ensure_named(named, "JUMPLUFF", "FRIENDLY", "")
	_ensure_named(named, "TAUROS", "IRRITABLE", "")
	_ensure_named(named, "PRIMEAPE", "AGGRESSIVE", "SAVANNA")
	return true
# The wiki disposition rule, witnessed on the live catalog: a probe record at the biome
# anchor resolves through the runtime's own _disposition_now (domain + live entry).
func _ensure_disposition_probe(mons, species_id: String, biome: String, want: String) -> void:
	var anchor: Vector2i = _anchors.get(biome, Vector2i.MAX)
	if anchor == Vector2i.MAX:
		_ensure(false, "spawn: the %s anchor is missing for the %s probe" % [biome, species_id]); return
	var record := {"kind": "mon", "species_id": species_id, "tile": anchor}
	var resolved: String = str(mons.call("_disposition_now", record))
	_ensure(resolved == want, "spawn: %s on %s resolved %s, expected %s (wiki disposition drift)" % [species_id, biome, resolved, want])
func _ensure_named(named: Dictionary, species_id: String, disposition: String, biome: String) -> void:
	if not named.has(species_id): return # presence is spawn-luck; the probe above is the pin
	var entry: Array = named[species_id]
	if biome != "" and str(entry[0]) != biome: return # biome-conditioned wiki gate
	_ensure(str(entry[1]) == disposition, "spawn: wild %s resolved %s, expected %s" % [species_id, str(entry[1]), disposition])

# --- CHARM-RECRUIT: the level gate, the calm window, dialogue recruitment :262 ----
func run_charm_case(runtime) -> bool:
	if not craft(runtime): return _ensure(false, "charm: crafted state failed")
	var mons := _mons(runtime)
	var pair := await _find_pair(runtime, mons, "FRIENDLY", "TIMID")
	var friendly: Dictionary = pair.get("A", {})
	var timid: Dictionary = pair.get("B", {})
	if friendly.is_empty(): friendly = _inject(runtime, mons, "JUMPLUFF", "FRIENDLY", 2, "")
	if timid.is_empty(): timid = _inject(runtime, mons, "PIDGEY", "TIMID", 2, "")
	if friendly.is_empty() or timid.is_empty():
		return _ensure(false, "charm: no %s roamer near spawn (and injection failed)" % ("friendly" if friendly.is_empty() else "timid"))
	_stand_by(runtime, mons, friendly.tile)
	var cursor_full := _runner.trace_log_line_count()
	var refused: Dictionary = mons.call("interact", friendly.tile) # the full party refuses :262
	if not _ensure(str(refused.get("reason", "")) == "party_full", "charm: full-party interact returned %s, expected party_full" % str(refused.get("reason", ""))): return false
	_ensure(_runner.trace_log_has_since("recruit_attempted", cursor_full, {"reason": "party_full", "ok": false, "party_free": false}), "charm: no recruit_attempted{party_full} trace")
	runtime.session.party.resize(5)
	var cursor_r := _runner.trace_log_line_count()
	var joined: Dictionary = mons.call("interact", friendly.tile)
	if not _ensure(bool(joined.get("ok", false)), "charm: dialogue recruit refused on a free slot (%s)" % str(joined.get("reason", ""))): return false
	var ok := _ensure(_runner.trace_log_has_since("recruit_attempted", cursor_r, {"path": "dialogue", "ok": true}), "charm: no recruit_attempted{dialogue,ok} trace")
	ok = _ensure(_runner.trace_log_has_since("recruit_succeeded", cursor_r, {"species_id": str(friendly.species_id),
		"level": int(friendly.level), "is_shiny": bool(friendly.is_shiny), "party_size": 6}), "charm: recruit_succeeded lost the spawn-time rolls") and ok
	_note_shiny(cursor_r)
	recruited_species.append(str(friendly.species_id))
	# REFUSAL BRANCH (deep-dive T6 pin): an over-leveled target FAILS the gate — pacified:false,
	# charm_used{level_gate_met:false}, and no calm window on the entity (a charm-pacifies-
	# anything regression must red HERE, not ship certified green).
	var cursor_ref := _runner.trace_log_line_count()
	var over_leveled: Dictionary = runtime.field_move_runtime.use_charm(str(timid.species_id), int(timid.level) + 50)
	if not _ensure(bool(over_leveled.get("ok", false)) and not bool(over_leveled.get("pacified", true)), "charm: an over-leveled target was pacified (level-gate refusal unpinned)"): return false
	_ensure(_runner.trace_log_has_since("charm_used", cursor_ref, {"level_gate_met": false}), "charm: no charm_used{level_gate_met:false} refusal trace")
	_ensure(int((mons.call("entity_at", timid.tile) as Dictionary).get("pacify_steps", 0)) == 0, "charm: a refused charm left a calm window")
	# Charm pacifies (Dedenne 50 >= the band level); the calm window holds the flee at SPOOK range.
	_stand_by(runtime, mons, timid.tile) # adjacency (1) <= SPOOK_RADIUS(3): uncharmed, it would flee on a step
	var cursor_c := _runner.trace_log_line_count()
	var charm: Dictionary = runtime.field_move_runtime.use_charm(str(timid.species_id), int(timid.level))
	if not _ensure(bool(charm.get("pacified", false)), "charm: use_charm did not pacify (level gate)"): return false
	if not _ensure(_runner.trace_log_has_since("charm_used", cursor_c, {"level_gate_met": true}), "charm: no charm_used{level_gate_met} trace"): return false
	if not _ensure(int((mons.call("entity_at", timid.tile) as Dictionary).get("pacify_steps", 0)) == CHARM_CALM_STEPS, "charm: the calm window is not %d steps" % CHARM_CALM_STEPS): return false
	runtime.note_player_step()
	var held := probe.by_id(mons, _player().tile_position, str(timid.id)) # the roam tick may shift the tile
	if not _ensure(not held.is_empty() and str(held.get("state", "")) == "idle", "charm: the pacified timid fled anyway"): return false
	runtime.session.party.resize(5)
	var cursor_p := _runner.trace_log_line_count()
	var calmed: Dictionary = mons.call("interact", held.tile) # DIVERGENCE #6: calm-then-interact
	if not _ensure(bool(calmed.get("ok", false)), "charm: the pacified timid refused recruitment (%s)" % str(calmed.get("reason", ""))): return false
	_ensure(_runner.trace_log_has_since("recruit_succeeded", cursor_p, {"species_id": str(timid.species_id)}), "charm: no recruit_succeeded for the pacified timid")
	_note_shiny(cursor_p)
	recruited_species.append(str(timid.species_id))
	return ok
func _inject(runtime, mons, species_id: String, disposition: String, distance: int, biome: String) -> Dictionary:
	return probe.inject_entity(_world(), mons, _player().tile_position, species_id, disposition, distance, biome)

func _find_pair(runtime, mons, disposition_a: String, disposition_b: String) -> Dictionary:
	var spawn: Vector2i = _player().tile_position
	for anchor in [spawn, spawn + Vector2i(16, 0), spawn + Vector2i(0, 16), spawn + Vector2i(-16, 0),
			spawn + Vector2i(0, -16), spawn + Vector2i(16, 16)]:
		await get_tree().process_frame
		_runner.teleport_player(_world(), _player(), runtime, anchor)
		runtime.note_player_step(); runtime.note_player_step()
		var found := {}
		for e in probe.live(mons, anchor, 24):
			if str(e.get("kind", "")) != "mon" or str(e.get("state", "")) != "idle": continue
			if str(e.get("disposition", "")) == disposition_a and not found.has("A"):
				found["A"] = e
			elif str(e.get("disposition", "")) == disposition_b and not found.has("B"):
				found["B"] = e
		if found.has("A") and found.has("B"):
			return found
	return {}
func _stand_by(runtime, mons, tile: Vector2i) -> void: # a walkable neighbor (the SPOOK/interact range)
	for direction in [Vector2i.DOWN, Vector2i.UP, Vector2i.LEFT, Vector2i.RIGHT]:
		if _world().is_tile_walkable(tile + direction):
			_runner.teleport_player(_world(), _player(), runtime, tile + direction)
			mons.call("note_faced_tile", tile)
			return
	_runner.teleport_player(_world(), _player(), runtime, tile)
func _note_shiny(cursor: int) -> void: # EVERY entity-instance build traces shiny_rolled{origin:overworld}
	shiny_ok = (probe.trace_count(cursor, "shiny_rolled", {"origin": "overworld"}) >= 1) and shiny_ok
func _ensure(ok: bool, label: String) -> bool:
	if not ok:
		_failures.append(label)
	return ok
func _mons(runtime) -> Object: return runtime.get("overworld_mons_runtime")
func _world() -> Node: return _ctx["world"]
func _player() -> Node: return _ctx["player"]
