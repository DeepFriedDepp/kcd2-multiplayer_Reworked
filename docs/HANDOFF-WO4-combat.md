# WO-4 handoff — shared combat

State as of 2026-07-28. Branch: `main` (feat/native-plugin merged).

**Read `NATIVE-PLUGIN-findings.md` first** for capability evidence. This document
is the operational handover: what works, what does not, and the one open bug.

---

## One-line status

Shared combat replicates **in both directions**, verified end to end on
2026-07-28. Inbound (a peer's hit lands on my NPC) and outbound (my hit reaches
a peer) are both green. The pipe bug that blocked outbound is fixed; it is kept
below because the reasoning generalises.

---

## THE PIPE DEADLOCK — fixed, and worth understanding

**Symptom:** a frame written by the DLL to `\\.\pipe\kcdmp` never reached the
agent. `PIPE: LocalHit 9.00 guid=...` appeared in the DLL log with no
`[no agent attached, not sent]` suffix, so an agent was attached and
`send_frame` ran — but `CombatPipe.ReadLoopAsync`, which logs *every* frame,
printed nothing. Inbound `ApplyDamage`/`Result` worked perfectly the whole time.

**Cause:** the pipe was created **without `FILE_FLAG_OVERLAPPED`**, making
`g_pipe` a synchronous handle. Windows serialises every I/O request against a
synchronous file object. `serve()` parks in `ReadFile` waiting on the agent —
and there is no keepalive, so it parks indefinitely — and the game thread's
`WriteFile` in `send_local_hit` then **queues behind that parked read and never
issues**. The log line prints before the write, which is why detection looked
healthy while delivery was dead.

The old code had a `CRITICAL_SECTION` around writes and a comment naming the
exact race. A user-mode lock cannot do anything about kernel-level handle
serialisation; it only stops two writers interleaving frames, which is still
why it is there.

**Fix** (`pipe_server.cpp`): `FILE_FLAG_OVERLAPPED` on the pipe, an explicit
`OVERLAPPED` per operation in `read_all`/`write_all` (the `Op` RAII helper),
and overlapped `ConnectNamedPipe`. `send_frame` also emits head+body as one
write, and a failed write is now logged instead of silently discarded.

**Also fixed:** `ReadLoopAsync`'s `catch` filter covered only
`IOException`/`ObjectDisposedException`, so any other throw became an unobserved
task exception — the reader would stop with no output at all, which is
indistinguishable from the DLL never writing. It now catches and logs
everything, and logs on exit.

**Generalisable lessons:**

- A duplex pipe used from two threads at once **requires** overlapped I/O on
  both handles. This is not an optimisation.
- "The write returned" was never checked. `send_frame` discarded its result, so
  a blocked or failed write looked exactly like a delivered one. Same class of
  mistake as an unchecked `variant::is_valid`.
- A silent catch filter on a background task is a diagnostic dead end. It cost
  more time here than the deadlock did.

**Verify:** relay + agent + game with the DLL injected, then
`tools\Test-CombatOutbound.ps1` → `PASS - our hit crossed the relay to a peer`.

> Note: `Test-CombatOutbound.ps1` itself had a bug that masked the first green
> run — `[Guid]::new($pkt.Payload[1..16])` throws, because a PowerShell range
> index yields `Object[]` and selects the `string` overload. The peer *had*
> received the packet. Cast to `[byte[]]` first.

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
| Outbound end to end | local hit → sampler → pipe → agent → relay → peer got `0x13`, same guid, health 9 |
| Both directions on one connection | outbound and inbound tests pass back to back against a single attached agent |
| Peer damage is not echoed back | `ApplyDamage health=6.00 -> applied` produced **no** following `LocalHit`; `note_remote_damage` credits it correctly |

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
| `tools\Test-CombatOutbound.ps1` | outbound chain with a synthetic peer |
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
- **A PowerShell range index returns `Object[]`, not `byte[]`.**
  `[Guid]::new($bytes[1..16])` picks the `string` overload and throws. Cast
  explicitly. This made a passing outbound test look like a failing one.
- **A container read without `?depth=`** serialises the whole object graph — one
  returned 658 MB. Always `?depth=0` or `?depth=1`.
- **`Soul.Revive()`** undoes a death; `SetState(health, ...)` does not.
- **`Guid` needs no byte reordering in C#.** `System.Guid`'s layout matches the
  game's CryGUID in memory. Only the *text* form needs field reversal.

---

## Suggested next steps

1. **Run `KCDMP_launcher` against a real launch.** It is now wired to the
   injector and starts the agent, and the master-server chain is closed
   (`LAUNCHING.md`), but the launcher's own sequencing has been reviewed rather
   than observed. Its pieces are individually proven; the whole is not.
2. **Run the Python master server.** There is no Python on this machine, so
   `servers.py` and `models.py` were exercised only against a stub of the Flask
   contract. Note the schema change: an existing database needs a migration.
3. Consider whether the `kdcmp.lua` ghost should keep
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
