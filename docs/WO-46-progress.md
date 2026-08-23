# WO-46 progress

Worked 2026-08-23 (Fable 5), immediately after WO-45 in the same live session
chain. `docs/WO-46-findings.md` is the deliverable; this is the session log.

## What was done, in order

1. Scoped from WO-45 §6's handoff: make the WO-45 rung-2 construction the
   production render path for a peer's swing in the WO-39 combat-visibility
   stream. Read the existing seams first: pipe_server (typed duplex commands,
   game-thread marshalling), CombatPipe (agent side), GameBridge's
   CombatEventDown → `KCD2MP_GhostCombat` route, the Lua ghost registry and
   its `[KCD2-MP-EVT]` emit channel.
2. Implemented the four-layer change (native `ghost_swing` + pipe 0x06 +
   Lua `ghostid` emit / native-swing hold + agent cache-and-route). Committed
   honestly as UNTESTED (1aa140b) before any live work — same-day power-outage
   precedent.
3. Deploy cycle: pak install from this shell (D:, unsandboxed); DLL + agent
   via the user's shell (AppData, sandbox — WO-45's rule held). Verified the
   loaded build by ModuleMemorySize (0x51000).
4. **Relay crash detour:** the flat client-publish copy broke the installed
   relay (shared KcdMp.Protocol.dll now wants System.Text.Json 10.0.0.0 —
   event-log confirmed). Republished the server; user redeployed; second
   detour: the harness's default relay port 5273 is actually the relay's
   Kestrel HTTP endpoint — the TCP socket is `--port` = 7778. Both recorded
   in findings §2.
5. Found and fixed a real routing flaw before it shipped: the swing gate
   required `_combat.IsConnected`, but the agent's one startup connect can
   race injection (observed live: no agent-connected line) — swings would
   have stayed on the fallback forever. Now GhostSwingAsync connects on
   demand and the Lua cue is the on-failure fallback.
6. **Live E2E (Test-CombatVizE2E.ps1 on -RelayPort 7778):** ghost spawned
   male with the longsword; `ghostid` emitted and cached; all three peer
   swing events arrived as native pipe commands (three SWING log lines,
   fragment 195, at the scheduled times); **human confirmed three real
   swings on the ghost.** Draw and block rendered on the untouched paths.
7. Chased the one visual gap — no sheathe seen — to the harness ghost
   despawning at peer disconnect. Targeted retest on a fresh male ghost
   (draw → native swing → HolsterWeapon): weapon returns to the sheath after
   a native swing (instant, no animation — pre-existing behaviour).
   Human-confirmed. Not a regression.
8. Cleanup (trigger file cleared, test ghost removed), suites green (59/59),
   findings + progress written, committed and pushed.

## Gate

**Achieved and live-verified: a peer's swing renders as a real, complete
combat swing on their ghost, over the real wire.** WO-39's honest ceiling
("cue, not a true swing") is lifted.

## Not done, on purpose

- No VERSION change (docs/VERSIONING.md — the user owns version strings; the
  deployed stack on this machine is ahead of any cut release).
- Blocks stay on the Lua cue path; per-weapon-class fragment rows and
  swing-zone variety are follow-ups (findings §4).
- No paired/sync-attack work (WO-45 §3's Phase 3 remains open).

## Handoff

Findings §4. Also: the launcher misses a relay that dies just after its
500 ms startup check — twice this session it sat silently dead; small UX fix,
its own change.
