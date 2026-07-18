extends Node

# Runtime audio service for Pokemon cries. Resolves a dex number to the
# zero-padded source cry under pokewilds/pokemon/cries/ (000.ogg is the
# fallback/unknown entry) and plays it through a lazily created child
# AudioStreamPlayer, which only becomes audible once this node is added to
# the scene tree by app wiring. One cry at a time: a new play_cry replaces
# whatever is currently playing. Missing files are a no-op with a warning
# trace, never a crash.

const CRIES_DIR := "res://pokewilds/pokemon/cries/"
const VOLUME_DB := -12.0

var _trace = null
var _player: AudioStreamPlayer = null


func setup(trace_logger) -> void:
	_trace = trace_logger


static func cry_path_for_dex(dex_number: int) -> String:
	return "%s%03d.ogg" % [CRIES_DIR, maxi(dex_number, 0)]


func play_cry(dex_number: int) -> void:
	var cry_path := cry_path_for_dex(dex_number)
	if not ResourceLoader.exists(cry_path):
		_warn("Cry file is missing; skipping playback.", {"dex_number": dex_number, "path": cry_path})
		return
	var stream: AudioStream = load(cry_path)
	if stream == null:
		_warn("Cry file failed to load; skipping playback.", {"dex_number": dex_number, "path": cry_path})
		return
	if stream is AudioStreamOggVorbis:
		(stream as AudioStreamOggVorbis).loop = false
	var player = _ensure_player()
	if player == null:
		return
	player.stop()
	player.stream = stream
	player.volume_db = VOLUME_DB
	if player.is_inside_tree():
		player.play()


func stop() -> void:
	if _player != null and is_instance_valid(_player):
		_player.stop()


func _ensure_player() -> AudioStreamPlayer:
	if _player != null and is_instance_valid(_player):
		return _player
	_player = AudioStreamPlayer.new()
	_player.name = "CryPlayerStream"
	_player.volume_db = VOLUME_DB
	add_child(_player)
	return _player


func _warn(message: String, payload: Dictionary) -> void:
	if _trace != null:
		_trace.warning("CryPlayer", message, payload)
	else:
		push_warning("CryPlayer: %s %s" % [message, JSON.stringify(payload)])
