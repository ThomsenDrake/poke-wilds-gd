extends RefCounted

# Battle-end material drops (spec: docs/product-specs/camping-crafting-survival.md).
# Pure data + rules, NO RNG: a victorious / captured type-matched Pokemon yields its
# material 100% of the time, so the crafting economy is self-sufficient without a
# determinism seam (the interim is scenario-seedable for free; see the spec). Game
# runtime grants the drop on battle victory / capture and traces material_dropped.
#
# FAITHFUL SOURCE: wiki-materials.md's per-species drop table (:463-471 and below)
# maps each species' type(s) to materials — Squirtle(WATER)->Hard Shell,
# Caterpie(BUG)->Silky Thread, Pidgey(NORMAL/FLYING)->Soft Feather, Magnemite
# (ELECTRIC/STEEL)->Magnet, Steelix(STEEL/GROUND)->Metal Coat. This interim table
# keeps ONLY the five materials a Phase 2 recipe consumes (charcoal excluded — no
# Phase 2 recipe uses it) and derives the material from the species' type, walking
# primary-then-secondary so dual-type mons match the wiki (Pidgey's Soft Feather
# comes from its secondary FLYING type). Phase 5 replaces this with faithful
# happy-Pokemon habitat drops (tech-debt-tracker.md + spec handoff retire it).
#
# WITNESS INVARIANT (load-bearing, asserted by craft_flow every run via
# crafting_runtime.drop_witness_clean): the table
# NEVER yields "log" or "hard_stone". Those are the build-loop witness materials
# (log->Cut, hard_stone->Smash); a shop / gift / battle source for either would turn
# a permitted wall-ring seal into a permanent self-trap
# (build_runtime.unwitnessed_demolish_moves). Keep this table free of both.

# Uppercase type -> lowercase bag id (every id is in pokewilds/i18n/item.properties).
const TYPE_MATERIALS := {
	"ELECTRIC": "magnet",
	"WATER": "hard_shell",
	"STEEL": "metal_coat",
	"BUG": "silky_thread",
	"FLYING": "soft_feather",
}


# The material a species drops ("" when no type maps). Walks the catalog species
# entry's "types" in primary->secondary order and returns the first mapped material,
# matching the wiki's dual-type rows. Pure function of the species entry.
static func drop_for(species_entry: Dictionary) -> String:
	var types: Variant = species_entry.get("types", PackedStringArray())
	if types is PackedStringArray or types is Array:
		for type_name in types:
			var material := str(TYPE_MATERIALS.get(str(type_name), ""))
			if not material.is_empty():
				return material
	return ""


# True when item_id is a battle-drop material. Audits use this to assert the witness
# invariant (drop materials are never log / hard_stone) without re-deriving the set.
static func is_drop_material(item_id: String) -> bool:
	return TYPE_MATERIALS.values().has(item_id)
