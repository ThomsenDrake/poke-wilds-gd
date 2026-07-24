extends Node

# Campfire crafting scenario (Phase 2 crafting slice; spec:
# docs/product-specs/camping-crafting-survival.md). Proves the craft loop end to
# end on a placed lit campfire: every refusal is traced with a reason
# (no_station with no station faced; missing with the exact missing list;
# wrong_station for the kiln-gated Great Ball — faithful split, never flattened),
# poke_ball / soft_bedding / old_rod craft with exact all-or-nothing bag deltas
# and item_crafted payloads, craftable_at_station("campfire") lists exactly the
# five campfire recipes, can_afford("bed") flips true once soft_bedding exists,
# and crafted counts survive a save round-trip. Deterministic: seed pinned, bag
# granted directly (the interim battle-drop source is proven by the material
# drops audit + the drop_witness_clean invariant asserted below), dispatcher save guard.

const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")

const SEED := 2026072302
const CAMPFIRE_MENU := ["good_rod", "old_rod", "poke_ball", "soft_bedding", "super_rod"]
# The app layer may not import domain (check_architecture): the station literal
# is pinned here (mirrors recipes.gd STATION_CAMPFIRE); a drift there turns the
# item_crafted station asserts + the menu listing red.
const STATION := "campfire"

var _ctx: Dictionary = {}
var _runner = SmokeScenarioRunner.new()
var _failures: Array = []
var _refused := 0
var _crafted := 0


func run(ctx: Dictionary) -> void:
	_ctx = ctx
	await get_tree().create_timer(0.2).timeout
	var runtime = _runtime()
	runtime.seed_for_smoke(SEED)
	# Witness invariant (material_drops.gd): the battle-drop source this scenario
	# funds from must never yield log / hard_stone — the build-loop witness breach.
	if not runtime.crafting_runtime.drop_witness_clean():
		_failures.append("witness: drop table yields log/hard_stone (region-seal escape breach)")
	var saved_chance: float = _player().encounter_chance
	_player().encounter_chance = 0.0
	var party_before: Array = _runner.swap_party(runtime, ["MACHOP"]) # FIGHTING -> Build-capable
	_grant_materials()
	var fire_tile := _find_open_tile(_player().tile_position)
	if fire_tile == Vector2i.ZERO:
		_failures.append("site: no open tile for the campfire within 8 rings")
	var placed: Dictionary = runtime.build_runtime.try_place(fire_tile, "campfire", {}) if fire_tile != Vector2i.ZERO else {"ok": false, "reason": "no_site"}
	if not bool(placed.get("ok", false)):
		_failures.append("campfire: placement refused (%s)" % str(placed.get("reason", "")))
	else:
		_check_refusals()
		_check_crafts()
	var save_ok := _check_save_roundtrip()
	if _failures.is_empty():
		runtime.emit_trace("craft_flow_passed", "SmokeScenarios", {"refused": _refused,
			"crafted": _crafted, "station_count": runtime.crafting_runtime.craftable_at_station(STATION).size(), "save_ok": save_ok})
	else:
		runtime.emit_trace("craft_flow_failed", "SmokeScenarios", {"failures": _failures})
		runtime.warn("CraftFlowScenario", "Craft flow failed: %s." % "; ".join(PackedStringArray(_failures)), {})
	_runner.restore_party(runtime, party_before)
	_player().encounter_chance = saved_chance


# The three refusals, each traced with its reason and never consuming anything.
func _check_refusals() -> void:
	if not _failures.is_empty():
		return
	var runtime = _runtime()
	var cursor := _runner.trace_log_line_count()
	# (1) No station faced: the empty station id is the "nowhere" craft.
	var no_station: Dictionary = runtime.crafting_runtime.craft("poke_ball", "")
	if bool(no_station.get("ok", true)) or str(no_station.get("reason", "")) != "no_station":
		_failures.append("refuse-no_station: got %s" % str(no_station))
	elif not _runner.trace_log_has_since("craft_refused", cursor, {"output_id": "poke_ball", "reason": "no_station"}):
		_failures.append("refuse-no_station: no craft_refused trace")
	else:
		_refused += 1
	if not _failures.is_empty():
		return
	# (2) Missing ingredients: good_rod needs an old_rod + 2 metal coats, bag has neither.
	cursor = _runner.trace_log_line_count()
	var bag_before: Dictionary = runtime.session.bag.duplicate(true)
	var missing: Dictionary = runtime.crafting_runtime.craft("good_rod", STATION)
	if bool(missing.get("ok", true)) or str(missing.get("reason", "")) != "missing":
		_failures.append("refuse-missing: got %s" % str(missing))
	elif (missing.get("missing", {}) as Dictionary) != {"old_rod": 1, "metal_coat": 2}:
		_failures.append("refuse-missing: missing list %s != {old_rod:1, metal_coat:2}" % str(missing.get("missing", {})))
	elif runtime.session.bag != bag_before:
		_failures.append("refuse-missing: a refusal consumed ingredients")
	elif not _runner.trace_log_has_since("craft_refused", cursor, {"output_id": "good_rod", "reason": "missing"}):
		_failures.append("refuse-missing: no craft_refused trace")
	else:
		_refused += 1
	if not _failures.is_empty():
		return
	# (3) Wrong station: Great Ball is a KILN recipe (faithful split), refused at a campfire.
	cursor = _runner.trace_log_line_count()
	var wrong: Dictionary = runtime.crafting_runtime.craft("great_ball", STATION)
	if bool(wrong.get("ok", true)) or str(wrong.get("reason", "")) != "wrong_station":
		_failures.append("refuse-wrong_station: got %s" % str(wrong))
	elif not str(wrong.get("message", "")).contains("kiln"):
		_failures.append("refuse-wrong_station: message '%s' does not name the kiln" % str(wrong.get("message", "")))
	elif not _runner.trace_log_has_since("craft_refused", cursor, {"output_id": "great_ball", "reason": "wrong_station"}):
		_failures.append("refuse-wrong_station: no craft_refused trace")
	else:
		_refused += 1


# Three crafts at the campfire with exact all-or-nothing bag deltas; soft_bedding
# unlocks the bed (can_afford flips true).
func _check_crafts() -> void:
	if not _failures.is_empty():
		return
	_craft_one("poke_ball", {"magnet": 1, "hard_shell": 1})
	if not _failures.is_empty():
		return
	_craft_one("soft_bedding", {"soft_feather": 3, "silky_thread": 3})
	if not _failures.is_empty():
		return
	var biome = _world().get_tile_biome(_player().tile_position)
	if not _runtime().build_runtime.can_afford("bed", biome):
		_failures.append("craft: can_afford(bed) is false after crafting soft_bedding")
	_craft_one("old_rod", {"log": 1, "silky_thread": 1})
	if not _failures.is_empty():
		return
	# The campfire menu lists EXACTLY the five campfire recipes (Great Ball never appears).
	var menu: Array = _runtime().crafting_runtime.craftable_at_station(STATION)
	if menu != CAMPFIRE_MENU:
		_failures.append("craft: campfire menu %s != %s" % [str(menu), str(CAMPFIRE_MENU)])


# One craft: asserts ok, the exact consumption of every ingredient, the +1 grant,
# and the item_crafted payload (ingredients ride the trace verbatim).
func _craft_one(output_id: String, ingredients: Dictionary) -> void:
	var runtime = _runtime()
	var before := {}
	for item_id in ingredients.keys():
		before[item_id] = runtime.get_item_count(str(item_id))
	var owned_before: int = runtime.get_item_count(output_id)
	var cursor := _runner.trace_log_line_count()
	var result: Dictionary = runtime.crafting_runtime.craft(output_id, STATION)
	if not bool(result.get("ok", false)):
		_failures.append("craft-%s: refused (%s)" % [output_id, str(result.get("reason", ""))])
		return
	for item_id in ingredients.keys():
		if runtime.get_item_count(str(item_id)) != int(before[item_id]) - int(ingredients[item_id]):
			_failures.append("craft-%s: did not consume exactly %s of %s" % [output_id, str(ingredients[item_id]), str(item_id)])
	if runtime.get_item_count(output_id) != owned_before + 1:
		_failures.append("craft-%s: bag did not gain exactly one output" % output_id)
	elif not _runner.trace_log_has_since("item_crafted", cursor, {"output_id": output_id, "station": STATION, "ingredients": ingredients}):
		_failures.append("craft-%s: no item_crafted trace with the exact payload" % output_id)
	else:
		_crafted += 1


# Crafted counts ride the bag key and survive the save round-trip unchanged.
func _check_save_roundtrip() -> bool:
	if not _failures.is_empty():
		return false
	var runtime = _runtime()
	var counts_before := {"poke_ball": runtime.get_item_count("poke_ball"),
		"soft_bedding": runtime.get_item_count("soft_bedding"), "old_rod": runtime.get_item_count("old_rod")}
	_runner.save_and_reload(_world(), runtime)
	for item_id in counts_before.keys():
		if runtime.get_item_count(str(item_id)) != int(counts_before[item_id]):
			_failures.append("save: %s count %d did not survive the round-trip" % [str(item_id), int(counts_before[item_id])])
	return _failures.is_empty()


# Exact grant the refusal/craft math reads (placement_flow's grant style): DRAIN
# the ids the exact deltas + refusal-absence checks read first, so leftover bag
# state (interim material drops, playtest accumulation) cannot skew the math,
# then fund the three crafts + the campfire cost (4 log + 2 dry_soil) + the bed's
# 4-log headroom the can_afford(bed) flip needs before old_rod spends a log.
func _grant_materials() -> void:
	for item_id in ["magnet", "hard_shell", "silky_thread", "soft_feather", "log", "dry_soil", "old_rod", "metal_coat", "soft_bedding"]:
		_runtime().session.remove_item(item_id, _runtime().get_item_count(item_id))
	for entry in [["magnet", 2], ["hard_shell", 2], ["silky_thread", 4], ["soft_feather", 3], ["log", 9], ["dry_soil", 2]]:
		_runtime().session.add_item(str(entry[0]), int(entry[1]))


func _find_open_tile(center: Vector2i) -> Vector2i:
	for ring in range(1, 9):
		for tile in _runner.ring_around(center, ring):
			var logic: Dictionary = _world().get_tile_logic(tile)
			if bool(logic.get("walkable", false)) and str(logic.get("prop_path", "")).is_empty() \
				and str(logic.get("structure_id", "")).is_empty():
				return tile
	return Vector2i.ZERO


func _world() -> Node: return _ctx["world"]
func _player() -> Node: return _ctx["player"]
func _runtime() -> Node: return _ctx["runtime"]
