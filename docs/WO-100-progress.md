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

## End gate — build: HELD, by maintainer decision

Asked rather than assumed, per the WO's own rule that `VERSION` is the
maintainer's to name. **No build was cut and `VERSION` stays `0.22.8`.**

The reasoning, recorded so a later session does not re-open it: nothing this WO
landed has been verified against a running game. Phase 4's code is real and
tested, but synthetic-only, and Phase 0's known-answer check — the gate on
everything downstream — has not run. A build follows the live check rather than
preceding it.

Consequences: the README badge is untouched, no release notes were written, and
no installer exists for this work. The native DLL **is** built locally
(`native/build/KCDMP/KCDMP.dll`) and can be deployed on its own for the Phase 0
probe without an installer, which is the only thing the live check needs.

---

## Live session addendum — 2026-09-17 16:38–16:46

A solo live session ran after the phases above were written. Full account in
`docs/WO-100-findings.md` §10. Summary of what changed:

* **Phase 0 is REACHABLE, live-verified.** The known-answer check passed on
  every step; no refusals; `unknownTags=0` throughout.
* **Phase 1 is live-verified**: 20/20 model properties read back their own
  registered name, and an accepted-input event was captured mid-attack.
* **Phase 3's gate is passed.** The tags are continuous state, not transient —
  the 300 ms "flicker" was the sampling. Phase 3 is unblocked on evidence.
* **Phase 6 is live-confirmed**: `NPC_NAI` spawns and has its own Mannequin
  action controller sharing the player's tag definition object.
* **A real defect was caught by the live data**: three model properties are
  one-byte bools and one is a float; reading them as int32 printed plausible
  nonsense. Widths are now part of the property table.

**The DLL deploy step is obsolete for solo native probes.** `KCDMP.dll` was
injected straight from the build directory with
`KCDMP_LauncherInjector.exe --pid <pid> --dll <absolute path>`, verified by
`ModuleMemorySize == SizeOfImage`. No copy into AppData, so the WO-74 redirect
never applied, and the DLL's own log landed inside the repo where the coding
shell can read it directly.

### Known state of the tree after the session

The `PropType` width fix is **written and compiles**, but the final link was
refused because the previous DLL was still loaded in the running game
(`LNK1104: cannot open file KCDMP\KCDMP.dll`). Re-run the native build once the
game is closed:

```
cmake --build native/build --target KCDMP
```

Nothing else is outstanding.

### Still unverified

Everything in **Phase 4** — swing reason codes, inbox counters, the
body-generation rule. Those need two machines. Phase 5 remains a STOP.
