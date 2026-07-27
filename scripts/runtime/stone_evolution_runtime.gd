extends RefCounted

# Evolution-stone bag-use seam (exec plan pokewilds-feature-completion.md
# :141-156; spec breeding-shinies-drops-fishing.md § Evolution stones). Flow:
# validate -> consume -> swap -> trace (consume FIRST: a refused decrement
# evolves nothing). Stats RECOMPUTE exactly as the level-evolution path
# (battle_runtime._try_evolve): build_stats off the target entry's base_stats
# at the mon's level, max_hp from the new stats, current_hp scaled by the
# pre-swap ratio (clamp >= 1), catch_rate from the target — a stone evolution
# can never leave stale pre-evo stats behind. The stone-id gate is an EXPLICIT set:
# pokemon_rules.check_item_evolution matches ANY ITEM-method evolution param
# (CRACKEDPOT / SWEET_APPLE / TART_APPLE also match) and hard_stone is a bagged
# building material ending in "_stone", so a suffix test would misroute both.
# No rng is threaded here, so seeded scenario streams stay byte-stable.
# ACQUISITION is deferred (spec :89, tech-debt item 11): scenarios GRANT stones.
# The only cited source is Beach Dig -> Water Stone (fresh-beach.md "Dig Items":
# Big Pearl, Water Stone, Clear Glass, Revive); the wider table (incl. the exec
# plan's "Steel-type drops") is uncited (wiki-materials.md:393 Steel = Metal Coat
# only) and a faithful one-of-pool Dig would need a seeded rng threaded into
# harvest_runtime plus a Beach-vs-SAND/DESERT key decision — a harvest-loop
# follow-up that would re-stamp build_house_flow's exact dig-yield pins.

const NO_EFFECT_MESSAGE := "It would have no effect."
const DEFAULT_CATCH_RATE := 45 # the battle_runtime fallback; catalog entries carry their own

# Bag ids exactly as pokewilds/i18n/item.properties:80-89 keys them. thunderstone
# has NO underscore (item.properties:83 + the THUNDERSTONE evo param) — the brief
# spelling "thunder_stone" would be a silent no-effect on every Electric-stone evo.
# SINGLE SOURCE: bag_screen reads this const off the preloaded module, so routing
# and validation can never disagree (the divergent-second-table pattern, eliminated).
const STONE_ITEM_IDS := {"fire_stone": true, "water_stone": true, "thunderstone": true, "leaf_stone": true, "moon_stone": true, "sun_stone": true, "ice_stone": true, "dawn_stone": true, "dusk_stone": true, "shiny_stone": true}

var _session = null
var _catalog = null
var _pokemon_rules = null
var _trace = null


func setup(session_state, catalog, pokemon_rules, trace_logger) -> void:
	_session = session_state
	_catalog = catalog
	_pokemon_rules = pokemon_rules
	_trace = trace_logger


# (item_id, party_index) -> {ok, reason, message, evolved_species_id on success}.
# Reasons: not_a_stone / no_such_mon (index guard — a refusal, never the no-effect
# line) / no_effect (egg, wrong stone, no-ITEM-evo line, already-final, unknown
# species — consumes nothing, emits no trace; the Potion precedent) / no_item
# (defensive: the bag decrement refused — nothing applied) / bad_target (defensive
# catalog miss — warning trace, consumes nothing) / "" on success (consume 1
# stone, emit evolution_stone_used).
func use_stone_on_mon(item_id: String, party_index: int) -> Dictionary:
	var stone := item_id.strip_edges().to_lower()
	if not STONE_ITEM_IDS.has(stone):
		return {"ok": false, "reason": "not_a_stone", "message": "Can't use that here."}
	if party_index < 0 or party_index >= _session.party.size():
		return {"ok": false, "reason": "no_such_mon", "message": "There is no Pokemon to use it on."}
	var mon_variant: Variant = _session.party[party_index]
	if not mon_variant is Dictionary:
		return {"ok": false, "reason": "no_such_mon", "message": "There is no Pokemon to use it on."}
	var mon: Dictionary = mon_variant
	if bool(mon.get("is_egg", false)): # eggs never evolve: the no-effect line, not the Potion egg line
		return {"ok": false, "reason": "no_effect", "message": NO_EFFECT_MESSAGE}
	var evo: Dictionary = _pokemon_rules.check_item_evolution(mon, stone, Callable(_catalog, "get_species"))
	if evo.is_empty():
		return {"ok": false, "reason": "no_effect", "message": NO_EFFECT_MESSAGE}
	var target_id := str(evo.get("target", ""))
	var target_entry: Dictionary = _catalog.get_species(target_id)
	if target_entry.is_empty():
		_trace.warning("GameRuntime", "Evolution stone target species is missing from the catalog.", {"item_id": stone, "target_id": target_id})
		return {"ok": false, "reason": "bad_target", "message": NO_EFFECT_MESSAGE}
	var evolved := mon.duplicate(true) # is_shiny + level/exp/moves/happiness ride the swap
	var pre_species := str(mon.get("species_id", ""))
	var pre_name := str(mon.get("name", "Pokemon"))
	var old_max_hp := maxi(1, int(evolved.get("max_hp", 1)))
	var hp_ratio := clampf(float(int(evolved.get("current_hp", 0))) / float(old_max_hp), 0.0, 1.0)
	var stats: Dictionary = _pokemon_rules.build_stats(target_entry.get("base_stats", {}), int(evolved.get("level", 1)))
	evolved["species_id"] = target_id
	evolved["name"] = str(target_entry.get("display_name", target_id))
	evolved["types"] = target_entry.get("types", evolved.get("types", PackedStringArray(["NORMAL", "NORMAL"])))
	evolved["front_path"] = str(target_entry.get("front_path", ""))
	evolved["back_path"] = str(target_entry.get("back_path", ""))
	evolved["catch_rate"] = int(target_entry.get("catch_rate", DEFAULT_CATCH_RATE))
	evolved["stats"] = stats # battle_runtime._try_evolve parity: stats follow the species
	evolved["max_hp"] = int(stats.get("hp", old_max_hp))
	evolved["current_hp"] = clampi(int(round(hp_ratio * float(int(evolved["max_hp"])))), 1, int(evolved["max_hp"]))
	if not _session.remove_item(stone, 1): # consume BEFORE the swap — a refused decrement evolves nothing
		return {"ok": false, "reason": "no_item", "message": NO_EFFECT_MESSAGE}
	_session.set_party_member(party_index, evolved)
	_trace.emit_event("evolution_stone_used", "GameRuntime", {"item_id": stone, "species_id": pre_species, "evolved": target_id})
	return {"ok": true, "reason": "", "message": "%s evolved into %s!" % [pre_name, str(target_entry.get("display_name", target_id))], "evolved_species_id": target_id}
