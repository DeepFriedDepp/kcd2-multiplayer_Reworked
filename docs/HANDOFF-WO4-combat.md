# WO-4 handoff — shared combat

State as of 2026-07-28. Branch: `main` (feat/native-plugin merged).

**Read `NATIVE-PLUGIN-findings.md` first** for capability evidence. This document
is the operational handover: what works, what does not, and the one open bug.

---

## One-line status

Shared combat is **~85% done**. Inbound (a peer's hit lands on my NPC) is proven
end to end. Outbound (my hit reaches a peer) is proven up to the pipe boundary
and **stuck there** — one focused bug, described in full below.

---

## THE OPEN BUG — start here

**A frame written by the DLL to `\\.\pipe\kcdmp` is never read by the agent.**

Evidence, all reproducible:

- DLL log shows `PIPE: LocalHit 9.00 guid=20DD03E3-...` **with no
  `[no agent attached, not sent]` suffix**. That suffix is printed when
  `g_connected` is false, so an agent *was* attached and `send_frame` ran.
- The agent's `CombatPipe.ReadLoopAsync` logs **every** frame it receives
  (`[combat] pipe frame 0x..`). It printed nothing at all.
- The same pipe carries `ApplyDamage`/`Result` in the other direction perfectly
  — inbound is fully working — so the pipe itself is live and both processes
  agree on framing.
- A listening peer therefore times out waiting for `Damage (0x13)`.

So: DLL writes, agent does not read. Both ends verified independently.

**Untested hypotheses, in the order worth trying:**

1. `ReadLoopAsync` throws on its first `ReadAsync` and dies silently. The
   `catch` filter only covers `IOException`/`ObjectDisposedException`; anything
   else becomes an unobserved task exception with no output. **Widen the catch
   and log it** — cheapest first move.
2. `PipeOptions.Asynchronous` on the C# client against a **synchronous** server
   handle (the DLL creates the pipe without `FILE_FLAG_OVERLAPPED`). Try
   `PipeOptions.None`.
3. `Task.Run(ReadLoopAsync)` is started while `_gate` is held in
   `EnsureConnectedAsync`. It should not matter — `ReadLoopAsync` never takes
   `_gate` — but it is worth ruling out.
4. Server-side buffering: `send_frame` does two `WriteFile` calls (head, then
   body). Byte-mode pipes should not care, but combining them into one write is
   trivial and removes the question.

**Reproduce:** relay + agent + game with DLL injected, then
`tools\Test-CombatOutbound.ps1`. It damages an NPC by a route the DLL did not
cause and expects a peer to receive `0x13`. Current failure is the peer's read
timing out, which is the correct symptom for this state.

---

## What is proven

### Capability (all verified in-process, effects observed)

| Thing | Evidence |
|---|---|
| Engine state is mutable from native code | health writes, damage, death |
| `CombatSoul::TakeDamage` via rttr | ttkc_man_32 100 → 95 → 94 |
| Death | health → 0, `IsDead=true` |
| `SharedSoulGuid` is the cross-client key | authored in shipped level XML, byte-identical everywhere |
| Soul lookup by GUID from native | `find_soul_by_guid` walks `SoulsByGuid` |
| Main-thread marshalling | IAT hook on `C_ModulesManager::Update`, 26–79 Hz |
| Inbound end to end | synthetic peer → relay → agent → pipe → DLL → NPC health dropped |
| Outbound **detection** | `PIPE: LocalHit 8.00` with the exact delta and right soul |

### Not achievable (closed, do not re-derive)

- **Aggro / stimulus injection.** No reachable surface. `xgen` reflected surface
  is two read-only properties; `XBehaviorModule` is empty; XGenAIModule's 1,784
  exports are behaviour-tree enum glue; `SkirmishManager::DebugTriggerEvent`
  does nothing observable outside a running skirmish.
- **Attacker attribution.** `TakeDamage`'s `Attacker` parameter does **not**
  create combat history — verified with `HasCombatHistoryWithSoul(player, 30s)`
  returning false after a hit. So replicated damage hurts NPCs but does not make
  them fight back.
- **Faction manipulation.** `SetParent` corrupted the faction tree and crashed
  the game (see below). Disabled in code.

---

## Architecture as built

```
game process                          agent (KcdMpClient)         relay
┌──────────────────────────┐          ┌──────────────────┐        ┌────────┐
│ KCDMP.dll                │          │ CombatPipe       │        │        │
│  IAT hook on ModulesMgr  │          │  reader loop     │        │ stateless
│   └ main-thread queue    │◄─pipe───►│  OnLocalHit      │◄─TCP──►│ ordered
│  rttr ABI (by name)      │  kcdmp   │ GameBridge       │        │ broadcast
│  sampler (health deltas) │          │  0x13/0x15 → pipe│        │        │
└──────────────────────────┘          └──────────────────┘        └────────┘
```

**Wire protocol v3** (`Protocol.cs`, duplicated in both projects — change both):

```
C→S 0x12 Damage [guid:16][stamina:4f][health:4f][flags:1]   (25)
S→C 0x13 Damage [sourceGhostId:1] + above                    (26)
C→S 0x14 Death  [guid:16]                                    (16)
S→C 0x15 Death  [sourceGhostId:1][guid:16]                   (17)
```

**Pipe protocol** (`pipe_server.h`), same framing `[type:1][len:2 LE][payload]`:

```
agent→DLL  0x01 ApplyDamage  0x02 ApplyDeath  0x03 Ping
DLL→agent  0x81 Result [ok:1][seq:1]  0x83 Pong  0x90 LocalHit [guid:16][stam:4f][health:4f]
```

### Design decisions and why

- **Relay stays stateless.** It orders and forwards; authority is per-hit and
  belongs to the client whose player landed the blow.
- **Death is its own packet**, never inferred from health hitting zero. Two
  clients diverging on "who is alive" does not self-correct; a health value does.
  Receivers treat it as idempotent.
- **Damage is not echoed to the sender** even in relay `--echo` mode, unlike
  Ghost — the sender's game already applied it.
- **Outbound by sampling, not hooking.** `TakeDamage` is not exported. The rttr
  method wrapper was dissected far enough to prove a route exists (18-slot
  vtable in RPGModule, invoke overloads around `+0x7BC0xx`), but reaching the
  real target means disassembling for a call address — a hardcoded offset that
  breaks silently on the next patch. Sampling costs a few reflected reads per
  tick and cannot break that way.
- **Sampler details:** souls within 60 m re-scanned every 3 s, health sampled
  every 60 ms. Damage applied on a peer's behalf is credited and subtracted, or
  the two clients echo the same hit forever.
- **Accepted sampler consequences:** a hit is reported up to ~60 ms late;
  several fast hits inside one interval merge; damage from **any** source is
  reported including NPC-vs-NPC, which keeps the shared world consistent.

---

## How to run everything

```powershell
# .NET SDK is user-scope and not on PATH
$env:DOTNET_ROOT = "$env:USERPROFILE\.dotnet-sdk8"; $env:PATH = "$env:DOTNET_ROOT;$env:PATH"

# native (MSVC is installed but not on PATH; the script finds it)
powershell -ExecutionPolicy Bypass -File native\Build-Native.ps1

dotnet build KCD2-MP.sln
dotnet run --project dotnet\KcdMp.Server -- --port 7778
dotnet run --project dotnet\KcdMp.Client -- --host localhost --no-voice

# inject (game must be launched via the KCD2 Modding Tools Steam entry)
native\build\KCDMP_LauncherInjector\KCDMP_LauncherInjector.exe --pid <pid> --dll <path>\KCDMP.dll
```

### Test scripts

| Script | Proves |
|---|---|
| `tools\Test-Combat.ps1` | relay forwarding, 14/14 green, no game needed |
| `tools\Test-Pipe.ps1` | pipe → DLL → NPC, no agent or relay needed |
| `tools\Test-CombatE2E.ps1` | full inbound chain with a synthetic peer |
| `tools\Test-CombatOutbound.ps1` | outbound chain — **currently fails, see the bug** |
| `tools\Probe-Reflection.ps1` | re-run after any game patch |

`tools\KcdApi.ps1` is the bounded REST client — dot-source it.

---

## Traps that cost time here

- **A stale injected DLL keeps the pipe** (`ERROR_PIPE_BUSY`) and its sampler
  keeps running. A rebuilt DLL must be tested against a **restarted game**, or
  you are silently testing the old one. This produced two false "it doesn't
  work" results.
- **A fault-free `invoke` is not a successful one.** rttr returns an *invalid
  variant* on argument mismatch — no exception. Always check
  `variant::is_valid`. This is `pcall` returning true, one layer down.
- **`TakeDamage`'s third parameter is `Attacker` (`I_Soul*`), not
  `SuppressHitReaction`.** Passing a bool there silently did nothing.
- **Never pass a borrowed reference to a by-value parameter that owns a
  resource** (`shared_ptr`, `CryStringT`, containers). The callee destroys it.
  Doing this to `SetParent` released a faction object and crashed the game.
  Value types (floats, enums, raw pointers) are fine.
- **Immediate read-back is not verification** for anything the game re-derives.
  The faction write read back correctly and was reverted minutes later.
- **PowerShell variables are case-insensitive.** `$ack` shadows `$ACK`,
  `$pong` shadows `$PONG`. Cost two false failures.
- **A container read without `?depth=`** serialises the whole object graph — one
  returned 658 MB. Always `?depth=0` or `?depth=1`.
- **`Soul.Revive()`** undoes a death; `SetState(health, ...)` does not.
- **`Guid` needs no byte reordering in C#.** `System.Guid`'s layout matches the
  game's CryGUID in memory. Only the *text* form needs field reversal.

---

## Suggested next steps

1. **Fix the pipe read bug** (top of this document). Everything else waits on it.
2. Then run `Test-CombatOutbound.ps1` for the first green two-way result.
3. Then: `KCDMP_launcher` still needs wiring to the now-real injector, and the
   two master-server gaps in `LAUNCHING.md` remain open.
4. Consider whether the `kdcmp.lua` ghost should keep
   `esModularBehaviorTree=""`. A ghost with a behaviour tree genuinely perceives
   (it appears in `PerceptionHistory`), but the empty tree exists deliberately
   so the scheduler does not fight `ForceMount` during horse riding. Real
   trade-off, not an oversight.

## Environment notes

- One machine, one copy of the game, no second player. Synthetic TCP peers and
  the pipe test cover everything except a real second client.
- Game must run via **KCD2 Modding Tools** (`D:\SteamLibrary\steamapps\common\KCD2Mod`),
  not the base game: the reflection REST API and the exported module DLLs exist
  only there. Retail is monolithic and exports nothing.
- The user's GPU threw two driver TDRs during this work, unrelated to the mod.
