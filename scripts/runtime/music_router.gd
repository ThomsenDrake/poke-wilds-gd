extends RefCounted

const OVERWORLD_TRACK := "res://pokewilds/music/route_1.ogg"
const BATTLE_TRACK := "res://pokewilds/music/wild_battle.ogg"

var _player: AudioStreamPlayer = null


func bind(player: AudioStreamPlayer) -> void:
	_player = player


func play_overworld() -> void:
	_play(OVERWORLD_TRACK)


func play_battle() -> void:
	_play(BATTLE_TRACK)


func _play(track_path: String) -> void:
	if _player == null or not ResourceLoader.exists(track_path):
		return
	var stream: AudioStream = load(track_path)
	if stream == null:
		return
	if _player.stream == stream and _player.playing:
		return
	_player.stream = stream
	_player.play()
