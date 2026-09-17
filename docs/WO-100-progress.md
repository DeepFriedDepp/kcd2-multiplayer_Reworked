# WO-100 — progress

Session 2026-09-17. Findings: `docs/WO-100-findings.md`.

## What landed

| phase | state | commit |
|---|---|---|
| 0 — Mannequin tag surface | mapped + read-only probe built; **live check not run** | `WO-100: Phase 0 …` |
| 1 — attack acceptance | found, mapped, replayability answered read-only | `WO-100: Phase 1 …` |
| 2 — wire format | designed, not implemented | with phases 2/3/6 docs |
| 3 — locomotion replication | **not built** — Phase 0 gate | — |
| 4 — unconditional improvements | **landed**, all five items | `WO-100: Phase 4 …` |
| 5 — combat replication | **not run — STOP** (native write) | — |
| 6 — AI-less puppet class | found: `NPC_NAI`; investigation only | with phases 2/3/6 docs |

## Code

* `native/KCDMP/mannequin_read.{h,cpp}` — read-only tag-state probe, file-watched
  on `kcdmp-mannequin.txt`, five refusal gates.
* `native/KCDMP/combat_swing.h`, `combat_construct.cpp`, `pipe_server.cpp` —
  `SwingResult` reason codes on the pipe's Result frame (third byte, additive).
* `dotnet/KcdMp.Client/PipeResult.cs` — the agent-side mirror plus agent-only
  reasons (200+).
* `dotnet/KcdMp.Client/CombatPipe.cs` — bounded reply channel, sequence-matched,
  stale replies dropped/counted/logged. Fixes a real defect (§3.1).
* `dotnet/KcdMp.Client/SwingInbox.cs` — validity counters, bounded precondition
  wait, reason vocabulary, queue bound. `SwingInboxTests.cs`, 10 tests.
* `dotnet/KcdMp.Client/GameBridge.cs` — per-ghost body generation; inbound
  swings routed through the inbox.
* `native/ghidra_scripts/DumpWo100Vtbl.java` — vtable dump that self-identifies
  each slot from the `__FUNCTION__` strings inside the target function.

Builds: native DLL green, agent green, **111 tests green**. All synthetic.

## Not verified

**Nothing in this WO was verified against a running game.** No live session was
reachable. Every claim is marked (code-verified) or (synthetic) accordingly.

## Next session, in order

1. **Phase 0 live known-answer check** — `docs/WO-100-findings.md` §1.6.
   ~2 minutes in game, maintainer at the keyboard. This is the gate on Phase 3
   and it is the single highest-value thing left.
2. **Field-verify Phase 4** — the swing reason codes and the inbox counters both
   want a real two-player session. Watch `MP-SWING hop=queued … reason=` and
   `MP-SUMMARY section=swinginbox`.
3. Then the WO-101 candidates, §9.

## Deploy note

The native DLL is **maintainer-deploy** (WO-45). The agent and the DLL are now a
**matched set**: the DLL sends a three-byte Result frame and the agent reads the
third byte. Both directions degrade safely on their own (an old agent ignores
the byte; an old DLL makes the agent report `reason=unknown`), so a mismatch is
not fatal — but the reason codes are only useful with both halves.

Verify a deploy by `ModuleMemorySize` on the **loaded module**, never by the
file on disk (WO-99.5 §6.1 — AppData is sandbox-redirected).

**No wire change shipped.** Phase 2's `0x3B`/`0x3C` are reserved on paper only,
so this build does not require both machines to update for the protocol's sake.
