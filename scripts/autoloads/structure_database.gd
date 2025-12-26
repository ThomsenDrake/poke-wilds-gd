extends Node
## StructureDatabase - Central repository for buildable structure definitions
## Loads, caches, and provides access to all StructureData resources

signal database_loaded()
signal structure_loaded(structure_id: String)

# All loaded structures indexed by ID
var _structures: Dictionary = {}  # String -> StructureData

# Structures by category for quick filtering
var _by_category: Dictionary = {}  # StructureData.Category -> Array[StructureData]

# Loading state
var _is_loaded: bool = false


func _ready() -> void:
	# Initialize category arrays
	for cat in StructureData.Category.values():
		_by_category[cat] = []
	
	# Register built-in structures
	_register_foundations()
	_register_walls()
	_register_furniture()
	_register_storage()
	_register_crafting()
	_register_utility()
	_register_pokemon()
	
	_is_loaded = true
	database_loaded.emit()
	print("StructureDatabase initialized with ", _structures.size(), " structures")


## Check if database is ready
func is_loaded() -> bool:
	return _is_loaded


## Get a structure by ID
func get_structure(structure_id: String) -> StructureData:
	var upper_id := structure_id.to_upper()
	if _structures.has(upper_id):
		return _structures[upper_id]
	return null


## Check if a structure exists
func has_structure(structure_id: String) -> bool:
	return _structures.has(structure_id.to_upper())


## Get all structures in a category
func get_structures_by_category(category: StructureData.Category) -> Array:
	if _by_category.has(category):
		return _by_category[category]
	return []


## Get all structure IDs
func get_all_structure_ids() -> Array[String]:
	var ids: Array[String] = []
	ids.assign(_structures.keys())
	return ids


## Get structure count
func get_structure_count() -> int:
	return _structures.size()


## Get all buildable structures (player has materials for)
func get_buildable_structures(inventory) -> Array[StructureData]:
	var buildable: Array[StructureData] = []
	for structure in _structures.values():
		if structure.can_afford(inventory):
			buildable.append(structure)
	return buildable


## Register a structure in the database
func register_structure(structure: StructureData) -> void:
	var upper_id := structure.id.to_upper()
	_structures[upper_id] = structure
	
	if not _by_category.has(structure.category):
		_by_category[structure.category] = []
	_by_category[structure.category].append(structure)
	
	structure_loaded.emit(upper_id)


# ============ Built-in Structure Registration ============

func _register_foundations() -> void:
	# Wood Floor
	var wood_floor := StructureData.new()
	wood_floor.id = "WOOD_FLOOR"
	wood_floor.display_name = "Wood Floor"
	wood_floor.description = "A simple wooden floor tile."
	wood_floor.category = StructureData.Category.FOUNDATION
	wood_floor.function = StructureData.Function.WALKABLE
	wood_floor.recipe = {"WOOD": 2}
	wood_floor.blocks_movement = false
	wood_floor.requires_floor = false
	wood_floor.color = Color(0.6, 0.4, 0.2)
	wood_floor.sort_order = 1
	register_structure(wood_floor)
	
	# Stone Floor
	var stone_floor := StructureData.new()
	stone_floor.id = "STONE_FLOOR"
	stone_floor.display_name = "Stone Floor"
	stone_floor.description = "A sturdy stone floor tile."
	stone_floor.category = StructureData.Category.FOUNDATION
	stone_floor.function = StructureData.Function.WALKABLE
	stone_floor.recipe = {"STONE": 2}
	stone_floor.blocks_movement = false
	stone_floor.requires_floor = false
	stone_floor.color = Color(0.5, 0.5, 0.5)
	stone_floor.sort_order = 2
	register_structure(stone_floor)
	
	# Wood Platform (can place on water)
	var wood_platform := StructureData.new()
	wood_platform.id = "WOOD_PLATFORM"
	wood_platform.display_name = "Wood Platform"
	wood_platform.description = "A wooden platform. Can be placed on water."
	wood_platform.category = StructureData.Category.FOUNDATION
	wood_platform.function = StructureData.Function.WALKABLE
	wood_platform.recipe = {"WOOD": 4}
	wood_platform.blocks_movement = false
	wood_platform.requires_floor = false
	wood_platform.can_place_on_water = true
	wood_platform.color = Color(0.5, 0.35, 0.2)
	wood_platform.sort_order = 3
	register_structure(wood_platform)


func _register_walls() -> void:
	# Wood Wall
	var wood_wall := StructureData.new()
	wood_wall.id = "WOOD_WALL"
	wood_wall.display_name = "Wood Wall"
	wood_wall.description = "A simple wooden wall."
	wood_wall.category = StructureData.Category.WALL
	wood_wall.function = StructureData.Function.BLOCKING
	wood_wall.recipe = {"WOOD": 3}
	wood_wall.blocks_movement = true
	wood_wall.color = Color(0.55, 0.35, 0.15)
	wood_wall.sort_order = 10
	register_structure(wood_wall)
	
	# Stone Wall
	var stone_wall := StructureData.new()
	stone_wall.id = "STONE_WALL"
	stone_wall.display_name = "Stone Wall"
	stone_wall.description = "A sturdy stone wall."
	stone_wall.category = StructureData.Category.WALL
	stone_wall.function = StructureData.Function.BLOCKING
	stone_wall.recipe = {"STONE": 3}
	stone_wall.blocks_movement = true
	stone_wall.color = Color(0.45, 0.45, 0.45)
	stone_wall.sort_order = 11
	register_structure(stone_wall)
	
	# Fence
	var fence := StructureData.new()
	fence.id = "FENCE"
	fence.display_name = "Fence"
	fence.description = "A wooden fence."
	fence.category = StructureData.Category.WALL
	fence.function = StructureData.Function.BLOCKING
	fence.recipe = {"WOOD": 2}
	fence.blocks_movement = true
	fence.color = Color(0.65, 0.45, 0.25)
	fence.sort_order = 12
	register_structure(fence)


func _register_furniture() -> void:
	# Bed
	var bed := StructureData.new()
	bed.id = "BED"
	bed.display_name = "Bed"
	bed.description = "A place to rest. Saves your game."
	bed.category = StructureData.Category.FURNITURE
	bed.function = StructureData.Function.SLEEP
	bed.recipe = {"WOOD": 5, "FIBER": 3}
	bed.blocks_movement = true
	bed.color = Color(0.8, 0.3, 0.3)
	bed.sort_order = 20
	register_structure(bed)
	
	# Chair
	var chair := StructureData.new()
	chair.id = "CHAIR"
	chair.display_name = "Chair"
	chair.description = "A simple wooden chair."
	chair.category = StructureData.Category.FURNITURE
	chair.function = StructureData.Function.NONE
	chair.recipe = {"WOOD": 3}
	chair.blocks_movement = true
	chair.color = Color(0.6, 0.4, 0.2)
	chair.sort_order = 21
	register_structure(chair)
	
	# Table
	var table := StructureData.new()
	table.id = "TABLE"
	table.display_name = "Table"
	table.description = "A wooden table."
	table.category = StructureData.Category.FURNITURE
	table.function = StructureData.Function.NONE
	table.recipe = {"WOOD": 4}
	table.blocks_movement = true
	table.color = Color(0.5, 0.35, 0.2)
	table.sort_order = 22
	register_structure(table)


func _register_storage() -> void:
	# Chest
	var chest := StructureData.new()
	chest.id = "CHEST"
	chest.display_name = "Chest"
	chest.description = "Stores items. Has 20 slots."
	chest.category = StructureData.Category.STORAGE
	chest.function = StructureData.Function.STORAGE
	chest.function_param = "20"  # Number of slots
	chest.recipe = {"WOOD": 6}
	chest.blocks_movement = true
	chest.color = Color(0.7, 0.5, 0.2)
	chest.sort_order = 30
	register_structure(chest)
	
	# Large Chest
	var large_chest := StructureData.new()
	large_chest.id = "LARGE_CHEST"
	large_chest.display_name = "Large Chest"
	large_chest.description = "Stores items. Has 40 slots."
	large_chest.category = StructureData.Category.STORAGE
	large_chest.function = StructureData.Function.STORAGE
	large_chest.function_param = "40"
	large_chest.recipe = {"WOOD": 10, "STONE": 2}
	large_chest.blocks_movement = true
	large_chest.color = Color(0.6, 0.45, 0.2)
	large_chest.sort_order = 31
	register_structure(large_chest)


func _register_crafting() -> void:
	# Workbench
	var workbench := StructureData.new()
	workbench.id = "WORKBENCH"
	workbench.display_name = "Workbench"
	workbench.description = "Used to craft items and structures."
	workbench.category = StructureData.Category.CRAFTING
	workbench.function = StructureData.Function.CRAFTING
	workbench.recipe = {"WOOD": 8}
	workbench.blocks_movement = true
	workbench.color = Color(0.55, 0.4, 0.2)
	workbench.sort_order = 40
	register_structure(workbench)
	
	# Forge
	var forge := StructureData.new()
	forge.id = "FORGE"
	forge.display_name = "Forge"
	forge.description = "Used to smelt and craft metal items."
	forge.category = StructureData.Category.CRAFTING
	forge.function = StructureData.Function.CRAFTING
	forge.function_param = "METAL"
	forge.recipe = {"STONE": 10, "WOOD": 5}
	forge.blocks_movement = true
	forge.color = Color(0.3, 0.3, 0.3)
	forge.sort_order = 41
	register_structure(forge)
	
	# Apricorn Processor
	var apricorn_proc := StructureData.new()
	apricorn_proc.id = "APRICORN_PROCESSOR"
	apricorn_proc.display_name = "Apricorn Processor"
	apricorn_proc.description = "Turns Apricorns into Poke Balls."
	apricorn_proc.category = StructureData.Category.CRAFTING
	apricorn_proc.function = StructureData.Function.CRAFTING
	apricorn_proc.function_param = "APRICORN"
	apricorn_proc.recipe = {"WOOD": 6, "STONE": 4}
	apricorn_proc.blocks_movement = true
	apricorn_proc.color = Color(0.8, 0.6, 0.3)
	apricorn_proc.sort_order = 42
	register_structure(apricorn_proc)


func _register_utility() -> void:
	# Door
	var door := StructureData.new()
	door.id = "DOOR"
	door.display_name = "Door"
	door.description = "A wooden door. Can be opened and closed."
	door.category = StructureData.Category.UTILITY
	door.function = StructureData.Function.NONE
	door.recipe = {"WOOD": 4}
	door.blocks_movement = false  # Can walk through when open
	door.color = Color(0.5, 0.35, 0.2)
	door.sort_order = 50
	register_structure(door)
	
	# Torch
	var torch := StructureData.new()
	torch.id = "TORCH"
	torch.display_name = "Torch"
	torch.description = "Provides light in dark areas."
	torch.category = StructureData.Category.UTILITY
	torch.function = StructureData.Function.LIGHT
	torch.recipe = {"WOOD": 1, "FIBER": 1}
	torch.blocks_movement = false
	torch.color = Color(1.0, 0.8, 0.3)
	torch.sort_order = 51
	register_structure(torch)
	
	# Sign
	var sign := StructureData.new()
	sign.id = "SIGN"
	sign.display_name = "Sign"
	sign.description = "A sign to mark locations."
	sign.category = StructureData.Category.UTILITY
	sign.function = StructureData.Function.NONE
	sign.recipe = {"WOOD": 2}
	sign.blocks_movement = false
	sign.color = Color(0.7, 0.55, 0.35)
	sign.sort_order = 52
	register_structure(sign)


func _register_pokemon() -> void:
	# Pokemon Center Table
	var heal_table := StructureData.new()
	heal_table.id = "HEAL_TABLE"
	heal_table.display_name = "Healing Table"
	heal_table.description = "Fully heals your Pokemon."
	heal_table.category = StructureData.Category.POKEMON
	heal_table.function = StructureData.Function.HEALING
	heal_table.recipe = {"WOOD": 8, "STONE": 5}
	heal_table.blocks_movement = true
	heal_table.color = Color(1.0, 0.4, 0.5)
	heal_table.sort_order = 60
	register_structure(heal_table)
	
	# PC Terminal
	var pc := StructureData.new()
	pc.id = "PC_TERMINAL"
	pc.display_name = "PC Terminal"
	pc.description = "Access your Pokemon storage."
	pc.category = StructureData.Category.POKEMON
	pc.function = StructureData.Function.PC_ACCESS
	pc.recipe = {"WOOD": 5, "STONE": 8}
	pc.blocks_movement = true
	pc.color = Color(0.3, 0.5, 0.8)
	pc.sort_order = 61
	register_structure(pc)
	
	# Breeding Den
	var breeding := StructureData.new()
	breeding.id = "BREEDING_DEN"
	breeding.display_name = "Breeding Den"
	breeding.description = "A place for Pokemon to breed."
	breeding.category = StructureData.Category.POKEMON
	breeding.function = StructureData.Function.BREEDING
	breeding.width = 2
	breeding.height = 2
	breeding.recipe = {"WOOD": 15, "FIBER": 10}
	breeding.blocks_movement = true
	breeding.color = Color(0.9, 0.7, 0.8)
	breeding.sort_order = 62
	register_structure(breeding)
	
	# Berry Planter
	var planter := StructureData.new()
	planter.id = "BERRY_PLANTER"
	planter.display_name = "Berry Planter"
	planter.description = "Grow berries over time."
	planter.category = StructureData.Category.FARMING
	planter.function = StructureData.Function.NONE
	planter.recipe = {"WOOD": 4, "STONE": 2}
	planter.blocks_movement = true
	planter.color = Color(0.4, 0.6, 0.3)
	planter.sort_order = 70
	register_structure(planter)
