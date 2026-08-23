# Agent Map

Use this file as the table of contents, not the encyclopedia.

## Read First

- Product direction and slice: [STRATEGY.md](STRATEGY.md), [docs/product-specs/](docs/product-specs/)
- Layer rules and allowed dependencies: [ARCHITECTURE.md](ARCHITECTURE.md)
- Subsystem registry: [docs/registry/subsystems.toml](docs/registry/subsystems.toml)
- Agent surface (machine-readable manifest + integration guide): [docs/registry/agent-surface.toml](docs/registry/agent-surface.toml), [docs/references/agent-integration.md](docs/references/agent-integration.md)
- Reliability and validation: [docs/RELIABILITY.md](docs/RELIABILITY.md)
- Quality scorecard: [docs/QUALITY_SCORE.md](docs/QUALITY_SCORE.md)
- Tech debt tracker: [docs/tech-debt-tracker.md](docs/tech-debt-tracker.md)

## Where Knowledge Lives

- Design principles: `docs/design-docs/`
- Product behavior and supported gameplay slice: `docs/product-specs/`
- Godot/DAP and trace contracts: `docs/references/`
- Active and completed execution plans: `docs/exec-plans/`
- Generated maintenance output: `docs/generated/`

## Canonical Commands

```bash
python3 tools/setup_worktree.py --quick       # fast local Cursor/Codex hook: runtime checks only; no cache/import lock
python3 tools/setup_worktree.py               # full preparation before runtime tests; add --seed-from /path/to/warm/worktree to clone missing caches
bash tools/setup_codex_cloud.sh               # Codex Cloud only: install pinned Linux Godot + full cached preparation
bash tools/run_codex_cloud_visuals.sh --check # Codex Cloud only: display + live Command Code API/model readiness
python3 tools/verify_all.py                  # THE pre-push local gate: static + determinism + full suite + windowed pixel lanes + legibility + refuse-on-mismatch/freshness (details: docs/RELIABILITY.md § Local gate)
python3 tools/verify_all.py --skip-windowed  # display-less environments: windowed lanes reported SKIP, never PASS (honest headless path)
python3 tools/check_repo_contracts.py
python3 tools/check_architecture.py
python3 tools/check_change_contract.py
python3 tools/check_quality_docs.py
python3 tools/godot_dap_smoketest.py --project /absolute/path/to/poke-wilds-godot --scene res://scenes/app/Main.tscn --scenario boot
```

## Working Rules

- Keep new durable knowledge in `docs/`, not in ad hoc chat context.
- Register every subsystem and keep its `spec_doc`, validation commands, trace events, and quality row up to date.
- Preserve the fixed layer structure under `scripts/` and `scenes/`.
- Prefer adding or tightening mechanical checks over adding prose-only guidance.
- Keep `scripts/app/*.gd` and `scripts/ui/*.gd` under the line budget; split responsibilities early.
- Emit or update structured trace events when adding user-visible runtime behavior.
- Do not reintroduce large state buckets like the original monolithic `game_state.gd`.

## Validation Expectations

- Run `python3 tools/verify_all.py` as the pre-push local gate (`--skip-windowed` on a display-less machine); it orchestrates the static gates, determinism, the full playtest suite, the windowed pixel lanes, legibility, and the refuse-on-mismatch/freshness checks in one run. The full (windowed) run stays the local ritual; CI mirrors it two-tier — the `playtests-headless` workflow runs the same gate with `--skip-windowed` (windowed pixel lanes honestly SKIP there; baselines are renderer-stamped) and `repo-contracts` runs the Godot-free static/freshness/determinism gates plus a PR legibility check. See `docs/RELIABILITY.md` § Local gate.
- Static checks must pass before asking for review.
- Use the DAP smoke runner for runtime validation when the Godot editor is listening on `127.0.0.1:6006`.
- The gated suite is 67 scenarios (54 playtest + 13 smoke); the canonical lists are `PLAYTEST_SCENARIOS`/`SMOKE_SCENARIOS` in `tools/run_playtests.py` — cite them instead of re-enumerating them here.
- Families: smoke/boot probes (`boot`, `overworld_step`, `menu_save`, `wild_battle`, `biome_probe`, `biome_traverse`, `field_move`, `save_migration` + the five windowed sweep entries); journey/soak bots (`playtest_journey`, `playtest_soak`, `playtest_field_soak`, `playtest_breed_soak`, `playtest_entity_soak`); audits (`nav_audit`, `texture_audit`, `data_audit`, `layout_audit`, `world_consistency_audit`, `ui_render_audit`, `ui_tree_dump`) and presentation probes (`battle_anim`, `display_matrix`); gameplay flows (`harvest_flow` … `new_game_flow` / `update_flow`, incl. `dig_silence`); the deterministic `visual_sweep` + satellite sweep families and their `_update` accept-new-baselines variants; `showcase_capture` (docs-only frames); `temporal_flow`; and the windowed-only `play_agent` reference driver.
- `legibility_soak` gates the agent-legibility surfaces: it drives the five agent-facing screens and asserts the ui_tree dumps, the `game/*` Performance monitors, and the trace lifecycle agree (details: `docs/RELIABILITY.md` § Runtime smoke checks).
- Lane 4 (VLM vision review): every windowed sweep run regenerates `.godot-smoke/vision-review.json` via `tools/vlm_reviewer.py` (quarantine-forever findings; `verify_all` R6 refuses a stale manifest) — see `docs/RELIABILITY.md` § Agent vision review.

## Codex Cloud specific instructions

The dedicated setup installs pinned Godot, Xvfb/lavapipe/X11 libraries, Node
22 when the environment is pinned lower, and pinned Command Code. The display
is process state, so start it in the task that runs the sweep:

```bash
bash tools/run_codex_cloud_visuals.sh --check    # display + binary + runtime-auth preflight
bash tools/run_codex_cloud_visuals.sh --focused  # visual_sweep only
bash tools/run_codex_cloud_visuals.sh            # complete verify_all windowed gate
```

Codex Cloud secrets exist only during setup and are removed before the coding
agent runs. Never copy `COMMAND_CODE_API_KEY` from setup into a cached file.
Runtime Command Code review therefore needs either an existing `cmd` login or
`COMMAND_CODE_API_KEY` configured as an agent-readable environment variable;
the latter is appropriate only for a scoped, revocable token whose exposure to
the coding agent is acceptable. Without one of those explicit auth choices,
use the honest headless gate: `python3 tools/verify_all.py --skip-windowed`.
Codex Cloud also blocks agent-phase internet access by default. Enable it for
this environment with HTTPS access to `api.commandcode.ai`, including `POST`;
the read-only HTTP-method restriction is insufficient. Setup-script
internet access does not carry into the visual task. The launcher performs a
bounded, inspect-only model probe and fails before capture when that host,
credential, or the pinned model is unavailable.
When access is enabled, the launcher also sets `NODE_USE_ENV_PROXY=1` and
`NODE_USE_SYSTEM_CA=1` so Command Code's Node `fetch()` follows the Cloud proxy
and trusts the platform system CA without disabling certificate validation.

Lavapipe captures are useful live visual evidence but do not certify or update
the Apple M4 renderer-stamped pixel baselines.

## Cursor Cloud specific instructions

Cursor Cloud VMs can run the windowed + Lane-4 path. They do **not** certify Mac PNG baselines (those are `forward_plus` + `Apple M4` hardware stamps). On adapter mismatch the pixel/region compare is skipped (warn, never a silent pass) and Command Code reviews the live frames. Paired shots still appear in `per_shot` so satellite `*_passed` coverage checks do not suppress the VLM path. A missing-shot `auto_update` (or a satellite copy that omits `auto_update`, including `*_update` names) that would copy lavapipe frames over committed Mac baselines is refused and the pre-run snapshot is restored.

```bash
bash .cursor/start.sh                          # DISPLAY + lavapipe; reuses a live desktop
python3 tools/verify_all.py --skip-windowed    # still the honest path if display/VLM is down
python3 tools/verify_all.py --windowed-timeout 1800   # full gate once DISPLAY + cmd + COMMAND_CODE_API_KEY are up
```

`start.sh` is a short-lived child of `environment.json` `start`. It writes `~/.pokewilds-cloud.env` (no secrets). Later interactive shells source that file via a bashrc/profile hook; `tools/verify_all.py` / `tools/run_playtests.py` load it through `tools/cloud_env.py` when `DISPLAY` is unset or dead, and prepend `$HOME/.local/bin` so `cmd` is found without a login PATH. A manual `source ~/.pokewilds-cloud.env` is not required.

Required Cloud env (never commit values):

- `GODOT_BIN` — set by `.cursor/install.sh` to `$HOME/godot-bin/godot`
- `DISPLAY` — set by `tools/ensure_cloud_display.sh` (reuses computer-use `:1` when live). Installer provisions `x11-utils` (`xdpyinfo`); the probe falls back to `/tmp/.X11-unix` if that binary is missing.
- `COMMAND_CODE_API_KEY` — environment secret; Command Code CLI (`cmd`) is the Lane-4 backend
- `COMMANDCODE_SKIP_UPDATES=1` — persist across boots so the CLI does not self-update mid-run
- `GODOT_AUDIO_DRIVER=Dummy` — no ALSA card on Cloud; Dummy avoids Godot's `ERR_CANT_OPEN` false-red through miss-002 `ERROR:` capture

Install/start live in `.cursor/install.sh` and `.cursor/start.sh`. The personal Cloud environment must Save those scripts (and the API key secret) before new agents inherit them.

## Common Entry Points

- App scene: `res://scenes/app/Main.tscn`
- Autoload runtime: `res://scripts/runtime/game_runtime.gd`
- Battle UI: `res://scripts/ui/battle_view.gd`
- Source data catalog: `res://scripts/data/pokemon_catalog.gd`
- Trace logger: `res://scripts/core/trace_logger.gd`
