Status: completed
Last verified: 2026-08-24
Review cadence days: 14
Source paths: assets/source, LICENSING.md, THIRD_PARTY.md, docs/references/source-assets.md, README.md, docs/registry/art-anchors.toml, docs/registry/subsystems.toml

# Source Asset Vendoring

Re-verified 2026-08-24: `assets/source/` is still the vendored v0.8.11 snapshot (no `pokewilds/` submodule); `THIRD_PARTY.md` and `docs/references/source-assets.md` still own provenance. No re-vendor since 2026-08-09.

## Goal

Drop the `pokewilds/` git submodule entirely. The upstream PokeWilds tree becomes a plain vendored snapshot at `assets/source/` — the full tracked tree, no content trimming, at a relocated path — and every runtime/tooling reference moves from `res://pokewilds/` to `res://assets/source/`. The submodule, `.gitmodules`, and the CI submodule checkouts are removed.

## Provenance

- Upstream project: `https://github.com/SheerSt/pokewilds`
- Pinned commit: `2e1ad7126e57bd293b5610def7d9dd04e0c555f1` (tag `v0.8.11`)
- Vendored: 2026-08-09 — 66,989 files, verified 1:1 against the submodule's tracked tree at the pinned SHA.
- Licensing posture: owner-documented in [LICENSING.md](../../../LICENSING.md). Upstream ships no `LICENSE`; this project does not relicense that tree. Provenance stays in [THIRD_PARTY.md](../../../THIRD_PARTY.md).

## Execution (three commits)

1. **Commit 1 — `5c0c1f9` (LANDED 2026-08-09)**: "Vendor PokeWilds v0.8.11 source asset snapshot at assets/source/". Pure addition: `git -C pokewilds archive HEAD | tar -x -C assets/source` exported exactly the tracked tree at the pinned SHA (no `.git` gitlink, no untracked `.import` sidecars); `*.import` added to `.gitignore` so Godot's regenerated import sidecars don't flood git status. The submodule was still active at this commit; nothing referenced the new tree yet, so the gate stayed green.
2. **Commit 2 — `db99e4c4` (LANDED 2026-08-09)**: "Drop pokewilds submodule; switch asset refs to vendored assets/source/". Mechanical prefix rewrite — `res://pokewilds/` → `res://assets/source/` (GDScript, JSON fixtures, docs) and bare `pokewilds/` → `assets/source/` (registries, tools, doc path citations) — across ~35 GDScript files, `docs/registry/art-anchors.toml` (`source_art` fields; sha256 pins untouched — the bytes are unchanged by the move), `docs/registry/subsystems.toml`, the frozen fixtures (`docs/generated/golden-saves/v4_golden.json` + the 14 visual-baseline sidecars; baseline PNGs untouched), and the current docs. Then submodule removal: `git submodule deinit -f pokewilds && git rm -f pokewilds`, delete `.gitmodules` and `.git/modules/pokewilds`.
3. **CI follow-up — `d5a658ab` (LANDED 2026-08-09)**: "Drop submodule checkouts from CI workflows; watch assets/ in repo-contracts". Removed `submodules: true` from both CI workflows and replaced the `.gitmodules` path trigger with `assets/**` in `repo-contracts.yml` (leftover cleanup from commit 2).

## Validation

- Godot reimport (`/Applications/Godot.app/Contents/MacOS/Godot --headless --import --path .`) regenerated 56,424 `.import` sidecars under `assets/source/` (gitignored) and rebuilt `.godot/imported/` before the windowed lanes ran.
- Full local gate re-run 2026-08-09 at `df1b7b29` (the close-out HEAD; only docs moved after): **21 PASS / 2 FAIL / 0 SKIP / 0 REFUSE** — determinism pins + canary + double-run, the full headless suite (61/61, incl. `save_stability` validating the rewritten golden), all eight windowed pixel lanes (`ui_render_audit` + `visual_sweep` family validating the rewritten sidecars, zero anchor refusals), and legibility all GREEN under `res://assets/source/`.
- The 2 FAILs are **pre-existing, unrelated to the vendoring** (verified by running both gates on a `f98a7cab` worktree — they fail identically there, before commit 1 existed): `check_architecture` line budgets blown by f98a7cab (`field_action_router.gd` 227>220, `battle_rules.gd` 326>320, `creation_screen.gd` 226>220, `party_rows.gd` 262>220) and the `check_repo_contracts` registry-coverage gap for f98a7cab's `dig_silence_scenario.gd`. Documented in [docs/tech-debt-tracker.md](../../tech-debt-tracker.md) for the f98a7cab owner; not fixed here (unrelated workstream).
- Vendoring fallout found and fixed during validation: the db99e4c4 sidecar rewrite drifted the `miss-001-hp-bar-11px` plant's four `revert_scope` sidecar pins — re-stamped to current tree bytes per the ledger's `re_stamp_log` convention (commit `bceda5fc`; HP-bar revert contract verified intact, visual_sweep green).
- Post-rewrite `rg` for `pokewilds`: only upstream-project prose (no trailing slash), historical docs (`docs/superpowers/`, completed exec plans, QUALITY_SCORE narrative — old paths stay as past-tense record), and the `pokewilds-feature-completion.md` filename remain.

## Re-vendoring

Upstream stays on GitHub; the snapshot is refreshed manually if ever needed. Canonical procedure: [docs/references/source-assets.md](../../references/source-assets.md) § Re-vendoring (fresh clone → `git -C <clone> archive <sha> | tar -x -C assets/source` → commit → update the pinned SHA in `source-assets.md` and `THIRD_PARTY.md`).

## Rollback

Reverting commit 2 restores the submodule pointer (`git submodule update --init` repopulates); commit 1 is inert on its own.
