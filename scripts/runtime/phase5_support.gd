extends RefCounted

# Runtime adapters + witnesses for the Phase 5 scenarios (breed_flow /
# shiny_odds / habitat_drops / fishing_flow; spec + registry: docs/product-specs/
# breeding-shinies-drops-fishing.md). Site / pen / water / material helpers live
# in phase5_sites.gd (the split keeps both under the runtime budget). Absent or
# drifted surfaces fail LOUD and named (the miss-002 total-exit contract) —
# never a crash, never a silent pass.

const HABITAT_DROPS_PATH := "res://scripts/domain/habitat_drops.gd"
const BREEDING_DOMAIN_PATH := "res://scripts/domain/breeding.gd"
const FISHING_DOMAIN_PATH := "res://scripts/domain/fishing.gd"
const BREEDING_RUNTIME_PATH := "res://scripts/runtime/breeding_runtime.gd"

# --- Phase 5 runtime + domain adapters -----------------------------------------

# The breeding runtime — WIRED (game_runtime var) once the wiring task lands;
# until then the scenarios instantiate + setup their OWN on the game_runtime
# meta (same shared _rng, session, catalog, trace, world_gen) and pen_tick
# drives its tick directly. The two paths never run at once (the wired var
# wins), so the scenarios auto-reconcile when the wiring lands.
static func breeding_rt(runtime) -> Variant:
	var wired = runtime.get("breeding_runtime")
	if wired != null:
		return wired
	if runtime.has_meta("scenario_breeding_rt"):
		return runtime.get_meta("scenario_breeding_rt")
	if not ResourceLoader.exists(BREEDING_RUNTIME_PATH):
		return null
	var inst = load(BREEDING_RUNTIME_PATH).new()
	inst.setup(runtime.session, runtime.catalog, runtime.pokemon_rules, runtime.trace, runtime._world_gen, runtime._rng, Callable(), null)
	runtime.set_meta("scenario_breeding_rt", inst)
	return inst


static func breeding_rt_is_wired(runtime) -> bool: return runtime.get("breeding_runtime") != null
static func fishing_rt(runtime) -> Variant: return runtime.get("fishing_runtime")
static func habitat_rt(runtime) -> Variant: return runtime.get("habitat_runtime")


static func habitat_drops_domain(runtime) -> Variant:
	return load(HABITAT_DROPS_PATH) if ResourceLoader.exists(HABITAT_DROPS_PATH) else null


static func breeding_domain(runtime) -> Variant:
	return load(BREEDING_DOMAIN_PATH) if ResourceLoader.exists(BREEDING_DOMAIN_PATH) else null


# The fishing domain (app scenarios may not load domain scripts directly —
# check_architecture — so this runtime-layer accessor fronts the tier tables).
static func fishing_domain() -> Variant:
	return load(FISHING_DOMAIN_PATH) if ResourceLoader.exists(FISHING_DOMAIN_PATH) else null


# Contract witness: every Phase 5 surface the scenarios read must exist (the
# breeding runtime may be wired OR scenario-owned — breeding_rt instantiates
# the fallback; habitat + fishing must be wired by game_runtime).
static func contract_problem(runtime) -> String:
	if breeding_rt(runtime) == null:
		return "contract: breeding_runtime is missing (wired or instantiable)"
	if habitat_rt(runtime) == null:
		return "contract: runtime.habitat_runtime is not wired (game_runtime setup)"
	if fishing_rt(runtime) == null:
		return "contract: runtime.fishing_runtime is not wired (game_runtime setup)"
	return shiny_contract_problem(runtime)


static func shiny_contract_problem(runtime) -> String:
	if not runtime.pokemon_rules.has_method("roll_shiny"):
		return "contract: pokemon_rules.roll_shiny is missing"
	if habitat_drops_domain(runtime) == null or breeding_domain(runtime) == null:
		return "contract: a Phase 5 domain module is missing"
	return ""


# --- Pasture (party <-> pen) -----------------------------------------------------

# breeding_runtime's seam (the breeding scenarios): gates on pen_tile_near, so
# the caller teleports the player inside the pen first (fences are solid).
static func pasture_deposit(runtime, party_index: int) -> Dictionary:
	var rt = breeding_rt(runtime)
	if rt != null and (rt as Object).has_method("deposit_to_nearest_pen"):
		return _dict((rt as Object).call("deposit_to_nearest_pen", party_index), "deposit_to_nearest_pen")
	return {"ok": false, "reason": "contract: breeding_runtime.deposit_to_nearest_pen is missing"}


# habitat_runtime's seam (the drops scenarios): evaluates + caches the habitat
# satisfaction the drop gate reads.
static func habitat_deposit(runtime, party_index: int, tile: Vector2i) -> Dictionary:
	var hrt = habitat_rt(runtime)
	if hrt != null and (hrt as Object).has_method("deposit_mon"):
		return _dict((hrt as Object).call("deposit_mon", party_index, tile), "deposit_mon")
	return {"ok": false, "reason": "contract: habitat_runtime.deposit_mon is missing"}


static func pasture_withdraw(runtime, anchor: String, mon_index: int) -> Dictionary:
	var hrt = habitat_rt(runtime)
	if hrt != null and (hrt as Object).has_method("withdraw_mon"):
		return _dict((hrt as Object).call("withdraw_mon", anchor, mon_index), "withdraw_mon")
	return {"ok": false, "reason": "contract: habitat_runtime.withdraw_mon is missing"}


# Faced-fence Z on breeding_runtime: ground-egg pickup first, else the latest
# penned mon withdraws ({} when the faced spot is no pen interior).
static func pasture_interact(runtime, stand_tile: Vector2i, faced_tile: Vector2i) -> Dictionary:
	var rt = breeding_rt(runtime)
	if rt == null or not (rt as Object).has_method("interact"):
		return {"ok": false, "reason": "contract: breeding_runtime.interact is missing"}
	return _dict((rt as Object).call("interact", stand_tile, faced_tile), "interact")


static func pasture_snapshot(runtime) -> Dictionary:
	var rt = breeding_rt(runtime)
	if rt != null and (rt as Object).has_method("pasture_snapshot"):
		var snapshot = (rt as Object).call("pasture_snapshot")
		if snapshot is Dictionary:
			return snapshot
	var raw: Variant = runtime.session.get("pastures")
	return (raw as Dictionary).duplicate(true) if raw is Dictionary else {}


# [{"tile": Vector2i, "egg": Dictionary}] ground eggs for one pen anchor.
static func pasture_eggs(runtime, anchor: String) -> Array:
	var entry: Variant = pasture_snapshot(runtime).get(anchor, {})
	var eggs: Variant = (entry as Dictionary).get("eggs", []) if entry is Dictionary else []
	var out: Array = []
	if eggs is Array:
		for egg_variant in eggs:
			if egg_variant is Dictionary:
				var tile: Variant = (egg_variant as Dictionary).get("tile", [0, 0])
				out.append({"tile": Vector2i(int((tile as Array)[0]), int((tile as Array)[1])) if tile is Array and (tile as Array).size() == 2 else Vector2i.ZERO,
					"egg": (egg_variant as Dictionary).get("egg", {})})
	return out


static func first_pen_egg(runtime, anchor: String) -> Dictionary:
	var eggs := pasture_eggs(runtime, anchor)
	return {} if eggs.is_empty() else eggs[0]


# Steps the clock until the pen holds an egg ({} after cap_steps).
static func wait_for_pen_egg(runtime, anchor: String, cap_steps: int, batch: int) -> Dictionary:
	var egg := first_pen_egg(runtime, anchor)
	for _i in range(cap_steps / maxi(1, batch)):
		if not egg.is_empty():
			return egg
		pen_tick(runtime, batch)
		egg = first_pen_egg(runtime, anchor)
	return egg


# One player step through the public seam main.gd drives (note_player_step ticks
# the habitat runtime; the breeding runtime ticks there too once wired — until
# then the scenario-owned instance's tick is driven directly, same cadence).
static func pen_tick(runtime, steps: int) -> void:
	var wired := breeding_rt_is_wired(runtime)
	for _i in range(steps):
		runtime.note_player_step()
		if not wired:
			var rt = breeding_rt(runtime)
			if rt != null and (rt as Object).has_method("tick"):
				(rt as Object).call("tick")


# Direct happiness poke on the LIVE pasture entry — the documented scenario seam
# (breeding_runtime header: "scenarios may poke happiness directly"); the real
# habitat gain is habitat_runtime's tick (habitat_drops proves that path).
static func poke_pasture_happiness(runtime, anchor: String, value: int) -> bool:
	var rt = breeding_rt(runtime)
	if rt != null:
		var pastures: Variant = (rt as Object).get("_pastures")
		if pastures is Dictionary and (pastures as Dictionary).has(anchor):
			var mons: Variant = ((pastures as Dictionary)[anchor] as Dictionary).get("mons", [])
			if mons is Array and not (mons as Array).is_empty():
				for mon in mons:
					(mon as Dictionary)["happiness"] = value
				return true
	var hrt = habitat_rt(runtime)
	if hrt != null and (hrt as Object).has_method("mons_for"):
		var mons: Array = (hrt as Object).call("mons_for", anchor)
		if not mons.is_empty():
			for mon in mons:
				(mon as Dictionary)["happiness"] = value
			return true
	return false


# breeding_runtime's region cache (empty fences -> pen detection re-floods).
static func invalidate_pen_cache(runtime) -> void:
	var rt = breeding_rt(runtime)
	if rt != null and (rt as Object).has_method("note_structures_changed"):
		(rt as Object).call("note_structures_changed")


# The breeding runtime's OWN pen detection for the tile ("" when it sees no pen
# there — the enclosure witness from the runtime's side of the seam). Reads the
# shared Breeding.detect_pens the runtime uses (same budget), so it sees a
# freshly built pen even before any pasture entry exists.
static func pen_key_for(runtime, tile: Vector2i) -> String:
	var domain = breeding_domain(runtime)
	if domain == null or not (domain as Object).has_method("detect_pens"):
		return ""
	var pens = (domain as Object).call("detect_pens", runtime._world_gen.placements_for_save(), Callable(runtime._world_gen, "get_tile_logic"), 256)
	if pens is Dictionary:
		for key in (pens as Dictionary).keys():
			if (((pens as Dictionary)[key]) as Array).has(tile):
				return str(key)
	return ""


# --- Fishing (reconciled to the LANDED fishing_runtime.try_fish) ---------------

static func cast_rod(runtime, faced_tile: Vector2i) -> Dictionary:
	var rt = fishing_rt(runtime)
	if rt == null or not (rt as Object).has_method("try_fish"):
		return {"ok": false, "reason": "contract: fishing_runtime.try_fish is missing"}
	return _dict((rt as Object).call("try_fish", faced_tile), "try_fish")


# The user-adjustable-odds hook (original FAQ; shiny_odds proves it). Probes the
# candidate seams; false when no hook is wired — a LOUD contract red.
static func set_shiny_odds(runtime, odds: int) -> bool:
	for target in [breeding_domain(runtime), runtime.pokemon_rules, breeding_rt(runtime)]:
		if target != null and (target as Object).has_method("set_shiny_odds"):
			(target as Object).call("set_shiny_odds", odds)
			return true
	return false


# --- Witnesses + party crafting --------------------------------------------------

# The load-bearing drop-economy invariant (habitat_drops.witness_clean): the
# habitat drop table never yields log/hard_stone.
static func drop_table_witness_clean(runtime) -> bool:
	var domain = habitat_drops_domain(runtime)
	if domain != null and (domain as Object).has_method("witness_clean"):
		return bool((domain as Object).call("witness_clean"))
	return false


# One instance per wanted gender (deterministic: gender rides the creation
# nonce, shiny the pinned rng); {} when a gender never appears in 128 tries.
static func gendered_instances(runtime, species_id: String, level: int, genders: Array) -> Dictionary:
	var entry: Dictionary = runtime.catalog.get_species(species_id)
	var get_move := Callable(runtime.catalog, "get_move")
	var found := {}
	for _i in range(128):
		var mon: Dictionary = runtime.pokemon_rules.create_pokemon_instance(entry, level, get_move, runtime._rng)
		var gender := str(mon.get("gender", ""))
		if genders.has(gender) and not found.has(gender):
			found[gender] = mon
		if found.size() == genders.size():
			return found
	return {} if found.size() < genders.size() else found


# No egg group in common — the can_breed gate's load-bearing core (the catalog
# drift guard the breed_flow wrong-group negative rides).
static func egg_groups_disjoint(entry_a: Dictionary, entry_b: Dictionary) -> bool:
	var groups_b: Variant = entry_b.get("egg_groups", PackedStringArray())
	for group in entry_a.get("egg_groups", PackedStringArray()):
		if str(group) in groups_b:
			return false
	return true


# True when the species is satisfied on bare basic ground alone (basic-recessive
# types) — the wrong-group guard that keeps habitat from confounding the gate.
static func basic_ground_satisfies(runtime, species_id: String) -> bool:
	var domain = habitat_drops_domain(runtime)
	var entry: Dictionary = runtime.catalog.get_species(species_id)
	return domain != null and bool((domain as Object).call("types_satisfied", entry.get("types", PackedStringArray()), species_id, {"basic": true}))


# First party index holding the species (-1 when absent).
static func party_index_of(runtime, species_id: String) -> int:
	for i in range(runtime.session.party.size()):
		if str((runtime.session.party[i] as Dictionary).get("species_id", "")) == species_id:
			return i
	return -1


static func _dict(result: Variant, method: String) -> Dictionary:
	return result if result is Dictionary else {"ok": false, "reason": "contract: %s returned no dict" % method}
