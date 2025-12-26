extends Node
## AudioManager - Handles all game audio (music and sound effects)
## Supports crossfading between tracks and layered sound effects

# Audio bus names
const MASTER_BUS := "Master"
const MUSIC_BUS := "Music"
const SFX_BUS := "SFX"

# Music players (for crossfading)
var _music_player_a: AudioStreamPlayer
var _music_player_b: AudioStreamPlayer
var _active_music_player: AudioStreamPlayer
var _current_music_path: String = ""

# SFX pool for overlapping sounds
var _sfx_pool: Array[AudioStreamPlayer] = []
const SFX_POOL_SIZE := 8

# Fade settings
var _is_fading: bool = false
var _fade_duration: float = 0.5
var _fade_timer: float = 0.0
var _fade_from_player: AudioStreamPlayer
var _fade_to_player: AudioStreamPlayer

# Volume settings (0.0 to 1.0)
var music_volume: float = 1.0:
	set(value):
		music_volume = clampf(value, 0.0, 1.0)
		_update_music_volume()

var sfx_volume: float = 1.0:
	set(value):
		sfx_volume = clampf(value, 0.0, 1.0)
		_update_sfx_volume()

# Signals
signal music_finished
signal sfx_finished(sound_name: String)


func _ready() -> void:
	# Create audio buses if they don't exist
	_setup_audio_buses()
	
	# Create music players
	_music_player_a = AudioStreamPlayer.new()
	_music_player_a.bus = MUSIC_BUS
	add_child(_music_player_a)
	
	_music_player_b = AudioStreamPlayer.new()
	_music_player_b.bus = MUSIC_BUS
	add_child(_music_player_b)
	
	_active_music_player = _music_player_a
	
	# Connect signals
	_music_player_a.finished.connect(_on_music_finished)
	_music_player_b.finished.connect(_on_music_finished)
	
	# Create SFX pool
	for i in range(SFX_POOL_SIZE):
		var player := AudioStreamPlayer.new()
		player.bus = SFX_BUS
		add_child(player)
		_sfx_pool.append(player)
	
	print("AudioManager initialized")


func _setup_audio_buses() -> void:
	# Check if buses exist, create if not
	var bus_count := AudioServer.bus_count
	var has_music := false
	var has_sfx := false
	
	for i in range(bus_count):
		var name := AudioServer.get_bus_name(i)
		if name == MUSIC_BUS:
			has_music = true
		elif name == SFX_BUS:
			has_sfx = true
	
	if not has_music:
		var idx := AudioServer.bus_count
		AudioServer.add_bus()
		AudioServer.set_bus_name(idx, MUSIC_BUS)
		AudioServer.set_bus_send(idx, MASTER_BUS)
	
	if not has_sfx:
		var idx := AudioServer.bus_count
		AudioServer.add_bus()
		AudioServer.set_bus_name(idx, SFX_BUS)
		AudioServer.set_bus_send(idx, MASTER_BUS)


func _process(delta: float) -> void:
	if _is_fading:
		_fade_timer += delta
		var t := clampf(_fade_timer / _fade_duration, 0.0, 1.0)
		
		# Crossfade volumes
		_fade_from_player.volume_db = linear_to_db((1.0 - t) * music_volume)
		_fade_to_player.volume_db = linear_to_db(t * music_volume)
		
		if t >= 1.0:
			_is_fading = false
			_fade_from_player.stop()
			_active_music_player = _fade_to_player


func _update_music_volume() -> void:
	if not _is_fading:
		_active_music_player.volume_db = linear_to_db(music_volume)


func _update_sfx_volume() -> void:
	for player in _sfx_pool:
		player.volume_db = linear_to_db(sfx_volume)


# Music Functions
func play_music(path: String, loop: bool = true, crossfade: bool = true) -> void:
	if path == _current_music_path and _active_music_player.playing:
		return  # Already playing this track
	
	var stream := load(path) as AudioStream
	if stream == null:
		push_error("Failed to load music: " + path)
		return
	
	_current_music_path = path
	
	# Set up the new player
	var new_player := _music_player_b if _active_music_player == _music_player_a else _music_player_a
	new_player.stream = stream
	
	# Handle looping
	if stream is AudioStreamOggVorbis:
		stream.loop = loop
	elif stream is AudioStreamMP3:
		stream.loop = loop
	elif stream is AudioStreamWAV:
		if loop:
			stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
	
	if crossfade and _active_music_player.playing:
		# Start crossfade
		_is_fading = true
		_fade_timer = 0.0
		_fade_from_player = _active_music_player
		_fade_to_player = new_player
		new_player.volume_db = linear_to_db(0.0)
		new_player.play()
	else:
		# Immediate switch
		_active_music_player.stop()
		_active_music_player = new_player
		_active_music_player.volume_db = linear_to_db(music_volume)
		_active_music_player.play()


func stop_music(fade_out: bool = true) -> void:
	if fade_out:
		_is_fading = true
		_fade_timer = 0.0
		_fade_from_player = _active_music_player
		# Create a silent "to" player state
		var silent_player := _music_player_b if _active_music_player == _music_player_a else _music_player_a
		silent_player.stop()
		_fade_to_player = silent_player
	else:
		_active_music_player.stop()
	
	_current_music_path = ""


func pause_music() -> void:
	_active_music_player.stream_paused = true


func resume_music() -> void:
	_active_music_player.stream_paused = false


func is_music_playing() -> bool:
	return _active_music_player.playing and not _active_music_player.stream_paused


func get_current_music() -> String:
	return _current_music_path


# SFX Functions
func play_sfx(path: String, volume_scale: float = 1.0, pitch_scale: float = 1.0) -> void:
	var stream := load(path) as AudioStream
	if stream == null:
		push_error("Failed to load SFX: " + path)
		return
	
	# Find an available player
	var player: AudioStreamPlayer = null
	for p in _sfx_pool:
		if not p.playing:
			player = p
			break
	
	# If all players are busy, use the first one (oldest sound)
	if player == null:
		player = _sfx_pool[0]
		# Rotate pool so oldest is always first
		_sfx_pool.remove_at(0)
		_sfx_pool.append(player)
	
	player.stream = stream
	player.volume_db = linear_to_db(sfx_volume * volume_scale)
	player.pitch_scale = pitch_scale
	player.play()


func play_sfx_at_position(path: String, position: Vector2, volume_scale: float = 1.0) -> void:
	# For future 2D positional audio - currently just plays normally
	play_sfx(path, volume_scale)


func stop_all_sfx() -> void:
	for player in _sfx_pool:
		player.stop()


# Signals
func _on_music_finished() -> void:
	music_finished.emit()


# Volume helpers
func set_master_volume(volume: float) -> void:
	var bus_idx := AudioServer.get_bus_index(MASTER_BUS)
	AudioServer.set_bus_volume_db(bus_idx, linear_to_db(clampf(volume, 0.0, 1.0)))


func get_master_volume() -> float:
	var bus_idx := AudioServer.get_bus_index(MASTER_BUS)
	return db_to_linear(AudioServer.get_bus_volume_db(bus_idx))


func mute_all(muted: bool) -> void:
	var bus_idx := AudioServer.get_bus_index(MASTER_BUS)
	AudioServer.set_bus_mute(bus_idx, muted)
