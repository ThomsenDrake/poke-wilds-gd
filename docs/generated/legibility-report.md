Status: generated
Last verified: 2026-07-21
Review cadence days: 7
Source paths: tools/generate_legibility_report.py, tools/check_repo_contracts.py, tools/check_architecture.py, tools/check_quality_docs.py, tools/contrast_check.py, tools/cvd_sim.py, tools/graduation_ledger.py, tools/vision_metrics.py

# Legibility Report

- Generated at: 2026-07-21 17:12:54Z
- Total findings: 0
- contrast_low findings (advisory, quarantine-tier): 0
- cvd_collapse findings (accessibility evidence, quarantine-forever): 17

## Repo Contracts

No findings.

## Architecture

No findings.

## Quality Docs

No findings.

## Contrast (WCAG rendered-pixel)

No contrast_low findings (all measured labels meet the WCAG AA bar).

- 06_menu.png "MENU" ratio 7.13 (need 4.5) ok
- 06_menu.png "Z: Select   X: Close" ratio 5.987 (need 4.5) ok
- 07_party_screen.png "19/19" ratio 5.67 (need 4.5) ok
- 07_party_screen.png "61/61" ratio 6.146 (need 4.5) ok
- 07_party_screen.png ">" ratio 11.415 (need 4.5) ok
- 07_party_screen.png "POKEMON" ratio 7.374 (need 4.5) ok
- 07_party_screen.png "Z: Actions   X: Back" ratio 5.733 (need 4.5) ok
- 07_party_screen.png "chikorita  Lv.5" ratio 6.151 (need 4.5) ok
- 07_party_screen.png "decidueye  Lv.20" ratio 5.221 (need 4.5) ok
- 08_bag_screen.png "A tool for catching POKéMON." ratio 5.523 (need 4.5) ok
- 08_bag_screen.png "BAG" ratio 8.991 (need 4.5) ok
- 08_bag_screen.png "Z: Use   X: Back" ratio 6.207 (need 4.5) ok
- 09_battle.png "61/61" ratio 6.833 (need 4.5) ok
- 09_battle.png ":L 18" ratio 6.422 (need 4.5) ok
- 09_battle.png ":L 20" ratio 6.259 (need 4.5) ok
- 09_battle.png "A wild decidueye appeared!" ratio 7.518 (need 4.5) ok
- 09_battle.png "DECIDUEYE" ratio 7.401 (need 4.5) ok
- 09_battle.png "DECIDUEYE" ratio 7.401 (need 4.5) ok
- 10_battle_moves.png "35" ratio 5.147 (need 4.5) ok
- 10_battle_moves.png "35" ratio 5.147 (need 4.5) ok
- 10_battle_moves.png "61/61" ratio 6.963 (need 4.5) ok
- 10_battle_moves.png ":L 18" ratio 6.555 (need 4.5) ok
- 10_battle_moves.png "DECIDUEYE" ratio 8.078 (need 4.5) ok
- 10_battle_moves.png "FLYING" ratio 7.708 (need 4.5) ok
- 10_battle_moves.png "PECK" ratio 8.404 (need 4.5) ok
- 10_battle_moves.png "RAZOR LEAF" ratio 7.555 (need 4.5) ok
- 10_battle_moves.png "SYNTHESIS" ratio 6.621 (need 4.5) ok
- 11_battle_after_attack.png "38/61" ratio 6.695 (need 4.5) ok
- 11_battle_after_attack.png ":L 18" ratio 6.422 (need 4.5) ok
- 11_battle_after_attack.png ":L 20" ratio 6.259 (need 4.5) ok
- 11_battle_after_attack.png "DECIDUEYE" ratio 7.401 (need 4.5) ok
- 11_battle_after_attack.png "DECIDUEYE" ratio 7.401 (need 4.5) ok
- 11_battle_after_attack.png "decidueye used peck!
It's super effective!
decidueye took 23 damage.
decidueye used astonish!
It's super effective!
decidueye took 23 damage." ratio 6.525 (need 4.5) ok
- 12_battle_items.png "38/61" ratio 6.413 (need 4.5) ok
- 12_battle_items.png ":L 18" ratio 6.555 (need 4.5) ok
- 12_battle_items.png ":L 20" ratio 6.388 (need 4.5) ok
- 12_battle_items.png "BACK" ratio 8.308 (need 4.5) ok
- 12_battle_items.png "DECIDUEYE" ratio 8.078 (need 4.5) ok
- 12_battle_items.png "DECIDUEYE" ratio 8.078 (need 4.5) ok
- 12_battle_items.png "POKE BALL x5" ratio 6.879 (need 4.5) ok
- 12_battle_items.png "POTION x3" ratio 6.954 (need 4.5) ok

## Color-vision deficiency (Machado 2009)

Severity 1.0 (full dichromacy); collapse = a pair with original CIE76 deltaE >= 10.0 falling below it under simulation. Quarantine-forever: accessibility evidence, never a red gate.

cvd_collapse findings: 17 (quarantine-forever)

- [deutan] hp_bar: ['#3aa63f', '#d03d34'] deltaE 109.18 -> 8.14 (< 10.0)
- [protan] 09_battle.png: ['#308840', '#b86830'] deltaE 70.99 -> 5.41 (< 10.0)
- [protan] 09_battle.png: ['#308840', '#ba6c35'] deltaE 69.77 -> 3.52 (< 10.0)
- [protan] 09_battle.png: ['#338a42', '#b86830'] deltaE 70.8 -> 6.09 (< 10.0)
- [protan] 09_battle.png: ['#338a42', '#ba6c35'] deltaE 69.56 -> 4.2 (< 10.0)
- [protan] 10_battle_moves.png: ['#308840', '#b86830'] deltaE 70.99 -> 5.41 (< 10.0)
- [protan] 10_battle_moves.png: ['#308840', '#ba6c35'] deltaE 69.77 -> 3.52 (< 10.0)
- [protan] 10_battle_moves.png: ['#338a42', '#b86830'] deltaE 70.8 -> 6.09 (< 10.0)
- [protan] 10_battle_moves.png: ['#338a42', '#ba6c35'] deltaE 69.56 -> 4.2 (< 10.0)
- [protan] 11_battle_after_attack.png: ['#308840', '#b86830'] deltaE 70.99 -> 5.41 (< 10.0)
- [protan] 11_battle_after_attack.png: ['#308840', '#ba6c35'] deltaE 69.77 -> 3.52 (< 10.0)
- [protan] 11_battle_after_attack.png: ['#338a42', '#b86830'] deltaE 70.8 -> 6.09 (< 10.0)
- [protan] 11_battle_after_attack.png: ['#338a42', '#ba6c35'] deltaE 69.56 -> 4.2 (< 10.0)
- [protan] 12_battle_items.png: ['#308840', '#b86830'] deltaE 70.99 -> 5.41 (< 10.0)
- [protan] 12_battle_items.png: ['#308840', '#ba6c35'] deltaE 69.77 -> 3.52 (< 10.0)
- [protan] 12_battle_items.png: ['#338a42', '#b86830'] deltaE 70.8 -> 6.09 (< 10.0)
- [protan] 12_battle_items.png: ['#338a42', '#ba6c35'] deltaE 69.56 -> 4.2 (< 10.0)

## Graduation & calibration

Ledger `graduation-ledger.json` (schema graduation-ledger/1): 7 recorded run(s), threshold 5 consecutive clean eligible runs; streaks are computed from the entries, never narrated. Missing-evidence ineligibles (headless/skipped, or ok=true runs lacking a pass event) neither count nor break streaks; a windowed RED (ok=false) BREAKS consecutiveness for every state (a failed windowed audit is not a clean windowed run).

GRADUATED_STATES (live): {"battle_action": true, "battle_item": true, "battle_message": true, "battle_moves": true}

Flips (recorded evidence):
- battle_moves: anchor (glyph template match) at 7b733946b2ad73930cda0d9d3a4e05a73ec3a37c, evidence runs [1, 2, 3, 4, 5]
- battle_item: anchor (glyph template match) at 7b733946b2ad73930cda0d9d3a4e05a73ec3a37c, evidence runs [1, 2, 3, 4, 5]
- battle_action: lint (lint cleanliness on ACTION_ROWS (garble/low_ink/forbidden_ink)) at 7b733946b2ad73930cda0d9d3a4e05a73ec3a37c, evidence runs [1, 2, 3, 4, 5]
- battle_message: box (lint cleanliness; glyph match excluded by design) at 7b733946b2ad73930cda0d9d3a4e05a73ec3a37c, evidence runs [1, 2, 3, 4, 5] — judgment: BOX mode: the message string's exact pen is engine-owned — BattleView.tscn MessageLabel at (8,103) vs model MSG_INTERIOR box at (7,104), a ~1px placement fringe; that fringe is why white-bg glyph template match is excluded for battle_message by design (text_oracle.check skips non-anchor glyphs). Lint cleanliness (low_ink/forbidden_ink/garble) on the state's ACTION_ROWS + forbidden rects over the recorded 5-run window (runs 1-5, HEAD 7b733946, zero findings, text_oracle_passed on every entry) is accepted as sufficient evidence for graduation. The deferral option was considered and rejected: the streak is complete at 5/5 with the engine pinning stable at the measured offset across all five runs.

Exit-criterion-4 seeded proof (temporary perturbations, all reverted byte-identical; documented as PROOF, never counted as organic statistics — graduated_reds/confirmed/precision/recall exclude these):
- plant 1 (battle_moves, graduated): 54 findings {"battle_moves/glyph_mismatch": 54} (trace session 27446-27508) — RED — both pass events absent (54 glyph mismatches routed to _failures by the graduated gate)
- plant 2 (battle_item, un-flipped): 30 findings {"battle_item/glyph_mismatch": 30} (trace session 27509-27548) — GREEN quarantine — ui_render_audit_passed fired with quarantined=30 (text_oracle_passed withheld: 30 glyph mismatches), _failures empty
- post-flip clean run 6: both pass events, quarantined=0 (no flip-introduced false positives)
- revert proof: ui_render_model.gd and scripts/ui/battle_surface*.gd byte-identical to HEAD (git diff empty); the only scripts/ change in the tree is the GRADUATED_STATES flip in ui_render_audit.gd

Per-state trailing eligible-clean streak:
- battle_moves: 7/5 — GRADUATED
- battle_item: 7/5 — GRADUATED
- battle_action: 7/5 — GRADUATED
- battle_message: 7/5 — GRADUATED

Calibration (cadence: weekly, aligned to the legibility-garden workflow (Mon 14:00 UTC); a trend needs >=2 cycles):
- cycle 1 (2026-07-21, head 7b733946b2ad, window [1, 6]): precision undefined (0 of 0 — no quarantine findings in the window); graduated reds / recall undefined (0 of 0 — no real defects in the window; baseline cycle)
  notes: Cycle 1 baseline recorded 2026-07-21 at 7b733946b2ad73930cda0d9d3a4e05a73ec3a37c. A two-cycle TREND requires the next legibility-garden cycle (weekly, Mon 14:00 UTC); none is claimed from a single cycle. Seeded-proof plants (exit criterion 4, temporary, reverted — documented as proof, NOT counted as organic statistics): (1) +1px MOVE_ANCHOR shift in ui_render_model.gd (battle_moves, graduated) => scenario RED via the graduated gate (ui_render_audit_passed in missing_all, 54 glyph_mismatch quarantine_finding traces (trace session start_line 27446, findings lines 27452-27505; no ui_render_audit_passed/text_oracle_passed fired), zero per-bug assertions); (2) same +1px anchor-shift class on ITEM_ANCHOR with battle_item temporarily un-flipped => GREEN, 30 battle_item glyph_mismatch quarantine findings (trace session start_line 27509, findings lines 27515-27544), _failures empty, ui_render_audit_passed fired with quarantined=30; (3) post-flip clean run => GREEN, both pass events, recorded as run 6 (streak 6/5); ui_render_model.gd reverted byte-identical to HEAD (git diff empty).

## SSIM corroboration (optional, quarantine-forever)

Skipped: scikit-image not installed — opt in with `uv sync --extra vision` (or `pip install scikit-image`); this extra is quarantine-tier and never gates (quarantine-forever, never a gate).
