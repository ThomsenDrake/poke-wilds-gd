@tool
class_name StructureData
extends Resource
## StructureData - Resource class for buildable structure definitions
## Contains structure properties, recipes, and placement rules

# Structure categories
enum Category {
	FOUNDATION,    # Floors, platforms
	WALL,          # Walls, fences
	FURNITURE,     # Tables, chairs, beds
	STORAGE,       # Chests, containers
	CRAFTING,      # Workbenches, forges
	DECORATION,    # Signs, lights
	UTILITY,       # Doors, ladders
	FARMING,       # Planters, berry pots
	POKEMON        # Pokemon-related structures
}

# Structure function types
enum Function {
	NONE,
	WALKABLE,      # Can walk on it (floors)
	BLOCKING,      # Blocks movement (walls)
	STORAGE,       # Can store items
	CRAFTING,      # Opens crafting menu
	HEALING,       # Heals Pokemon
	PC_ACCESS,     # Access PC boxes
	SLEEP,         # Rest/save point
	LIGHT,         # Provides light
	BREEDING       # Pokemon breeding
}

# Basic identification
@export var id: String = ""
@export var display_name: String = ""
@export var description: String = ""
@export var category: Category = Category.FURNITURE

# Function
@export var function: Function = Function.NONE
@export var function_param: String = ""  # Extra data for function

# Size in tiles (most are 1x1)
@export var width: int = 1
@export var height: int = 1

# Recipe: Dictionary of item_id -> count required
@export var recipe: Dictionary = {}  # e.g., {"WOOD": 5, "STONE": 2}

# Placement rules
@export var requires_floor: bool = true     # Must be placed on floor/ground
@export var can_place_on_water: bool = false
@export var blocks_movement: bool = true
@export var indoor_only: bool = false
@export var outdoor_only: bool = false

# Durability
@export var max_durability: int = 100
@export var can_be_damaged: bool = true
@export var can_be_destroyed: bool = true

# Visual
@export var sprite_path: String = ""
@export var color: Color = Color.WHITE  # Fallback color if no sprite
@export var z_layer: int = 0  # Sorting layer

# Build time
@export var build_ticks: int = 1  # How many "ticks" to build (instant if 1)

# Sorting
@export var sort_order: int = 0


## Check if player has required materials
func can_afford(inventory) -> bool:
	for item_id in recipe.keys():
		var required: int = recipe[item_id]
		if inventory.get_item_count(item_id) < required:
			return false
	return true


## Get list of missing materials
func get_missing_materials(inventory) -> Array[Dictionary]:
	var missing: Array[Dictionary] = []
	for item_id in recipe.keys():
		var required: int = recipe[item_id]
		var have: int = inventory.get_item_count(item_id)
		if have < required:
			missing.append({
				"item_id": item_id,
				"required": required,
				"have": have,
				"need": required - have
			})
	return missing


## Consume materials from inventory
func consume_materials(inventory) -> bool:
	if not can_afford(inventory):
		return false
	
	for item_id in recipe.keys():
		var amount: int = recipe[item_id]
		inventory.remove_item(item_id, amount)
	
	return true


## Get recipe as formatted string
func get_recipe_string() -> String:
	var parts: Array[String] = []
	for item_id in recipe.keys():
		var item: ItemData = ItemDatabase.get_item(item_id)
		var item_name: String = item.display_name if item else item_id
		parts.append(str(recipe[item_id]) + "x " + item_name)
	return ", ".join(parts)


## Get category display name
static func get_category_name(cat: Category) -> String:
	match cat:
		Category.FOUNDATION: return "Foundations"
		Category.WALL: return "Walls"
		Category.FURNITURE: return "Furniture"
		Category.STORAGE: return "Storage"
		Category.CRAFTING: return "Crafting"
		Category.DECORATION: return "Decoration"
		Category.UTILITY: return "Utility"
		Category.FARMING: return "Farming"
		Category.POKEMON: return "Pokemon"
		_: return "Structures"


## Create structure from parameters
static func create(
	p_id: String,
	p_name: String,
	p_desc: String,
	p_category: Category,
	p_recipe: Dictionary,
	p_function: Function = Function.NONE
) -> StructureData:
	var structure := StructureData.new()
	structure.id = p_id
	structure.display_name = p_name
	structure.description = p_desc
	structure.category = p_category
	structure.recipe = p_recipe
	structure.function = p_function
	return structure
