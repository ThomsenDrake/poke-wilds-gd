# Godot IDE API Workflows

## Common tasks

### Check startup regressions

```bash
"$GODOT_DAP" smoke-test \
  --project /absolute/path/to/project \
  --scene res://scenes/Main.tscn
```

Use after script edits, scene changes, or asset-path changes. Expect `RESULT: OK` when startup is clean.

### Inspect debugger errors

```bash
"$GODOT_DAP" debugger-report \
  --project /absolute/path/to/project \
  --scene res://scenes/Main.tscn
```

Use when the user says "check the Godot debugger" or when `smoke-test` fails. Report the exception text and the first relevant file/line.

### Confirm the editor is reachable

```bash
"$GODOT_DAP" probe
```

If no DAP port is found, verify the project is open in the Godot editor and retry.

## Failure patterns

- `ERROR: Failed to initialize Godot DAP`: the port is reachable but not speaking DAP, or the editor is not ready yet.
- `UNREACHABLE 127.0.0.1:6006`: the editor is not listening on the default DAP port.
- `Exception: Parser Error ...`: launch succeeded far enough to parse the project, but a script or scene load failed.
- Clean smoke test but wrong runtime behavior: use `debugger-report` again with a longer `--timeout` to catch delayed exceptions.
