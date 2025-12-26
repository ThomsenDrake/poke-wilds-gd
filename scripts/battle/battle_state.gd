class_name BattleState
extends RefCounted
## BattleState - Represents the current state of a battle
## Contains all participants, field effects, and battle history

# Battle types
enum BattleType {
	WILD,           # Wild Pokemon encounter
	TRAINER,        # Trainer battle (not in PokeWilds)
	LEGENDARY       # Special legendary encounter
}

# Battle phases
enum Phase {
	INTRO,          # Battle starting animation
	ACTION_SELECT,  # Player choosing action
	MOVE_SELECT,    # Player choosing move
	TARGET_SELECT,  # Player choosing target (doubles)
	TURN_EXECUTE,   # Executing turn actions
	TURN_END,       # End of turn effects
	SWITCH_SELECT,  # Player choosing switch
	CATCH_ATTEMPT,  # Throwing pokeball
	RUN_ATTEMPT,    # Attempting to flee
	VICTORY,        # Player won
	DEFEAT,         # Player lost (all fainted)
	FLED,           # Successfully fled
	CAUGHT          # Pokemon was caught
}

# Current phase
var phase: Phase = Phase.INTRO

# Battle type
var battle_type: BattleType = BattleType.WILD

# Participants
var player_party: Array[Pokemon] = []       # Player's full party
var player_active: Pokemon = null           # Currently active player Pokemon
var player_active_index: int = 0

var enemy_party: Array[Pokemon] = []        # Enemy party (usually 1 for wild)
var enemy_active: Pokemon = null            # Currently active enemy Pokemon
var enemy_active_index: int = 0

# Original Pokemon data (for resetting stat stages on switch)
var player_original_stats: Dictionary = {}
var enemy_original_stats: Dictionary = {}

# Turn tracking
var turn_number: int = 0
var flee_attempts: int = 0

# Field effects
var weather: String = "clear"  # clear, rain, sun, sandstorm, hail
var weather_turns: int = 0

var player_side_effects: Dictionary = {
	"reflect": 0,      # Turns remaining
	"light_screen": 0,
	"spikes": 0,
	"toxic_spikes": 0
}

var enemy_side_effects: Dictionary = {
	"reflect": 0,
	"light_screen": 0,
	"spikes": 0,
	"toxic_spikes": 0
}

# Actions for current turn
var player_action: Dictionary = {}  # {type: "attack/switch/item/run", data: ...}
var enemy_action: Dictionary = {}

# Battle log for UI
var battle_log: Array[String] = []

# Callbacks
var on_phase_changed: Callable
var on_pokemon_switched: Callable
var on_battle_ended: Callable


func _init(type: BattleType = BattleType.WILD) -> void:
	battle_type = type


## Initialize battle with parties
func setup(p_player_party: Array, p_enemy_party: Array) -> void:
	player_party.clear()
	enemy_party.clear()
	
	for p in p_player_party:
		if p is Pokemon:
			player_party.append(p)
	
	for p in p_enemy_party:
		if p is Pokemon:
			enemy_party.append(p)
	
	# Set first healthy Pokemon as active
	player_active = _get_first_healthy(player_party)
	player_active_index = player_party.find(player_active)
	
	enemy_active = _get_first_healthy(enemy_party)
	enemy_active_index = enemy_party.find(enemy_active)
	
	# Reset state
	turn_number = 0
	flee_attempts = 0
	battle_log.clear()
	
	# Store original stats for reference
	if player_active:
		player_original_stats = _snapshot_stats(player_active)
	if enemy_active:
		enemy_original_stats = _snapshot_stats(enemy_active)


func _get_first_healthy(party: Array[Pokemon]) -> Pokemon:
	for p in party:
		if p and p.can_battle():
			return p
	return null


func _snapshot_stats(pokemon: Pokemon) -> Dictionary:
	return {
		"max_hp": pokemon.max_hp,
		"attack": pokemon.max_attack,
		"defense": pokemon.max_defense,
		"sp_attack": pokemon.max_sp_attack,
		"sp_defense": pokemon.max_sp_defense,
		"speed": pokemon.max_speed
	}


## Change battle phase
func set_phase(new_phase: Phase) -> void:
	var old_phase := phase
	phase = new_phase
	
	if on_phase_changed.is_valid():
		on_phase_changed.call(old_phase, new_phase)


## Add message to battle log
func log_message(message: String) -> void:
	battle_log.append(message)
	print("[Battle] ", message)


## Check if player has healthy Pokemon
func player_has_healthy_pokemon() -> bool:
	for p in player_party:
		if p and p.can_battle():
			return true
	return false


## Check if enemy has healthy Pokemon
func enemy_has_healthy_pokemon() -> bool:
	for p in enemy_party:
		if p and p.can_battle():
			return true
	return false


## Get healthy Pokemon count
func get_player_healthy_count() -> int:
	var count := 0
	for p in player_party:
		if p and p.can_battle():
			count += 1
	return count


func get_enemy_healthy_count() -> int:
	var count := 0
	for p in enemy_party:
		if p and p.can_battle():
			count += 1
	return count


## Switch player Pokemon
func switch_player_pokemon(index: int) -> bool:
	if index < 0 or index >= player_party.size():
		return false
	
	var new_pokemon: Pokemon = player_party[index]
	if new_pokemon == null or not new_pokemon.can_battle():
		return false
	
	if new_pokemon == player_active:
		return false
	
	# Reset stat stages of outgoing Pokemon
	if player_active:
		player_active.reset_stages()
		player_active.clear_volatile_statuses()
	
	player_active = new_pokemon
	player_active_index = index
	
	log_message("Go! " + player_active.get_display_name() + "!")
	
	if on_pokemon_switched.is_valid():
		on_pokemon_switched.call(true, player_active)
	
	return true


## Switch enemy Pokemon
func switch_enemy_pokemon(index: int) -> bool:
	if index < 0 or index >= enemy_party.size():
		return false
	
	var new_pokemon: Pokemon = enemy_party[index]
	if new_pokemon == null or not new_pokemon.can_battle():
		return false
	
	if new_pokemon == enemy_active:
		return false
	
	# Reset stat stages
	if enemy_active:
		enemy_active.reset_stages()
		enemy_active.clear_volatile_statuses()
	
	enemy_active = new_pokemon
	enemy_active_index = index
	
	log_message("Wild " + enemy_active.get_display_name() + " appeared!")
	
	if on_pokemon_switched.is_valid():
		on_pokemon_switched.call(false, enemy_active)
	
	return true


## Set player action for turn
func set_player_action(action_type: String, data: Variant = null) -> void:
	player_action = {"type": action_type, "data": data}


## Determine enemy action (AI)
func determine_enemy_action() -> void:
	if enemy_active == null or not enemy_active.can_battle():
		enemy_action = {"type": "none", "data": null}
		return
	
	# Simple AI: pick a random attacking move
	var moves := enemy_active.move_ids
	var valid_moves: Array[int] = []
	
	for i in range(moves.size()):
		var move := MoveDatabase.get_move(moves[i])
		if move and enemy_active.move_pp[i] > 0:
			valid_moves.append(i)
	
	if valid_moves.is_empty():
		# Struggle
		enemy_action = {"type": "attack", "data": {"move_index": -1, "move_id": "STRUGGLE"}}
	else:
		var chosen := valid_moves[randi() % valid_moves.size()]
		enemy_action = {"type": "attack", "data": {"move_index": chosen, "move_id": moves[chosen]}}


## Check if player moves first
func player_moves_first() -> bool:
	if player_action.type == "run" or player_action.type == "switch" or player_action.type == "item":
		return true
	if enemy_action.type == "switch":
		return false
	
	# Compare move priorities
	var player_priority := 0
	var enemy_priority := 0
	
	if player_action.type == "attack" and player_action.data:
		var move := MoveDatabase.get_move(player_action.data.get("move_id", ""))
		if move:
			player_priority = move.priority
	
	if enemy_action.type == "attack" and enemy_action.data:
		var move := MoveDatabase.get_move(enemy_action.data.get("move_id", ""))
		if move:
			enemy_priority = move.priority
	
	if player_priority != enemy_priority:
		return player_priority > enemy_priority
	
	# Speed check
	var player_speed := player_active.get_effective_stat("speed") if player_active else 0
	var enemy_speed := enemy_active.get_effective_stat("speed") if enemy_active else 0
	
	# Paralysis halves speed
	if player_active and player_active.status == Pokemon.Status.PARALYSIS:
		player_speed = player_speed / 4  # Gen 2: 1/4 speed when paralyzed
	if enemy_active and enemy_active.status == Pokemon.Status.PARALYSIS:
		enemy_speed = enemy_speed / 4
	
	if player_speed != enemy_speed:
		return player_speed > enemy_speed
	
	# Speed tie: random
	return randi() % 2 == 0


## Can player flee from this battle?
func can_flee() -> bool:
	return battle_type == BattleType.WILD


## Can player catch in this battle?
func can_catch() -> bool:
	return battle_type == BattleType.WILD or battle_type == BattleType.LEGENDARY


## Get active wild Pokemon for catching
func get_catch_target() -> Pokemon:
	if can_catch():
		return enemy_active
	return null


## Clean up after battle ends
func cleanup() -> void:
	# Reset stat stages for all Pokemon
	for p in player_party:
		if p:
			p.reset_stages()
			p.clear_volatile_statuses()
	
	for p in enemy_party:
		if p:
			p.reset_stages()
			p.clear_volatile_statuses()
