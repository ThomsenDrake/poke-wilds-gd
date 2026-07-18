extends Node

# Deterministic visual-regression sweep dispatched from SmokeScenarios: drives
# the live scene through overworld, biome, time-of-day, menu, and battle
# states, captures the root viewport per state, then reconciles the captures
# against committed baselines (docs/generated/visual-baselines) via
# VisualSweepBaselines + tools/visual_diff.py. Session state is crafted
# before the first shot (fixed seed, spawn tile, noon clock, fixed party,
# forced wild species, seeded battle RNG) so captures are byte-stable across
# runs on the same machine. Mode comes from the scenario options: "compare"
# (visual_sweep) fails on drift, "update" (visual_sweep_update) rewrites
# baselines; missing baselines force an update pass (auto_update flag).
# visual_sweep_passed is emitted only after an in-threshold compare or an
# update pass; on mismatch both files stay on disk and nothing is emitted.

const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")
const VisualSweepBaselines := preload("res://scripts/app/visual_sweep_baselines.gd")

const MIN_SHOT_BYTES := 5120
const WALK_STEPS := 4
const MAX_BIOME_SHOTS := 5
const BIOME_SCAN_RADIUS := 40
const BATTLE_SHOTS := ["09_battle.png", "10_battle_moves.png", "11_battle_after_attack.png", "12_battle_items.png"]
# Determinism contract: change these only together with a baseline update.
# DECIDUEYE front.png is a 13-frame strip: a sprite-loader regression canary.
const CRAFTED_STATE := {
	"world_seed": 20260717,
	"time_of_day": 720,
	"party": [["DECIDUEYE", 20], ["CHIKORITA", 5]],
	"bag": {"poke_ball": 5, "potion": 3}
}
const WILD_SPECIES := "DECIDUEYE"
const WILD_LEVEL := 18
const BATTLE_RNG_SEED := 20260717
const DEFAULT_THRESHOLD_PCT := 0.5

var _ctx: Dictionary = {}
var _runner = SmokeScenarioRunner.new()
var _baselines = VisualSweepBaselines.new()
var _base_dir := ""
var _mode := VisualSweepBaselines.MODE_COMPARE
var _threshold_pct := DEFAULT_THRESHOLD_PCT
var _shots: Array = []
var _failures: Array = []


func run_sweep(ctx: Dictionary, options: Dictionary = {}) -> void:
	_ctx = ctx
	_mode = str(options.get("mode", VisualSweepBaselines.MODE_COMPARE))
	_threshold_pct = float(options.get("threshold_pct", DEFAULT_THRESHOLD_PCT))
	_base_dir = _baselines.resolve_shot_dir()
	if _base_dir.is_empty():
		_runtime().warn("SmokeScenarios", "Visual sweep found no writable screenshot directory.", {})
		return
	_baselines.clear_shots(_base_dir)
	if not _baselines.craft_state(_ctx, _runner, CRAFTED_STATE):
		push_error("Visual sweep could not craft its deterministic state; species catalog incomplete.")
		return
	var saved_chance: float = _player().encounter_chance
	_player().encounter_chance = 0.0
	var spawn_biome: String = _world().get_tile_biome(_player().tile_position)
	await _capture("01_overworld_spawn.png")
	await _walk_a_few_steps()
	await _capture("02_overworld_walked.png")
	await _sweep_biomes(spawn_biome)
	_world().set_time_of_day(0)
	await _capture("04_night.png")
	_world().set_time_of_day(360)
	await _capture("05_dawn.png")
	_world().set_time_of_day(CRAFTED_STATE["time_of_day"])
	await _menu_shots()
	await _battle_shots()
	_player().encounter_chance = saved_chance
	_finish()


# Two idle frames let the renderer present the new state before the readback.
# The message box is hidden first so toast timing never enters a capture.
func _capture(filename: String) -> void:
	_message_box().hide_message()
	await _settle(2)
	var path := "%s/%s" % [_base_dir, filename]
	var image := get_viewport().get_texture().get_image()
	if image == null or image.is_empty():
		_failures.append("%s: viewport image unavailable" % filename)
		return
	if image.save_png(path) != OK:
		_failures.append("%s: save_png failed" % filename)
		return
	var file := FileAccess.open(path, FileAccess.READ)
	var size := -1 if file == null else file.get_length()
	if file != null:
		file.close()
	if size < MIN_SHOT_BYTES:
		_failures.append("%s: undersized (%d bytes)" % [filename, size])
		return
	_shots.append(filename)


func _settle(frames: int) -> void:
	for _i in range(frames):
		await get_tree().process_frame


func _walk_a_few_steps() -> void:
	for _i in range(WALK_STEPS):
		var direction = _runner.find_safe_step_direction(_world(), _player(), _runtime())
		if direction == Vector2i.ZERO:
			break
		if _player().smoke_step(direction):
			await _player().tile_changed


# Rings outward from the walked-to tile, teleporting to the first walkable
# tile of each biome not yet seen; unfound biomes are skipped gracefully.
func _sweep_biomes(spawn_biome: String) -> void:
	var seen := {spawn_biome: true}
	var found := 0
	var center: Vector2i = _player().tile_position
	for radius in range(1, BIOME_SCAN_RADIUS + 1):
		if found >= MAX_BIOME_SHOTS:
			break
		for tile in _runner.ring_around(center, radius):
			if found >= MAX_BIOME_SHOTS:
				break
			var biome: String = _world().get_tile_biome(tile)
			if biome.is_empty() or seen.has(biome) or not _world().is_tile_walkable(tile):
				continue
			seen[biome] = true
			found += 1
			_runner.teleport_player(_world(), _player(), _runtime(), tile)
			await _capture("03_biome_%s.png" % biome.to_lower())


func _menu_shots() -> void:
	_call("toggle_menu")
	await _capture("06_menu.png")
	_start_menu()._activate_entry(0) # POKEMON entry; opens the party screen
	await _capture("07_party_screen.png")
	var party_screen := _start_menu().get_node_or_null("PartyScreen")
	if party_screen != null:
		party_screen._back() # close and reshow the menu panel
	_start_menu()._activate_entry(1) # BAG entry; opens the bag screen
	await _capture("08_bag_screen.png")
	var bag_screen := _start_menu().get_node_or_null("BagScreen")
	if bag_screen != null:
		bag_screen._back()
	_call("toggle_menu")


func _battle_shots() -> void:
	if not _start_battle():
		for shot in BATTLE_SHOTS:
			_failures.append("%s: could not start a wild battle" % shot)
		return
	var view := _battle_view()
	await _capture("09_battle.png")
	view._set_menu_state("action")
	view._selection = "fight"
	view._activate_selection()
	await _capture("10_battle_moves.png")
	view._selection = _baselines.damaging_move_id(_runtime())
	view._activate_selection()
	await _baselines.await_battle_idle(get_tree(), view)
	await _capture("11_battle_after_attack.png")
	if not view.visible and not _start_battle():
		_failures.append("12_battle_items.png: battle ended and no new battle could start")
		return
	await _baselines.await_battle_idle(get_tree(), view)
	view._set_menu_state("action")
	view._selection = "item"
	view._activate_selection()
	await _capture("12_battle_items.png")
	if view.visible:
		view.run_smoke_escape()
		await _settle(2)


# Forces a fixed wild species (strip-sprite canary) and reseeds the battle
# RNG so damage rolls, enemy move picks, and message lines are reproducible.
func _start_battle() -> bool:
	var runtime = _runtime()
	runtime.battle_runtime._rng.seed = BATTLE_RNG_SEED
	var entry: Dictionary = runtime.catalog.get_species(WILD_SPECIES)
	if entry.is_empty():
		return false
	var wild_mon = runtime.pokemon_rules.create_pokemon_instance(entry, WILD_LEVEL, Callable(runtime.catalog, "get_move"))
	if wild_mon.is_empty():
		return false
	_call("set_battle", [true])
	_message_box().hide_message()
	_music_router().play_battle_track("wild")
	_battle_view().start_wild_battle(wild_mon)
	return _battle_view().visible


func _finish() -> void:
	if not _failures.is_empty():
		push_error("Visual sweep failed captures: %s" % "; ".join(PackedStringArray(_failures)))
		return
	_baselines.report(_runtime(), _shots, _base_dir, _mode, _threshold_pct)


func _call(key: String, args: Array = []) -> void:
	var callable: Callable = _ctx.get(key, Callable())
	if callable.is_valid():
		callable.callv(args)


func _world() -> Node: return _ctx["world"]
func _player() -> Node: return _ctx["player"]
func _runtime() -> Node: return _ctx["runtime"]
func _battle_view() -> Node: return _ctx["battle_view"]
func _start_menu() -> Node: return _ctx["start_menu"]
func _message_box() -> Node: return _ctx["message_box"]
func _music_router() -> Object: return _ctx["music_router"]
