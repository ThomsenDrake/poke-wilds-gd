extends RefCounted

# Player-avatar sprite frames, EXTRACTED from player_avatar.gd (both at the 320 runtime
# budget): builds the walk/run SpriteFrames from the one-row-of-eight 16x16 sheets — idle
# down/up/left/right (0-3) then stride (4-7), so walk and run share one frame map under a
# "run_" animation-name prefix. Pure presentation: no game state, no rng, no input.
# Sheets resolve by AVATAR NAME (creation-flow slice): res://pokewilds/player/
# <name>-walking.png + <name>-running.png. The default "ben" is exactly the pre-slice
# hardcoded sheet pair, so every existing render keeps its pixels. The -back/-sitting/
# -sleepingbag/-fishing variants have NO consumers in the port yet; they follow the
# identical <name>-<variant>.png grammar, so future consumers read session.player_avatar
# and format their paths the same way.

const TILE_SIZE := 16
const WALK_ANIMATION_FPS := 12.5
const DEFAULT_AVATAR_NAME := "ben"
const LEGACY_WALK_SHEET_PATH := "res://pokewilds/player/kris-walking.png" # pre-avatar-knob fallback, kept

# Null when no walk sheet loads (the avatar keeps its scene-default frames) — mirrors the
# pre-extraction early-return exactly. Fallback chain: requested walk sheet -> ben walk ->
# kris walk (LEGACY) -> null; a missing run sheet falls back to the walk sheet, as today.
static func build(avatar_name: String = DEFAULT_AVATAR_NAME) -> SpriteFrames:
	var walk_sheet: Texture2D = load(_sheet_path(avatar_name, "walking"))
	if walk_sheet == null:
		walk_sheet = load(_sheet_path(DEFAULT_AVATAR_NAME, "walking"))
	if walk_sheet == null:
		walk_sheet = load(LEGACY_WALK_SHEET_PATH)
	if walk_sheet == null:
		return null
	var run_sheet: Texture2D = load(_sheet_path(avatar_name, "running"))
	if run_sheet == null:
		run_sheet = walk_sheet
	var frames := SpriteFrames.new()
	_add_sheet_animations(frames, walk_sheet, "")
	_add_sheet_animations(frames, run_sheet, "run_")
	return frames


static func _sheet_path(avatar_name: String, sheet_kind: String) -> String:
	return "res://pokewilds/player/%s-%s.png" % [avatar_name, sheet_kind]


static func _add_sheet_animations(frames: SpriteFrames, sheet: Texture2D, prefix: String) -> void:
	var frame_map = {
		"down": [0, 4],
		"up": [1, 5],
		"left": [2, 6],
		"right": [3, 7]
	}
	for animation_name in frame_map.keys():
		var full_name := prefix + str(animation_name)
		frames.add_animation(full_name)
		frames.set_animation_speed(full_name, WALK_ANIMATION_FPS)
		frames.set_animation_loop(full_name, true)
		for frame_index in frame_map[animation_name]:
			var frame = AtlasTexture.new()
			frame.atlas = sheet
			frame.region = Rect2(frame_index * TILE_SIZE, 0, TILE_SIZE, TILE_SIZE)
			frames.add_frame(full_name, frame)
