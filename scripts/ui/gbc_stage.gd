extends RefCounted

# Shared GBC stage library (menu restyle slice, wave 0): extracts the BattleView
# SubViewport-160x144 idiom (scenes/ui/BattleView.tscn, scripts/ui/battle_view.gd)
# so every menu screen renders in the same native 160x144 stage space,
# integer-scaled into the window.
#
# Hard rules encoded here:
# - Stage children (inside the 160x144 ScreenStage) get EXPLICIT integer
#   offsets only. Never call set_anchors_preset() on a parented node: the
#   preset is rect-preserving and bakes 0x0 (slice plan, diagnosis 2).
# - Full-rect helpers (Backing, resize watcher) set anchors + offsets
#   explicitly — no preset call.
# - Labels: fonts.ttf size 7 via apply_font() (battle_surface.gd:220
#   _apply_battle_font pattern) with an ink parameter. Black ink on white
#   plates; white ink ONLY on the pure-black splash.
# - NEAREST filtering on every art TextureRect.
#
# Usage from a screen's _ready (host root must already be in the tree):
#   var parts := GbcStage.build(self)          # {viewport, stage, display, backing}
#   GbcStage.on_resized(self, parts.display)   # resize wiring + first layout

const STAGE_SIZE := Vector2(160.0, 144.0)
const STAGE_PADDING := 16.0 # battle_view.gd:195-203 pads the window by 16px
const FONT_PATH := "res://assets/source/fonts.ttf"
const FONT_SIZE := 7

static var _font: Font


# Builds the stage tree under host_root. opts: opaque_backing (default true) —
# opaque black ColorRect behind everything (battle's root-ColorRect idiom);
# transparent_bg (default false) — SubViewport clear flag (MessageBox-style
# overlay stages pass true). Returns {viewport, stage, display, backing}.
static func build(host_root: Control, opts: Dictionary = {}) -> Dictionary:
	var backing: ColorRect = null
	if opts.get("opaque_backing", true):
		backing = ColorRect.new()
		backing.name = "Backing"
		backing.color = Color.BLACK
		backing.mouse_filter = Control.MOUSE_FILTER_IGNORE
		host_root.add_child(backing)
		_full_rect(backing)
	var viewport := SubViewport.new()
	viewport.name = "ScreenViewport"
	viewport.disable_3d = true
	viewport.handle_input_locally = false
	viewport.transparent_bg = opts.get("transparent_bg", false)
	viewport.size = Vector2i(160, 144)
	host_root.add_child(viewport)
	var stage := Control.new()
	stage.name = "ScreenStage"
	stage.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stage.offset_right = STAGE_SIZE.x
	stage.offset_bottom = STAGE_SIZE.y
	viewport.add_child(stage)
	var display := TextureRect.new()
	display.name = "ScreenDisplay"
	display.texture = viewport.get_texture()
	display.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	# BattleView.tscn's stretch_mode 6 (design §1.1): COVERED scales the 160x144
	# texture up to the integer-scaled rect. STRETCH_KEEP would draw it 1:1!
	display.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	display.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	display.mouse_filter = Control.MOUSE_FILTER_IGNORE
	host_root.add_child(display)
	if backing != null:
		# Opaque-black FIRST stage child (design §0.5: opaque stages): the root
		# Backing sits BEHIND the opaque SubViewport (gray default clear), so the
		# splash's pure-black ink contract lives INSIDE the stage, under the art.
		var stage_backing := ColorRect.new()
		stage_backing.name = "StageBacking"
		stage_backing.color = Color.BLACK
		stage_backing.mouse_filter = Control.MOUSE_FILTER_IGNORE
		stage_backing.offset_right = STAGE_SIZE.x
		stage_backing.offset_bottom = STAGE_SIZE.y
		stage.add_child(stage_backing)
		stage.move_child(stage_backing, 0)
	return {"viewport": viewport, "stage": stage, "display": display, "backing": backing}


# Integer-scale layout, ported verbatim from battle_view.gd:195-203.
static func layout(display: TextureRect, window_size: Vector2) -> void:
	var available = window_size - Vector2.ONE * STAGE_PADDING * 2.0
	var scale_factor = min(available.x / STAGE_SIZE.x, available.y / STAGE_SIZE.y)
	# Integer-snap when the stage fits: fractional scales alias the pixel font.
	scale_factor = maxf(floorf(scale_factor), 1.0) if scale_factor >= 1.0 else maxf(scale_factor, 0.1)
	var scaled_size = STAGE_SIZE * scale_factor
	display.size = scaled_size
	display.position = ((window_size - scaled_size) * 0.5).floor()


# Wires NOTIFICATION_RESIZED: a full-rect, input-ignoring watcher child re-runs
# layout() whenever the host resizes (battle_view.gd:32-34 _notification
# idiom). Idempotent. Also lays out once immediately.
static func on_resized(host: Control, display: TextureRect) -> void:
	for child in host.get_children():
		if child is ResizeWatcher:
			return
	var watcher := ResizeWatcher.new()
	watcher.name = "GbcResizeWatcher"
	watcher.mouse_filter = Control.MOUSE_FILTER_IGNORE
	watcher.relayout = func() -> void: layout(display, host.get_viewport_rect().size)
	host.add_child(watcher)
	_full_rect(watcher)
	layout(display, host.get_viewport_rect().size)


# Inverse display-to-stage map, ported from battle_view.gd:205-213.
# screen_point is host-local (e.g. a root _gui_input event.position). Returns
# the stage-local Vector2, or null when the point is outside the display rect.
static func stage_point(display: TextureRect, screen_point: Vector2):
	var display_rect := Rect2(display.position, display.size)
	if not display_rect.has_point(screen_point):
		return null
	var local_point := screen_point - display_rect.position
	return Vector2(
		STAGE_SIZE.x * (local_point.x / maxf(display_rect.size.x, 1.0)),
		STAGE_SIZE.y * (local_point.y / maxf(display_rect.size.y, 1.0))
	)


# Cached fonts.ttf load (battle_surface.gd:9-10 font contract).
static func font() -> Font:
	if _font == null:
		_font = load(FONT_PATH)
	return _font


# _apply_battle_font pattern (battle_surface.gd:220) with an ink parameter.
static func apply_font(label: Label, ink: Color) -> void:
	label.add_theme_font_override("font", font())
	label.add_theme_font_size_override("font_size", FONT_SIZE)
	label.add_theme_color_override("font_color", ink)


# Stage Label factory: absolute integer position, fonts.ttf@7, input-ignoring.
# Non-empty text pins the accessible name (docs/references/accessibility.md);
# empty-at-build labels (mutating hints) stay unnamed so the engine tracks
# their .text as the accessible value instead of a stale pinned name.
static func make_label(text: String, pos: Vector2i, ink: Color, parent: Control) -> Label:
	var label := Label.new()
	label.text = text
	if not text.is_empty():
		label.accessibility_name = text
	label.position = Vector2(pos)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	apply_font(label, ink)
	parent.add_child(label)
	return label


# Full rect via EXPLICIT anchors + zero offsets (never set_anchors_preset on a
# parented node — the preset is rect-preserving and bakes 0x0).
static func _full_rect(node: Control) -> void:
	node.anchor_left = 0.0
	node.anchor_top = 0.0
	node.anchor_right = 1.0
	node.anchor_bottom = 1.0
	node.offset_left = 0.0
	node.offset_top = 0.0
	node.offset_right = 0.0
	node.offset_bottom = 0.0


# Full-rect child, so it receives NOTIFICATION_RESIZED whenever the host does.
class ResizeWatcher extends Control:
	var relayout: Callable

	func _notification(what: int) -> void:
		if what == NOTIFICATION_RESIZED and relayout.is_valid():
			relayout.call()
