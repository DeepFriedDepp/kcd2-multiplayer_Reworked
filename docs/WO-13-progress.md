# WO-13 progress — ghost-freeze fix and in-menu indicator

2026-07-31. Branch: `main`. Read `docs/WO-13-findings.md` first — this is the
build log for what it authorised.

---

## Status

All three of the WO's asks are done and verified live, plus two bugs found
along the way that were not in the WO (one of them larger than the WO's own
#2 — see the findings doc).

| WO item | Status |
|---|---|
| 1. Confirm B never slows because A paused | **Done.** Retired the response entirely; zero executable references to `t_scale` remain, and a live peer-pause cycle left `t_scale = 1`. |
| 2. Fix the own-menu ghost freeze | **Done.** Reproduced first, then fixed; 6.09 m / 7.19 m of measured ghost movement during inventory / pause menu. |
| 3. In-menu indicator on the ghost | **Done.** `[in menu]` nameplate tag, observed rendering live by the user. |

---

## Decisions worth flagging

**The WO's Phase 0 premise was wrong and the correction changed the work.**
The broadcast slowdown was not "only ever a proposal" — it was fully built and
tested, uncommitted, across 9 files. Retiring it meant deleting working code
and unwinding a protocol version bump, so it went back to the user as a choice
rather than being decided here. Chosen: **kill the response, keep the signal**,
which also meant Phase 2 needed no new wire byte — `0x1C`/`0x1D` were
repurposed instead of allocating `0x1E`.

**The WO's Phase 1.2 mechanism was not used.** It called for moving ghost
updates onto the native tick, justified by RTTR writes being "proven
extensively". That conflates soul-property writes (proven) with entity
transform writes (not proven — the `ent` module reflects three properties and
no methods). The agent-pump approach used instead rests only on WO-12 §0.4,
which is proven, and moves *more* of the tick than a native position write
would have. Flagged before building, not silently substituted.

**1.1 was checked before reaching for the bigger fix, as instructed** — and
found a documented-looking one-line fix (`bUpdateDuringPause`) that turned out
to be inert in this build, plus two entity-scheduling APIs that never fire at
all. All three are recorded in the findings doc as clean negatives so nobody
re-walks them.

---

## Files touched

| File | Change |
|---|---|
| `kdcmp/Data/Scripts/Startup/kdcmp.lua` | `"ext"` sentinel on `InterpTick`; `KCD2MP_InterpPump`; `KCD2MP_ApplyHorseTransforms` split out of `LabelTick`; `ghostInMenu` + `KCD2MP_SetGhostMenuState`; `tickAlive` liveness on all three timer loops |
| `dotnet/KcdMp.Client/GameBridge.cs` | pump start/stop on the local menu signal; `ApplyPeerPauseAsync` rewritten to tag instead of slow; `_pausedPeers` removed; periodic `StartInterp` re-arm; transport-selection retry |
| `dotnet/KcdMp.Client/IGameTransport.cs`, `HttpGameTransport.cs`, `LogTailGameTransport.cs` | `SetTimeScaleAsync` → `ExecuteNowAsync`; `ResetEmitterStart` |
| `dotnet/KcdMp.Protocol/Protocol.cs` | `PausedPeerTimeScale` deleted; 0x1C/0x1D docs rewritten as a presence signal |
| `docs/WO-11-findings.md` | dated superseded banner on the Phase 1 recommendation, original reasoning preserved |
| `tools/Bot-WalkingGhost.ps1` | **new** — walking synthetic peer, with `-MenuAtSec` to simulate a peer opening a menu |
| `tools/Test-Pause.ps1` | docstring corrected (it still described the retired t_scale response) |
| `docs/WO-13-findings.md`, `docs/WO-13-progress.md` | **new** |

`native/` untouched. `SessionManager.cs` untouched — presence-layer work, not
a paired interaction.

`kdcmp/Data/kdcmp.pak` is rebuilt and installed into the Modding Tools
instance, so the running game has the new Lua.

---

## Verification

```
Test-Combat.ps1   : 14 passed, 0 failed
Test-Sessions.ps1 : 22 passed, 0 failed
Test-Dice.ps1     : 10 passed, 0 failed
Test-Pause.ps1    : 10 passed, 0 failed
```

Isolated relay on 7779 / HTTP 5299; the user's own relay on 7778 was never
touched or restarted. `Test-Pipe.ps1` deliberately skipped — it needs the
native DLL injected and deals real damage to a live NPC, and this WO changed
nothing native.

Live, human-witnessed, against the real game with a real agent
(`kcd-log-tail` transport) and a synthetic walking peer:

- freeze reproduced with the pump disabled (identical world position across a
  ~10 s inventory; fast catch-up snap on exit)
- fixed with the pump enabled: **6.09 m** of ghost movement during an
  inventory, **7.19 m** during a pause menu, every sample a distinct position
- pause menu confirmed by eye (it is transparent); inventory confirmed by
  instrument only (it is opaque)
- `[in menu]` tag observed appearing and clearing on the rendered nameplate
- pump rate measured live at **35–86 Hz**

---

## What is NOT verified

- **Two real human players.** One machine, one copy of the game — the same
  constraint as every WO on this project. Verified with a real agent plus a
  synthetic peer.
- **Nameplates during your own menu.** Deliberately still hidden (see the
  findings doc's scope section). Unchanged from before, but it means a ghost
  that walks past you while your inventory is open has no label on it.
- **Mounted ghosts during a menu.** `KCD2MP_ApplyHorseTransforms` is pumped
  and the code path is the same one `LabelTick` uses, but no test this session
  had a peer on horseback. The split exists precisely so this works; it is
  reasoned, not observed.
- **The transport-retry fix firing.** The retry was added after observing the
  failure once, but the log-tail transport selected first-try on every attempt
  afterwards, so the retry path itself has not executed in anger.
- **Whether the save-load liveness fix survives a real save load.** The fix
  was written after the freeze was diagnosed; the game was restarted with a
  fresh save immediately afterwards, so the specific "load a save mid-session
  and watch ghosts recover" sequence was not re-run end to end.

---

## Leftovers

- A test relay may still be running on port 7779 (`KcdMpServer`, HTTP 5299).
  Harmless, but it is not the user's own instance and can be killed.
- `KCD2MP_InterpPump_SAVED` is still set as a global in the running game from
  the Pass A/B toggle. Inert, and gone on the next game restart.
