extends RefCounted

# Phase 4 field-move callers (spec: docs/product-specs/field-moves.md). EXTRACTED
# from game_runtime.gd (AT its 320 budget; game_runtime only instantiates + setup()s
# this beside the other runtimes, injected with the shared session/catalog/trace/
# world_gen). NO rng injection: NONE of the eight moves ROLL (the Phase-7 audit's
# dormant-injection finding — a future roll re-injects game_runtime._rng, the
# fishing_runtime precedent, so seed_for_smoke pins it). Owns the
# EIGHT Phase-4 moves that had capability rules but ZERO runtime callers: flash,
# teleport (+ way stones), ride, fly, repel, power (movable boulders), and the
# attack/charm overworld HOOKS Phase 6 consumes. cut/dig/smash (harvest_runtime), surf
# (the passive world_view gate) and build (build_runtime) already have live callers.
#
# FAITHFUL DECISIONS (field-moves.md):
# - FLASH: the faithful effect is the PASSIVE traveling light (a Flash-capable Fire
#   mon lights the party via night_system._party_has_flash; LIGHT_RADIUS 4, "the same
#   range as a campfire"). The active caller (use_flash) drives night_system's
#   set_active_flash seam — a tangible light at the player's tile of its own — and
#   traces flash_lit, never diverging from the campfire range ("can't be selected like
#   Cut" is honored).
# - FLY/RIDE resolve via EXPLICIT db flags only (field_moves.gd AUTO_TYPES carries
#   "fly":""/"ride":"" — the empty auto-type IS the flag-only encoding). The all-moves
#   party rides Charizard fly=1 / Rhyperior ride=1; no AUTO_TYPES broadening.
# - TELEPORT/FLY target WAY STONES (placed way_stone structures; the registry IS the live
#   placement map — NO separate session key — persisting on the structures save key for
#   free), step-ordered (last = last-registered); Fly REFUSES an unregistered tile. Way
#   stones are plain INTRA-WORLD warp points on the seamless infinite plane (infinite-world
#   slice retired the world-edge beacon concept — no edge_suppressed, no beacon_placed).
# - REPEL rides session_state.repel_steps (an additive, PERSISTED key; note_step_taken
#   decays it one per step). Documented deviation: the original is a crafted low-level
#   ITEM; the port suppresses ALL encounters for N steps — generate_wild_encounter
#   returns {} consuming NO encounter rng (a structural suppression the scenario proves).
# - POWER moves a movable BOULDER prop (distinct from Smash's destructible
#   rock_small1.png — that rock is harvested, a boulder is pushed), riding the
#   placements map so it renders, blocks, and survives save like a built structure.
# - ATTACK/CHARM are HOOKS: they trace + (charm) level-gate a pacify, but the
#   overworld-Pokemon ENTITIES they target land in Phase 6 — no entity behavior here.

const FieldMoves := preload("res://scripts/domain/field_moves.gd")
const Structures := preload("res://scripts/domain/structures.gd")
const NightSystem := preload("res://scripts/runtime/night_system.gd")

const REPEL_DEFAULT_STEPS := 20

var _session = null
var _catalog = null
var _trace = null
var _world_gen = null
var _night_system = null
var _riding := false
var _tile_overridden: Callable = Callable() # world_overridden.emit (the harvest_runtime precedent)
# Phase-6 plug-in seams: the overworld entities register these; until they land the
# hooks default to invalid callables so use_attack/use_charm still trace + run clean.
var overworld_attack_hook: Callable = Callable(); var overworld_charm_hook: Callable = Callable()

func setup(session_state, catalog, trace_logger, world_generator, night_system, tile_overridden: Callable = Callable()) -> void:
	_session = session_state
	_catalog = catalog
	_trace = trace_logger
	_world_gen = world_generator
	_night_system = night_system
	_tile_overridden = tile_overridden

func _capable(move_id: String) -> bool:
	var get_species := Callable(_catalog, "get_species")
	for mon in _session.party:
		if mon is Dictionary and FieldMoves.can_perform(mon, move_id, get_species):
			return true
	return false

# --- FLASH (passive light is night_system's; the active caller only traces) ----

func use_flash(tile: Vector2i) -> Dictionary:
	if not _capable("flash"):
		_refuse("flash", {"tile": _t(tile), "reason": "not_capable"})
		return {"ok": false, "reason": "not_capable"}
	if _night_system != null:
		_night_system.set_active_flash(true) # the player's tile lights at LIGHT_RADIUS
	_emit("flash_lit", {"tile": _t(tile), "radius": NightSystem.LIGHT_RADIUS, "species_id": _first_capable_species("flash")})
	return {"ok": true, "radius": NightSystem.LIGHT_RADIUS}

# Clears the active Flash light (the scenario's dark-control seam; the passive
# Fire-type party light, if any, is unaffected).
func clear_flash() -> void:
	if _night_system != null:
		_night_system.set_active_flash(false)

# --- TELEPORT + WAY STONES ----------------------------------------------------

# Registered way stones = placed way_stone structures, step-ordered (last = last-registered).
func way_stone_tiles() -> Array:
	return _placement_tiles(Structures.WAYSTONE_ID)

func is_way_stone(tile: Vector2i) -> bool:
	return way_stone_tiles().has(tile)

func last_way_stone() -> Vector2i:
	var tiles := way_stone_tiles()
	return tiles[tiles.size() - 1] if not tiles.is_empty() else Vector2i.MAX

# Registers a warp point: stamps the way_stone placement (rides the structures save
# key) + traces waystone_registered. Refuses an occupied/unplaceable tile.
func register_way_stone(tile: Vector2i) -> Dictionary:
	if not _capable("teleport"):
		_refuse("teleport", {"tile": _t(tile), "reason": "not_capable"})
		return {"ok": false, "reason": "not_capable"}
	if not Structures.can_place_on(_world_gen.get_tile_logic(tile)):
		_refuse("teleport", {"tile": _t(tile), "reason": "not_placeable"})
		return {"ok": false, "reason": "not_placeable"}
	if not _world_gen.add_placement(tile, Structures.WAYSTONE_ID, "teleport", int(_session.total_steps)):
		_refuse("teleport", {"tile": _t(tile), "reason": "cap_reached"})
		return {"ok": false, "reason": "cap_reached"}
	_emit("waystone_registered", {"tile": _t(tile)})
	_notify(tile)
	return {"ok": true, "tile": tile}

# Warps to `target`, or the last registered way stone when target is Vector2i.MAX.
# Returns the destination tile; the caller (router/scenario) moves the avatar.
func use_teleport(target: Vector2i = Vector2i.MAX) -> Dictionary:
	if not _capable("teleport"):
		_refuse("teleport", {"reason": "not_capable"})
		return {"ok": false, "reason": "not_capable"}
	var dest := last_way_stone() if target == Vector2i.MAX else target
	if dest == Vector2i.MAX or not is_way_stone(dest):
		_refuse("teleport", {"tile": _t(dest if dest != Vector2i.MAX else Vector2i.ZERO), "reason": "no_way_stone"})
		return {"ok": false, "reason": "no_way_stone"}
	_emit("teleport_used", {"from": _t(_session.player_tile), "tile": _t(dest)})
	return {"ok": true, "tile": dest}

# --- FLY (to a VISITED/registered way stone; edge-fly chaining is Phase 7) -----

func use_fly(target: Vector2i) -> Dictionary:
	if not _capable("fly"):
		_refuse("fly", {"tile": _t(target), "reason": "not_capable"})
		return {"ok": false, "reason": "not_capable"}
	if not is_way_stone(target):
		_refuse("fly", {"tile": _t(target), "reason": "unvisited_way_stone"})
		return {"ok": false, "reason": "unvisited_way_stone"}
	_emit("fly_used", {"from": _t(_session.player_tile), "tile": _t(target)})
	return {"ok": true, "tile": target}


# --- RIDE (the mount speed mode lives on player_avatar; this owns state + trace) -

func is_riding() -> bool:
	return _riding


# Toggles the mounted state; the avatar's speed mode/sprite follow the returned
# `riding` flag (the app layer owns the node). Traces mount_summoned (mounted flag).
func use_ride() -> Dictionary:
	if not _capable("ride"):
		_refuse("ride", {"reason": "not_capable"})
		return {"ok": false, "reason": "not_capable"}
	_riding = not _riding
	_emit("mount_summoned", {"species_id": _first_capable_species("ride"), "mounted": _riding})
	return {"ok": true, "riding": _riding}


# --- REPEL (session-scoped step counter; structural encounter suppression) -----

func activate_repel(steps: int = REPEL_DEFAULT_STEPS) -> Dictionary:
	if not _capable("repel"):
		_refuse("repel", {"reason": "not_capable"})
		return {"ok": false, "reason": "not_capable"}
	_session.repel_steps = maxi(0, steps)
	_emit("repel_active", {"steps": int(_session.repel_steps)})
	return {"ok": true, "steps": int(_session.repel_steps)}


func repel_steps() -> int:
	return int(_session.repel_steps)


# True while repel suppresses encounters; game_runtime.generate_wild_encounter
# returns {} BEFORE consuming any encounter rng (a structural suppression). The
# counter itself decays in session_state.note_step_taken (one per overworld step).
func repel_suppresses() -> bool:
	return int(_session.repel_steps) > 0


# --- POWER (movable boulder prop; the smallest strength task) ------------------

func boulder_tiles() -> Array:
	return _placement_tiles(Structures.BOULDER_ID)


# Seeds a movable boulder (setup/scenario seam); rides the placements map so it
# renders, blocks, and survives save like any placed prop.
func place_boulder(tile: Vector2i) -> Dictionary:
	if not Structures.can_place_on(_world_gen.get_tile_logic(tile)):
		return {"ok": false, "reason": "not_placeable"}
	if not _world_gen.add_placement(tile, Structures.BOULDER_ID, "power", int(_session.total_steps)):
		return {"ok": false, "reason": "cap_reached"}
	_notify(tile)
	return {"ok": true, "tile": tile}


# Pushes the boulder on `tile` one tile along `direction` when the destination is
# open ground. Refuses with no faced boulder or a blocked destination.
func use_power(tile: Vector2i, direction: Vector2i) -> Dictionary:
	if not _capable("power"):
		_refuse("power", {"tile": _t(tile), "reason": "not_capable"})
		return {"ok": false, "reason": "not_capable"}
	if not boulder_tiles().has(tile):
		_refuse("power", {"tile": _t(tile), "reason": "no_boulder"})
		return {"ok": false, "reason": "no_boulder"}
	var dest := tile + direction
	if not Structures.can_place_on(_world_gen.get_tile_logic(dest)):
		_refuse("power", {"tile": _t(tile), "reason": "blocked_destination"})
		return {"ok": false, "reason": "blocked_destination"}
	_world_gen.remove_placement(tile)
	_world_gen.add_placement(dest, Structures.BOULDER_ID, "power", int(_session.total_steps))
	_emit("power_used", {"from": _t(tile), "to": _t(dest)})
	_notify(tile) # vacated source + new destination both re-render (whole map re-mirrors)
	_notify(dest)
	return {"ok": true, "from": tile, "to": dest}


# --- ATTACK / CHARM (Phase-6 overworld hooks; trace + refuse, no entities yet) --

func use_attack(target_species_id: String) -> Dictionary:
	if not _capable("attack"):
		_refuse("attack", {"reason": "not_capable"})
		return {"ok": false, "reason": "not_capable"}
	if target_species_id.is_empty():
		_refuse("attack", {"reason": "no_target"})
		return {"ok": false, "reason": "no_target"}
	_emit("overworld_attack", {"tile": _t(_session.player_tile), "target_species_id": target_species_id})
	if overworld_attack_hook.is_valid():
		overworld_attack_hook.call(target_species_id)
	return {"ok": true, "species_id": target_species_id}


# Level-gated pacify: a high-enough Charm user prevents the (Phase-6) timid mon's
# flight/attack altogether. The hook is the Phase-6 plug-in; the trace is the proof.
func use_charm(target_species_id: String, target_level: int) -> Dictionary:
	if not _capable("charm"):
		_refuse("charm", {"reason": "not_capable"})
		return {"ok": false, "reason": "not_capable"}
	if target_species_id.is_empty():
		_refuse("charm", {"reason": "no_target"})
		return {"ok": false, "reason": "no_target"}
	var pacified := _first_capable_level("charm") >= target_level
	_emit("charm_used", {"tile": _t(_session.player_tile), "target_species_id": target_species_id, "level_gate_met": pacified})
	if overworld_charm_hook.is_valid():
		overworld_charm_hook.call(target_species_id, pacified)
	return {"ok": true, "species_id": target_species_id, "pacified": pacified}


# --- shared helpers -----------------------------------------------------------

# Tiles carrying a placed structure_id (way stone / boulder registry read), ordered by
# registration STEP then tile so last_way_stone() is the LAST-REGISTERED stone (both
# register_way_stone and the build loop stamp `step`), not a coordinate max. Boulder
# reads are membership-only (.has) — order moot; (step, tile) is a deterministic total order.
func _placement_tiles(structure_id: String) -> Array:
	var found: Array = [] # each: [step:int, tile:Vector2i]
	var placements: Dictionary = _world_gen.placements_for_save()
	for key in placements.keys():
		var entry: Variant = placements[key]
		if entry is Dictionary and str((entry as Dictionary).get("structure_id", "")) == structure_id:
			found.append([int((entry as Dictionary).get("step", 0)), _parse_tile(str(key))])
	found.sort_custom(func(a, b): return a[0] < b[0] if a[0] != b[0] else a[1] < b[1])
	return found.map(func(p): return p[1])


func _first_capable_species(move_id: String) -> String:
	var get_species := Callable(_catalog, "get_species")
	for mon in _session.party:
		if mon is Dictionary and FieldMoves.can_perform(mon, move_id, get_species):
			return str(mon.get("species_id", ""))
	return ""


func _first_capable_level(move_id: String) -> int:
	var get_species := Callable(_catalog, "get_species")
	var best := 0
	for mon in _session.party:
		if mon is Dictionary and FieldMoves.can_perform(mon, move_id, get_species):
			best = maxi(best, int(mon.get("level", 0)))
	return best


func _refuse(move_id: String, payload: Dictionary) -> void:
	var full := payload.duplicate()
	full["move_id"] = move_id
	_emit("field_move_refused", full)


func _emit(event_name: String, payload: Dictionary) -> void:
	_trace.emit_event(event_name, "FieldMoveRuntime", payload)


# Tell the world view a tile mutation happened (the harvest_runtime precedent):
# world_view._on_world_overridden re-mirrors the runtime mutation map + re-renders.
func _notify(tile: Vector2i) -> void:
	if _tile_overridden.is_valid():
		_tile_overridden.call(tile)


func _t(tile: Vector2i) -> Array:
	return [tile.x, tile.y]


func _parse_tile(key: String) -> Vector2i:
	var parts := key.split(",")
	if parts.size() != 2 or not parts[0].is_valid_int() or not parts[1].is_valid_int():
		return Vector2i.MAX
	return Vector2i(parts[0].to_int(), parts[1].to_int())
