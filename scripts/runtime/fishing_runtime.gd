extends RefCounted

# Fishing runtime (Phase 5; spec: docs/product-specs/breeding-shinies-drops-fishing.md).
# EXTRACTED per the line-budget contract (game_runtime.gd stays AT its 320 budget;
# it only instantiates + setup()s this beside the other runtimes), injected with the
# SHARED _rng so casts stay deterministic under seed_for_smoke — the exact
# night_system pattern. Activation: overworld Z facing a water tile with a bagged
# rod (field_action_router's fishing arm — from shore, no Surf needed, since water
# tiles are walkable=false / encounter=false / surf-gated). The BEST bagged rod
# casts (Super > Good > Old). The wiki describes NO minigame: every cast facing
# water HOOKS, drawn from the rod tier's pool — better rod -> strictly better mons
# (fishing.gd's cumulative tiers). Water tiles spawn NO encounters otherwise, so
# fishing is purely additive — no existing encounter stream changes.
#
# BATTLE HANDOFF: a hooked mon rides the pending-encounter seam — the router emits
# player_avatar.encounter_requested so main presents the battle through the normal
# path (battle view + cry + music), and game_runtime.generate_wild_encounter returns
# the pending mon BEFORE the wild draw. Repel therefore never suppresses a hooked
# mon and unlit-night ghosts never replace it — canonical: Repel affects grass
# encounters, not fishing, and the night system's shadow draw is a grass hazard.
# game_runtime._finish_battle traces fish_caught when a fishing battle ends in a
# capture (consume_fishing_battle clears the mark on ANY finished battle, so the
# flag can never leak into an ordinary encounter). The shiny roll APPLIES to hooked
# mons (a water shiny hunt is real): the hook-up instance rides the INJECTED shared
# _rng (the wild/starter/egg pattern — seed_for_smoke pins it), never the nonce
# fallback, and emits shiny_rolled{origin:fish} so the EVERY-creation contract
# (shiny_odds scenario) covers water hunts too.
#
# Traces: fishing_cast on every rng-consuming cast (with the bite flag); fish_hooked
# on the hook-up (rod_id, species_id, level, tile); shiny_rolled{origin:fish} on
# EVERY hook-up (is_shiny in the payload — the EVERY-creation contract);
# fishing_refused for no_rod / no_water / no_species, ALSO warning-traced
# ("Fishing refused.") so the degraded paths are never silent, mirroring
# field_move_refused. game_runtime traces fish_caught on a fishing capture.

const Fishing := preload("res://scripts/domain/fishing.gd")
const PokemonRules := preload("res://scripts/domain/pokemon_rules.gd")

var _session = null
var _catalog = null
var _rules = null
var _trace = null
var _world_gen = null
var _rng = null # injected shared rng — NEVER a private seed (determinism seam)
var _get_move: Callable = Callable()
var _pending: Dictionary = {} # the hooked mon, consumed by generate_wild_encounter
var _last_battle_was_fishing := false
var last_rod_used := "" # game_runtime's fish_caught trace reads the rod that hooked it
var _pool_cache: Dictionary = {} # tier -> viable species ids (catalog is fixed post-load)


func setup(session_state, catalog, rules, trace_logger, world_generator, rng, get_move: Callable) -> void:
	_session = session_state
	_catalog = catalog
	_rules = rules
	_trace = trace_logger
	_world_gen = world_generator
	_rng = rng
	_get_move = get_move


# One cast at `tile` (the faced tile; the router pre-gates water + polls only
# outside battle/menus). Returns {ok, reason, bite, wild_mon, rod_id, species_id,
# message}: ok=true means a mon is hooked and pending (fish_hooked traced);
# ok=false carries a reason — no_rod / no_water (fishing_refused, NO rng consumed)
# or no_bite (the cast roll missed; fishing_cast traced with bite=false).
func try_fish(tile: Vector2i) -> Dictionary:
	var rod := Fishing.best_rod(_bag_counts())
	if rod.is_empty():
		_refuse("no_rod", "")
		return {"ok": false, "reason": "no_rod", "bite": false, "wild_mon": {}, "rod_id": "",
			"species_id": "", "message": "You need a fishing rod."}
	var logic: Dictionary = _world_gen.get_tile_logic(tile)
	if str(logic.get("biome", "")) != "WATER" and str(logic.get("requires_field_move", "")) != "surf":
		_refuse("no_water", rod)
		return {"ok": false, "reason": "no_water", "bite": false, "wild_mon": {}, "rod_id": rod,
			"species_id": "", "message": "Use by water to fish for Pokemon."}
	var tier := Fishing.tier_of(rod)
	var bite: bool = _rng.randf() < Fishing.bite_chance(tier)
	_emit("fishing_cast", {"rod_id": rod, "tier": tier, "tile": [tile.x, tile.y], "bite": bite})
	if not bite:
		return {"ok": false, "reason": "no_bite", "bite": false, "wild_mon": {}, "rod_id": rod,
			"species_id": "", "message": "Not a bite... The water settles."}
	var pool := _viable_pool(tier)
	if pool.is_empty():
		_refuse("no_species", rod)
		_trace.warning("FishingRuntime", "Fishing pool was empty after the viability filter; the cast yielded nothing.",
			{"rod_id": rod, "tier": tier})
		return {"ok": false, "reason": "no_species", "bite": false, "wild_mon": {}, "rod_id": rod,
			"species_id": "", "message": "The water is quiet. Nothing bit."}
	var species_id := str(pool[_rng.randi_range(0, pool.size() - 1)])
	var band := Fishing.level_range_for(tier)
	var level: int = _rng.randi_range(int(band[0]), int(band[1]))
	var wild_mon: Dictionary = _rules.create_pokemon_instance(_catalog.get_species(species_id), level, _get_move, _rng)
	if wild_mon.is_empty():
		_refuse("no_species", rod)
		return {"ok": false, "reason": "no_species", "bite": false, "wild_mon": {}, "rod_id": rod,
			"species_id": species_id, "message": "The water is quiet. Nothing bit."}
	_pending = wild_mon
	_last_battle_was_fishing = true
	last_rod_used = rod
	_emit("shiny_rolled", {"species_id": species_id, "is_shiny": bool(wild_mon.get("is_shiny", false)), "odds": PokemonRules.shiny_odds, "origin": "fish"})
	_emit("fish_hooked", {"rod_id": rod, "species_id": species_id, "level": level, "tile": [tile.x, tile.y]})
	return {"ok": true, "reason": "", "bite": true, "wild_mon": wild_mon, "rod_id": rod,
		"species_id": species_id, "message": "Something bit the hook!"}


# The hooked mon ({} when no cast is pending); consumed exactly once —
# game_runtime.generate_wild_encounter calls this BEFORE the wild draw.
func take_pending_encounter() -> Dictionary:
	var pending := _pending
	_pending = {}
	return pending


# True once when the battle that just finished began from a hook; resets on EVERY
# finished battle, so the fishing mark never leaks into an ordinary encounter.
func consume_fishing_battle() -> bool:
	var was_fishing := _last_battle_was_fishing
	_last_battle_was_fishing = false
	return was_fishing


# Battle-end consumption extracted from game_runtime._finish_battle (its line budget):
# fish_caught traces on a fishing capture. The mark resets on EVERY finished battle (the
# consume_fishing_battle precedent — no leak into an ordinary encounter). Source stays
# "GameRuntime" exactly as the absorbed trace emitted it (pin-safe).
func note_battle_finished(outcome: String, species_id: String) -> void:
	if consume_fishing_battle() and outcome.begins_with("caught"):
		_trace.emit_event("fish_caught", "GameRuntime", {"species_id": species_id, "rod_id": last_rod_used})


# Domain table pass-throughs so the app layer (scenarios/audits — forbidden from
# preloading scripts/domain) can assert the tier gate without the layer violation.
static func tier_pool(tier: int) -> Array:
	return Fishing.pool_for(tier)


static func is_rod_item(item_id: String) -> bool:
	return Fishing.is_rod(item_id)


# Tier pool filtered to battle-viable species (the catalog's encounter list —
# sprites, catch rate, learnset; the same gate wild draws use). Cached per tier:
# the catalog is fixed after load (setup runs before load_all, so build lazily).
func _viable_pool(tier: int) -> Array:
	if _pool_cache.has(tier):
		return _pool_cache[tier]
	var viable: Array = []
	for species_id in Fishing.pool_for(tier):
		if _catalog.encounter_species.has(str(species_id)):
			viable.append(str(species_id))
	_pool_cache[tier] = viable
	return viable


func _bag_counts() -> Dictionary:
	var counts: Dictionary = {}
	for rod_id in Fishing.ROD_TIERS.keys():
		counts[str(rod_id)] = _session.get_item_count(str(rod_id))
	return counts


func _refuse(reason: String, rod_id: String) -> void:
	_emit("fishing_refused", {"rod_id": rod_id, "reason": reason})
	_trace.warning("FishingRuntime", "Fishing refused.", {"rod_id": rod_id, "reason": reason})


func _emit(event_name: String, payload: Dictionary) -> void:
	_trace.emit_event(event_name, "FishingRuntime", payload)
