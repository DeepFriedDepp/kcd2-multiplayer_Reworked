# WO-77 progress

Read `docs/WO-77-findings.md` first — it carries the evidence, the
implementation decisions and the Step 3 call. This file is the
state-of-play.

## Status

| Phase | State |
|---|---|
| 0 — ground truth | done. `main` up to date at WO-76's head; WO-76 findings read — Phase 3 discriminator **was not run**, so no data; `Test-NpcSyncE2E.ps1` Phase 2 read directly, asserts post-WO-39 behaviour; WO-75 design read in full |
| 1 — Step 1 (renderer) | done. Time-based interpolation-behind in `kdcmp.lua`: 3-deep ring, hold-at-newest, DELAY-capped segments, copied hysteresis bands, `lerpAngle` yaw, snap on > 5 m. `mp_npc_smooth on\|off`, **default ON** (override recorded) |
| 1 — Step 2 (cadence) | done. `emitMs` 250 → 100, unconditional; DELAY derived from `emitMs` (`KCD2MP_NpcSmoothDelayS`, 0.120 s) |
| 1 — Step 3 (call) | **undetermined** — no discriminator data exists; recommendation recorded (run WO-76 Phase 3 first). Not built, by design |
| 2 — verification | done. New `tools/Test-NpcSmoothSynthetic.ps1` + `.lua`, 39/39; six existing suites green (22/22, 14/14, 15/15 fresh relay, 29/29, 35/35, 11/11) |
| Docs | this file, `WO-77-findings.md`; one row in `PROJECT-STATE.md`'s test table; one clause in the README NPC-sync row |
| Code changes | Lua only (`kdcmp.lua`), plus PowerShell/Lua test tooling. No .NET, native, protocol or relay change |
| `VERSION` | unchanged (`0.19.0`) |
| Live game / two-machine session / footage | none — not available; stated as the open question it is |

## Commits, in order (all on `main`, all pushed)

1. `WO-77: NPC puppet renderer -- time-based interpolation-behind, emit 10 Hz (WO-75 Steps 1+2)`
2. `WO-77: synthetic stream test for the puppet renderer (MoonSharp), README/PROJECT-STATE rows`
3. `WO-77: findings and progress docs`

## What was done, in order

1. Confirmed the session was in the right repo (`git remote -v`) — it
   started from a generic scratch workspace and was redirected.
2. `git pull` (already up to date). Read `docs/WO-75-jitter-design.md` in
   full, `docs/WO-76-findings.md` (§3: discriminator not run), and
   `Test-NpcSyncE2E.ps1` Phase 2 directly.
3. Read the puppet path (`KCD2MP_ApplyNpcState`, `KCD2MP_NpcPuppetTick`,
   `KCD2MP_StartNpcPuppet`, `KCD2MP_NpcSyncTick`, the `npcSync` config
   block, `KCD2MP_InterpPump`) and the ghost pieces to be copied, not
   shared (`lerpAngle`, `ANIM_UP`/`ANIM_DOWN`, `calcAnimTag`).
4. Implemented Step 1 and Step 2 in `kdcmp.lua`; kept the legacy lerp as the
   `mp_npc_smooth off` branch verbatim. Parsed the whole file under
   MoonSharp before anything else.
5. Built the synthetic harness: a PowerShell script that loads MoonSharp
   from the NuGet cache (restoring it once if absent), splices the real
   `kdcmp.lua` into a scenario file, stubs the engine and the clock, and
   asserts on what the puppet entity is told to render. Two harness
   iterations were needed (a `$PSScriptRoot`-in-param-default quirk in
   Windows PowerShell 5.1; a non-strict sort comparator) and one test
   metric was corrected (a hold tick renders *at* the newest sample, so
   "position unchanged" was the wrong way to count holds) — all fixed
   before the final 39/39.
6. Built the Debug relay; ran `Test-Sessions`, `Test-Combat` on one relay;
   restarted it fresh for `Test-Dice`; ran the three self-starting suites
   sequentially (two of them share default ports).
7. Wrote the docs; committed in three commits; pushed.

## Not done, deliberately

- Step 3 (native AI suppression) — different risk class, own session;
  and no data yet says it is needed. See findings §4.
- Adaptive per-NPC emit cadence — noted as a future refinement in the
  config comment.
- The design's Step 4 ghost-path housekeeping.
- No `VERSION` bump, no release notes — the maintainer's call on when this
  ships.
- No live game run of any kind. The two open questions (human feel; WO-60
  under two-player pressure) are stated as open, not resolved.

## For the next field session

- Grep any incoming logs for `[WO66-REJECT]`, `NPC-SYNC tracking` /
  `untracking`, `NPC-FIGHT`, `CHAIN LEAK CONFIRMED`; poll
  `GET api/information/npc-validation` on the relay.
- `mp_npc_smooth off` mid-session is the live A/B for the renderer.
- Run `Test-NpcSyncE2E.ps1` Phase 3 with and without `AI.SetIgnorant` —
  that is the Step 3 decider.
