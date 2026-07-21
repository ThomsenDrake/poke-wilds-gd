extends RefCounted

# Capture-honesty contract for the vision lanes (docs/product-specs/
# vision-fidelity.md): a RenderingServer.frame_post_draw readback guard ADDED
# AFTER callers' existing settle waits (never a substitute — resized windows
# must present, and the battle SubViewport redraws only while visible); a
# validity oracle (undersize / blank / uniform / magenta — the Godot 4.6
# #115402 SubViewport signature, fixed only in 4.7 — with transport-vs-
# regression classification); and an opt-in duplicate-capture hook whose
# nonzero deltas emit a quarantine-tier nondeterministic_pair trace.
# Slice 3: non-empty options.metadata makes capture() inject the capture-side
# fields and write the canonical <shot>.sidecar.json next to the PNG.

const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")
const RenderIntrospection := preload("res://scripts/app/render_introspection.gd")

const MIN_SHOT_BYTES := 5120      # PNG bytes; below => undersize (only when a save_path wrote one)
const LUMINANCE_FLOOR := 0.01     # Rec.709 mean luminance (0-1); below => blank
const UNIFORM_LUMA_SPAN := 0.004  # ~1/255; sampled luminance span below => uniform
const MAGENTA_CHANNEL_TOL := 8    # r >= 255-tol && g <= tol && b >= 255-tol => magenta sample
const MAGENTA_RATIO := 0.5        # magenta sample share at/above => magenta frame
const SAMPLE_BUDGET := 4096       # even-stride pixel samples per validity pass
const DUPCHECK_ENV := "PLAYTEST_CAPTURE_DUPCHECK"

var shot_seq := 0     # 1-based per instance; capture order within one sweep
var dup_checked := 0  # duplicate checks performed (feeds visual_sweep_passed)
var invalid := 0      # invalid captures seen, kind != "" (feeds visual_sweep_passed)

# Fires after all viewports finished updating; callers await their settles FIRST.
func guard_readback() -> void:
	await RenderingServer.frame_post_draw

# Pure validity oracle, no traces; png_bytes < 0 skips the undersize check.
# Precedence: headless > blank > undersize > magenta > uniform (magenta runs
# before uniform because a magenta frame is also uniform and magenta is the
# identified cause). Transport only under the headless display server; magenta
# is ALWAYS regression.
func classify(image: Image, png_bytes: int) -> Dictionary:
	var headless := DisplayServer.get_name() == "headless"
	var classification := "transport" if headless else "regression"
	if image == null or image.is_empty():
		return {"kind": "headless" if headless else "blank", "classification": classification, "luminance": 0.0, "detail": "headless display server renders no pixels" if headless else "viewport image unavailable"}
	var stats := _sample_stats(image)
	var luma: float = stats["mean"]
	if luma < LUMINANCE_FLOOR:
		return {"kind": "blank", "classification": classification, "luminance": luma, "detail": "mean luminance %.4f below floor %.4f" % [luma, LUMINANCE_FLOOR]}
	if png_bytes >= 0 and png_bytes < MIN_SHOT_BYTES:
		return {"kind": "undersize", "classification": classification, "luminance": luma, "detail": "PNG is %d bytes, below minimum %d" % [png_bytes, MIN_SHOT_BYTES]}
	if float(stats["magenta"]) >= MAGENTA_RATIO:
		return {"kind": "magenta", "classification": "regression", "luminance": luma, "detail": "magenta sample ratio %.3f at/above %.2f; Godot 4.6 #115402 SubViewport readback" % [stats["magenta"], MAGENTA_RATIO]}
	if float(stats["span"]) < UNIFORM_LUMA_SPAN:
		return {"kind": "uniform", "classification": classification, "luminance": luma, "detail": "luminance span %.4f below %.4f" % [stats["span"], UNIFORM_LUMA_SPAN]}
	return {"kind": "", "classification": classification, "luminance": luma, "detail": ""}

# Emits capture_invalid from a classify() verdict; quarantine-tier, never
# fails a scenario on its own. Source is fixed: App.SnapshotCapture.
func trace_invalid(runtime: Node, shot: String, verdict: Dictionary, extra_detail: String) -> void:
	var detail := str(verdict.get("detail", ""))
	if not extra_detail.is_empty():
		detail = extra_detail if detail.is_empty() else "%s; %s" % [detail, extra_detail]
	runtime.emit_trace("capture_invalid", "App.SnapshotCapture", {"shot": shot,
		"kind": str(verdict.get("kind", "")), "classification": str(verdict.get("classification", "")),
		"luminance": float(verdict.get("luminance", 0.0)), "detail": detail})

# Full pipeline: guard -> trace_cursor (join key, sampled before readback) ->
# readback -> optional PNG write -> classify -> on valid, sidecar write (when
# metadata non-empty) + snapshot_captured (record lands at cursor+1); on
# invalid, capture_invalid. options: save_path / shot_seq / dup_check /
# metadata (sidecar content; capture injects the capture-side fields).
func capture(runtime: Node, viewport: Viewport, shot: String, options: Dictionary = {}) -> Dictionary:
	var metadata := {}
	if options.get("metadata", {}) is Dictionary:
		metadata = options.get("metadata", {})
	await guard_readback()
	var trace_cursor: int = SmokeScenarioRunner.new().trace_log_line_count()
	var ts: int = Time.get_ticks_msec()
	var seq: int = int(options.get("shot_seq", 0))
	if seq <= 0:
		shot_seq += 1
		seq = shot_seq
	var image: Image = viewport.get_texture().get_image()
	var save_path: String = str(options.get("save_path", ""))
	var png_bytes := -1
	var save_err := OK
	if not save_path.is_empty() and image != null and not image.is_empty():
		save_err = image.save_png(save_path)
		if save_err == OK:
			var file := FileAccess.open(save_path, FileAccess.READ)
			if file != null:
				png_bytes = file.get_length()
				file.close()
	var verdict := classify(image, png_bytes)
	if save_err != OK and str(verdict.get("kind", "")) == "":
		verdict = {"kind": "undersize", "classification": "transport" if DisplayServer.get_name() == "headless" else "regression", "luminance": 0.0, "detail": "save_png failed (err %d); no PNG written" % save_err}
	var kind := str(verdict.get("kind", ""))
	var sidecar_path := ""
	if kind == "" and not save_path.is_empty() and not metadata.is_empty():
		metadata.merge({"shot": shot, "shot_seq": seq, "ts_msec": ts, "trace_cursor": trace_cursor,
			"window": [DisplayServer.window_get_size().x, DisplayServer.window_get_size().y],
			"palettes": RenderIntrospection.palettes_from_image(image, metadata.get("palette_regions", {})),
			"validity": {"luminance": float(verdict.get("luminance", 0.0)), "uniform": false, "bytes": png_bytes}}, true)
		metadata.erase("palette_regions")
		sidecar_path = _write_sidecar(save_path, metadata)
	var result := {"ok": kind == "", "image": image, "kind": kind, "bytes": png_bytes,
		"classification": str(verdict.get("classification", "")), "luminance": float(verdict.get("luminance", 0.0)),
		"shot_seq": seq, "trace_cursor": trace_cursor, "detail": str(verdict.get("detail", "")),
		"metadata": metadata, "sidecar_path": sidecar_path}
	if kind != "":
		invalid += 1
		trace_invalid(runtime, shot, verdict, "")
		return result
	# No RenderingServer.get_current_renderer() in 4.6.1 (verified); the
	# project setting resolves per platform and names the active method.
	runtime.emit_trace("snapshot_captured", "App.SnapshotCapture", {"shot": shot, "shot_seq": seq,
		"ts_msec": ts, "trace_cursor": trace_cursor,
		"window": [DisplayServer.window_get_size().x, DisplayServer.window_get_size().y],
		"renderer": str(ProjectSettings.get_setting("rendering/renderer/rendering_method", "")),
		"godot_version": str(Engine.get_version_info().get("string", "")),
		"sidecar_path": sidecar_path})
	if _dup_check_on(options):
		await _duplicate_check(runtime, viewport, shot, image, result["luminance"])
	return result

# Canonical sidecar next to the PNG: JSON.stringify sorts keys recursively by
# default (verified on 4.6.1), compact, no trailing newline; ints upstream.
func _write_sidecar(save_path: String, metadata: Dictionary) -> String:
	var path := save_path + RenderIntrospection.SIDECAR_SUFFIX
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return ""
	file.store_string(JSON.stringify(metadata))
	file.close()
	return path

# Root-viewport crop fallback for the battle SubViewport (#115402 stale/
# magenta readback): same geometry as display_matrix's _display_crop —
# BattleDisplay's global rect scaled by frame / visible rect, clamped. Pure,
# no traces; RGBA8 crop at window texel scale, empty when unavailable.
func crop_battle_display(root_viewport: Viewport, battle_view: Node) -> Image:
	var frame: Image = root_viewport.get_texture().get_image()
	var display := battle_view.get_node_or_null("BattleDisplay") as Control
	if frame == null or frame.is_empty() or display == null:
		return Image.new()
	var visible_size: Vector2 = root_viewport.get_visible_rect().size
	if visible_size.x <= 0.0 or visible_size.y <= 0.0:
		return Image.new()
	var texel_scale := Vector2(frame.get_size()) / visible_size
	var rect: Rect2 = display.get_global_rect()
	var crop := Rect2i(Vector2i((rect.position * texel_scale).round()), Vector2i((rect.size * texel_scale).round()))
	crop = crop.intersection(Rect2i(Vector2i.ZERO, frame.get_size()))
	if crop.size.x <= 0 or crop.size.y <= 0:
		return Image.new()
	var image := frame.get_region(crop)
	image.convert(Image.FORMAT_RGBA8)
	return image

# Duplicate hook: a second guard + readback of the same quiesced viewport, one
# newly rendered frame later (no game state advances between the pair; the two
# readbacks DO span one rendered frame — catching exactly that is the point).
# Any nonzero delta emits a quarantine-tier nondeterministic_pair trace with an
# identified cause; the primary capture stays canonical (ok=true) and the pair
# is never saved. Triggered by options.dup_check or DUPCHECK env; default OFF.
func _duplicate_check(runtime: Node, viewport: Viewport, shot: String, primary: Image, luminance: float) -> void:
	dup_checked += 1
	await guard_readback()
	var second: Image = viewport.get_texture().get_image()
	var a := _rgba8(primary)
	var b := _rgba8(second)
	var da := PackedByteArray() if a == null else a.get_data()
	var db := PackedByteArray() if b == null else b.get_data()
	if da == db:
		return
	var detail := "byte length mismatch (%d vs %d)" % [da.size(), db.size()]
	if da.size() == db.size():
		var diff_pixels := 0
		var first := -1
		for offset in range(0, da.size(), 4):
			if da[offset] != db[offset] or da[offset + 1] != db[offset + 1] or da[offset + 2] != db[offset + 2] or da[offset + 3] != db[offset + 3]:
				diff_pixels += 1
				first = offset if first < 0 else first
		detail = "%d of %d pixels differ; first byte offset %d" % [diff_pixels, da.size() / 4, first]
	trace_invalid(runtime, shot, {"kind": "nondeterministic_pair", "classification": "regression", "luminance": luminance, "detail": detail}, "")

func _dup_check_on(options: Dictionary) -> bool:
	if bool(options.get("dup_check", false)):
		return true
	var value := OS.get_environment(DUPCHECK_ENV).strip_edges().to_lower()
	return not (value in ["", "0", "false", "no", "off"])

# Even-stride Rec.709 luminance + magenta-ratio sampling over an RGBA8 copy.
func _sample_stats(image: Image) -> Dictionary:
	var img := _rgba8(image)
	var data := img.get_data()
	var pixels := img.get_width() * img.get_height()
	var sum := 0.0
	var min_luma := 1.0
	var max_luma := 0.0
	var magenta := 0
	var count := 0
	for pixel in range(0, pixels, maxi(pixels / SAMPLE_BUDGET, 1)):
		var offset := pixel * 4
		var r: int = data[offset]
		var g: int = data[offset + 1]
		var b: int = data[offset + 2]
		var luma := (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255.0
		sum += luma
		min_luma = minf(min_luma, luma)
		max_luma = maxf(max_luma, luma)
		if r >= 255 - MAGENTA_CHANNEL_TOL and g <= MAGENTA_CHANNEL_TOL and b >= 255 - MAGENTA_CHANNEL_TOL:
			magenta += 1
		count += 1
	return {"mean": sum / float(maxi(count, 1)), "span": max_luma - min_luma,
		"magenta": magenta / float(maxi(count, 1))}

func _rgba8(image: Image) -> Image:
	if image == null or image.is_empty():
		return null
	var copy := image.duplicate()
	copy.convert(Image.FORMAT_RGBA8)
	return copy
