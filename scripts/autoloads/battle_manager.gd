extends Node
## BattleManager - Global battle state and execution manager
## Handles battle flow, turn execution, and transitions

# Signals
signal battle_started(battle_state: BattleState)
signal battle_ended(result: String, data: Dictionary)
signal turn_started(turn_number: int)
signal turn_ended(turn_number: int)
signal phase_changed(old_phase: BattleState.Phase, new_phase: BattleState.Phase)
signal message_queued(message: String)
signal pokemon_damaged(is_player: bool, damage: int, remaining_hp: int)
signal pokemon_fainted(is_player: bool, pokemon: Pokemon)
signal pokemon_switched(is_player: bool, pokemon: Pokemon)
signal move_used(is_player: bool, pokemon: Pokemon, move: MoveData)
signal effectiveness_shown(message: String)

# Current battle state
var current_battle: BattleState = null
var is_in_battle: bool = false

# Message queue for sequential display
var _message_queue: Array[String] = []
var _is_processing_messages: bool = false

# Battle scene reference
var _battle_scene: Node = null


func _ready() -> void:
	print("BattleManager initialized")


## Start a new wild battle
func start_wild_battle(player_party: Array, wild_pokemon: Pokemon) -> void:
	if is_in_battle:
		push_warning("Already in battle!")
		return
	
	# Safety check: ensure we have valid participants
	if player_party.is_empty():
		push_error("Cannot start battle: player party is empty!")
		return
	if wild_pokemon == null:
		push_error("Cannot start battle: wild Pokemon is null!")
		return
	
	current_battle = BattleState.new(BattleState.BattleType.WILD)
	current_battle.setup(player_party, [wild_pokemon])
	current_battle.on_phase_changed = _on_phase_changed
	current_battle.on_pokemon_switched = _on_pokemon_switched
	
	# Verify setup succeeded
	if current_battle.player_active == null:
		push_error("Cannot start battle: no healthy Pokemon in party!")
		current_battle = null
		return
	
	is_in_battle = true
	
	# Log intro
	current_battle.log_message("Wild " + wild_pokemon.get_display_name() + " appeared!")
	current_battle.log_message("Go! " + current_battle.player_active.get_display_name() + "!")
	
	# Log to GameLogger
	GameLogger.log_battle("Battle started: WILD", {
		"player": current_battle.player_active.get_display_name(),
		"player_level": current_battle.player_active.level,
		"enemy": wild_pokemon.get_display_name(),
		"enemy_level": wild_pokemon.level,
		"type": "wild"
	})
	
	battle_started.emit(current_battle)
	
	# Start at action selection
	current_battle.set_phase(BattleState.Phase.ACTION_SELECT)


## Start a trainer battle (placeholder for future)
func start_trainer_battle(player_party: Array, trainer_party: Array) -> void:
	if is_in_battle:
		push_warning("Already in battle!")
		return
	
	current_battle = BattleState.new(BattleState.BattleType.TRAINER)
	current_battle.setup(player_party, trainer_party)
	current_battle.on_phase_changed = _on_phase_changed
	current_battle.on_pokemon_switched = _on_pokemon_switched
	
	is_in_battle = true
	battle_started.emit(current_battle)
	current_battle.set_phase(BattleState.Phase.ACTION_SELECT)


## End the current battle
func end_battle(result: String, data: Dictionary = {}) -> void:
	if not is_in_battle or current_battle == null:
		return
	
	# Log battle end
	GameLogger.log_battle("Battle ended: " + result, {
		"result": result,
		"turns": current_battle.turn_number
	})
	
	current_battle.cleanup()
	
	var end_data := data.duplicate()
	end_data["result"] = result
	end_data["turns"] = current_battle.turn_number
	
	battle_ended.emit(result, end_data)
	
	current_battle = null
	is_in_battle = false


## Player selects "Fight" - execute attack
func select_attack(move_index: int) -> void:
	if current_battle == null or current_battle.player_active == null:
		return
	
	var moves := current_battle.player_active.move_ids
	if move_index < 0 or move_index >= moves.size():
		return
	
	var move_id := moves[move_index]
	var pp := current_battle.player_active.move_pp[move_index]
	
	if pp <= 0:
		queue_message("No PP left for this move!")
		return
	
	current_battle.set_player_action("attack", {"move_index": move_index, "move_id": move_id})
	_execute_turn()


## Player selects "Run"
func select_run() -> void:
	if current_battle == null:
		return
	
	if not current_battle.can_flee():
		queue_message("Can't escape!")
		return
	
	current_battle.set_player_action("run", null)
	_execute_turn()


## Player selects "Pokemon" - switch
func select_switch(party_index: int) -> void:
	if current_battle == null:
		return
	
	if party_index == current_battle.player_active_index:
		queue_message("Already in battle!")
		return
	
	var pokemon: Pokemon = current_battle.player_party[party_index]
	if pokemon == null or not pokemon.can_battle():
		queue_message("Can't switch to a fainted Pokemon!")
		return
	
	current_battle.set_player_action("switch", {"party_index": party_index})
	_execute_turn()


## Player uses item
func select_item(item_id: String, target_index: int = -1) -> void:
	if current_battle == null:
		return
	
	current_battle.set_player_action("item", {"item_id": item_id, "target": target_index})
	_execute_turn()


## Player throws Pokeball
func throw_pokeball(ball_type: String = "POKE_BALL") -> void:
	if current_battle == null or not current_battle.can_catch():
		queue_message("Can't use that here!")
		return
	
	current_battle.set_player_action("catch", {"ball": ball_type})
	_execute_turn()


## Execute a turn
func _execute_turn() -> void:
	if current_battle == null:
		return
	
	current_battle.turn_number += 1
	current_battle.set_phase(BattleState.Phase.TURN_EXECUTE)
	turn_started.emit(current_battle.turn_number)
	
	# Determine enemy action
	current_battle.determine_enemy_action()
	
	# Determine turn order
	var player_first := current_battle.player_moves_first()
	
	# Execute actions
	if player_first:
		await _execute_player_action()
		if await _check_battle_over():
			return
		await _execute_enemy_action()
	else:
		await _execute_enemy_action()
		if await _check_battle_over():
			return
		await _execute_player_action()
	
	if await _check_battle_over():
		return
	
	# End of turn effects
	await _execute_end_of_turn()
	
	if await _check_battle_over():
		return
	
	turn_ended.emit(current_battle.turn_number)
	
	# Back to action selection
	current_battle.set_phase(BattleState.Phase.ACTION_SELECT)


## Execute player's action
func _execute_player_action() -> void:
	if current_battle == null or current_battle.player_active == null:
		return
	
	var action := current_battle.player_action
	
	match action.type:
		"attack":
			await _execute_attack(true, action.data)
		"switch":
			current_battle.switch_player_pokemon(action.data.party_index)
			pokemon_switched.emit(true, current_battle.player_active)
		"run":
			await _execute_run()
		"catch":
			await _execute_catch(action.data)
		"item":
			await _execute_item(action.data)


## Execute enemy's action
func _execute_enemy_action() -> void:
	if current_battle == null or current_battle.enemy_active == null:
		return
	if not current_battle.enemy_active.can_battle():
		return
	
	var action := current_battle.enemy_action
	
	match action.type:
		"attack":
			await _execute_attack(false, action.data)


## Execute an attack
func _execute_attack(is_player: bool, data: Dictionary) -> void:
	var attacker: Pokemon = current_battle.player_active if is_player else current_battle.enemy_active
	var defender: Pokemon = current_battle.enemy_active if is_player else current_battle.player_active
	
	if attacker == null or defender == null:
		return
	if not attacker.can_battle():
		return
	
	# Check if can move (paralysis, sleep, etc.)
	var can_move := BattleCalculator.can_move_this_turn(attacker)
	if not can_move.can_move:
		var prefix := "" if is_player else "Wild "
		match can_move.message:
			"frozen":
				queue_message(prefix + attacker.get_display_name() + " is frozen solid!")
			"asleep":
				queue_message(prefix + attacker.get_display_name() + " is fast asleep!")
			"paralyzed":
				queue_message(prefix + attacker.get_display_name() + " is paralyzed! It can't move!")
			"confused":
				queue_message(prefix + attacker.get_display_name() + " is confused!")
				# Hurt self
				var self_damage := maxi(1, attacker.max_hp / 8)
				attacker.take_damage(self_damage)
				queue_message("It hurt itself in its confusion!")
				pokemon_damaged.emit(is_player, self_damage, attacker.current_hp)
			"flinched":
				queue_message(prefix + attacker.get_display_name() + " flinched!")
		await _wait_for_messages()
		return
	
	# Get move
	var move_id: String = data.get("move_id", "STRUGGLE")
	var move := MoveDatabase.get_move(move_id)
	
	if move == null:
		# Struggle
		move = MoveData.create("STRUGGLE", "Struggle", TypeChart.Type.NORMAL, 
			MoveData.Category.PHYSICAL, 50, 100, 1)
	
	# Consume PP
	var move_index: int = data.get("move_index", -1)
	if move_index >= 0 and move_index < attacker.move_pp.size():
		attacker.move_pp[move_index] = maxi(0, attacker.move_pp[move_index] - 1)
	
	# Announce move
	var prefix := "" if is_player else "Wild "
	queue_message(prefix + attacker.get_display_name() + " used " + move.display_name + "!")
	move_used.emit(is_player, attacker, move)
	await _wait_for_messages()
	
	# Check accuracy
	if not BattleCalculator.check_accuracy(attacker, defender, move):
		queue_message(prefix + attacker.get_display_name() + "'s attack missed!")
		await _wait_for_messages()
		return
	
	# Calculate damage if damaging move
	if move.is_damaging():
		var is_crit := BattleCalculator.check_critical(attacker, move)
		var result := BattleCalculator.calculate_damage(attacker, defender, move, is_crit)
		
		# Apply damage
		defender.take_damage(result.damage)
		pokemon_damaged.emit(not is_player, result.damage, defender.current_hp)
		
		# Show effectiveness message
		if result.type_message == "super_effective":
			queue_message("It's super effective!")
			effectiveness_shown.emit("super_effective")
		elif result.type_message == "not_very_effective":
			queue_message("It's not very effective...")
			effectiveness_shown.emit("not_very_effective")
		elif result.type_message == "immune":
			queue_message("It doesn't affect " + defender.get_display_name() + "...")
			effectiveness_shown.emit("immune")
		
		if result.critical:
			queue_message("A critical hit!")
		
		await _wait_for_messages()
		
		# Check if defender fainted
		if defender.is_fainted():
			var def_prefix := "Wild " if is_player else ""
			queue_message(def_prefix + defender.get_display_name() + " fainted!")
			pokemon_fainted.emit(not is_player, defender)
			await _wait_for_messages()
			
			# Award EXP if player won
			if is_player:
				var exp := BattleCalculator.calculate_exp_gain(
					attacker, defender, 
					current_battle.battle_type == BattleState.BattleType.WILD,
					1
				)
				var levels := attacker.gain_experience(exp)
				queue_message(attacker.get_display_name() + " gained " + str(exp) + " EXP. Points!")
				if levels > 0:
					queue_message(attacker.get_display_name() + " grew to level " + str(attacker.level) + "!")
				await _wait_for_messages()
		
		# Recoil damage
		if move.effect == MoveData.Effect.RECOIL and move.recoil_percent > 0:
			var recoil := maxi(1, result.damage * move.recoil_percent / 100)
			attacker.take_damage(recoil)
			queue_message(prefix + attacker.get_display_name() + " is damaged by recoil!")
			pokemon_damaged.emit(is_player, recoil, attacker.current_hp)
			await _wait_for_messages()
	
	# Apply secondary effects
	if move.effect != MoveData.Effect.NONE and move.roll_effect_chance():
		await _apply_move_effect(is_player, attacker, defender, move)


## Apply move secondary effect
func _apply_move_effect(is_player: bool, attacker: Pokemon, defender: Pokemon, move: MoveData) -> void:
	var def_prefix := "Wild " if is_player else ""
	var atk_prefix := "" if is_player else "Wild "
	
	match move.effect:
		# Status conditions
		MoveData.Effect.BURN:
			if defender.status == Pokemon.Status.NONE:
				defender.status = Pokemon.Status.BURN
				queue_message(def_prefix + defender.get_display_name() + " was burned!")
		
		MoveData.Effect.FREEZE:
			if defender.status == Pokemon.Status.NONE:
				defender.status = Pokemon.Status.FREEZE
				queue_message(def_prefix + defender.get_display_name() + " was frozen solid!")
		
		MoveData.Effect.PARALYZE:
			if defender.status == Pokemon.Status.NONE:
				defender.status = Pokemon.Status.PARALYSIS
				queue_message(def_prefix + defender.get_display_name() + " is paralyzed! It may be unable to move!")
		
		MoveData.Effect.POISON:
			if defender.status == Pokemon.Status.NONE:
				defender.status = Pokemon.Status.POISON
				queue_message(def_prefix + defender.get_display_name() + " was poisoned!")
		
		MoveData.Effect.BADLY_POISON:
			if defender.status == Pokemon.Status.NONE:
				defender.status = Pokemon.Status.BADLY_POISONED
				defender.status_turns = 0
				queue_message(def_prefix + defender.get_display_name() + " was badly poisoned!")
		
		MoveData.Effect.SLEEP:
			if defender.status == Pokemon.Status.NONE:
				defender.status = Pokemon.Status.SLEEP
				defender.status_turns = randi_range(1, 3)
				queue_message(def_prefix + defender.get_display_name() + " fell asleep!")
		
		MoveData.Effect.CONFUSE:
			if Pokemon.VolatileStatus.CONFUSION not in defender.volatile_statuses:
				defender.volatile_statuses.append(Pokemon.VolatileStatus.CONFUSION)
				defender.volatile_data["confusion_turns"] = randi_range(2, 5)
				queue_message(def_prefix + defender.get_display_name() + " became confused!")
		
		MoveData.Effect.FLINCH:
			defender.volatile_statuses.append(Pokemon.VolatileStatus.FLINCH)
		
		# Stat changes (defender)
		MoveData.Effect.LOWER_ATTACK:
			var change := BattleCalculator.apply_stat_change(defender, "attack", -1)
			if change != 0:
				queue_message(def_prefix + defender.get_display_name() + "'s Attack fell!")
		
		MoveData.Effect.LOWER_DEFENSE:
			var change := BattleCalculator.apply_stat_change(defender, "defense", -1)
			if change != 0:
				queue_message(def_prefix + defender.get_display_name() + "'s Defense fell!")
		
		MoveData.Effect.LOWER_SPEED:
			var change := BattleCalculator.apply_stat_change(defender, "speed", -1)
			if change != 0:
				queue_message(def_prefix + defender.get_display_name() + "'s Speed fell!")
		
		MoveData.Effect.LOWER_ACCURACY:
			var change := BattleCalculator.apply_stat_change(defender, "accuracy", -1)
			if change != 0:
				queue_message(def_prefix + defender.get_display_name() + "'s accuracy fell!")
		
		# Stat changes (self)
		MoveData.Effect.RAISE_ATTACK:
			var change := BattleCalculator.apply_stat_change(attacker, "attack", 1)
			if change != 0:
				queue_message(atk_prefix + attacker.get_display_name() + "'s Attack rose!")
		
		MoveData.Effect.RAISE_DEFENSE:
			var change := BattleCalculator.apply_stat_change(attacker, "defense", 1)
			if change != 0:
				queue_message(atk_prefix + attacker.get_display_name() + "'s Defense rose!")
		
		MoveData.Effect.RAISE_SPEED:
			var change := BattleCalculator.apply_stat_change(attacker, "speed", 1)
			if change != 0:
				queue_message(atk_prefix + attacker.get_display_name() + "'s Speed rose!")
		
		# Healing
		MoveData.Effect.HEAL_SELF:
			var heal := attacker.max_hp / 2
			attacker.heal(heal)
			queue_message(atk_prefix + attacker.get_display_name() + " restored HP!")
	
	await _wait_for_messages()


## Execute run attempt
func _execute_run() -> void:
	current_battle.flee_attempts += 1
	
	var can_flee := BattleCalculator.calculate_flee_chance(
		current_battle.player_active,
		current_battle.enemy_active,
		current_battle.flee_attempts
	)
	
	if can_flee:
		queue_message("Got away safely!")
		await _wait_for_messages()
		current_battle.set_phase(BattleState.Phase.FLED)
		end_battle("fled")
	else:
		queue_message("Can't escape!")
		await _wait_for_messages()


## Execute catch attempt
func _execute_catch(data: Dictionary) -> void:
	var ball_type: String = data.get("ball", "POKE_BALL")
	var ball_modifier := 1.0
	
	# Ball modifiers
	match ball_type:
		"GREAT_BALL": ball_modifier = 1.5
		"ULTRA_BALL": ball_modifier = 2.0
		"MASTER_BALL": ball_modifier = 255.0
	
	queue_message("You threw a " + ball_type.replace("_", " ").capitalize() + "!")
	await _wait_for_messages()
	
	var target := current_battle.get_catch_target()
	if target == null:
		queue_message("It had no effect!")
		await _wait_for_messages()
		return
	
	var shakes := BattleCalculator.throw_pokeball(target, ball_modifier)
	
	# Show shake messages
	for i in range(mini(shakes, 3)):
		queue_message("...")
		await _wait_for_messages()
		await get_tree().create_timer(0.3).timeout
	
	if shakes >= 4:
		# Caught!
		queue_message("Gotcha! " + target.get_display_name() + " was caught!")
		await _wait_for_messages()
		current_battle.set_phase(BattleState.Phase.CAUGHT)
		end_battle("caught", {"pokemon": target})
	else:
		# Escaped
		var escape_messages := [
			"Oh no! The Pokemon broke free!",
			"Aww! It appeared to be caught!",
			"Aargh! Almost had it!",
			"Shoot! It was so close, too!"
		]
		queue_message(escape_messages[mini(shakes, 3)])
		await _wait_for_messages()


## Execute item use
func _execute_item(data: Dictionary) -> void:
	# TODO: Implement item effects
	queue_message("Used " + data.get("item_id", "item") + "!")
	await _wait_for_messages()


## Execute end of turn effects
func _execute_end_of_turn() -> void:
	current_battle.set_phase(BattleState.Phase.TURN_END)
	
	# Weather damage would go here
	
	# Status damage
	for pokemon_data in [
		{"pokemon": current_battle.player_active, "is_player": true},
		{"pokemon": current_battle.enemy_active, "is_player": false}
	]:
		var pokemon: Pokemon = pokemon_data.pokemon
		if pokemon == null or not pokemon.can_battle():
			continue
		
		var damage := BattleCalculator.apply_end_of_turn_damage(pokemon)
		if damage > 0:
			pokemon.take_damage(damage)
			var prefix := "" if pokemon_data.is_player else "Wild "
			
			match pokemon.status:
				Pokemon.Status.BURN:
					queue_message(prefix + pokemon.get_display_name() + " is hurt by its burn!")
				Pokemon.Status.POISON, Pokemon.Status.BADLY_POISONED:
					queue_message(prefix + pokemon.get_display_name() + " is hurt by poison!")
			
			pokemon_damaged.emit(pokemon_data.is_player, damage, pokemon.current_hp)
			await _wait_for_messages()
			
			if pokemon.is_fainted():
				queue_message(prefix + pokemon.get_display_name() + " fainted!")
				pokemon_fainted.emit(pokemon_data.is_player, pokemon)
				await _wait_for_messages()


## Check if battle is over
func _check_battle_over() -> bool:
	if current_battle == null:
		return true
	
	# Player lost
	if not current_battle.player_has_healthy_pokemon():
		current_battle.set_phase(BattleState.Phase.DEFEAT)
		queue_message("You have no more Pokemon that can fight!")
		await _wait_for_messages()
		end_battle("defeat")
		return true
	
	# Enemy lost
	if not current_battle.enemy_has_healthy_pokemon():
		current_battle.set_phase(BattleState.Phase.VICTORY)
		queue_message("You won!")
		await _wait_for_messages()
		end_battle("victory")
		return true
	
	# Player's active Pokemon fainted - need to switch
	if current_battle.player_active == null or not current_battle.player_active.can_battle():
		current_battle.set_phase(BattleState.Phase.SWITCH_SELECT)
		# UI will handle switch selection
		return false
	
	return false


## Queue a message for display
func queue_message(message: String) -> void:
	_message_queue.append(message)
	message_queued.emit(message)
	current_battle.log_message(message) if current_battle else null


## Wait for messages to be displayed
func _wait_for_messages() -> void:
	# Give time for UI to display messages
	await get_tree().create_timer(0.5).timeout


## Callbacks
func _on_phase_changed(old_phase: BattleState.Phase, new_phase: BattleState.Phase) -> void:
	phase_changed.emit(old_phase, new_phase)


func _on_pokemon_switched(is_player: bool, pokemon: Pokemon) -> void:
	pokemon_switched.emit(is_player, pokemon)


## Get current battle state
func get_battle_state() -> BattleState:
	return current_battle


## Check if we're in battle
func in_battle() -> bool:
	return is_in_battle
