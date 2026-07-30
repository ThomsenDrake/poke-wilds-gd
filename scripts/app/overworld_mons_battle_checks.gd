extends Node
# Phase 6 overworld mons gate-scenario check groups, part 2 (spec: docs/product-specs/
# overworld-pokemon.md § Smoke validation; the breed_flow_checks split precedent):
# HOSTILE ENGAGE — Attack forces the seam provoked:false/NO buff (:280), a chase-catch
# forces it provoked:true/+3 (:284), and Repel active the provoked battle STILL lands
# while the grass stream stays suppressed (pending-seam ordering); EGG TAKE -> ALPHA —
# nest_found, the :248 Attack/TAKE binary, the guardian forced battle, the level-5 hatch.
# Shared oracle helpers ride scripts/runtime/overworld_mons_probe.gd; NO domain preloads.
const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")
const VisualSweepBaselines := preload("res://scripts/app/visual_sweep_baselines.gd")
const Phase5 := preload("res://scripts/runtime/phase5_support.gd")
const OverworldMonsProbe := preload("res://scripts/runtime/overworld_mons_probe.gd")
const DAY_MINUTES := 600
const PROVOKED_ATTACK_STAGES := 3 # mirrors OverworldMons.PROVOKED_ATTACK_STAGES (:284)
const HATCH_STEPS := 2688 # DEFAULT_STEPS_TO_HATCH(2560) + headroom (breed_flow convention)
const NEST_EGGS := 2 # mirrors OverworldMons.NEST_EGGS (scenario contract)
const NEST_CENTERS := [Vector2i(88, 88), Vector2i(120, 88), Vector2i(88, 120), Vector2i(152, 88),
	Vector2i(88, 152), Vector2i(120, 120), Vector2i(184, 88), Vector2i(88, 184),
	Vector2i(152, 120), Vector2i(120, 152), Vector2i(216, 88), Vector2i(88, 216)]
var _ctx: Dictionary = {}
var _runner = SmokeScenarioRunner.new()
var _baselines = VisualSweepBaselines.new()
var probe = OverworldMonsProbe.new()
var _failures: Array = []
var _seed: int = 0
var _anchors: Dictionary = {}
var hatched_species := "" # the save-case witness (the party channel persists)
func setup(ctx: Dictionary, runner: SmokeScenarioRunner, failures: Array, seed: int) -> void:
	_ctx = ctx; _runner = runner; _failures = failures; _seed = seed

# --- HOSTILE: the forced seam both ways + the Repel ordering ----------------------
func run_hostile_case(runtime) -> bool:
	if not _craft(runtime):
		return _ensure(false, "hostile: crafted state failed")
	await get_tree().process_frame # flush the spawn case's deferred tile frees before more teleports
	var mons := _mons(runtime)
	_runner.teleport_player(_world(), _player(), runtime, _player().tile_position)
	runtime.note_player_step() # sync the window (craft + reset left the store empty)
	# (a) Player-initiated Attack: provoked:false, NO +3 buff (:280); escape leaves the mon (:288).
	var target := _first_idle_mon(mons, _player().tile_position)
	if target.is_empty():
		return _ensure(false, "hostile: no idle roamer near spawn for the Attack path")
	_stand_by(runtime, mons, target.tile)
	var cursor_a := _runner.trace_log_line_count()
	var atk: Dictionary = runtime.field_move_runtime.use_attack(str(target.species_id))
	if not _ensure(bool(atk.get("ok", false)), "hostile: use_attack refused"): return false
	if not _ensure(_runner.trace_log_has_since("overworld_attack", cursor_a, {"target_species_id": str(target.species_id)}), "hostile: no overworld_attack trace"): return false
	var battle_mon: Dictionary = runtime.generate_wild_encounter(_player().tile_position, _world().get_tile_biome(_player().tile_position))
	if not _ensure(str(battle_mon.get("species_id", "")) == str(target.species_id), "hostile: the seam returned %s, expected %s" % [str(battle_mon.get("species_id", "")), str(target.species_id)]): return false
	if not _ensure(int(battle_mon.get("attack_stages", 0)) == 0, "hostile: a player-initiated battle carried the +3 buff (:280 violation)"): return false
	if not _escape_battle(runtime, battle_mon): return false
	var alive := probe.by_id(mons, _player().tile_position, str(target.id))
	if not _ensure(not alive.is_empty() and str(alive.get("state", "")) == "idle", "hostile: the escaped mon left the overworld (:288 violation)"): return false
	# (b) Aggressive chase-catch: provoked:true + the +3 attack stages (:284).
	var provoked_species := await _provoke_chase_catch(runtime, mons)
	if provoked_species.is_empty():
		return _ensure(false, "hostile: no aggressive chase-catch armed the seam within the step budget")
	var chased: Dictionary = runtime.generate_wild_encounter(_player().tile_position, _world().get_tile_biome(_player().tile_position))
	if not _ensure(provoked_species.has(str(chased.get("species_id", ""))), "hostile: the chase battle species %s is not a seeded aggressive" % str(chased.get("species_id", ""))): return false
	if not _ensure(int(chased.get("attack_stages", 0)) == PROVOKED_ATTACK_STAGES, "hostile: the provoked battle lacks the +3 stages (:284 violation; got %d)" % int(chased.get("attack_stages", 0))): return false
	if not _escape_battle(runtime, chased): return false
	# (c) Repel ordering: grass suppressed, the provoked battle STILL lands (the pending seam first).
	runtime.field_move_runtime.activate_repel(100)
	if not _ensure(runtime.generate_wild_encounter(_player().tile_position, _world().get_tile_biome(_player().tile_position)).is_empty(), "hostile: repel did not suppress the grass stream"): return false
	var target3 := _first_idle_mon(mons, _player().tile_position)
	if target3.is_empty():
		return _ensure(false, "hostile: no idle roamer for the repel-ordered Attack")
	_stand_by(runtime, mons, target3.tile)
	runtime.field_move_runtime.use_attack(str(target3.species_id))
	var repelled: Dictionary = runtime.generate_wild_encounter(_player().tile_position, _world().get_tile_biome(_player().tile_position))
	if not _ensure(not repelled.is_empty(), "hostile: repel blocked the provoked battle (seam-order violation)"): return false
	_escape_battle(runtime, repelled)
	runtime.session.repel_steps = 0
	return true

# --- EGGS: nest_found, the :248 Attack/TAKE binary, the Alpha battle, the hatch ---
func run_egg_case(runtime, shiny_ok_ref: Array) -> bool:
	if not _craft(runtime):
		return _ensure(false, "egg: crafted state failed")
	await get_tree().process_frame # flush prior deferred tile frees before the nest teleports
	var mons := _mons(runtime)
	var nest := probe.find_nest(mons, NEST_CENTERS, 56)
	if nest == Vector2i.ZERO:
		return _ensure(false, "egg: no nest cell in the deterministic search sequence")
	_runner.teleport_player(_world(), _player(), runtime, nest + Vector2i(2, 2))
	var cursor_n := _runner.trace_log_line_count()
	runtime.note_player_step() # sync materializes the guardian + eggs + nest_found
	if not _ensure(_runner.trace_log_has_since("nest_found", cursor_n), "egg: no nest_found trace"): return false
	var eggs := _eggs_near(mons, nest)
	if not _ensure(eggs.size() == NEST_EGGS, "egg: the nest holds %d eggs, pinned %d (NEST_EGGS)" % [eggs.size(), NEST_EGGS]): return false
	var guardian_species := ""; var guardian_entity: Dictionary = {} # the live guardian beside THESE eggs (a second nest cell may share the window)
	for e in probe.live(mons, nest, 12):
		if str(e.get("kind", "")) == "guardian": guardian_entity = e; guardian_species = str(e.species_id); break
	if not _ensure(guardian_species != "", "egg: the nest cell materialized no guardian"): return false
	# Build 2's never-encounter exclusion reshuffled the roaming pools (legendaries slipped the TYPE-sentinel
	# fallback), so the pinned nest's natural alpha may share NO egg group with the egg — re-craft the alpha as
	# the egg's own species (PRIMEAPE-injection precedent), placed spotted-from-the-stand so the hatch-drive recapture rides the real mechanic.
	if str(guardian_entity.species_id) != str(eggs[1].species_id):
		mons._entities.erase(str(guardian_entity.id))
		var parent_tile := Vector2i.ZERO; var stand: Vector2i = nest + Vector2i(2, 2)
		for r in range(1, 9): # inside GUARDIAN_SPOT_RADIUS(8) of the stand AND EGG_PROVOKE_RADIUS(6) of the stolen egg
			for d in [Vector2i.DOWN, Vector2i.UP, Vector2i.LEFT, Vector2i.RIGHT]:
				var candidate: Vector2i = stand + d * r
				if parent_tile == Vector2i.ZERO and _world().is_tile_walkable(candidate) and absi(candidate.x - eggs[1].tile.x) + absi(candidate.y - eggs[1].tile.y) <= 6: parent_tile = candidate
		if parent_tile != Vector2i.ZERO:
			var parent: Dictionary = mons.get("_sim").call("new_mon", str(guardian_entity.id), "stationary", 0, Vector2i(floori(float(parent_tile.x) / 8.0), floori(float(parent_tile.y) / 8.0)), str(eggs[1].species_id), parent_tile, 5, "AGGRESSIVE")
			mons._entities[str(parent.id)] = parent
			guardian_species = str(parent.species_id)
	# Attack-on-egg: shiny-check + clear, NO provocation, NO battle (the :248 silence witness).
	var egg_attack: Dictionary = eggs[0]
	mons.call("note_faced_tile", egg_attack.tile)
	var cursor_atk := _runner.trace_log_line_count()
	runtime.field_move_runtime.use_attack(str(egg_attack.species_id))
	if not _ensure(_runner.trace_log_has_since("egg_cleared", cursor_atk, {"species_id": str(egg_attack.species_id), "is_shiny": bool(egg_attack.is_shiny)}), "egg: no egg_cleared trace for the Attack-on-egg"):
		return false
	if not _ensure(probe.trace_count(cursor_atk, "mon_provoked") == 0 and probe.trace_count(cursor_atk, "alpha_provoked") == 0, "egg: Attack-on-egg provoked a mon (:248 binary violation)"): return false
	if not _ensure((mons.call("take_pending_encounter") as Dictionary).is_empty(), "egg: Attack-on-egg armed the battle seam"): return false
	# TAKE: egg_stolen, provocation, alpha_provoked{+3}, the guardian forced battle.
	runtime.session.party.resize(5)
	var egg_taken: Dictionary = eggs[1]
	var cursor_t := _runner.trace_log_line_count()
	var taken: Dictionary = mons.call("interact", egg_taken.tile) # the Z arm routes to egg_take
	if not _ensure(bool(taken.get("ok", false)), "egg: TAKE refused (%s)" % str(taken.get("reason", ""))): return false
	if not _ensure(_runner.trace_log_has_since("egg_stolen", cursor_t, {"species_id": str(egg_taken.species_id)}), "egg: no egg_stolen trace"): return false
	if not _ensure(probe.trace_count(cursor_t, "mon_provoked", {"cause": "egg_theft"}) >= 1, "egg: the theft provoked nobody (parents/egg-group rule)"): return false
	if not _ensure(_runner.trace_log_has_since("alpha_provoked", cursor_t, {"attack_stages": PROVOKED_ATTACK_STAGES}), "egg: no alpha_provoked{stages:3}"): return false
	var alpha: Dictionary = runtime.generate_wild_encounter(_player().tile_position, _world().get_tile_biome(_player().tile_position))
	if not _ensure(str(alpha.get("species_id", "")) == guardian_species and int(alpha.get("attack_stages", 0)) == PROVOKED_ATTACK_STAGES, "egg: the forced battle is %s (stages %d), expected guardian %s +3" % [str(alpha.get("species_id", "")), int(alpha.get("attack_stages", 0)), guardian_species]):
		return false
	shiny_ok_ref[0] = (probe.trace_count(cursor_t, "shiny_rolled", {"origin": "overworld"}) >= 1) and shiny_ok_ref[0]
	_escape_battle(runtime, alpha)
	# The stolen egg rides the party channel and hatches on the existing step clock at level 5.
	if not _ensure(_party_egg_species(runtime) == str(egg_taken.species_id), "egg: no party egg for the taken %s" % str(egg_taken.species_id)): return false
	var cursor_h := _runner.trace_log_line_count()
	Phase5.pen_tick(runtime, HATCH_STEPS) # real steps (the note_player_step loop)
	if not _ensure(_runner.trace_log_has_since("egg_hatched", cursor_h, {"species_id": str(egg_taken.species_id), "level": 5}), "egg: the stolen egg did not hatch at level 5 within %d steps" % HATCH_STEPS):
		return false
	hatched_species = str(egg_taken.species_id)
	return _ensure(_party_egg_species(runtime).is_empty(), "egg: an egg still rides the party after hatching")
# Aggressive chase-catch: craft a PRIMEAPE on a CLEAR corridor beside the player (a
# SAVANNA tile -> resolves AGGRESSIVE live); the greedy chase has no pathfinding, so a
# verified straight line guarantees the catch. Steps until adjacency arms the forced
# battle (provoked:true, +3 stages :284).
func _provoke_chase_catch(runtime, mons) -> Array:
	for anchor_k in range(3):
		await get_tree().process_frame
		var anchor: Vector2i = _anchor("SAVANNA")
		if anchor == Vector2i.MAX: return []
		var stand: Vector2i = anchor if anchor_k == 0 else probe.band_point(absi(anchor.x) + absi(anchor.y) + 8 * anchor_k, anchor_k)
		_runner.teleport_player(_world(), _player(), runtime, stand)
		runtime.note_player_step()
		for d in [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]:
			for r in [3, 2]: # manhattan 2-3: inside SPOT_RADIUS(6), outside CATCH_RADIUS(1)
				var mon_tile: Vector2i = _player().tile_position + d * r
				var logic: Dictionary = _world().get_tile_logic(mon_tile)
				if not bool(logic.get("walkable", false)) or str(logic.get("biome", "")) != "SAVANNA": continue
				var clear := true
				for m in range(1, r):
					if not _world().is_tile_walkable(_player().tile_position + d * m): clear = false; break
				if not clear: continue
				var cell := Vector2i(floori(float(mon_tile.x) / 8.0), floori(float(mon_tile.y) / 8.0))
				var record: Dictionary = mons.get("_sim").call("new_mon", "inject_PRIMEAPE", "roaming", 0, cell, "PRIMEAPE", mon_tile, 5, "AGGRESSIVE")
				mons._entities[str(record.id)] = record
				for _step in range(8):
					runtime.note_player_step()
					if not (mons.get("_pending") as Dictionary).is_empty(): return ["PRIMEAPE"]
	return []

func _eggs_near(mons, center: Vector2i) -> Array:
	var eggs: Array = []
	for e in probe.live(mons, center, 12):
		if str(e.get("kind", "")) == "egg":
			eggs.append(e)
	eggs.sort_custom(func(a, b): return str(a.get("id", "")) < str(b.get("id", "")))
	return eggs
func _first_idle_mon(mons, center: Vector2i) -> Dictionary:
	for e in probe.live(mons, center, 16):
		if str(e.get("kind", "")) == "mon" and str(e.get("state", "")) == "idle":
			return e
	return {}
func _stand_by(runtime, mons, tile: Vector2i) -> void:
	for direction in [Vector2i.DOWN, Vector2i.UP, Vector2i.LEFT, Vector2i.RIGHT]:
		if _world().is_tile_walkable(tile + direction):
			_runner.teleport_player(_world(), _player(), runtime, tile + direction)
			mons.call("note_faced_tile", tile)
			return
	_runner.teleport_player(_world(), _player(), runtime, tile)
# Resolve through the real battle path (note_battle_outcome rides game_runtime._finish_battle).
func _escape_battle(runtime, mon: Dictionary) -> bool:
	runtime.start_wild_battle(mon)
	var response: Dictionary = runtime.run_from_battle()
	return _ensure(bool(response.get("finished", false)) and str(response.get("outcome", "")) == "escaped", "battle: escape failed (%s)" % str(response.get("outcome", "")))
func _party_egg_species(runtime) -> String:
	for mon in runtime.session.party:
		if mon is Dictionary and bool((mon as Dictionary).get("is_egg", false)):
			return str(((mon as Dictionary).get("egg", {}) as Dictionary).get("species_id", ""))
	return ""
func _craft(runtime) -> bool: # mirror of overworld_mons_checks.craft (each check file stands alone)
	var spec := {"world_seed": _seed, "time_of_day": DAY_MINUTES, "bag": {}, "party": [
		["RHYPERIOR", 50], ["CHARIZARD", 50], ["MACHOP", 50], ["CALYREX", 50], ["DEDENNE", 50], ["DRAPION", 50]]}
	var ok := _baselines.craft_state(_ctx, _runner, spec)
	if ok:
		runtime.session.repel_steps = 0
		var mons := _mons(runtime)
		mons._entities.clear(); mons._removed.clear(); mons._nests_found.clear(); mons._pool_cache.clear()
		mons._pending = {}; mons._pending_id = ""; mons._last_battle_was_entity = false
		mons._time_label = ""; mons._faced_tile = Vector2i.MAX; mons._last_interact_id = ""; mons._last_interact_step = -100
		mons.active = true
	return ok
func _anchor(biome: String) -> Vector2i:
	if _anchors.is_empty():
		_anchors = probe.biome_anchors(_world(), ["SAVANNA", "DESERT", "WATER"])
	return _anchors.get(biome, Vector2i.MAX)
func _ensure(ok: bool, label: String) -> bool:
	if not ok:
		_failures.append(label)
	return ok
func _mons(runtime) -> Object: return runtime.get("overworld_mons_runtime")
func _world() -> Node: return _ctx["world"]
func _player() -> Node: return _ctx["player"]
