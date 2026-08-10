extends RefCounted

# Shared battle-scenario fixtures (the smoke_tap.gd single-home precedent):
# helpers the scripted battle/capture scenarios pin identically. Extracted from
# the three verbatim copies of _guaranteed_capture_mon (battle_end_input_scenario,
# wild_battle_scenario, storage_flow_party_checks) so the capture-certainty pin
# lives in ONE place.


# 1 HP + asleep + catch_rate >= 192 pins capture probability at 1.0 (deterministic).
# Returns the first qualifying catalog species instance so shaped, or {} when the
# catalog holds no species at that catch rate (the callers fail red on empty).
static func guaranteed_capture_mon(runtime) -> Dictionary:
	for entry in runtime.catalog.species.values():
		if entry is Dictionary and int((entry as Dictionary).get("catch_rate", 0)) >= 192:
			var mon: Dictionary = runtime.pokemon_rules.create_pokemon_instance(entry, 3, Callable(runtime.catalog, "get_move"))
			if mon.is_empty():
				continue
			mon["max_hp"] = 2
			mon["current_hp"] = 1
			mon["status"] = "SLP"
			return mon
	return {}
