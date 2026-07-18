extends RefCounted

# Gen VI+ type effectiveness chart (18 types, FAIRY included).
# Only non-neutral (non-1.0) matchups are listed; anything missing is neutral.
const CHART := {
	"NORMAL": {"ROCK": 0.5, "GHOST": 0.0, "STEEL": 0.5},
	"FIRE": {"FIRE": 0.5, "WATER": 0.5, "GRASS": 2.0, "ICE": 2.0, "BUG": 2.0,
		"ROCK": 0.5, "DRAGON": 0.5, "STEEL": 2.0},
	"WATER": {"FIRE": 2.0, "WATER": 0.5, "GRASS": 0.5, "GROUND": 2.0, "ROCK": 2.0,
		"DRAGON": 0.5},
	"GRASS": {"FIRE": 0.5, "WATER": 2.0, "GRASS": 0.5, "POISON": 0.5, "GROUND": 2.0,
		"FLYING": 0.5, "BUG": 0.5, "ROCK": 2.0, "DRAGON": 0.5, "STEEL": 0.5},
	"ELECTRIC": {"WATER": 2.0, "GRASS": 0.5, "ELECTRIC": 0.5, "GROUND": 0.0,
		"FLYING": 2.0, "DRAGON": 0.5},
	"ICE": {"FIRE": 0.5, "WATER": 0.5, "GRASS": 2.0, "ICE": 0.5, "GROUND": 2.0,
		"FLYING": 2.0, "DRAGON": 2.0, "STEEL": 0.5},
	"FIGHTING": {"NORMAL": 2.0, "ICE": 2.0, "POISON": 0.5, "FLYING": 0.5,
		"PSYCHIC": 0.5, "BUG": 0.5, "ROCK": 2.0, "GHOST": 0.0, "DARK": 2.0,
		"STEEL": 2.0, "FAIRY": 0.5},
	"POISON": {"GRASS": 2.0, "POISON": 0.5, "GROUND": 0.5, "ROCK": 0.5, "GHOST": 0.5,
		"STEEL": 0.0, "FAIRY": 2.0},
	"GROUND": {"FIRE": 2.0, "GRASS": 0.5, "ELECTRIC": 2.0, "POISON": 2.0, "FLYING": 0.0,
		"BUG": 0.5, "ROCK": 2.0, "STEEL": 2.0},
	"FLYING": {"GRASS": 2.0, "ELECTRIC": 0.5, "FIGHTING": 2.0, "BUG": 2.0, "ROCK": 0.5,
		"STEEL": 0.5},
	"PSYCHIC": {"FIGHTING": 2.0, "POISON": 2.0, "PSYCHIC": 0.5, "DARK": 0.0, "STEEL": 0.5},
	"BUG": {"FIRE": 0.5, "GRASS": 2.0, "FIGHTING": 0.5, "POISON": 0.5, "FLYING": 0.5,
		"PSYCHIC": 2.0, "GHOST": 0.5, "DARK": 2.0, "STEEL": 0.5, "FAIRY": 0.5},
	"ROCK": {"FIRE": 2.0, "ICE": 2.0, "FIGHTING": 0.5, "GROUND": 0.5, "FLYING": 2.0,
		"BUG": 2.0, "STEEL": 0.5},
	"GHOST": {"NORMAL": 0.0, "PSYCHIC": 2.0, "GHOST": 2.0, "DARK": 0.5},
	"DRAGON": {"DRAGON": 2.0, "STEEL": 0.5, "FAIRY": 0.0},
	"DARK": {"FIGHTING": 0.5, "PSYCHIC": 2.0, "GHOST": 2.0, "DARK": 0.5, "FAIRY": 0.5},
	"STEEL": {"FIRE": 0.5, "WATER": 0.5, "ELECTRIC": 0.5, "ICE": 2.0, "ROCK": 2.0,
		"STEEL": 0.5, "FAIRY": 2.0},
	"FAIRY": {"FIRE": 0.5, "FIGHTING": 2.0, "POISON": 0.5, "DRAGON": 2.0, "DARK": 2.0,
		"STEEL": 0.5},
}


static func is_known_type(type_id: String) -> bool:
	return CHART.has(type_id.strip_edges().to_upper())


static func effectiveness(attack_type: String, defender_types: PackedStringArray) -> float:
	var attack_row: Dictionary = CHART.get(attack_type.strip_edges().to_upper(), {})
	var multiplier = 1.0
	var seen: Array = []
	for raw_type in defender_types:
		var defender_type = str(raw_type).strip_edges().to_upper()
		if defender_type.is_empty() or seen.has(defender_type):
			continue
		seen.append(defender_type)
		multiplier *= float(attack_row.get(defender_type, 1.0))
	return multiplier
