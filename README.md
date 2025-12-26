# PokeWilds-GD

A Godot 4.5 port of [PokeWilds](https://github.com/SheerSt/pokewilds) - an open-world Pokemon survival game inspired by the Game Boy Color era.

## About

PokeWilds-GD is a comprehensive reimplementation of PokeWilds using the Godot Engine, bringing modern engine features while maintaining the nostalgic pixel art style and gameplay mechanics. The game features procedurally generated worlds, wild Pokemon encounters, turn-based battles, and survival mechanics.

## Features

### Core Systems
- **Turn-based Battle System** - Traditional Pokemon battles with type effectiveness, moves, and stats
- **Procedural World Generation** - Dynamically generated overworld with multiple biomes
- **Pokemon Management** - Catch, train, and manage your Pokemon party
- **Breeding System** - Breed Pokemon to discover new species
- **Building System** - Construct structures and customize your ranch
- **Field Moves** - Use Pokemon abilities to navigate the world
- **Save System** - Persistent game saves

### Database Systems
- Species Database - Complete Pokemon data with stats, types, and movesets
- Move Database - All Pokemon moves with effects and properties
- Item Database - Items, tools, and consumables
- Structure Database - Buildings and constructible objects
- Type Chart - Full type effectiveness system

### UI Components
- Party Menu - Manage your Pokemon team
- Bag Menu - Item inventory management
- PC Box System - Store extra Pokemon
- Breeding Menu - Pokemon breeding interface
- Build Menu - Structure placement system
- Options Menu - Game settings and configuration

## Requirements

- **Godot Engine 4.5+** (GL Compatibility renderer)
- **Operating Systems**: Windows, macOS, Linux

## Installation

1. Clone the repository:
   ```bash
   git clone https://github.com/ThomsenDrake/poke-wilds-gd.git
   cd poke-wilds-gd
   ```

2. Open the project in Godot 4.5:
   - Launch Godot Engine
   - Click "Import"
   - Navigate to the project folder
   - Select `project.godot`
   - Click "Import & Edit"

3. Run the game:
   - Press F5 in the Godot Editor, or
   - Click the "Play" button in the top-right corner

## Controls

### Movement
- **Arrow Keys** or **WASD** - Move player
- **Z** or **Space** - Action/Confirm (A button)
- **X** or **Shift** - Cancel/Back (B button)
- **Enter** - Start menu
- **Backspace** - Select menu

### Camera
- **Q** - Zoom out
- **E** - Zoom in
- **R** - Reset zoom
- **F11** - Toggle fullscreen

## Project Structure

```
poke-wilds-gd/
├── assets/
│   └── sprites/          # Game sprites and textures
│       ├── player/       # Player character sprites
│       ├── pokemon/      # Pokemon sprites (front/back)
│       └── tiles/        # World tiles and terrain
├── scenes/
│   ├── main.tscn         # Main game scene
│   ├── overworld/        # Overworld scenes
│   └── battle/           # Battle system scenes
├── scripts/
│   ├── autoloads/        # Global singleton systems
│   │   ├── game_manager.gd
│   │   ├── battle_manager.gd
│   │   ├── species_database.gd
│   │   └── ...
│   ├── battle/           # Battle system scripts
│   ├── entities/         # Player and Pokemon entities
│   ├── resources/        # Data classes (Pokemon, Items, etc.)
│   ├── systems/          # World generation, tilemap
│   └── ui/               # UI components and menus
└── project.godot         # Godot project configuration
```

## Development

### Code Style
- **GDScript** with strict typing enabled
- `snake_case` for variables/functions
- `PascalCase` for classes/enums
- `UPPER_SNAKE_CASE` for constants
- Private members prefixed with `_`

### Key Patterns
- **Autoloads**: Global singletons for core systems
- **Resources**: Data classes extend `Resource` with `@export` properties
- **Signals**: Event-driven architecture for decoupling
- **InputManager**: Centralized input handling with GBC-style button mapping

### Display Configuration
- **Viewport**: 480×432 pixels (30×27 tiles)
- **Window**: 960×864 pixels (2× scale default)
- **Aspect Ratios**: 10:9 (authentic) or 16:9 (modern)
- **Camera Zoom**: 0.5× to 2.0× range

### Running Headless
```bash
godot --path . --headless
```

## Contributing

Contributions are welcome! This is an active port project with many features still in development. Feel free to:
- Report bugs via GitHub Issues
- Submit pull requests for bug fixes or features
- Suggest improvements or new features

## Credits

- **Original PokeWilds**: [SheerSt/pokewilds](https://github.com/SheerSt/pokewilds)
- **Godot Port**: Community effort to bring PokeWilds to Godot Engine
- **Pokemon**: © The Pokémon Company, Nintendo, Game Freak

## License

This is a fan project and is not affiliated with or endorsed by Nintendo, The Pokémon Company, or Game Freak. All Pokemon-related names, images, and concepts are © their respective owners.

The code for this Godot port follows the same open-source spirit as the original PokeWilds project.

## Status

**⚠️ Work in Progress** - This port is actively under development. Many features are implemented but the game is not yet feature-complete compared to the original PokeWilds.

### Implemented
- ✅ Core battle system
- ✅ Overworld movement and camera
- ✅ Pokemon data systems
- ✅ World generation framework
- ✅ Input management
- ✅ Save/load system

### In Progress
- 🚧 Complete Pokemon roster
- 🚧 All battle mechanics and effects
- 🚧 Building and crafting systems
- 🚧 UI polish and menus
- 🚧 Audio and music
- 🚧 Additional biomes and areas
