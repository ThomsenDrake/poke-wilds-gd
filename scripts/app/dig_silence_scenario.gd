extends Node

# Dig-silence QoL guard: Z on DIGGABLE ground with no Dig-capable party member
# must stay SILENT — field_action_router suppresses the dig capability-refusal
# toast (diggable tiles are walkable and everywhere — beach spawn — so the
# refusal fired on every exploratory Z: annoyance, not information). Real
# input-phase injection (battle_end_input / input_gate pattern; every tap
# carries a delivery witness so degraded delivery fails red, never vacuous):
#   (A) dig-less party (bulbasaur) faces a dig tile + Z: the toast text is
#       UNCHANGED, no field_move_used trace, the tile stands;
#   (B) same party, Z on a CUT tile: the cut harvest SPEAKS — the injection
#       witness proving (A)'s silence was the router's decision, not a
#       swallowed press;
#   (C) dig-capable party (geodude), Z on a fresh dig tile: the success toast
#       speaks — the silence never over-suppresses a real harvest.
# D/E/F live in build_toggle_checks.gd (the 220-wall extraction): Z on a
# diggable+placeable tile with MACHOP+GEODUDE Digs and never opens build; C
# opens the overlay without placing; overlay Z places a wall.
# Seeded fresh game (harvest_flow idiom) so dig/cut targets sit near spawn.

const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")
const SmokeTap := preload("res://scripts/app/smoke_tap.gd")
const HarvestResolver := preload("res://scripts/runtime/harvest_resolver.gd")
const BuildToggleChecks := preload("res://scripts/app/build_toggle_checks.gd")

const SEED := 2026080901
const SCAN_RADIUS := 40

var _ctx: Dictionary = {}
var _runner = SmokeScenarioRunner.new()
var _failures: Array = []


func run(ctx: Dictionary) -> void:
	_ctx = ctx
	await get_tree().create_timer(0.2).timeout
	Input.use_accumulated_input = true
	var runtime = _runtime()
	runtime.seed_for_smoke(SEED)
	runtime.new_game()
	_world().rebuild(runtime.get_world_seed())
	_runner.teleport_player(_world(), _player(), runtime, runtime.get_player_tile())
	var saved_chance: float = _player().encounter_chance
	_player().encounter_chance = 0.0
	var party_before: Array = _runner.swap_party(runtime, ["BULBASAUR"]) # cut-capable, dig-INcapable
	_expect(not runtime.party_has_field_move_ability("dig"), "precondition: the bulbasaur party can dig (the silence branch would be dead)")
	_expect(runtime.party_has_field_move_ability("cut"), "precondition: the bulbasaur party cannot cut (the B witness would be dead)")
	if _failures.is_empty():
		await _part_a_dig_press_stays_silent()
	if _failures.is_empty():
		await _part_b_cut_press_still_speaks()
	if _failures.is_empty():
		await _part_c_capable_dig_still_speaks()
	if _failures.is_empty():
		var checks := BuildToggleChecks.new()
		add_child(checks)
		await checks.run(_ctx, _runner, _failures)
	_runner.restore_party(runtime, party_before)
	_player().encounter_chance = saved_chance
	_runner.resync_player_tile(_world(), _player(), runtime)
	Input.use_accumulated_input = false
	if _failures.is_empty():
		runtime.emit_trace("dig_silence_passed", "SmokeScenarios", {"seed": SEED})
	else:
		runtime.emit_trace("dig_silence_failed", "SmokeScenarios", {"failures": _failures, "seed": SEED})
		runtime.warn("DigSilenceScenario", "Dig silence failed: %s." % "; ".join(PackedStringArray(_failures)), {})
		push_error("Dig silence failed: %s" % "; ".join(PackedStringArray(_failures)))


# (A) The QoL case itself: a dig-less party's Z on diggable ground is silent.
func _part_a_dig_press_stays_silent() -> void:
	var found := _runner.find_harvest_target(_world(), _player().tile_position, SCAN_RADIUS, "dig")
	if not _expect(not found.is_empty(), "site: no dig tile with a stand spot within %d rings" % SCAN_RADIUS):
		return
	_runner.teleport_player(_world(), _player(), _runtime(), found["from_tile"])
	_face(found["direction"])
	_expect(_player().facing_tile() == found["tile"], "site: the player does not face the dig tile")
	var toast_before := _toast_text()
	var cursor := _runner.trace_log_line_count()
	await _tap("action_a")
	_expect(_toast_text() == toast_before, "A: the dig refusal toast spoke ('%s' -> '%s')" % [toast_before, _toast_text()])
	_expect(not _runner.trace_log_has_since("field_move_used", cursor), "A: a harvest fired on the silent press")
	_expect(HarvestResolver.action_for_tile(_world().get_tile_logic(found["tile"])) == "dig", "A: the dig tile was harvested on the silent press")


# (B) Delivery witness: the SAME party's Z on a cut tree harvests loudly, so
# (A)'s silence was the router's dig branch — never a swallowed press.
func _part_b_cut_press_still_speaks() -> void:
	var found := _runner.find_harvest_target(_world(), _player().tile_position, SCAN_RADIUS, "cut")
	if not _expect(not found.is_empty(), "site: no cut tile with a stand spot within %d rings" % SCAN_RADIUS):
		return
	_runner.teleport_player(_world(), _player(), _runtime(), found["from_tile"])
	_face(found["direction"])
	var toast_before := _toast_text()
	var cursor := _runner.trace_log_line_count()
	await _tap("action_a")
	_expect(_runner.trace_log_has_since("field_move_used", cursor, {"move_id": "cut"}), "B: no field_move_used for the cut press (the A tap may never have reached the router)")
	_expect(_toast_text() != toast_before, "B: the cut harvest toast did not speak")


# (C) No over-suppression: a dig-capable party's Z on diggable ground still
# harvests and speaks.
func _part_c_capable_dig_still_speaks() -> void:
	_runner.swap_party(_runtime(), ["GEODUDE"]) # dig-capable (harvest_flow's dig/smash mon); run() restores the real party
	if not _expect(_runtime().party_has_field_move_ability("dig"), "precondition: the geodude party cannot dig"):
		return
	var found := _runner.find_harvest_target(_world(), _player().tile_position, SCAN_RADIUS, "dig")
	if not _expect(not found.is_empty(), "site: no second dig tile with a stand spot within %d rings" % SCAN_RADIUS):
		return
	_runner.teleport_player(_world(), _player(), _runtime(), found["from_tile"])
	_face(found["direction"])
	var toast_before := _toast_text()
	var cursor := _runner.trace_log_line_count()
	await _tap("action_a")
	_expect(_runner.trace_log_has_since("field_move_used", cursor, {"move_id": "dig"}), "C: no field_move_used for the capable dig press")
	_expect(_toast_text() != toast_before, "C: the dig success toast did not speak")


# Dig ground is WALKABLE, so battle_end_input's blocked-step face trick steps ONTO
# the tile; set the avatar's facing field directly instead.
func _face(direction: Vector2i) -> void:
	_player()._facing = direction


func _tap(action: String) -> void:
	if not SmokeTap.inject_press(action):
		_failures.append("injection: no key event is bound to %s" % action)
		return
	await get_tree().process_frame
	SmokeTap.inject_release(action)
	await get_tree().process_frame


func _toast_text() -> String:
	var label: Variant = _message_box().get("_label")
	return str((label as Label).text) if label is Label else ""


func _expect(ok: bool, label: String) -> bool: # appends a labeled failure; returns ok for witness early-returns
	if not ok:
		_failures.append(label)
	return ok


func _world() -> Node: return _ctx["world"]
func _player() -> Node: return _ctx["player"]
func _runtime() -> Node: return _ctx["runtime"]
func _message_box() -> Node: return _ctx["message_box"]
