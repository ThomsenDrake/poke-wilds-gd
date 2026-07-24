extends RefCounted

# Night-cycle support checks extracted from night_cycle_scenario.gd (exactly the
# placement_flow -> placement_flow_demolition pattern) so the host scenario stays
# under the app line budget. Owns the nocturnal-filter proof, the DayPhase /
# world_view keyframe boundary proof, the forced shadow-battle victory, and the
# trace-log event counter (has_since is boolean; the once-only retreat_blocked
# proof needs a real count). Shares the host's ctx / runner / failures so every
# broken check lands in the host's single failure report.

const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")

# The app layer may not import domain (check_architecture): the night bounds are
# PINNED here as expected values (mirror day_phase.gd); the boundary check drives
# the RUNTIME night gate (night_system.is_night, which reads day_phase under the
# hood) at the four boundary minutes, so a day_phase drift turns this red — the
# check asserts agreement between the pin, the runtime gate, and the keyframes.
const NIGHT_START := 1230
const NIGHT_END := 270

var _ctx: Dictionary = {}
var _runner = null
var _failures: Array = []


func setup(ctx: Dictionary, runner, failures: Array) -> void:
	_ctx = ctx
	_runner = runner
	_failures = failures


# Night pools add Ghost to every biome; the wiki anchor is UMBREON (Savanna,
# night-only), but UMBREON is DARK-typed and this port's SAVANNA type set never
# matches it, so the documented fallback carries the proof: the night pool
# strictly contains a Ghost-type the day pool lacks.
func check_nocturnal_filter() -> bool:
	if not _failures.is_empty():
		return false
	var runtime = _runtime()
	var species: Dictionary = runtime.catalog.species
	# Documented reach into the runtime's biome filter (the app layer may not
	# import domain; the same pattern the field_action_router uses for _world_gen).
	var night: Array = runtime._biome_encounters.filter_species_ids(species, "SAVANNA", "NIGHT").get("ids", [])
	var day: Array = runtime._biome_encounters.filter_species_ids(species, "SAVANNA", "DAY").get("ids", [])
	var umbreon_anchor: bool = night.has("UMBREON") and not day.has("UMBREON")
	var ghost_added := false
	for species_id in night:
		if day.has(species_id):
			continue
		if "GHOST" in (_runtime().catalog.get_species(str(species_id)).get("types", PackedStringArray()) as PackedStringArray):
			ghost_added = true
			break
	if not (umbreon_anchor or ghost_added):
		_failures.append("filter: SAVANNA night adds neither UMBREON nor a Ghost-type the day pool lacks")
	return umbreon_anchor or ghost_added


# The runtime night gate must flip exactly at the pinned boundary minutes (269
# night, 270 day, 1229 day, 1230 night), and the presentation keyframes must
# carry the same two bounds — three copies held in agreement mechanically.
func check_boundaries() -> bool:
	if not _failures.is_empty():
		return false
	var runtime = _runtime()
	var saved_minutes: int = runtime.session.time_of_day_minutes
	var ok := true
	for probe in [[269, true], [NIGHT_END, false], [1229, false], [NIGHT_START, true]]:
		runtime.session.time_of_day_minutes = int(probe[0])
		if runtime.night_system.is_night() != bool(probe[1]):
			ok = false
	runtime.session.time_of_day_minutes = saved_minutes
	var keyframe_minutes: Array = []
	for keyframe in _world().TIME_OF_DAY_KEYFRAMES:
		keyframe_minutes.append(int(keyframe[0]))
	ok = ok and keyframe_minutes.has(NIGHT_END) and keyframe_minutes.has(NIGHT_START)
	if not ok:
		_failures.append("boundary: night gate / pin / tint keyframes disagree at 269/270/1229/1230")
	return ok


# Enemy pinned to 1 HP, then a move ROTATION: an immune hit (NORMAL/FIGHTING
# moves never touch a Ghost, and the shadow battle IS a Ghost) leaves the enemy
# standing and the rotation advances. If no slot lands, the enemy's types are
# neutralized — a documented pin (drops read the catalog entry, never
# _enemy_mon, so it is inert to everything the scenario proves).
func finish_by_victory(cursor: int) -> void:
	var runtime = _runtime()
	_runner.refill_party_pp(runtime)
	var enemy: Dictionary = runtime.battle_runtime._enemy_mon
	enemy["current_hp"] = 1
	var result: Dictionary = {}
	var moves: Array = runtime.battle_runtime._player_mon.get("moves", [])
	for i in range(moves.size()):
		if int((moves[i] as Dictionary).get("power", 0)) > 0:
			result = runtime.perform_battle_move(i)
			if bool(result.get("finished", false)):
				break
	if not bool(result.get("finished", false)):
		enemy["types"] = PackedStringArray(["NORMAL", "NORMAL"])
		for _i in range(4):
			result = runtime.perform_battle_move(damaging_move_index(runtime.battle_runtime._player_mon))
			if bool(result.get("finished", false)):
				break
	if str(result.get("outcome", "")) != "victory":
		_failures.append("shadow: battle ended '%s', not victory" % str(result.get("outcome", "")))
	elif not _runner.trace_log_has_since("battle_finished", cursor, {"outcome": "victory"}):
		_failures.append("shadow: no battle_finished{outcome:victory} trace")


func damaging_move_index(mon: Dictionary) -> int:
	var moves: Array = mon.get("moves", [])
	for i in range(moves.size()):
		if int((moves[i] as Dictionary).get("power", 0)) > 0 and int((moves[i] as Dictionary).get("pp", 0)) > 0:
			return i
	return 0


# Trace-log event count since a cursor.
func count_since(event_name: String, from_line: int) -> int:
	var count := 0
	var file = FileAccess.open(SmokeScenarioRunner.TRACE_LOG_PATH, FileAccess.READ)
	if file == null:
		return 0
	var lines := file.get_as_text().split("\n", false)
	file.close()
	for index in range(maxi(from_line, 0), lines.size()):
		var parsed = JSON.parse_string(lines[index])
		if parsed is Dictionary and str((parsed as Dictionary).get("event", "")) == event_name:
			count += 1
	return count


func _world() -> Node: return _ctx["world"]
func _runtime() -> Node: return _ctx["runtime"]
