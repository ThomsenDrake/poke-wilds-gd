Status: active
Last verified: 2026-08-09
Review cadence days: 14
Source paths: assets/source, THIRD_PARTY.md, docs/references/source-assets.md, README.md, docs/registry/art-anchors.toml, docs/registry/subsystems.toml

# Source Asset Vendoring

## Goal

Drop the `pokewilds/` git submodule entirely. The upstream PokeWilds tree becomes a plain vendored snapshot at `assets/source/` — the full tracked tree, no content trimming, at a relocated path — and every runtime/tooling reference moves from `res://pokewilds/` to `res://assets/source/`. The submodule, `.gitmodules`, and the CI submodule checkouts are removed.

## Provenance

- Upstream project: `https://github.com/SheerSt/pokewilds`
- Pinned commit: `2e1ad7126e57bd293b5610def7d9dd04e0c555f1` (tag `v0.8.11`)
- Vendored: 2026-08-09 — 66,989 files, verified 1:1 against the submodule's tracked tree at the pinned SHA.
- Licensing posture unchanged: upstream ships no `LICENSE`; redistribution responsibility stays with the user ([THIRD_PARTY.md](../../../THIRD_PARTY.md)).

## Execution (two commits)

1. **Commit 1 — `5c0c1f9` (LANDED 2026-08-09)**: "Vendor PokeWilds v0.8.11 source asset snapshot at assets/source/". Pure addition: `git -C pokewilds archive HEAD | tar -x -C assets/source` exported exactly the tracked tree at the pinned SHA (no `.git` gitlink, no untracked `.import` sidecars); `*.import` added to `.gitignore` so Godot's regenerated import sidecars don't flood git status. The submodule was still active at this commit; nothing referenced the new tree yet, so the gate stayed green.
2. **Commit 2 (forthcoming)**: "Switch source asset root to vendored assets/source/ and drop the pokewilds submodule". Mechanical prefix rewrite — `res://pokewilds/` → `res://assets/source/` (GDScript, JSON fixtures, docs) and bare `pokewilds/` → `assets/source/` (registries, tools, doc path citations) — across ~35 GDScript files, `docs/registry/art-anchors.toml` (`source_art` fields; sha256 pins untouched — the bytes are unchanged by the move), `docs/registry/subsystems.toml`, the frozen fixtures (`docs/generated/golden-saves/v4_golden.json` + the 14 visual-baseline sidecars; baseline PNGs untouched), and the current docs. Then submodule removal: `git submodule deinit -f pokewilds && git rm -f pokewilds`, delete `.gitmodules` and `.git/modules/pokewilds`, drop `submodules: true` from both CI workflows.

## Validation

- Full local gate green on the commit-2 HEAD: `python3 tools/verify_all.py` — static gates (incl. art-anchor hashes recomputed against the new `source_art` paths), determinism pins, the full headless playtest suite (incl. `save_stability` validating the rewritten golden), the windowed pixel lanes (`ui_render_audit` + `visual_sweep` validating the rewritten sidecars), and legibility.
- Preceded by a Godot reimport (`godot --headless --import`) so the moved tree's `.import` sidecars and `.godot/imported/` cache are refreshed before the windowed lanes run.
- Boot smoke via the DAP runner when the editor is listening; `git status` clean apart from ignored `.import` output.
- Exhaustive post-rewrite `rg` for `pokewilds`: only upstream-project prose (no trailing slash), historical docs (`docs/superpowers/`, completed exec plans, QUALITY_SCORE narrative — old paths stay as past-tense record), and the `pokewilds-feature-completion.md` filename remain.

## Re-vendoring

Upstream stays on GitHub; the snapshot is refreshed manually if ever needed. Canonical procedure: [docs/references/source-assets.md](../../references/source-assets.md) § Re-vendoring (fresh clone → `git -C <clone> archive <sha> | tar -x -C assets/source` → commit → update the pinned SHA in `source-assets.md` and `THIRD_PARTY.md`).

## Rollback

Reverting commit 2 restores the submodule pointer (`git submodule update --init` repopulates); commit 1 is inert on its own.
