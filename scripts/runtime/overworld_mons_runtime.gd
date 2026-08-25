extends RefCounted

# Phase 6 overworld Pokémon runtime (spec: docs/product-specs/overworld-pokemon.md): the
# entity store, the forced-battle PENDING SEAM, the shared-tile CONTACT check (the collision-
# only default), and the store-level traces. The PLAYER ACTIONS (Attack/Charm via the Phase-4
# hooks on field_move_runtime's public vars; dialogue recruitment; the wild-egg TAKE/Attack
# binary :248) live in overworld_mons_actions.gd — extracted at the 320 wall, reached by the
# one-line public delegators below (call sites unchanged); the interact-provocation memory
# stays HERE (the app checks poke it). The per-step ENGINE (roam/flee/aggro/spawn/despawn/
# nests) lives in overworld_mons_sim.gd — extracted at the 320 budget wall (the encounter_
# selection precedent); it shares this object's dicts.
# game_runtime.generate_wild_encounter takes the pending mon BEFORE fishing/repel/ghosts;
# note_battle_outcome consumes the mark, reset on every finished battle.
#
# DETERMINISM (load-bearing, STRUCTURAL): setup() takes NO _rng parameter — the wild-
# encounter stream (night_system.gd:24-28) is never consumed here; every roll rides
# scripts/domain/overworld_mons.gd's derived SplitMix hash of (world_seed, cell, slot,
# step) and instance construction is STAMPED (3-arg create_pokemon_instance + spawn-time
# gender/shiny), never re-rolled. PERSISTENCE is TRANSIENT (spec § Persistence): NO save
# keys, NO SAVE_VERSION bump (v5 reserved for Phase 7); entities re-derive from
# (world_seed, total_steps) + the clock, _removed is session-scoped, recruits/taken eggs
# persist via the party.
#
# TRACES (source "OverworldMonsRuntime"; keys for docs/references/trace-events.md):
#   overworld_mon_spawned {slot, species_id, tile, disposition, level, is_shiny}
#   overworld_mon_despawned {slot, species_id, tile, reason: ko|caught|fled|distance|recompute}
#   recruit_attempted {species_id, tile, path:"dialogue", party_free, ok, reason}
#   recruit_succeeded {species_id, tile, level, is_shiny, party_size}
#   nest_found {tile, guardian_species_id, eggs} (once/session)
#   egg_stolen {tile, species_id, is_shiny, provoked_count} | alpha_provoked {tile, species_id, attack_stages}
# Auxiliaries: mon_provoked {slot, species_id, tile, cause: egg_theft|interact}; egg_cleared
#   {tile, species_id, is_shiny}; shiny_rolled {..., origin:"overworld"} on EVERY build.

const OverworldMons := preload("res://scripts/domain/overworld_mons.gd")
const OverworldMonsSim := preload("res://scripts/runtime/overworld_mons_sim.gd")
const OverworldMonsActions := preload("res://scripts/runtime/overworld_mons_actions.gd") # player-action surface, extracted at the 320 wall
const ContactEncounter := preload("res://scripts/domain/contact_encounter.gd") # the shared-tile collision predicate (contact-only default)
const LegendaryPlacement := preload("res://scripts/domain/legendary_placement.gd")
const DungeonLayouts := preload("res://scripts/domain/dungeon_layouts.gd") # the tablet-Regi table (the KO valve + the catch grant)
const PokemonRules := preload("res://scripts/domain/pokemon_rules.gd")
const DayPhase := preload("res://scripts/domain/day_phase.gd")

signal encounter_requested(tile: Vector2i) # entity_layer bridges it onto player_avatar's (zero main.gd lines)

var active := true # activation gate: the smoke dispatcher flips it for non-opt-in scenarios
var _sim = OverworldMonsSim.new()
var _actions = OverworldMonsActions.new()
var _session = null
var _catalog = null
var _rules = null
var _trace = null
var _world_gen = null
var _biome_encounters = null
var _field_move_runtime = null
var _entities: Dictionary = {} # id -> entity record (sorted iteration ⇒ order-independent)
var _removed: Dictionary = {} # id -> reason; session-scoped permanent removals (transient)
var _nests_found: Dictionary = {} # nest id -> true (nest_found fires once per session)
var _pool_cache: Dictionary = {} # "BIOME|LABEL" -> sorted viable species ids
var _time_label := ""
var _pending: Dictionary = {} # the provoked/engaged mon, taken by generate_wild_encounter
var _pending_id := ""
var _last_battle_was_entity := false
var _faced_tile := Vector2i.MAX
# Interact-provocation memory: OWNED here (the app checks poke it for test isolation, the
# same idiom as _time_label/_faced_tile) and read/written by overworld_mons_actions.interact.
var _last_interact_id := ""
var _last_interact_step := -100
var _prev_player_tile := Vector2i.ZERO
var _has_prev_player := false

# NO rng parameter — the guarantee is structural (header). Registers the Phase-4 hooks.
func setup(session_state, catalog, pokemon_rules, trace_logger, world_generator, biome_encounters, field_move_runtime) -> void:
	_session = session_state; _catalog = catalog; _rules = pokemon_rules; _trace = trace_logger
	_world_gen = world_generator; _biome_encounters = biome_encounters; _field_move_runtime = field_move_runtime
	_sim.setup(self)
	_actions.setup(self)
	if field_move_runtime != null:
		field_move_runtime.overworld_attack_hook = Callable(_actions, "on_attack_hook")
		field_move_runtime.overworld_charm_hook = Callable(_actions, "on_charm_hook")

# One overworld step on the player-step clock (game_runtime.note_player_step delegates
# AFTER habitat/breeding): DAY<->NIGHT recompute, flee/chase moves, radius triggers, the
# shared-tile CONTACT check (collision-only default), the roam tick, then the window sync
# (spawn/despawn + nests).
func note_player_step(total_steps: int, player_tile: Vector2i, time_label: String) -> void:
	if _in_dungeon():
		_check_player_contact(player_tile)
		return # chamber contact stays live; the overworld sim never moves/spawns at dungeon-local coords
	if not active:
		return
	var previous := _prev_player_tile if _has_prev_player else player_tile
	_sim.recompute_on_time_change(time_label)
	_sim.step_chase_flee(total_steps, player_tile, previous)
	_sim.step_triggers(player_tile, previous)
	_check_player_contact(player_tile)
	_sim.step_roam(total_steps, player_tile)
	_sim.sync_window(player_tile, time_label)
	_prev_player_tile = player_tile
	_has_prev_player = true

# Collision-only default (overworld-pokemon.md): stepping ONTO a wild mon's tile forces a
# battle — player-initiated, provoked:false (NO +3; the attack_entity precedent). Eggs never
# battle on contact. An already-armed chase-catch keeps first refusal this step.
func _check_player_contact(player_tile: Vector2i) -> void:
	if not _pending.is_empty() or _last_battle_was_entity:
		return
	var entity := entity_at(player_tile)
	if ContactEncounter.is_battle_contact(entity):
		_force_battle(entity, false)

# The entity on a tile ({} when none); mons take Z-precedence over an egg sharing a tile.
func entity_at(tile: Vector2i) -> Dictionary:
	var egg: Dictionary = {}
	for entity in _live_list():
		if entity.tile != tile:
			continue
		if str(entity.get("kind", "")) == "egg":
			egg = entity
		else:
			return entity
	return egg

func live_entities_in(rect: Rect2i) -> Array:
	var found: Array = []
	for entity in _live_list():
		if rect.has_point(entity.tile):
			found.append((entity as Dictionary).duplicate(true))
	return found

func note_faced_tile(tile: Vector2i) -> void: # field_move_actions pins the acted-on target
	_faced_tile = tile

# Nest finder for the sweep/scenario (the app cannot reach the domain; the sim owns the roll).
func find_nest_center_near(center: Vector2i, radius: int) -> Vector2i:
	return _sim.find_nest_center_near(center, radius)

# A warp (teleport/fly) ends every chase + flee (:278 counter-play) and re-syncs the
# window at the destination (warping never advances the step clock).
func note_warp(tile: Vector2i) -> void:
	for entity in _live_list():
		var state := str(entity.get("state", "idle"))
		if state == "fleeing" and OverworldMons.cell_for_tile(entity.tile) != entity.cell:
			_remove_entity(entity, OverworldMons.REASON_FLED) # a warp loses a far-fled mon past recovery: never strand it idle far from its home cell (the cell-based distance gate would keep it forever)
			continue
		if ["chasing", "fleeing"].has(state):
			entity["state"] = "idle"; entity["flee_steps"] = 0
	if active and not _in_dungeon():
		_sim.sync_window(tile, DayPhase.time_of_day_label(int(_session.time_of_day_minutes)))

# --- The dungeon seam (dungeon_runtime rides here; the sim stays the entity owner) -----------
func _in_dungeon() -> bool: return _session != null and str(_session.active_area) != "" # the sim-suppression gate, session-direct (the dungeon_runtime.in_dungeon predicate; unset session == the overworld)

# Stamps the chamber legendary: the sim's new_legendary (kind/battle_kind "legendary"
# preserved; the tile is the dungeon-local chamber; the ring is the entrance ring so
# guardian_level_for stays deep; the biome is the caller's — dungeon_runtime owns the
# DUNGEON_BIOME constant). The anchor is OVERWRITTEN to the ENTRANCE anchor so the removal
# key stays world-anchored (new_legendary pins anchor = the stamp tile). The session-scoped
# whittle ({current_hp, attack_stages}) re-applies. Idempotent.
func stamp_dungeon_chamber(dungeon_id: String, species_id: String, tile: Vector2i, anchor: Vector2i, ring: int, biome: String, instance_state: Dictionary = {}) -> void:
	var id := "legendary_%s" % dungeon_id
	if _entities.has(id) or _removed.has(id):
		return # already standing (or KO'd this session — the re-stand valve clears the mark first)
	var entity: Dictionary = _sim.new_legendary(id, Vector2i.ZERO, species_id, tile, biome, ring)
	entity["anchor"] = anchor # the ENTRANCE anchor: removal keys stay world-anchored
	entity["dungeon_id"] = dungeon_id
	entity["current_hp"] = int(instance_state.get("current_hp", 0))
	entity["attack_stages"] = int(instance_state.get("attack_stages", 0))
	_entities[id] = entity
	_sim._trace_spawned(entity) # the overworld_mon_spawned witness (the sim's own spawn path)

# The warp-in/out seam: drops every live entity (the overworld sim's live entities never leak
# into dungeon-local coords; the next in-context sync re-derives them). The _removed marks
# survive — a fled/despawned overworld mon stays marked.
func clear_live_entities() -> void:
	_entities.clear()

# New game / load: drops any stale chamber entity (it re-stamps subject to suppression).
func clear_dungeon_entities() -> void:
	for id in _entities.keys():
		if str(((_entities[id] as Dictionary).get("dungeon_id", ""))) != "":
			_entities.erase(id)

func has_removed_mark(id: String) -> bool:
	return _removed.has(id)

# The KO re-stand valve: a tablet Regi's session-scoped KO mark lapses WITH the cooldown, so
# the re-entry re-stamps it FRESH (full HP/fresh stages — dungeon_runtime erases the whittle).
func clear_removed_mark(id: String) -> void:
	_removed.erase(id)

# The chamber entity's whittle state ({current_hp, attack_stages}; {} when absent) — the ONE
# owner of the "legendary_%s" id grammar's read side (dungeon_runtime._snapshot_chamber rides it).
func chamber_state_for(dungeon_id: String) -> Dictionary:
	var entity: Dictionary = _entities.get("legendary_%s" % dungeon_id, {})
	if entity.is_empty():
		return {}
	return {"current_hp": int(entity.get("current_hp", 0)), "attack_stages": int(entity.get("attack_stages", 0))}

# The forced-battle seam: {} when none; consumed exactly once — game_runtime.generate_wild_
# encounter calls this BEFORE fishing, so Repel/unlit-night ghosts never touch a provoked
# battle (canonical: Repel wards the GRASS stream only — spec § Rate balance & Repel).
func take_pending_encounter() -> Dictionary:
	var pending := _pending
	_pending = {}
	return pending

# victory/catch removes the entity (:288); escaped/defeat keeps it with persisted HP +
# stages (:284) and drops chasing→idle on EVERY such outcome (DIVERGENCE #11). The pending
# entity is always a mon/guardian/legendary — eggs never arm into the seam (:250 dropped).
# Returns the post-battle message ("" when none) — the tablet grant surfaces through it.
func note_battle_outcome(outcome: String, enemy: Dictionary) -> String:
	if not _last_battle_was_entity:
		return ""
	_last_battle_was_entity = false
	var entity: Dictionary = _entities.get(_pending_id, {})
	_pending_id = ""
	if entity.is_empty():
		return ""
	entity["current_hp"] = int(enemy.get("current_hp", 0)); entity["state"] = "idle"
	if outcome == "victory":
		_remove_entity(entity, OverworldMons.REASON_KO)
	elif outcome.begins_with("caught"):
		_remove_entity(entity, OverworldMons.REASON_CAUGHT)
	if str(entity.get("kind", "")) != "legendary" or not (outcome == "victory" or outcome.begins_with("caught")):
		return "" # a white-out leaves the legendary re-battleable above
	var key := LegendaryPlacement.removal_key(entity.get("anchor", entity.get("tile", Vector2i.ZERO)), str(entity.species_id))
	var tablet := str(DungeonLayouts.TABLET_FOR_SPECIES.get(str(entity.species_id), ""))
	if outcome == "victory" and tablet != "" and str(entity.get("dungeon_id", "")) != "": # the KO re-stand valve: a tablet Regi rests in the additive session.legendary_kos log (NEVER the persistent removals) until REGI_RESTAND_STEPS lapses; MEWTWO/REGIGIGAS keep both-outcomes-permanent below
		_session.legendary_kos[key] = int(_session.total_steps)
		return "" # KO grants NOTHING (the tablets are catch-only)
	_session.legendary_removals.append(key) # gone-for-good PER INSTANCE (flagged PORT DECISION inverting wiki :224); v4-additive; session_payload marshals; anchor-keyed (per-instance)
	if outcome.begins_with("caught") and tablet != "" and _session.get_item_count(tablet) == 0: # the catch-only tablet grant (once per save; KO grants nothing)
		_session.add_item(tablet, 1)
		_emit("tablet_claimed", {"species_id": str(entity.species_id), "item_id": tablet, "tile": _t(entity.tile)})
		return "The %s left behind a tablet etched in Braille." % str(entity.species_id).capitalize()
	return ""

# Player actions (Attack/Charm hooks, dialogue recruitment, the wild-egg TAKE/Attack binary
# :248, the interact-provocation memory) live in overworld_mons_actions.gd — extracted at the
# 320 wall. These public delegators keep EVERY call site (overworld_entity_actions,
# playtest_bot_entity, the app checks) unchanged. An egg clears (NO battle); a mon is a
# player-initiated forced battle — provoked:false, so NO +3 buff (:280).
func attack_entity(tile: Vector2i) -> Dictionary: return _actions.attack_entity(tile)
func interact(tile: Vector2i) -> Dictionary: return _actions.interact(tile)
func egg_take(tile: Vector2i) -> Dictionary: return _actions.egg_take(tile)

func _force_battle(entity: Dictionary, provoked: bool) -> Dictionary:
	var mon := _stamp_instance(entity, int(entity.get("level", 5)))
	if mon.is_empty():
		return {"ok": false, "reason": "no_species"}
	var standing_hp := int(entity.get("current_hp", 0))
	if standing_hp > 0: mon["current_hp"] = clampi(standing_hp, 1, maxi(1, int(mon.get("max_hp", 1))))
	var stages := maxi(int(entity.get("attack_stages", 0)), OverworldMons.attack_stages_for(provoked))
	entity["attack_stages"] = stages
	if stages > 0:
		mon["attack_stages"] = stages # battle_runtime.start_wild_battle applies it post reset_stages (:284)
	if provoked and str(entity.get("kind", "")) == "guardian":
		_emit("alpha_provoked", {"tile": _t(entity.tile), "species_id": str(entity.species_id), "attack_stages": stages})
	_arm_pending(entity, mon)
	return {"ok": true, "species_id": str(entity.species_id), "provoked": provoked, "attack_stages": stages}

func _arm_pending(entity: Dictionary, mon: Dictionary) -> void:
	entity["state"] = "engaged"
	mon["battle_kind"] = str(entity.get("battle_kind", "wild")) # Build 2 seam: a legendary static sets "legendary" (music_router.gd:33); the battle-start path reads it
	if str(entity.get("kind", "")) == "legendary": # the legendary_encounter payload rides the pending (game_runtime owns the SINGLE trace)
		mon["tile"] = _t(entity.tile); mon["biome"] = str(entity.get("biome", "")); mon["ring"] = int(entity.get("ring", 0))
		if str(entity.get("dungeon_id", "")) != "":
			mon["dungeon_id"] = str(entity["dungeon_id"]) # additive: the chamber stamp's dungeon (wild_encounter_draw.trace_legendary forwards it)
	_pending = mon; _pending_id = str(entity.id); _last_battle_was_entity = true
	encounter_requested.emit(entity.tile)

# Stamped, never re-rolled: gender/is_shiny are OVERWRITTEN from the entity's derived-stream
# spawn rolls below. NOTE: the 3-arg create_pokemon_instance still advances pokemon_rules'
# shared _gender_nonce (a creation-order counter) — an INTENTIONAL consumer, consistent with
# the breeding runtime's stamping; gender is OUTSIDE the night_system guarantee (the CONTROL
# pins species|level|shiny only), so this re-orders grass GENDER, never the pinned wild stream.
func _stamp_instance(entity: Dictionary, level: int) -> Dictionary:
	var mon: Dictionary = _rules.create_pokemon_instance(_catalog.get_species(str(entity.species_id)), level, Callable(_catalog, "get_move")) # 3-arg: NO rng
	if mon.is_empty():
		_trace.warning("OverworldMonsRuntime", "Entity species missing from the catalog; cannot build an instance.", {"species_id": str(entity.species_id)})
		return {}
	mon["gender"] = str(entity.get("gender", mon.get("gender", "")))
	mon["is_shiny"] = bool(entity.is_shiny) # spawn-time roll on the derived stream, never re-rolled
	_emit("shiny_rolled", {"species_id": str(mon.get("species_id", "")), "is_shiny": bool(mon.is_shiny), "odds": PokemonRules.shiny_odds, "origin": "overworld"})
	return mon

func _disposition_now(entity: Dictionary) -> String: # live: resolved where the mon stands
	if ["guardian", "legendary"].has(str(entity.get("kind", ""))):
		return OverworldMons.DISPOSITION_AGGRESSIVE # forced (design — the legendary stationary presentation, never the catalog aggression byte)
	return OverworldMons.disposition_for(str(entity.species_id), _sim.biome_of(entity.tile), _time_label, _catalog.get_species(str(entity.species_id)))

func _remove_entity(entity: Dictionary, reason: String, permanent: bool = true) -> void:
	var id := str(entity.get("id", ""))
	_entities.erase(id)
	if permanent:
		_removed[id] = reason
	if str(entity.get("kind", "")) != "egg": # eggs trace egg_stolen/egg_cleared instead
		_emit("overworld_mon_despawned", {"slot": id, "species_id": str(entity.species_id), "tile": _t(entity.tile), "reason": reason})

func _live_list() -> Array:
	var keys := _entities.keys()
	keys.sort()
	var list: Array = []
	for key in keys:
		list.append(_entities[key])
	return list

func _emit(event_name: String, payload: Dictionary) -> void:
	_trace.emit_event(event_name, "OverworldMonsRuntime", payload)

func _t(tile: Vector2i) -> Array:
	return [tile.x, tile.y]
