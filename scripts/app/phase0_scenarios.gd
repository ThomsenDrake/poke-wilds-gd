extends Node

# Phase-0 defect-fix scenarios (qa_scenarios pattern) inside the runner's save
# backup/restore guard. wild_battle lives in wild_battle_scenario.gd (extracted for the
# v4 fixture work + the app line budget). save_migration: v1/v2->v3->v4->v5 migration —
# v3 "structures" (contents-less box backfills empty), v4 "contents" (corrupt -> empty
# box) + "pastures" (penless pasture RELOCATES mons to the campsite hold — habitat
# sub-dict intact, ground egg lost warned, garbage degrades, party egg survives load),
# v5 chain identity + per-world chained_worlds round-trip (non-trivial: active "0,-1",
# origin entry byte-identical — fence + pastures + campsite + Mansion puzzle state) +
# the two pinned byte witnesses (golden delta EXACTLY the three identity keys; relocation + argument purity), future refusal, corrupt recovery.

const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")
const SaveStore := preload("res://scripts/runtime/save_store.gd")
const WildBattleScenario := preload("res://scripts/app/wild_battle_scenario.gd")
const SessionState := preload("res://scripts/runtime/session_state.gd")
# Domain access rides the runtime's own preload (app may not preload domain — check_architecture.gd's layer table; the landmark_flow precedent).
const SaveMigration := SessionState.SaveMigration
const GOLDEN_PATH := "res://docs/generated/golden-saves/v4_golden.json" # v4 migration witness (shared with save_stability)

const SCENARIOS := {"wild_battle": "run_wild_battle", "save_migration": "run_save_migration"}
const MIGRATION_MON := {"species_id": "CHIKORITA", "name": "Chikorita", "level": 5, "exp": 125,
	"max_hp": 20, "current_hp": 20, "status": "PSN", "sleep_turns": 2,
	"moves": [{"move_id": "TACKLE", "pp": 35, "max_pp": 35, "power": 40}]}
# Penned mon with the full habitat sub-dict the Steel-stone cadence rides; the fixture pen has NO fence ring, so load relocates it to the campsite hold.
const PASTURE_MON := {"species_id": "EEVEE", "name": "Eevee", "level": 30, "exp": 0,
	"max_hp": 30, "current_hp": 30, "status": "", "sleep_turns": 2, "happiness": 220,
	"moves": [{"move_id": "TACKLE", "pp": 35, "max_pp": 35, "power": 40}],
	"habitat": {"satisfied": true, "last_drop_day": 3, "last_stone_day": 1}}
# Additive party-egg shape (Breeding.build_egg): max_hp/current_hp 0; the nested payload carries the child — normalize_loaded_mon passes it by shape.
const MIGRATION_EGG := {"species_id": "EGG", "name": "Egg", "level": 5, "exp": 0,
	"max_hp": 0, "current_hp": 0, "status": "", "sleep_turns": 0, "moves": [],
	"is_shiny": false, "is_egg": true,
	"egg": {"species_id": "EEVEE", "gender": "female", "is_shiny": false, "moves": ["TACKLE"], "steps_to_hatch": 2560}}
const MIGRATION_FIXTURES := [
	{"version": 1, "world_seed": 1234, "player_x": 3, "player_y": 4, "party": [MIGRATION_MON], "bag": {"pokeball": 5},
		"time_of_day_minutes": 700, "total_steps": 10, "unlocked_field_moves": {"cut": 1}},
	{"version": 2, "world_seed": 1234, "player_x": 5, "player_y": 6, "party": [MIGRATION_MON], "bag": {"poke_ball": 2, "potion": 1},
		"time_of_day_minutes": 800, "total_steps": 20, "unlocked_field_moves": {"surf": 1}},
	{"version": 3, "world_seed": 1234, "player_x": 3, "player_y": 4, "party": [MIGRATION_MON], "bag": {"poke_ball": 2},
		"time_of_day_minutes": 600, "total_steps": 0, "campsite_x": 5, "campsite_y": 2, "campsite_pokemon": [MIGRATION_MON],
		"structures": {"10,10": {"kind": "placed", "structure_id": "wall", "by": "build", "step": 0},
		"11,10": {"kind": "placed", "structure_id": "door", "by": "build", "step": 0},
		"12,10": {"kind": "placed", "structure_id": "storage_box", "by": "build", "step": 0}}},
	# v4 is PURELY additive over v3: a storage_box may carry "contents" (absent = empty;
	# 13,10's corrupt "garbage" normalizes to an empty box, never a crash) + "pastures"
	# (8,8 has NO fence ring: its mon RELOCATES to the campsite hold — habitat intact,
	# ground egg lost warned; 9,9 garbage degrades; a party egg survives the normalize).
	{"version": 4, "world_seed": 1234, "player_x": 3, "player_y": 4, "party": [MIGRATION_MON, MIGRATION_EGG], "bag": {"poke_ball": 2},
		"time_of_day_minutes": 600, "total_steps": 0, "campsite_x": 3, "campsite_y": 4, "campsite_pokemon": [],
		"structures": {"10,10": {"kind": "placed", "structure_id": "wall", "by": "build", "step": 0},
		"12,10": {"kind": "placed", "structure_id": "storage_box", "by": "build", "step": 0, "contents": [MIGRATION_MON]},
		"13,10": {"kind": "placed", "structure_id": "storage_box", "by": "build", "step": 0, "contents": "garbage"}},
		"pastures": {"8,8": {"anchor": [8, 8], "mons": [PASTURE_MON], "eggs": [{"tile": [8, 9], "egg": MIGRATION_EGG}]},
		"9,9": "garbage"}},
	# v5 (Phase 7 Build 3): pinned NON-TRIVIAL — the ACTIVE world is the chained "0,-1"
	# (root_seed set) and the NON-active origin "0,0" entry carries a fence structures
	# row + a pastures row + a campsite pair + a Mansion landmark_state row, proving
	# non-empty per-world data (puzzle state INCLUDED) lands byte-identical on session.chained_worlds.
	{"version": 5, "world_seed": 4242, "root_seed": 835143192, "active_chain": "0,-1",
		"player_x": 7, "player_y": 8, "party": [MIGRATION_MON], "bag": {"poke_ball": 3},
		"time_of_day_minutes": 600, "total_steps": 0, "campsite_x": 7, "campsite_y": 8,
		"campsite_pokemon": [], "structures": {}, "pastures": {},
		"chained_worlds": {"0,0": {
			"structures": {"30,40": {"kind": "placed", "structure_id": "fence", "by": "build", "step": 0}},
			"pastures": {"31,40": {"anchor": [31, 40], "mons": [PASTURE_MON], "eggs": []}},
			"campsite_x": 12, "campsite_y": 14,
			"landmark_state": {"pkmn_mansion": {"statues": [true, true, true], "unlocked": true, "key_taken": false}}}}},
]

static func handles(scenario: String) -> bool:
	return SCENARIOS.has(scenario)

static func run(scenario: String, host: Node, ctx: Dictionary) -> void:
	var node: Node = (load("res://scripts/app/phase0_scenarios.gd") as Script).new()
	host.add_child(node)
	await node.call(SCENARIOS[scenario], ctx, host)

func run_wild_battle(ctx: Dictionary, host: Node) -> void:
	var node: Node = WildBattleScenario.new()
	host.add_child(node) # the scenario reaches the host's _run_smoke_battle via get_parent()
	await node.run(ctx)

func run_save_migration(ctx: Dictionary, host: Node) -> void:
	await host.get_tree().create_timer(0.2).timeout
	var runtime: Node = ctx["runtime"]
	var runner := SmokeScenarioRunner.new()
	var checks := 0
	var fail := ""
	var cursor := runner.trace_log_line_count()
	var checkers := [Callable(self, "_v1_fields_ok"), Callable(self, "_v2_fields_ok"), Callable(self, "_v3_fields_ok"), Callable(self, "_v4_fields_ok"), Callable(self, "_v5_fields_ok")]
	var v_ok := [false, false, false, false, false]
	for i in range(MIGRATION_FIXTURES.size()):
		if not fail.is_empty():
			break
		_write_fixture(MIGRATION_FIXTURES[i])
		var payload: Dictionary = runtime.save_store.load_payload()
		v_ok[i] = not payload.is_empty() and runtime._apply_loaded_payload(payload) and checkers[i].call(runtime)
		if v_ok[i]:
			checks += 1
		else:
			fail = "v%d fixture did not migrate" % (i + 1)
	# Future version: refused, preserved to .newer.bak + warning traced, so the autosave can't clobber the newer save.
	var future_refused := false
	if fail.is_empty():
		_write_fixture({"version": 99, "party": [MIGRATION_MON]})
		var refused: Dictionary = runtime.save_store.load_payload()
		var kept_text := ""
		var kept_file = FileAccess.open(SaveStore.SAVE_PATH + ".newer.bak", FileAccess.READ)
		if kept_file != null:
			kept_text = kept_file.get_as_text()
			kept_file.close()
		var kept = JSON.parse_string(kept_text)
		var kept_version := int(kept.get("version", 0)) if kept is Dictionary else 0
		future_refused = refused.is_empty() and kept_version == 99 \
			and runner.trace_log_has_since("warning", cursor, {"found_version": 99})
		if future_refused:
			checks += 1
		else:
			fail = "future version was not refused non-destructively"
	if fail.is_empty():
		fail = runner.assert_save_recovery(runtime, cursor)
	_cleanup_fixtures()
	if fail.is_empty():
		runtime.emit_trace("save_migration_passed", "SmokeScenarios", {
			"v1_ok": v_ok[0], "v2_ok": v_ok[1], "v3_ok": v_ok[2], "v4_ok": v_ok[3], "v5_ok": v_ok[4], "future_refused": future_refused, "checks": checks})
	else:
		push_error("Save migration scenario failed: %s" % fail)

func _v1_fields_ok(runtime) -> bool:
	var session = runtime.session
	var mon: Dictionary = session.get_party_member(0)
	var stats: Dictionary = mon.get("stats", {})
	return int(session.world_seed) == 1234 and session.player_tile == Vector2i(3, 4) and int(session.bag.get("poke_ball", 0)) == 5 \
		and not session.bag.has("pokeball") and session.get_unlocked_field_moves().is_empty() and int(session.time_of_day_minutes) == 700 \
		and int(session.total_steps) == 10 and str(mon.get("species_id", "")) == "CHIKORITA" and str(mon.get("status", "")) == "PSN" \
		and int(mon.get("sleep_turns", -1)) == 0 and int(mon.get("level", 0)) == 5 and int(stats.get("hp", 0)) == 20 \
		and session.campsite_count() == 0 and session.campsite_tile == session.player_tile and session.get_structures().is_empty()

func _v2_fields_ok(runtime) -> bool:
	var session = runtime.session
	return session.player_tile == Vector2i(5, 6) and int(session.bag.get("poke_ball", 0)) == 2 \
		and int(session.bag.get("potion", 0)) == 1 and session.get_unlocked_field_moves().is_empty() \
		and int(session.time_of_day_minutes) == 800 and int(session.total_steps) == 20 \
		and session.campsite_count() == 0 and session.campsite_tile == session.player_tile \
		and runtime.mutations_for_view().is_empty() and session.get_structures().is_empty()

# v3-additive "structures" round-trips into the placement map (a structures-less
# save backfills to {}, asserted above). A contents-less storage_box backfills to
# an EMPTY box (absent = empty), and the v3 campsite hold keys load intact.
func _v3_fields_ok(runtime) -> bool:
	var session = runtime.session
	var placed: Dictionary = runtime._world_gen.placements_for_save()
	return str(placed.get("10,10", {}).get("structure_id", "")) == "wall" \
		and str(placed.get("11,10", {}).get("structure_id", "")) == "door" \
		and str(placed.get("12,10", {}).get("structure_id", "")) == "storage_box" \
		and (placed.get("12,10", {}).get("contents", []) as Array).is_empty() \
		and session.get_structures().size() == 3 and session.campsite_count() == 1 \
		and session.campsite_tile == Vector2i(5, 2) \
		and str(session.get_campsite_pokemon()[0].get("species_id", "")) == "CHIKORITA"

# v4-additive "contents" round-trips on the placement entry: 12,10 keeps its one
# mon (normalized — sleep_turns cleared, status kept, exactly like the party),
# while 13,10's corrupt "garbage" contents degrade to an empty box, never a crash.
# v4-additive "pastures": the fenceless 8,8 pen RELOCATES its EEVEE to the
# campsite hold (never lost; habitat {satisfied, last_drop_day, last_stone_day}
# intact; sleep_turns cleared by the same normalize as party mons), its ground
# egg is dropped (warning-tier, asserted by the empty pasture map), and 9,9's
# garbage entry degrades to nothing; the party egg survives the load normalize.
func _v4_fields_ok(runtime) -> bool:
	var session = runtime.session
	var placed: Dictionary = runtime._world_gen.placements_for_save()
	var contents: Array = placed.get("12,10", {}).get("contents", [])
	var mon: Dictionary = contents[0] if contents.size() == 1 else {}
	var garbage: Array = placed.get("13,10", {}).get("contents", ["sentinel"])
	var held: Dictionary = session.get_campsite_pokemon()[0] if session.campsite_count() == 1 else {}
	var habitat: Dictionary = held.get("habitat", {})
	var egg: Dictionary = session.party[1] if session.party.size() > 1 else {}
	var egg_payload: Dictionary = egg.get("egg", {})
	return str(placed.get("10,10", {}).get("structure_id", "")) == "wall" \
		and str(mon.get("species_id", "")) == "CHIKORITA" and str(mon.get("status", "")) == "PSN" \
		and int(mon.get("sleep_turns", -1)) == 0 and int(mon.get("level", 0)) == 5 \
		and int(mon.get("max_hp", 0)) == 20 and garbage.is_empty() \
		and session.get_structures().size() == 3 and session.campsite_count() == 1 \
		and str(held.get("species_id", "")) == "EEVEE" and int(held.get("sleep_turns", -1)) == 0 \
		and bool(habitat.get("satisfied", false)) and int(habitat.get("last_drop_day", -1)) == 3 \
		and int(habitat.get("last_stone_day", -1)) == 1 and session.pastures.is_empty() \
		and bool(egg.get("is_egg", false)) and str(egg_payload.get("species_id", "")) == "EEVEE" \
		and int(egg_payload.get("steps_to_hatch", 0)) == 2560 \
		and int(session.bag.get("poke_ball", 0)) == 2 and session.player_tile == Vector2i(3, 4)

# v5 (Phase 7 Build 3): chain identity applied to the session + chained_worlds retained
# BYTE-IDENTICAL (the accessor world_chain_runtime deserializes from) + save_migration's
# two pinned byte witnesses green (golden delta EXACTLY the three identity keys; relocation byte-verbatim + migrate() never mutates its argument).
func _v5_fields_ok(runtime) -> bool:
	var session = runtime.session
	if int(session.world_seed) != 4242 or int(session.root_seed) != 835143192 or str(session.active_chain) != "0,-1":
		return false
	# BYTE-IDENTICAL retention, deep compared on the JSON canonical of BOTH sides:
	# JSON.parse yields every number as float while the pinned fixture const carries ints,
	# and Godot 4.6's recursive Dictionary == refuses the type MIX (12.0 == 12 holds
	# scalar, fails nested) — one stringify round normalizes both to floats.
	var expected_canon: Variant = JSON.parse_string(JSON.stringify(MIGRATION_FIXTURES[4]["chained_worlds"]))
	if JSON.parse_string(JSON.stringify(session.chained_worlds)) != expected_canon:
		return false
	var golden: Variant = JSON.parse_string(FileAccess.get_file_as_string(GOLDEN_PATH))
	return golden is Dictionary and SaveMigration.byte_witness_issues(golden as Dictionary, SessionState.SAVE_VERSION).is_empty()

func _write_fixture(payload: Dictionary) -> void:
	var file = FileAccess.open(SaveStore.SAVE_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(payload))
		file.close()

func _cleanup_fixtures() -> void:
	for suffix in [".newer.bak", ".corrupt.bak", SaveStore.TMP_SUFFIX]:
		var path: String = SaveStore.SAVE_PATH + str(suffix)
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
