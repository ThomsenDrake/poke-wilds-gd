extends RefCounted

# Resolver and parser for the source attack-animation sets under
# pokewilds/attacks/. Each set lives in a <move>_<side>_gsc directory with:
#   metadata.out   per-frame effect script ("31, player_healthbar_gone player_translate_x:2")
#   output/        sequential 160x144 overlay frames (frame-001.png, ...; mostly
#                  transparent, meant to sit over the live battle stage)
#   sound.ogg      the move's sound, played once at animation start
# Metadata frame numbers do not align 1:1 with the rendered output frames, so
# rows are mapped onto output frames by normalized position; effects that
# express state (layer hides) carry forward, translations are per-row absolute
# offsets (a missing translate token means "back to base position").
# Parsing never crashes on missing pieces: an unusable key yields {} and the
# caller falls back to fallback_anim(). Parsed dicts are cached per key.

const ATTACKS_DIR := "res://pokewilds/attacks"
const FALLBACK_SOUND_PATH := "res://pokewilds/sounds/hit.ogg"
const FALLBACK_FRAMES := 14
const FALLBACK_LUNGE_PX := 4.0

# Sprite hide/show tokens are honored (fly/dig-style disappearances). The
# *_healthbar_gone tokens are intentionally NOT honored: the source's
# full-screen frame composites carried their own HUD state, but this port
# plays blank overlays, so hiding the live HUD would leave a gray track with
# no fill for the whole animation. The HUD stays up during move usage.
const HIDE_TOKENS := {
	"player_sprite_gone": "player_sprite",
	"enemy_sprite_gone": "enemy_sprite",
	"player_sprite_hide": "player_sprite",
	"enemy_sprite_hide": "enemy_sprite",
}
const SHOW_TOKENS := {
	"player_sprite_show": "player_sprite",
	"enemy_sprite_show": "enemy_sprite",
}

var _cache := {}
var _dir_names: PackedStringArray = []


# Contract resolver: player-perspective key for a move id ("RAZOR_LEAF" ->
# "razor_leaf_player_gsc"), or "" when no set exists for that move.
func anim_key_for_move(move_id: String) -> String:
	return anim_key_for_actor(move_id, "player")


# Battle playback resolves per acting side: enemy moves use the *_enemy_gsc set.
func anim_key_for_actor(move_id: String, actor_side: String) -> String:
	var base := move_id.strip_edges().to_lower()
	if base.is_empty():
		return ""
	_scan_dirs_once()
	var key := "%s_%s_gsc" % [base, actor_side]
	return key if key in _dir_names else ""


# Parsed anim dict, or {} when the key is unknown or its files are unusable.
func load(anim_key: String) -> Dictionary:
	if anim_key.is_empty():
		return {}
	if _cache.has(anim_key):
		return _cache[anim_key]
	var parsed := _parse_anim(anim_key)
	_cache[anim_key] = parsed
	return parsed


# One battle-turn entry for BattleRuntime responses. The parsed anim travels
# inside the turn so ui-layer consumers never touch the data layer.
func turn_for(actor_side: String, attack_result: Dictionary) -> Dictionary:
	var move_id := str(attack_result.get("move_id", ""))
	var anim_key := anim_key_for_actor(move_id, actor_side)
	# NOTE: bare load(...) would bind to the global ResourceLoader shorthand even
	# inside this class, so the parser method is invoked through self.
	var anim: Dictionary = self.load(anim_key) if not anim_key.is_empty() else {}
	if anim.is_empty():
		anim = fallback_anim(actor_side)
	return {
		"actor": actor_side,
		"move_id": move_id,
		"anim_key": anim_key,
		"hit": bool(attack_result.get("hit", false)),
		"damage": int(attack_result.get("damage", 0)),
		"anim": anim,
	}


# Synthesized anim for moves without a source set: short attacker lunge
# (4px out-and-back) plus a defender white-flash and a generic hit sound,
# expressed through the same playback contract as parsed anims.
func fallback_anim(actor_side: String) -> Dictionary:
	var defender := "enemy" if actor_side == "player" else "player"
	var direction := 1.0 if actor_side == "player" else -1.0
	var translate := {}
	var flash := {}
	for i in range(FALLBACK_FRAMES):
		var phase := sin(float(i) / float(FALLBACK_FRAMES - 1) * PI)
		var entry := {"player": Vector2.ZERO, "enemy": Vector2.ZERO}
		entry[actor_side] = Vector2(direction * FALLBACK_LUNGE_PX * phase, 0.0)
		translate[i] = entry
		if i in [5, 6, 9, 10]:
			flash[i] = PackedStringArray([defender])
	return {
		"frames": PackedStringArray(),
		"hide_layers_per_frame": {},
		"translate_per_frame": translate,
		"flash_per_frame": flash,
		"sound_path": FALLBACK_SOUND_PATH,
		"frame_count": FALLBACK_FRAMES,
		"fallback": true,
	}


func _scan_dirs_once() -> void:
	if not _dir_names.is_empty():
		return
	var dir := DirAccess.open(ATTACKS_DIR)
	if dir == null:
		return
	for name in dir.get_directories():
		_dir_names.append(name)


func _parse_anim(anim_key: String) -> Dictionary:
	var base_dir := "%s/%s" % [ATTACKS_DIR, anim_key]
	var frames := _frame_paths("%s/output" % base_dir)
	if frames.is_empty():
		return {}
	var sound_path := "%s/sound.ogg" % base_dir
	if not FileAccess.file_exists(sound_path):
		sound_path = ""
	var mapped := _map_rows_to_frames(_metadata_rows("%s/metadata.out" % base_dir), frames.size())
	return {
		"frames": frames,
		"hide_layers_per_frame": mapped["hide"],
		"translate_per_frame": mapped["translate"],
		"sound_path": sound_path,
		"frame_count": frames.size(),
		"fallback": false,
	}


func _frame_paths(output_dir: String) -> PackedStringArray:
	var paths: PackedStringArray = []
	var dir := DirAccess.open(output_dir)
	if dir == null:
		return paths
	var names := dir.get_files()
	names.sort()
	for name in names:
		if name.begins_with("frame-") and name.ends_with(".png"):
			paths.append("%s/%s" % [output_dir, name])
	return paths


# metadata.out rows: "<frame_number>, <token> <token> ..." -> row -> tokens.
func _metadata_rows(path: String) -> Dictionary:
	var rows := {}
	if not FileAccess.file_exists(path):
		return rows
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return rows
	while not file.eof_reached():
		var line := file.get_line().strip_edges()
		var comma := line.find(",")
		if comma <= 0:
			continue
		rows[line.left(comma).to_int()] = line.substr(comma + 1).split(" ", false)
	file.close()
	return rows


# Maps metadata rows onto output frames by normalized row position. Layer
# hides are persistent state and carry forward; translations are per-row
# absolute and hold until the next mapped row replaces them.
func _map_rows_to_frames(rows: Dictionary, frame_count: int) -> Dictionary:
	var hide := {}
	var translate := {}
	if rows.is_empty() or frame_count <= 0:
		return {"hide": hide, "translate": translate}
	var row_ids := rows.keys()
	row_ids.sort()
	var min_row: int = row_ids[0]
	var span := maxi(1, int(row_ids[row_ids.size() - 1]) - min_row)
	var hidden := {}
	var offsets := {"player": Vector2.ZERO, "enemy": Vector2.ZERO}
	var cursor := 0
	for frame_idx in range(frame_count):
		var row_target := min_row + roundi(float(frame_idx) / float(maxi(1, frame_count - 1)) * float(span))
		while cursor < row_ids.size() and int(row_ids[cursor]) <= row_target:
			offsets = _apply_row_tokens(rows[row_ids[cursor]], hidden)
			cursor += 1
		if not hidden.is_empty():
			hide[frame_idx] = PackedStringArray(hidden.keys())
		if offsets["player"] != Vector2.ZERO or offsets["enemy"] != Vector2.ZERO:
			translate[frame_idx] = {"player": offsets["player"], "enemy": offsets["enemy"]}
	return {"hide": hide, "translate": translate}


# Applies one metadata row: mutates the hidden-layer set and returns the row's
# absolute per-side sprite offsets.
func _apply_row_tokens(tokens: PackedStringArray, hidden: Dictionary) -> Dictionary:
	var offsets := {"player": Vector2.ZERO, "enemy": Vector2.ZERO}
	for token_variant in tokens:
		var token := str(token_variant)
		if HIDE_TOKENS.has(token):
			hidden[HIDE_TOKENS[token]] = true
		elif SHOW_TOKENS.has(token):
			hidden.erase(SHOW_TOKENS[token])
		elif token.begins_with("player_translate_x:"):
			offsets["player"].x = token.get_slice(":", 1).to_float()
		elif token.begins_with("player_translate_y:"):
			offsets["player"].y = token.get_slice(":", 1).to_float()
		elif token.begins_with("enemy_translate_x:"):
			offsets["enemy"].x = token.get_slice(":", 1).to_float()
		elif token.begins_with("enemy_translate_y:"):
			offsets["enemy"].y = token.get_slice(":", 1).to_float()
	return offsets
