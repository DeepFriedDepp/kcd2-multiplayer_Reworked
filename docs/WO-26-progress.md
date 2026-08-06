# WO-26 progress

Session 2026-08-06. Game running throughout until the Phase 1 crash. Human
present at the machine. `playline2` re-confirmed disposable at session start
and backed up to `playline2_wo26backup` before any live combat. Test site: an
isolated field verified to hold 0 actors within 60 m.

## Coverage

| phase | status | result |
|---|---|---|
| 0 — does a plain soul-backed ghost already fight back? | done, both directions | **Yes, decisively.** Under direct attack it treats the hit as a crime, arms itself unprompted, and took the human 100 → 57 HP in one exchange. As a bystander it engaged a hostile ghost it was never told about, pursued it 340 m and killed it. `aggroEnabled=false` throughout. |
| 1 — can a player be Henry? | done, stopped at the gate | **No.** Distinct class confirmed at three layers; second instance spawns malformed (no archetype, no faction) and **crashed the game** within ~52 error frames. Live-observed, not inferred. |
| 2 — reactive hostility without a face conflict | reached, answered by Phase 0 | No lever missing. Automatic, faction-free, face-preserving engagement already ships. Step 2's narrower-flag hunt deliberately skipped — its premise was false. |
| 3 — ship something | **not started** | No explicit mechanism-specific human decision, and Phase 0 changed what the decision is about. |

## What actually happened, in order

1. Confirmed game live (REST up, 1494 souls), player in Troskovice with 18
   actors within 40 m — refused to test there. Human relocated; re-scanned and
   got 0 actors within 60 m before spawning anything.
2. Read `KCD2MP_SpawnGhost` and replicated its exact spawn shape rather than
   guessing at it, so Phase 0 tested the shipped default and not an
   approximation.
3. **0a**: `wo26A`, soul binding verified by read-back first, 12 s stationary
   baseline, then a real attack by the human. Full telemetry captured.
4. **0b**: first run lost to my own tooling bug (`powershell -File` collapses
   `-Ghosts a,b` into one literal name). Recovered the end state from the API
   directly — the bandit ghost read `IsDead=true` with the soldier ghost 1.07 m
   away and 340 m from spawn — then re-ran fully instrumented and captured the
   whole duel.
5. **1**: static evidence from the locally extracted `Scripts.pak` / `Tables.pak`
   plus live `AI.GetTypeOf` and `/api/rpg/SoulList?info`. Recommended stopping
   without the live spawn; human directed running it; it crashed the game.
6. Cleanup swept before the crash: 0 test entities remaining.

## Judgement calls worth flagging

- **Refused the first test site.** The human said they were far from anything;
  the sphere query said 18 actors within 40 m. Re-checked after they moved
  rather than taking either statement on trust.
- **Asked open, non-leading questions about what the human saw**, offering fall
  damage and self-inflicted damage as alternatives to "the ghost hit me". The
  damage attribution rests on that answer, so it mattered that it not be led.
- **Did not round up the 0a disengagement.** The ghost broke off because the
  human flew away, not because it de-escalated. The WO's "released back to
  being ignored once it ends" clause is recorded as **untested**, which is the
  one part of the goal this session did not establish.
- **Recommended stopping Phase 1 before the live test, and was wrong to want
  to stop.** The static evidence pointed the right way but the crash is a
  materially better finding than the inference would have been. Recorded
  because the WO asked for the stop condition to be used honestly, and the
  honest record is that the human's call improved the result.
- **Discarded `Scripts/FeatureTests/found_checkpoints.csv`** after initially
  reaching for it — it names real C++ files and line numbers but is stale
  Crysis 3 SDK boilerplate, not Warhorse code. Recorded in the findings so the
  next session does not spend time on it.

## Corrections this session forces on prior work

- **WO-22 A2** ("the ghost fights back is not demonstrated") — superseded.
- **WO-22** "a soul-only ghost is byte-stationary" — true only while idle;
  in combat, 340 m.
- **WO-25 Phase 2** — its conclusion stands, but `AI.GetAttentionTargetType` /
  `GetPeakThreatLevel` must not be cited for it. Both read 0 through genuine,
  damage-dealing combat here.
- **WO-25 Phase 4's blocker is moot.** The face/soul conflict it stopped on
  only exists if hostility has to come from swapping `SharedSoulGuid` to a
  hostile soul. It does not — engagement is already reactive on the roster
  soul.

## Open, ranked

1. **`InterpTick` vs a fighting ghost.** The real remaining engineering
   problem, and unmeasured. A ghost that fights moves hundreds of metres while
   the position stream overwrites it every 50 ms. Nothing here tested the two
   together.
2. **Does a ghost de-escalate?** The one clause of the WO's goal not
   established. Needs a fight that ends without the player leaving.
3. **What the aggro toggle and the native `SetParent` attach are still for**,
   now that engagement is automatic without them.
4. **Player-proximity gating of AI.** Observed (nothing happened at 340 m with
   the player airborne; engagement resumed ~25 s after landing) but distance
   and flycam changed together, so not attributed.

## Next session should

Read `docs/WO-26-findings.md` Phase 0 first, then decide item 1 above. Do not
re-derive Phase 1 — a second `Player` entity crashes the game, and the reason
is a single-slot `PlayerSoul` pointer that Lua cannot reach.
