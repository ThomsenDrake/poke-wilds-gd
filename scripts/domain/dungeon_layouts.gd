extends RefCounted

# Legendary dungeon dimensions — the seven hand-authored dungeon maps as CONST DATA
# (plan: legendary_dungeon_dimensions; spec: docs/product-specs/world-depth.md § Legendaries).
# The landmarks.gd _tile_for hand-authored precedent promoted to whole maps: every layout is a
# fixed ASCII grid (one char per tile, the legend below), NEVER procedural noise. This file is
# pure data — no parsing here (dungeon_maps.gd owns the parse + the cell grammar); NO
# RandomNumberGenerator / engine hash() / dict iteration / I/O anywhere.
#
# ASCII legend (each char resolves through the dungeon's THEME to a landmarks-grammar cell):
#   '#' wall (blocked, region "wall")          '~' entry floor (region "entry")
#   '.' hall floor (region "hall")             ',' hall floor, ENCOUNTERS (carries the token)
#   ';' chamber floor (region "chamber")       'S' spawn tile (region "entry"; the warp landing)
#   'E' exit warp (walkable, region "exit")    'P' legendary pedestal (walkable, "chamber")
#   'x'/'X' theme ledge, blocked (hall/chamber)   't'/'T' theme prop, blocked (hall/chamber)
#   'd'/'D' theme drift decor, walkable (hall/chamber)
# Every map: exactly one 'E' near the south edge, exactly one 'S' beside it, exactly one 'P' at
# the far end; dungeon_maps.validate_map flood-fill-proves spawn->chamber + spawn->exit.
#
# DEVIATIONS from the plan's pinned asset names (verified against the tree): braille_sheet1.png
# lives at assets/source/ (NOT tiles/), and "mewtwo_special" is a battle sprite sheet, not a
# tile — the Hidden Sanctum's presentation rides tiles/unown_portal.png instead.

const _T := "res://assets/source/tiles/"

# --- Themes (role -> texture path + refusal text) -------------------------------
# Roles: wall/floor/ledge/prop/drift/pedestal + the three refusal lines. The drift role is
# walkable decor (snow drifts in the Colossus Vault); elsewhere it aliases the floor.
const THEME_ICE := { # Frostbound Cavern (REGICE) — ice cave (plan: ice2, rock_ice2, ledges3icecave*)
	"wall": _T + "rock_ice2.png", "floor": _T + "ice2.png",
	"ledge": _T + "ledges3icecave.png", "prop": _T + "stalagmite1.png",
	"drift": _T + "ice2.png", "pedestal": _T + "pedistal1.png",
	"wall_reason": "A wall of solid ice blocks the way.",
	"ledge_reason": "A sheer ice ledge blocks the way.",
	"prop_reason": "An ice spire blocks the way.",
}
const THEME_STORM := { # Stormcell Vault (REGIELEKI) — ice cave + torch_sheet1/pedistal1 (plan)
	"wall": _T + "rock_ice2.png", "floor": _T + "ice2.png",
	"ledge": _T + "ledges3icecave.png", "prop": _T + "torch_sheet1.png",
	"drift": _T + "ice2.png", "pedestal": _T + "pedistal1.png",
	"wall_reason": "A wall of solid ice blocks the way.",
	"ledge_reason": "A sheer ice ledge blocks the way.",
	"prop_reason": "A torch burns with cold blue fire.",
}
const THEME_BASALT := { # Basalt Warren (REGIROCK) — cave1*/cave2* + rock_volcano1, ledges3volcano* (plan)
	"wall": _T + "rock_volcano1.png", "floor": _T + "cave1/cave1_floor1.png",
	"ledge": _T + "ledges3volcano.png", "prop": _T + "cave1/cave1_stone1.png",
	"drift": _T + "cave1/cave1_floor1.png", "pedestal": _T + "pedistal1.png",
	"wall_reason": "A wall of volcanic rock blocks the way.",
	"ledge_reason": "A basalt ledge blocks the way.",
	"prop_reason": "A slab of stone blocks the way.",
}
const THEME_IRON := { # Irondeep Vault (REGISTEEL) — ledges3bluecave* + cave1_stone1 (plan)
	"wall": _T + "cave1/cave1_stone1.png", "floor": _T + "cave1/cave1_floor2.png",
	"ledge": _T + "ledges3bluecave.png", "prop": _T + "ledges3bluecave_inner.png",
	"drift": _T + "cave1/cave1_floor2.png", "pedestal": _T + "pedistal1.png",
	"wall_reason": "A wall of cut stone blocks the way.",
	"ledge_reason": "A steel-blue ledge blocks the way.",
	"prop_reason": "A stone support pillar blocks the way.",
}
const THEME_CHASM := { # Dragonmaw Chasm (REGIDRAGO) — volcano ledges + lavafall_sheet1 decor (plan)
	"wall": _T + "rock_volcano1.png", "floor": _T + "cave1/cave1_floor1.png",
	"ledge": _T + "ledges3volcano.png", "prop": _T + "lavafall_sheet1.png",
	"drift": _T + "cave1/cave1_floor1.png", "pedestal": _T + "pedistal1.png",
	"wall_reason": "A wall of volcanic rock blocks the way.",
	"ledge_reason": "A basalt ledge blocks the way.",
	"prop_reason": "A cascade of lava pours down.",
}
const THEME_COLOSSUS := { # Colossus Vault (REGIGIGAS) — snow-buried ruins hall (plan: ruins walls + cave1_regipedistal1, regi_eye1)
	"wall": _T + "ruins2_wall1.png", "floor": _T + "ruins2_floor.png",
	"ledge": _T + "ruins1_pillar1.png", "prop": _T + "cave1/regi_eye1.png",
	"drift": _T + "snow4.png", "pedestal": _T + "cave1/cave1_regipedistal1.png",
	"wall_reason": "An ancient wall blocks the way.",
	"ledge_reason": "A toppled pillar blocks the way.",
	"prop_reason": "A stone eye watches, unmoving.",
}
const THEME_SANCTUM := { # Hidden Sanctum (MEWTWO) — ledges3darkcave* + unown_portal presentation (plan; mewtwo_special is a battle sheet — see header)
	"wall": _T + "ledges3darkcave.png", "floor": _T + "cave1/cave1_down1_dark.png",
	"ledge": _T + "ledges3darkcave_inner.png", "prop": _T + "unown_portal.png",
	"drift": _T + "cave1/cave1_down1_dark.png", "pedestal": _T + "unown_portal.png",
	"wall_reason": "A dark rock face blocks the way.",
	"ledge_reason": "A dark ledge blocks the way.",
	"prop_reason": "A sealed portal hums with power.",
}

# --- The seven dungeons (pinned id <-> species; grid row 0 is the NORTH edge) -----
# Tokens are footprint-scoped dormant ids (the PKMNMANSION/RUINS_* discipline: no catalog
# spawn_biomes line carries them, so they NEVER alias a biome pool port-wide).
const DUNGEONS := {
	"dungeon_regice": {
		"species": "REGICE", "name": "Frostbound Cavern", "theme": THEME_ICE,
		"grid": [
			"#############",
			"#####;P;#####",
			"#####;;;#####",
			"######.######",
			"#xx,,,.,,,xx#",
			"#,,,,,.,,,,,#",
			"#x,,x,.,x,,x#",
			"######~######",
			"######S######",
			"######E######",
		],
	},
	"dungeon_regieleki": {
		"species": "REGIELEKI", "name": "Stormcell Vault", "theme": THEME_STORM,
		"grid": [
			"###############",
			"###;TPT;#######",
			"###;;;;;#######",
			"####..#########",
			"#x,,,.,,,,,,tx#",
			"#,,,.,.,,,t,,,#",
			"#,,t...,,,,,,,#",
			"#,,,,,,.,,t,,x#",
			"#x,,,,,..,,,,,#",
			"#######~#######",
			"#######S#######",
			"#######E#######",
		],
	},
	"dungeon_regirock": {
		"species": "REGIROCK", "name": "Basalt Warren", "theme": THEME_BASALT,
		"grid": [
			"#################",
			"##;XPX;##########",
			"##;;;;;##########",
			"###;.############",
			"#x,,,.,,,,,,,,xx#",
			"#,,,.,.,,,x,,,,,#",
			"#,,x...,..,,,x,,#",
			"#,,,,,x,,,,,,,,,#",
			"#x,,,,,,.,,,x,,x#",
			"#######~S~#######",
			"########E########",
		],
	},
	"dungeon_registeel": {
		"species": "REGISTEEL", "name": "Irondeep Vault", "theme": THEME_IRON,
		"grid": [
			"###############",
			"####X;P;X######",
			"####;;;;;######",
			"#####.#########",
			"#x,,,..,,,,,,x#",
			"#,,t,,,,,,,t,,#",
			"#,,,,,...,,,,,#",
			"#,,t,,..,,,t,,#",
			"#x,,,,.~.,,,,x#",
			"#######S#######",
			"#######E#######",
		],
	},
	"dungeon_regidrago": {
		"species": "REGIDRAGO", "name": "Dragonmaw Chasm", "theme": THEME_CHASM,
		"grid": [
			"###################",
			"#####;;P;;#########",
			"#####;;;;;#########",
			"######.############",
			"#x,,,,.,,,,,,ttt,,#",
			"#,,,,,.,,,,,ttt,,,#",
			"#,,x,,.,,,,,ttt,,x#",
			"#,,,,,.,,,,,ttt,,,#",
			"#x,,,,.,,,,,ttt,,,#",
			"#,,,,,.,,,,,,,,,,,#",
			"######.############",
			"######S############",
			"######E############",
		],
	},
	"dungeon_regigigas": {
		"species": "REGIGIGAS", "name": "Colossus Vault", "theme": THEME_COLOSSUS,
		"grid": [
			"###############",
			"####X;P;X######",
			"####;;;;;######",
			"######.########",
			"#d,,t,.,,t,,d,#",
			"#,,,,,.,,,,,,,#",
			"#x,,,,.,,,,x,,#",
			"#,,,,,..~.,,,,#",
			"#d,,,,,~,,,,,d#",
			"#######S#######",
			"#######E#######",
		],
	},
	"dungeon_mewtwo": {
		"species": "MEWTWO", "name": "Hidden Sanctum", "theme": THEME_SANCTUM,
		"grid": [
			"#####################",
			"#######;TTPTT;#######",
			"#######;;;;;;;#######",
			"##########.##########",
			"#x,,,,,,,.,,,,,,,,,x#",
			"#,,,,x,,,.,,,x,,,,,,#",
			"#,,,,,,,,..,,,,,,,,,#",
			"#,,x,,,,,..,,,,,x,,,#",
			"#,,,,,,,,.,,,,,,,,,,#",
			"#,,,,x,,,.,,,x,,,,,,#",
			"#x,,,,,,,.,,,,,,,,,x#",
			"#,,,,,,,,.,,,,,,,,,,#",
			"##########~##########",
			"##########S##########",
			"##########E##########",
		],
	},
}

# --- Overworld entrance facades (5x4 cave mouths; the warp tile sits ON the anchor) ----------
# 'F' frame rock / 'M' the cave mouth (blocked) / 'W' the warp tile (walkable) / '.' approach
# floor / 'B' braille seal (blocked; the Regigigas facade ONLY — the five-tablet seal's face).
# SNOW anchors frame in ice (rock_ice2), LAVA anchors frame in volcanic rock (rock_volcano1).
const ENTRANCE_SIZE := Vector2i(5, 4)
const ENTRANCE_WARP_LOCAL := Vector2i(2, 2)
const ENTRANCE_MOUTH := _T + "cave1/cave1_entrance1.png"
const ENTRANCE_WARP := _T + "cave1/cave1_door1.png"
const ENTRANCE_BRAILLE := "res://assets/source/braille_sheet1.png" # NOT under tiles/ (header note)
const ENTRANCE_FRAME := {
	"SNOW": {"frame": _T + "rock_ice2.png", "floor": _T + "snow1.png"},
	"LAVA": {"frame": _T + "rock_volcano1.png", "floor": _T + "soot1.png"},
}
const ENTRANCE_GRID := [
	"FFFFF",
	"FFMFF",
	"F.W.F",
	"F...F",
]
const ENTRANCE_GRID_SEALED := [ # the braille seal flanks the mouth (tablet-gated dungeon)
	"FFFFF",
	"FBMBF",
	"F.W.F",
	"F...F",
]

# --- Per-dungeon curated encounter scopes (the RUINS_INNER_CURATED precedent) ----------------
# FLAGGED port curation over bare TYPE sentinels — NEVER any LegendaryPlacement.LEGENDARY_IDS
# entry. level_band floors the token-pool draws; every entrance anchors at ring >= 60 (the
# LEGENDARY_RING_MIN progression floor), so bands sit past the Ruins' 38-45 curated band and
# the Hidden Sanctum is the deepest. Every curated key must pass biome_encounters.
# is_battle_viable; the authoring gate below enforces it and dungeon_runtime defensively
# filters the live facade before drawing. A spriteless entry (UNOWN's empty folder — spec
# § Legendaries; BAGON/GOLURK ship no battle sprites either) yields no encounter, never a
# placeholder or catalog fallback. Those three are culled here, leaving single-species scopes.
const SCOPES := {
	"dungeon_regice": {"level_band": [38, 45], "curated": {"SNORUNT": [38, 45], "GLALIE": [42, 46]}},
	"dungeon_regieleki": {"level_band": [38, 45], "curated": {"ELEKID": [38, 45], "JOLTIK": [38, 45]}},
	"dungeon_regirock": {"level_band": [40, 47], "curated": {"GEODUDE": [40, 47], "LARVITAR": [40, 47]}},
	"dungeon_registeel": {"level_band": [40, 47], "curated": {"ARON": [40, 47], "BELDUM": [40, 47]}},
	"dungeon_regidrago": {"level_band": [42, 49], "curated": {"DEINO": [42, 49]}},
	"dungeon_regigigas": {"level_band": [45, 52], "curated": {"BRONZONG": [45, 52]}},
	"dungeon_mewtwo": {"level_band": [50, 58], "curated": {"SIGILYPH": [50, 58]}},
}

static func normalized_encounter_scope(dungeon_id: String) -> Dictionary:
	return normalize_encounter_scope(dungeon_id, SCOPES.get(dungeon_id, {}))
static func normalize_encounter_scope(dungeon_id: String, raw: Variant) -> Dictionary:
	if not DUNGEONS.has(dungeon_id): return {}
	var refused := {"token": dungeon_id, "extra_ids": [], "curated": {}}
	if not (raw is Dictionary): return refused
	var curated: Variant = (raw as Dictionary).get("curated", {})
	var level_band: Variant = (raw as Dictionary).get("level_band", [])
	if not (curated is Dictionary) or (curated as Dictionary).is_empty() or not _valid_level_band(level_band): return refused
	var extra_ids: Array = []
	for species_id in (curated as Dictionary):
		if not _valid_level_band((curated as Dictionary)[species_id]): return refused
		extra_ids.append(str(species_id))
	extra_ids.sort()
	return {"token": dungeon_id, "level_band": (level_band as Array).duplicate(), "extra_ids": extra_ids, "curated": (curated as Dictionary).duplicate(true)}

static func _valid_level_band(value: Variant) -> bool:
	if not (value is Array) or (value as Array).size() != 2: return false
	return (value[0] is int or value[0] is float) and (value[1] is int or value[1] is float) and int(value[0]) > 0 and int(value[1]) >= int(value[0])

# Catalog-backed authoring gate. Runtime filtering remains defensive, but every shipped
# dungeon must own a nonempty curated table whose IDs pass the shared battle-viability rule.
static func validate_encounter_scopes(species: Dictionary, is_viable: Callable) -> Dictionary:
	var out: Dictionary = {}
	var dungeon_ids: Array = DUNGEONS.keys(); dungeon_ids.sort()
	for dungeon_id in dungeon_ids:
		var issues: Array = []
		var scope := normalized_encounter_scope(str(dungeon_id))
		var curated: Dictionary = scope.get("curated", {})
		if not scope.has("level_band"):
			issues.append("encounter scope must carry valid curated and level_band fields")
		if curated.is_empty():
			issues.append("curated encounter table must not be empty")
		var ids: Array = curated.keys(); ids.sort()
		for species_id in ids:
			var sid := str(species_id)
			var entry = species.get(sid, {})
			if not (entry is Dictionary) or (entry as Dictionary).is_empty():
				issues.append("curated species is absent from the catalog: %s" % sid)
			elif not is_viable.is_valid() or not bool(is_viable.call(sid, entry)):
				issues.append("curated species is not battle-viable: %s" % sid)
		out[dungeon_id] = issues
	return out

# --- The five Braille Tablets (the regi-tablets slice; the Regigigas entrance seal) ----------
# Catch-only grant (a KO grants NOTHING); the seal reads the bag, NEVER consumes. MEWTWO +
# REGIGIGAS carry no tablet (both-outcomes-permanent — the KO re-stand valve covers exactly
# these five, keyed off this table). Bag ids are lowercase (the mansion_key precedent).
const TABLET_FOR_SPECIES := {
	"REGIROCK": "rock_tablet", "REGICE": "ice_tablet", "REGISTEEL": "steel_tablet",
	"REGIELEKI": "volt_tablet", "REGIDRAGO": "dragon_tablet",
}
const SEAL_DUNGEON := "dungeon_regigigas" # its warp refuses until all five tablets are held

# --- Per-dungeon field music (entry/exit switch; the landmark_music trace precedent) ---------
# Existing tracks under assets/source/music/, fitted per theme: the Sanctum's unown portal,
# the Regi caves, the Colossus Vault's sealed chamber (the five-tablet seal's theme).
const MUSIC := {
	"dungeon_mewtwo": "res://assets/source/music/unown1.ogg",
	"dungeon_regirock": "res://assets/source/music/relic_castle2.ogg",
	"dungeon_regice": "res://assets/source/music/union_cave.ogg",
	"dungeon_registeel": "res://assets/source/music/ambient_rumbling.ogg",
	"dungeon_regieleki": "res://assets/source/music/unown-signal1.ogg",
	"dungeon_regidrago": "res://assets/source/music/RSE_Route113-stitched.ogg",
	"dungeon_regigigas": "res://assets/source/music/sealed_chamber2.ogg",
}
