extends RefCounted

# Campfire / kiln crafting runtime (spec:
# docs/product-specs/camping-crafting-survival.md): validates a recipe against a
# station and the bag, consumes ingredients all-or-nothing through the session item
# API, grants the output, and traces every outcome (item_crafted on success,
# craft_refused — never silent — on every refusal, each carrying a reason). Recipes
# are pure domain (recipes.gd); this is the stateful bag-mutation orchestration,
# mirroring build_runtime's trace-and-reason conventions. Craft-into-bag only: a
# crafted poke_ball enters the bag, but battle_runtime's BALL_ID is hardcoded to
# poke_ball until Phase 8's ball tiers (great_ball usability is out of scope).
# STATION-GATED, NOT LIT-GATED (deliberate, source-faithful — spec :13/:21/:22):
# craft() checks the station string + ingredients only, never the placement 'lit'
# flag, so an EXTINGUISHED campfire still crafts. The original has no fuel mechanic
# (firelight is permanent; "light or die" gates ghost PLACEMENT, not crafting);
# light correctly gates night ghost spawns (night_system.gd), just not crafting.

const Recipes := preload("res://scripts/domain/recipes.gd")
const MaterialDrops := preload("res://scripts/domain/material_drops.gd")

var _session = null
var _catalog = null
var _trace = null


func setup(session_state, catalog, trace_logger) -> void:
	_session = session_state
	_catalog = catalog
	_trace = trace_logger


# The sorted output ids a station's menu lists (the five campfire recipes; Great
# Ball never appears — its station is KILN). Passthrough to the domain table.
func craftable_at_station(station_id: String) -> Array:
	return Recipes.craftable_at_station(station_id)


# {item_id: count_still_needed} for an output given the live bag — the menu greys
# short recipes with these counts.
func missing_for(output_id: String) -> Dictionary:
	return Recipes.missing_ingredients(Recipes.recipe_for(output_id), _bag_counts_for(output_id))


# Witness-invariant audit seam (material_drops.gd WITNESS INVARIANT): the interim
# battle-drop table must NEVER yield log / hard_stone, the build-loop witness
# materials the region-seal demolition escape rides on. craft_flow asserts this
# every run (via is_drop_material) so a future edit adding either fails loudly
# instead of silently turning a permitted wall-ring seal into a permanent self-trap.
static func drop_witness_clean() -> bool:
	return not MaterialDrops.is_drop_material("log") and not MaterialDrops.is_drop_material("hard_stone")


# Crafts one output at a station. Returns {ok, message, output_id, station, reason,
# missing}: ok=true consumes the ingredients and grants the item (item_crafted);
# ok=false emits craft_refused with a reason — no_station (no station faced),
# no_recipe (unknown output), wrong_station (a kiln recipe at a campfire), or
# missing (short ingredients). All-or-nothing: counts are verified before any
# removal, so a refusal never consumes.
func craft(output_id: String, station_id: String) -> Dictionary:
	var recipe := Recipes.recipe_for(output_id)
	if recipe.is_empty():
		return _refuse(output_id, station_id, "no_recipe", {})
	if station_id.is_empty():
		return _refuse(output_id, station_id, "no_station", {})
	if str(recipe.get("station", "")) != station_id:
		return _refuse(output_id, station_id, "wrong_station", {}, str(recipe.get("station", "")))
	var missing := Recipes.missing_ingredients(recipe, _bag_counts_for(output_id))
	if not missing.is_empty():
		return _refuse(output_id, station_id, "missing", missing)
	var ingredients: Dictionary = recipe.get("ingredients", {})
	for item_id in ingredients.keys():
		_session.remove_item(str(item_id), int(ingredients[item_id]))
	_session.add_item(output_id, 1)
	_emit("item_crafted", {"output_id": output_id, "station": station_id, "ingredients": ingredients.duplicate()})
	return {"ok": true, "message": "Crafted a %s." % _label(output_id), "output_id": output_id,
		"station": station_id, "reason": "", "missing": {}}


# The live bag counts for an output's ingredients ({item_id: have}) via the session
# item API — the pure missing_ingredients domain rule reads this, never the bag.
func _bag_counts_for(output_id: String) -> Dictionary:
	var counts: Dictionary = {}
	var raw: Variant = Recipes.recipe_for(output_id).get("ingredients", {})
	if raw is Dictionary:
		for item_id in (raw as Dictionary).keys():
			counts[str(item_id)] = _session.get_item_count(str(item_id))
	return counts


func _refuse(output_id: String, station_id: String, reason: String, missing: Dictionary, needed_station: String = "") -> Dictionary:
	_emit("craft_refused", {"output_id": output_id, "station": station_id, "reason": reason, "missing": missing.duplicate()})
	return {"ok": false, "message": _refusal_message(reason, output_id, needed_station), "output_id": output_id,
		"station": station_id, "reason": reason, "missing": missing}


func _refusal_message(reason: String, output_id: String, needed_station: String) -> String:
	match reason:
		"no_recipe":
			return "You don't know how to make that."
		"no_station":
			return "There is no crafting station here."
		"wrong_station":
			return "That needs a %s." % (needed_station.replace("_", " ") if not needed_station.is_empty() else "different station")
		"missing":
			return "You lack the materials for the %s." % _label(output_id)
	return "You can't craft that here."


func _label(output_id: String) -> String:
	var display := str(_catalog.get_item(output_id).get("display_name", "")) if _catalog != null else ""
	return display if not display.is_empty() else str(output_id).replace("_", " ")


func _emit(event_name: String, payload: Dictionary) -> void:
	_trace.emit_event(event_name, "CraftingRuntime", payload)
