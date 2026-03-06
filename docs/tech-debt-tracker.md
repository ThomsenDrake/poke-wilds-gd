Status: current
Last verified: 2026-03-06
Review cadence days: 14
Source paths: scripts/runtime/battle_runtime.gd, scripts/data/pokemon_catalog.gd, scripts/app/main.gd

# Tech Debt Tracker

## Open items

- Investigate why the current source-data snapshot can produce an empty species catalog and remove the synthetic `SMOKE_MON` fallback once real encounter data is stable.
- Add richer battle smoke assertions beyond one move plus escape.
- Expand warning traces for data fallbacks and save recovery paths.
- Replace remaining dictionary-heavy runtime contracts with more explicit typed boundaries once the gameplay slice stabilizes.
- Add subsystem entries and specs immediately when new systems such as NPCs, PC storage, or field moves are introduced.
