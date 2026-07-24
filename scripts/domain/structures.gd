extends RefCounted

# Structure definitions for the building loop (spec:
# docs/product-specs/building-and-placement.md). Pure data + rules: the
# buildable structures faithful to the original PokeWilds build move, their
# per-biome material costs, occupancy, and the sprite a placed structure stamps
# onto a tile. No Godot node imports and no runtime/data/catalog dependency, so
# the domain layer (check_architecture SCRIPT_ALLOWED[domain] = {domain, core})
# stays intact; sprite paths are res:// string constants like world_generator's
# ROCK_PROP_PATH.
#
# Faithful source (Buildings / House_Building wiki, .firecrawl): Wall, Roof,
# Door, Interior Wall, Fence, Campfire, Storage Box and Bed all exist, and their
# Log+Grass / wood costs below are the wiki's (the original "Grass" secondary maps
# to the harvest slice's dry_soil yield — thatch/daub). The wiki also says Desert
# homes "require Hard Stone"; the EXACT desert quantities and the SAND inclusion are
# documented assumptions, not scraped fact (see _DESERT_SHELL). The bed's faithful
# cost (4 Log + 1 Soft Bedding) is UNBUILDABLE until Phase 2 adds the Soft Bedding
# recipe, so it is definition + occupancy + cost only.

# Buildable structure ids. The order doubles as the build-mode cycle order
# (structure_layer cycles this list); the two Phase 2-3 placeholders trail so a
# player never lands on an unbuildable entry first. TORCH is APPENDED LAST (after
# bed) so every existing build-cycle index and placement scenario stays stable.
const IDS := ["wall", "door", "roof", "partition", "fence", "campfire", "storage_box", "bed", "torch"]
# The only walkable structure: a door is the opening in a wall line that
# connects rooms (and, beside a fence, renders as a gate). Every other id is
# solid and blocks traversal.
const WALKABLE := {"door": true}

# Material costs use the lowercase bag ids the harvest slice already grants
# (session.add_item("log"/"hard_stone"/"dry_soil"); see harvest_resolver.gd).
const _DEFAULT_COSTS := {
	"wall": {"log": 1, "dry_soil": 1},
	"door": {"log": 1, "dry_soil": 1},
	"roof": {"log": 1, "dry_soil": 1},
	"partition": {"log": 1, "dry_soil": 1},
	"fence": {"log": 1, "dry_soil": 1},
	"campfire": {"log": 4, "dry_soil": 2},
	"storage_box": {"log": 2},
	"bed": {"log": 4, "soft_bedding": 1},
	# Original torch = 1 Log + 1 Grass (buildings-scrape.md:286); Grass -> dry_soil is
	# the documented Phase 1 thatch/daub mapping used across the wood costs above.
	"torch": {"log": 1, "dry_soil": 1},
}
# Desert homes require Hard Stone for the shell — SOURCED (house-building-scrape.md:
# "Most homes require Logs and Grass... with the exception of Desert homes which
# require Hard Stone"). The exact per-structure quantities below (2 hard_stone for
# wall/door/roof/partition, 1 for fence) are a DOCUMENTED ASSUMPTION — the wiki gives
# no per-structure desert counts. Campfire/box/bed keep their universal/wood costs,
# so they are absent here and fall through to _DEFAULT_COSTS.
const _DESERT_SHELL := {
	"wall": {"hard_stone": 2},
	"door": {"hard_stone": 2},
	"roof": {"hard_stone": 2},
	"partition": {"hard_stone": 2},
	"fence": {"hard_stone": 1},
}
# SAND (beach) rides the stone shell by ASSUMPTION: the wiki names only "Desert";
# there is no sourced beach-shell rule (documented deviation — see the spec).
const _DESERT_BIOMES := ["DESERT", "SAND"]

# Traversal block reasons for solid structures; walkable ids return "".
const _BLOCK_REASONS := {
	"wall": "A built wall blocks the way.",
	"door": "",
	"roof": "A built roof blocks the way.",
	"partition": "An interior wall blocks the way.",
	"fence": "A fence blocks the way.",
	"campfire": "A campfire blocks the way.",
	"storage_box": "A storage box blocks the way.",
	"bed": "A bed blocks the way.",
	"torch": "A torch blocks the way.",
}

# Sprite families per shell kind. The asset dump ships house1/house5 per-tile
# walls plus a stone ruins family; SNOW/spooky/wooded variants have no clean
# per-tile wall/roof/door set, so they fall through to the default family and
# are logged as art tech debt (per-biome completeness is Phase 1-incomplete).
const _SHELL := {
	"default": {
		"wall": "res://pokewilds/tiles/buildings/house1_middle1.png",
		"door": "res://pokewilds/tiles/buildings/house1_door1.png",
		"roof": "res://pokewilds/tiles/buildings/house1_roof_middle1.png",
	},
	"stone": {
		"wall": "res://pokewilds/tiles/ruins2_wall1.png",
		"door": "res://pokewilds/tiles/ruins2_door.png",
		"roof": "res://pokewilds/tiles/buildings/house6_roof_middle1.png",
	},
	"savanna": {
		"wall": "res://pokewilds/tiles/buildings/house5_wall1.png",
		"door": "res://pokewilds/tiles/buildings/house5_door1.png",
		"roof": "res://pokewilds/tiles/buildings/house5_roof_middle1.png",
	},
}
const _PARTITION_PATH := "res://pokewilds/tiles/buildings/building1_wall1.png"
const _CAMPFIRE_PATH := "res://pokewilds/tiles/campfire1.png"
const _FENCE_PATH := "res://pokewilds/tiles/fence1.png"
# Faithful: a door placed between two fence tiles becomes a gate. The gate art
# is a fixed sheet (not biome-skinned); runtime stamps it when door_is_gate().
const GATE_PATH := "res://pokewilds/tiles/fence1gate1.png"
const _BED_PATH := "res://pokewilds/tiles/buildings/house_bed1.png"
const _BOX_PATH := "res://pokewilds/tiles/chest1.png"
const _TORCH_PATH := "res://pokewilds/tiles/torch_sheet1.png"
# campfire1/chest1 are 2-frame sheets; one 16-wide frame is the static prop.
# campfire1 is a 32x20 sheet (two 16x20 frames): frame 0 is the unlit base the
# build loop stamps, frame 1 is the lit fire — pin both so the light layer can swap.
const _CAMPFIRE_REGION := Rect2(0, 0, 16, 20)
const _CAMPFIRE_LIT_REGION := Rect2(16, 0, 16, 20)
const _BOX_REGION := Rect2(0, 0, 16, 32)
# torch_sheet1 is a multi-frame sheet; a torch is ALWAYS lit, so the build loop
# stamps its first 16x20 frame (verified against the camping visual-sweep shot).
const _TORCH_REGION := Rect2(0, 0, 16, 20)


static func is_valid(id: String) -> bool:
	return IDS.has(id)


# Material cost for one structure in a biome; a fresh dict the caller may read
# freely (the cost tables themselves are const and shared).
static func cost_for(id: String, biome: String) -> Dictionary:
	if _DESERT_BIOMES.has(biome) and _DESERT_SHELL.has(id):
		return (_DESERT_SHELL[id] as Dictionary).duplicate()
	var base: Dictionary = _DEFAULT_COSTS.get(id, {})
	return base.duplicate()


static func is_walkable(id: String) -> bool:
	return bool(WALKABLE.get(id, false))


# The field move that demolishes a placed structure (faithful original: Cut
# refunds ALL materials built into a tile; hard-stone structures need Smash —
# here the desert/sand stone shells; dug terrain would need Dig, but no Phase-1
# structure carries a dig-only cost, so demolition is always cut or smash).
# LOAD-BEARING: every shell class carries a witness material only its move yields
# (log->cut, hard_stone->smash), so gathering the build materials forces the
# demolish capability — the escape for region enclosure the trap guard allows;
# see build_runtime.unwitnessed_demolish_moves (mechanized) and the spec note.
static func demolish_move_for(id: String, biome: String) -> String:
	return "smash" if cost_for(id, biome).has("hard_stone") else "cut"


static func block_reason(id: String) -> String:
	return str(_BLOCK_REASONS.get(id, ""))


# A door beside a fence renders as a gate (the original's fence-gate rule).
static func door_is_gate(neighbors_has_fence: bool) -> bool:
	return neighbors_has_fence


# Sprite path a placement stamps for (id, biome); gate overrides the door sheet.
# Pure function of (id, biome, gate) so the view mirror and audits agree.
static func sprite_path_for(id: String, biome: String, gate: bool = false) -> String:
	if id == "door" and gate:
		return GATE_PATH
	match id:
		"partition":
			return _PARTITION_PATH
		"campfire":
			return _CAMPFIRE_PATH
		"fence":
			return _FENCE_PATH
		"bed":
			return _BED_PATH
		"storage_box":
			return _BOX_PATH
		"torch":
			return _TORCH_PATH
		"wall", "door", "roof":
			return (_SHELL[_shell_family(biome)] as Dictionary).get(id, "")
	return ""


# Atlas region for multi-frame sheets; null means the full PNG (the default). A
# campfire shows its lit frame unless `lit` is false: apply_placement threads the
# placement entry's "lit" field through placement_is_lit, so an extinguished fire
# stamps its UNLIT base frame AND drops its glow (the light layer reads the same
# field off the placement map — sprite and light can never disagree).
static func sprite_region_for(id: String, _biome: String, _gate: bool = false, lit: bool = true) -> Variant:
	match id:
		"campfire":
			return _CAMPFIRE_LIT_REGION if lit else _CAMPFIRE_REGION
		"storage_box":
			return _BOX_REGION
		"torch":
			return _TORCH_REGION
	return null


# Placement eligibility over a tile's live logic: the tile must be open ground
# (walkable, no prop, not already carrying a placement). This forces the
# harvest -> build loop: a tree/rock tile must be cleared before it can hold a
# structure, while bare or already-cleared ground accepts one directly.
static func can_place_on(logic: Dictionary) -> bool:
	if not bool(logic.get("walkable", false)):
		return false
	if str(logic.get("prop_path", "")) != "":
		return false
	if str(logic.get("structure_id", "")) != "":
		return false
	return true


static func _shell_family(biome: String) -> String:
	if _DESERT_BIOMES.has(biome):
		return "stone"
	if biome == "SAVANNA":
		return "savanna"
	return "default"


# --- Phase 2 behavior hooks (camping / crafting; spec camping-crafting-survival) --
# Pure classification the camping / crafting / night systems read off a structure id
# or a placement entry. Definitions + costs + occupancy above are unchanged; these
# fill the Phase 1 no-behavior placeholders (campfire, bed) and the torch light prop.

# Light sources for the night model: a placed campfire (unless extinguished via a
# "lit": false entry field) or a torch (always lit) lights its surroundings.
const LIGHT_SOURCES := {"campfire": true, "torch": true}


static func is_light_source(id: String) -> bool:
	return bool(LIGHT_SOURCES.get(id, false))


# The crafting station a placed structure provides ("" for non-stations). A campfire
# is the only station in Phase 2; the value is recipes.gd's STATION_CAMPFIRE literal.
static func crafting_station_for(id: String) -> String:
	return "campfire" if id == "campfire" else ""


static func is_crafting_station(id: String) -> bool:
	return id == "campfire"


# The rest kind a placed structure offers ("" for none): a bed gives full heal +
# status cure. The sleeping bag is a BAG item (session_state STARTING_BAG), not a
# structure, so it is deliberately absent here.
static func rest_kind_for(id: String) -> String:
	return "bed" if id == "bed" else ""


# A campfire is lit unless its placement entry explicitly carries "lit": false
# (absent = lit, so Phase 1 campfire saves load as lit). A torch is always lit.
static func placement_is_lit(placement: Dictionary) -> bool:
	if str(placement.get("structure_id", "")) == "torch":
		return true
	return bool(placement.get("lit", true))
