# WO-78 — progress

Session 2026-09-11. Root-cause the chain leak (ghost + puppet) from the first
real two-player session's logs; extend the puppet fix's protection to ghosts.
Findings and every number: `docs/WO-78-findings.md`.

Privacy: the field bundles' on-disk paths contain real usernames and are not
quoted anywhere; they are "host" and "joiner" throughout.

## Status

- **Phase 0** done: `main` at WO-77's head; WO-75 §2.5 and WO-77 docs read.
- **Phase 1** done: verdict **(A) shared root cause** — `tickAlive` cannot
  tell a suspended chain from a dead one, every `Start*` treated stale as
  dead, and menus/inventory/dialogs/cutscenes suspend all chains at once
  while the agent's re-arm (and the puppet path's per-packet entry) keep
  running. 33/33 host and 40/40 joiner non-initial restarts sit inside a
  ≥ 1 s emitter stall; a 60 s cutscene produced 24 restarts and 14–21
  concurrent interp chains on the joiner. Puppet render state is fully
  shared (no divergence found; the "still-visible puppet flicker" premise
  has no evidence in the logs).
- **Phase 2** done, Lua only: probe-confirmed restart gate shared by all six
  chains; ghost interp made time-based; ghost leak detector with gen tokens
  + native toast; both stale-chain exits default ON (`mp_npc_chainfix`,
  new `mp_ghost_chainfix`), puppet leak line also toasts.
- **Phase 3** synthetic done: ghost harness **35/35**, puppet harness
  **48/48** (39 + 9 new). Live: **not run** — no game was running.
- `VERSION` unchanged (0.20.2). No pak built or installed.

## Commits, in order (all on `main`, pushed to `origin main`)

See `git log --oneline` for hashes; the messages are prefixed `WO-78:`.

1. `WO-78: chain leak root cause -- probe-confirmed restart gate, time-based
   ghost interp, ghost leak detector, stale-chain exits default on`
2. `WO-78: synthetic ghost-interp harness + puppet gate scenario`
3. `WO-78: findings and progress docs, README/PROJECT-STATE rows`

## What was done, in order

1. Pulled; confirmed head. Read WO-75 §2.5, WO-77 findings.
2. Traced both re-arm paths in `kdcmp.lua` and `GameBridge.cs` /
   `LogTailGameTransport.cs` (all six `Start*`, both tick entries, the 2.5 s
   re-arm, the menu pump, the pause markers).
3. Extracted both field bundles to the scratchpad (never into the repo) and
   counted: restarts per chain, stops, leak lines, menu/inventory/skip/
   dialog/cutscene markers, DATA-clock gap across every restart, `TICK_ALIVE`
   interval timeline vs restarts and level loads, puppet-start spacing,
   animation-queue overflows, ExecuteString truncation errors.
4. Wrote the verdict, then the code:
   - `chainMayStart(key, flagField, stampField, restart)` next to `tickAlive`;
     all six `Start*` use it.
   - `KCD2MP_InterpTick(arg, gen)`: gen check + `GHOST CHAIN LEAK CONFIRMED` +
     toast + stale exit; gen-carrying reschedule; `KCD2MP_StartInterp` claims
     `interpGen` and logs `Interp tick started (20ms) gen=N`.
   - Per-ghost `dt`/`steps` block; DR by real time; time-scaled lerp, speed
     smoother, horse smoothers and velocity readback; same-frame duplicate
     fire (< 2 ms) does nothing.
   - `KCD2MP.npcChainFix = true`, `KCD2MP.ghostChainFix = true`,
     `KCD2MP_SetGhostChainFix`, `mp_ghost_chainfix` console command; the
     puppet leak line toasts too.
5. `tools/Test-NpcSmoothSynthetic.ps1` gained `-Scenario`/`-Title` (default
   behaviour unchanged; a PowerShell case-insensitivity bug — `$scenario`
   vs `$Scenario` — was hit and fixed in the same edit). New
   `tools/Test-GhostInterpSynthetic.{ps1,lua}`. Puppet scenario (j) added.
6. Ran both harnesses to green; wrote the docs.

## Not done, deliberately

- No agent change for dialog/cutscene pause detection (named follow-up).
- No fix for `GHOST_DEATH` flapping, the horse teleport, the ExecuteString
  batch truncation, or anything else on the brief's out-of-scope list.
- No `VERSION` bump, no release, no install.
- Did not port the ring-buffer renderer to ghosts: §2.5 prescribed
  time-based advance for this path, and that is what shipped.

## For the next field session

- Grep incoming `kcd.log`s for, in this order:
  - `GHOST CHAIN LEAK CONFIRMED` and `NPC-SYNC CHAIN LEAK CONFIRMED` —
    **should be absent**. Presence = the gate failed; read the adjacent lines.
  - `CHAIN <key> was suspended, not dead` — the gate refusing a false restart.
    Expect roughly one per menu/dialog/cutscene longer than a second.
  - `CHAIN <key> confirmed dead` — should sit next to a `Loading level`
    cluster every time. One that does not = the timer-ordering caveat in
    findings §4.3.
  - `Interp tick started` count should now be ≈ 1 + number of save loads.
  - `TICK_ALIVE` interval should hold 5.0–6.6 s for the whole session.
- A native toast reading "chain leak detected" mid-session is the same alarm
  for a human.
- `mp_ghost_chainfix` / `mp_npc_chainfix off` are the rollbacks; either with
  no argument prints the current state (`mp_ghost_chainfix` also prints the
  refusal counter).
- Rebuild the pak (`Build-And-Install-Mod.ps1`) before any of this is live.
