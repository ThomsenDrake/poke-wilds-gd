# Godot Local API Notes

## Discovered endpoints
- `127.0.0.1:6006` = Godot Debug Adapter Protocol (DAP).
- `127.0.0.1:6005` is open but not used in this port flow.

## Working DAP launch contract
After `initialize`, a launch request succeeds with:

```json
{
  "command": "launch",
  "arguments": {
    "project": "/absolute/path/to/project",
    "scene": "res://scenes/Main.tscn"
  }
}
```

Then send `configurationDone`.

## Smoke test command

```bash
./tools/godot_dap_smoketest.py \
  --project /Users/drakethomsen-mai/Documents/game-projects/poke-wilds-godot \
  --scene res://scenes/Main.tscn \
  --timeout 6
```

Expected success tail:
- Godot engine startup line
- `RESULT: OK`
