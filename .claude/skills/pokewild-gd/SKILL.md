---
name: pokewild-gd
description: PokeWilds-GD specific workflows - autoloads, databases, world gen, camera
allowed-tools: [Bash]
---

# PokeWilds-GD Development Workflows

Project-specific tools for the PokeWilds-GD codebase.

## Architecture Overview

This game uses **16 autoload singletons** for all game logic:
- GameManager, BattleManager, SaveManager
- SpeciesDatabase, MoveDatabase, ItemDatabase
- BuildManager, HabitatManager, BreedingManager
- And more...

Scenes are minimal - most logic lives in autoloads.

## Autoload Inspection

**Query Autoload State**
```bash
# Execute GDScript to query autoloads
mcp-exec ~/.claude/scripts/godot_execute_code.py \
  --code "print(GameManager.current_state)"

# Get Pokemon database count
mcp-exec ~/.claude/scripts/godot_execute_code.py \
  --code "print(SpeciesDatabase.get_species_count())"

# Check battle status
mcp-exec ~/.claude/scripts/godot_execute_code.py \
  --code "print(BattleManager.is_battle_active())"
```

**Call Autoload Methods**
```bash
mcp-exec ~/.claude/scripts/godot_call_method.py \
  --node "GameManager" \
  --method "get_state"

mcp-exec ~/.claude/scripts/godot_call_method.py \
  --node "SpeciesDatabase" \
  --method "get_species" \
  --args "25"  # Pikachu
```

## Database Queries

**Species Database**
```bash
# Get specific Pokemon
mcp-exec ~/.claude/scripts/godot_execute_code.py \
  --code "print(SpeciesDatabase.get_species(25))"  # Pikachu

# List all species
mcp-exec ~/.claude/scripts/godot_execute_code.py \
  --code "print(SpeciesDatabase.get_all_species())"
```

**Move Database**
```bash
# Get move data
mcp-exec ~/.claude/scripts/godot_execute_code.py \
  --code "print(MoveDatabase.get_move('thunderbolt'))"
```

**Item Database**
```bash
# Get item info
mcp-exec ~/.claude/scripts/godot_execute_code.py \
  --code "print(ItemDatabase.get_item('potion'))"
```

## Camera Controls

**Zoom**
```bash
# Zoom in (2x)
mcp-exec ~/.claude/scripts/pokewild_camera.py --zoom 2.0

# Zoom out (0.5x)
mcp-exec ~/.claude/scripts/pokewild_camera.py --zoom 0.5
```

**Position**
```bash
# Move camera
mcp-exec ~/.claude/scripts/pokewild_camera.py --position 400 300

# Zoom and move
mcp-exec ~/.claude/scripts/pokewild_camera.py --zoom 1.5 --position 200 150
```

**Current Camera State**
```bash
mcp-exec ~/.claude/scripts/godot_get_properties.py --node "Camera2D"
```

## World Generation

**Habitat System**
```bash
# Check habitat at position
mcp-exec ~/.claude/scripts/godot_execute_code.py \
  --code "print(HabitatManager.get_habitat_at(100, 100))"

# Get biome info
mcp-exec ~/.claude/scripts/godot_execute_code.py \
  --code "print(HabitatManager.get_current_biome())"
```

**Procedural Generation**
```bash
# Trigger world generation (if exposed)
mcp-exec ~/.claude/scripts/godot_execute_code.py \
  --code "WorldGenerator.generate_chunk(0, 0)"

# Get generation parameters
mcp-exec ~/.claude/scripts/godot_execute_code.py \
  --code "print(WorldGenerator.get_config())"
```

## Building System

**Build Mode**
```bash
# Check build mode status
mcp-exec ~/.claude/scripts/godot_execute_code.py \
  --code "print(BuildManager.is_build_mode_active())"

# Get available structures
mcp-exec ~/.claude/scripts/godot_execute_code.py \
  --code "print(StructureDatabase.get_all_structures())"
```

## Battle System

**Battle State**
```bash
# Check if in battle
mcp-exec ~/.claude/scripts/godot_execute_code.py \
  --code "print(BattleManager.is_in_battle())"

# Get battle info
mcp-exec ~/.claude/scripts/godot_execute_code.py \
  --code "print(BattleManager.get_battle_state())"
```

## Common Workflows

### Debug Game State
```bash
# Full game state snapshot
mcp-exec ~/.claude/scripts/godot_execute_code.py \
  --code "print({
    'game': GameManager.get_state(),
    'player': GameManager.get_player_info(),
    'camera': {'zoom': Camera2D.zoom, 'pos': Camera2D.position}
  })"
```

### Test Pokemon Spawning
```bash
# Spawn a Pokemon for testing
mcp-exec ~/.claude/scripts/godot_execute_code.py \
  --code "GameManager.spawn_pokemon(25, 100, 100)"  # Pikachu at (100, 100)
```

### Inspect World at Position
```bash
# What's at a specific position?
mcp-exec ~/.claude/scripts/godot_execute_code.py \
  --code "print({
    'habitat': HabitatManager.get_habitat_at(200, 200),
    'entities': GameManager.get_entities_at(200, 200)
  })"
```

### Camera Debugging
```bash
# Reset camera
mcp-exec ~/.claude/scripts/pokewild_camera.py --zoom 1.0 --position 0 0

# Get current camera state
mcp-exec ~/.claude/scripts/godot_get_properties.py --node "Camera2D"
```

## Manager Reference

### Core Managers
- **GameManager** - Main game state, player, entities
- **InputManager** - Input handling (use InputManager methods, not is_action_pressed!)
- **SaveManager** - Save/load game state
- **GameLogger** - Logging system

### Battle & Breeding
- **BattleManager** - Battle system
- **BreedingManager** - Pokemon breeding
- **TypeChart** - Type effectiveness

### World & Building
- **HabitatManager** - Biomes and habitats
- **BuildManager** - Building mode
- **StructureDatabase** - Available structures
- **FieldMoveManager** - Field moves (Surf, Cut, etc.)

### Databases
- **SpeciesDatabase** - Pokemon species data
- **MoveDatabase** - Move data
- **ItemDatabase** - Item data

### Other
- **AudioManager** - Sound and music
- **RanchManager** - Ranch/farm system

## Code Patterns (from AGENTS.md)

**Input Handling**
```gdscript
# DON'T: Direct input checks
if Input.is_action_pressed("move_up"):

# DO: Use InputManager
if InputManager.is_action_pressed("move_up"):
```

**Strict Typing**
```gdscript
# Always use type hints
var player_position: Vector2 = GameManager.get_player_position()
func calculate_damage(attacker: Pokemon, defender: Pokemon) -> int:
```

**Viewport System**
- Display: 480×432 (30×27 tiles)
- Camera zoom: Flexible (use pokewild_camera.py)

## Tips

1. **Most logic is in autoloads** - Query them instead of scene nodes
2. **Use GDScript execution** for complex queries
3. **Camera is in main scene** - Access via "Camera2D" node
4. **Reference Java source** - Check `source_reference/` for original implementation
5. **Follow strict typing** - All code uses type hints

## See Also

- Global Godot MCP skill: `~/.claude/skills/godot-mcp/SKILL.md`
- Code style guide: `AGENTS.md`
- Continuity ledger: `thoughts/ledgers/CONTINUITY_CLAUDE-poke-wilds-gd.md`
