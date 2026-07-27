extends RefCounted

# Phase 6 overworld mons — the STEP ENGINE, extracted from overworld_mons_runtime.gd
# (both at the 320 runtime budget; the runtime owns the entity store, the forced-battle
# seam, the player actions and every trace — this owns their EVOLUTION): DAY<->NIGHT pool
# recompute, flee/chase moves, the radius triggers, the roam tick, and the window sync
# (slot spawns + the nest/Alpha materialization). It reaches the runtime's dicts through
# the injected reference (the subsystem's internal seam, never a public API).
#
# DETERMINISM (load-bearing; spec docs/product-specs/overworld-pokemon.md § Determinism):
# NO rng anywhere — every roll is OverworldMons' derived SplitMix hash of (world_seed,
# cell, slot, step); tile walkability rides world_generator's pure noise (no rng at
# tile-logic time); movement is step-indexed, never frame delta. The shared _rng (the
# wild-encounter stream) is never consumed, so the pinned scenarios/canary stay untouched.

const OverworldMons := preload("res://scripts/domain/overworld_mons.gd")

const DIRS := [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]

# The overworld_mons_runtime back-reference is a WEAKREF: the runtime holds this sim
# strongly, so a strong back-ref would be a RefCounted cycle that never frees at exit
# (leaking the runtime's catalog/trace refs — the "resources still in use" red).
var _rt_ref := WeakRef.new()

func setup(rt) -> void:
	_rt_ref = weakref(rt)

# A crossed DAY<->NIGHT boundary re-filters pools; mons now illegal in their SPAWN cell's
# pool un-materialize (reason "recompute") and re-derive on re-entry.
func recompute_on_time_change(time_label: String) -> void:
	var previous := str(_rt_ref.get_ref()._time_label)
	_rt_ref.get_ref()._time_label = time_label
	if previous.is_empty() or previous == time_label:
		return
	for entity in _rt_ref.get_ref()._live_list(): # membership pins to the spawn cell (roamers cross biomes)
		if str(entity.get("kind", "")) != "egg" and not pool_for(biome_of(OverworldMons.cell_center(entity.cell)), time_label).has(str(entity.species_id)):
			_rt_ref.get_ref()._remove_entity(entity, OverworldMons.REASON_RECOMPUTE, false)

func step_chase_flee(total_steps: int, player_tile: Vector2i) -> void:
	var half_cadence: bool = _rt_ref.get_ref()._field_move_runtime != null and _rt_ref.get_ref()._field_move_runtime.is_riding() # Ride counter-play (:278)
	for entity in _rt_ref.get_ref()._live_list():
		match str(entity.get("state", "idle")):
			"fleeing":
				entity["tile"] = _greedy_step(entity, player_tile, true)
				entity["flee_steps"] = int(entity.get("flee_steps", 0)) - 1
				if int(entity.get("flee_steps", 0)) <= 0:
					_rt_ref.get_ref()._remove_entity(entity, OverworldMons.REASON_FLED)
			"chasing":
				if not half_cadence or total_steps % 2 == 0:
					entity["tile"] = _greedy_step(entity, player_tile, false)

func step_triggers(player_tile: Vector2i) -> void:
	for entity in _rt_ref.get_ref()._live_list():
		var kind := str(entity.get("kind", ""))
		if kind == "egg":
			continue
		if int(entity.get("pacify_steps", 0)) > 0:
			entity["pacify_steps"] = int(entity.pacify_steps) - 1 # Charm calm window counts down
		var state := str(entity.get("state", "idle"))
		var radius := OverworldMons.guardian_spot_radius() if kind == "guardian" else OverworldMons.SPOT_RADIUS
		if state == "idle":
			if _rt_ref.get_ref()._disposition_now(entity) == OverworldMons.DISPOSITION_TIMID and int(entity.get("pacify_steps", 0)) <= 0 and OverworldMons.is_spooked(entity.tile, player_tile):
				entity["state"] = "fleeing"; entity["flee_steps"] = OverworldMons.FLEE_STEPS
			elif _rt_ref.get_ref()._disposition_now(entity) == OverworldMons.DISPOSITION_AGGRESSIVE and int(entity.get("pacify_steps", 0)) <= 0 and OverworldMons.is_spotted(entity.tile, player_tile, radius):
				entity["state"] = "chasing"
		elif state == "chasing":
			if OverworldMons.is_adjacent(entity.tile, player_tile):
				if _rt_ref.get_ref()._pending.is_empty() and not _rt_ref.get_ref()._last_battle_was_entity:
					_rt_ref.get_ref()._force_battle(entity, true) # caught: +3 attack stages (:284)
			elif OverworldMons.chase_dropped(entity.tile, player_tile):
				entity["state"] = "idle" # re-spots at once inside SPOT_RADIUS (cooldown DEFERRED)
		elif state == "engaged" and _rt_ref.get_ref()._pending.is_empty() and not _rt_ref.get_ref()._last_battle_was_entity:
			entity["state"] = "idle" # safety: resolved with no outcome feed

func step_roam(total_steps: int, player_tile: Vector2i) -> void:
	for entity in _rt_ref.get_ref()._live_list():
		if str(entity.get("kind", "")) != "mon" or str(entity.get("state", "idle")) != "idle":
			continue
		if not OverworldMons.should_roam(str(entity.species_id), total_steps):
			continue
		var open: Array = []
		for direction in DIRS:
			var next: Vector2i = entity.tile + direction
			if next != player_tile and _rt_ref.get_ref().entity_at(next).is_empty() and is_open(next, bool(entity.swim_only)):
				open.append(next)
		if not open.is_empty(): # blocked on all sides: mons never phase through props, stack on an entity, or stand on the player
			entity["tile"] = open[OverworldMons.roam_neighbor_index(int(_rt_ref.get_ref()._session.world_seed), entity.cell, int(entity.slot), str(entity.species_id), total_steps, open.size())]

# Window sync: spawn band == despawn band (prototype amendment — no edge-cell flicker).
func sync_window(player_tile: Vector2i, time_label: String) -> void:
	var player_cell := OverworldMons.cell_for_tile(player_tile)
	for entity in _rt_ref.get_ref()._live_list(): # the invented distance un-materialization (re-derives on return)
		if not OverworldMons.in_spawn_band(entity.cell, player_cell):
			_rt_ref.get_ref()._remove_entity(entity, OverworldMons.REASON_DISTANCE, false)
	var edge := OverworldMons.DESPAWN_CELLS
	for cy in range(player_cell.y - edge, player_cell.y + edge + 1):
		for cx in range(player_cell.x - edge, player_cell.x + edge + 1):
			_spawn_slot(Vector2i(cx, cy), time_label)
			_spawn_nest(Vector2i(cx, cy))

func _spawn_slot(cell: Vector2i, time_label: String) -> void:
	var slot_id := "mon_%d,%d" % [cell.x, cell.y]
	if _rt_ref.get_ref()._entities.has(slot_id) or _rt_ref.get_ref()._removed.has(slot_id) or not OverworldMons.is_slot_present(int(_rt_ref.get_ref()._session.world_seed), cell, 0):
		return
	var biome := biome_of(OverworldMons.cell_center(cell))
	var pool := pool_for(biome, time_label)
	if pool.is_empty():
		return
	var species_id := str(pool[OverworldMons.species_index(int(_rt_ref.get_ref()._session.world_seed), cell, 0, pool.size())])
	var anchor := _find_anchor(cell, _swim_only(_rt_ref.get_ref()._catalog.get_species(species_id)))
	if anchor == Vector2i.MAX:
		return # presence rolled, no walkable anchor (open water; prototype: skip, counted)
	_rt_ref.get_ref()._entities[slot_id] = new_mon(slot_id, OverworldMons.CLASS_ROAMING, 0, cell, species_id, anchor,
		OverworldMons.level_for(int(_rt_ref.get_ref()._session.world_seed), cell, 0, ring_of(cell)),
		OverworldMons.disposition_for(species_id, biome, time_label, _rt_ref.get_ref()._catalog.get_species(species_id)))
	_trace_spawned(_rt_ref.get_ref()._entities[slot_id])

# DIVERGENCE #1 (exec-plan mandate): nest + Alpha guardian on ring >= NEST_MIN_RING cells.
# The faithful STREWN single egg stays the common case; a dedicated strewn-egg roll is NOT
# pinned (no constant in the domain table), so eggs ride nest cells until one lands.
func _spawn_nest(cell: Vector2i) -> void:
	if not OverworldMons.is_nest_cell(int(_rt_ref.get_ref()._session.world_seed), cell, ring_of(cell)):
		return
	var pool := pool_for(biome_of(OverworldMons.cell_center(cell)), _rt_ref.get_ref()._time_label)
	if pool.is_empty():
		return
	var seed := int(_rt_ref.get_ref()._session.world_seed)
	var guardian_id := "guardian_%d,%d" % [cell.x, cell.y]
	if not _rt_ref.get_ref()._entities.has(guardian_id) and not _rt_ref.get_ref()._removed.has(guardian_id):
		var species_id := str(pool[OverworldMons.species_index(seed, cell, 0, pool.size())])
		var anchor := _find_anchor(cell, false)
		if anchor != Vector2i.MAX: # stationary guardian: forced AGGRESSIVE, sight widened
			_rt_ref.get_ref()._entities[guardian_id] = new_mon(guardian_id, OverworldMons.CLASS_STATIONARY, 0, cell, species_id, anchor, OverworldMons.guardian_level_for(seed, cell, ring_of(cell)), OverworldMons.DISPOSITION_AGGRESSIVE)
			_trace_spawned(_rt_ref.get_ref()._entities[guardian_id])
	var eggs := 0
	for egg_index in range(OverworldMons.NEST_EGGS):
		var egg_id := "egg_%d,%d_%d" % [cell.x, cell.y, egg_index]
		if _rt_ref.get_ref()._entities.has(egg_id) or _rt_ref.get_ref()._removed.has(egg_id):
			continue
		var egg_species := str(pool[OverworldMons.nest_egg_species_index(seed, cell, egg_index, pool.size())])
		var egg_tile := _find_anchor(cell, false, OverworldMons.nest_egg_species_index(seed, cell, egg_index, OverworldMons.CELL_SIZE * OverworldMons.CELL_SIZE))
		if egg_tile != Vector2i.MAX:
			_rt_ref.get_ref()._entities[egg_id] = new_egg(egg_id, egg_index, cell, egg_species, egg_tile)
			eggs += 1
	var nest_id := "nest_%d,%d" % [cell.x, cell.y]
	if not _rt_ref.get_ref()._nests_found.has(nest_id) and (_rt_ref.get_ref()._entities.has(guardian_id) or eggs > 0):
		_rt_ref.get_ref()._nests_found[nest_id] = true
		var guardian: Dictionary = _rt_ref.get_ref()._entities.get(guardian_id, {})
		_rt_ref.get_ref()._emit("nest_found", {"tile": _rt_ref.get_ref()._t(guardian.get("tile", OverworldMons.cell_center(cell))), "guardian_species_id": str(guardian.get("species_id", "")), "eggs": eggs})

# biome_encounters is the ONE biome truth (the same filter the grass stream rides), minus
# Undiscovered-group species — legendaries/mythicals never roam (the prototype's banlist;
# data-driven off the LIVE catalog, never a hardcoded list).
func pool_for(biome: String, time_label: String) -> Array:
	var key := biome + "|" + time_label
	if _rt_ref.get_ref()._pool_cache.has(key):
		return _rt_ref.get_ref()._pool_cache[key]
	var filtered: Dictionary = _rt_ref.get_ref()._biome_encounters.filter_species_ids(_rt_ref.get_ref()._catalog.species, biome, time_label)
	if bool(filtered.get("used_fallback", false)):
		_rt_ref.get_ref()._trace.warning("OverworldMonsRuntime", "Overworld pool fell back to the full catalog.", {"biome": biome, "time": time_label})
	var pool: Array = []
	for species_id in filtered.get("ids", []):
		var groups: Variant = _rt_ref.get_ref()._catalog.get_species(str(species_id)).get("egg_groups", PackedStringArray())
		var undiscovered := (groups is PackedStringArray and (groups as PackedStringArray).has("UNDISCOVERED")) or (groups is Array and (groups as Array).has("UNDISCOVERED"))
		if not undiscovered:
			pool.append(str(species_id))
	_rt_ref.get_ref()._pool_cache[key] = pool
	return pool

# Entity records — spawn-time rolls on the derived stream (gender/shiny pinned for life).
func new_mon(id: String, entity_class: String, slot: int, cell: Vector2i, species_id: String, tile: Vector2i, level: int, disposition: String) -> Dictionary:
	var entry: Dictionary = _rt_ref.get_ref()._catalog.get_species(species_id)
	var seed := int(_rt_ref.get_ref()._session.world_seed)
	return {"id": id, "kind": "guardian" if entity_class == OverworldMons.CLASS_STATIONARY else "mon", "class": entity_class, "render_kind": "guardian" if entity_class == OverworldMons.CLASS_STATIONARY else "mon", "slot": slot,
		"cell": cell, "species_id": species_id, "tile": tile, "level": level, "disposition": disposition, "state": "idle",
		"gender": OverworldMons.gender_for(seed, cell, slot, str(entry.get("gender_ratio", ""))), "is_shiny": OverworldMons.is_shiny(seed, cell, slot),
		"flee_steps": 0, "pacify_steps": 0, "current_hp": 0, "attack_stages": 0, "swim_only": _swim_only(entry)}

func new_egg(id: String, egg_index: int, cell: Vector2i, species_id: String, tile: Vector2i) -> Dictionary:
	var seed := int(_rt_ref.get_ref()._session.world_seed)
	var ratio := str(_rt_ref.get_ref()._catalog.get_species(species_id).get("gender_ratio", ""))
	return {"id": id, "kind": "egg", "class": "", "render_kind": "egg", "slot": egg_index, "cell": cell, "species_id": species_id, "tile": tile,
		"level": OverworldMons.WILD_EGG_LEVEL, "disposition": "", "state": "idle", "gender": OverworldMons.nest_egg_gender_for(seed, cell, egg_index, ratio),
		"is_shiny": OverworldMons.nest_egg_is_shiny(seed, cell, egg_index), "flee_steps": 0, "pacify_steps": 0, "current_hp": 0, "attack_stages": 0, "swim_only": false}

func _trace_spawned(entity: Dictionary) -> void:
	_rt_ref.get_ref()._emit("overworld_mon_spawned", {"slot": str(entity.id), "species_id": str(entity.species_id), "tile": _rt_ref.get_ref()._t(entity.tile),
		"disposition": str(entity.disposition), "level": int(entity.level), "is_shiny": bool(entity.is_shiny)})

# In-cell scan from the anchor stream offset (open-water cells have none and skip in the
# caller — prototype amendment); occupied tiles excluded so nest components never stack.
func _find_anchor(cell: Vector2i, swim_only: bool, stream_offset: int = -1) -> Vector2i:
	var offset := stream_offset if stream_offset >= 0 else OverworldMons.anchor_offset(int(_rt_ref.get_ref()._session.world_seed), cell, 0)
	var base := cell * OverworldMons.CELL_SIZE
	var area := OverworldMons.CELL_SIZE * OverworldMons.CELL_SIZE
	for k in range(area):
		var index := (offset + k) % area
		var tile := base + Vector2i(index % OverworldMons.CELL_SIZE, index / OverworldMons.CELL_SIZE)
		if is_open(tile, swim_only) and _rt_ref.get_ref().entity_at(tile).is_empty():
			return tile
	return Vector2i.MAX

# Greedy Manhattan step away from (flee) or toward (chase) the player; first strictly
# better DIRS-order neighbor wins (deterministic); no open move ⇒ hold the tile.
func _greedy_step(entity: Dictionary, player_tile: Vector2i, flee: bool) -> Vector2i:
	var best: Vector2i = entity.tile
	var best_distance := OverworldMons.manhattan(entity.tile, player_tile)
	for direction in DIRS:
		var next: Vector2i = entity.tile + direction
		if next == player_tile or not _rt_ref.get_ref().entity_at(next).is_empty() or not is_open(next, bool(entity.swim_only)):
			continue # a chaser/fleer never stands ON the player or another entity (adjacency triggers the battle)
		var distance := OverworldMons.manhattan(next, player_tile)
		if (flee and distance > best_distance) or (not flee and distance < best_distance):
			best = next; best_distance = distance
	return best

# swim_only mons (14 species) ride WATER tiles only; everyone else walks walkable tiles
# (water tiles are walkable=false, so land mons never enter — the cross-biome wander :224).
# DIVERGENCE #14 (spec § Divergences): a fenced pen's INTERIOR tiles stay walkable, so a wild
# roamer can spawn/roam inside a player's closed pen (fence tiles block, the ground inside does
# not). Fresh worlds have no pens, so the gates never see it; pens stay ABSTRACT in Phase 6 (the
# Phase-5 boundary) and pen/overworld integration is future work — flagged, never silent.
func is_open(tile: Vector2i, swim_only: bool) -> bool:
	var logic: Dictionary = _rt_ref.get_ref()._world_gen.get_tile_logic(tile)
	return str(logic.get("biome", "")) == "WATER" if swim_only else bool(logic.get("walkable", false))

func _swim_only(entry: Dictionary) -> bool:
	var behavior: Variant = entry.get("overworld_behavior", {})
	return behavior is Dictionary and int((behavior as Dictionary).get("swim_only", 0)) == 1

func biome_of(tile: Vector2i) -> String:
	return str(_rt_ref.get_ref()._world_gen.get_tile_logic(tile).get("biome", ""))

func ring_of(cell: Vector2i) -> int: # Manhattan ring of the cell center (world_generator bands)
	var center := OverworldMons.cell_center(cell)
	return absi(center.x) + absi(center.y)

# Deterministic nest finder (sweep/scenario seam; the app cannot reach the domain): the
# center tile of the first nest cell within `radius` tiles of `center`, or Vector2i.ZERO
# (cell centers are never (0,0), so ZERO is a safe sentinel — the shot skips, never fakes).
func find_nest_center_near(center: Vector2i, radius: int) -> Vector2i:
	var center_cell := OverworldMons.cell_for_tile(center)
	var edge := radius / OverworldMons.CELL_SIZE + 1
	for cy in range(center_cell.y - edge, center_cell.y + edge + 1):
		for cx in range(center_cell.x - edge, center_cell.x + edge + 1):
			var cell := Vector2i(cx, cy)
			if OverworldMons.manhattan(OverworldMons.cell_center(cell), center) > radius or not OverworldMons.is_nest_cell(int(_rt_ref.get_ref()._session.world_seed), cell, ring_of(cell)):
				continue
			if _find_anchor(cell, false) == Vector2i.MAX:
				continue # a water-locked cell can hold neither guardian nor eggs — keep seeking
			return OverworldMons.cell_center(cell)
	return Vector2i.ZERO
