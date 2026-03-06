---
name: godot-ide-api
description: Connect to a locally running Godot editor through the Debug Adapter Protocol, launch a project or scene for smoke tests, and collect debugger exceptions. Use when validating Godot startup or runtime behavior, checking debugger errors, or running repeatable playtest checks from the terminal.
license: AGPL-3.0-or-later
compatibility: Requires Python 3 and a locally running Godot editor exposing the Debug Adapter Protocol on localhost, typically 127.0.0.1:6006.
---

# Godot IDE API

Use the local Godot editor as a test harness. Prefer the bundled DAP script instead of ad hoc socket code.

## Available scripts

- `scripts/godot_dap.py` - Probe the Godot DAP endpoint, launch a project or scene, collect debugger exceptions, and run smoke tests.

## Prerequisite check

Confirm a local Godot editor is listening before proposing deeper commands:

```bash
lsof -nP -iTCP -sTCP:LISTEN | rg 'Godot|:6006|:6005'
```

If `6006` is not listening, ask the user to open the project in the Godot editor first.

## Quick start

Probe for the DAP endpoint:

```bash
python3 scripts/godot_dap.py probe
```

Run a scene smoke test:

```bash
python3 scripts/godot_dap.py smoke-test \
  --project /absolute/path/to/project \
  --scene res://scenes/Main.tscn
```

Collect debugger exceptions with stack traces:

```bash
python3 scripts/godot_dap.py debugger-report \
  --project /absolute/path/to/project \
  --scene res://scenes/Main.tscn
```

## Core workflow

1. Probe the endpoint if the port is unknown.
2. Run `smoke-test` after code changes to catch parser/runtime regressions quickly.
3. Run `debugger-report` when the user asks about debugger errors or when `smoke-test` fails.
4. Patch the code.
5. Re-run `smoke-test` until it exits cleanly.

## Command guidance

- Use `probe` when the editor may not be listening or the port is unclear.
- Use `smoke-test` for fast validation in CI-like loops. It fails on debugger exceptions.
- Use `debugger-report` when you need file/line stack frames for exceptions.
- Pass `--timeout` when startup is slow or the project intentionally runs longer before errors surface.
- Default to `127.0.0.1:6006` unless the user or environment shows a different DAP port.

## Guardrails

- Always use absolute `--project` paths.
- Prefer `res://...` scene paths for launch requests.
- Treat `6006` as the DAP endpoint. Do not assume `6005` is HTTP.
- When reporting debugger errors back to the user, include the exception text and the first relevant file/line.
- When no exception appears, say that explicitly instead of implying a failure.

## References

Open only what you need:

- Workflow examples and common recovery patterns: `references/workflows.md`
