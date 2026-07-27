extends RefCounted

# Habitat happiness + drop tables (Phase 5; spec: docs/product-specs/
# breeding-shinies-drops-fishing.md). Pure data + rules, NO RNG and no runtime/data
# dependency (the domain layer stays intact). Two faithful tables from
# .firecrawl/wiki-habitat.md + wiki-materials.md:
#
# HABITAT TILES: a penned Pokemon is comfortable only inside a pen (Phase 1 fence
# enclosure — habitat_runtime owns detection) containing tiles matching EACH of its
# types' requirements. Dual-types need BOTH tiles (Jumpluff Grass/Flying -> tall
# grass AND trees). "Basic" ground is RECESSIVE: any other requirement overrides it,
# and it is only required when ALL of the mon's types are basic-related (Gardevoir
# Psychic/Fairy) — so every pen floor satisfies basic-only mons. FIRE accepts lava
# OR a built campfire. The Dragonite line (Water 1 egg group) prefers WATER only —
# "doesn't even require Trees for its Flying-type half". Dark contributes no
# requirement (the original wants the SECONDARY type's habitat at night, which the
# dual-type AND rule already demands; pure Dark -> basic). DOCUMENTED PLACEHOLDERS:
# GHOST (cursed soil / gravestones) and STEEL (light clay) have no tiles in this
# port yet — both fall back to basic ground until those structures land. The port
# also re-evaluates comfort periodically (habitat_runtime's tick) where the original
# holds the deposit-time check until pickup — a documented divergence that makes
# "becomes uncomfortable -> forfeits the generated drop" observable at all.
#
# DROP MATERIALS: a comfortable penned mon yields each type's material (dual-types
# drop EACH — Bulbasaur Grass/Poison -> Miracle Seed + Poison Barb; Dragon -> BOTH
# Dragon Scale + Dragon Fang), once per in-game day (habitat_runtime cadence).
# Species overrides replace or add (wiki-materials specials). Every id resolves in
# pokewilds/i18n/item.properties — moo_moo_milk excepted, which the source game
# hardcodes (pokemon_catalog.gd's RUNTIME_ITEM_SUPPLEMENTS covers it, the potion
# precedent).
#
# WITNESS INVARIANT (load-bearing, shared with material_drops.gd): the drop economy
# must NEVER yield "log" or "hard_stone" — the build loop's demolition-witness
# materials (log->Cut, hard_stone->Smash) the region-seal escape rests on
# (build_runtime.unwitnessed_demolish_moves). Faithful Rock -> Hard Stone is
# therefore WITHHELD: ROCK types contribute NO material (dual Rock/Ground mons keep
# Soft Sand) — a documented divergence until a witnessed hard_stone source design
# lands. witness_clean() mechanizes the guarantee for audits. Phase 5 acquisition
# adds ONE more flagged yield: the Steel-type cadence drop (STEEL_STONE_DROP below —
# invented; wiki-materials.md:393 documents Metal Coat ONLY). It is witness-safe by
# construction and rides habitat_runtime's day tick, never drops_for's daily path.

# Type -> acceptable habitat tags (OR within the list, AND across a mon's types).
# [] = basic-recessive (the pen floor suffices) — also the documented placeholder
# for GHOST / STEEL (no cursed soil / gravestones / light clay tiles in the port).
const TYPE_HABITATS := {
	"GRASS": ["tall_grass"],
	"FLYING": ["tree"],
	"BUG": ["flower"],
	"WATER": ["deep_water"],
	"FIRE": ["lava", "campfire"],
	"ICE": ["snow"],
	"ROCK": ["rock"],
	"GROUND": ["sand"],
	"NORMAL": [], "ELECTRIC": [], "FIGHTING": [], "POISON": [],
	"PSYCHIC": [], "FAIRY": [], "DARK": [], "DRAGON": [],
	"GHOST": [], "STEEL": []
}

# Dragonite line (Water 1 egg group): WATER only — overrides the type walk entirely.
const DRAGONITE_LINE := {"DRATINI": true, "DRAGONAIR": true, "DRAGONITE": true}

# Uppercase type -> lowercase bag ids (dual-types drop EACH list; Dragon drops
# BOTH). ROCK is deliberately EMPTY — the witness invariant withholds Hard Stone.
const TYPE_MATERIALS := {
	"BUG": ["silky_thread"], "FLYING": ["soft_feather"], "ELECTRIC": ["magnet"],
	"WATER": ["hard_shell"], "STEEL": ["metal_coat"], "FIRE": ["charcoal"],
	"NORMAL": ["manure"], "POISON": ["poison_barb"], "GROUND": ["soft_sand"],
	"GRASS": ["miracle_seed"], "FAIRY": ["stardust"], "FIGHTING": ["binding_band"],
	"ROCK": [], "PSYCHIC": ["psi_energy"], "DARK": ["dark_energy"],
	"GHOST": ["life_force"], "ICE": ["nevermeltice"],
	"DRAGON": ["dragon_scale", "dragon_fang"]
}

# DIVERGENCE (port-invented, uncited): a happy comfortable Steel-type mon yields ONE
# shiny_stone on a cadence ABOVE its daily materials (habitat_runtime._day_tick's
# second gate — NEVER drops_for's daily path; TYPE_MATERIALS["STEEL"] stays exactly
# [metal_coat]). wiki-materials.md:393 documents Steel drops as Metal Coat ONLY;
# exec plan pokewilds-feature-completion.md:149 ("Steel-type drops") is the uncited
# design intent; BOTH the stone choice (gleaming-metal stone) and the cadence are
# invented. Witness-safe by construction (shiny_stone is neither log nor hard_stone).
# ice_stone / dawn_stone stay acquisition-less (tech-debt item 11 residual).
const STEEL_STONE_DROP := "shiny_stone"
const STEEL_STONE_CADENCE := 4 # one stone per >= 4 in-game-day window (same happy/comfortable gate)

# Species-override drops (wiki-materials specials + Miltank milk): "replace"
# supersedes the type walk; "add" appends (Star Piece ADDS to Staryu's type drops).
# Beedrill "only drop Honey" per pokewilds-getting-started.md; the Combee/Cutiefly
# lines are the other Honey sources. The Regis + Mewtwo + Unown yield Ancientpowder.
const SPECIES_OVERRIDES := {
	"COMBEE": {"replace": ["honey"]}, "VESPIQUEN": {"replace": ["honey"]},
	"CUTIEFLY": {"replace": ["honey"]}, "RIBOMBEE": {"replace": ["honey"]},
	"BEEDRILL": {"replace": ["honey"]},
	"MAREEP": {"replace": ["soft_wool"]}, "FLAAFFY": {"replace": ["soft_wool"]},
	"AMPHAROS": {"replace": ["soft_wool"]},
	"STARYU": {"add": ["star_piece"]}, "STARMIE": {"add": ["star_piece"]},
	"SHUCKLE": {"replace": ["berry_juice"]},
	"UNOWN": {"replace": ["ancientpowder"]}, "MEWTWO": {"add": ["ancientpowder"]},
	"REGIROCK": {"add": ["ancientpowder"]}, "REGICE": {"add": ["ancientpowder"]},
	"REGISTEEL": {"add": ["ancientpowder"]},
	"MILTANK": {"replace": ["moo_moo_milk"]}
}


# The habitat tags one tile provides (read off a world_generator.get_tile_logic
# dict). Tree props (biome_defs' tree1 / swamp tree13 / spooky tree1 suffixes) are
# FLYING; flower1 is BUG; tall_grass_path is GRASS; the WATER biome (the surf gate)
# is deep water; the LAVA biome or a lava prop is FIRE, as is a built campfire; the
# SNOW biome is ICE; the ROCK biome or natural rock props are ROCK; SAND/DESERT are
# GROUND; walkable non-water ground carries "basic" (the recessive floor tag).
static func tile_habitat_tags(logic: Dictionary) -> Array:
	var tags: Array = []
	var biome := str(logic.get("biome", ""))
	var prop := str(logic.get("prop_path", ""))
	if str(logic.get("tall_grass_path", "")) != "": tags.append("tall_grass")
	if prop.ends_with("tree1.png") or prop.ends_with("tree13.png"): tags.append("tree")
	if prop.ends_with("flower1.png"): tags.append("flower")
	if biome == "WATER": tags.append("deep_water")
	if biome == "LAVA" or prop.ends_with("lava_sheet1.png"): tags.append("lava")
	if biome == "SNOW": tags.append("snow")
	if biome == "ROCK" or prop.ends_with("rock_small1.png") or prop.ends_with("rock1.png"): tags.append("rock")
	if biome == "SAND" or biome == "DESERT": tags.append("sand")
	if str(logic.get("structure_id", "")) == "campfire": tags.append("campfire")
	if bool(logic.get("walkable", false)) and biome != "WATER": tags.append("basic")
	return tags


# Habitat tags over a region PLUS its one-tile 4-neighbor ring (deduped): solid
# props (trees) and unwalkable biomes (water / lava) are never interior tiles —
# the ring catches them. ONE scan shared by drops (habitat_runtime) AND the
# breeding lay gate (breeding_runtime): drops-comfortable ⟺ lay-gate passes.
static func pen_habitat_tags(tiles: Array, get_tile_logic: Callable) -> Dictionary:
	var tags: Dictionary = {}
	var scanned: Dictionary = {}
	for tile_variant in tiles:
		var tile: Vector2i = tile_variant
		for candidate in [tile, tile + Vector2i.UP, tile + Vector2i.DOWN, tile + Vector2i.LEFT, tile + Vector2i.RIGHT]:
			if scanned.has(candidate):
				continue
			scanned[candidate] = true
			for tag in tile_habitat_tags(get_tile_logic.call(candidate)):
				tags[str(tag)] = true
	return tags


# True when tag_set covers every type requirement of the species (dual-types need
# ALL; the recessive basic rule falls out of the empty basic requirements).
static func types_satisfied(types: Variant, species_id: String, tag_set: Dictionary) -> bool:
	if DRAGONITE_LINE.has(species_id.strip_edges().to_upper()):
		return tag_set.has("deep_water")
	if types is PackedStringArray or types is Array:
		for type_variant in types:
			var required: Array = TYPE_HABITATS.get(str(type_variant), [])
			if required.is_empty():
				continue
			var met := false
			for tag in required:
				if tag_set.has(str(tag)):
					met = true
					break
			if not met:
				return false
	return true


# The bag ids a comfortable mon of this species yields per drop day (may be empty —
# pure Rock types drop nothing in the port; witness invariant). Type walk in
# primary->secondary order, then the species override (replace OR add).
static func drops_for(species_entry: Dictionary) -> Array:
	var species_id := str(species_entry.get("species_id", "")).strip_edges().to_upper()
	var override: Variant = SPECIES_OVERRIDES.get(species_id, {})
	if override is Dictionary and (override as Dictionary).has("replace"):
		return _as_id_array((override as Dictionary)["replace"])
	var materials: Array = []
	var types: Variant = species_entry.get("types", PackedStringArray())
	if types is PackedStringArray or types is Array:
		for type_variant in types:
			for item_variant in TYPE_MATERIALS.get(str(type_variant), []):
				if not materials.has(str(item_variant)):
					materials.append(str(item_variant))
	if override is Dictionary and (override as Dictionary).has("add"):
		for item_variant in (override as Dictionary)["add"]:
			if not materials.has(str(item_variant)):
				materials.append(str(item_variant))
	return materials


# True when a Steel-type's cadence window has elapsed since its last stone (pure
# function of species types + day index + last stone day — NO rng, NO clock; the
# night_system determinism guarantee, extended). DIVERGENCE gate: STEEL_STONE_DROP.
static func steel_stone_due(species_entry: Dictionary, day: int, last_stone_day: int) -> bool:
	var types: Variant = species_entry.get("types", PackedStringArray())
	if types is PackedStringArray or types is Array:
		for type_variant in types:
			if str(type_variant) == "STEEL":
				return day - last_stone_day >= STEEL_STONE_CADENCE
	return false


# True when item_id can come from the habitat drop economy (type table, a species
# override, or the Steel cadence drop — audit honesty: the yieldable set is complete).
# Audits assert the witness invariant through witness_clean() without
# re-deriving the full set.
static func is_habitat_drop_material(item_id: String) -> bool:
	if item_id == STEEL_STONE_DROP:
		return true
	for item_ids in TYPE_MATERIALS.values():
		if (item_ids as Array).has(item_id):
			return true
	for override in SPECIES_OVERRIDES.values():
		for key in ["replace", "add"]:
			if (override as Dictionary).has(key) and _as_id_array((override as Dictionary)[key]).has(item_id):
				return true
	return false


# The shared witness guarantee (material_drops.gd WITNESS INVARIANT): the habitat
# drop economy never yields log / hard_stone, so a permitted region-scale enclosure
# keeps its demolition escape (build_runtime.unwitnessed_demolish_moves).
static func witness_clean() -> bool:
	return not is_habitat_drop_material("log") and not is_habitat_drop_material("hard_stone")


static func _as_id_array(raw: Variant) -> Array:
	var ids: Array = []
	if raw is Array:
		for item_variant in raw:
			ids.append(str(item_variant))
	return ids
