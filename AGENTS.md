# AGENTS.md - PokeWilds Godot Port

## Build & Run
- **Run game**: `godot --path . --headless` (validation) or open in Godot 4.5 editor
- **Check errors**: Open project in Godot editor → Errors panel, or use LSP diagnostics
- No automated test framework; test by running the game

## Code Style (GDScript)
- **Strict typing enabled** — all variables from `Dictionary.get()`, untyped arrays, or iteration need explicit types: `var x: Type = dict.get("key")`
- `snake_case` for variables/functions, `PascalCase` for classes/enums, `UPPER_SNAKE_CASE` for constants
- Private members prefixed with `_` (e.g., `_species`, `_calc_stat()`)
- Doc comments: `##` for public API, `#` for inline
- Class structure: `class_name`, `extends`, doc comment, enums, constants, exports, vars, signals, lifecycle, public funcs, private funcs

## Key Patterns
- **Autoloads**: Global singletons (GameManager, InputManager, TypeChart, etc.) — access directly by name
- **Resources**: Data classes extend `Resource` with `@export` properties
- **Signals**: Use for decoupling (e.g., `game_state_changed`)
- **InputManager**: Uses `GBCButton` enum (renamed from `Button`), call `is_pressed()`, `is_held()`, `run_held()` — NOT `is_action_pressed()`

## Display & Camera System
- **Viewport**: 480×432 (30×27 tiles) — larger than original GBC for better exploration
- **Window**: 960×864 (2× scale) by default
- **Aspect Ratios**: `10:9` (authentic) or `16:9` (modern) — configured in GameManager, requires restart
- **Camera Zoom**: Global via `GameManager.set_camera_zoom()` (range: 0.5× to 2.0×)
- **CameraController**: Extends Camera2D, handles zoom transitions and battle mode

### Display Constants (GameManager)
- `BASE_VIEWPORT_WIDTH = 480`, `BASE_VIEWPORT_HEIGHT = 432`
- `VIEWPORT_TILES_X = 30`, `VIEWPORT_TILES_Y = 27`
- `SCREEN_WIDTH/SCREEN_HEIGHT` — legacy aliases, still work

### Camera Controls
- **Q** = Zoom out, **E** = Zoom in, **R** = Reset zoom (1.0×)
- **F11** = Toggle fullscreen
- Battle camera uses fixed zoom independent of overworld

### UI Positioning
- Use `GameManager.BASE_VIEWPORT_WIDTH/HEIGHT` for positioning calculations
- UI elements stay fixed size (don't scale with camera zoom)
- Anchor-based layouts preferred for responsive sizing

## Common Gotchas
- Never use `as any`, `@ts-ignore` equivalents — fix types properly
- Coroutines returning values must be `await`ed
- Don't override built-in method names (`_set`, `_get`) without renaming
- Use `GameManager.BASE_VIEWPORT_*` for viewport-relative positioning, not hardcoded 160×144
