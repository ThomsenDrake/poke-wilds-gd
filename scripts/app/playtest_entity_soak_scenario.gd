extends Node

# Phase-6 ENTITY SOAK (pre-Phase-7 suite): the playtest_bot_entity.gd band (steal-egg /
# provoke-Alpha / charm-recruit / flee-despawn) over hundreds of seeded iterations.
# Postconditions audited every AUDIT_EVERY ticks and once at the end: the sprite count
# stays bounded by the live store, y-sort keys are never NaN, the bot's store hygiene
# holds (pending seam disarmed, no entity past DESPAWN_CELLS, no entity_at on the
# player's tile), and every band engaged at least once (a starved band is LOUD, never a
# silent skip). Self-guarded: the playtest_ prefix skips the dispatcher's save guard, so
# the bot owns the backup/restore (the breed-soak precedent). Phase 7 audit R11: the
# harness reset wipes new_game's legendary statics, so the soak RE-STAMPS the frozen seven
# (the whole soak runs WITH the window-exempt statics in the store) and engages each
# anchored legendary through the forced-battle seam at least once — a soak that never
# touches a legendary is LOUD, never a silent pass.

const PlaytestBot := preload("res://scripts/runtime/playtest_bot.gd")
const PlaytestBotEntity := preload("res://scripts/runtime/playtest_bot_entity.gd")
const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")
const WorldDrawOrder := preload("res://scripts/app/world_draw_order.gd")
const OverworldMonsRuntime := preload("res://scripts/runtime/overworld_mons_runtime.gd")
# Domain access rides the runtime's re-export (the app layer may not preload domain
# directly — check_architecture.gd's layer table; the legendary_spawn_checks precedent).
const LegendaryPlacement := OverworldMonsRuntime.LegendaryPlacement

const SOAK_SEED := 2026072810 # entity-soak pin (distinct from the joint-pin / save seeds). Build-2 RE-PIN from 2026072806: the contract-required never-encounter exclusion (world-depth.md § Legendaries) reshuffled the roamer pool, so under the old pin the lone near-spawn TIMID flipped disposition and band 3 starved; the whole-store teleport scan then dragged the player ring-91 outward and starved the FRIENDLY bank too (flee 0 / recruit 8). Build-3 RE-PIN from 2026072807 (verify pass, 2026-07-31): the R11 re-stamp assert exposed that the old pin's derived world (world_seed 921588470 — new_game's starter instance consumes ONE _rng draw, so the root_seed is clean-stream index 1, NOT the first draw) carries ZERO affinity-biome anchors inside the ring 60..134 probe budget (a legal NO_ANCHOR — "the world lacks the biome"), so the post-reset re-stamp stamped nothing and the legendary witness starved red. This sibling derives world_seed 1319840800: the SNOW three anchor inside slice 2's ±256 climate reach box (the LAVA four NO_ANCHOR here — the box lacks a pocket; measured), and all four bands re-engage (flee 2 / recruit 15 / egg 10 / alpha 102, warn 1 — miss-002's "seed is the calibration lever"). Deterministic; the harness reset wipes the stamped statics, and the R11 RE-STAMP returns the anchored frozen seven to the store for the whole soak — the bot's band targeting still SKIPS them (a whole-store scan would drag the player 60+ rings out and starve the roam banks), so the legendaries are witnessed by the direct forced-battle seam (_prove_legendary_encounters), never the bands.
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
	var saved_chance: float = player.encounter_chance
	player.encounter_chance = 0.0
	var stats := {"iterations": 0, "engaged": 0, "starved": 0, "egg_attempts": 0, "eggs_stolen": 0,
		"alpha_attempts": 0, "alpha_provoked": 0, "recruit_attempts": 0, "recruits": 0,
		"flee_attempts": 0, "flees_startled": 0, "legendary_encounters": 0, "max_sprites": 0}
	if mons == null:
		_reasons.append("overworld_mons_runtime is not wired")
	else:
		_reset(mons)
		mons.stamp_legendaries() # R11: the harness reset wipes new_game's stamped statics — RE-STAMP so the whole soak runs WITH the frozen seven in the store (window-exempt static persistence + sprite sync + store hygiene witnessed on every audit tick)
		var stamped: int = _legendary_entities(mons).size()
		if stamped == 0:
			_reasons.append("legendaries: the post-reset re-stamp derived ZERO anchored statics under seed %d (re-pin SOAK_SEED — miss-002's calibration lever)" % SOAK_SEED)
		else:
			_prove_legendary_encounters(mons, stats)
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
		if int(stats.get("legendary_encounters", 0)) == 0:
			_reasons.append("legendary encounters starved: ZERO across the soak (the re-stamp + the direct forced-battle seam never fired — the distance-gated statics went untouched)")
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


# R11: engage EVERY anchored legendary through the forced-battle seam — the alpha band's
# own attack_entity path (:280 player-initiated; NO rng beyond the shared gender nonce, an
# intentional creation-order consumer). The set_battle latch keeps main._in_battle set so
# the presentation bridge early-returns (the legendary_spawn / landmark_guardian_checks
# precedent): the pending seam arms on the DIRECT take, the species is counted, and the
# seam is disarmed — never a real battle view. NO step-clock tick and NO player move, so
# the calibrated 400 iterations run exactly as the SOAK_SEED pin demands; legendaries ride
# the store for the whole soak regardless.
func _prove_legendary_encounters(mons, stats: Dictionary) -> void:
	var set_battle: Callable = _ctx.get("set_battle", Callable())
	if set_battle.is_valid(): set_battle.call(true) # latch the presentation bridge: the forced battle stays on the DIRECT seam, never the battle view
	for entity in _legendary_entities(mons):
		var species := str(entity.get("species_id", ""))
		var result: Dictionary = mons.attack_entity(entity.get("tile", Vector2i.MAX))
		var pending: Dictionary = mons.take_pending_encounter(); mons._pending_id = ""
		if bool(result.get("ok", false)) and LegendaryPlacement.LEGENDARY_IDS.has(str(pending.get("species_id", ""))):
			stats["legendary_encounters"] = int(stats.get("legendary_encounters", 0)) + 1
		else:
			_reasons.append("legendaries: attack_entity on the anchored %s did not arm the forced-battle seam (%s)" % [species, str(result.get("reason", "pending empty"))])
		entity["state"] = "idle"; entity["attack_stages"] = 0 # the take leaves "engaged"/+stages behind; tidy so the loop's step clock sees an idle static (the landmark_guardian_checks cleanup precedent)
	if set_battle.is_valid(): set_battle.call(false)
	mons._last_battle_was_entity = false # clean latch state: the loop's chase-catch gate opens exactly as on a fresh soak


# The anchored frozen seven currently IN the store (kind "legendary" records; the origin
# world anchors at least one under any seed with a ring-band affinity biome — the
# legendary_spawn pin's SNOW three under ITS seed; the soak seed derives its own set).
func _legendary_entities(mons) -> Array:
	var legendaries: Array = []
	for entity_id in mons._entities.keys():
		var entity: Dictionary = mons._entities[entity_id]
		if str(entity.get("kind", "")) == "legendary":
			legendaries.append(entity)
	return legendaries


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
