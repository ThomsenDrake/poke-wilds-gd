extends Node

# Legendary spawn scenario (Phase 7 Build 2; spec: docs/product-specs/world-depth.md
# § Legendaries). The climate-anchored spawn proof, self-pinned seed_for_smoke(SEED)
# -> new_game -> rebuild (the breed_flow precedent; joins the double-run lane —
# legendary stamping is pure _mix, NO rng). (1) ANCHORS — each frozen species anchors at
# ring >= LEGENDARY_RING_MIN (the progression floor) in its affinity biome (stamped
# entity == derived anchor, resolver biome == affinity, AGGRESSIVE, battle_kind
# "legendary"); the partition is PINNED to the exact derived set under SEED
# (anchor_set_pin) — ALL SEVEN anchor under the climate field (slice 2: LAVA generates;
# the radial quantization-tail EMPIRICAL FLAG is RESOLVED). The NO_ANCHOR negative
# proof rides a SYNTHETIC reach-1 witness (the natural case is vacuous on this seed).
# (2) EXCLUSION — no legendary in any pool (DAY+NIGHT filter, the forced full-catalog
# fallback, the is_battle_viable TYPE-fallback guard the night-ghost pool shares).
# (3) ENCOUNTER — chase-catch +3 (:284), the legendary_encounter battle-start trace,
# player-initiated +0 (:280). (4) WHITE-OUT — defeat leaves it standing, damage
# persisted, re-battleable (:284/:288). (5) KO — gone-for-good per world (PORT
# DECISION inverting wiki :224): removal key -> session.legendary_removals, despawn,
# re-stamp suppression + the to_payload/apply_into round-trip. Battles ride the DIRECT
# seam under the set_battle latch; play_battle_track rides a verbatim MIMIC of
# main.gd:92 (latch-bypassed; music_track_selected + a grep pin make it observable).

const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")
const OverworldMonsRuntime := preload("res://scripts/runtime/overworld_mons_runtime.gd")
const LegendarySpawnChecks := preload("res://scripts/app/legendary_spawn_checks.gd") # the hardened proofs extracted at the app 220 budget wall
# Domain access rides the runtime's own preload (the layer table; the landmark_flow precedent).
const LegendaryPlacement := OverworldMonsRuntime.LegendaryPlacement

const SEED := 2026073001
const ORIGIN := Vector2i.ZERO # stamps the origin world (chain frozen — slice 1)
const DAY_MINUTES := 600
const PROVOKED_ATTACK_STAGES := 3 # mirrors OverworldMons.PROVOKED_ATTACK_STAGES (:284)
const WHITEOUT_ENEMY_HP := 9999 # the white-out subject survives one hit so the persisted damage is observable

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
	if _failures.is_empty(): _oks["ko_ok"] = _prove_ko(runtime, str(_anchored[1]))
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
# one entity on that tile (kind/battle_kind/AGGRESSIVE, biome == affinity, ring >= 60); NO_ANCHOR
# -> NO entity. The expected set derives through legendaries_for_world (the sim's exact source).
func _prove_anchors(runtime) -> bool:
	var start: int = _failures.size()
	var seed: int = runtime.get_world_seed()
	var entities: Dictionary = runtime.overworld_mons_runtime._entities
	var expected: Dictionary = LegendarySpawnChecks.expected_anchor_set(seed) # the sim's exact source set (the sibling-exclusion chain)
	for species in LegendaryPlacement.LEGENDARY_IDS:
		var sid := str(species)
		var id := "legendary_0,0:%s" % sid
		var anchor: Vector2i = expected.get(sid, {}).get("tile", LegendaryPlacement.NO_ANCHOR)
		var entity: Dictionary = entities.get(id, {})
		if anchor == LegendaryPlacement.NO_ANCHOR:
			_ensure(entity.is_empty(), "anchor: %s resolved NO_ANCHOR yet entity %s is stamped" % [sid, id])
			_lava_absent.append(sid) # contract-legal; the payload witnesses it (the header's empirical flag)
			continue
		var ring := LegendaryPlacement.ring_of(anchor)
		_ensure(ring >= LegendaryPlacement.LEGENDARY_RING_MIN, "anchor: %s anchored at ring %d (< %d)" % [sid, ring, LegendaryPlacement.LEGENDARY_RING_MIN])
		_ensure(_world().get_tile_biome(anchor) == LegendaryPlacement.affinity_for(sid), "anchor: %s tile %s resolver biome %s != affinity %s" % [sid, str(anchor), str(_world().get_tile_biome(anchor)), LegendaryPlacement.affinity_for(sid)])
		if _ensure(not entity.is_empty(), "anchor: %s anchored at %s but the sim stamped no entity" % [sid, str(anchor)]):
			_ensure(entity.get("tile", Vector2i.MAX) == anchor and int(entity.get("ring", 0)) == ring, "anchor: %s entity tile/ring %s/%d != derived %s/%d" % [sid, str(entity.get("tile", "")), int(entity.get("ring", 0)), str(anchor), ring])
			_ensure(str(entity.get("kind", "")) == "legendary" and str(entity.get("battle_kind", "")) == "legendary", "anchor: %s kind/battle_kind %s/%s" % [sid, str(entity.get("kind", "")), str(entity.get("battle_kind", ""))])
			_ensure(str(entity.get("disposition", "")) == "AGGRESSIVE", "anchor: %s disposition %s != AGGRESSIVE" % [sid, str(entity.get("disposition", ""))])
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

# Chase-catch provoked +3 -> the battle-start trace -> a white-out leaves it standing (damage
# persisted on the entity, dropped to idle) and re-battleable (:284/:288); the REMATCH carries the
# PERSISTED +3 + a second legendary_encounter. The :280 no-buff witness rides the KO case's FIRST engagement (stages 0).
func _prove_whiteout(runtime, species_id: String) -> bool:
	var start: int = _failures.size()
	var mons = runtime.overworld_mons_runtime
	var entity: Dictionary = mons._entities.get("legendary_0,0:%s" % species_id, {})
	if not _ensure(not entity.is_empty(), "whiteout: no stamped entity for %s" % species_id): return false
	var tile: Vector2i = entity.get("tile", Vector2i.MAX)
	mons._force_battle(entity, true) # the forced-AGGRESSIVE chase-catch, exactly like a Phase-6 guardian
	var cursor: int = _runner.trace_log_line_count()
	var battle_mon: Dictionary = _take_and_assert_payload(runtime, species_id, cursor, PROVOKED_ATTACK_STAGES, "whiteout")
	if battle_mon.is_empty(): return false
	_ctx["music_router"].play_battle_track(str(battle_mon.get("battle_kind", "wild"))) # a verbatim MIMIC of the main.gd:92 seam — kind plumbing only (headless never plays audio, miss-002)
	var music_pin := LegendarySpawnChecks.music_seam_pin(_runner, cursor) # music_track_selected{legendary} witness + the main.gd:92 consumer grep pin (the live bridge is latch-bypassed)
	_ensure(music_pin == "", music_pin)
	battle_mon["max_hp"] = WHITEOUT_ENEMY_HP; battle_mon["current_hp"] = WHITEOUT_ENEMY_HP # survives the one damaging hit so the persisted damage is observable
	runtime.start_wild_battle(battle_mon)
	runtime.battle_runtime._player_mon["max_hp"] = WHITEOUT_ENEMY_HP; runtime.battle_runtime._player_mon["current_hp"] = WHITEOUT_ENEMY_HP # unkillable lead: the damaging move lands whatever the ring-band level/speed
	runtime.perform_battle_move(_damaging_move_index(runtime.battle_runtime._player_mon))
	for mon in runtime.session.party: mon["current_hp"] = 0 # zero the WHOLE party: the faint handler finds no healthy successor -> defeat (wild_battle's single-mon precedent, generalized)
	runtime.battle_runtime._player_mon["current_hp"] = 0
	var defeat: Dictionary = runtime.perform_battle_move(_damaging_move_index(runtime.battle_runtime._player_mon))
	if not _ensure(str(defeat.get("outcome", "")) == "defeat", "whiteout: the defeat path reached outcome %s" % str(defeat.get("outcome", ""))): return false
	var standing: Dictionary = mons.entity_at(tile)
	if not _ensure(not standing.is_empty() and str(standing.get("kind", "")) == "legendary", "whiteout: the white-out REMOVED the legendary (:288 violation)"): return false
	_ensure(int(standing.get("current_hp", 0)) > 0 and int(standing.get("current_hp", WHITEOUT_ENEMY_HP)) < WHITEOUT_ENEMY_HP, "whiteout: the enemy's damage did not persist on the entity (hp %d)" % int(standing.get("current_hp", 0)))
	_ensure(str(standing.get("state", "")) == "idle", "whiteout: the surviving entity did not drop to idle")
	var atk: Dictionary = mons.attack_entity(tile)
	if not _ensure(bool(atk.get("ok", false)), "whiteout: the surviving legendary refused a second battle (%s)" % str(atk.get("reason", ""))): return false
	var cursor2: int = _runner.trace_log_line_count()
	var retry: Dictionary = runtime.generate_wild_encounter(_player().tile_position, _world().get_tile_biome(_player().tile_position))
	_ensure(int(retry.get("attack_stages", 0)) == PROVOKED_ATTACK_STAGES, "whiteout: the provoked +3 did NOT persist across the white-out (:284 stat persistence; the :280 no-buff witness rides the ko case's fresh attack)")
	_ensure(_runner.trace_log_has_since("legendary_encounter", cursor2, {"species_id": species_id, "battle_kind": "legendary"}), "whiteout: no second legendary_encounter on the rematch")
	runtime.start_wild_battle(retry)
	_ensure(str(runtime.run_from_battle().get("outcome", "")) == "escaped", "whiteout: the rematch escape failed")
	return _failures.size() == start

# KO -> gone-for-good per instance: overworld_mon_despawned{ko}, the removal key rides
# legendary_removals, a second attempt finds NO target, a re-stamp re-derives suppression, and the payload round-trip keeps it gone.
func _prove_ko(runtime, species_id: String) -> bool:
	var start: int = _failures.size()
	var mons = runtime.overworld_mons_runtime
	var id := "legendary_0,0:%s" % species_id
	var entity_ko: Dictionary = mons._entities.get(id, {})
	var tile: Vector2i = entity_ko.get("tile", Vector2i.MAX); var anchor: Vector2i = entity_ko.get("anchor", tile) # removals key off `anchor` (chase moves `tile`; slice 3)
	var atk: Dictionary = mons.attack_entity(tile)
	if not _ensure(bool(atk.get("ok", false)), "ko: attack on %s refused (%s)" % [species_id, str(atk.get("reason", ""))]): return false
	var cursor: int = _runner.trace_log_line_count()
	var battle_mon: Dictionary = _take_and_assert_payload(runtime, species_id, cursor, 0, "ko")
	if battle_mon.is_empty(): return false
	battle_mon["current_hp"] = 1 # any damaging hit KOs
	runtime.start_wild_battle(battle_mon)
	runtime.battle_runtime._player_mon["max_hp"] = WHITEOUT_ENEMY_HP; runtime.battle_runtime._player_mon["current_hp"] = WHITEOUT_ENEMY_HP # unkillable lead: victory lands whatever the ring-band level/speed order
	var victory: Dictionary = runtime.perform_battle_move(_damaging_move_index(runtime.battle_runtime._player_mon))
	if not _ensure(str(victory.get("outcome", "")) == "victory", "ko: outcome %s != victory" % str(victory.get("outcome", ""))): return false
	_ensure(_runner.trace_log_has_since("overworld_mon_despawned", cursor, {"species_id": species_id, "reason": "ko"}), "ko: no overworld_mon_despawned{reason:ko}")
	_ensure((runtime.session.legendary_removals as Array).has(LegendaryPlacement.removal_key(anchor, species_id)), "ko: the removal key %s never reached session.legendary_removals (%s)" % [LegendaryPlacement.removal_key(anchor, species_id), str(runtime.session.legendary_removals)])
	var roundtrip := LegendarySpawnChecks.roundtrip_removal(runtime, species_id, _anchored) # the save marshalling round-trip (to_payload/apply_into into a fresh session)
	_ensure(roundtrip == "", roundtrip)
	var again: Dictionary = mons.attack_entity(tile) # the second encounter attempt finds it gone
	_ensure(str(again.get("reason", "")) == "no_target", "ko: the KO'd legendary is still attackable (%s)" % str(again.get("reason", "")))
	mons.stamp_legendaries() # suppression re-derives from the persistent removal set (the untouched anchored re-stamp)
	_ensure(not mons._entities.has(id), "ko: the re-stamp re-created the KO'd legendary (suppression not re-derived)")
	for other in _anchored:
		if str(other) != species_id: _ensure(mons._entities.has("legendary_0,0:%s" % str(other)), "ko: the re-stamp dropped the untouched %s" % str(other))
	return _failures.size() == start

# The pending-seam take + the legendary_encounter payload (species/kind/ring/stages). {} on any red, so the caller bails.
func _take_and_assert_payload(runtime, species_id: String, cursor: int, stages: int, label: String) -> Dictionary:
	var battle_mon: Dictionary = runtime.generate_wild_encounter(_player().tile_position, _world().get_tile_biome(_player().tile_position))
	if not _ensure(str(battle_mon.get("species_id", "")) == species_id, "%s: the seam returned %s, expected %s" % [label, str(battle_mon.get("species_id", "")), species_id]): return {}
	var ok := _ensure(str(battle_mon.get("battle_kind", "")) == "legendary", "%s: battle_kind %s != legendary" % [label, str(battle_mon.get("battle_kind", ""))])
	ok = _ensure(int(battle_mon.get("attack_stages", 0)) == stages, "%s: attack_stages %d != %d" % [label, int(battle_mon.get("attack_stages", 0)), stages]) and ok
	ok = _ensure(int(battle_mon.get("ring", 0)) >= LegendaryPlacement.LEGENDARY_RING_MIN, "%s: the encounter's ring %d < %d" % [label, int(battle_mon.get("ring", 0)), LegendaryPlacement.LEGENDARY_RING_MIN]) and ok
	ok = _ensure(_runner.trace_log_has_since("legendary_encounter", cursor, {"species_id": species_id, "battle_kind": "legendary"}), "%s: no legendary_encounter{battle_kind:legendary} at battle start" % label) and ok
	return battle_mon if ok else {}

# A damaging move that cannot stall (heal/leech would never end the defeat path).
func _damaging_move_index(mon: Dictionary) -> int:
	var moves: Array = mon.get("moves", [])
	for i in range(moves.size()):
		var move: Dictionary = moves[i]
		if int(move.get("power", 0)) > 0 and int(move.get("pp", 0)) > 0 and str(move.get("effect", "")) != "EFFECT_LEECH_HIT" and str(move.get("effect", "")) != "EFFECT_HEAL": return i
	return 0

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
