extends RefCounted

# Phase 6 overworld Pokémon — PURE domain rules (spec: docs/product-specs/
# overworld-pokemon.md): slot/cell spawn model, disposition resolution, the egg-theft
# provocation rule, nest/Alpha rolls. NO rng, NO I/O, NO catalog instance (callers pass
# dicts, the biome_encounters convention). overworld_mons_runtime.gd owns entity lifetime
# + traces. (The Charm gate lives in field_move_runtime.gd:254 — the single live source.)
#
# LOAD-BEARING DETERMINISM: every roll is a pure SplitMix-style hash of
# (world_seed, a, b, salt) — a verbatim lift of harvest_resolver._dig_draw
# (harvest_resolver.gd:99-103) with ONE additive salt term. The shared _rng (the
# wild-encounter stream; night_system.gd:24-28) is NEVER consumed here, so the 39
# pinned scenarios, the determinism canary and shiny_odds stay untouched. No engine
# hash() (no Godot-version drift), no dict iteration in any roll; distinct odd salts
# keep streams uncorrelated.
#
# FAITHFUL ANCHORS (.firecrawl/wiki-overworld-encounters.md): four dispositions
# (:252-270), egg TAKE-provokes / Attack-clears (:248), wild-egg level-5 HATCH
# (:250; the :250 battle path is dropped — spec § Divergences), +3-stage provoked
# buff (:284), KO/catch removal + white-out leaves mons
# (:288), no overworld shiny visual (:230), Diglett/Dugtrio speed (:296). EVERY
# invented number is flagged inline (DIVERGENCE #n) + in the spec's § Divergences.

const PokemonRules := preload("res://scripts/domain/pokemon_rules.gd") # shiny_odds static var + gender constants ONLY (same layer)

# --- Pinned constants (scenario contract; changing one is a spec change) ---------
const CELL_SIZE := 8 # DIVERGENCE #2: world tiled into 8x8 cells (nothing published)
const SLOTS_PER_CELL := 1 # DIVERGENCE #2: one roaming slot per cell (2nd = a const flip)
const SPAWN_PRESENT_PCT := 25 # DIVERGENCE #2/#8: slot presence %; ~6-9 roamers per window
const DESPAWN_CELLS := 3 # DIVERGENCE #2: invented distance un-materialization (Chebyshev cells)
const ROAM_EVERY := 4 # DIVERGENCE #2/#3: roam cadence on the player-step clock (:222)
const FAST_ROAM_IDS := {"DIGLETT": true, "DUGTRIO": true} # FAITHFUL :296: faster than any other
const SPOT_RADIUS := 6 # DIVERGENCE #3: aggressive sight (Manhattan; "spotted" :270)
const SPOOK_RADIUS := 3 # DIVERGENCE #3: timid flee trigger ("too close" :254)
const CHASE_RADIUS := 8 # DIVERGENCE #3: a chase drops beyond this
const CATCH_RADIUS := 1 # DIVERGENCE #3: adjacency starts the forced battle
const FLEE_STEPS := 6 # DIVERGENCE #3: timid flee duration before despawn
const CHARM_CALM_STEPS := 12 # DIVERGENCE #6: Charm pacification window
const EGG_PROVOKE_RADIUS := 6 # DIVERGENCE #5: egg-theft reach ("nearby" :248)
const WILD_EGG_LEVEL := 5 # FAITHFUL :250 hatch level (the :250 battle path is dropped — spec § Divergences)
const PROVOKED_ATTACK_STAGES := 3 # FAITHFUL :284: chase-catch +3 physical-attack buff
const NEST_PRESENT_PCT := 3 # DIVERGENCE #1: nest cell gate (rare; strewn egg is common)
const NEST_EGGS := 2 # DIVERGENCE #1: wild-egg entities per nest
const ALPHA_LEVEL_BONUS := 5 # DIVERGENCE #1: guardian level over the distance band
const NEST_MIN_RING := 10 # DIVERGENCE #1: nests only FOREST-and-beyond bands
const GUARDIAN_SPOT_RADIUS := 8 # DIVERGENCE #1: guardian sight widened (it guards)
# Shared vocabulary (runtime + scenario + audit).
const DISPOSITION_TIMID := "TIMID"
const DISPOSITION_FRIENDLY := "FRIENDLY"
const DISPOSITION_IRRITABLE := "IRRITABLE"
const DISPOSITION_AGGRESSIVE := "AGGRESSIVE"
const CLASS_ROAMING := "roaming"
const CLASS_STATIONARY := "stationary"
const REASON_KO := "ko" # FAITHFUL :288
const REASON_CAUGHT := "caught" # FAITHFUL :288
const REASON_FLED := "fled" # FAITHFUL :254-258
const REASON_DISTANCE := "distance" # DIVERGENCE #2
const REASON_RECOMPUTE := "recompute" # DAY<->NIGHT pool re-filter
# Disposition data — wiki examples over the near-degenerate catalog overworld_behavior
# (DIVERGENCE #4; disposition_for is the one editable home). AGGRESSIVE is SPECIES+
# BIOME+TIME gated exactly as the wiki names (:268-274).
const AGGRESSIVE_BIOME_SPECIES := {"PRIMEAPE": {"SAVANNA": true}, "DRAPION": {"DESERT": true}, "SHARPEDO": {"WATER": true}}
const GHOST_BIOMES := {"SWAMP": true, "FOREST": true} # GRAVEYARD/DEEP_FOREST aliases
# TIMID = flee=1 data set + wiki-named CHANSEY "(though not Blissey)" (:252-258); the
# override pins wiki examples against flee-flag drift, BLISSEY barred from the flee
# branch so "not Blissey" holds even if data ever flags it.
const TIMID_OVERRIDE_IDS := {"EKANS": true, "PIDGEY": true, "RATTATA": true, "SPEAROW": true, "PORYGON": true, "SMEARGLE": true, "CHANSEY": true}
const FRIENDLY_EXCEPTION_IDS := {"JUMPLUFF": true, "BELLOSSOM": true, "BLISSEY": true, "POOCHYENA": true} # :262; POOCHYENA over its data aggression=2
# Derived-hash salts — distinct odd constants; extends the spec's named eight with
# ANCHOR (in-cell scan), SLOT (per-entity time identity) and EGG (per-egg stream).
const SALT_PRESENT := 0x1
const SALT_ANCHOR := 0x3
const SALT_SPECIES := 0x5
const SALT_LEVEL := 0x7
const SALT_MOVE := 0x9
const SALT_GENDER := 0xB
const SALT_SHINY := 0xD
const SALT_NEST := 0xF
const SALT_EGG := 0x11
const SALT_SLOT := 0x13
const K0 := 0x6C62272E07BB0142
const K1 := 0x62B821756295C58D
const K2 := 0x4A5A6B2D0E8F3C97
const K3 := 0x5851F42D4C957F2D
const MASK := 0x7FFFFFFFFFFFFFFF


# The hash (harvest_resolver._dig_draw body verbatim + one salt term). int64 multiply
# wrap is deterministic two's-complement, exactly as splitmix64 relies on.
static func _mix(world_seed: int, a: int, b: int, salt: int) -> int:
	var h := (world_seed * K0 + a * K1 + b * K2 + salt * K3) & MASK
	h = ((h ^ (h >> 30)) * K0) & MASK
	h = ((h ^ (h >> 27)) * K1) & MASK
	return (h ^ (h >> 31)) & MASK


# --- Cell/slot grid --------------------------------------------------------------
# Floor div so negative tiles map to the correct (negative) cell — GDScript integer
# division truncates toward zero, which would mirror cells at the origin.
static func _floor_div(value: int, divisor: int) -> int:
	return floori(float(value) / float(divisor))
static func cell_for_tile(tile: Vector2i) -> Vector2i:
	return Vector2i(_floor_div(tile.x, CELL_SIZE), _floor_div(tile.y, CELL_SIZE))
static func cell_center(cell: Vector2i) -> Vector2i:
	return cell * CELL_SIZE + Vector2i(CELL_SIZE / 2, CELL_SIZE / 2)
# Chebyshev: the spawn/despawn band is a square around the player cell (prototype
# amendment — spawn band == despawn band so edge cells never flicker).
static func cell_distance(a: Vector2i, b: Vector2i) -> int:
	return maxi(absi(a.x - b.x), absi(a.y - b.y))
static func in_spawn_band(cell: Vector2i, player_cell: Vector2i) -> bool:
	return cell_distance(cell, player_cell) <= DESPAWN_CELLS
# (a, b) fold a cell+slot into the mix's coordinate args; slot rides b so a second
# slot is a const flip. For SLOTS_PER_CELL=1, (a, b) == (cell.x, cell.y).
static func _cell_a(cell: Vector2i, _slot: int) -> int:
	return cell.x
static func _cell_b(cell: Vector2i, slot: int) -> int:
	return cell.y * maxi(1, SLOTS_PER_CELL) + slot
# Stable positive per-slot identity for time-indexed rolls; world_seed-independent so
# a recompute at the same steps re-derives the same timeline.
static func _slot_scalar(cell: Vector2i, slot: int) -> int:
	return _mix(0, cell.x, _cell_b(cell, slot), SALT_SLOT)


# --- Spawn draws (pure; runtime supplies pool sizes + tile walkability) ----------
static func is_slot_present(world_seed: int, cell: Vector2i, slot: int) -> bool:
	return _mix(world_seed, _cell_a(cell, slot), _cell_b(cell, slot), SALT_PRESENT) % 100 < SPAWN_PRESENT_PCT
# Start offset (0..63) for the runtime's in-cell walkable scan — cells with no
# walkable tile (open water) are skipped there, never here.
static func anchor_offset(world_seed: int, cell: Vector2i, slot: int) -> int:
	return _mix(world_seed, _cell_a(cell, slot), _cell_b(cell, slot), SALT_ANCHOR) % (CELL_SIZE * CELL_SIZE)
# Index into the SORTED biome_encounters.filter_species_ids result (sorted ⇒ stable
# membership — one biome truth). -1 on an empty pool (runtime skips the slot).
static func species_index(world_seed: int, cell: Vector2i, slot: int, pool_size: int) -> int:
	if pool_size <= 0:
		return -1
	return _mix(world_seed, _cell_a(cell, slot), _cell_b(cell, slot), SALT_SPECIES) % pool_size
# FAITHFUL anchor ("levels increase the further you explore", github-readme.md:201):
# the same Manhattan ring bands world_generator uses, +0-2 jitter. Evolved-variant
# surfacing for high parties is DEFERRED (DIVERGENCE #9).
static func level_for(world_seed: int, cell: Vector2i, slot: int, ring: int) -> int:
	return clampi(2 + ring / 6 + _mix(world_seed, _cell_a(cell, slot), _cell_b(cell, slot), SALT_LEVEL) % 3, 2, 100)
# Shiny rides the LIVE PokemonRules.shiny_odds (default 256 = the spec's literal
# "% 256 == 0", :230); tracking the static var keeps the odds provable both ways.
# Wild entities render IDENTICALLY shiny or not (FAITHFUL :230 — no overworld visual).
static func is_shiny(world_seed: int, cell: Vector2i, slot: int) -> bool:
	return _mix(world_seed, _cell_a(cell, slot), _cell_b(cell, slot), SALT_SHINY) % PokemonRules.shiny_odds == 0
# Gender from the species ratio (mirrors pokemon_rules.resolve_gender's parsing), on
# the derived stream so it is spawn-pinned, not creation-ordered.
static func gender_for(world_seed: int, cell: Vector2i, slot: int, gender_ratio: String) -> String:
	return _gender_at(world_seed, _cell_a(cell, slot), _cell_b(cell, slot), gender_ratio)
static func _gender_at(world_seed: int, a: int, b: int, gender_ratio: String) -> String:
	var ratio := gender_ratio.strip_edges().to_upper()
	if not ratio.begins_with(PokemonRules.GENDER_RATIO_PREFIX):
		return PokemonRules.GENDERLESS
	var pct := ratio.substr(PokemonRules.GENDER_RATIO_PREFIX.length()).replace("_", ".").to_float()
	if pct <= 0.0:
		return PokemonRules.GENDER_MALE
	if pct >= 100.0:
		return PokemonRules.GENDER_FEMALE
	var roll := _mix(world_seed, a, b, SALT_GENDER) % 256
	return PokemonRules.GENDER_FEMALE if roll < int(pct / 100.0 * 256.0) else PokemonRules.GENDER_MALE


# --- Roaming (player-step clock, never frame delta) ------------------------------
static func roam_every_for(species_id: String) -> int:
	return ROAM_EVERY / 2 if FAST_ROAM_IDS.has(species_id) else ROAM_EVERY
# Gated on total_steps>0 (prototype amendment): step 0 would otherwise tick before any
# player move, so crafted total_steps=0 baselines see no immediate roam.
static func should_roam(species_id: String, total_steps: int) -> bool:
	return total_steps > 0 and total_steps % roam_every_for(species_id) == 0
# Index into the runtime's candidate-neighbor list (walkable 4-neighbors, optionally
# the current tile for a "stay"); -1 on empty (mons never phase through props).
static func roam_neighbor_index(world_seed: int, cell: Vector2i, slot: int, species_id: String, total_steps: int, neighbor_count: int) -> int:
	if neighbor_count <= 0:
		return -1
	var tick := total_steps / roam_every_for(species_id)
	return _mix(world_seed, _slot_scalar(cell, slot), tick, SALT_MOVE) % neighbor_count


# --- Disposition resolution (the single editable home; DIVERGENCE #4) ------------
static func disposition_for(species_id: String, biome: String, time_of_day: String, entry: Dictionary) -> String:
	# (c) AGGRESSIVE first — biome+time-gated wiki examples are the strongest signal,
	# so a first-form ghost on SWAMP at night is aggressive, not friendly.
	var biome_set: Variant = AGGRESSIVE_BIOME_SPECIES.get(species_id, {})
	if biome_set is Dictionary and (biome_set as Dictionary).has(biome):
		return DISPOSITION_AGGRESSIVE
	if _is_night(time_of_day) and GHOST_BIOMES.has(biome) and _has_type(entry, "GHOST"):
		return DISPOSITION_AGGRESSIVE # DIVERGENCE #10: night ghosts (soil dwell ported)
	# (a) TIMID — flee-data set + wiki CHANSEY ("though not Blissey").
	if TIMID_OVERRIDE_IDS.has(species_id) or (_behavior_flag(entry, "flee") == 1 and species_id != "BLISSEY"):
		return DISPOSITION_TIMID
	# (b) FRIENDLY — first-forms (non-empty evolution list) + wiki exceptions.
	if FRIENDLY_EXCEPTION_IDS.has(species_id) or _is_first_form(entry):
		return DISPOSITION_FRIENDLY
	return DISPOSITION_IRRITABLE # (d) default: "mostly evolved Pokemon", interact-twice
# The recruitable subset == the Friendly disposition (:262, wiki-getting-started.md:65).
static func is_recruitable(species_id: String, biome: String, time_of_day: String, entry: Dictionary) -> bool:
	return disposition_for(species_id, biome, time_of_day, entry) == DISPOSITION_FRIENDLY


# --- Radius state-machine triggers (pure predicates; runtime owns the states) ----
static func manhattan(a: Vector2i, b: Vector2i) -> int:
	return absi(a.x - b.x) + absi(a.y - b.y)
static func within_manhattan(a: Vector2i, b: Vector2i, radius: int) -> bool:
	return manhattan(a, b) <= radius
static func is_spooked(entity_tile: Vector2i, player_tile: Vector2i) -> bool: # timid flee
	return within_manhattan(entity_tile, player_tile, SPOOK_RADIUS)
static func is_spotted(entity_tile: Vector2i, player_tile: Vector2i, spot_radius: int = SPOT_RADIUS) -> bool:
	return within_manhattan(entity_tile, player_tile, spot_radius)
static func chase_dropped(entity_tile: Vector2i, player_tile: Vector2i) -> bool:
	return manhattan(entity_tile, player_tile) > CHASE_RADIUS
static func is_adjacent(a: Vector2i, b: Vector2i) -> bool: # forced-battle start
	return manhattan(a, b) <= CATCH_RADIUS
# The Charm gate ("more reliably at higher levels", :254/:278) lives in field_move_runtime.gd:254
# (the single live source — `user_level >= target_level`); the calm-then-interact recruit is DIVERGENCE #6.
# The provoked buff (FAITHFUL :284): a chase-catch raises physical attack +3; a
# player-initiated Attack denies it (:280) — `provoked` carries the choice.
static func attack_stages_for(provoked: bool) -> int:
	return PROVOKED_ATTACK_STAGES if provoked else 0


# --- Egg-theft provocation (DIVERGENCE #5: parents AND egg-group sharers) --------
static func shares_egg_group(entry_a: Dictionary, entry_b: Dictionary) -> bool:
	var groups_a: Variant = entry_a.get("egg_groups", PackedStringArray())
	var groups_b: Variant = entry_b.get("egg_groups", PackedStringArray())
	if not (groups_a is PackedStringArray or groups_a is Array) or not (groups_b is PackedStringArray or groups_b is Array):
		return false
	for group in groups_a:
		var group_name := str(group)
		if group_name != "" and group_name != "UNDISCOVERED" and _contains_str(groups_b, group_name):
			return true
	return false
# A wild egg of species X was laid by an X, so same-species is the parent trigger
# (never fewer than parents, :248); egg-group sharers widen it (reconciling
# wiki-overworld-encounters.md:248 vs wiki-getting-started.md:74 toward broader).
static func is_provoked_by_egg(candidate_species_id: String, candidate_entry: Dictionary, egg_species_id: String, egg_entry: Dictionary) -> bool:
	if candidate_species_id == egg_species_id:
		return true
	return shares_egg_group(candidate_entry, egg_entry)
static func in_egg_provoke_range(entity_tile: Vector2i, egg_tile: Vector2i) -> bool:
	return within_manhattan(entity_tile, egg_tile, EGG_PROVOKE_RADIUS)


# --- Nests & Alpha guardians (DIVERGENCE #1 — NOT scrape-backed; spec § Nests) ---
# Justified against the +3-stage buff (:284) + stationary-rematch rule (:224); the
# faithful STREWN single egg stays the common case (NEST_PRESENT_PCT 3).
static func is_nest_cell(world_seed: int, cell: Vector2i, ring: int) -> bool:
	if ring < NEST_MIN_RING:
		return false
	return _mix(world_seed, cell.x, cell.y, SALT_NEST) % 100 < NEST_PRESENT_PCT
# Guardian = the cell's biome-pool species (species_index, slot 0) at band + bonus,
# forced AGGRESSIVE, sight widened — the port's first STATIONARY entity.
static func guardian_level_for(world_seed: int, cell: Vector2i, ring: int) -> int:
	return clampi(level_for(world_seed, cell, 0, ring) + ALPHA_LEVEL_BONUS, 2, 100)
static func guardian_spot_radius() -> int:
	return GUARDIAN_SPOT_RADIUS
static func nest_egg_species_index(world_seed: int, cell: Vector2i, egg_index: int, pool_size: int) -> int:
	if pool_size <= 0:
		return -1
	return _mix(world_seed, cell.x, cell.y * NEST_EGGS + egg_index, SALT_EGG) % pool_size
static func nest_egg_is_shiny(world_seed: int, cell: Vector2i, egg_index: int) -> bool:
	return _mix(world_seed, cell.x, cell.y * NEST_EGGS + egg_index, SALT_SHINY) % PokemonRules.shiny_odds == 0
static func nest_egg_gender_for(world_seed: int, cell: Vector2i, egg_index: int, gender_ratio: String) -> String:
	return _gender_at(world_seed, cell.x, cell.y * NEST_EGGS + egg_index, gender_ratio)

# --- Catalog-entry readers (pure; tolerate PackedStringArray/Array) --------------
static func _is_night(time_of_day: String) -> bool:
	return time_of_day.strip_edges().to_upper() == "NIGHT"
static func _is_first_form(entry: Dictionary) -> bool:
	var evolutions: Variant = entry.get("evolutions", [])
	return evolutions is Array and not (evolutions as Array).is_empty()
static func _has_type(entry: Dictionary, type_name: String) -> bool:
	var types: Variant = entry.get("types", PackedStringArray())
	if types is PackedStringArray:
		return (types as PackedStringArray).has(type_name)
	return (types as Array).has(type_name) if types is Array else false
static func _behavior_flag(entry: Dictionary, key: String) -> int:
	var behavior: Variant = entry.get("overworld_behavior", {})
	return int((behavior as Dictionary).get(key, 0)) if behavior is Dictionary else 0
static func _contains_str(container: Variant, value: String) -> bool:
	if container is PackedStringArray:
		return (container as PackedStringArray).has(value)
	return (container as Array).has(value) if container is Array else false
