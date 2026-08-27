# WO-64 — progress

## Session 1 (2026-08-27)

- Shallow-cloned `DeepFriedDepp/KCD2Online_forked` @ `5777c15` (v0.1.6) into
  the session scratchpad; all reading done against that pin.
- Read in full or in relevant part (source, not just docs):
  `native_remote_avatar_backend.{hpp,cpp}` (complete),
  `native_remote_avatar_equipment.cpp` (complete),
  `remote_avatar.hpp` (complete), `remote_avatar_readiness.hpp` (complete),
  `client.cpp` interpolation + snapshot-accept region,
  `npc_registry.{hpp,cpp}` (complete),
  `native_entity_backend.cpp` NPC-apply/isolation regions,
  `item_ledger.hpp`, `environment.hpp`, `server_core.hpp`,
  `server_main.cpp` head, `CMakeLists.txt` server targets,
  their `README.md`, `multiplayer.md`, `player-lifecycle.md`,
  `libkcd2-kcse-migration.md`, `libkcd2-vendor.md`.
- Cross-checked against our own record: WO-60 findings (full), WO-40 weather
  section, `kdcmp.lua` weather block, native/ + kdcmp/ tree layout.
- Wrote `docs/WO-64-findings.md`: four phases, each closed with an explicit
  adopt/don't verdict; six scoped follow-up WOs (A, B, D, E, F, G) ranked in
  the summary table; four documented docs-vs-code discrepancies in their repo
  that redirect the phase conclusions (Lua spawn behind "native" claims, no
  MovementController path, 5 s not 2 s lease, dynamic NPC replication disabled
  in code).
- Headline conclusions: no ghost-representation migration (their shipped spawn
  is our spawn family); dedicated server is authority/persistence only, keeps
  the headless-instance idea closed; our claim/hold stands (their lease has no
  defense for the menu-pause flap ours was built for) with three refinements
  worth porting; the two best single finds are the Lua
  `Contexts.SetPersistentOption`/`crime_disableReport` ghost-isolation block
  and native `IEntity::Activate(false)` puppet brain suppression (pilot).
- No implementation, no VERSION change, no live session. Nothing in this WO
  was live-verified — explicitly labeled throughout the findings.
