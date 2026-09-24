# WO-118 — progress: what ran, what did not, what it cost

Session 2026-09-23, solo. Findings: `docs/WO-118-findings.md`. Field page:
`docs/WO-118-runbook.md`. Harness: `tools/wo118/README.md`.
**Nothing ran two-player.** Paths: `<install>` (Modding Tools install),
`<saves>`, `<scratch>` (the session scratchpad, not committed).

## 1. Phases

| phase | status | note |
|---|---|---|
| 0 — addresses by anchor, fail closed | **done** | RTTI vftables + required instruction bytes per slot; armed on all 4 launches; DISARMED path code-verified (findings §3.1) |
| 1 — agent→DLL samples, ring, sender clock, WUID check, Z on the segment | **done** | 906 binds, 0 WUID mismatches; two stale-state traps fixed (§3.2); 1 ms stamps (§3.13) |
| 2 — per-frame write; Lua keeps start/release/pause/gait/draw/swings/death | **done** | render = written 0.000 mm; slope and fight: no sinking (§3.3) |
| 2b — the peer's ghost | **done** | traced first (50.1 % frozen), moved to the native write (0 %); pace wobble remains (§3.4) |
| 3 — detach, skipped in dialogue/cutscene, MP-DETACH | **done** | 16-NPC table incl. bartender, field worker, guard spot, sellers, carpenter, sawyer (scale runs); 1 m / 3 m / 30 m walk-away → 0.0000 (§3.5) |
| 4 — MP-NPCPULL; Lua detectors labelled legacy | **done** | lag frames separated (9aefa8f); `path=legacy` (a1c5b5f) (§3.6) |
| 5 — `mp_npc_trace` CSV gate | **done** | green three times this WO; `tools/wo118/phase5_gate.py` (§3.7); shipped-build run §5 below |
| 6 — cost at 40 and 80; network noise | **done** | noise found the sender-clock headroom defect, fixed (92023cc, §3.8); cost §3.9; 80 needed a 200 ms emit (§3.10) |
| 7 — presets, WO118-BUILD, runbook, predictions | **done** | toggles in both presets (4781c86, cfea218); runbook; predictions in findings §1 |
| end gate | see §5 | the version is the maintainer's call |

## 2. Live sessions

Steam running. Every launch: `<install>\Bin\Win64ReleaseSteamLTO_DLL\KingdomCome.exe`
started directly, `wh_sys_LoadGame 1 <save>` once the API answered, world-time
ratio 1, the WO-111 `death_protection` guard added (non-persistent), KCDMP.dll
injected from `<scratch>` with `KCDMP_LauncherInjector --pid --dll`, the relay
on 7778, the agent connected as the joiner behind a placeholder peer (relay
rule 2). `kcd.log`, `logbackups\kcd.log` and the native mirror log were copied
to `<scratch>` before every relaunch.

| session | DLL | what ran |
|---|---|---|
| 1 | writer + agent feed + Lua bind (d1164e4–4781c86) | `quicksave027` loaded, **fresh throwaway `quicksave033` written at once** (`wh_sys_TestSaveGame`); smoke, walker/seat traces, detach A/B, the 16-NPC activity runs, the legacy baselines, the stale-authority bug |
| 2 | + lag frames, restarts, 1 ms stamps, ghost (9aefa8f–6258502) | ghost traced legacy then native; the first noise runs (contaminated, §4) |
| 3 | + cost line, a lateness-only allowance | noise batch (found the headroom defect), scale 40/64, slope, fight, ghost before |
| 4 | + the need tracker, ring 16 (92023cc) | noise batch (clean), ghost after, scale 40/80 (100 and 200 ms emit, minimized), Phase 5 gate ×2 |

`quicksave024/026/028/031/032` untouched. Nothing was saved after
`quicksave033` (each relaunch killed the process). Daytime throughout
(09:30–10:00 in-game at ratio 1).

## 3. Commits

`d1164e4` writer · `af18b09` agent feed · `4781c86` Lua bind + fallback ·
`cfea218` detach · `eb0436c` CombatRole fix · `9aefa8f` lag frames / restarts /
parented · `bd26225` 1 ms stamps · `6258502` ghost · `4d92c14` cost line ·
`92023cc` jitter allowance · `a1c5b5f` `path=legacy` · `f299310` pak ·
`704845a` `tools/wo118` · docs. Nothing reverted.

## 4. Gaps, side effects, stated plainly

* **Methodology error, session 2:** noise runs spaced less than 15 s / 60 s apart
  inherited the previous run's stream sequence and sender-clock minimum (the
  two traps fixed in 9aefa8f and the 5 s clock reset). Those runs were
  discarded and redone on sessions 3–4.
* **The background frame limiter** (findings §3.11) put several session-3/4 runs
  at 26 fps before it was understood (P0–P3 of the lateness-only batch, the
  ghost-after batch, the first 80-puppet run). They are reported with their fps
  and not compared with 75 fps runs.
* **REST under load:** with dozens of puppets, harness commands were refused
  (503) or silently lost; the scale schedule moved into Lua timers.
* **Henry was teleported** 83 m for the slope run and back (throwaway, not
  saved). Scale runs puppeted most of the village and released it; NPCs walked
  back to their activities.
* **Not done:** two-player; 80 walkers at 10 Hz (ingress, §3.10); ghost sender
  time (protocol); the dice minigame with detach; a traced reload with puppets
  bound.

## 5. End gate

| step | status |
|---|---|
| push first | done (every commit pushed to `origin main`) |
| build from a fresh clone | see below |
| version named by the maintainer; rollback tagged before the bump | **waiting for the maintainer** |
| all gates green | see below |
| privacy sweep UTF-8 + UTF-16LE | see below |
| pak content check | see below |
| Phase 5 gate against the shipped build | see below |
| release notes | drafted; filename takes the version |
| no GitHub Release | none made |
