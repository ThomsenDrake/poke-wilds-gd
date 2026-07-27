extends RefCounted

# Harvest orchestration extracted from game_runtime.gd (Phase 3 storage slice:
# game_runtime was at its line ceiling and hosting storage_runtime needed room).
# Callers keep using game_runtime.harvest_tile, which forwards here: one faced tile
# through the shared resolver (action, capability, override stamp, base yield,
# field_move_used trace), and a built tile routes to build_runtime.try_demolish
# (Cut refunds everything; hard-stone shells Smash). A fresh dig additionally draws
# ONE bonus find (resolver DIG_BONUS_POOLS; step-counter pure — NO rng is injected,
# game_runtime's setup seam holds; emits dig_item_found, Phase 5 acquisition).
# The world_overridden signal reaches this runtime as the injected emitter
# Callable so the view still re-renders the tile in place.

const HarvestResolver := preload("res://scripts/runtime/harvest_resolver.gd")
const FieldMoves := preload("res://scripts/domain/field_moves.gd")

var _session = null
var _catalog = null
var _trace = null
var _world_gen = null
var _build_runtime = null
var _tile_overridden: Callable = Callable()


func setup(session_state, catalog, trace_logger, world_generator, build_runtime, tile_overridden: Callable) -> void:
	_session = session_state
	_catalog = catalog
	_trace = trace_logger
	_world_gen = world_generator
	_build_runtime = build_runtime
	_tile_overridden = tile_overridden


# Harvests one faced tile through the shared resolver: action, capability,
# override stamp, yield, trace. A built tile instead routes to demolition.
func harvest_tile(tile: Vector2i, mon_constraint: Dictionary = {}) -> Dictionary:
	var logic: Dictionary = _world_gen.get_tile_logic(tile)
	var action := HarvestResolver.action_for_tile(logic)
	if action.is_empty():
		if str(logic.get("override_kind", "")) == "placed":
			return _build_runtime.try_demolish(tile, mon_constraint)
		return {"ok": false, "move_id": "", "message": "There is nothing left here.", "yield_item": ""}
	if not _capable(action, mon_constraint):
		var mon_name := str(mon_constraint.get("name", "")) if not mon_constraint.is_empty() else ""
		return {"ok": false, "move_id": action, "message": HarvestResolver.refusal_message(action, logic, mon_name), "yield_item": ""}
	var yield_item := HarvestResolver.yield_for(action, logic)
	if yield_item.is_empty() or not _world_gen.add_override(tile, HarvestResolver.kind_for(action), action, _session.total_steps):
		_trace.warning("GameRuntime", "Harvest was refused by the world override map.", {"tile": _tile_payload(tile), "move_id": action})
		return {"ok": false, "move_id": action, "message": "Nothing happened.", "yield_item": ""}
	_session.add_item(yield_item)
	_trace.emit_event("field_move_used", "GameRuntime", {
		"move_id": action,
		"tile": _tile_payload(tile),
		"yield": yield_item
	})
	_tile_overridden.call(tile)
	var item_name := str(_catalog.get_item(yield_item).get("display_name", yield_item))
	var message := HarvestResolver.success_message(action, item_name)
	if action == "dig": # BONUS find parallel to the base yield — pure step-counter draw, NO rng (night_system guarantee)
		var bonus := HarvestResolver.bonus_for(action, logic, tile, _session.total_steps)
		if not bonus.is_empty():
			_session.add_item(bonus)
			# dig_item_found payload keys: tile [x, y], item_id, biome (docs/references/trace-events.md).
			_trace.emit_event("dig_item_found", "GameRuntime", {"tile": _tile_payload(tile), "item_id": bonus, "biome": str(logic.get("biome", ""))})
			message += " Also found %s!" % str(_catalog.get_item(bonus).get("display_name", bonus))
	return {"ok": true, "move_id": action, "message": message, "yield_item": yield_item}


# Single capability gate: a constrained mon must itself be able; else any party member.
func _capable(move_id: String, mon_constraint: Dictionary) -> bool:
	var get_species := Callable(_catalog, "get_species")
	if not mon_constraint.is_empty():
		return FieldMoves.can_perform(mon_constraint, move_id, get_species)
	for mon in _session.party:
		if mon is Dictionary and FieldMoves.can_perform(mon, move_id, get_species):
			return true
	return false


func _tile_payload(tile: Vector2i) -> Array:
	return [tile.x, tile.y]
