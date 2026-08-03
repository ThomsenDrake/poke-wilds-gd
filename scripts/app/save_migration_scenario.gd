extends Node

# Save-migration scenario, EXTRACTED from phase0_scenarios.gd for the app 220-line budget
# (the wild_battle_scenario precedent): v1/v2->v3->v4->v5->v6 — v3 structures, v4 contents +
# pastures, v5 CHAIN-LESS -> v6 lossless flatten (delta == {version: 6}) + the pinned byte
# witnesses + the CHAINED-v5 REFUSAL witness (predicate AND the load-path _preserve), future refusal, corrupt recovery.

const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")
const SaveStore := preload("res://scripts/runtime/save_store.gd")
const SessionState := preload("res://scripts/runtime/session_state.gd")
const SaveStabilitySupport := preload("res://scripts/app/save_stability_support.gd")
const LandmarkRuntime := preload("res://scripts/runtime/landmark_runtime.gd") # the anchor derivation rides the runtime's own preload (the layer table)
const Landmarks := LandmarkRuntime.Landmarks
const ContentScatter := LandmarkRuntime.ContentScatter
# Domain access rides the runtime's own preload (app may not preload domain — check_architecture's layer table).
const SaveMigration := SessionState.SaveMigration
const GOLDEN_PATH := "res://docs/generated/golden-saves/v4_golden.json" # v4 migration witness (shared with save_stability)

const MIGRATION_MON := {"species_id": "CHIKORITA", "name": "Chikorita", "level": 5, "exp": 125,
	"max_hp": 20, "current_hp": 20, "status": "PSN", "sleep_turns": 2,
	"moves": [{"move_id": "TACKLE", "pp": 35, "max_pp": 35, "power": 40}]}
# Penned mon with the full habitat sub-dict the Steel-stone cadence rides; the fixture pen has NO fence ring, so load relocates it.
const PASTURE_MON := {"species_id": "EEVEE", "name": "Eevee", "level": 30, "exp": 0,
	"max_hp": 30, "current_hp": 30, "status": "", "sleep_turns": 2, "happiness": 220,
	"moves": [{"move_id": "TACKLE", "pp": 35, "max_pp": 35, "power": 40}],
	"habitat": {"satisfied": true, "last_drop_day": 3, "last_stone_day": 1}}
# Additive party-egg shape (Breeding.build_egg): the nested payload carries the child — normalize passes it by shape.
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
	# v5 CHAIN-LESS (infinite-world slice): migrates LOSSLESSLY to v6 (delta == {version: 6}; chain identity dropped).
	{"version": 5, "world_seed": 4242, "root_seed": 4242, "active_chain": "0,0",
		"player_x": 7, "player_y": 8, "party": [MIGRATION_MON], "bag": {"poke_ball": 3},
		"time_of_day_minutes": 600, "total_steps": 0, "campsite_x": 7, "campsite_y": 8,
		"campsite_pokemon": [], "structures": {}, "pastures": {},
		"chained_worlds": {"0,0": {
			"landmark_state": {"pkmn_mansion": {"statues": [true, true, true], "unlocked": true, "key_taken": false}}}}},
]

# A truly chained v5 save is structurally unrepresentable on the infinite plane (the REFUSAL witness; NOT applied).
const CHAINED_V5_FIXTURE := {"version": 5, "world_seed": 4242, "root_seed": 4242, "active_chain": "0,-1",
	"player_x": 7, "player_y": 8, "party": [MIGRATION_MON], "bag": {"poke_ball": 3},
	"time_of_day_minutes": 600, "total_steps": 0, "campsite_x": 7, "campsite_y": 8, "campsite_pokemon": [],
	"chained_worlds": {"0,0": {"structures": {"30,40": {"kind": "placed", "structure_id": "fence", "by": "build", "step": 0}}},
		"0,-1": {"structures": {"31,40": {"kind": "placed", "structure_id": "fence", "by": "build", "step": 0}}}}}


func run(ctx: Dictionary, host: Node) -> void:
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
	# CHAINED v5 refusal (infinite-world slice): a truly chained v5 save cannot be represented on
	# one plane — can_represent_infinite refuses it (preserved to .chained.bak + fresh start); a chain-less v5 flattens losslessly.
	var chained_refused := false
	if fail.is_empty():
		chained_refused = not SaveMigration.can_represent_infinite(CHAINED_V5_FIXTURE) \
			and SaveMigration.can_represent_infinite(MIGRATION_FIXTURES[4])
		if chained_refused:
			checks += 1
		else:
			fail = "chained v5 refusal: can_represent_infinite must refuse a chained save and accept a chain-less one"
	# CHAINED refusal LOAD-PATH: the refusal rides save_store._preserve, arming live-path protection on failure so a write never clobbers the un-preserved save.
	if fail.is_empty():
		fail = SaveStabilitySupport.chained_refusal_preserve_test(runtime.save_store, Callable(self, "_write_fixture"), CHAINED_V5_FIXTURE)
		if fail.is_empty():
			checks += 1
	if fail.is_empty():
		fail = runner.assert_save_recovery(runtime, cursor)
	_cleanup_fixtures()
	if fail.is_empty():
		runtime.emit_trace("save_migration_passed", "SmokeScenarios", {
			"v1_ok": v_ok[0], "v2_ok": v_ok[1], "v3_ok": v_ok[2], "v4_ok": v_ok[3], "v5_ok": v_ok[4], "future_refused": future_refused, "chained_refused": chained_refused, "checks": checks})
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

# v5 CHAIN-LESS -> v6 (infinite-world slice): migrate() flattens losslessly — world_seed
# preserved (frozen origin identity), the origin chained_worlds["0,0"].landmark_state hoisted
# to the top-level seat and re-keyed to the per-instance grammar (slice 3, derived from the
# payload's own world_seed), chain identity dropped + the pinned byte witnesses green
# (golden delta EXACTLY {version: 6}; relocation value byte-verbatim at the re-keyed seat +
# the removals normalization + argument purity + the chained-refusal witness).
func _v5_fields_ok(runtime) -> bool:
	var session = runtime.session
	if int(session.world_seed) != 4242:
		return false
	var expected := ContentScatter.instance_key("pkmn_mansion", Landmarks.anchor_for(4242, Vector2i.ZERO, "pkmn_mansion"))
	var mansion: Dictionary = (session.landmark_state as Dictionary).get(expected, {})
	if not bool(mansion.get("unlocked", false)):
		return false # the hoisted puzzle state must land on the re-keyed instance seat
	var golden: Variant = JSON.parse_string(FileAccess.get_file_as_string(GOLDEN_PATH))
	return golden is Dictionary and SaveMigration.byte_witness_issues(golden as Dictionary, SessionState.SAVE_VERSION).is_empty()

func _write_fixture(payload: Dictionary) -> void:
	var file = FileAccess.open(SaveStore.SAVE_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(payload))
		file.close()

func _cleanup_fixtures() -> void:
	for suffix in [".newer.bak", ".corrupt.bak", ".chained.bak", SaveStore.TMP_SUFFIX]:
		var path: String = SaveStore.SAVE_PATH + str(suffix)
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
