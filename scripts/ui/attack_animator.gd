extends RefCounted

# Plays parsed attack-animation dicts (see scripts/data/attack_anims.gd) over
# the live battle stage: an overlay TextureRect cycles the source frames while
# per-frame metadata offsets the combatant sprites and hides HUD layers, and
# the move's sound plays once at start. Playback advances ONE FRAME PER
# PROCESS FRAME (never real-time timers): playback length is then bounded in
# process frames, so frame-counted idle waits (visual_sweep's 240-frame
# await_battle_idle) outlast it at ANY display refresh rate — a real-time
# playback clock loses that race above ~135Hz and a capture can land
# mid-animation (frozen flash modulate, pre-turn message). Every exit path
# restores sprite positions/modulates and layer visibility, and abort checks
# let the battle view cancel stale playback when a newer response arrives.
# Headless-safe: guards missing tree/instance on every step.

const MAX_SHOWN_FRAMES := 90  # ~3s at a 30fps cadence; long anims frame-skip to fit
const SOUND_VOLUME_DB := -12.0
const OVERLAY_NAME := "AttackAnimOverlay"
const FLASH_MODULATE := Color(6.0, 6.0, 6.0)


# Plays each hit turn's anim sequentially; should_abort() -> bool cancels
# between turns. Returns one stats dict per PLAYED turn (frames/sound/
# fallback plus the turn's move_id/anim_key) for the caller's trace events.
func play_turns(turns: Array, stage: Control, actors: Dictionary, should_abort: Callable) -> Array:
	var played: Array = []
	if stage == null or not is_instance_valid(stage) or not stage.is_inside_tree():
		return played
	for turn in turns:
		if _aborted(should_abort):
			break
		if not bool(turn.get("hit", false)):
			continue
		var anim: Dictionary = turn.get("anim", {})
		if anim.is_empty():
			continue
		var stats := await play(anim, stage, actors, should_abort)
		stats["move_id"] = str(turn.get("move_id", ""))
		stats["anim_key"] = str(turn.get("anim_key", ""))
		played.append(stats)
	return played


# Plays one anim dict; always restores the stage and reports what played.
func play(anim: Dictionary, stage: Control, actors: Dictionary, should_abort: Callable = Callable()) -> Dictionary:
	var stats := {"frames": 0, "sound": false, "fallback": bool(anim.get("fallback", false))}
	if stage == null or not is_instance_valid(stage) or not stage.is_inside_tree():
		return stats
	var frames: PackedStringArray = anim.get("frames", PackedStringArray())
	var source_count := maxi(frames.size(), int(anim.get("frame_count", 0)))
	if source_count <= 0:
		return stats
	# Frame-skip long anims so playback stays within MAX_SHOWN_FRAMES.
	var step := maxi(1, int(ceil(float(source_count) / float(MAX_SHOWN_FRAMES))))
	var hide_layers: Dictionary = anim.get("hide_layers_per_frame", {})
	var translate: Dictionary = anim.get("translate_per_frame", {})
	var flash: Dictionary = anim.get("flash_per_frame", {})
	stats["sound"] = _play_sound(str(anim.get("sound_path", "")), stage)
	var state := _capture_state(actors)
	var overlay := _overlay_for(stage)
	overlay.visible = true
	var tree := stage.get_tree()
	for i in range(0, source_count, step):
		if tree == null or not is_instance_valid(stage) or not stage.is_inside_tree() or _aborted(should_abort):
			break
		if i < frames.size():
			overlay.texture = load(frames[i])
		_apply_frame(hide_layers.get(i, []), translate.get(i, {}), flash.get(i, []), actors, state)
		stats["frames"] += 1
		await tree.process_frame
	_restore_state(actors, state)
	if is_instance_valid(overlay):
		overlay.visible = false
		overlay.texture = null
	return stats


func _aborted(should_abort: Callable) -> bool:
	return should_abort.is_valid() and bool(should_abort.call())


func _capture_state(actors: Dictionary) -> Dictionary:
	var state := {"base_pos": {}, "layer_vis": {}}
	for side in ["player", "enemy"]:
		var sprite = actors.get(side)
		if sprite != null and is_instance_valid(sprite):
			state["base_pos"][side] = sprite.position
	var layers: Dictionary = actors.get("layers", {})
	for layer_name in layers:
		for item in layers[layer_name]:
			if item != null and is_instance_valid(item):
				state["layer_vis"][item.get_instance_id()] = item.visible
	return state


# One playback frame: reset to base state, then apply this frame's hides,
# offsets, and white-flashes. Guarded per node so mid-play scene changes
# (audit drives, battle end) cannot crash a stale playback.
func _apply_frame(hidden_layers, translate_entry: Dictionary, flash_sides, actors: Dictionary, state: Dictionary) -> void:
	var layers: Dictionary = actors.get("layers", {})
	for layer_name in layers:
		for item in layers[layer_name]:
			if item != null and is_instance_valid(item):
				item.visible = bool(state["layer_vis"].get(item.get_instance_id(), true))
	for layer_name in hidden_layers:
		for item in layers.get(str(layer_name), []):
			if item != null and is_instance_valid(item):
				item.visible = false
	for side in ["player", "enemy"]:
		var sprite = actors.get(side)
		if sprite == null or not is_instance_valid(sprite):
			continue
		sprite.position = state["base_pos"].get(side, sprite.position) + translate_entry.get(side, Vector2.ZERO)
		sprite.modulate = FLASH_MODULATE if side in flash_sides else Color.WHITE


func _restore_state(actors: Dictionary, state: Dictionary) -> void:
	for side in ["player", "enemy"]:
		var sprite = actors.get(side)
		if sprite != null and is_instance_valid(sprite):
			sprite.position = state["base_pos"].get(side, sprite.position)
			sprite.modulate = Color.WHITE
	var layers: Dictionary = actors.get("layers", {})
	for layer_name in layers:
		for item in layers[layer_name]:
			if item != null and is_instance_valid(item):
				item.visible = bool(state["layer_vis"].get(item.get_instance_id(), true))


func _overlay_for(stage: Control) -> TextureRect:
	var existing := stage.get_node_or_null(OVERLAY_NAME)
	if existing is TextureRect:
		return existing
	var overlay := TextureRect.new()
	overlay.name = OVERLAY_NAME
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	overlay.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	overlay.stretch_mode = TextureRect.STRETCH_SCALE
	overlay.visible = false
	stage.add_child(overlay)
	return overlay


func _play_sound(path: String, stage: Control) -> bool:
	if path.is_empty() or not ResourceLoader.exists(path):
		return false
	var stream = load(path)
	if stream is not AudioStream:
		return false
	var player := AudioStreamPlayer.new()
	player.stream = stream
	player.volume_db = SOUND_VOLUME_DB
	stage.add_child(player)
	player.play()
	_free_sound_later(player, stage, maxf(0.5, stream.get_length()) + 0.25)
	return true


# Dummy audio drivers (headless) may never emit finished, so free after the
# stream's length counted in process frames instead of trusting the signal.
func _free_sound_later(player: AudioStreamPlayer, stage: Control, delay: float) -> void:
	var tree := stage.get_tree() if is_instance_valid(stage) else null
	if tree == null:
		player.queue_free()
		return
	var frames_left := int(ceil(delay * 60.0)) + 15
	while frames_left > 0:
		await tree.process_frame
		frames_left -= 1
		if not is_instance_valid(player) or not is_instance_valid(stage):
			return
	if is_instance_valid(player):
		player.queue_free()
