extends RefCounted

# Coded legibility oracle (Slice 4; spec docs/product-specs/vision-fidelity.md).
# Rasterizes expected strings to an ink mask the canonical way — a throwaway
# SubViewport whose Node2D._draw issues Font.draw_string at the model pens, read
# back via RenderingServer.texture_2d_get behind frame_post_draw — and XOR-matches
# the engine readback at UiRenderModel.expected() rects; a failed match IS the
# garble signal. Only ANCHOR strings (move/item names; engine labels sit at exactly
# MOVE_ANCHOR/ITEM_ANCHOR) are pixel-matched; BOX strings (message/type/PP) carry
# an engine-owned pen offset, so the scene-tree half layout-checks them and they
# graduate last. Windowed only. Raster parity with the battle Label (measured;
# 4.6.1-stable/forward_plus/M4): fonts.ttf@7, subpixel AUTO->ONE_QUARTER, hinting
# LIGHT, AA GRAY, oversampling 1.0, ascent 7, snap_2d_transforms_to_pixel=true,
# msaa_2d=0. Duplicate-run + draw-vs-Label XOR = 0 px on a shared bg; only motion =
# white-vs-#f8 fringe, <=1 px/string. Tolerances CALIBRATED from that floor (never
# assumed): T_STR=max(2,2*N_str)=2 (N_str=1), T_GLYPH=max(1,2*N_glyph)=1 (N_glyph=0),
# 2x headroom over the worst fringe flip (a real garble moves ~10-40 ink px).
# RE-MEASURE (2-launch XOR) after any rendering pin/font .import/binary change.

const UiRenderModel := preload("res://scripts/app/ui_render_model.gd")

const T_STR := 2
const T_GLYPH := 1
const SMEAR_RUN := 3  # 3x the measured healthy 1px stem (min ink run-length)

# Run-level stats the audit reads to emit text_oracle_passed; reset per run. states_checked counts only verification-COMPLETE states (readback OK, or nothing to rasterize); a double readback failure leaves it short, so the audit's all-specs pass gate withholds the clean-run signal (lint still runs).
static var states_checked := 0
static var strings_checked := 0
static var glyphs_checked := 0
static var glyph_mismatches := 0
static var _collected: Dictionary = {}

static func reset_stats() -> void:
	states_checked = 0
	strings_checked = 0
	glyphs_checked = 0
	glyph_mismatches = 0
	_collected = {}

# Draws expected strings black-on-white at their model pens (Font.draw_string only
# commits glyph quads inside a _draw context; a bare server canvas item reads blank).
class DrawNode extends Node2D:
	var font: Font
	var texts: Array = []
	var pens: Array = []  # Vector2(x, baseline_y) per string

	func _draw() -> void:
		for i in range(texts.size()):
			font.draw_string(get_canvas_item(), pens[i], str(texts[i]),
				HORIZONTAL_ALIGNMENT_LEFT, -1.0, UiRenderModel.FONT_SIZE, Color.BLACK)

# Rasterizes expected strings into a stage-space (160x144) mask parked on host, then
# tears the SubViewport down. Glyph pens are integer baselines = model rect top +
# ascent, so the raster equals the battle Label's (snap quantizes the Label to the
# same integer pen). Returns {mask, glyphs:{text,mode,rect,glyph_rects,ink,min_run,
# glyph_ink}} and stores it for pixel_findings.
static func collect(host: Node, state: String, model: Dictionary) -> Dictionary:
	var font: Font = UiRenderModel.battle_font()
	var ascent := int(font.get_ascent(UiRenderModel.FONT_SIZE))
	var glyphs := []
	var texts := []
	var pens := []
	for expected in model.get("strings", []):
		var region: Rect2 = expected["region"]
		var text := str(expected["text"])
		texts.append(text)
		pens.append(Vector2(region.position.x, region.position.y + ascent))
		glyphs.append(_string_glyphs(text, str(expected.get("mode", "anchor")), region, ascent))
	var empty := {"mask": Image.new(), "glyphs": glyphs}
	if texts.is_empty():
		states_checked += 1  # nothing to rasterize (e.g. battle_action): lint-only by design, verification complete
		_collected = empty
		return empty
	var vp := SubViewport.new()
	vp.size = Vector2i(160, 144)
	vp.transparent_bg = false
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	host.add_child(vp)
	var bg := ColorRect.new()
	bg.color = Color.WHITE
	bg.size = Vector2(160, 144)
	vp.add_child(bg)
	var node := DrawNode.new()
	node.font = font
	node.texts = texts
	node.pens = pens
	vp.add_child(node)
	await host.get_tree().process_frame
	await RenderingServer.frame_post_draw
	var image: Image = RenderingServer.texture_2d_get(vp.get_texture().get_rid())
	if image == null or image.is_empty():
		image = vp.get_texture().get_image()
	vp.queue_free()
	if image == null or image.is_empty():  # double readback failure: UNCOUNTED, so the all-specs gate cannot mint a pass
		_collected = empty
		return empty
	states_checked += 1  # readback-verified
	image.convert(Image.FORMAT_RGBA8)
	_ink_stats(image, glyphs)
	var result := {"mask": image, "glyphs": glyphs}
	_collected = result
	return result

# Unified pixel findings the audit loops once: the ink/forbidden/garble visual_lint
# bridge (call site relocated here from ui_render_audit) + glyph match findings.
static func pixel_findings(state: String, model: Dictionary, image: Image, display: Rect2) -> Array:
	var findings := UiRenderModel.run_lint(state, model, image, display)
	findings.append_array(check(state, model, _collected, image, display))
	return findings

# XOR-matches the engine readback against the collected anchor-string masks per
# glyph and per string, plus min-stroke (vanished stem/smear) + clipping
# corroboration. Emits {kind,state,text,glyph_index,region,mismatch}; the audit
# routes each to red (graduated state) or a quarantine_finding trace.
static func check(state: String, model: Dictionary, collected: Dictionary, image: Image, display: Rect2) -> Array:
	var findings := []
	var mask: Image = collected.get("mask", Image.new())
	if mask.is_empty() or image == null or image.is_empty():
		return findings
	for glyph in collected.get("glyphs", []):
		if str(glyph.get("mode", "")) != "anchor":
			continue
		strings_checked += 1
		var text := str(glyph.get("text", ""))
		var srect: Array = glyph["rect"]
		var glyph_rects: Array = glyph["glyph_rects"]
		glyphs_checked += glyph_rects.size()
		var total := _xor(mask, image, srect, _mapped(srect, display))
		if total > T_STR:
			findings.append({"kind": "glyph_mismatch", "state": state, "text": text, "glyph_index": -1, "region": srect, "mismatch": total})
			glyph_mismatches += 1
		var per: Array = glyph.get("glyph_ink", [])
		for gi in range(glyph_rects.size()):
			var gr: Array = glyph_rects[gi]
			var gmiss := _xor(mask, image, gr, _mapped(gr, display))
			if gmiss > T_GLYPH:
				findings.append({"kind": "glyph_mismatch", "state": state, "text": text, "glyph_index": gi, "region": gr, "mismatch": gmiss})
				glyph_mismatches += 1
			if int(gr[0]) < 0 or int(gr[1]) < 0 or int(gr[0]) + int(gr[2]) > 160 or int(gr[1]) + int(gr[3]) > 144:
				findings.append({"kind": "clipped", "state": state, "text": text, "glyph_index": gi, "region": gr, "mismatch": 0})
				continue
			var coll: Dictionary = per[gi] if gi < per.size() else {"ink": 0, "min_run": 0, "max_run": 0}
			var eng: Dictionary = _runs(image, _mapped(gr, display))
			if int(coll.get("ink", 0)) > 0 and int(eng.get("ink", 0)) == 0:
				findings.append({"kind": "low_ink", "state": state, "text": text, "glyph_index": gi, "region": gr, "mismatch": 0})
			elif int(coll.get("max_run", 0)) < SMEAR_RUN and int(eng.get("max_run", 0)) >= SMEAR_RUN:
				findings.append({"kind": "garble", "state": state, "text": text, "glyph_index": gi, "region": gr, "mismatch": 0})
	return findings

# Per-glyph bboxes from cumulative get_string_size (exact pen x, kerning included);
# height is the font ascent band.
static func _string_glyphs(text: String, mode: String, region: Rect2, ascent: int) -> Dictionary:
	var font: Font = UiRenderModel.battle_font()
	var glyph_rects := []
	var prev := 0.0
	for i in range(text.length()):
		var next := font.get_string_size(text.substr(0, i + 1), HORIZONTAL_ALIGNMENT_LEFT, -1.0, UiRenderModel.FONT_SIZE).x
		var gx := int(region.position.x + prev)
		var gw := maxi(1, int(region.position.x + next) - gx)
		glyph_rects.append([gx, int(region.position.y), gw, ascent])
		prev = next
	return {"text": text, "mode": mode, "rect": [int(region.position.x), int(region.position.y), int(region.size.x), int(region.size.y)],
		"glyph_rects": glyph_rects, "ink": 0, "min_run": 0, "glyph_ink": []}

static func _ink_stats(mask: Image, glyphs: Array) -> void:
	for glyph in glyphs:
		var per := []
		var total_ink := 0
		var min_run := 0
		for gr in glyph["glyph_rects"]:
			var r: Dictionary = _runs(mask, gr)
			per.append(r)
			total_ink += int(r["ink"])
			if int(r["min_run"]) > 0:
				min_run = int(r["min_run"]) if min_run == 0 else mini(min_run, int(r["min_run"]))
		glyph["glyph_ink"] = per
		glyph["ink"] = total_ink
		glyph["min_run"] = min_run

# Count where exactly one of two masks has ink over corresponding rects (stage rect
# on a, mapped image-space rect on b). Ink predicate matches tools/visual_lint.py.
static func _xor(a: Image, b: Image, arect: Array, brect: Array) -> int:
	var w := mini(int(arect[2]), int(brect[2]))
	var h := mini(int(arect[3]), int(brect[3]))
	var diff := 0
	for dy in range(h):
		for dx in range(w):
			if _is_ink(a, int(arect[0]) + dx, int(arect[1]) + dy) != _is_ink(b, int(brect[0]) + dx, int(brect[1]) + dy):
				diff += 1
	return diff

# Horizontal ink run-lengths in a rect: ink count, min non-zero run (healthy stem =
# 1), max run (a smear widens it).
static func _runs(image: Image, rect: Array) -> Dictionary:
	var ink := 0
	var min_run := 0
	var max_run := 0
	for dy in range(int(rect[3])):
		var run := 0
		for dx in range(int(rect[2])):
			if _is_ink(image, int(rect[0]) + dx, int(rect[1]) + dy):
				ink += 1
				run += 1
			elif run > 0:
				max_run = maxi(max_run, run)
				min_run = run if min_run == 0 else mini(min_run, run)
				run = 0
		if run > 0:
			max_run = maxi(max_run, run)
			min_run = run if min_run == 0 else mini(min_run, run)
	return {"ink": ink, "min_run": min_run, "max_run": max_run}

static func _is_ink(image: Image, x: int, y: int) -> bool:
	if x < 0 or y < 0 or x >= image.get_width() or y >= image.get_height():
		return false
	var c: Color = image.get_pixel(x, y)
	return int(c.r8 * 299 + c.g8 * 587 + c.b8 * 114) / 1000 < 128

static func _mapped(rect: Array, display: Rect2) -> Array:
	return UiRenderModel.map_region(Rect2(float(rect[0]), float(rect[1]), float(rect[2]), float(rect[3])), display)
