extends Node
## ItemDatabase - Central repository for item definitions
## Loads, caches, and provides access to all ItemData resources

signal database_loaded()
signal item_loaded(item_id: String)

# All loaded items indexed by ID
var _items: Dictionary = {}  # String -> ItemData

# Items by category for quick filtering
var _by_category: Dictionary = {}  # ItemData.Category -> Array[ItemData]

# Loading state
var _is_loaded: bool = false


func _ready() -> void:
	# Initialize category arrays
	for cat in ItemData.Category.values():
		_by_category[cat] = []
	
	# Register built-in items
	_register_pokeballs()
	_register_medicine()
	_register_battle_items()
	_register_materials()
	_register_key_items()
	
	_is_loaded = true
	database_loaded.emit()
	print("ItemDatabase initialized with ", _items.size(), " items")


## Check if database is ready
func is_loaded() -> bool:
	return _is_loaded


## Get an item by ID
func get_item(item_id: String) -> ItemData:
	var upper_id := item_id.to_upper()
	if _items.has(upper_id):
		return _items[upper_id]
	return null


## Check if an item exists
func has_item(item_id: String) -> bool:
	return _items.has(item_id.to_upper())


## Get all items in a category
func get_items_by_category(category: ItemData.Category) -> Array:
	if _by_category.has(category):
		return _by_category[category]
	return []


## Get all item IDs
func get_all_item_ids() -> Array[String]:
	var ids: Array[String] = []
	ids.assign(_items.keys())
	return ids


## Get item count
func get_item_count() -> int:
	return _items.size()


## Register an item in the database
func register_item(item: ItemData) -> void:
	var upper_id := item.id.to_upper()
	_items[upper_id] = item
	
	if not _by_category.has(item.category):
		_by_category[item.category] = []
	_by_category[item.category].append(item)
	
	item_loaded.emit(upper_id)


## Get all Pokeball items
func get_pokeballs() -> Array:
	return get_items_by_category(ItemData.Category.POKEBALL)


## Get catch rate modifier for a ball type
func get_ball_modifier(ball_id: String) -> float:
	var item := get_item(ball_id)
	if item and item.category == ItemData.Category.POKEBALL:
		return item.catch_rate_modifier
	return 1.0


# ============ Built-in Item Registration ============

func _register_pokeballs() -> void:
	var poke_ball := ItemData.new()
	poke_ball.id = "POKE_BALL"
	poke_ball.display_name = "Poke Ball"
	poke_ball.description = "A device for catching wild Pokemon."
	poke_ball.category = ItemData.Category.POKEBALL
	poke_ball.effect = ItemData.Effect.CATCH_POKEMON
	poke_ball.catch_rate_modifier = 1.0
	poke_ball.buy_price = 200
	poke_ball.sell_price = 100
	poke_ball.usable_outside_battle = false
	poke_ball.sort_order = 1
	register_item(poke_ball)
	
	var great_ball := ItemData.new()
	great_ball.id = "GREAT_BALL"
	great_ball.display_name = "Great Ball"
	great_ball.description = "A good, high-performance Ball."
	great_ball.category = ItemData.Category.POKEBALL
	great_ball.effect = ItemData.Effect.CATCH_POKEMON
	great_ball.catch_rate_modifier = 1.5
	great_ball.buy_price = 600
	great_ball.sell_price = 300
	great_ball.usable_outside_battle = false
	great_ball.sort_order = 2
	register_item(great_ball)
	
	var ultra_ball := ItemData.new()
	ultra_ball.id = "ULTRA_BALL"
	ultra_ball.display_name = "Ultra Ball"
	ultra_ball.description = "An ultra-performance Ball."
	ultra_ball.category = ItemData.Category.POKEBALL
	ultra_ball.effect = ItemData.Effect.CATCH_POKEMON
	ultra_ball.catch_rate_modifier = 2.0
	ultra_ball.buy_price = 1200
	ultra_ball.sell_price = 600
	ultra_ball.usable_outside_battle = false
	ultra_ball.sort_order = 3
	register_item(ultra_ball)
	
	var master_ball := ItemData.new()
	master_ball.id = "MASTER_BALL"
	master_ball.display_name = "Master Ball"
	master_ball.description = "The best Ball. It never fails."
	master_ball.category = ItemData.Category.POKEBALL
	master_ball.effect = ItemData.Effect.CATCH_POKEMON
	master_ball.catch_rate_modifier = 255.0
	master_ball.buy_price = 0  # Cannot buy
	master_ball.sell_price = 0  # Cannot sell
	master_ball.usable_outside_battle = false
	master_ball.sort_order = 4
	register_item(master_ball)


func _register_medicine() -> void:
	# Potions
	var potion := ItemData.new()
	potion.id = "POTION"
	potion.display_name = "Potion"
	potion.description = "Restores 20 HP."
	potion.category = ItemData.Category.MEDICINE
	potion.effect = ItemData.Effect.HEAL_HP
	potion.effect_value = 20
	potion.buy_price = 300
	potion.sell_price = 150
	potion.sort_order = 10
	register_item(potion)
	
	var super_potion := ItemData.new()
	super_potion.id = "SUPER_POTION"
	super_potion.display_name = "Super Potion"
	super_potion.description = "Restores 50 HP."
	super_potion.category = ItemData.Category.MEDICINE
	super_potion.effect = ItemData.Effect.HEAL_HP
	super_potion.effect_value = 50
	super_potion.buy_price = 700
	super_potion.sell_price = 350
	super_potion.sort_order = 11
	register_item(super_potion)
	
	var hyper_potion := ItemData.new()
	hyper_potion.id = "HYPER_POTION"
	hyper_potion.display_name = "Hyper Potion"
	hyper_potion.description = "Restores 200 HP."
	hyper_potion.category = ItemData.Category.MEDICINE
	hyper_potion.effect = ItemData.Effect.HEAL_HP
	hyper_potion.effect_value = 200
	hyper_potion.buy_price = 1200
	hyper_potion.sell_price = 600
	hyper_potion.sort_order = 12
	register_item(hyper_potion)
	
	var max_potion := ItemData.new()
	max_potion.id = "MAX_POTION"
	max_potion.display_name = "Max Potion"
	max_potion.description = "Fully restores HP."
	max_potion.category = ItemData.Category.MEDICINE
	max_potion.effect = ItemData.Effect.HEAL_HP
	max_potion.effect_value = 9999
	max_potion.buy_price = 2500
	max_potion.sell_price = 1250
	max_potion.sort_order = 13
	register_item(max_potion)
	
	# Status healers
	var antidote := ItemData.new()
	antidote.id = "ANTIDOTE"
	antidote.display_name = "Antidote"
	antidote.description = "Cures poison."
	antidote.category = ItemData.Category.MEDICINE
	antidote.effect = ItemData.Effect.HEAL_STATUS
	antidote.effect_param = "POISON"
	antidote.buy_price = 100
	antidote.sell_price = 50
	antidote.sort_order = 20
	register_item(antidote)
	
	var burn_heal := ItemData.new()
	burn_heal.id = "BURN_HEAL"
	burn_heal.display_name = "Burn Heal"
	burn_heal.description = "Cures a burn."
	burn_heal.category = ItemData.Category.MEDICINE
	burn_heal.effect = ItemData.Effect.HEAL_STATUS
	burn_heal.effect_param = "BURN"
	burn_heal.buy_price = 250
	burn_heal.sell_price = 125
	burn_heal.sort_order = 21
	register_item(burn_heal)
	
	var paralyze_heal := ItemData.new()
	paralyze_heal.id = "PARALYZE_HEAL"
	paralyze_heal.display_name = "Paralyze Heal"
	paralyze_heal.description = "Cures paralysis."
	paralyze_heal.category = ItemData.Category.MEDICINE
	paralyze_heal.effect = ItemData.Effect.HEAL_STATUS
	paralyze_heal.effect_param = "PARALYSIS"
	paralyze_heal.buy_price = 200
	paralyze_heal.sell_price = 100
	paralyze_heal.sort_order = 22
	register_item(paralyze_heal)
	
	var awakening := ItemData.new()
	awakening.id = "AWAKENING"
	awakening.display_name = "Awakening"
	awakening.description = "Wakes a sleeping Pokemon."
	awakening.category = ItemData.Category.MEDICINE
	awakening.effect = ItemData.Effect.HEAL_STATUS
	awakening.effect_param = "SLEEP"
	awakening.buy_price = 250
	awakening.sell_price = 125
	awakening.sort_order = 23
	register_item(awakening)
	
	var ice_heal := ItemData.new()
	ice_heal.id = "ICE_HEAL"
	ice_heal.display_name = "Ice Heal"
	ice_heal.description = "Defrosts a frozen Pokemon."
	ice_heal.category = ItemData.Category.MEDICINE
	ice_heal.effect = ItemData.Effect.HEAL_STATUS
	ice_heal.effect_param = "FREEZE"
	ice_heal.buy_price = 250
	ice_heal.sell_price = 125
	ice_heal.sort_order = 24
	register_item(ice_heal)
	
	var full_heal := ItemData.new()
	full_heal.id = "FULL_HEAL"
	full_heal.display_name = "Full Heal"
	full_heal.description = "Cures all status problems."
	full_heal.category = ItemData.Category.MEDICINE
	full_heal.effect = ItemData.Effect.HEAL_STATUS
	full_heal.buy_price = 600
	full_heal.sell_price = 300
	full_heal.sort_order = 25
	register_item(full_heal)
	
	# Revives
	var revive := ItemData.new()
	revive.id = "REVIVE"
	revive.display_name = "Revive"
	revive.description = "Revives a fainted Pokemon to half HP."
	revive.category = ItemData.Category.MEDICINE
	revive.effect = ItemData.Effect.REVIVE
	revive.buy_price = 1500
	revive.sell_price = 750
	revive.sort_order = 30
	register_item(revive)
	
	var max_revive := ItemData.new()
	max_revive.id = "MAX_REVIVE"
	max_revive.display_name = "Max Revive"
	max_revive.description = "Revives a fainted Pokemon to full HP."
	max_revive.category = ItemData.Category.MEDICINE
	max_revive.effect = ItemData.Effect.MAX_REVIVE
	max_revive.buy_price = 4000
	max_revive.sell_price = 2000
	max_revive.sort_order = 31
	register_item(max_revive)
	
	# Full Restore
	var full_restore := ItemData.new()
	full_restore.id = "FULL_RESTORE"
	full_restore.display_name = "Full Restore"
	full_restore.description = "Fully restores HP and cures all status."
	full_restore.category = ItemData.Category.MEDICINE
	full_restore.effect = ItemData.Effect.HEAL_ALL
	full_restore.effect_value = 9999
	full_restore.buy_price = 3000
	full_restore.sell_price = 1500
	full_restore.sort_order = 14
	register_item(full_restore)
	
	# PP restore
	var ether := ItemData.new()
	ether.id = "ETHER"
	ether.display_name = "Ether"
	ether.description = "Restores 10 PP of one move."
	ether.category = ItemData.Category.MEDICINE
	ether.effect = ItemData.Effect.HEAL_PP
	ether.effect_value = 10
	ether.buy_price = 0  # Cannot buy
	ether.sell_price = 600
	ether.sort_order = 40
	register_item(ether)
	
	var elixir := ItemData.new()
	elixir.id = "ELIXIR"
	elixir.display_name = "Elixir"
	elixir.description = "Restores 10 PP of all moves."
	elixir.category = ItemData.Category.MEDICINE
	elixir.effect = ItemData.Effect.HEAL_PP
	elixir.effect_value = 10
	elixir.buy_price = 0
	elixir.sell_price = 1500
	elixir.sort_order = 41
	register_item(elixir)


func _register_battle_items() -> void:
	var x_attack := ItemData.new()
	x_attack.id = "X_ATTACK"
	x_attack.display_name = "X Attack"
	x_attack.description = "Raises Attack in battle."
	x_attack.category = ItemData.Category.BATTLE
	x_attack.effect = ItemData.Effect.BOOST_ATTACK
	x_attack.effect_value = 1
	x_attack.usable_outside_battle = false
	x_attack.buy_price = 500
	x_attack.sell_price = 250
	x_attack.sort_order = 50
	register_item(x_attack)
	
	var x_defense := ItemData.new()
	x_defense.id = "X_DEFENSE"
	x_defense.display_name = "X Defense"
	x_defense.description = "Raises Defense in battle."
	x_defense.category = ItemData.Category.BATTLE
	x_defense.effect = ItemData.Effect.BOOST_DEFENSE
	x_defense.effect_value = 1
	x_defense.usable_outside_battle = false
	x_defense.buy_price = 550
	x_defense.sell_price = 275
	x_defense.sort_order = 51
	register_item(x_defense)
	
	var x_speed := ItemData.new()
	x_speed.id = "X_SPEED"
	x_speed.display_name = "X Speed"
	x_speed.description = "Raises Speed in battle."
	x_speed.category = ItemData.Category.BATTLE
	x_speed.effect = ItemData.Effect.BOOST_SPEED
	x_speed.effect_value = 1
	x_speed.usable_outside_battle = false
	x_speed.buy_price = 350
	x_speed.sell_price = 175
	x_speed.sort_order = 52
	register_item(x_speed)
	
	var x_accuracy := ItemData.new()
	x_accuracy.id = "X_ACCURACY"
	x_accuracy.display_name = "X Accuracy"
	x_accuracy.description = "Raises Accuracy in battle."
	x_accuracy.category = ItemData.Category.BATTLE
	x_accuracy.effect = ItemData.Effect.BOOST_ACCURACY
	x_accuracy.effect_value = 1
	x_accuracy.usable_outside_battle = false
	x_accuracy.buy_price = 950
	x_accuracy.sell_price = 475
	x_accuracy.sort_order = 53
	register_item(x_accuracy)


func _register_materials() -> void:
	# PokeWilds crafting materials
	var wood := ItemData.new()
	wood.id = "WOOD"
	wood.display_name = "Wood"
	wood.description = "A piece of wood. Used for building."
	wood.category = ItemData.Category.MATERIAL
	wood.effect = ItemData.Effect.CRAFTING_MATERIAL
	wood.usable_in_battle = false
	wood.usable_outside_battle = false
	wood.sell_price = 10
	wood.sort_order = 100
	register_item(wood)
	
	var stone := ItemData.new()
	stone.id = "STONE"
	stone.display_name = "Stone"
	stone.description = "A sturdy stone. Used for building."
	stone.category = ItemData.Category.MATERIAL
	stone.effect = ItemData.Effect.CRAFTING_MATERIAL
	stone.usable_in_battle = false
	stone.usable_outside_battle = false
	stone.sell_price = 15
	stone.sort_order = 101
	register_item(stone)
	
	var apricorn_red := ItemData.new()
	apricorn_red.id = "RED_APRICORN"
	apricorn_red.display_name = "Red Apricorn"
	apricorn_red.description = "A red Apricorn. Can be made into a Ball."
	apricorn_red.category = ItemData.Category.MATERIAL
	apricorn_red.effect = ItemData.Effect.CRAFTING_MATERIAL
	apricorn_red.usable_in_battle = false
	apricorn_red.usable_outside_battle = false
	apricorn_red.sell_price = 50
	apricorn_red.sort_order = 110
	register_item(apricorn_red)
	
	var apricorn_blue := ItemData.new()
	apricorn_blue.id = "BLUE_APRICORN"
	apricorn_blue.display_name = "Blue Apricorn"
	apricorn_blue.description = "A blue Apricorn. Can be made into a Ball."
	apricorn_blue.category = ItemData.Category.MATERIAL
	apricorn_blue.effect = ItemData.Effect.CRAFTING_MATERIAL
	apricorn_blue.usable_in_battle = false
	apricorn_blue.usable_outside_battle = false
	apricorn_blue.sell_price = 50
	apricorn_blue.sort_order = 111
	register_item(apricorn_blue)
	
	# Plant Fiber
	var fiber := ItemData.new()
	fiber.id = "FIBER"
	fiber.display_name = "Plant Fiber"
	fiber.description = "Fibrous plant material. Used for crafting."
	fiber.category = ItemData.Category.MATERIAL
	fiber.effect = ItemData.Effect.CRAFTING_MATERIAL
	fiber.usable_in_battle = false
	fiber.usable_outside_battle = false
	fiber.sell_price = 5
	fiber.sort_order = 102
	register_item(fiber)
	
	# Iron Ore
	var iron := ItemData.new()
	iron.id = "IRON_ORE"
	iron.display_name = "Iron Ore"
	iron.description = "Raw iron ore. Can be smelted."
	iron.category = ItemData.Category.MATERIAL
	iron.effect = ItemData.Effect.CRAFTING_MATERIAL
	iron.usable_in_battle = false
	iron.usable_outside_battle = false
	iron.sell_price = 25
	iron.sort_order = 103
	register_item(iron)
	
	# Iron Ingot
	var iron_ingot := ItemData.new()
	iron_ingot.id = "IRON_INGOT"
	iron_ingot.display_name = "Iron Ingot"
	iron_ingot.description = "Smelted iron. Used for crafting tools."
	iron_ingot.category = ItemData.Category.MATERIAL
	iron_ingot.effect = ItemData.Effect.CRAFTING_MATERIAL
	iron_ingot.usable_in_battle = false
	iron_ingot.usable_outside_battle = false
	iron_ingot.sell_price = 50
	iron_ingot.sort_order = 104
	register_item(iron_ingot)
	
	# Clay
	var clay := ItemData.new()
	clay.id = "CLAY"
	clay.display_name = "Clay"
	clay.description = "Soft clay. Can be shaped and fired."
	clay.category = ItemData.Category.MATERIAL
	clay.effect = ItemData.Effect.CRAFTING_MATERIAL
	clay.usable_in_battle = false
	clay.usable_outside_battle = false
	clay.sell_price = 8
	clay.sort_order = 105
	register_item(clay)


func _register_key_items() -> void:
	var old_rod := ItemData.new()
	old_rod.id = "OLD_ROD"
	old_rod.display_name = "Old Rod"
	old_rod.description = "Use by water to fish for Pokemon."
	old_rod.category = ItemData.Category.KEY_ITEM
	old_rod.consumable = false
	old_rod.usable_in_battle = false
	old_rod.sort_order = 200
	register_item(old_rod)
	
	var good_rod := ItemData.new()
	good_rod.id = "GOOD_ROD"
	good_rod.display_name = "Good Rod"
	good_rod.description = "A better fishing rod."
	good_rod.category = ItemData.Category.KEY_ITEM
	good_rod.consumable = false
	good_rod.usable_in_battle = false
	good_rod.sort_order = 201
	register_item(good_rod)
	
	var super_rod := ItemData.new()
	super_rod.id = "SUPER_ROD"
	super_rod.display_name = "Super Rod"
	super_rod.description = "The best fishing rod."
	super_rod.category = ItemData.Category.KEY_ITEM
	super_rod.consumable = false
	super_rod.usable_in_battle = false
	super_rod.sort_order = 202
	register_item(super_rod)
	
	var axe := ItemData.new()
	axe.id = "AXE"
	axe.display_name = "Axe"
	axe.description = "Used to cut down trees for wood."
	axe.category = ItemData.Category.KEY_ITEM
	axe.consumable = false
	axe.usable_in_battle = false
	axe.sort_order = 210
	register_item(axe)
	
	var pickaxe := ItemData.new()
	pickaxe.id = "PICKAXE"
	pickaxe.display_name = "Pickaxe"
	pickaxe.description = "Used to mine rocks for stone."
	pickaxe.category = ItemData.Category.KEY_ITEM
	pickaxe.consumable = false
	pickaxe.usable_in_battle = false
	pickaxe.sort_order = 211
	register_item(pickaxe)
