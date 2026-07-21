extends Node

# Phase-0 defect-fix scenarios (qa_scenarios pattern) inside the runner's save
# backup/restore guard. wild_battle: campsite hold/retrieval + clean heal (0.1/0.5).
# save_migration: v1/v2->v3 migration, future refusal, corrupt recovery, campsite round-trip.

const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")
const SaveStore := preload("res://scripts/runtime/save_store.gd")

const SCENARIOS := {"wild_battle": "run_wild_battle", "save_migration": "run_save_migration"}
const MIGRATION_MON := {"species_id": "CHIKORITA", "name": "Chikorita", "level": 5, "exp": 125,
	"max_hp": 20, "current_hp": 20, "status": "PSN", "sleep_turns": 2,
	"moves": [{"move_id": "TACKLE", "pp": 35, "max_pp": 35, "power": 40}]}
const MIGRATION_FIXTURES := [
	{"version": 1, "world_seed": 1234, "player_x": 3, "player_y": 4, "party": [MIGRATION_MON], "bag": {"pokeball": 5},
		"time_of_day_minutes": 700, "total_steps": 10, "unlocked_field_moves": {"cut": 1}},
	{"version": 2, "world_seed": 1234, "player_x": 5, "player_y": 6, "party": [MIGRATION_MON], "bag": {"poke_ball": 2, "potion": 1},
		"time_of_day_minutes": 800, "total_steps": 20, "unlocked_field_moves": {"surf": 1}},
]

static func handles(scenario: String) -> bool:
	return SCENARIOS.has(scenario)

static func run(scenario: String, host: Node, ctx: Dictionary) -> void:
	var node: Node = (load("res://scripts/app/phase0_scenarios.gd") as Script).new()
	host.add_child(node)
	await node.call(SCENARIOS[scenario], ctx, host)

func run_wild_battle(ctx: Dictionary, host: Node) -> void:
	await host.get_tree().create_timer(0.2).timeout
	var runtime: Node = ctx["runtime"]
	var world: Node = ctx["world"]
	var player: Node = ctx["player"]
	var runner := SmokeScenarioRunner.new()
	var fail := ""
	# Phase A: the original UI-driven smoke battle still reaches an outcome.
	var wild_mon: Dictionary = runtime.generate_wild_encounter(player.tile_position, world.get_tile_biome(player.tile_position))
	if wild_mon.is_empty():
		fail = "could not create a wild encounter"
	else:
		await host._run_smoke_battle(wild_mon)
	var set_battle: Callable = ctx.get("set_battle", Callable())
	if set_battle.is_valid():
		set_battle.call(false)
	runner.resync_player_tile(world, player, runtime)
	# Phase B: a full-party capture overflows to the campsite hold, not loss.
	var party_before: Array = runner.swap_party(runtime, _species_sample(runtime, 6))
	runtime.session.add_item("poke_ball", 5)
	var cursor := runner.trace_log_line_count()
	var target: Dictionary = _guaranteed_capture_mon(runtime)
	if fail.is_empty() and target.is_empty():
		fail = "no catalog species met the guaranteed-capture catch rate"
	if fail.is_empty():
		fail = _assert_campsite_capture(runtime, runner, target, cursor)
	# Phase C: the blackout heal restores HP AND clears status/sleep_turns.
	if fail.is_empty():
		fail = _assert_defeat_clean_heal(runtime, runner)
	runner.resync_player_tile(world, player, runtime)
	runner.restore_party(runtime, party_before)
	if fail.is_empty():
		runtime.emit_trace("wild_battle_passed", "SmokeScenarios", {"campsite_hold": true, "defeat_heal": true})
	else:
		push_error("Wild battle scenario failed: %s" % fail)

# Box-full outcome, mon held (not lost) with mon_relocated traced, retrieved.
func _assert_campsite_capture(runtime, runner, target: Dictionary, cursor: int) -> String:
	var session = runtime.session
	runtime.start_wild_battle(target)
	var caught: Dictionary = runtime.use_pokeball()
	var target_id := str(target.get("species_id", ""))
	if str(caught.get("outcome", "")) != "caught_box_full":
		return "full-party capture outcome was '%s', not caught_box_full" % str(caught.get("outcome", ""))
	var held: Array = session.get_campsite_pokemon()
	if session.campsite_count() != 1 or str(held[0].get("species_id", "")) != target_id:
		return "full-party capture did not land in the campsite hold"
	if not runner.trace_log_has_since("mon_relocated", cursor, {"species_id": target_id, "level": int(target.get("level", 1))}):
		return "no mon_relocated trace for the full-party capture"
	session.party.remove_at(session.party.size() - 1) # make room; retrieve via runtime (emits mon_retrieved)
	var retrieved: Dictionary = runtime.retrieve_campsite_mon(0)
	if retrieved.is_empty() or str(retrieved.get("species_id", "")) != target_id or session.campsite_count() != 0:
		return "campsite-held mon was not retrievable"
	if not runner.trace_log_has_since("mon_retrieved", cursor, {"species_id": target_id}):
		return "no mon_retrieved trace for the retrieval"
	return ""

# Forces a defeat against an unkillable enemy; asserts a clean blackout heal.
func _assert_defeat_clean_heal(runtime, runner) -> String:
	runner.swap_party(runtime, _species_sample(runtime, 1))
	var sick: Dictionary = runtime.session.get_party_member(0)
	sick["status"] = "PSN"
	sick["sleep_turns"] = 2
	runtime.session.set_party_member(0, sick)
	var brute_id := str(runtime.catalog.species.keys()[0])
	var brute: Dictionary = runtime.pokemon_rules.create_pokemon_instance(runtime.catalog.get_species(brute_id), 50, Callable(runtime.catalog, "get_move"))
	brute["max_hp"] = 9999
	brute["current_hp"] = 9999
	runtime.start_wild_battle(brute)
	runtime.battle_runtime._player_mon["current_hp"] = 0
	runtime.battle_runtime._player_mon["status"] = "PSN"
	runtime.battle_runtime._player_mon["sleep_turns"] = 2
	var result: Dictionary = runtime.perform_battle_move(_safe_move_index(runtime.battle_runtime._player_mon))
	if str(result.get("outcome", "")) != "defeat":
		return "defeat path reached outcome '%s'" % str(result.get("outcome", ""))
	for mon in runtime.session.party:
		if str(mon.get("status", "")) != "" or int(mon.get("sleep_turns", 0)) != 0:
			return "blackout heal left status '%s' / sleep_turns %d" % [str(mon.get("status", "")), int(mon.get("sleep_turns", 0))]
		if int(mon.get("current_hp", 0)) != int(mon.get("max_hp", 1)):
			return "blackout heal did not restore full HP"
	return ""

# A damaging move that cannot restore the fainted player mon (heal/leech would stall the defeat path).
func _safe_move_index(mon: Dictionary) -> int:
	var moves: Array = mon.get("moves", [])
	for i in range(moves.size()):
		var effect := str((moves[i] as Dictionary).get("effect", ""))
		if int(moves[i].get("power", 0)) > 0 and int(moves[i].get("pp", 0)) > 0 and effect != "EFFECT_LEECH_HIT" and effect != "EFFECT_HEAL":
			return i
	return 0

# 1 HP + asleep + catch_rate >= 192 pins capture probability at 1.0 (deterministic).
func _guaranteed_capture_mon(runtime) -> Dictionary:
	for entry in runtime.catalog.species.values():
		if entry is Dictionary and int((entry as Dictionary).get("catch_rate", 0)) >= 192:
			var mon: Dictionary = runtime.pokemon_rules.create_pokemon_instance(entry, 3, Callable(runtime.catalog, "get_move"))
			if mon.is_empty():
				continue
			mon["max_hp"] = 2
			mon["current_hp"] = 1
			mon["status"] = "SLP"
			return mon
	return {}

func _species_sample(runtime, count: int) -> Array:
	var ids: Array = []
	for species_id in runtime.catalog.species.keys():
		ids.append(str(species_id))
		if ids.size() >= count:
			break
	return ids

func run_save_migration(ctx: Dictionary, host: Node) -> void:
	await host.get_tree().create_timer(0.2).timeout
	var runtime: Node = ctx["runtime"]
	var runner := SmokeScenarioRunner.new()
	var checks := 0
	var fail := ""
	var cursor := runner.trace_log_line_count()
	var checkers := [Callable(self, "_v1_fields_ok"), Callable(self, "_v2_fields_ok")]
	var v_ok := [false, false]
	# v1 (legacy bag id, dropped unlock key) then v2 (bag/time/steps added).
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
	# Future version: refused, preserved to .newer.bak, warning traced -- so
	# the autosave after a refused load writes the now-empty live path and
	# can never overwrite the preserved newer save.
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
	# Corrupt-tier recovery (0.3) + populated-campsite save/load round-trip (0.1).
	if fail.is_empty():
		fail = runner.assert_save_recovery(runtime, cursor)
	_cleanup_fixtures()
	if fail.is_empty():
		runtime.emit_trace("save_migration_passed", "SmokeScenarios", {
			"v1_ok": v_ok[0], "v2_ok": v_ok[1], "future_refused": future_refused, "checks": checks})
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
		and session.campsite_count() == 0 and session.campsite_tile == session.player_tile

func _v2_fields_ok(runtime) -> bool:
	var session = runtime.session
	return session.player_tile == Vector2i(5, 6) and int(session.bag.get("poke_ball", 0)) == 2 \
		and int(session.bag.get("potion", 0)) == 1 and session.get_unlocked_field_moves().is_empty() \
		and int(session.time_of_day_minutes) == 800 and int(session.total_steps) == 20 \
		and session.campsite_count() == 0 and session.campsite_tile == session.player_tile \
		and runtime.world_overrides_for_save().is_empty()

func _write_fixture(payload: Dictionary) -> void:
	var file = FileAccess.open(SaveStore.SAVE_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(payload))
		file.close()

# Fixture artifacts must not leak into sibling scenarios (guard restores SAVE_PATH).
func _cleanup_fixtures() -> void:
	for suffix in [".newer.bak", ".corrupt.bak", SaveStore.TMP_SUFFIX]:
		var path: String = SaveStore.SAVE_PATH + str(suffix)
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
