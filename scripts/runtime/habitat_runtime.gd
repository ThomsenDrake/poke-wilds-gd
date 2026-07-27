extends RefCounted

# Habitat happiness + drops runtime (Phase 5; spec: docs/product-specs/
# breeding-shinies-drops-fishing.md). The SHARED habitat-happiness subsystem the
# breeding loop layers on top of: breeding pairs gate on the SAME comfort check.
# The coupling with breeding_runtime is ONE shared store, never a copy: the v4
# additive session "pastures" key is held BY REFERENCE on both sides (breeding_
# runtime._pastures IS this dict) — this runtime reads and writes the pasture
# entries in place, so the daily +10 happiness reaches breeding's 220 lay gate
# IMMEDIATELY (no save roundtrip; an earlier header claimed one — that was false).
# EXTRACTED per the line-budget contract: game_runtime.gd only instantiates +
# setup()s it. NO rng is injected — every outcome below is a pure function of the
# lifetime step counter, so drops + happiness are deterministic for free and the
# shared encounter stream is NEVER consumed (night_system guarantee, extended).
#
# PENS = Phase 1 fence enclosures detected through the ONE shared flood this runtime
# and breeding_runtime both ride (Breeding.detect_pens, PEN_FLOOD_BUDGET — a flood
# reaching the budget is unbounded; the min-y-then-x anchor convention is shared so
# BOTH runtimes key the same pen identically on the session key). A fence-adjacent
# DOOR (gate) is WALKABLE, so the flood escapes through it — an open gate is NO
# enclosure (faithful; spec'd). Mons enter/leave through the pasture API only (no
# overworld mon entities until Phase 6).
#
# COMFORT + HAPPINESS: comfort is evaluated at drop and cached per mon (never live
# tile scanning), re-evaluated on each in-game day tick (documented divergence: the
# original holds the drop-time check until pickup; the port's daily re-check is what
# makes "becomes uncomfortable -> forfeits the drop" observable). Comfortable mons
# gain HABITAT_HAPPINESS_GAIN per day tick (clamp 0-255); the 220 friendship-evolution
# threshold doubles as the HAPPY GATE for drops (and breeding) and feeds the wired
# happiness evolution once the mon returns to the party. Habitat tags scan the pen
# interior PLUS its one-tile ring (trees / lava / water are solid or unwalkable —
# the ring catches them; dual-types need BOTH tiles via habitat_drops.types_satisfied).
#
# DROPS — the FAITHFUL primary source (material_drops.gd's Phase 4 battle-end table
# stays a documented SECONDARY): once per in-game day (1440 steps — one step is one
# clock minute), each happy (>= 220) + comfortable penned mon yields its
# habitat_drops.drops_for materials (dual-types emit one item_dropped PER material)
# straight to the bag; an uncomfortable mon forfeits that day's drop (faithful).
# DIVERGENCE (Phase 5 acquisition, uncited): on each Steel-type mon's drop day the
# SAME gate also cadence-drops one shiny_stone (habitat_drops.STEEL_STONE_DROP /
# STEEL_STONE_CADENCE — invented; wiki-materials.md:393 documents Metal Coat only).
# Traces: habitat_happiness_changed, item_dropped, pasture_deposited/withdrawn;
# refusals are warning-tier ("Pasture action refused."), never silent.

const HabitatDrops := preload("res://scripts/domain/habitat_drops.gd")
const PokemonRules := preload("res://scripts/domain/pokemon_rules.gd")
const Breeding := preload("res://scripts/domain/breeding.gd")

const PEN_FLOOD_BUDGET := 256 # SHARED with breeding_runtime: ONE pen detector (Breeding.detect_pens), one anchor
const DAY_STEPS := 1440 # one step = one clock minute; one in-game day per 1440 steps
const HABITAT_HAPPINESS_GAIN := 10 # per comfortable day tick (clamp 255; 220 = happy gate)

var _session = null
var _catalog = null
var _rules = null
var _trace = null
var _world_gen = null
var _last_day := -1 # day index seen at the previous note_step (-1 until the first tick)
var _loaded_normalized := false # pasture mons bypass the load-time party normalize — do it once


func setup(session_state, catalog, rules, trace_logger, world_generator) -> void:
	_session = session_state
	_catalog = catalog
	_rules = rules
	_trace = trace_logger
	_world_gen = world_generator


# --- Pens (ONE shared detector with breeding_runtime) ------------------------------

# The enclosed walkable region containing `tile` (or a 4-neighbor of it, so dropping
# works while standing OUTSIDE the fence); [] when no pen bounds it. Rides the SAME
# Breeding.detect_pens breeding_runtime caches (one budget, one verdict — the old
# private 100-tile flood diverged for pens with 100-255 interior tiles and is gone).
func pen_region_for(tile: Vector2i) -> Array:
	var regions := Breeding.detect_pens(_world_gen.placements_for_save(), Callable(_world_gen, "get_tile_logic"), PEN_FLOOD_BUDGET)
	var candidates: Array = [tile]
	for direction in [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]:
		candidates.append(tile + direction)
	for candidate in candidates:
		for region_variant in regions.values():
			if (region_variant as Array).has(candidate):
				return region_variant as Array
	return []


# Habitat tags over the pen interior PLUS its one-tile ring — the ONE shared scan
# (HabitatDrops.pen_habitat_tags) the breeding lay gate rides too, so drops-comfortable
# ⟺ the breeding lay-gate passes by construction.
func habitat_tags_for(region: Array) -> Dictionary:
	return HabitatDrops.pen_habitat_tags(region, Callable(_world_gen, "get_tile_logic"))


# --- Pasture API (party <-> pen; the breeding loop reads these seams) --------------

func pasture_anchors() -> Array:
	return _session.pastures.keys()


# The LIVE mons array for one pen (snapshot callers duplicate — the breeding tick reads live state).
func mons_for(anchor: String) -> Array:
	var entry: Variant = _session.pastures.get(anchor, {})
	if entry is Dictionary:
		var mons: Variant = (entry as Dictionary).get("mons", [])
		if mons is Array:
			return mons
	return []


# The LIVE eggs array for one pen (breeding's eggs ride the shared store under the
# same anchor; withdraw erases the entry only when BOTH mons and eggs are gone).
func _eggs_for(anchor: String) -> Array:
	var entry: Variant = _session.pastures.get(anchor, {})
	if entry is Dictionary:
		var eggs: Variant = (entry as Dictionary).get("eggs", [])
		if eggs is Array:
			return eggs
	return []


# Comfort as last evaluated (the breeding gate reads this; never-penned party mons -> false, faithful).
func is_comfortable(mon: Dictionary) -> bool:
	var habitat: Variant = mon.get("habitat", {})
	return habitat is Dictionary and bool((habitat as Dictionary).get("satisfied", false))


# Moves a party mon into the pen bounding `tile`; refuses a bad index (no_such_mon),
# eggs (egg_guard — breeding rides party slots), the LAST party member (the storage
# no-strand precedent), and tiles no enclosure bounds (not_in_pen). Evaluates comfort
# at drop (the faithful check); traces pasture_deposited + habitat_happiness_changed.
func deposit_mon(party_index: int, tile: Vector2i) -> Dictionary:
	var party: Array = _session.party
	if party_index < 0 or party_index >= party.size():
		return _refuse("drop", "no_such_mon", {}, tile)
	var mon: Dictionary = party[party_index]
	if bool(mon.get("is_egg", false)):
		return _refuse("drop", "egg_guard", mon, tile)
	if party.size() <= 1:
		return _refuse("drop", "last_party_member", mon, tile)
	var region := pen_region_for(tile)
	if region.is_empty():
		return _refuse("drop", "not_in_pen", mon, tile)
	var anchor := _anchor_of(region)
	var satisfied := _evaluate(mon, region)
	party.remove_at(party_index)
	mon["habitat"] = {"satisfied": satisfied, "last_drop_day": -1, "last_stone_day": -HabitatDrops.STEEL_STONE_CADENCE} # stone-due on the first drop day; loaded mons self-heal via _habitat_of's .get default
	var entry: Variant = _session.pastures.get(anchor, {})
	if not (entry is Dictionary) or not (entry as Dictionary).has("mons"):
		entry = {"anchor": _anchor_pair(anchor), "mons": []}
	(entry as Dictionary)["mons"].append(mon)
	_session.pastures[anchor] = entry
	_emit("pasture_deposited", {"species_id": str(mon.get("species_id", "")), "tile": _anchor_pair(anchor)})
	_emit_happiness(mon, anchor, 0)
	return {"ok": true, "reason": "", "anchor": anchor, "satisfied": satisfied,
		"message": "%s settles into the pen." % str(mon.get("name", "The Pokemon"))}


# Returns a pastured mon to the party (cap 6; a refusal leaves it penned, never
# lost — party_full / no_such_mon / not_in_pen). Happiness accrued in the pen rides
# with it (friendship evolutions read it).
func withdraw_mon(anchor: String, mon_index: int) -> Dictionary:
	if not _session.pastures.has(anchor):
		return _refuse("take_out", "not_in_pen", {}, _anchor_tile(anchor))
	var mons := mons_for(anchor)
	if mon_index < 0 or mon_index >= mons.size():
		return _refuse("take_out", "no_such_mon", {}, _anchor_tile(anchor))
	if _session.party.size() >= 6:
		return _refuse("take_out", "party_full", mons[mon_index], _anchor_tile(anchor))
	var mon: Dictionary = mons[mon_index]
	mons.remove_at(mon_index)
	if mons.is_empty() and _eggs_for(anchor).is_empty(): # shared store: never erase breeding's eggs
		_session.pastures.erase(anchor)
	_session.party.append(mon)
	_emit("pasture_withdrawn", {"species_id": str(mon.get("species_id", "")), "tile": _anchor_pair(anchor)})
	return {"ok": true, "reason": "", "mon": mon,
		"message": "%s rejoins the party." % str(mon.get("name", "The Pokemon"))}


# --- Per-step tick (wired into game_runtime.note_player_step) -----------------------

func note_step() -> void:
	if _session.pastures.is_empty():
		return
	if not _loaded_normalized:
		_normalize_loaded_pastures() # pasture mons bypass the load-time party normalize
		_loaded_normalized = true
	var day := int(_session.total_steps) / DAY_STEPS
	if day != _last_day:
		if _last_day >= 0: # skip the load-time first tick: the day tick fires on a CROSSED boundary only
			_day_tick(day)
		_last_day = day


# Day tick: comfort re-evaluation (a broken pen — fence demolished — reads as an
# empty region -> uncomfortable), happiness gain while comfortable, and the drop
# cadence — once per in-game day, each happy (>= 220) + comfortable mon yields its
# materials; an uncomfortable mon forfeits the day (faithful).
func _day_tick(day: int) -> void:
	for anchor in _session.pastures.keys():
		var region := pen_region_for(_anchor_tile(str(anchor)))
		var tags := habitat_tags_for(region) if not region.is_empty() else {}
		for mon_variant in mons_for(str(anchor)):
			if not (mon_variant is Dictionary) or bool((mon_variant as Dictionary).get("is_egg", false)):
				continue
			var mon: Dictionary = mon_variant
			var habitat := _habitat_of(mon)
			var satisfied := not region.is_empty() and HabitatDrops.types_satisfied(
				_species_types(mon), str(mon.get("species_id", "")), tags)
			var was_satisfied := bool(habitat.get("satisfied", false))
			habitat["satisfied"] = satisfied
			mon["habitat"] = habitat # publish BEFORE the emits below so is_comfortable reads the FRESH verdict
			var gain := HABITAT_HAPPINESS_GAIN if satisfied else 0
			var old := int(mon.get("happiness", PokemonRules.DEFAULT_HAPPINESS))
			var updated := mini(255, old + gain)
			if updated != old:
				mon["happiness"] = updated
			if satisfied != was_satisfied:
				_emit_happiness(mon, str(anchor), 0) # comfort flipped — delta 0, new verdict
			elif updated != old:
				_emit_happiness(mon, str(anchor), updated - old)
			if satisfied and int(mon.get("happiness", 0)) >= PokemonRules.HAPPINESS_EVOLUTION_THRESHOLD \
					and int(habitat.get("last_drop_day", -1)) < day:
				var species_entry: Dictionary = _catalog.get_species(str(mon.get("species_id", "")))
				for item_id in HabitatDrops.drops_for(species_entry):
					_session.add_item(str(item_id), 1)
					_emit("item_dropped", {"species_id": str(mon.get("species_id", "")),
						"item_id": str(item_id), "tile": _anchor_pair(str(anchor)), "day": day})
				habitat["last_drop_day"] = day
				# DIVERGENCE (uncited — wiki-materials.md:393 Steel = Metal Coat ONLY): a happy Steel
				# mon yields ONE shiny_stone per STEEL_STONE_CADENCE-day window, reusing item_dropped
				# (same payload keys: species_id, item_id, tile [x, y], day). Step-counter pure — no rng.
				var last_stone_day := int(habitat.get("last_stone_day", -HabitatDrops.STEEL_STONE_CADENCE))
				if HabitatDrops.steel_stone_due(species_entry, day, last_stone_day):
					_session.add_item(HabitatDrops.STEEL_STONE_DROP, 1)
					_emit("item_dropped", {"species_id": str(mon.get("species_id", "")),
						"item_id": HabitatDrops.STEEL_STONE_DROP, "tile": _anchor_pair(str(anchor)), "day": day})
					habitat["last_stone_day"] = day


# --- shared helpers ------------------------------------------------------------------

func _evaluate(mon: Dictionary, region: Array) -> bool:
	return HabitatDrops.types_satisfied(_species_types(mon), str(mon.get("species_id", "")), habitat_tags_for(region))


func _species_types(mon: Dictionary) -> Variant:
	var entry: Dictionary = _catalog.get_species(str(mon.get("species_id", "")))
	return entry.get("types", mon.get("types", PackedStringArray())) if entry is Dictionary else mon.get("types", PackedStringArray())


# Fresh copy: the habitat sub-dict rides the mon dict (additive mon key; survives
# normalize_loaded_mon's duplicate(true) untouched), so the runtime self-heals a
# missing/corrupt value here instead of a load-time sanitizer.
func _habitat_of(mon: Dictionary) -> Dictionary:
	var habitat: Variant = mon.get("habitat", {})
	return (habitat as Dictionary).duplicate() if habitat is Dictionary else {}


# One-time load sanitize: apply_loaded_state duplicates pastures without the party's
# normalize pass, so run normalize_loaded_mon over every penned mon once (keeps the
# additive habitat/egg keys, clamps happiness, clears volatile battle keys).
func _normalize_loaded_pastures() -> void:
	if _rules == null:
		return
	for anchor in _session.pastures.keys():
		var mons := mons_for(str(anchor))
		for i in range(mons.size()):
			if mons[i] is Dictionary:
				mons[i] = _rules.normalize_loaded_mon(mons[i])


# Pen identity = Breeding.anchor_key (min y, then x — the SHARED convention, so the
# session "pastures" entry keys EXACTLY as breeding_runtime's cache does).
func _anchor_of(region: Array) -> String:
	return Breeding.anchor_key(region)


func _anchor_tile(anchor: String) -> Vector2i:
	var parts := anchor.split(",")
	if parts.size() != 2 or not parts[0].is_valid_int() or not parts[1].is_valid_int():
		return Vector2i.MAX
	return Vector2i(parts[0].to_int(), parts[1].to_int())


func _anchor_pair(anchor: String) -> Array:
	var tile := _anchor_tile(anchor)
	return [tile.x, tile.y]


func _refuse(action: String, reason: String, mon: Dictionary, tile: Vector2i) -> Dictionary:
	var species_id := str(mon.get("species_id", ""))
	_trace.warning("HabitatRuntime", "Pasture action refused.", {"action": action, "reason": reason, "species_id": species_id})
	_emit("pasture_refused", {"action": action, "reason": reason, "species_id": species_id, "tile": [tile.x, tile.y]})
	var messages := {"not_in_pen": "No fence enclosure bounds that spot.", "last_party_member": "You can't pen your last Pokemon.",
		"egg_guard": "Eggs stay in the party.", "party_full": "Your party is full."}
	return {"ok": false, "reason": reason, "anchor": "", "tile": [tile.x, tile.y],
		"message": str(messages.get(reason, "That Pokemon can't be penned there."))}


func _emit_happiness(mon: Dictionary, anchor: String, delta: int) -> void:
	_emit("habitat_happiness_changed", {"species_id": str(mon.get("species_id", "")), "tile": _anchor_pair(anchor),
		"happiness": int(mon.get("happiness", 0)), "delta": delta, "satisfied": is_comfortable(mon)})


func _emit(event_name: String, payload: Dictionary) -> void:
	_trace.emit_event(event_name, "HabitatRuntime", payload)
