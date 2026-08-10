extends RefCounted

# Pure-data move-effect tables extracted from battle_rules.gd at the 320 domain
# wall (the house extract-before-edit pattern; the harvest_runtime.gd /
# party_actions.gd precedent). Lookup data ONLY lives here — every roll, gate,
# and branch stays in battle_rules.gd, which preloads this module.

const OHKO_EFFECT := "EFFECT_OHKO"
# Effects that target the user; the defender's protect never blocks them.
const SELF_TARGET_EFFECTS: PackedStringArray = ["EFFECT_HEAL", "EFFECT_PROTECT"]
# Damage effects _apply_damage_move handles inline (no status/multi-hit/stage branch).
const HANDLED_DAMAGE_EFFECTS: PackedStringArray = ["EFFECT_NORMAL_HIT", "EFFECT_ALWAYS_HIT", "EFFECT_PRIORITY_HIT", "EFFECT_FLINCH_HIT", "EFFECT_RECOIL_HIT", "EFFECT_LEECH_HIT", "EFFECT_CONFUSE_HIT", "EFFECT_TRAP_TARGET", "EFFECT_RAMPAGE", "EFFECT_FURY_CUTTER"]
const HIT_STATUS_EFFECTS := {"EFFECT_POISON_HIT": "PSN", "EFFECT_BURN_HIT": "BRN", "EFFECT_PARALYZE_HIT": "PAR", "EFFECT_SLEEP_HIT": "SLP", "EFFECT_FREEZE_HIT": "FRZ", "EFFECT_POISON_MULTI_HIT": "PSN", "EFFECT_FLAME_WHEEL": "BRN", "EFFECT_SACRED_FIRE": "BRN"}
const PURE_STATUS_EFFECTS := {"EFFECT_POISON": "PSN", "EFFECT_BURN": "BRN", "EFFECT_PARALYZE": "PAR", "EFFECT_SLEEP": "SLP"}
# Value 0 means "roll 2-5"; a positive value is a fixed hit count.
const MULTI_HIT_EFFECTS := {"EFFECT_MULTI_HIT": 0, "EFFECT_POISON_MULTI_HIT": 0, "EFFECT_DOUBLE_HIT": 2}
