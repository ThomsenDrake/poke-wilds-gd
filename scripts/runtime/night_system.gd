extends RefCounted

# Night-danger system (Phase 2 night survival; spec:
# docs/product-specs/camping-crafting-survival.md). Reads the session clock
# through day_phase.gd (the single source of truth mirroring world_view.gd's
# tint keyframes) and answers three questions: is it night, does the player
# stand in light, and does the dark spawn a ghost this draw.
#
# LIGHT SOURCES (faithful "light or die"): a lit campfire or a placed torch
# within Manhattan LIGHT_RADIUS tiles (structures.gd LIGHT_SOURCES; a campfire
# carries an additive "lit" placement-entry field — absent means lit, so
# Phase 1 campfire saves stay lit — while a torch is always lit), OR a
# Flash-capable party member (Fire type per field_moves.gd AUTO_TYPES). The
# party check is a capability READ — the passive Fire-type light from the
# SheerSt interview — NOT the Phase 4 Flash field-move action.
#
# UNLIT NIGHT: GHOST_CHANCE of the shared encounter draw becomes a type-
# derived ghost (sorted viable-GHOST pool; BIOME_TYPES has no GHOST entry —
# ghosts seek the player in every biome) that blocks retreat for the whole
# battle. Time freezes mid-battle in the port (1 min/step, no steps in
# battle), so the original's "until dawn" ports as "for the battle's
# duration": escapes are victory, capture, or blackout.
#
# DETERMINISM: the ghost roll + species pick ride the INJECTED shared rng
# (game_runtime._rng) and the clock is session.time_of_day_minutes (scenario-
# settable) — never a private seed, never the wall clock — so seed_for_smoke
# pins every ghost encounter exactly. Day and lit draws consume NO rng, so
# daytime encounter streams are byte-identical to the pre-Phase-2 behavior.

const DayPhase := preload("res://scripts/domain/day_phase.gd")
const FieldMoves := preload("res://scripts/domain/field_moves.gd")
const Structures := preload("res://scripts/domain/structures.gd")

# One constant covers campfire, torch and Flash: the originals document
# "Flash shares the same range as a campfire" (pinned design note; the wiki
# gives no exact number). Manhattan distance on the tile grid.
const LIGHT_RADIUS := 4
# Share of the existing per-step encounter cadence ghosts claim at unlit
# night (pinned; rides the shared rng stream, so scenarios seed it).
const GHOST_CHANCE := 0.5

var _session = null
var _catalog = null
var _trace = null
var _get_placements: Callable # () -> Dictionary ("x,y" -> placement entry)
var _is_species_viable: Callable # (species_id, entry) -> bool (biome_encounters rule)
var _rng = null # injected shared rng — NEVER a private seed (determinism seam)
var _ghost_species_ids: Array = []
var _ghost_pool_built := false
var _pending_shadow := false # set by a ghost roll, consumed at battle start
var _battle_is_shadow := false
var _shadow_species_id := ""
var _retreat_blocked_logged := false


func setup(session_state, catalog, trace_logger, get_placements: Callable, is_species_viable: Callable, rng) -> void:
	_session = session_state
	_catalog = catalog
	_trace = trace_logger
	_get_placements = get_placements
	_is_species_viable = is_species_viable
	_rng = rng


func is_night() -> bool:
	return DayPhase.is_night(int(_session.time_of_day_minutes))


# True inside the radius of a lit campfire or torch, or with a Flash-capable
# (Fire-type) party member — the traveling light source.
func has_light_at(tile: Vector2i) -> bool:
	if _party_has_flash():
		return true
	var placements = _get_placements.call() if _get_placements.is_valid() else {}
	if not (placements is Dictionary):
		return false
	for key in (placements as Dictionary).keys():
		var entry = (placements as Dictionary)[key]
		if not (entry is Dictionary):
			continue
		var structure_id := str((entry as Dictionary).get("structure_id", ""))
		if not Structures.is_light_source(structure_id):
			continue
		if structure_id == "campfire" and (entry as Dictionary).get("lit", true) == false:
			continue # extinguished: still a crafting station, but emits no light
		var light_tile := _parse_tile(str(key))
		if abs(light_tile.x - tile.x) + abs(light_tile.y - tile.y) <= LIGHT_RADIUS:
			return true
	return false


# The ghost trigger: empty unless unlit night AND the shared rng roll lands.
# A chosen ghost marks the pending shadow battle (begin_battle consumes it).
func try_ghost_species(tile: Vector2i) -> String:
	_pending_shadow = false
	if not is_night() or has_light_at(tile) or _rng == null:
		return ""
	if _rng.randf() >= GHOST_CHANCE:
		return ""
	var ids := ghost_species_ids()
	if ids.is_empty():
		return ""
	var species_id := str(ids[_rng.randi_range(0, ids.size() - 1)])
	_pending_shadow = true
	if _trace != null:
		_trace.emit_event("night_hazard_spawned", "NightSystem", {"species_id": species_id,
			"tile": [tile.x, tile.y], "minutes": int(_session.time_of_day_minutes)})
	return species_id


# Sorted, built lazily (the catalog loads after setup, in ensure_initialized):
# every battle-viable GHOST-type species, via the injected biome_encounters
# viability rule so the two pools never disagree about what is encounterable.
func ghost_species_ids() -> Array:
	if _ghost_pool_built:
		return _ghost_species_ids
	_ghost_pool_built = true
	if _catalog == null or not _is_species_viable.is_valid():
		return _ghost_species_ids
	for key in _catalog.species.keys():
		var entry = _catalog.species[key]
		if not (entry is Dictionary):
			continue
		var species_entry: Dictionary = entry
		if not bool(_is_species_viable.call(str(key), species_entry)):
			continue
		var types = species_entry.get("types", PackedStringArray())
		if (types is PackedStringArray or types is Array) and ("GHOST" in types):
			_ghost_species_ids.append(str(key))
	_ghost_species_ids.sort()
	return _ghost_species_ids


# Battle lifecycle: every wild battle start resolves the pending shadow mark
# (a non-ghost encounter clears it), so the block can never leak into a
# later, ordinary battle.
func begin_battle(wild_mon: Dictionary) -> void:
	_battle_is_shadow = _pending_shadow and not wild_mon.is_empty()
	_pending_shadow = false
	_retreat_blocked_logged = false
	_shadow_species_id = str(wild_mon.get("species_id", "")) if _battle_is_shadow else ""


func battle_is_shadow() -> bool:
	return _battle_is_shadow


# False while a shadow battle rages — the injected battle_runtime retreat
# check. Emits retreat_blocked ONCE per battle (dawn cannot arrive mid-battle,
# so repeated attempts all fail identically until victory/capture/blackout).
func retreat_allowed() -> bool:
	if not _battle_is_shadow:
		return true
	if not _retreat_blocked_logged:
		_retreat_blocked_logged = true
		if _trace != null:
			_trace.emit_event("retreat_blocked", "NightSystem", {"species_id": _shadow_species_id})
	return false


func _party_has_flash() -> bool:
	if _session == null or _catalog == null:
		return false
	var get_species := Callable(_catalog, "get_species")
	for mon in _session.party:
		if mon is Dictionary and FieldMoves.can_perform(mon, "flash", get_species):
			return true
	return false


# Placement save-shape key "x,y" -> tile; a malformed key maps to a tile too
# far away to light anything (has_light_at then skips it naturally).
func _parse_tile(key: String) -> Vector2i:
	var parts := key.split(",")
	if parts.size() != 2 or not parts[0].is_valid_int() or not parts[1].is_valid_int():
		return Vector2i.MAX
	return Vector2i(parts[0].to_int(), parts[1].to_int())
