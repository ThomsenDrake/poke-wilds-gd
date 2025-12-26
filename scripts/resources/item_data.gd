@tool
class_name ItemData
extends Resource
## ItemData - Resource class for item definitions
## Contains item properties, effects, and usage data

# Item categories
enum Category {
	POKEBALL,      # Catching Pokemon
	MEDICINE,      # Healing items
	BATTLE,        # X Attack, etc.
	BERRY,         # Berries
	KEY_ITEM,      # Story/special items
	TM_HM,         # Technical/Hidden Machines
	MATERIAL,      # Crafting materials (PokeWilds specific)
	TOOL,          # Tools like fishing rod
	HELD_ITEM      # Items Pokemon can hold
}

# Item effect types
enum Effect {
	NONE,
	# Pokeball effects
	CATCH_POKEMON,
	# Healing effects
	HEAL_HP,
	HEAL_PP,
	HEAL_STATUS,
	HEAL_ALL,
	REVIVE,
	MAX_REVIVE,
	# Stat boost effects
	BOOST_ATTACK,
	BOOST_DEFENSE,
	BOOST_SPEED,
	BOOST_SP_ATTACK,
	BOOST_SP_DEFENSE,
	BOOST_ACCURACY,
	BOOST_CRIT,
	# Evolution items
	EVOLUTION_STONE,
	# Held item effects
	HELD_BOOST_TYPE,
	HELD_HEAL,
	# TM/HM
	TEACH_MOVE,
	# PokeWilds specific
	CRAFTING_MATERIAL,
	BUILD_STRUCTURE
}

# Basic identification
@export var id: String = ""
@export var display_name: String = ""
@export var description: String = ""
@export var category: Category = Category.MEDICINE

# Pricing
@export var buy_price: int = 0      # 0 = cannot buy
@export var sell_price: int = 0     # 0 = cannot sell

# Usage
@export var usable_in_battle: bool = true
@export var usable_outside_battle: bool = true
@export var consumable: bool = true  # Is it used up when used?
@export var holdable: bool = false   # Can Pokemon hold it?

# Effect data
@export var effect: Effect = Effect.NONE
@export var effect_value: int = 0    # HP to heal, catch rate modifier, etc.
@export var effect_param: String = "" # Move ID for TM, type for stones, etc.

# Pokeball specific
@export var catch_rate_modifier: float = 1.0  # Multiplier for catch rate

# Sprite
@export var sprite_path: String = ""

# Sorting
@export var sort_order: int = 0


## Check if item can be used on a Pokemon
func can_use_on_pokemon(pokemon: Pokemon, in_battle: bool) -> bool:
	if in_battle and not usable_in_battle:
		return false
	if not in_battle and not usable_outside_battle:
		return false
	
	match effect:
		Effect.HEAL_HP:
			return pokemon.current_hp < pokemon.max_hp and not pokemon.is_fainted()
		Effect.HEAL_STATUS:
			return pokemon.status != Pokemon.Status.NONE
		Effect.REVIVE, Effect.MAX_REVIVE:
			return pokemon.is_fainted()
		Effect.HEAL_PP:
			# Check if any move has less than max PP
			for i in range(pokemon.move_pp.size()):
				var move := MoveDatabase.get_move(pokemon.move_ids[i])
				if move and pokemon.move_pp[i] < move.max_pp:
					return true
			return false
		Effect.HEAL_ALL:
			return pokemon.current_hp < pokemon.max_hp or pokemon.status != Pokemon.Status.NONE
		Effect.TEACH_MOVE:
			var species := pokemon.get_species()
			return species != null and species.can_learn_move(effect_param)
		Effect.EVOLUTION_STONE:
			# Check if Pokemon can evolve with this stone
			var species := pokemon.get_species()
			if species == null:
				return false
			for evo in species.evolutions:
				if evo.get("method") == PokemonSpecies.EvolutionMethod.ITEM:
					if evo.get("param") == effect_param:
						return true
			return false
		_:
			return true


## Apply item effect to Pokemon
func apply_to_pokemon(pokemon: Pokemon) -> Dictionary:
	var result := {
		"success": false,
		"message": "",
		"consumed": consumable
	}
	
	match effect:
		Effect.HEAL_HP:
			var healed := pokemon.heal(effect_value)
			result.success = healed > 0
			result.message = pokemon.get_display_name() + " recovered " + str(healed) + " HP!"
		
		Effect.HEAL_STATUS:
			if pokemon.status != Pokemon.Status.NONE:
				pokemon.status = Pokemon.Status.NONE
				pokemon.status_turns = 0
				result.success = true
				result.message = pokemon.get_display_name() + " was cured!"
		
		Effect.HEAL_ALL:
			var healed := pokemon.heal(effect_value)
			pokemon.status = Pokemon.Status.NONE
			pokemon.status_turns = 0
			result.success = true
			result.message = pokemon.get_display_name() + " was fully restored!"
		
		Effect.REVIVE:
			if pokemon.is_fainted():
				pokemon.current_hp = pokemon.max_hp / 2
				result.success = true
				result.message = pokemon.get_display_name() + " was revived!"
		
		Effect.MAX_REVIVE:
			if pokemon.is_fainted():
				pokemon.current_hp = pokemon.max_hp
				result.success = true
				result.message = pokemon.get_display_name() + " was fully revived!"
		
		Effect.HEAL_PP:
			# Restore PP for all moves
			for i in range(pokemon.move_pp.size()):
				var move := MoveDatabase.get_move(pokemon.move_ids[i])
				if move:
					pokemon.move_pp[i] = move.max_pp
			result.success = true
			result.message = pokemon.get_display_name() + "'s PP was restored!"
		
		Effect.TEACH_MOVE:
			# Teaching move is handled separately (needs move selection UI)
			result.success = false
			result.message = "Use TM from menu to teach moves"
			result.consumed = false
		
		_:
			result.message = "Can't use that here!"
	
	return result


## Get category display name
static func get_category_name(cat: Category) -> String:
	match cat:
		Category.POKEBALL: return "Poke Balls"
		Category.MEDICINE: return "Medicine"
		Category.BATTLE: return "Battle Items"
		Category.BERRY: return "Berries"
		Category.KEY_ITEM: return "Key Items"
		Category.TM_HM: return "TMs & HMs"
		Category.MATERIAL: return "Materials"
		Category.TOOL: return "Tools"
		Category.HELD_ITEM: return "Held Items"
		_: return "Items"


## Create item from parameters
static func create(
	p_id: String,
	p_name: String,
	p_desc: String,
	p_category: Category,
	p_effect: Effect = Effect.NONE,
	p_value: int = 0
) -> ItemData:
	var item := ItemData.new()
	item.id = p_id
	item.display_name = p_name
	item.description = p_desc
	item.category = p_category
	item.effect = p_effect
	item.effect_value = p_value
	return item
