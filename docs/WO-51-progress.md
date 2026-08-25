# WO-51 progress

## 2026-08-25 — design session (Fable 5), no code

- Read in full this session: WO-26 findings + shared-combat design, WO-28,
  WO-32, WO-38, WO-39, WO-40 findings + footage findings, WO-41 progress,
  WO-49 findings; plus current source spot-checks: `ClientHandler.cs`
  (claim table), `ClientSession.cs` (claim drop), `GameBridge.cs`
  (0x27/0x30/0x21 apply paths), `kdcmp.lua` (npcSync emit gate, drag
  sensor, `KCD2MP_ApplyNpcState`).
- Key code facts pinned for the synthesis (all read this session):
  - Non-authorities send NPC state **only** from the drag sensor
    (`kdcmp.lua:2076-2079`) — per-entity claims never fire in combat.
  - The tracked set is ≤5 NPCs within 30 m of the **authority's own
    player** (`kdcmp.lua:1917`).
  - Swing cues emit only on the **authority's own** health drop
    (`kdcmp.lua:2100`).
  - The 0x26/0x27 `hp` field is stored on the puppet record, never written
    to the entity (`kdcmp.lua:2194`) — health converges via damage events
    (0x12/0x30) only.
- Key evidence-status facts pinned: Flow B (0x21/0x22) cross-machine step
  never verified since WO-28; reload-convergence / weather-arbiter / 0x30
  E2Es still "one install away" per WO-40:589 with no later doc closing
  them; the only field observation of joint combat is
  `WO-40-footage-findings.md:53-58`, under a 24.5 h clock divergence on a
  pre-fix build.
- Deliverable: `docs/WO-51-findings.md` — Phase 1 complete problem
  synthesis (per-mechanism closed/mitigated/live table), Phase 2 option
  space (fixed authority / combat-scoped claims / deep suppression /
  dedicated instance / finish-the-shared-arena), Phase 3 ordered
  recommendation (measure → Flow B + symmetric cues → suppression →
  combat-scoped claims; do not build the dedicated instance) with explicit
  evidence triggers that would change it.
- No live game work was needed; no code, VERSION, or installer changes.
