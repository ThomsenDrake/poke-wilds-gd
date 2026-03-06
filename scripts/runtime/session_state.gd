extends RefCounted

var world_seed: int = 1337
var player_tile: Vector2i = Vector2i.ZERO
var party: Array = []
var bag: Dictionary = {}


func reset_for_new_game(new_world_seed: int, starter: Dictionary) -> void:
	world_seed = new_world_seed
	player_tile = Vector2i.ZERO
	party.clear()
	bag = {
		"pokeball": 10,
		"potion": 5
	}
	if not starter.is_empty():
		party.append(starter)


func apply_loaded_state(data: Dictionary, normalized_party: Array) -> void:
	world_seed = int(data.get("world_seed", 1337))
	player_tile = Vector2i(int(data.get("player_x", 0)), int(data.get("player_y", 0)))
	bag = data.get("bag", {"pokeball": 10, "potion": 5})
	party = normalized_party


func to_save_payload() -> Dictionary:
	return {
		"world_seed": world_seed,
		"player_x": player_tile.x,
		"player_y": player_tile.y,
		"party": party,
		"bag": bag
	}


func get_active_party_index() -> int:
	for i in range(party.size()):
		var mon = party[i]
		if int(mon.get("current_hp", 0)) > 0:
			return i
	return -1


func get_next_healthy_party_index(excluding_index: int) -> int:
	for i in range(party.size()):
		if i == excluding_index:
			continue
		var mon = party[i]
		if int(mon.get("current_hp", 0)) > 0:
			return i
	return -1


func get_party_member(index: int) -> Dictionary:
	if index < 0 or index >= party.size():
		return {}
	return party[index]


func set_party_member(index: int, mon: Dictionary) -> void:
	if index < 0 or index >= party.size():
		return
	party[index] = mon


func add_pokemon_to_party(mon: Dictionary) -> bool:
	if party.size() >= 6:
		return false
	party.append(mon)
	return true


func set_party_lead(index: int) -> void:
	if index <= 0 or index >= party.size():
		return
	var selected = party[index]
	party.remove_at(index)
	party.insert(0, selected)


func heal_party_full() -> void:
	for i in range(party.size()):
		var mon = party[i]
		mon["current_hp"] = int(mon.get("max_hp", 1))
		party[i] = mon


func get_item_count(item_id: String) -> int:
	return int(bag.get(item_id, 0))


func consume_item(item_id: String, amount: int = 1) -> bool:
	var current = get_item_count(item_id)
	if current < amount:
		return false
	bag[item_id] = current - amount
	return true


func add_item(item_id: String, amount: int = 1) -> void:
	bag[item_id] = get_item_count(item_id) + amount


func get_party_snapshot() -> Array:
	return party.duplicate(true)


func get_bag_snapshot() -> Dictionary:
	return bag.duplicate(true)
