extends Node

# The Ditto / unbreedable / wrong-group / evolution-stone / save groups of
# breed_flow (the app-budget split, placement_flow precedent; spec: docs/
# product-specs/breeding-shinies-drops-fishing.md). Ditto + a male breed with
# the NON-Ditto parent as the offspring; a genderless pair (MAGNEMITE) and a
# DISJOINT-group pair (EEVEE x ABRA — both basic-recessive, so the habitat
# gate cannot confound the egg-group negative) produce NOTHING; the evolution
# stone (FIRE_STONE -> FLAREON) proves the bag-use seam, is_shiny preserved.

const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")
const Phase5 := preload("res://scripts/runtime/phase5_support.gd")
const Sites := preload("res://scripts/runtime/phase5_sites.gd")

const PAIR_LEVEL := 30
const LAY_STEP_CAP := 6000
const LAY_BATCH := 60
const UNBREEDABLE_WINDOW := 960 # 8 lay cadences (120 steps); a pair would almost surely lay

var _ctx: Dictionary = {}
var _runner = SmokeScenarioRunner.new()
var _failures: Array = []
var _pen_center := Vector2i.ZERO
var _anchor := ""


func setup(ctx: Dictionary, runner: SmokeScenarioRunner, failures: Array, pen_center: Vector2i, anchor: String) -> void:
	_ctx = ctx
	_runner = runner
	_failures = failures
	_pen_center = pen_center
	_anchor = anchor


# Ditto + male EEVEE: the Ditto lays; the offspring is the non-Ditto parent's
# species (EEVEE). The wait rides the SPECIES-TAGGED egg_laid trace.
func run_ditto_case(runtime) -> bool:
	if not _failures.is_empty():
		return false
	var male: Dictionary = Phase5.gendered_instances(runtime, "EEVEE", PAIR_LEVEL, ["male"]).get("male", {})
	if male.is_empty():
		return _ensure(false, "ditto: no male EEVEE within 128 creations")
	var ditto: Dictionary = runtime.pokemon_rules.create_pokemon_instance(runtime.catalog.get_species("DITTO"), PAIR_LEVEL, Callable(runtime.catalog, "get_move"), runtime._rng)
	runtime.session.party = [runtime.session.party[0], runtime.session.party[1], ditto, male]
	_runner.teleport_player(_world(), _player(), runtime, _pen_center)
	for species_id in ["DITTO", "EEVEE"]:
		var result: Dictionary = Phase5.pasture_deposit(runtime, Phase5.party_index_of(runtime, species_id))
		if not bool(result.get("ok", false)):
			return _ensure(false, "ditto: %s deposit refused (%s)" % [species_id, str(result.get("reason", ""))])
	if not Phase5.poke_pasture_happiness(runtime, _anchor, 255):
		return _ensure(false, "ditto: happiness poke found no penned mons")
	var cursor := _runner.trace_log_line_count()
	for _batch in range(LAY_STEP_CAP / LAY_BATCH):
		if _runner.trace_log_has_since("egg_laid", cursor, {"species_id": "EEVEE"}):
			break
		Phase5.pen_tick(runtime, LAY_BATCH)
	var ok := _ensure(_runner.trace_log_has_since("egg_laid", cursor, {"species_id": "EEVEE"}), "ditto: no EEVEE egg_laid trace within %d steps (non-Ditto parent rule)" % LAY_STEP_CAP)
	_empty_pen(runtime, 3) # the single ground egg first, then the pair
	return ok


# Two genderless MAGNEMITE: no Ditto, no genders — the pair never forms, NO egg.
func run_unbreedable_case(runtime) -> bool:
	if not _failures.is_empty():
		return false
	var magnemite: Dictionary = runtime.catalog.get_species("MAGNEMITE")
	var mon_a: Dictionary = runtime.pokemon_rules.create_pokemon_instance(magnemite, PAIR_LEVEL, Callable(runtime.catalog, "get_move"), runtime._rng)
	var mon_b: Dictionary = runtime.pokemon_rules.create_pokemon_instance(magnemite, PAIR_LEVEL, Callable(runtime.catalog, "get_move"), runtime._rng)
	if str(mon_a.get("gender", "")) != "genderless" or str(mon_b.get("gender", "")) != "genderless":
		return _ensure(false, "unbreedable: MAGNEMITE is not genderless in this catalog")
	runtime.session.party = [runtime.session.party[0], runtime.session.party[1], mon_a, mon_b]
	_runner.teleport_player(_world(), _player(), runtime, _pen_center)
	for _i in range(2):
		var result: Dictionary = Phase5.pasture_deposit(runtime, 2)
		if not bool(result.get("ok", false)):
			return _ensure(false, "unbreedable: deposit refused (%s)" % str(result.get("reason", "")))
	var cursor := _runner.trace_log_line_count()
	Phase5.pen_tick(runtime, UNBREEDABLE_WINDOW)
	var ok := _ensure(not _runner.trace_log_has_since("egg_laid", cursor), "unbreedable: a genderless pair produced an egg")
	ok = _ensure(Phase5.pasture_eggs(runtime, _anchor).is_empty(), "unbreedable: a ground egg appeared in the pen") and ok
	_empty_pen(runtime, 2)
	return ok


# Female EEVEE (EGG_FIELD) x male ABRA (EGG_HUMANLIKE): the shared-egg-group
# gate's negative. ABRA is basic-recessive (PSYCHIC needs NO habitat tag), so
# the standard basic pen satisfies BOTH parents — pinned by the live-catalog
# guard below, with happiness poked to 255 — so the ONLY gate left that can
# hold this pair back is the disjoint egg groups: removing that gate produces
# an egg and this case FAILS as intended. Disjointness is asserted off the LIVE
# catalog so a drift fails the check instead of going vacuous.
func run_wrong_group_case(runtime) -> bool:
	if not _failures.is_empty():
		return false
	var female: Dictionary = Phase5.gendered_instances(runtime, "EEVEE", PAIR_LEVEL, ["female"]).get("female", {})
	var male: Dictionary = Phase5.gendered_instances(runtime, "ABRA", PAIR_LEVEL, ["male"]).get("male", {})
	if female.is_empty() or male.is_empty():
		return _ensure(false, "wrong_group: no female EEVEE / male ABRA within 128 creations")
	if not Phase5.egg_groups_disjoint(runtime.catalog.get_species("EEVEE"), runtime.catalog.get_species("ABRA")):
		return _ensure(false, "wrong_group: EEVEE x ABRA egg groups are no longer disjoint (catalog drift)")
	if not Phase5.basic_ground_satisfies(runtime, "EEVEE") or not Phase5.basic_ground_satisfies(runtime, "ABRA"):
		return _ensure(false, "wrong_group: a parent is no longer basic-recessive (habitat would confound the gate)")
	runtime.session.party = [runtime.session.party[0], runtime.session.party[1], female, male]
	_runner.teleport_player(_world(), _player(), runtime, _pen_center)
	for _i in range(2):
		var result: Dictionary = Phase5.pasture_deposit(runtime, 2)
		if not bool(result.get("ok", false)):
			return _ensure(false, "wrong_group: deposit refused (%s)" % str(result.get("reason", "")))
	if not Phase5.poke_pasture_happiness(runtime, _anchor, 255):
		return _ensure(false, "wrong_group: happiness poke found no penned mons")
	var cursor := _runner.trace_log_line_count()
	Phase5.pen_tick(runtime, UNBREEDABLE_WINDOW)
	var ok := _ensure(not _runner.trace_log_has_since("egg_laid", cursor), "wrong_group: a disjoint-group pair produced an egg")
	ok = _ensure(Phase5.pasture_eggs(runtime, _anchor).is_empty(), "wrong_group: a ground egg appeared in the pen") and ok
	_empty_pen(runtime, 2)
	return ok


# FIRE_STONE on a party EEVEE through the bag-use seam (game_runtime exposes use_stone_on_mon):
# evolution_stone_used + FLAREON with the stats recomputed off FLAREON's base stats (level-path
# parity), is_shiny preserved, the stone consumed; then the no-effect contract — a stone on
# MAGIKARP (no ITEM-method evolution) refuses no_effect, consumes nothing, traces nothing.
func run_stone_case(runtime) -> Variant:
	if not _failures.is_empty():
		return false
	if _stone_seam(runtime).is_empty():
		runtime.warn("BreedFlowChecks", "Evolution-stone bag-use seam not wired; stone group skipped.", {"seam": "evolution_stone_used"})
		return "skipped_no_seam"
	var eevee: Dictionary = runtime.pokemon_rules.create_pokemon_instance(runtime.catalog.get_species("EEVEE"), PAIR_LEVEL, Callable(runtime.catalog, "get_move"), runtime._rng)
	var shiny_before := bool(eevee.get("is_shiny", false))
	var eevee_level := int(eevee.get("level", PAIR_LEVEL))
	runtime.session.party = [runtime.session.party[0], runtime.session.party[1], eevee]
	runtime.session.remove_item("fire_stone", runtime.get_item_count("fire_stone"))
	runtime.session.add_item("fire_stone", 1)
	var cursor := _runner.trace_log_line_count()
	var result: Dictionary = _use_stone(runtime, 2)
	if not bool(result.get("ok", false)):
		return _ensure(false, "stone: bag-use refused (%s)" % str(result.get("reason", "")))
	var ok := _ensure(_runner.trace_log_has_since("evolution_stone_used", cursor), "stone: no evolution_stone_used trace")
	var evolved: Dictionary = runtime.session.party[2] if runtime.session.party.size() > 2 else {}
	ok = _ensure(str(evolved.get("species_id", "")) == "FLAREON", "stone: EEVEE became %s, not FLAREON" % str(evolved.get("species_id", ""))) and ok
	ok = _ensure(bool(evolved.get("is_shiny", false)) == shiny_before, "stone: is_shiny did not survive the evolution") and ok
	ok = _ensure(runtime.get_item_count("fire_stone") == 0, "stone: the fire_stone was not consumed") and ok
	var expected: Dictionary = runtime.pokemon_rules.build_stats(runtime.catalog.get_species("FLAREON").get("base_stats", {}), eevee_level)
	ok = _ensure((evolved.get("stats", {}) as Dictionary) == expected, "stone: stats were not recomputed off FLAREON's base stats") and ok
	ok = _ensure(int(evolved.get("max_hp", 0)) == int(expected.get("hp", -1)), "stone: max_hp %d != FLAREON's %d (stats rode the swap)" % [int(evolved.get("max_hp", 0)), int(expected.get("hp", -1))]) and ok
	# No-effect negative: MAGIKARP has no ITEM-method evolution (level 20 -> GYARADOS).
	runtime.session.party.append(runtime.pokemon_rules.create_pokemon_instance(runtime.catalog.get_species("MAGIKARP"), PAIR_LEVEL, Callable(runtime.catalog, "get_move"), runtime._rng))
	runtime.session.add_item("fire_stone", 1)
	var no_cursor := _runner.trace_log_line_count()
	var refused: Dictionary = _use_stone(runtime, runtime.session.party.size() - 1)
	ok = _ensure(str(refused.get("reason", "")) == "no_effect", "stone: a no-effect use returned %s, not no_effect" % str(refused.get("reason", ""))) and ok
	ok = _ensure(runtime.get_item_count("fire_stone") == 1, "stone: a no-effect use consumed the stone") and ok
	return _ensure(not _runner.trace_log_has_since("evolution_stone_used", no_cursor), "stone: a no-effect use emitted evolution_stone_used") and ok


# Save round-trip: a party egg + a penned EEVEE both survive the reload.
func run_save_case(runtime) -> bool:
	if not _failures.is_empty():
		return false
	var get_move := Callable(runtime.catalog, "get_move")
	var eevee_entry: Dictionary = runtime.catalog.get_species("EEVEE")
	var mother: Dictionary = runtime.pokemon_rules.create_pokemon_instance(eevee_entry, PAIR_LEVEL, get_move, runtime._rng)
	var father: Dictionary = runtime.pokemon_rules.create_pokemon_instance(eevee_entry, PAIR_LEVEL, get_move, runtime._rng)
	var pen_mon: Dictionary = runtime.pokemon_rules.create_pokemon_instance(eevee_entry, PAIR_LEVEL, get_move, runtime._rng)
	var Breeding = Phase5.breeding_domain(runtime)
	var egg: Dictionary = Breeding.call("build_egg", mother, father, eevee_entry, get_move, runtime._rng, "save-proof")
	runtime.session.party = [runtime.session.party[0], runtime.session.party[1], egg, pen_mon]
	_runner.teleport_player(_world(), _player(), runtime, _pen_center)
	var deposit: Dictionary = Phase5.pasture_deposit(runtime, 3)
	if not bool(deposit.get("ok", false)):
		return _ensure(false, "save: pen deposit refused (%s)" % str(deposit.get("reason", "")))
	_runner.save_and_reload(_world(), runtime)
	var pastures: Dictionary = runtime.session.pastures if runtime.session.pastures is Dictionary else {}
	var entry: Dictionary = pastures.get(_anchor, {})
	var mons: Array = entry.get("mons", []) if entry is Dictionary else []
	var ok := _ensure(not mons.is_empty() and str((mons[0] as Dictionary).get("species_id", "")) == "EEVEE", "save: the penned EEVEE did not survive the round-trip")
	var party_egg := {}
	for mon in runtime.session.party:
		if mon is Dictionary and bool((mon as Dictionary).get("is_egg", false)):
			party_egg = mon
	if party_egg.is_empty():
		return _ensure(false, "save: the party egg did not survive the round-trip") and ok
	var payload: Dictionary = (party_egg as Dictionary).get("egg", {})
	return _ensure(str(payload.get("species_id", "")) == "EEVEE" and int(payload.get("steps_to_hatch", 0)) > 0, "save: the egg payload was torn by the round-trip") and ok


# --- shared helpers ---

# Face the pen and Z until quiet: ground eggs first, then mons (latest-first).
func _empty_pen(runtime, interacts: int) -> void:
	var spot: Dictionary = Sites.pen_stand_spot(_world(), _pen_center)
	if not spot.is_empty():
		for _i in range(interacts):
			Phase5.pasture_interact(runtime, spot["stand"], spot["faced"])


const STONE_SEAM_METHODS := ["use_item_on_mon", "use_evolution_item", "use_stone_on_mon", "bag_use_item"]

func _stone_seam(runtime) -> String:
	for method in STONE_SEAM_METHODS:
		if runtime.has_method(method):
			return str(method)
	return ""

func _use_stone(runtime, party_index: int) -> Dictionary:
	var seam := _stone_seam(runtime)
	if seam.is_empty():
		return {"ok": false, "reason": "contract: no evolution-stone bag-use seam is wired"}
	var result = runtime.call(seam, "fire_stone", party_index)
	return result if result is Dictionary else {"ok": false, "reason": "contract: %s returned no dict" % seam}


func _ensure(ok: bool, label: String) -> bool:
	if not ok:
		_failures.append(label)
	return ok

func _world() -> Node: return _ctx["world"]
func _player() -> Node: return _ctx["player"]
