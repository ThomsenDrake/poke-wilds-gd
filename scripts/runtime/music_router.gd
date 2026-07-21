extends Node

# Runtime audio service for background music. Maps overworld biomes (ids from
# scripts/domain/biome_defs.gd) and battle kinds to tracks under
# pokewilds/music/. Playback goes through a lazily created child
# AudioStreamPlayer, which only becomes audible once this router is added to
# the scene tree by wave-2 wiring. Missing track files are a no-op with a
# warning trace, never a crash.

const MUSIC_DIR := "res://pokewilds/music/"
const VOLUME_DB := -12.0

const DEFAULT_OVERWORLD_TRACK := MUSIC_DIR + "route_1.ogg"
const DEFAULT_BATTLE_KIND := "wild"

const BIOME_TRACKS := {
	"WATER": MUSIC_DIR + "waves1.ogg",
	"SAND": MUSIC_DIR + "MD2_BeachDusk-stitched.ogg",
	"PLAINS": MUSIC_DIR + "route_1.ogg",
	"GRASSLAND": MUSIC_DIR + "HGSS_Route29-stitched.ogg",
	"FOREST": MUSIC_DIR + "viridian_forest_gs.ogg",
	"SAVANNA": MUSIC_DIR + "nature1_render.ogg",
	"DESERT": MUSIC_DIR + "route_111-5-stitched.ogg",
	"SWAMP": MUSIC_DIR + "route_42.ogg",
	"ROCK": MUSIC_DIR + "union_cave.ogg",
	"SNOW": MUSIC_DIR + "DP_Route216-stitched.ogg",
	"LAVA": MUSIC_DIR + "RSE_MtChimney-stitched.ogg"
}

const BATTLE_TRACKS := {
	"wild": MUSIC_DIR + "wild_battle.ogg",
	"trainer": MUSIC_DIR + "pokemon_tcg_gym1.ogg",
	"legendary": MUSIC_DIR + "gsc-vs-legendary-beasts.ogg"
}

var _trace = null
var _player: AudioStreamPlayer = null
var _owned_player: AudioStreamPlayer = null


func setup(trace_logger) -> void:
	_trace = trace_logger


func play_biome_track(biome: String) -> void:
	var track_path = str(BIOME_TRACKS.get(biome, ""))
	if track_path.is_empty():
		_warn("No track mapped for biome; falling back to the default overworld theme.", {"biome": biome})
		track_path = DEFAULT_OVERWORLD_TRACK
	play_track_path(track_path)


func play_battle_track(kind: String = DEFAULT_BATTLE_KIND) -> void:
	var track_path = str(BATTLE_TRACKS.get(kind, ""))
	if track_path.is_empty():
		_warn("No track mapped for battle kind; falling back to the wild battle theme.", {"kind": kind})
		track_path = str(BATTLE_TRACKS[DEFAULT_BATTLE_KIND])
	play_track_path(track_path)


func play_track_path(track_path: String) -> void:
	# Headless has no audio device; playing there is pointless and is what
	# leaks the OGG stream (an AudioStreamPlayer still playing at process exit
	# keeps the AudioServer mixer thread holding the stream past the
	# ResourceCache sweep). Gate before create/play so the boot diagnostic and
	# every headless scenario run stay leak-free.
	if DisplayServer.get_name() == "headless":
		return
	if not ResourceLoader.exists(track_path):
		_warn("Music track is missing; skipping playback.", {"path": track_path})
		return
	var stream: AudioStream = load(track_path)
	if stream == null:
		_warn("Music track failed to load; skipping playback.", {"path": track_path})
		return
	if stream is AudioStreamOggVorbis:
		(stream as AudioStreamOggVorbis).loop = true
	var player = _ensure_player()
	if player == null:
		return
	if player.stream == stream and player.playing:
		return
	player.stream = stream
	player.volume_db = VOLUME_DB
	if player.is_inside_tree():
		player.play()


func stop() -> void:
	var player = _ensure_player()
	if player != null:
		player.stop()


func _exit_tree() -> void:
	# Defense-in-depth for windowed exit: stop playback and drop the stream so
	# the mixer thread releases the OGG reference chain. (Alone this does not
	# fix a frame-1 --quit — the headless gate above is the acceptance fix.)
	if _owned_player != null and is_instance_valid(_owned_player):
		_owned_player.stop()
		_owned_player.stream = null


func _ensure_player() -> AudioStreamPlayer:
	if _player != null and is_instance_valid(_player):
		return _player
	if _owned_player == null:
		_owned_player = AudioStreamPlayer.new()
		_owned_player.name = "MusicRouterPlayer"
		_owned_player.volume_db = VOLUME_DB
		add_child(_owned_player)
	return _owned_player


func _warn(message: String, payload: Dictionary) -> void:
	if _trace != null:
		_trace.warning("MusicRouter", message, payload)
	else:
		push_warning("MusicRouter: %s %s" % [message, JSON.stringify(payload)])
