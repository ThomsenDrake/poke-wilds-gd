class_name Inventory
extends RefCounted
## Inventory - Player's item storage system
## Manages items, quantities, and bag pockets

# Item storage: Dictionary of item_id -> quantity
var _items: Dictionary = {}  # String -> int

# Maximum stack size per item type
const MAX_STACK_SIZE := 999


## Add items to inventory
func add_item(item_id: String, quantity: int = 1) -> int:
	"""Add items to inventory. Returns actual amount added."""
	var upper_id := item_id.to_upper()
	
	if not ItemDatabase.has_item(upper_id):
		push_warning("Cannot add unknown item: ", item_id)
		return 0
	
	var current: int = _items.get(upper_id, 0)
	var space: int = MAX_STACK_SIZE - current
	var to_add := mini(quantity, space)
	
	if to_add > 0:
		_items[upper_id] = current + to_add
	
	return to_add


## Remove items from inventory
func remove_item(item_id: String, quantity: int = 1) -> bool:
	"""Remove items from inventory. Returns true if successful."""
	var upper_id := item_id.to_upper()
	
	var current: int = _items.get(upper_id, 0)
	if current < quantity:
		return false
	
	var new_count: int = current - quantity
	if new_count <= 0:
		_items.erase(upper_id)
	else:
		_items[upper_id] = new_count
	
	return true


## Get quantity of an item
func get_item_count(item_id: String) -> int:
	return _items.get(item_id.to_upper(), 0)


## Check if player has at least a certain quantity
func has_item(item_id: String, quantity: int = 1) -> bool:
	return get_item_count(item_id) >= quantity


## Get all items (returns array of {item_id, quantity})
func get_all_items() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for item_id in _items:
		result.append({"item_id": item_id, "quantity": _items[item_id]})
	return result


## Get items by category
func get_items_by_category(category: ItemData.Category) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	
	for item_id in _items:
		var item := ItemDatabase.get_item(item_id)
		if item and item.category == category:
			result.append({
				"item_id": item_id,
				"item": item,
				"quantity": _items[item_id]
			})
	
	# Sort by sort_order
	result.sort_custom(func(a, b): return a.item.sort_order < b.item.sort_order)
	
	return result


## Get all Pokeballs in inventory
func get_pokeballs() -> Array[Dictionary]:
	return get_items_by_category(ItemData.Category.POKEBALL)


## Get all medicine items
func get_medicine() -> Array[Dictionary]:
	return get_items_by_category(ItemData.Category.MEDICINE)


## Get total number of unique items
func get_unique_item_count() -> int:
	return _items.size()


## Get total number of all items
func get_total_item_count() -> int:
	var total := 0
	for count in _items.values():
		total += count
	return total


## Check if inventory is empty
func is_empty() -> bool:
	return _items.is_empty()


## Clear all items
func clear() -> void:
	_items.clear()


## Use an item on a Pokemon
func use_item_on_pokemon(item_id: String, pokemon: Pokemon, in_battle: bool = false) -> Dictionary:
	"""Use an item on a Pokemon. Returns result dictionary."""
	var upper_id := item_id.to_upper()
	
	if not has_item(upper_id):
		return {"success": false, "message": "You don't have that item!"}
	
	var item := ItemDatabase.get_item(upper_id)
	if item == null:
		return {"success": false, "message": "Unknown item!"}
	
	if not item.can_use_on_pokemon(pokemon, in_battle):
		return {"success": false, "message": "It won't have any effect."}
	
	var result := item.apply_to_pokemon(pokemon)
	
	# Consume item if used successfully
	if result.success and result.get("consumed", true):
		remove_item(upper_id)
	
	return result


## Serialize for saving
func to_dict() -> Dictionary:
	return _items.duplicate()


## Load from save data
func from_dict(data: Dictionary) -> void:
	_items.clear()
	for item_id in data:
		if data[item_id] is int:
			_items[item_id.to_upper()] = data[item_id]


## Give starter items to player
func give_starter_items() -> void:
	"""Give player starting items for a new game"""
	add_item("POKE_BALL", 10)
	add_item("POTION", 5)
