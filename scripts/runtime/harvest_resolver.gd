extends RefCounted

# Single resolver for harvest actions on a faced tile (spec sections 2-3:
# docs/superpowers/specs/2026-07-18-harvest-and-world-mutation-design.md).
# Pure functions over a tile-logic Dictionary; game_runtime.harvest_tile owns
# capability checks, override stamping, item grants, and the trace.
# Prop suffixes verified against scripts/domain/biome_defs.gd: tree1.png
# (GRASSLAND/FOREST), cactus1.png (SAVANNA/DESERT), swamp tree13.png,
# spooky/tree1.png (SNOW), and rock_small1.png (ROCK + elevation cliffs).

const TREE_PROPS := ["tree1.png", "cactus1.png", "tree13.png", "spooky/tree1.png"]
const ROCK_PROP := "rock_small1.png"
const DIG_BIOME_ITEMS := {"PLAINS": "dry_soil", "GRASSLAND": "dry_soil", "FOREST": "dry_soil", "SAVANNA": "dry_soil", "SWAMP": "dry_soil", "SAND": "dry_sand", "DESERT": "soft_sand"}
const YIELDS := {"cut": "log", "smash": "hard_stone"}


# The applicable harvest action, checked cut -> dig -> smash; "" when the tile
# was already mutated or has nothing harvestable.
static func action_for_tile(logic: Dictionary) -> String:
	if bool(logic.get("mutated", false)):
		return ""
	var prop := str(logic.get("prop_path", ""))
	for tree_prop in TREE_PROPS:
		if prop.ends_with(tree_prop):
			return "cut"
	if bool(logic.get("walkable", false)) and DIG_BIOME_ITEMS.has(str(logic.get("biome", ""))):
		return "dig"
	if prop.ends_with(ROCK_PROP):
		return "smash"
	return ""


static func yield_for(move_id: String, logic: Dictionary) -> String:
	if move_id == "dig":
		return str(DIG_BIOME_ITEMS.get(str(logic.get("biome", "")), ""))
	return str(YIELDS.get(move_id, ""))


# Override kind stamped for a successful action: dug ground vs cleared props.
static func kind_for(move_id: String) -> String:
	return "dug" if move_id == "dig" else "cleared"


# item_name is the catalog display name of the granted yield.
static func success_message(move_id: String, item_name: String) -> String:
	match move_id:
		"cut":
			return "The tree was cut down! Got a log!"
		"smash":
			return "The rock was smashed! Got a hard stone!"
		"dig":
			return "The ground was dug up! Got %s!" % item_name
	return "Nothing happened."


# Failure wording: a constrained mon gets the personal refusal; the party-wide
# check gets the tile's block reason with the capability hint.
static func refusal_message(move_id: String, logic: Dictionary, mon_name: String) -> String:
	if not mon_name.is_empty():
		return "%s can't use that here." % mon_name
	var reason := str(logic.get("block_reason", "")).strip_edges()
	var hint := "It could be %s." % move_id.to_upper()
	return hint if reason.is_empty() else "%s %s" % [reason, hint]
