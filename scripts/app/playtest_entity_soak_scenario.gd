extends Node

# Phase-6 ENTITY SOAK (pre-Phase-7 suite): the playtest_bot_entity.gd band (steal-egg /
# provoke-Alpha / charm-recruit / flee-despawn) over hundreds of seeded iterations.
# Postconditions audited every AUDIT_EVERY ticks and once at the end: the sprite count
# stays bounded by the live store, y-sort keys are never NaN, the bot's store hygiene
# holds (pending seam disarmed, no entity past DESPAWN_CELLS, no entity_at on the
# player's tile), and every band engaged at least once (a starved band is LOUD, never a
# silent skip). Self-guarded: the playtest_ prefix skips the dispatcher's save guard, so
# the bot owns the backup/restore (the breed-soak precedent).

const PlaytestBot := preload("res://scripts/runtime/playtest_bot.gd")
const PlaytestBotEntity := preload("res://scripts/runtime/playtest_bot_entity.gd")
const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")
const WorldDrawOrder := preload("res://scripts/app/world_draw_order.gd")

const SOAK_SEED := 2026072807 # entity-soak pin (distinct from the joint-pin / save seeds). Build-2 RE-PIN from 2026072806: the contract-required never-encounter exclusion (world-depth.md § Legendaries) reshuffled the roamer pool, so under the old pin the lone near-spawn TIMID flipped disposition and band 3 starved; the whole-store teleport scan then dragged the player ring-91 outward and starved the FRIENDLY bank too (flee 0 / recruit 8). This sibling seed re-engages all four bands under the reshuffled pool (flee 3 / recruit 22 / egg 19 / alpha 107, warn 1) — miss-002's "seed is the calibration lever". Deterministic; the legendaries themselves are NOT in this soak's store (the harness reset wipes the stamped statics), so the bot's legendary band-exclusion is defense-in-depth, not this lever.
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
		"flee_attempts": 0, "flees_startled": 0, "max_sprites": 0}
	if mons == null:
		_reasons.append("overworld_mons_runtime is not wired")
	else:
		_reset(mons)
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
