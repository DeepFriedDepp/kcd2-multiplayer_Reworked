# WO-75 progress — audit + jitter design

Read `docs/WO-75-audit-findings.md` (Part 1) and `docs/WO-75-jitter-design.md`
(Part 2) first. This file is the state of play and the runbook for the field
session the design depends on.

## Status

| Item | State |
|---|---|
| Repo state | `main` fast-forwarded from `018d2d4` to `8e836c5` (PR #1 merged remotely 2026-08-30) before any code was read. Clean tree; no `VERSION` change. |
| PR #3 | **open** on GitHub (split `kdcmp.lua`), opened 2026-08-30. Not read, not acted on. PR #2 closed unmerged. |
| Part 1 audit | done — seven subsystem verdicts, backlog dispositions for every recorded item |
| Part 2 design | done — receiver-side snapshot interpolation + time-based tick, cadence raise deferred, D3 re-analysed, send-side duplication re-graded |
| Code changes | **none** |
| Docs touched | only the three `WO-75-*.md` files; every stale doc found is listed, not edited |
| Live game / relay / injector | none run |

## What was done, in order

1. Mapped the tree and every `docs/*.md` (38k lines) with five parallel
   read-only sweeps, then read the jitter-critical docs and code directly.
2. Fast-forwarded `main` (3 commits behind) and read PR #1's diff, since a
   "current main" audit of a stale checkout would have been wrong on the relay
   (max-players, bounded queue), the agent (cadence conversion) and the native
   `run_sync` path.
3. Mined the committed field logs (`docs/WO-38/40/58-test-logs`) for numbers
   no prior doc had extracted — in-process `ExecuteString` round trip
   (~18 ms p50, n=56), emitter output rate (41–45 lines/s), single-chain
   interp heartbeat cadence (5.3–6.6 s / 250 ticks), zero emit-side
   duplicates on the pre-WO-60 path (2,231 lines), zero puppet activity and
   zero menu opens in those bundles.
4. Traced the puppet stream hop by hop in code and found the two premises the
   inherited plan rested on that do not hold (delivery RTT; send-side
   "same mechanism"), and the one it did not have (D3 is general, and a
   time-based tick fixes it structurally).
5. Wrote the two deliverables, checked them for private strings, committed.

## Runbook — the pending field session

Everything below uses lines that already exist in shipped builds. Nothing
needs a new deploy. Capture **both machines, whole session**, via the
launcher's COLLECT LOGS (the standard bundle carries `kcd.log`, `agent.log*`).

1. **Raw first.** Do not flip any smoothing toggle until the WO-60 footage
   of a claimed NPC under two-player pressure exists.
2. **Packet cadence**: `grep "NPC-SYNC packet cadence" kcd.log` on the
   receiving machine — the first real inbound arrival numbers ever.
3. **D3, puppet chain**: `grep -c "CHAIN LEAK CONFIRMED" kcd.log`. If >0, the
   leak is real; `mp_npc_chainfix on` is the live A/B.
4. **D3, ghost chain** (new recipe, no new code) — timestamp each `TICK_ALIVE`
   by the `os.clock` field of the nearest `[KCD2-MP-DATA]` line and print the
   intervals; 250 ticks should take ~5.3–6.6 s for one chain:

   ```bash
   awk '/KCD2-MP-DATA\] v[12] / { for(i=1;i<=NF;i++) if($i ~ /^v[12]$/){ clk=$(i+2); break } }
        /TICK_ALIVE/ { if (clk != "" && prev != "") printf "%.2f\n", clk-prev; if (clk != "") prev=clk }' kcd.log
   ```

   Correlate any drop toward ~2.6 s or ~1.3 s with `[menu] local menu open`
   timestamps in `agent.log` and with `grep -c "Interp tick started" kcd.log`.
5. **D2**: `grep "NPC-FIGHT" kcd.log` (5 cm/tick threshold since WO-69). Run
   `mp_npc_fight` once mid-session for the attractor clusters.
6. **Send-side duplication**: keep the raw `[KCD2-MP-EVT] ... npc_claim` lines;
   check `seq` monotonicity and byte-identical consecutive pairs per NPC; on
   the relay, read `GET api/information/npc-validation` — a non-zero
   `staleOwner` count during a two-player session with no rival claimant
   points at a second sender.
7. **WO-60 claim behaviour**: `NPC-SYNC tracking/untracking` churn per NPC;
   whether the fight's NPC ever changes hands mid-fight.
8. Cheap extras while there: the save-load rebuild spawn path for the gender
   fix (`spawn verify` lines after a load); the launcher Add Server → Launch
   flow with a hostname; a puppet watched after its stream goes silent (does
   the engine re-anchor it within 3 s or not — WO-32 vs WO-39).

## Corrections this session makes to earlier records

- The `ExecuteString` channel costs ~18 ms in-process (observed), not the
  60–130 ms WO-30 measured through PowerShell and WO-38/63 carried forward.
  WO-1 had measured ~13–42 ms in-process; the later docs picked the wrong one
  of the two figures the project already held.
- WO-69's send-side "same mechanism, same fix shape" is unsupported by the
  emitter's `moved` gate (code-verified); the observed shape's cause is unknown.
- The duplicate-agent launcher guard is WO-27's, not WO-58's (code comments).
- WO-69-progress's relay "mismatched assembly" diagnosis was already
  retracted by WO-74; WO-69-progress itself is unamended and the memory note
  still leads with the retracted version.
- `kdcmp.lua` is 7,867 lines, not ~2,400.

## Not done, deliberately

- No edits to the stale docs Part 1 §6 lists. Scoping those amendments is the
  maintainer's; the list is the deliverable.
- No history rewrite for the committed field logs containing public IPs
  (Part 1 §6). Outward-facing and destructive; surfaced only.
- No reading of PR #3.
- No verification run of anything that needs a game, relay or injector.
- No `Test-*` fixes, though six stale assertions are named (Part 1 §5).

## Traps hit or re-confirmed

- **Local `main` can be behind `origin`** when PRs merge remotely; read code
  only after `git fetch` + compare. This session would otherwise have audited
  a relay without max-players and an agent with tick-count cadences.
- `gh` is not installed here; the GitHub REST API via `curl` answers PR state.
- Committed `kcd.log` files carry **no timestamps**; the `[KCD2-MP-DATA]`
  line's `os.clock` field is the only wall clock in them, and it works as one.
- The agent's `[pos]` cadence is change-gated at 5 cm and cannot be read as a
  channel cadence at walking speed.
- Sub-agent summaries are useful for breadth and must not be trusted for a
  verdict: two of their numeric claims (flush cadence, a WO attribution) were
  wrong on re-read and are corrected in Part 1.
