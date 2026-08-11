extends Node

# Phase-6 ENTITY SOAK (pre-Phase-7 suite): the playtest_bot_entity.gd band (steal-egg /
# provoke-Alpha / charm-recruit / flee-despawn) over hundreds of seeded iterations.
# Postconditions audited every AUDIT_EVERY ticks and once at the end: the sprite count
# stays bounded by the live store, y-sort keys are never NaN, the bot's store hygiene
# holds (pending seam disarmed, no entity past DESPAWN_CELLS, no entity_at on the
# player's tile), and every band engaged at least once (a starved band is LOUD, never a
# silent skip). Self-guarded: the playtest_ prefix skips the dispatcher's save guard, so
# the bot owns the backup/restore (the breed-soak precedent). Phase 7 audit R11 (updated
# for the legendary-dungeon slice): the legendary witness rides the CHAMBER path — the
# boot-time overworld statics are RETIRED, so the soak warps into each anchored dungeon,
# witnesses the stamped chamber legendary through the forced-battle seam, and warps back
# out — a soak that never touches a legendary is LOUD, never a silent pass.

const PlaytestBot := preload("res://scripts/runtime/playtest_bot.gd")
const PlaytestBotEntity := preload("res://scripts/runtime/playtest_bot_entity.gd")
const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")
const WorldDrawOrder := preload("res://scripts/app/world_draw_order.gd")
const OverworldMonsRuntime := preload("res://scripts/runtime/overworld_mons_runtime.gd")
const DungeonRuntime := preload("res://scripts/runtime/dungeon_runtime.gd") # rides its domain preloads (the layer table; the legendary_spawn precedent)
# Domain access rides the runtime's re-export (the app layer may not preload domain
# directly — check_architecture.gd's layer table; the legendary_spawn_checks precedent).
const LegendaryPlacement := OverworldMonsRuntime.LegendaryPlacement
const DungeonMaps := DungeonRuntime.DungeonMaps

const SOAK_SEED := 2026072812 # entity-soak pin (distinct from the joint-pin / save seeds). Build-2 RE-PIN from 2026072806: the contract-required never-encounter exclusion (world-depth.md § Legendaries) reshuffled the roamer pool, so under the old pin the lone near-spawn TIMID flipped disposition and band 3 starved; the whole-store teleport scan then dragged the player ring-91 outward and starved the FRIENDLY bank too (flee 0 / recruit 8). Build-3 RE-PIN from 2026072807 (verify pass, 2026-07-31): the R11 re-stamp assert exposed that the old pin's derived world (world_seed 921588470 — new_game's starter instance consumes ONE _rng draw, so the root_seed is clean-stream index 1, NOT the first draw) carries ZERO affinity-biome anchors inside the ring 60..134 probe budget (a legal NO_ANCHOR — "the world lacks the biome"), so the post-reset re-stamp stamped nothing and the legendary witness starved red. Sibling 2026072810 derived world_seed 1319840800: the SNOW three anchor inside slice 2's ±256 climate reach box (the LAVA four NO_ANCHOR there — the box lacks a pocket; measured), all four bands engaged (flee 2 / recruit 15 / egg 10 / alpha 102). 2026-08-09 RE-PIN (2026072810 -> 2026072812; sibling 2026072811 starved the same way) for the PokeAPI catalog migration gate phase: the 9 newly encounter-eligible species (rotom forms, shellos_east/west, corsola_galarian, gmrmime/mr_mime_galarian — catalog-parity `encounter-eligibility`) joined the TYPE-fallback pools and diluted the 7-species TIMID roster's share (the roster itself is unchanged: EKANS/PIDGEY/PORYGON/RATTATA/SMEARGLE/SPEAROW + the CHANSEY override), so under the old pin band 3 starved exactly like the Build-2 miss (flee 0 / 400, engaged 8). 2026072812 re-engages all four bands with the legendary witness intact — verify pass on BOTH transports, headless + dap (miss-002's "seed is the calibration lever"; no code change). Deterministic; the legendary-dungeon slice RETIRED the boot-time overworld statics, so the R11 witness rides the chamber path: warp into each anchored dungeon (the chamber stamp is the statics' replacement), engage the stamped legendary off the direct forced-battle seam (_prove_chamber_encounters), warp out. NO step-clock tick and the player tile is restored, so the calibrated 400 iterations run exactly as the pin demands — the bot's band targeting still SKIPS legendaries (a whole-store scan would drag the player 60+ rings out and starve the roam banks), never the bands.
const ITERATIONS := 400
const AUDIT_EVERY := 25

var _ctx: Dictionary = {}
var _runner = SmokeScenarioRunner.new()
var _bot = PlaytestBot.new()
var _band = PlaytestBotEntity.new()
var _reasons: Array = []


func run(ctx: Dictionary) -> void:
	_ctx = ctx
	await get_tree().create_timer(0.2).timeout
	_bot.backup_save()
	var runtime = _runtime()
	var mons: Object = runtime.get("overworld_mons_runtime")
	var rng := RandomNumberGenerator.new()
	rng.seed = SOAK_SEED
	runtime.seed_for_smoke(SOAK_SEED) # before new_game: the world seed is pinned too
	runtime.new_game()
	_world().rebuild(runtime.get_world_seed()) # the view owns its own generator: re-seed it or the bot's far walkability reads answer from the BOOT world (the playtest _fresh_game precedent)
	var player := _player()
	_runner.teleport_player(_world(), player, runtime, runtime.get_player_tile()) # hermeticity (2026-08-09 gate): new_game moves the SESSION tile but not the player NODE, so the bot's whole-store nearest-target walk otherwise starts from the BOOT save's tile and the soak's outcome becomes a function of the leftover user save (a [26,26] boot walks SNOVER-first and starves the FRIENDLY bank; the calibrated walk starts at the soak spawn)
	var saved_chance: float = player.encounter_chance
	player.encounter_chance = 0.0
	var stats := {"iterations": 0, "engaged": 0, "starved": 0, "egg_attempts": 0, "eggs_stolen": 0,
		"alpha_attempts": 0, "alpha_provoked": 0, "recruit_attempts": 0, "recruits": 0,
		"flee_attempts": 0, "flees_startled": 0, "legendary_encounters": 0, "max_sprites": 0}
	if mons == null:
		_reasons.append("overworld_mons_runtime is not wired")
	else:
		_reset(mons)
		var spawn_tile: Vector2i = runtime.get_player_tile() # the dungeon-witness warps move the SESSION tile; restored below so the calibrated walk starts exactly at the soak spawn
		_prove_chamber_encounters(runtime, mons, stats) # R11: the legendary witness rides the CHAMBER path (the retired boot-time statics' replacement)
		if int(stats.get("legendary_encounters", 0)) == 0:
			_reasons.append("legendaries: ZERO chamber witnesses under seed %d — no anchored dungeon stamped/engaged (re-pin SOAK_SEED, miss-002's calibration lever)" % SOAK_SEED)
		_runner.teleport_player(_world(), player, runtime, spawn_tile)
		mons.active = true # the dispatcher's activation gate leaves this scenario inert; the soak opts in
		for i in range(ITERATIONS):
			stats["iterations"] = int(stats["iterations"]) + 1
			_band.iterate(runtime, mons, player, _world(), _runner, rng, stats)
			if i % AUDIT_EVERY == AUDIT_EVERY - 1:
				await get_tree().create_timer(0.0).timeout # one frame: the entity layer's sync catches up
				_audit_sprites(mons, stats)
				var problem := _band.store_clean(mons, player.tile_position)
				if not problem.is_empty():
					_reasons.append("iter %d: %s" % [i, problem])
		var final := _band.store_clean(mons, player.tile_position)
		if not final.is_empty():
			_reasons.append("final: %s" % final)
		_check_engagement(stats)
		mons.active = false
	player.encounter_chance = saved_chance
	_emit(runtime, stats)
	_bot.restore_save()


# The scenario-harness reset (the overworld_mons_checks.reset_entities precedent): a
# fresh derivation with every transient cleared, so the soak starts from a known store.
func _reset(mons) -> void:
	mons._entities.clear(); mons._removed.clear(); mons._nests_found.clear(); mons._pool_cache.clear()
	mons._pending = {}; mons._pending_id = ""; mons._last_battle_was_entity = false
	mons._time_label = ""; mons._faced_tile = Vector2i.MAX; mons._last_interact_id = ""; mons._last_interact_step = -100


func _audit_sprites(mons, stats: Dictionary) -> void:
	var layer := _entity_layer()
	if layer == null:
		_reasons.append("audit: the EntityLayer node is missing")
		return
	var live: int = mons._entities.size()
	var sprites: int = layer._entity_nodes.size()
	stats["max_sprites"] = maxi(int(stats.get("max_sprites", 0)), sprites)
	if sprites > live + 2: # a frame of sync slack, never a leak
		_reasons.append("audit: %d sprites over a %d-entity live store (sprite leak)" % [sprites, live])
	for entity_id in layer._entity_nodes.keys():
		var record: Dictionary = layer._entity_nodes[entity_id]
		var sprite: Variant = record.get("sprite")
		if sprite is CanvasItem:
			var key := WorldDrawOrder.y_sort_key(sprite as CanvasItem)
			if is_nan(key) or is_inf(key):
				_reasons.append("audit: entity %s has a non-finite y-sort key (%f)" % [str(entity_id), key])
				return


# Every band must have engaged at least once over the soak (miss-002: a band that never
# fires is a LOUD named skip, never a silent pass — the seed is the calibration lever).
func _check_engagement(stats: Dictionary) -> void:
	for band_key in ["egg_attempts", "alpha_attempts", "recruit_attempts", "flee_attempts"]:
		if int(stats.get(band_key, 0)) == 0:
			_reasons.append("band %s starved: zero engagements across %d iterations" % [band_key, ITERATIONS])


# R11: witness EVERY anchored legendary through its DUNGEON CHAMBER (the retired boot-time
# statics' replacement): warp in off the entrance anchor (try_enter_at stamps the chamber),
# engage the stationary through the forced-battle seam — the alpha band's own attack_entity
# path (:280 player-initiated; NO rng beyond the shared gender nonce, an intentional
# creation-order consumer — the SAME per-legendary consume count the retired statics path
# had) — then warp out (the chamber entity dies with the context, never the calibrated
# walk's store). The set_battle latch keeps main._in_battle set so the presentation bridge
# early-returns (the legendary_spawn precedent): the pending seam arms on the DIRECT take,
# the species is counted, and the seam is disarmed — never a real battle view. NO step-clock
# tick; the caller restores the player tile, so the 400 iterations run exactly as pinned.
func _prove_chamber_encounters(runtime, mons, stats: Dictionary) -> void:
	var set_battle: Callable = _ctx.get("set_battle", Callable())
	if set_battle.is_valid(): set_battle.call(true) # latch the presentation bridge: the forced battle stays on the DIRECT seam, never the battle view
	var seed: int = runtime.get_world_seed()
	for species in LegendaryPlacement.LEGENDARY_IDS:
		var sid := str(species)
		var anchor: Vector2i = DungeonMaps.entrance_anchor_for(seed, sid) # the SAME sibling-exclusion derivation the retired statics rode
		if anchor == LegendaryPlacement.NO_ANCHOR:
			continue # a legal NO_ANCHOR (the reach box lacks the affinity pocket): no dungeon, no witness
		var dungeon_id: String = DungeonMaps.dungeon_for_species(sid)
		if not runtime.dungeon_runtime.try_enter_at(anchor):
			# SEAL_DUNGEON (Regigigas) refuses by construction — the bag holds no tablets mid-soak;
			# the traced dungeon_entry_refused IS its witness. Any other refusal is LOUD.
			if dungeon_id != DungeonRuntime.DungeonLayouts.SEAL_DUNGEON:
				_reasons.append("legendaries: the warp into the %s dungeon refused" % sid)
			continue
		var entity: Dictionary = mons._entities.get("legendary_%s" % dungeon_id, {})
		var result: Dictionary = mons.attack_entity(entity.get("tile", Vector2i.MAX)) if not entity.is_empty() else {}
		var pending: Dictionary = mons.take_pending_encounter(); mons._pending_id = ""
		if entity.is_empty():
			_reasons.append("legendaries: the %s dungeon stamped no chamber entity" % sid)
		elif bool(result.get("ok", false)) and str(pending.get("species_id", "")) == sid:
			stats["legendary_encounters"] = int(stats.get("legendary_encounters", 0)) + 1
		else:
			_reasons.append("legendaries: attack_entity on the chamber %s did not arm the forced-battle seam (%s)" % [sid, str(result.get("reason", "pending empty"))])
		runtime.dungeon_runtime.exit_dungeon() # the warp-out wipes the live store (the whittle skips a fresh 0/0 entity)
	if set_battle.is_valid(): set_battle.call(false)
	mons._last_battle_was_entity = false # clean latch state: the loop's chase-catch gate opens exactly as on a fresh soak


func _emit(runtime, stats: Dictionary) -> void:
	if _reasons.is_empty():
		var payload: Dictionary = stats.duplicate()
		payload["seed"] = SOAK_SEED
		runtime.emit_trace("playtest_entity_soak_passed", "SmokeScenarios", payload)
	else:
		runtime.emit_trace("playtest_entity_soak_failed", "SmokeScenarios", {"seed": SOAK_SEED, "reasons": _reasons, "stats": stats})
		push_error("PlaytestEntitySoakScenario failed: %s" % "; ".join(PackedStringArray(_reasons)))
		runtime.warn("PlaytestEntitySoakScenario", "Entity soak failed.", {"reasons": _reasons})


func _entity_layer() -> Node: # the world_entity_audit path: a sibling of the player under Main
	var parent := _player().get_parent()
	return parent.get_node_or_null("EntityLayer") if parent != null else null


func _world() -> Node: return _ctx["world"]
func _player() -> Node: return _ctx["player"]
func _runtime() -> Node: return _ctx["runtime"]
