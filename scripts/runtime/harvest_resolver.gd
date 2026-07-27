extends RefCounted

# Single resolver for harvest actions on a faced tile (spec sections 2-3:
# docs/superpowers/specs/2026-07-18-harvest-and-world-mutation-design.md).
# Pure functions over a tile-logic Dictionary; game_runtime.harvest_tile owns
# capability checks, override stamping, item grants, and the trace.
# Prop suffixes verified against scripts/domain/biome_defs.gd: tree1.png
# (GRASSLAND/FOREST), cactus1.png (SAVANNA/DESERT), swamp tree13.png,
# spooky/tree1.png (SNOW), and rock_small1.png (ROCK + elevation cliffs).
# BONUS DIG POOLS (Phase 5 stone acquisition; spec docs/product-specs/
# harvest-and-mutation.md): FAITHFUL only for SAND = the Beach (fresh-beach.md
# intro + "## Dig Items": Big Pearl, Water Stone, Clear Glass, Revive — the
# membership AND order below). EVERY other biome pool is a flagged port DIVERGENCE
# (the scrapes cite NO non-Beach stone source) — see DIG_BONUS_POOLS per-key flags.

const StoneEvolutionRuntime := preload("res://scripts/runtime/stone_evolution_runtime.gd") # STONE_ITEM_IDS const ONLY (same layer, never instantiated)

const TREE_PROPS := ["tree1.png", "cactus1.png", "tree13.png", "spooky/tree1.png"]
const ROCK_PROP := "rock_small1.png"
const DIG_BIOME_ITEMS := {"PLAINS": "dry_soil", "GRASSLAND": "dry_soil", "FOREST": "dry_soil", "SAVANNA": "dry_soil", "SWAMP": "dry_soil", "SAND": "dry_sand", "DESERT": "soft_sand"}
const YIELDS := {"cut": "log", "smash": "hard_stone"}

# BONUS finds on a fresh successful dig — PARALLEL to DIG_BIOME_ITEMS (the base
# material above is still yielded). PLAINS is deliberately ABSENT: documented
# dry_soil-only (keeps the harvest_flow PLAINS digs byte-identical). ice_stone /
# dawn_stone are UNASSIGNED by design: SNOW is not a diggable biome (extending
# action_for_tile's biome set is a separate slice); both stay scenarios-grant-only
# (tech-debt item 11 residual — never a bad thematic fit to paper over the gap).
const DIG_BONUS_POOLS := {
	"SAND": ["big_pearl", "water_stone", "clear_glass", "revive"], # FAITHFUL: fresh-beach.md "## Dig Items", exact wiki order
	"GRASSLAND": ["leaf_stone"], # DIVERGENCE (port-invented; faithful source = Beach pool only, fresh-beach.md)
	"FOREST": ["leaf_stone", "moon_stone"], # DIVERGENCE (moonlit canopy; uncited)
	"SAVANNA": ["fire_stone", "thunderstone"], # DIVERGENCE (dry heat + storms; uncited; thunderstone underscore-free, item.properties:83)
	"DESERT": ["sun_stone"], # DIVERGENCE (sun; uncited)
	"SWAMP": ["dusk_stone"], # DIVERGENCE (murk; uncited)
}

# One successful fresh dig on a pooled biome draws; bonus iff the draw's low bits
# gate, pool index = quotient (no correlated-modulo; pools are Arrays, order stable).
# DIVERGENCE: the RATE is invented even for the faithful Beach pool (the wiki
# documents pool membership, NO rate) — water_stone lands on ~1/32 Beach digs,
# single-stone biomes on 1/8. That ~4x gap stacked on biome commonness makes
# leaf_stone (GRASSLAND, an abundant biome) notably cheaper than the faithful
# water_stone (Beach-only): an intentional, flagged tuning stance, NOT a defect —
# DIG_BONUS_RARITY is the one-const lever if Grass stones should ever stay scarce
# (steepening it would re-pin the divergent-case hunt's landing round).
const DIG_BONUS_RARITY := 8


# The applicable harvest action, checked cut -> dig -> smash; "" when the tile
# was already mutated or has nothing harvestable.
static func action_for_tile(logic: Dictionary) -> String:
	if bool(logic.get("mutated", false)):
		return ""
	var prop := str(logic.get("prop_path", ""))
	for tree_prop in TREE_PROPS:
		if prop.ends_with(tree_prop):
			return "cut"
	if bool(logic.get("walkable", false)) and DIG_BIOME_ITEMS.has(str(logic.get("biome", ""))):
		return "dig"
	if prop.ends_with(ROCK_PROP):
		return "smash"
	return ""


static func yield_for(move_id: String, logic: Dictionary) -> String:
	if move_id == "dig":
		return str(DIG_BIOME_ITEMS.get(str(logic.get("biome", "")), ""))
	return str(YIELDS.get(move_id, ""))


# Override kind stamped for a successful action: dug ground vs cleared props.
static func kind_for(move_id: String) -> String:
	return "dug" if move_id == "dig" else "cleared"


# The bonus id a successful fresh dig found ("" on non-dig moves, unpooled biomes
# — PLAINS —, or an unrolled draw; the base yield is untouched either way). A PURE
# function of the lifetime step counter + tile coords (the habitat-drops step-counter
# precedent — NO rng, so the shared wild-encounter stream is NEVER consumed and the
# night_system determinism guarantee holds: identical input script -> identical
# bonus at every dig). `logic` is the caller's already-fetched tile dict — no
# world-gen re-read. harvest_runtime owns the grant + dig_item_found trace.
static func bonus_for(move_id: String, logic: Dictionary, tile: Vector2i, total_steps: int) -> String:
	if move_id != "dig":
		return ""
	var pool: Variant = DIG_BONUS_POOLS.get(str(logic.get("biome", "")), [])
	if not (pool is Array) or (pool as Array).is_empty():
		return ""
	var draw := _dig_draw(total_steps, tile.x, tile.y)
	if draw % DIG_BONUS_RARITY != 0:
		return ""
	return str((pool as Array)[(draw / DIG_BONUS_RARITY) % (pool as Array).size()])


# SplitMix-style integer mix over (steps, x, y): explicit constants + 63-bit masks
# (NOT engine hash() — no Godot-version drift; int64 multiply wrap is deterministic
# two's-complement, exactly as splitmix64 relies on). No dict iteration anywhere.
static func _dig_draw(steps: int, x: int, y: int) -> int:
	var h := (steps * 0x6C62272E07BB0142 + x * 0x62B821756295C58D + y * 0x4A5A6B2D0E8F3C97) & 0x7FFFFFFFFFFFFFFF
	h = ((h ^ (h >> 30)) * 0x6C62272E07BB0142) & 0x7FFFFFFFFFFFFFFF
	h = ((h ^ (h >> 27)) * 0x62B821756295C58D) & 0x7FFFFFFFFFFFFFFF
	return (h ^ (h >> 31)) & 0x7FFFFFFFFFFFFFFF


# item_name is the catalog display name of the granted yield.
static func success_message(move_id: String, item_name: String) -> String:
	match move_id:
		"cut":
			return "The tree was cut down! Got a log!"
		"smash":
			return "The rock was smashed! Got a hard stone!"
		"dig":
			return "The ground was dug up! Got %s!" % item_name
	return "Nothing happened."


# Failure wording: a constrained mon gets the personal refusal; the party-wide
# check gets the tile's block reason with the capability hint.
static func refusal_message(move_id: String, logic: Dictionary, mon_name: String) -> String:
	if not mon_name.is_empty():
		return "%s can't use that here." % mon_name
	var reason := str(logic.get("block_reason", "")).strip_edges()
	var hint := "It could be %s." % move_id.to_upper()
	return hint if reason.is_empty() else "%s %s" % [reason, hint]


# The witness_clean() pattern for the acquisition single-source mandate: every
# stone in DIG_BONUS_POOLS audited against stone_evolution_runtime.STONE_ITEM_IDS
# (preloaded for the CONST only — a second literal stone set never exists). Fails on
# hard_stone (an unrelated building material ending in "_stone"), a misspelled
# "thunder_stone" (item.properties:83 has NO underscore; the evo param is THUNDERSTONE),
# OR "log" — extending the material_drops.gd WITNESS INVARIANT (the build-loop witness
# materials log->Cut / hard_stone->Smash must never be grantable, or a permitted
# wall-ring seal becomes a permanent self-trap) over this third item-granting table.
static func stone_pool_contract_clean() -> bool:
	for pool_variant in DIG_BONUS_POOLS.values():
		for id_variant in pool_variant as Array:
			var item_id := str(id_variant)
			if item_id == "hard_stone" or item_id == "thunder_stone" or item_id == "log":
				return false
			if (item_id.ends_with("_stone") or item_id == "thunderstone") \
					and not StoneEvolutionRuntime.STONE_ITEM_IDS.has(item_id):
				return false
	return true
