Status: generated
Last verified: 2026-07-21
Review cadence days: 7
Source paths: tools/generate_legibility_report.py, tools/check_repo_contracts.py, tools/check_architecture.py, tools/check_quality_docs.py, tools/contrast_check.py, tools/cvd_sim.py

# Legibility Report

- Generated at: 2026-07-21 11:38:55Z
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
