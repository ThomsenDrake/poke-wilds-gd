Status: current
Last verified: 2026-03-06
Review cadence days: 30
Source paths: scripts/app/main.gd, scripts/runtime/game_runtime.gd, tools/check_repo_contracts.py, tools/check_architecture.py

# Core Beliefs

- Repository-local knowledge is the system of record. If a rule matters, it should live in versioned code or docs.
- `AGENTS.md` is a map. Durable detail belongs in `docs/`.
- Architecture is enforced with mechanical checks, not only prose.
- Runtime behavior should be visible to agents through structured traces and repeatable smoke scenarios.
- Growing the codebase without updating specs, registry entries, and quality scoring is treated as drift.
- Small files with one clear responsibility are cheaper for agents to reason about than large multi-role scripts.
