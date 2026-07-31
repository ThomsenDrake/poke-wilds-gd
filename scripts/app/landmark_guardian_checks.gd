extends RefCounted

# Ruins Underground guardian battle witness (Phase 7 audit R2; world-depth.md § Landmarks,
# CONTROLS.md:195 "ALWAYS aggressive, +3 Attack"). Extracted from world_depth_checks.gd at
# the app 220 wall (the legendary_spawn_checks precedent). THIS owns BOTH guardian witnesses:
# the AGGRESSIVE disposition (audit Major #1 — the persisted disposition + the live
# _disposition_now, since the landmark_entity_spawned trace LITERAL is a constant==constant
# tautology) AND the forced-battle +3 proof through the pending seam — the guardian's defining
# property that the trace payload alone cannot witness. A player-initiated FIRST attack carries NO buff
# (:280, stages 0); the provoked chase-catch carries +3 (:284, stages 3). The set_battle latch
# (main._in_battle) keeps the presentation bridge from consuming the seam, exactly like
# legendary_spawn._prove_whiteout. NO rng, NO I/O beyond the runtime's trace log + pending seam.

const LandmarkRuntime := preload("res://scripts/runtime/landmark_runtime.gd")
# Domain access rides the runtime's own preload (the app layer may not preload domain
# directly — check_architecture.gd's layer table; the world_depth_checks precedent).
const Landmarks := LandmarkRuntime.Landmarks
const OverworldMons := LandmarkRuntime.OverworldMons

const PROVOKED_ATTACK_STAGES := OverworldMons.PROVOKED_ATTACK_STAGES # 3 (:284)


# Engage the persisted DUSCLOPS guardian (spawned by run_ruins_case under opt-in activation;
# the entity outlives the activation flip) through the forced-battle pending seam BOTH ways and
# read the encounter payload off generate_wild_encounter (the seam the battle system consumes).
# ORDER IS LOAD-BEARING: the player-initiated attack runs FIRST so the entity's attack_stages is
# 0 when the provoked case raises it (provoked-after-player; _force_battle takes the MAX of the
# entity's persisted stages and the provoked value, so the reverse order would fake the +3).
static func run_guardian_battle_case(runtime, runner, failures: Array, ctx: Dictionary) -> bool:
	var start: int = failures.size()
	var mons = runtime.overworld_mons_runtime
	var entity: Dictionary = _guardian_entity(mons)
	if entity.is_empty():
		failures.append("guardian: no DUSCLOPS guardian entity persisted after run_ruins_case (the opt-in spawn is broken)")
		return false
	# Disposition witness (audit Major #1): the landmark_entity_spawned disposition LITERAL is a
	# constant==constant tautology (the emit at landmark_runtime.gd:254 hardcodes the SAME
	# OverworldMons.DISPOSITION_AGGRESSIVE a trace-literal assert would match), so it can never red
	# under the named sabotage — a guardian that chases as FRIENDLY. Witness the LIVE chase-driving
	# value here, beside the +3 proof: the persisted entity's stored disposition AND _disposition_now
	# (the value the sim's spotted-chase path reads, overworld_mons_sim.gd:66) BOTH resolve AGGRESSIVE.
	# Sabotaging the stored byte or the kind-driven guardian clause (overworld_mons_runtime.gd:296-297) reds.
	_ensure(failures, str(entity.get("disposition", "")) == OverworldMons.DISPOSITION_AGGRESSIVE, "guardian: the persisted disposition is %s, not AGGRESSIVE" % str(entity.get("disposition", "")))
	_ensure(failures, mons._disposition_now(entity) == OverworldMons.DISPOSITION_AGGRESSIVE, "guardian: _disposition_now resolves %s — the live chase path is not aggression-driven" % str(mons._disposition_now(entity)))
	var guard_tile: Vector2i = entity.get("tile", Vector2i.MAX)
	var player_tile: Vector2i = ctx["player"].tile_position
	var biome: String = ctx["world"].get_tile_biome(player_tile)
	var set_battle: Callable = ctx.get("set_battle", Callable())
	if set_battle.is_valid(): set_battle.call(true) # latch main._in_battle: the presentation bridge early-returns, so the forced battle stays on the DIRECT seam (legendary_spawn precedent)
	# (1) Player-initiated FIRST attack -> NO buff (:280). attack_entity arms the pending seam
	# provoked:false -> stages maxi(0,0)=0; the encounter payload must carry 0.
	var atk: Dictionary = mons.attack_entity(guard_tile)
	if not _ensure(failures, bool(atk.get("ok", false)), "guardian: the player-initiated attack was refused (%s)" % str(atk.get("reason", ""))):
		if set_battle.is_valid(): set_battle.call(false)
		return false
	var plain: Dictionary = runtime.generate_wild_encounter(player_tile, biome)
	_ensure(failures, str(plain.get("species_id", "")) == Landmarks.RUINS_UNDERGROUND_SPECIES, "guardian: the player-initiated seam returned %s, expected %s" % [str(plain.get("species_id", "")), Landmarks.RUINS_UNDERGROUND_SPECIES])
	_ensure(failures, int(plain.get("attack_stages", 0)) == 0, "guardian: the player-initiated encounter carried attack_stages %d (:280 expects 0)" % int(plain.get("attack_stages", 0)))
	# (2) Provoked chase-catch -> +3 (:284). _force_battle(entity, true) raises stages
	# maxi(0,3)=3 and (kind == "guardian") emits alpha_provoked{attack_stages:3}; the pending
	# payload the battle system consumes must carry the +3.
	var provoked_cursor: int = runner.trace_log_line_count()
	var provoked: Dictionary = mons._force_battle(entity, true)
	_ensure(failures, int(provoked.get("attack_stages", 0)) == PROVOKED_ATTACK_STAGES, "guardian: the provoked forced battle carried attack_stages %d != %d (:284)" % [int(provoked.get("attack_stages", 0)), PROVOKED_ATTACK_STAGES])
	var chased: Dictionary = runtime.generate_wild_encounter(player_tile, biome)
	_ensure(failures, int(chased.get("attack_stages", 0)) == PROVOKED_ATTACK_STAGES, "guardian: the provoked encounter payload carried attack_stages %d != %d (:284 — the +3 never reached the seam)" % [int(chased.get("attack_stages", 0)), PROVOKED_ATTACK_STAGES])
	_ensure(failures, runner.trace_log_has_since("alpha_provoked", provoked_cursor, {"species_id": Landmarks.RUINS_UNDERGROUND_SPECIES, "attack_stages": PROVOKED_ATTACK_STAGES}), "guardian: no alpha_provoked{DUSCLOPS,attack_stages:3} on the provoked chase-catch")
	# Tidy the transient battle flags the two pending-seam takes leave armed: NO real battle
	# runs here, so note_battle_outcome never resets them, and the save round-trip that follows
	# must not inherit a dangling engaged entity / _last_battle_was_entity (the sim's safety arm).
	entity["state"] = "idle"; entity["attack_stages"] = 0
	mons._pending_id = ""; mons._last_battle_was_entity = false
	if set_battle.is_valid(): set_battle.call(false)
	return failures.size() == start


# The DUSCLOPS guardian record ({} when absent): a stationary entity of the guardian species.
static func _guardian_entity(mons) -> Dictionary:
	for id in mons._entities.keys():
		var entity: Dictionary = mons._entities[id]
		if str(entity.get("species_id", "")) == Landmarks.RUINS_UNDERGROUND_SPECIES and str(entity.get("kind", "")) == "guardian":
			return entity
	return {}


static func _ensure(failures: Array, ok: bool, label: String) -> bool:
	if not ok:
		failures.append(label)
	return ok
