extends RefCounted

# Fishing (Phase 5; spec: docs/product-specs/breeding-shinies-drops-fishing.md).
# Pure data + rules, NO RNG — the runtime seam (fishing_runtime.gd) injects the
# shared rng so seed_for_smoke pins every cast exactly. Rod tiers are the Phase 2
# campfire recipes (recipes.gd: Old = 1 Log + 1 Silky Thread, Good = 1 Old Rod +
# 2 Metal Coat, Super = 1 Good Rod + 3 Magnet — exact wiki match); using a rod by
# water triggers a WATER encounter drawn from the tier's pool — better rod ->
# strictly better mons (each tier ADDS to the previous, never replaces).
#
# FAITHFUL ANCHOR + DOCUMENTED APPROXIMATION: only the Beach biome's fishing table
# was scraped (fresh-beach.md:63): Tentacool + Magikarp on ANY rod, Corsola + Horsea
# on Good, Qwilfish on Super. The per-biome tables for every other biome were NOT
# retrievable (firecrawl credits exhausted), so this port pins ONE global table
# anchored on that exact shape, with FIXED per-tier level bands (Old 3-7, Good 8-14,
# Super 15-22 — "better rod -> better mons" by species AND level). The wiki describes
# NO fishing minigame — the cast is a per-tier bite roll (BITE_CHANCE) straight into
# a normal wild battle; fishing_runtime traces fishing_cast (every rng-consuming
# cast) + fish_hooked (the hook-up) and game_runtime traces fish_caught on capture.
# Lure Ball (3x fished) / Dive Ball (3.5x water) bonuses arrive with Phase 8's ball
# tiers (battle_runtime's BALL_ID is hardcoded until then). Water tiles spawn NO
# encounters otherwise (biome_defs encounter=false), so fishing is purely additive.

const ROD_TIERS := {"old_rod": 1, "good_rod": 2, "super_rod": 3}

# Per-tier bite chance (pinned design constants; the wiki gives no minigame —
# better rods bite more often AND pull strictly better pools/levels).
const BITE_CHANCE := {1: 0.55, 2: 0.70, 3: 0.85}

# Cumulative species pools (each tier ADDS; every species is Beach-scraped — the
# only scraped table, fresh-beach.md:63 — the documented global approximation).
const TIER_POOLS := {
	1: ["MAGIKARP", "TENTACOOL"], # base pair (any rod)
	2: ["MAGIKARP", "TENTACOOL", "HORSEA", "CORSOLA"], # Good adds Horsea + Corsola
	3: ["MAGIKARP", "TENTACOOL", "HORSEA", "CORSOLA", "QWILFISH"], # Super adds Qwilfish
}

# Fixed per-tier level bands [low, high] (documented; better rod -> better mons).
const TIER_LEVEL_RANGE := {1: [3, 7], 2: [8, 14], 3: [15, 22]}


# The best bagged rod (highest tier with count > 0); "" without any rod.
static func best_rod(bag_counts: Dictionary) -> String:
	if int(bag_counts.get("super_rod", 0)) > 0: return "super_rod"
	if int(bag_counts.get("good_rod", 0)) > 0: return "good_rod"
	if int(bag_counts.get("old_rod", 0)) > 0: return "old_rod"
	return ""


static func tier_of(rod_id: String) -> int:
	return int(ROD_TIERS.get(rod_id.strip_edges().to_lower(), 0))


static func bite_chance(tier: int) -> float:
	return float(BITE_CHANCE.get(tier, 0.5))


# A fresh copy of the tier's cumulative pool (the table itself is const + shared).
static func pool_for(tier: int) -> Array:
	var pool: Variant = TIER_POOLS.get(tier, TIER_POOLS[1])
	return (pool as Array).duplicate() if pool is Array else []


# The tier's level band [low, high] (a fresh array; the table is const + shared).
static func level_range_for(tier: int) -> Array:
	var band: Variant = TIER_LEVEL_RANGE.get(tier, TIER_LEVEL_RANGE[1])
	return (band as Array).duplicate() if band is Array else [3, 7]


static func is_rod(item_id: String) -> bool:
	return ROD_TIERS.has(item_id.strip_edges().to_lower())
