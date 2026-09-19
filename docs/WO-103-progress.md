# WO-103 — progress

Session 2026-09-18. Findings: `docs/WO-103-findings.md`. Field runbook:
`docs/WO-103-field-runbook.md`. Builds on WO-102.5 (0.25.1, native NPC scan
+ uncapped co-located ownership shipped).

## Phases

| phase | state | evidence |
|---|---|---|
| 0 — measure what's replaced | **instrumentation built**: `MP-NPCREAD path=lua\|native\|mixed n= mean_ms= p50_ms= p95_ms= max_ms= window_s=` (a Lua-side bucketed-histogram mirror of `CadenceStats.cs`'s scheme — Lua cannot call the C# class), `MP-NPCTRACK tracked= culled=` every 15s. **Baseline NOT taken — no game ran.** | (code-verified); (synthetic) scenario `dd`; runbook §1 handed off |
| 1 — uncap the radius | **shipped**: upper clamp removed (floor 10m only), default 150→300m, `GameBridge.cs`'s mirror bumped to match. Reply truncation now logs loudly with a real dropped-count on both sides — fixing this also fixed a latent bug where a truncated scan under-reported its own `total_walked`/`vptrOk`/`nameRejects` (the loop used to `break` outright). A SECOND, self-found ceiling: the agent→Lua push (not the wire) would have exceeded the transport's 4000-char batching budget at the old 200-name cap once positions were added — cut to 40, with the arithmetic in a comment | (code-verified); wire header 14→18 bytes, agent<->DLL local pipe only; (synthetic) scenario `bb` updated (radius-clamp test rewritten, 4 new checks) |
| 2 — native position/yaw | **shipped behind `mp_npc_read_native_on` (on)**: the native scan already computed and wired x/y/z/yaw per entity (WO-102.5) — the entire gap was the agent discarding them before the push. Now pushed as `name:x:y:z:yaw:isHorse`; `KCD2MP_NpcSyncTick`'s read loop takes position from the push when fresh, else the SAME `e:GetWorldPos()` it always called (the entity is fetched regardless, for health/dead/KO/drawn/engaged — WO-103.5's job, unmapped). This is the answer to the cadence question: the fallback is free, so nothing stale ever ships and no cadence/second-call fix was needed. `mp_npc_read_compare` known-answer check (age-scaled tolerance) fails the toggle closed on a genuine mismatch; re-enabling re-verifies immediately | (code-verified); (synthetic) scenario `dd`, 18 new checks; NOT live-verified |
| 3 — find the ceiling | **NOT RUN** — no game this session. Runbook §2 (45/150/300/600/1000/beyond, recording tracked/culled/MP-NPCREAD/truncation) written for the maintainer | none this session |
| 4 — verification | synthetic 194/194 (was 169, +25, 0 regressed); every other Lua synthetic suite re-run green (48/35/33/72/47/70/101/32/160/50) + WO-99's durable "exits 2" quirk unchanged; agent unit tests 157/157 (was 156, +1); relay 13/13 unchanged (no wire change crosses it); native + full dotnet solution build clean | (observed) this session's own runs |

## Commits (`WO-103:` on `origin main`)

1. `WO-103 Phase 1: native reply-truncation accounting (dropped-match count)`
   — native (`npc_scan.h/.cpp`, `pipe_server.h/.cpp`) + `NpcScanCodec.cs` +
   its tests. Findings §1.2-1.3.
2. `WO-103 Phases 0-2: read-loop timing, uncapped radius, native
   position/yaw` — `kdcmp.lua` + `GameBridge.cs` together (they land in one
   commit because Phase 0's bracket and Phase 2's substitution touch the
   same tick function; splitting them would have meant an artificial
   mid-function commit boundary, not a real one). Findings §0-§2.
3. `WO-103: synthetic coverage for Phases 0-2 (scenario dd, bb radius fix)`
   — `tools/Test-WO102Synthetic.lua`. Findings §4.1.
4. Docs — this file, `docs/WO-103-findings.md`,
   `docs/WO-103-field-runbook.md`.
5. End gate — 0.26.0 build (below).

## Baseline before any change (observed this session)

* `cmake --build native/build --target KCDMP` (via `native/Build-Native.ps1`):
  green, 396,800 bytes, before any WO-103 change was reverted to check —
  confirmed the working tree built clean at the start via the SAME command
  after all changes landed (below), not compared against a pre-change
  artifact size (none was taken; WO-102.5's own baseline section didn't
  either).
* `dotnet test KcdMp.Client.Tests`: 157/157 post-change. `KcdMp.Relay.Tests`:
  13/13. (Pre-change baseline not separately captured — the repo was clean
  at session start per `git status`, and WO-102.5's own end-gate numbers
  — 156/156 agent, 13/13 relay — are the last known-good baseline this
  session built on.)
* `tools/Test-WO102Synthetic.ps1`: 169/169 pre-change (WO-102.5's own
  shipped count, confirmed by reading that session's progress doc, not
  re-run against the pre-change tree separately since the tree was already
  clean at 169/169 per WO-102.5's own end gate).

## Not done, and why

* **Phase 3, entirely** — the radius ceiling was not found. No game ran
  this session (same environment constraint as WO-102/WO-102.5's opening
  sessions). `docs/WO-103-field-runbook.md` §2 is the handoff.
* **Phase 0's baseline A/B** — `MP-NPCREAD path=lua` vs `path=native` was
  never captured against a live game, so "is Phase 2 actually faster" is
  still an open, honestly-stated question (findings §2.4) — the isolated
  win is expected to be small this WO regardless (health/dead/KO/drawn/
  engaged still force `GetEntityByName` every tick), and that expectation
  itself has not been confirmed live either.
* **The agent-push chunking gap** (findings §1.4) — at high tracked counts,
  the 40-entry push cap means most tracked NPCs beyond the first 40 keep
  falling back to the live read. Correct and safe, but it means Phase 3's
  own ceiling-finding radii (where tracked counts are largest) are exactly
  where Phase 2's win shrinks the most. Not fixed this session; chunking
  the push across multiple `ExecuteString` calls is the stated follow-up.
* **The two-machine falsifiable condition** (WO-102.5's own runbook §4) —
  still not run, unrelated to this WO's own changes but unresolved from
  the prior session and worth restating so it isn't lost.
* **WO-103.5** (health/dead/KO/drawn/engaged natively) — deliberately not
  attempted; explicitly out of scope per the session prompt. The wire
  format is left exactly where WO-102.5 shipped it (`NpcEntry` unchanged in
  shape); that future session will need to grow the per-entry structure
  itself, a bigger wire change than either of this WO's two additions
  (a header-only growth, and an agent-local push format change that never
  touches the DLL<->agent wire).

## An eighth costume for the standing trap

"A plausible result is not a result" (WO-96/97/99.5/100/100.5/101/102.5)
gained an eighth instance this session: `npc_scan.cpp`'s pre-WO-103
truncation `break` silently under-reported `total_walked`/`vptrOk`/
`nameRejects` for any truncated scan (the walk stopped early, so these
counters stopped incrementing early too) — a normal-looking number that was
quietly wrong. Found while fixing the NAMED gap (the missing dropped-count
itself), not independently sought. Findings §1.2.
