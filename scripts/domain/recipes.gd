extends RefCounted

# Campfire / kiln crafting recipe table (spec:
# docs/product-specs/camping-crafting-survival.md). Pure data + rules: the
# faithful PokeWilds campfire recipes plus the one kiln recipe, keyed by the
# lowercase bag ids the rest of the port already uses (session.add_item and
# pokewilds/i18n/item.properties). No Godot node imports and no runtime/data
# dependency, so the domain layer stays intact (check_architecture
# SCRIPT_ALLOWED[domain] = {domain, core}).
#
# FAITHFUL SOURCES (.firecrawl): Poke Ball = 1 Magnet + 1 Hard Shell at a
# Campfire (fresh-sleepingbag.md:163, wiki-campfire.md:427); Soft Bedding =
# 3 Soft Feather + 3 Silky Thread (wiki-campfire.md:320); Old Rod = 1 Log +
# 1 Silky Thread (:388); Good Rod = 1 Old Rod + 2 Metal Coats (:396);
# Super Rod = 1 Good Rod + 3 Magnets (:404). Great Ball = 1 Poke Ball +
# 1 Metal Coat, but crafted at a KILN, not a campfire (fresh-sleepingbag.md:167,
# wiki-campfire.md:432) — the exec plan's "Great Ball (Magnet + Hard Shell)"
# parenthetical IS the Poke Ball recipe, so the faithful split is recorded here
# rather than flattening Great Ball into the Poke Ball recipe. No recipe-learning
# / discovery mechanic exists in the wiki, so every campfire recipe is always
# listable; the craft menu greys the ones whose ingredients are short.
#
# EXPLICITLY OUT OF PHASE 2 (documented in the spec): Repel (conflicts with the
# Phase 4 field-move model), apricorn balls, the other kiln balls (Ultra / Nest /
# Dusk / ...), Rare Candy, and any USABILITY for the rods (they craft into the bag;
# fishing lands in Phase 5). Crafted balls are bag inventory until Phase 8's ball
# tiers (battle_runtime.BALL_ID is hardcoded to poke_ball until then).

# Crafting station ids. Campfire is the only station a placed structure provides
# in Phase 2; KILN is defined so the Great Ball recipe stays faithful even though
# no kiln structure exists yet — Great Ball is therefore UNAVAILABLE this phase (a
# craft attempt is refused with reason "wrong_station", never silently flattened).
const STATION_CAMPFIRE := "campfire"
const STATION_KILN := "kiln"

# Lowercase bag ids, all present in pokewilds/i18n/item.properties (verified).
const RECIPES := {
	"poke_ball": {"station": STATION_CAMPFIRE, "ingredients": {"magnet": 1, "hard_shell": 1}},
	"soft_bedding": {"station": STATION_CAMPFIRE, "ingredients": {"soft_feather": 3, "silky_thread": 3}},
	"old_rod": {"station": STATION_CAMPFIRE, "ingredients": {"log": 1, "silky_thread": 1}},
	"good_rod": {"station": STATION_CAMPFIRE, "ingredients": {"old_rod": 1, "metal_coat": 2}},
	"super_rod": {"station": STATION_CAMPFIRE, "ingredients": {"good_rod": 1, "magnet": 3}},
	# Kiln-gated and UNAVAILABLE in Phase 2 (no kiln structure); defined for fidelity.
	"great_ball": {"station": STATION_KILN, "ingredients": {"poke_ball": 1, "metal_coat": 1}},
}


# The recipe dict for an output id ({} when unknown). Fresh duplicate so callers
# may read freely (the table itself is const and shared).
static func recipe_for(output_id: String) -> Dictionary:
	var recipe: Variant = RECIPES.get(output_id.strip_edges().to_lower(), {})
	return (recipe as Dictionary).duplicate(true) if recipe is Dictionary else {}


# Sorted output ids craftable at a station. The campfire menu lists EXACTLY these
# five; Great Ball never appears because its station is KILN.
static func craftable_at_station(station_id: String) -> Array:
	var ids: Array = []
	for output_id in RECIPES.keys():
		if str((RECIPES[output_id] as Dictionary).get("station", "")) == station_id:
			ids.append(str(output_id))
	ids.sort()
	return ids


# {item_id: count_still_needed} for the ingredients the bag cannot yet cover;
# empty when the recipe is craftable from bag_counts. Pure function of the recipe
# and the caller-supplied counts ({item_id: have}); no session dependency.
static func missing_ingredients(recipe: Dictionary, bag_counts: Dictionary) -> Dictionary:
	var missing: Dictionary = {}
	var raw: Variant = recipe.get("ingredients", {})
	if not (raw is Dictionary):
		return missing
	var ingredients: Dictionary = raw
	for item_id in ingredients.keys():
		var need := int(ingredients[item_id])
		var have := int(bag_counts.get(str(item_id), 0))
		if have < need:
			missing[str(item_id)] = need - have
	return missing


# True when output_id exists, its station matches, and the bag covers every
# ingredient. Convenience wrapper over recipe_for + missing_ingredients.
static func can_craft(output_id: String, bag_counts: Dictionary, station_id: String) -> bool:
	var recipe := recipe_for(output_id)
	if recipe.is_empty():
		return false
	if str(recipe.get("station", "")) != station_id:
		return false
	return missing_ingredients(recipe, bag_counts).is_empty()


# True when the output is a campfire recipe (the menu's list gate; also how the
# craft flow proves the five campfire recipes are the complete campfire set).
static func is_campfire_recipe(output_id: String) -> bool:
	return str(recipe_for(output_id).get("station", "")) == STATION_CAMPFIRE
