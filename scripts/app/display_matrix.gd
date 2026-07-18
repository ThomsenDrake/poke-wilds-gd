extends Node

# Window-size oracle for the battle display path. The deterministic
# visual_sweep captures at one window size and ui_render_audit's pixel half
# reads the native 1:1 SubViewport, so fractional display scales (which alias
# the pixel font into garble) used to slip both lanes. This scenario starts
# the same deterministic wild battle the sweep uses, resizes the window
# through a matrix of sizes (including fractional-inducing ones), and per
# size checks CONTENT-vs-DISPLAY consistency on the windowed frame's battle
# display rect: (1) a round-trip diff — the rect downscaled to the native
# 160x144 stage and compared to the 1:1 SubViewport capture with
# tools/visual_diff.py semantics (per-channel tolerance, percent-changed) —
# guards content integrity, and (2) a block-uniformity check — texels
# sharing one native pixel must render identically — catches the uneven
# pixel replication of fractional scales, which the round trip resamples
# away. Integer-snapped scales drift 0.0 on both; fractional scales fail.
# Every windowed frame lands in .godot-smoke/shots/matrix/ for the
# vision-review lane. One
# display_matrix_passed trace on success; push_error per failing size and no
# trace otherwise. Headless runs have no resizable window or renderer, so
# they emit the pass event with {"skipped": "headless"} (documented skip,
# keeps headless CI green). The pre-run window size is restored before exit.

const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")
const VisualSweep := preload("res://scripts/app/visual_sweep.gd")
const VisualSweepBaselines := preload("res://scripts/app/visual_sweep_baselines.gd")

const WINDOW_SIZES := [[1152, 648], [1024, 600], [800, 600], [640, 480], [438, 383], [1290, 768]]
const SETTLE_FRAMES := 5
const CHANNEL_TOLERANCE := 8 # mirrors tools/visual_diff.py's default per-channel tolerance
const DRIFT_THRESHOLD_PCT := 1.0
const MATRIX_DIR := "res://.godot-smoke/shots/matrix"

var _ctx: Dictionary = {}
var _baselines = VisualSweepBaselines.new()
var _failures: Array = []
var _max_drift := 0.0


func run(ctx: Dictionary) -> void:
	_ctx = ctx
	if DisplayServer.get_name() == "headless":
		_runtime().emit_trace("display_matrix_passed", "SmokeScenarios",
			{"sizes_checked": 0, "max_drift_pct": 0.0, "skipped": "headless"})
		return
	var previous_size := DisplayServer.window_get_size()
	if not _baselines.craft_state(_ctx, SmokeScenarioRunner.new(), VisualSweep.CRAFTED_STATE):
		push_error("Display matrix could not craft its deterministic state; species catalog incomplete.")
		return
	if not _start_battle():
		push_error("Display matrix could not start its deterministic wild battle.")
		return
	var view := _battle_view()
	await _baselines.await_battle_idle(get_tree(), view)
	view._set_menu_state("action")
	_prepare_matrix_dir()
	for size_spec in WINDOW_SIZES:
		await _check_size(int(size_spec[0]), int(size_spec[1]))
	DisplayServer.window_set_size(previous_size)
	if view.visible:
		view.run_smoke_escape()
		await _settle(2)
	if _failures.is_empty():
		_runtime().emit_trace("display_matrix_passed", "SmokeScenarios",
			{"sizes_checked": WINDOW_SIZES.size(), "max_drift_pct": snappedf(_max_drift, 0.0001)})
	else:
		for failure in _failures:
			push_error(str(failure))


func _check_size(width: int, height: int) -> void:
	DisplayServer.window_set_size(Vector2i(width, height))
	await _settle(SETTLE_FRAMES)
	var label := "%dx%d" % [width, height]
	var actual := DisplayServer.window_get_size()
	if absi(actual.x - width) > 2 or absi(actual.y - height) > 2:
		_failures.append("Display matrix at %s: window resize rejected (actual %dx%d); the scenario requires a standalone window, not an editor-managed one." % [label, actual.x, actual.y])
		return
	var frame := get_viewport().get_texture().get_image()
	var native: Image = _battle_view().get_node("BattleViewport").get_texture().get_image()
	if frame == null or frame.is_empty() or native == null or native.is_empty():
		_failures.append("Display matrix at %s: viewport capture unavailable." % label)
		return
	frame.save_png("%s/%s_battle.png" % [MATRIX_DIR, label])
	var drift := _display_drift(frame, native)
	_max_drift = maxf(_max_drift, drift["total"])
	if drift["total"] > DRIFT_THRESHOLD_PCT:
		_failures.append("Display matrix drift at %s: %.2f%% display inconsistency (round-trip %.2f%%, blocks %.2f%%; threshold %.1f%%)." % [label, drift["total"], drift["round_trip"], drift["blocks"], DRIFT_THRESHOLD_PCT])


# Crops the battle display rect out of the windowed frame (canvas rect
# scaled into frame texels, clamped) and converts it to RGBA8 for the
# byte-level checks. Empty image when the rect is degenerate.
func _display_crop(frame: Image) -> Image:
	var display: TextureRect = _battle_view().get_node("BattleDisplay")
	var rect := display.get_global_rect()
	var texel_scale := Vector2(frame.get_size()) / get_viewport().get_visible_rect().size
	var crop := Rect2i(Vector2i((rect.position * texel_scale).round()), Vector2i((rect.size * texel_scale).round()))
	crop = crop.intersection(Rect2i(Vector2i.ZERO, frame.get_size()))
	if crop.size.x <= 0 or crop.size.y <= 0:
		return Image.new()
	var image := frame.get_region(crop)
	image.convert(Image.FORMAT_RGBA8)
	return image


# Both consistency metrics over the display crop; the size's drift is the
# worse of the two. Keys: round_trip, blocks, total (percent each).
func _display_drift(frame: Image, native: Image) -> Dictionary:
	var crop := _display_crop(frame)
	if crop.is_empty():
		return {"round_trip": 100.0, "blocks": 100.0, "total": 100.0}
	var round_trip := _round_trip_drift_pct(crop, native)
	var blocks := _block_drift_pct(crop, native.get_width(), native.get_height())
	return {"round_trip": round_trip, "blocks": blocks, "total": maxf(round_trip, blocks)}


# Downscales the crop to the native stage and diffs it against the 1:1
# capture: a pixel counts as changed when any channel moves past
# CHANNEL_TOLERANCE; returns the changed share in percent.
func _round_trip_drift_pct(crop: Image, native: Image) -> float:
	var scaled: Image = crop.duplicate()
	scaled.resize(native.get_width(), native.get_height(), Image.INTERPOLATE_NEAREST)
	native.convert(Image.FORMAT_RGBA8)
	var a := native.get_data()
	var b := scaled.get_data()
	var changed := 0
	var pixels := native.get_width() * native.get_height()
	for pixel in range(pixels):
		var offset := pixel * 4
		var delta := maxi(maxi(absi(a[offset] - b[offset]), absi(a[offset + 1] - b[offset + 1])),
			maxi(absi(a[offset + 2] - b[offset + 2]), absi(a[offset + 3] - b[offset + 3])))
		if delta > CHANNEL_TOLERANCE:
			changed += 1
	return changed * 100.0 / pixels


# Uneven-replication check: at an exact integer scale every native pixel
# lands on a solid k-by-k texel block, so adjacent texels inside a block are
# byte-identical and only block boundaries may change color. Fractional
# scales break that periodicity; returns the disagreeing-pair share.
func _block_drift_pct(crop: Image, native_w: int, native_h: int) -> float:
	var w := crop.get_width()
	var h := crop.get_height()
	var kx := maxi(int(round(w / float(native_w))), 1)
	var ky := maxi(int(round(h / float(native_h))), 1)
	var bytes := crop.get_data()
	var violations := 0
	var pairs := 0
	for y in range(h):
		var row := y * w * 4
		for x in range(w - 1):
			if (x + 1) % kx == 0:
				continue
			pairs += 1
			if bytes.decode_u32(row + x * 4) != bytes.decode_u32(row + x * 4 + 4):
				violations += 1
	for y in range(h - 1):
		if (y + 1) % ky == 0:
			continue
		for x in range(w):
			pairs += 1
			if bytes.decode_u32((y * w + x) * 4) != bytes.decode_u32(((y + 1) * w + x) * 4):
				violations += 1
	return violations * 100.0 / maxi(pairs, 1)


# Same deterministic battle visual_sweep.gd starts: fixed wild species and a
# reseeded battle RNG, over the sweep's crafted party/world state.
func _start_battle() -> bool:
	var runtime = _runtime()
	runtime.battle_runtime._rng.seed = VisualSweep.BATTLE_RNG_SEED
	var entry: Dictionary = runtime.catalog.get_species(VisualSweep.WILD_SPECIES)
	if entry.is_empty():
		return false
	var wild_mon = runtime.pokemon_rules.create_pokemon_instance(entry, VisualSweep.WILD_LEVEL, Callable(runtime.catalog, "get_move"))
	if wild_mon.is_empty():
		return false
	_call("set_battle", [true])
	_message_box().hide_message()
	_music_router().play_battle_track("wild")
	_battle_view().start_wild_battle(wild_mon)
	return _battle_view().visible


# Fresh matrix directory per run so the vision lane reviews current captures.
func _prepare_matrix_dir() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(MATRIX_DIR))
	var dir := DirAccess.open(ProjectSettings.globalize_path(MATRIX_DIR))
	if dir == null:
		return
	for filename in dir.get_files():
		if filename.ends_with(".png"):
			dir.remove(filename)


func _settle(frames: int) -> void:
	for _i in range(frames):
		await get_tree().process_frame


func _call(key: String, args: Array = []) -> void:
	var callable: Callable = _ctx.get(key, Callable())
	if callable.is_valid():
		callable.callv(args)


func _runtime() -> Node: return _ctx["runtime"]
func _battle_view() -> Node: return _ctx["battle_view"]
func _message_box() -> Node: return _ctx["message_box"]
func _music_router() -> Object: return _ctx["music_router"]
