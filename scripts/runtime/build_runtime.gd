extends RefCounted

# Build-mode orchestration (spec: docs/product-specs/building-and-placement.md):
# the capability/occupancy/material gates for placing structures, material
# consumption through the session bag, the four build traces (every refusal
# carries a reason, never silent), and the placement signal GameRuntime mirrors
# to world_overridden so world_view re-renders the tile in place through its
# existing prop pipeline (placements apply at the get_tile_logic boundary).

const Structures := preload("res://scripts/domain/structures.gd")
const FieldMoves := preload("res://scripts/domain/field_moves.gd")
const HarvestResolver := preload("res://scripts/runtime/harvest_resolver.gd")

const BUILD_MOVE := "build"
const DEFAULT_STRUCTURE := "wall"

# Mirrored to GameRuntime.world_overridden (one-line connect in _ready).
signal structure_placed(tile: Vector2i)
signal structure_removed(tile: Vector2i)

# Would-trap guard budget: 2 reachable tiles proves the player still has a step
# (self + one neighbor); 1 means walled in on their own tile.
const TRAP_CHECK_BUDGET := 2

var _session = null
var _catalog = null
var _trace = null
var _world_gen = null


func setup(session_state, catalog, trace_logger, world_generator) -> void:
	_session = session_state
	_catalog = catalog
	_trace = trace_logger
	_world_gen = world_generator


# Entering build mode is traced with the default selection and the tile's biome
# so any refusals that follow are contextualized in the log.
func enter_build_mode(tile: Vector2i, structure_id: String = DEFAULT_STRUCTURE) -> Dictionary:
	var biome := _biome_for(tile)
	_emit("build_mode_entered", {"tile": _tile_payload(tile), "structure_id": structure_id, "biome": biome})
	return {"tile": tile, "structure_id": structure_id, "biome": biome}


# Per-biome material cost table pass-through ({item_id: count}).
func materials_for(structure_id: String, biome: String) -> Dictionary:
	return Structures.cost_for(structure_id, biome)


# Bag check against the session item API (lowercase bag ids: log/dry_soil/...).
func can_afford(structure_id: String, biome: String) -> bool:
	var cost: Dictionary = materials_for(structure_id, biome)
	for item_id in cost.keys():
		if _session.get_item_count(str(item_id)) < int(cost[item_id]):
			return false
	return true


# Places one structure: capability -> occupancy -> placeability -> materials ->
# would-trap guard -> shared override cap. Only a fully accepted placement
# consumes materials (and every refusal carries a reason, never silent).
func try_place(tile: Vector2i, structure_id: String, mon_constraint: Dictionary = {}) -> Dictionary:
	var biome := _biome_for(tile)
	if not Structures.is_valid(structure_id) or not _capable(BUILD_MOVE, mon_constraint):
		return _refuse(structure_id, tile, "not_capable" if Structures.is_valid(structure_id) else "not_placeable")
	var logic: Dictionary = _world_gen.get_tile_logic(tile)
	if str(logic.get("override_kind", "")) == "placed":
		return _refuse(structure_id, tile, "tile_occupied")
	if not Structures.can_place_on(logic):
		return _refuse(structure_id, tile, "not_placeable")
	if not can_afford(structure_id, biome):
		return _refuse(structure_id, tile, "missing_materials")
	# Gate is a PLACEMENT-TIME SNAPSHOT: the fence-neighbor check runs now and the
	# result is stored on the placement entry (world_overrides.apply_placement
	# renders from the stored flag, never re-deriving it). Deliberate — the ghost
	# preview uses the identical snapshot, so preview and placement always agree;
	# a later fence change leaving a door's gate art stale is cosmetic only
	# (gate vs door is a sprite choice; is_walkable/cost/refund ignore it).
	var gate := structure_id == "door" and _has_fence_neighbor(tile)
	if not Structures.is_walkable(structure_id) and _would_trap_player(tile):
		return _refuse(structure_id, tile, "would_trap")
	if not _world_gen.add_placement(tile, structure_id, BUILD_MOVE, int(_session.total_steps), gate):
		return _refuse(structure_id, tile, "cap_reached")
	var cost: Dictionary = materials_for(structure_id, biome)
	for item_id in cost.keys():
		_session.remove_item(str(item_id), int(cost[item_id]))
	_emit("structure_placed", {"structure_id": structure_id, "tile": _tile_payload(tile), "biome": biome})
	_emit("materials_consumed", {"structure_id": structure_id, "tile": _tile_payload(tile), "items": cost.duplicate()})
	structure_placed.emit(tile)
	return {"ok": true, "reason": "", "structure_id": structure_id, "tile": tile,
		"message": "The %s was built." % _label(structure_id)}


# Demolishes the structure on the tile — the faithful original escape from the
# build loop: Cut refunds ALL of cost_for(id, biome); a hard_stone-cost shell
# needs Smash. Removes the PLACEMENT entry only: the tile's clear (if any)
# persists by the two-map v3 design, so demolished ground stays cleared and
# never respawns its prop. The refund rides the session item API; the removal
# mirrors structure_placed with a structure_removed signal + two traces.
func try_demolish(tile: Vector2i, mon_constraint: Dictionary = {}) -> Dictionary:
	var logic: Dictionary = _world_gen.get_tile_logic(tile)
	if str(logic.get("override_kind", "")) != "placed":
		return {"ok": false, "move_id": "", "message": "", "refund": {}, "yield_item": ""}
	var structure_id := str(logic.get("structure_id", ""))
	var biome := str(logic.get("biome", ""))
	var move_id := Structures.demolish_move_for(structure_id, biome)
	if not _capable(move_id, mon_constraint):
		return {"ok": false, "move_id": move_id, "refund": {}, "yield_item": "",
			"message": _demolish_refusal(logic, move_id, mon_constraint)}
	var refund: Dictionary = materials_for(structure_id, biome)
	if _world_gen.remove_placement(tile).is_empty():
		return {"ok": false, "move_id": move_id, "message": "Nothing happened.", "refund": {}, "yield_item": ""}
	for item_id in refund.keys():
		_session.add_item(str(item_id), int(refund[item_id]))
	_emit("structure_demolished", {"structure_id": structure_id, "tile": _tile_payload(tile), "refund": refund.duplicate()})
	_emit("materials_refunded", {"structure_id": structure_id, "tile": _tile_payload(tile), "items": refund.duplicate()})
	structure_removed.emit(tile)
	return {"ok": true, "move_id": move_id, "structure_id": structure_id, "tile": tile, "refund": refund,
		"message": "The %s was demolished. Materials refunded." % _label(structure_id), "yield_item": ""}


# Whether the tile carries a clear fact in the separate clears map. Public seam
# so the app-layer demolition proof can assert demolition never destroys a clear
# (two-map v3 invariant) without reaching into the generator's private members.
func tile_has_clear(tile: Vector2i) -> bool:
	return _world_gen.overrides_for_save().has("%d,%d" % [tile.x, tile.y])


# Demolish moves whose shell class has NO witness material — a cost material that
# ONLY that move yields (log->cut, hard_stone->smash). While this stays empty, any
# party that gathered the materials to build was forced to field the very move
# that demolishes the result, and mons never leave the party — so a build-capable
# party is always demolition-capable. That is the load-bearing escape for the
# region-scale enclosure the would-trap guard deliberately allows (a closed wall
# ring with interior, a sealed island chokepoint): a non-empty result — from a
# shop/gift/starting-bag material source or a party-release/box mechanic — would
# turn a permitted seal into a permanent self-trap, so extend the guard before
# shipping either (spec: building-and-placement.md, the load-bearing invariant).
# PLAINS + DESERT between them cover both cost tables (default + desert shell).
func unwitnessed_demolish_moves() -> Array:
	var witnessed := {}
	for structure_id in Structures.IDS:
		for biome in ["PLAINS", "DESERT"]:
			var cost: Dictionary = materials_for(structure_id, biome)
			var move := Structures.demolish_move_for(structure_id, biome)
			for item_id in cost.keys():
				if _only_yield_of(str(item_id), move):
					witnessed[move] = true
	var missing := []
	for move in ["cut", "smash"]:
		if not witnessed.has(move):
			missing.append(move)
	return missing


# True when `move` yields item_id AND no other harvest action does (a dig yield
# is never exclusive to a demolish move, so dig items are never witnesses).
static func _only_yield_of(item_id: String, move: String) -> bool:
	if str(HarvestResolver.YIELDS.get(move, "")) != item_id:
		return false
	for other_move in HarvestResolver.YIELDS.keys():
		if str(other_move) != move and str(HarvestResolver.YIELDS[other_move]) == item_id:
			return false
	return not HarvestResolver.DIG_BIOME_ITEMS.values().has(item_id)


# A constrained mon must itself be capable of the move; otherwise any party member.
func _capable(move_id: String, mon_constraint: Dictionary) -> bool:
	var get_species := Callable(_catalog, "get_species")
	if not mon_constraint.is_empty():
		return FieldMoves.can_perform(mon_constraint, move_id, get_species)
	for mon in _session.party:
		if mon is Dictionary and FieldMoves.can_perform(mon, move_id, get_species):
			return true
	return false


# Would-trap guard: flood-fill from the PLAYER tile treating the candidate tile
# as solid (reachable_walkable_count's `blocked` seam — a hypothetical stamp that
# never touches the live placements map, so a phantom placement cannot leak, by
# construction rather than by a side-effect-free add/remove contract). Refused
# when the player would be left with no step at all — walled in on their own tile
# (the self-enclosure softlock: four walls in the open, two in a 1-wide corridor).
# Pens enclosing POKEMON are intentional: only PLAYER-tile reachability is
# guarded. Region-scale enclosure (a closed ring around interior space) stays
# ALLOWED by design — escape from it rests on demolition, guaranteed only while
# the material->demolition witness invariant holds (unwitnessed_demolish_moves).
func _would_trap_player(tile: Vector2i) -> bool:
	return _world_gen.reachable_walkable_count(_session.player_tile, TRAP_CHECK_BUDGET, tile) < 2


# A door beside a fence is stored (and rendered) as a gate; mirrors the
# structure_layer ghost check so preview and placement always agree.
func _has_fence_neighbor(tile: Vector2i) -> bool:
	for direction in [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]:
		if str(_world_gen.get_tile_logic(tile + direction).get("structure_id", "")) == "fence":
			return true
	return false


func _refuse(structure_id: String, tile: Vector2i, reason: String) -> Dictionary:
	_emit("structure_refused", {"structure_id": structure_id, "tile": _tile_payload(tile), "reason": reason})
	return {"ok": false, "reason": reason, "structure_id": structure_id, "tile": tile,
		"message": _refusal_message(reason, structure_id)}


func _refusal_message(reason: String, structure_id: String) -> String:
	match reason:
		"not_capable":
			return "No party Pokemon can BUILD."
		"missing_materials":
			return "You lack the materials for the %s." % _label(structure_id)
		"tile_occupied":
			return "Something is already built there."
		"would_trap":
			return "Building that would wall you in."
		"cap_reached":
			return "The world cannot hold any more structures."
	return "A %s can't be built there." % _label(structure_id)


# Harvest-style demolition wording: a constrained mon gets the personal refusal;
# the party-wide check gets the block reason plus the required-move hint.
func _demolish_refusal(logic: Dictionary, move_id: String, mon_constraint: Dictionary) -> String:
	var mon_name := str(mon_constraint.get("name", ""))
	if not mon_name.is_empty():
		return "%s can't use that here." % mon_name
	var reason := str(logic.get("block_reason", "")).strip_edges()
	var hint := "It could be %s." % move_id.to_upper()
	return hint if reason.is_empty() else "%s %s" % [reason, hint]


func _label(structure_id: String) -> String:
	return str(structure_id).replace("_", " ")


func _biome_for(tile: Vector2i) -> String:
	return str(_world_gen.get_tile_logic(tile).get("biome", ""))


func _tile_payload(tile: Vector2i) -> Array:
	return [tile.x, tile.y]


func _emit(event_name: String, payload: Dictionary) -> void:
	_trace.emit_event(event_name, "BuildRuntime", payload)
