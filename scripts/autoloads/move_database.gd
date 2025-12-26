extends Node
## MoveDatabase - Central repository for Pokemon move data
## Loads, caches, and provides access to all MoveData resources

# Signal when database is fully loaded
signal database_loaded()
signal move_loaded(move_id: String)

# All loaded moves indexed by ID
var _moves: Dictionary = {}  # String -> MoveData

# Indexes for quick lookup
var _by_type: Dictionary = {}     # TypeChart.Type -> Array[MoveData]
var _hm_moves: Array[MoveData] = []
var _tm_moves: Array[MoveData] = []

# Loading state
var _is_loaded: bool = false


func _ready() -> void:
	# Initialize type index
	for type_val in TypeChart.Type.values():
		_by_type[type_val] = []
	
	# Register test moves for development
	_register_test_moves()
	print("MoveDatabase initialized with ", _moves.size(), " moves")


## Check if database is ready
func is_loaded() -> bool:
	return _is_loaded


## Get a move by ID
func get_move(move_id: String) -> MoveData:
	var upper_id := move_id.to_upper()
	if _moves.has(upper_id):
		return _moves[upper_id]
	push_warning("Move not found: ", move_id)
	return null


## Check if a move exists
func has_move(move_id: String) -> bool:
	return _moves.has(move_id.to_upper())


## Get all move IDs
func get_all_move_ids() -> Array[String]:
	var ids: Array[String] = []
	ids.assign(_moves.keys())
	return ids


## Get move count
func get_move_count() -> int:
	return _moves.size()


## Register a move in the database
func register_move(move: MoveData) -> void:
	var upper_id := move.id.to_upper()
	_moves[upper_id] = move
	
	# Add to type index
	if move.type >= 0 and move.type < TypeChart.Type.size():
		_by_type[move.type].append(move)
	
	# Track HM/TM moves
	if move.is_hm:
		_hm_moves.append(move)
	if move.is_tm:
		_tm_moves.append(move)
	
	move_loaded.emit(upper_id)


## Get all moves of a specific type
func get_moves_by_type(type_val: int) -> Array[MoveData]:
	if _by_type.has(type_val):
		var result: Array[MoveData] = []
		result.assign(_by_type[type_val])
		return result
	return []


## Get all moves of a specific category
func get_moves_by_category(category: MoveData.Category) -> Array[MoveData]:
	var result: Array[MoveData] = []
	for move in _moves.values():
		if move.category == category:
			result.append(move)
	return result


## Get all HM moves
func get_hm_moves() -> Array[MoveData]:
	return _hm_moves


## Get all TM moves
func get_tm_moves() -> Array[MoveData]:
	return _tm_moves


## Get all moves with a specific effect
func get_moves_by_effect(effect: MoveData.Effect) -> Array[MoveData]:
	var result: Array[MoveData] = []
	for move in _moves.values():
		if move.effect == effect:
			result.append(move)
	return result


## Get all field moves
func get_field_moves() -> Array[MoveData]:
	var result: Array[MoveData] = []
	for move in _moves.values():
		if move.has_field_use():
			result.append(move)
	return result


## Get moves within a power range
func get_moves_by_power(min_power: int, max_power: int) -> Array[MoveData]:
	var result: Array[MoveData] = []
	for move in _moves.values():
		if move.power >= min_power and move.power <= max_power:
			result.append(move)
	return result


## Get random move (for testing or Metronome)
func get_random_move() -> MoveData:
	if _moves.is_empty():
		return null
	var keys := _moves.keys()
	var random_key: String = keys[randi() % keys.size()]
	return _moves[random_key]


## Load moves from a JSON file
func load_from_json(file_path: String) -> int:
	if not FileAccess.file_exists(file_path):
		push_error("Move JSON file not found: ", file_path)
		return 0
	
	var file := FileAccess.open(file_path, FileAccess.READ)
	if file == null:
		push_error("Failed to open move JSON: ", file_path)
		return 0
	
	var json := JSON.new()
	var error := json.parse(file.get_as_text())
	file.close()
	
	if error != OK:
		push_error("Failed to parse move JSON: ", json.get_error_message())
		return 0
	
	var data: Array = json.data
	var count := 0
	
	for entry in data:
		var move := MoveData.from_dict(entry)
		register_move(move)
		count += 1
	
	return count


## Register test moves for development
func _register_test_moves() -> void:
	# === NORMAL TYPE ===
	_register_move("TACKLE", "Tackle", TypeChart.Type.NORMAL, MoveData.Category.PHYSICAL, 40, 100, 35)
	_register_move("SCRATCH", "Scratch", TypeChart.Type.NORMAL, MoveData.Category.PHYSICAL, 40, 100, 35)
	_register_move("POUND", "Pound", TypeChart.Type.NORMAL, MoveData.Category.PHYSICAL, 40, 100, 35)
	_register_move("QUICK_ATTACK", "Quick Attack", TypeChart.Type.NORMAL, MoveData.Category.PHYSICAL, 40, 100, 30, MoveData.Effect.ALWAYS_FIRST)
	_register_move("SLAM", "Slam", TypeChart.Type.NORMAL, MoveData.Category.PHYSICAL, 80, 75, 20)
	_register_move("TAKE_DOWN", "Take Down", TypeChart.Type.NORMAL, MoveData.Category.PHYSICAL, 90, 85, 20, MoveData.Effect.RECOIL)
	_register_move("DOUBLE_EDGE", "Double-Edge", TypeChart.Type.NORMAL, MoveData.Category.PHYSICAL, 120, 100, 15, MoveData.Effect.RECOIL)
	_register_move("SKULL_BASH", "Skull Bash", TypeChart.Type.NORMAL, MoveData.Category.PHYSICAL, 130, 100, 10, MoveData.Effect.CHARGE_TURN)
	_register_move("GROWL", "Growl", TypeChart.Type.NORMAL, MoveData.Category.STATUS, 0, 100, 40, MoveData.Effect.LOWER_ATTACK)
	_register_move("TAIL_WHIP", "Tail Whip", TypeChart.Type.NORMAL, MoveData.Category.STATUS, 0, 100, 30, MoveData.Effect.LOWER_DEFENSE)
	_register_move("SCARY_FACE", "Scary Face", TypeChart.Type.NORMAL, MoveData.Category.STATUS, 0, 100, 10, MoveData.Effect.LOWER_SPEED)
	_register_move("DOUBLE_TEAM", "Double Team", TypeChart.Type.NORMAL, MoveData.Category.STATUS, 0, 0, 15, MoveData.Effect.RAISE_EVASION)
	_register_move("PROTECT", "Protect", TypeChart.Type.NORMAL, MoveData.Category.STATUS, 0, 0, 10, MoveData.Effect.PROTECT)
	
	# === FIRE TYPE ===
	_register_move("EMBER", "Ember", TypeChart.Type.FIRE, MoveData.Category.SPECIAL, 40, 100, 25, MoveData.Effect.BURN, 10)
	_register_move("FIRE_FANG", "Fire Fang", TypeChart.Type.FIRE, MoveData.Category.PHYSICAL, 65, 95, 15, MoveData.Effect.BURN, 10)
	_register_move("FLAME_BURST", "Flame Burst", TypeChart.Type.FIRE, MoveData.Category.SPECIAL, 70, 100, 15)
	_register_move("FLAMETHROWER", "Flamethrower", TypeChart.Type.FIRE, MoveData.Category.SPECIAL, 90, 100, 15, MoveData.Effect.BURN, 10)
	_register_move("FIRE_SPIN", "Fire Spin", TypeChart.Type.FIRE, MoveData.Category.SPECIAL, 35, 85, 15, MoveData.Effect.TRAP)
	_register_move("INFERNO", "Inferno", TypeChart.Type.FIRE, MoveData.Category.SPECIAL, 100, 50, 5, MoveData.Effect.BURN, 100)
	_register_move("FLARE_BLITZ", "Flare Blitz", TypeChart.Type.FIRE, MoveData.Category.PHYSICAL, 120, 100, 15, MoveData.Effect.RECOIL)
	_register_move("SMOKESCREEN", "Smokescreen", TypeChart.Type.NORMAL, MoveData.Category.STATUS, 0, 100, 20, MoveData.Effect.LOWER_ACCURACY)
	
	# === WATER TYPE ===
	_register_move("WATER_GUN", "Water Gun", TypeChart.Type.WATER, MoveData.Category.SPECIAL, 40, 100, 25)
	_register_move("BUBBLE", "Bubble", TypeChart.Type.WATER, MoveData.Category.SPECIAL, 40, 100, 30, MoveData.Effect.LOWER_SPEED, 10)
	_register_move("WATER_PULSE", "Water Pulse", TypeChart.Type.WATER, MoveData.Category.SPECIAL, 60, 100, 20, MoveData.Effect.CONFUSE, 20)
	_register_move("AQUA_TAIL", "Aqua Tail", TypeChart.Type.WATER, MoveData.Category.PHYSICAL, 90, 90, 10)
	_register_move("HYDRO_PUMP", "Hydro Pump", TypeChart.Type.WATER, MoveData.Category.SPECIAL, 110, 80, 5)
	_register_move("WITHDRAW", "Withdraw", TypeChart.Type.WATER, MoveData.Category.STATUS, 0, 0, 40, MoveData.Effect.RAISE_DEFENSE)
	_register_move("RAIN_DANCE", "Rain Dance", TypeChart.Type.WATER, MoveData.Category.STATUS, 0, 0, 5, MoveData.Effect.WEATHER_RAIN)
	_register_move("RAPID_SPIN", "Rapid Spin", TypeChart.Type.NORMAL, MoveData.Category.PHYSICAL, 50, 100, 40)
	
	# === GRASS TYPE ===
	_register_move("VINE_WHIP", "Vine Whip", TypeChart.Type.GRASS, MoveData.Category.PHYSICAL, 45, 100, 25)
	_register_move("RAZOR_LEAF", "Razor Leaf", TypeChart.Type.GRASS, MoveData.Category.PHYSICAL, 55, 95, 25)
	_register_move("SEED_BOMB", "Seed Bomb", TypeChart.Type.GRASS, MoveData.Category.PHYSICAL, 80, 100, 15)
	_register_move("SOLAR_BEAM", "Solar Beam", TypeChart.Type.GRASS, MoveData.Category.SPECIAL, 120, 100, 10, MoveData.Effect.CHARGE_TURN)
	_register_move("GROWTH", "Growth", TypeChart.Type.NORMAL, MoveData.Category.STATUS, 0, 0, 20, MoveData.Effect.RAISE_SPECIAL_ATTACK)
	_register_move("LEECH_SEED", "Leech Seed", TypeChart.Type.GRASS, MoveData.Category.STATUS, 0, 90, 10, MoveData.Effect.LEECH_SEED)
	_register_move("POISON_POWDER", "Poison Powder", TypeChart.Type.POISON, MoveData.Category.STATUS, 0, 75, 35, MoveData.Effect.POISON)
	_register_move("SLEEP_POWDER", "Sleep Powder", TypeChart.Type.GRASS, MoveData.Category.STATUS, 0, 75, 15, MoveData.Effect.SLEEP)
	_register_move("SWEET_SCENT", "Sweet Scent", TypeChart.Type.NORMAL, MoveData.Category.STATUS, 0, 100, 20, MoveData.Effect.LOWER_EVASION)
	_register_move("SYNTHESIS", "Synthesis", TypeChart.Type.GRASS, MoveData.Category.STATUS, 0, 0, 5, MoveData.Effect.HEAL_SELF)
	_register_move("WORRY_SEED", "Worry Seed", TypeChart.Type.GRASS, MoveData.Category.STATUS, 0, 100, 10)
	
	# === ELECTRIC TYPE ===
	_register_move("THUNDER_SHOCK", "Thunder Shock", TypeChart.Type.ELECTRIC, MoveData.Category.SPECIAL, 40, 100, 30, MoveData.Effect.PARALYZE, 10)
	_register_move("SPARK", "Spark", TypeChart.Type.ELECTRIC, MoveData.Category.PHYSICAL, 65, 100, 20, MoveData.Effect.PARALYZE, 30)
	_register_move("ELECTRO_BALL", "Electro Ball", TypeChart.Type.ELECTRIC, MoveData.Category.SPECIAL, 60, 100, 10)  # Power varies
	_register_move("DISCHARGE", "Discharge", TypeChart.Type.ELECTRIC, MoveData.Category.SPECIAL, 80, 100, 15, MoveData.Effect.PARALYZE, 30)
	_register_move("WILD_CHARGE", "Wild Charge", TypeChart.Type.ELECTRIC, MoveData.Category.PHYSICAL, 90, 100, 15, MoveData.Effect.RECOIL)
	_register_move("THUNDER", "Thunder", TypeChart.Type.ELECTRIC, MoveData.Category.SPECIAL, 110, 70, 10, MoveData.Effect.PARALYZE, 30)
	_register_move("THUNDER_WAVE", "Thunder Wave", TypeChart.Type.ELECTRIC, MoveData.Category.STATUS, 0, 90, 20, MoveData.Effect.PARALYZE)
	_register_move("AGILITY", "Agility", TypeChart.Type.PSYCHIC, MoveData.Category.STATUS, 0, 0, 30, MoveData.Effect.RAISE_SPEED)
	_register_move("LIGHT_SCREEN", "Light Screen", TypeChart.Type.PSYCHIC, MoveData.Category.STATUS, 0, 0, 30, MoveData.Effect.LIGHT_SCREEN)
	
	# === DRAGON TYPE ===
	_register_move("DRAGON_RAGE", "Dragon Rage", TypeChart.Type.DRAGON, MoveData.Category.SPECIAL, 0, 100, 10, MoveData.Effect.FIXED_DAMAGE)
	
	# === FIGHTING TYPE ===
	_register_move("BITE", "Bite", TypeChart.Type.DARK, MoveData.Category.PHYSICAL, 60, 100, 25, MoveData.Effect.FLINCH, 30)
	_register_move("SLASH", "Slash", TypeChart.Type.NORMAL, MoveData.Category.PHYSICAL, 70, 100, 20)  # High crit
	
	# === STEEL TYPE ===
	_register_move("IRON_DEFENSE", "Iron Defense", TypeChart.Type.STEEL, MoveData.Category.STATUS, 0, 0, 15, MoveData.Effect.RAISE_DEFENSE)
	
	# === HM MOVES (with field effects) ===
	var cut := _register_move("CUT", "Cut", TypeChart.Type.NORMAL, MoveData.Category.PHYSICAL, 50, 95, 30)
	cut.is_hm = true
	cut.field_effect = MoveData.Effect.FIELD_CUT
	
	var fly := _register_move("FLY", "Fly", TypeChart.Type.FLYING, MoveData.Category.PHYSICAL, 90, 95, 15, MoveData.Effect.CHARGE_TURN)
	fly.is_hm = true
	fly.field_effect = MoveData.Effect.FIELD_FLY
	
	var surf := _register_move("SURF", "Surf", TypeChart.Type.WATER, MoveData.Category.SPECIAL, 90, 100, 15)
	surf.is_hm = true
	surf.field_effect = MoveData.Effect.FIELD_SURF
	
	var strength := _register_move("STRENGTH", "Strength", TypeChart.Type.NORMAL, MoveData.Category.PHYSICAL, 80, 100, 15)
	strength.is_hm = true
	strength.field_effect = MoveData.Effect.FIELD_STRENGTH
	
	var flash := _register_move("FLASH", "Flash", TypeChart.Type.NORMAL, MoveData.Category.STATUS, 0, 100, 20, MoveData.Effect.LOWER_ACCURACY)
	flash.is_hm = true
	flash.field_effect = MoveData.Effect.FIELD_FLASH
	
	var rock_smash := _register_move("ROCK_SMASH", "Rock Smash", TypeChart.Type.FIGHTING, MoveData.Category.PHYSICAL, 40, 100, 15, MoveData.Effect.LOWER_DEFENSE, 50)
	rock_smash.is_hm = true
	rock_smash.field_effect = MoveData.Effect.FIELD_ROCK_SMASH
	
	var waterfall := _register_move("WATERFALL", "Waterfall", TypeChart.Type.WATER, MoveData.Category.PHYSICAL, 80, 100, 15, MoveData.Effect.FLINCH, 20)
	waterfall.is_hm = true
	waterfall.field_effect = MoveData.Effect.FIELD_WATERFALL
	
	var dig := _register_move("DIG", "Dig", TypeChart.Type.GROUND, MoveData.Category.PHYSICAL, 80, 100, 10, MoveData.Effect.CHARGE_TURN)
	dig.is_hm = true
	dig.field_effect = MoveData.Effect.FIELD_DIG
	
	var headbutt := _register_move("HEADBUTT", "Headbutt", TypeChart.Type.NORMAL, MoveData.Category.PHYSICAL, 70, 100, 15, MoveData.Effect.FLINCH, 30)
	headbutt.is_hm = true
	headbutt.field_effect = MoveData.Effect.FIELD_HEADBUTT
	
	_is_loaded = true
	database_loaded.emit()


## Helper to register a move quickly
func _register_move(
	id: String,
	name: String,
	type: int,
	category: MoveData.Category,
	power: int,
	accuracy: int,
	pp: int,
	effect: MoveData.Effect = MoveData.Effect.NONE,
	effect_chance: int = 0
) -> MoveData:
	var move := MoveData.create(id, name, type, category, power, accuracy, pp, effect, effect_chance)
	register_move(move)
	return move
