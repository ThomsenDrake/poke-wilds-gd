extends RefCounted

# CampMenu runtime-access block EXTRACTED from camp_menu.gd at the 220 ui wall
# (restyle slice wave 2; the title_screen_stage.gd/menu_context.gd extraction
# precedent). Every function is behavior-identical to the pre-extraction
# private methods: the crafting runtime / session / catalog reads, the
# REFLECTIVE recipe-ingredient read off the crafting runtime's pinned Recipes
# domain const (ui may not import domain per check_architecture), the lit
# placement read, and the MessageBox toast. All take the runtime (or screen)
# as a parameter so the screen stays the owner of state.

# The crafting runtime off /root/GameRuntime (null-safe).
static func crafting(runtime: Node) -> Variant:
	return runtime.get("crafting_runtime") if runtime != null else null


# The sorted output ids a station lists (the five campfire recipes).
static func craftable_ids(crafting: Variant, station_id: String) -> Array:
	if crafting == null or not crafting.has_method("craftable_at_station"):
		return []
	var listed: Variant = crafting.call("craftable_at_station", station_id)
	return listed if listed is Array else []


# {item_id: count_still_needed}; the crafting runtime's menu contract.
static func missing_for(crafting: Variant, output_id: String) -> Dictionary:
	if crafting == null or not crafting.has_method("missing_for"):
		return {}
	var missing: Variant = crafting.call("missing_for", output_id)
	return missing if missing is Dictionary else {}


# Ingredients read reflectively off the crafting runtime's pinned Recipes
# domain const (script -> Recipes -> RECIPES): the layer-safe read.
static func ingredients_for(crafting: Variant, output_id: String) -> Dictionary:
	var script: Variant = (crafting as Object).get_script() if crafting != null else null
	var recipes: Variant = (script as Script).get_script_constant_map().get("Recipes") if script is Script else null
	var table: Variant = (recipes as Script).get_script_constant_map().get("RECIPES") if recipes is Script else null
	var recipe: Variant = (table as Dictionary).get(output_id, {}) if table is Dictionary else {}
	var ingredients: Variant = (recipe as Dictionary).get("ingredients", {}) if recipe is Dictionary else {}
	return ingredients if ingredients is Dictionary else {}


static func item_count(runtime: Node, item_id: String) -> int:
	var session: Variant = runtime.get("session") if runtime != null else null
	return int(session.get_item_count(item_id)) if session != null else 0


static func item_label(runtime: Node, item_id: String) -> String:
	var item: Variant = runtime.catalog.get_item(item_id.strip_edges().to_lower()) if runtime != null else {}
	var label := str(item.get("display_name", "")) if item is Dictionary else ""
	return label.capitalize() if not label.is_empty() else item_id.replace("_", " ").capitalize()


# Absent "lit" means lit (structures.placement_is_lit semantics; via the public
# placed_structures accessor — the ui layer never reads the domain rule).
static func placement_is_lit(runtime: Node, tile: Vector2i) -> bool:
	if runtime == null:
		return true
	var entry: Variant = runtime.placed_structures().get("%d,%d" % [tile.x, tile.y], {})
	return entry.get("lit", true) != false if entry is Dictionary else true


# The MessageBox-sibling toast (no-op on empty text / missing box).
static func toast(screen: Node, text: String, seconds: float) -> void:
	if text.is_empty():
		return
	var box := screen.get_node_or_null("../MessageBox")
	if box != null and box.has_method("show_message"):
		box.call("show_message", text, seconds)
