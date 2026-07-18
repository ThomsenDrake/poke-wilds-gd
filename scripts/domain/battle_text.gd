extends RefCounted

# Formats human-readable battle text from structured execute_attack results.
const STATUS_INFLICTION_TEXT := {
	"BRN": "was burned",
	"PSN": "was poisoned",
	"PAR": "was paralyzed",
	"SLP": "fell asleep",
	"FRZ": "was frozen solid",
}
const STAT_DISPLAY_TEXT := {
	"atk": "Attack", "def": "Defense", "sat": "Sp. Atk", "sdf": "Sp. Def",
	"spe": "Speed", "accuracy": "accuracy", "evasion": "evasion",
}
# Result flags that mean something visible happened even without damage.
const OUTCOME_FLAGS: PackedStringArray = ["confused", "infatuated", "trapped", "protected",
	"self_confused", "ohko"]


static func describe_status_infliction(status: String) -> String:
	return str(STATUS_INFLICTION_TEXT.get(status, "was afflicted"))


static func describe_stat(stat_key: String) -> String:
	return str(STAT_DISPLAY_TEXT.get(stat_key, stat_key))


static func blocked_line(attacker_name: String, status: String) -> String:
	match status:
		"PAR":
			return "%s is fully paralyzed!" % attacker_name
		"SLP":
			return "%s is fast asleep!" % attacker_name
		"FRZ":
			return "%s is frozen solid!" % attacker_name
		"INFATUATION":
			return "%s is immobilized by love!" % attacker_name
	return "%s couldn't move!" % attacker_name


static func stat_change_line(change: Dictionary, attacker_name: String, defender_name: String) -> String:
	var target_name = attacker_name if str(change.get("target", "")) == "attacker" else defender_name
	var stat_name = describe_stat(str(change.get("stat", "")))
	var delta = int(change.get("delta_applied", 0))
	if delta == 0:
		var direction = "higher" if int(change.get("stages", 0)) > 0 else "lower"
		return "%s's %s won't go %s!" % [target_name, stat_name, direction]
	var adverb = "sharply " if absi(delta) >= 2 else ""
	if delta > 0:
		return "%s's %s %srose!" % [target_name, stat_name, adverb]
	return "%s's %s %sfell!" % [target_name, stat_name, adverb]


static func attack_message(result: Dictionary, attacker_name: String, defender_name: String, move_name: String) -> String:
	var lines: Array = []
	if bool(result.get("woke_up", false)):
		lines.append("%s woke up!" % attacker_name)
	if bool(result.get("thawed", false)):
		lines.append("%s thawed out!" % attacker_name)
	if bool(result.get("snapped_out", false)):
		lines.append("%s snapped out of its confusion!" % attacker_name)
	var blocked = str(result.get("blocked_by", ""))
	if not blocked.is_empty():
		lines.append(blocked_line(attacker_name, blocked))
		return "\n".join(lines)
	if bool(result.get("hurt_itself", false)):
		lines.append("%s is confused!" % attacker_name)
		lines.append("It hurt itself in its confusion!")
		if bool(result.get("self_fainted", false)):
			lines.append("%s fainted!" % attacker_name)
		return "\n".join(lines)

	lines.append("%s used %s!" % [attacker_name, move_name])
	if bool(result.get("protected_target", false)):
		lines.append("%s protected itself!" % defender_name)
		return "\n".join(lines)
	if not bool(result.get("hit", false)):
		lines.append("But it missed!")
		return "\n".join(lines)

	var damage = int(result.get("damage", 0))
	var effectiveness = float(result.get("effectiveness", 1.0))
	if effectiveness <= 0.0:
		lines.append("It doesn't affect %s..." % defender_name)
	elif damage > 0:
		if bool(result.get("critical", false)):
			lines.append("Critical hit!")
		if effectiveness > 1.0:
			lines.append("It's super effective!")
		elif effectiveness < 1.0:
			lines.append("It's not very effective...")
		lines.append("%s took %d damage." % [defender_name, damage])
		if bool(result.get("ohko", false)):
			lines.append("It's a one-hit KO!")
		var hits = int(result.get("hits", 1))
		if hits > 1:
			lines.append("Hit %d times!" % hits)

	var status_applied = str(result.get("status_applied", ""))
	if not status_applied.is_empty():
		lines.append("%s %s!" % [defender_name, describe_status_infliction(status_applied)])
	if bool(result.get("confused", false)):
		lines.append("%s became confused!" % defender_name)
	if bool(result.get("infatuated", false)):
		lines.append("%s fell in love with %s!" % [defender_name, attacker_name])
	if bool(result.get("trapped", false)):
		lines.append("%s is trapped!" % defender_name)
	if not str(result.get("encored", "")).is_empty():
		lines.append("%s received an encore!" % defender_name)
	if bool(result.get("flinched", false)):
		lines.append("%s flinched!" % defender_name)
	for change_variant in result.get("stat_changes", []):
		if change_variant is Dictionary:
			lines.append(stat_change_line(change_variant, attacker_name, defender_name))
	if int(result.get("restored", 0)) > 0:
		lines.append("%s regained health!" % attacker_name)
	if int(result.get("healed", 0)) > 0:
		lines.append("%s absorbed some HP!" % attacker_name)
	if int(result.get("recoil", 0)) > 0:
		lines.append("%s is hit with recoil!" % attacker_name)
	if bool(result.get("protected", false)):
		lines.append("%s protected itself!" % attacker_name)
	if bool(result.get("self_confused", false)):
		lines.append("%s became confused due to fatigue!" % attacker_name)
	if bool(result.get("failed", false)):
		lines.append("But it failed!")
	elif _nothing_happened(result, damage, status_applied, effectiveness):
		lines.append("But nothing happened.")
	if bool(result.get("fainted", false)):
		lines.append("%s fainted!" % defender_name)
	return "\n".join(lines)


static func _nothing_happened(result: Dictionary, damage: int, status_applied: String, effectiveness: float) -> bool:
	if damage > 0 or not status_applied.is_empty() or effectiveness <= 0.0:
		return false
	if not (result.get("stat_changes", []) as Array).is_empty():
		return false
	if int(result.get("restored", 0)) > 0 or not str(result.get("encored", "")).is_empty():
		return false
	for flag in OUTCOME_FLAGS:
		if bool(result.get(flag, false)):
			return false
	return true
