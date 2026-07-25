extends Node

# Phase-0 defect-fix scenarios (qa_scenarios pattern) inside the runner's save
# backup/restore guard. wild_battle: campsite hold/retrieval + clean heal
# (0.1/0.5) — the implementation lives in wild_battle_scenario.gd (extracted for
# the v4 fixture work + the app line budget; dispatch name stays stable here).
# save_migration: v1/v2->v3->v4 migration, the v3-additive "structures" round-
# trip (a contents-less storage_box backfills empty; the campsite hold rides the
# v3 keys), the v4-additive box "contents" round-trip (corrupt contents degrade
# to an empty box, never a crash), future refusal, corrupt recovery, and the
# campsite round-trip.

const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")
const SaveStore := preload("res://scripts/runtime/save_store.gd")
const WildBattleScenario := preload("res://scripts/app/wild_battle_scenario.gd")

const SCENARIOS := {"wild_battle": "run_wild_battle", "save_migration": "run_save_migration"}
const MIGRATION_MON := {"species_id": "CHIKORITA", "name": "Chikorita", "level": 5, "exp": 125,
	"max_hp": 20, "current_hp": 20, "status": "PSN", "sleep_turns": 2,
	"moves": [{"move_id": "TACKLE", "pp": 35, "max_pp": 35, "power": 40}]}
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
	# v4 is PURELY additive over v3: a storage_box entry may carry "contents"
	# (absent = empty). 12,10 round-trips one mon; 13,10's corrupt "garbage"
	# contents must normalize to an empty box, never a crash or a torn entry.
	{"version": 4, "world_seed": 1234, "player_x": 3, "player_y": 4, "party": [MIGRATION_MON], "bag": {"poke_ball": 2},
		"time_of_day_minutes": 600, "total_steps": 0, "campsite_x": 3, "campsite_y": 4, "campsite_pokemon": [],
		"structures": {"10,10": {"kind": "placed", "structure_id": "wall", "by": "build", "step": 0},
		"12,10": {"kind": "placed", "structure_id": "storage_box", "by": "build", "step": 0, "contents": [MIGRATION_MON]},
		"13,10": {"kind": "placed", "structure_id": "storage_box", "by": "build", "step": 0, "contents": "garbage"}}},
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
	var checkers := [Callable(self, "_v1_fields_ok"), Callable(self, "_v2_fields_ok"), Callable(self, "_v3_fields_ok"), Callable(self, "_v4_fields_ok")]
	var v_ok := [false, false, false, false]
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
			"v1_ok": v_ok[0], "v2_ok": v_ok[1], "v3_ok": v_ok[2], "v4_ok": v_ok[3], "future_refused": future_refused, "checks": checks})
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
func _v4_fields_ok(runtime) -> bool:
	var session = runtime.session
	var placed: Dictionary = runtime._world_gen.placements_for_save()
	var contents: Array = placed.get("12,10", {}).get("contents", [])
	var mon: Dictionary = contents[0] if contents.size() == 1 else {}
	var garbage: Array = placed.get("13,10", {}).get("contents", ["sentinel"])
	return str(placed.get("10,10", {}).get("structure_id", "")) == "wall" \
		and str(mon.get("species_id", "")) == "CHIKORITA" and str(mon.get("status", "")) == "PSN" \
		and int(mon.get("sleep_turns", -1)) == 0 and int(mon.get("level", 0)) == 5 \
		and int(mon.get("max_hp", 0)) == 20 and garbage.is_empty() \
		and session.get_structures().size() == 3 and session.campsite_count() == 0 \
		and int(session.bag.get("poke_ball", 0)) == 2 and session.player_tile == Vector2i(3, 4)

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
