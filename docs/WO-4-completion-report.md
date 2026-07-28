# WO-4 completion report

Session of 2026-07-28. Branch `main`, pushed to `origin` as `c6b664b..54af330`.

WO-4 (shared combat) is **closed**. This document records what was done, what
was proven and how, and — separately and deliberately — what was *not* verified.
Read `HANDOFF-WO4-combat.md` for the operational picture; this is the change
record behind it.

Two commits:

| Commit | Subject |
|---|---|
| `b8ffaae` | Fix the pipe deadlock: outbound combat now replicates end to end |
| `54af330` | Wire the launcher to the real injector and close the master server chain |

---

## Part 1 — the pipe deadlock (`b8ffaae`)

### The bug as inherited

A frame the injected DLL wrote to `\\.\pipe\kcdmp` never reached the agent.
`PIPE: LocalHit 9.00 guid=...` appeared in the DLL log without the
`[no agent attached, not sent]` suffix, so an agent was attached and
`send_frame` ran — but `CombatPipe.ReadLoopAsync`, which logs *every* frame,
printed nothing. Inbound `ApplyDamage`/`Result` worked perfectly throughout.

Four hypotheses were on file. **None of them was the cause.**

### Root cause

`CreateNamedPipeA` was called without `FILE_FLAG_OVERLAPPED`, so `g_pipe` was a
**synchronous handle**. Windows serialises every I/O request against a
synchronous file object.

1. `serve()` parks in `ReadFile` waiting for the agent to send a command.
2. Nothing prompts the agent to send one — `PingAsync` has **no callers**, so
   there is no keepalive. The park is indefinite.
3. The game thread reaches `WriteFile` in `send_local_hit`; it queues behind the
   parked read and never issues.

The log line at `send_local_hit` prints *before* the write, which is exactly why
detection looked healthy while delivery was dead.

The pre-existing `CRITICAL_SECTION` named this race in its own comment. A
user-mode lock cannot affect kernel-level handle serialisation; it only stops
two writers interleaving frames, which is still why it is there.

### The fix

`native/KCDMP/pipe_server.cpp`:

- `FILE_FLAG_OVERLAPPED` on the pipe.
- An `Op` RAII helper (one `OVERLAPPED` + event per operation) used by
  `read_all` and `write_all`, so a read and a write can be in flight at once.
- Overlapped `ConnectNamedPipe`, waiting on the event rather than in the call.
- `send_frame` emits head and body as **one** write and now **returns whether it
  succeeded**. It previously discarded that, which is the reason a permanently
  blocked write was indistinguishable from a delivered one.
- `send_local_hit` logs `PIPE: LocalHit write failed: <err>` on failure.

`dotnet/KcdMp.Client/CombatPipe.cs`:

- `ReadLoopAsync`'s catch filter covered only `IOException` /
  `ObjectDisposedException`. Anything else became an unobserved task exception:
  the reader stopped with no output, indistinguishable from the DLL never
  writing. It now catches and logs everything, and logs on exit.

This was hypothesis 1 on the list. It was worth doing — a silent catch on a
background task is a diagnostic dead end — but it was **not** the bug.

### Evidence it works

Against a **freshly built DLL injected into a game that had none**:

```
DLL    PIPE: LocalHit 9.00 guid=20DD03E3-...        (no write-failure line)
agent  [combat] pipe frame 0x90 (24 bytes)          <- never appeared before
agent  [combat] sent hit 9.0 on 20dd03e3-8db2-4377-8427-99f25bcbffdd
peer   PEER RECEIVED Damage: from ghost 1, soul 20dd03e3-..., health 9
       PASS - our hit crossed the relay to a peer
```

| Test | Result |
|---|---|
| `tools\Test-CombatOutbound.ps1` | **PASS** — first ever green |
| `tools\Test-CombatE2E.ps1` (inbound) | **PASS** — no regression from the rewritten read path |
| `tools\Test-Combat.ps1` (relay) | **14/14** |

Both directions ran back to back over a **single attached agent**, which is the
concurrency the deadlock was blocking.

Bonus observation, newly checkable with a live agent: an inbound
`ApplyDamage health=6.00 -> applied` produced **no** following `LocalHit`, so
`note_remote_damage` credits peer damage correctly and the two clients do not
echo a hit forever.

### A test that was lying

`tools\Test-CombatOutbound.ps1` threw `"Guid should contain 32 digits with 4
dashes"` on the first green run — **after** the peer had already received the
packet. A PowerShell range index (`$pkt.Payload[1..16]`) yields `Object[]`, which
selects `[Guid]::new(string)`. Cast to `[byte[]]` first. Fixed.

### An invalid check of my own

I checked whether the running game's main thread was hung, expecting the
deadlock to freeze it. It was responsive — but that proved nothing: no `kcdmp`
pipe existed and the DLL log's last attach was a different pid, so **that game
had no DLL injected at all**. Discarded rather than treated as counter-evidence.

---

## Part 2 — launcher and master server (`54af330`)

### Launcher: `LaunchGame` now drives the real system

It was scaffolding for a DLL-injection design that did not exist when it was
written. Every assumption in it is now settled.

| Was | Now |
|---|---|
| Launched whatever `GamePath` pointed at | Refuses anything without `Framework.dll` + `CrySystem.dll` beside the exe |
| `+map <MapName>`, guarded by a level-directory check | Dropped — KCD2 loads a save; there is no level to boot into |
| Injected 3 s after `Process.Start` | Waits for `WHGame.dll` to load, up to `InjectDelaySeconds` (default 20) |
| **Never started the agent** | Starts `KcdMpClient.exe --host <ip> --port <port>` |
| Ignored the injector's exit code | Reports a failed injection instead of continuing |

The 3-second timer could never have worked: the DLL hooks `WHGame.dll`'s import
of `Framework.dll`'s `C_ModulesManager::Update`, and that module is not loaded
that early.

**The build discriminator was checked, not assumed.** My first heuristic —
"WHGame.dll sits next to the exe" — was **wrong**: retail ships it too. Measured:

| Build | DLLs beside exe | `Framework.dll` | `CrySystem.dll` |
|---|---|---|---|
| `KCD2Mod\Bin\Win64ReleaseSteamLTO_DLL` | 45 | yes | yes |
| `KingdomComeDeliverance2\Bin\Win64MasterMasterSteamPGO` | 6 | no | no |

Both name the executable `KingdomCome.exe`, so the filename cannot tell them
apart. `Framework.dll` and `CrySystem.dll` are exactly what the plugin needs
(IAT hook target, and the rttr ABI's exporter), so the check tests for the
requirement rather than for an install path. `Home.IsModdingToolsBuild` is
public so the settings modal can warn inline.

New settings: `AgentPath`, `InjectDelaySeconds`, `ServerInfoPort`.

### Master server: three breaks, not the two on record

1. **Wrong URL.** Launcher defaulted to `http://localhost:5000/api/servers`;
   Flask serves `/servers/servers_list`. *(documented)*
2. **Nothing registered a relay.** *(documented)*
3. **The DTO never matched.** `MasterServerEntry` bound `"ip"`, but
   `Server.to_dict()` emits `"ip_address"` and `"map_name"`. **Even with the URL
   fixed, every row would have arrived with a blank address.** The DTO's own
   comment admitted it was a guess. *(not previously recorded)*

`MasterRegistrationService` (new, `dotnet/KcdMp.Server/Features/ServerInformation/`)
is the missing half. It is **opt-in** — with no `MasterServer:Url` it does
nothing, because publishing a relay's address to a third party is the operator's
call, not a default. Registration doubles as the heartbeat and carries the token
the master hands back.

That forced two changes on the Python side:

- **`/register` is an upsert** keyed on `(ip_address, port)`. It inserted
  unconditionally, so every relay restart added another row for the same server.
- **`last_seen` is recorded** and `/servers_list` hides anything older than five
  minutes (`?all=1` bypasses). A crashed relay cannot deregister itself, so
  without this the browser only ever grows.

`ip_address` is now optional, falling back to `request.remote_addr`: a relay
behind NAT does not know the address peers reach it on, but the master can see
it. `AdvertisedIp` overrides for a relay behind a reverse proxy.

### Turned up while doing the above

- **`ServerInfo:Tags` was `["PvP", "PvE", "RP", "Feeling quite hungry"]`** —
  four tags where the master allows three, and one not in its fixed list
  (`PvP, PvE, RP, Hardcore, Friendly, Modded`). Either alone rejects the whole
  registration. Fixed in **both** `appsettings.json` and
  `appsettings.Development.json`; the latter overrides the former in the dev
  environment, so fixing only the base file changes nothing. A startup warning
  now names the problem instead of leaving a bare 400.
- **`GetDedicatedServerInfoAsync` returned random numbers** behind a
  `TODO: actual udp`, so the browser showed a plausible map name and player
  count for servers that were not running. It now reads the relay's existing
  `/api/information` and returns `null` when there is no answer, so the row is
  marked offline rather than invented.
- **`ValidateIpAddr` rejected every IPv6 address** (hand-rolled four-octet
  split). Since the master now falls back to `remote_addr`, a same-machine relay
  registers as `::1`; such rows reached the browser and were dropped as
  unreachable without ever being pinged. Now `IPAddress.TryParse`, and IPv6
  literals are bracketed when building the info URL. This also dropped the old
  "last octet cannot be 0" rule, which is not a real constraint.

---

## Files changed

**`b8ffaae`**

| File | Change |
|---|---|
| `native/KCDMP/pipe_server.cpp` | overlapped I/O; single-write frames; write result checked |
| `dotnet/KcdMp.Client/CombatPipe.cs` | reader catches and logs everything |
| `tools/Test-CombatOutbound.ps1` | `[byte[]]` cast for the GUID |
| `docs/HANDOFF-WO4-combat.md` | bug section rewritten as fixed; proven table extended |

**`54af330`**

| File | Change |
|---|---|
| `KCDMP_launcher/Pages/Home.razor.cs` | `LaunchGame` rewritten; `IsModdingToolsBuild`, `WaitForInjectableAsync`, `ResolveAgainstLauncher` |
| `KCDMP_launcher/Models/AppModels.cs` | DTO matches the Python; new settings |
| `KCDMP_launcher/Models/NetService.cs` | real `/api/information` read; IPv6-capable validation |
| `KCDMP_launcher/Components/Modals/SettingsModal.razor` | new fields; inline wrong-build warning |
| `dotnet/KcdMp.Server/Features/ServerInformation/MasterRegistrationService.cs` | **new** |
| `dotnet/KcdMp.Server/Program.cs` | registers the hosted service |
| `dotnet/KcdMp.Server/appsettings*.json` | valid tags; `MasterServer` section |
| `kcd2_master_server/app/models.py` | `last_seen`, unique `(ip_address, port)` |
| `kcd2_master_server/app/routes/servers.py` | upsert, staleness filter, input validation |
| `docs/LAUNCHING.md` | rewritten |

---

## Verified vs not verified

### Verified by observing an effect

- Outbound combat end to end: local hit → sampler → pipe → agent → relay → peer
  received `0x13` with the matching GUID and health.
- Inbound combat end to end, after the read path was rewritten.
- Relay suite 14/14.
- Peer damage is not echoed back (`note_remote_damage` credits it).
- Relay registers on start, re-registers on the heartbeat carrying its token,
  and a **restart refreshes the existing entry rather than duplicating it**.
- The tag warning fires on a bad config and clears once corrected.
- `/api/information` returns `{"mapName","players","maxPlayers","tags"}` — the
  shape the launcher's DTO expects.
- `MasterServerEntry` deserialises `Server.to_dict()`'s exact payload (checked
  by compiling the real `AppModels.cs` against a verbatim sample).
- Modding Tools vs retail DLL layout (the table above).

### NOT verified — do not assume these work

- **The Python master server was never executed.** There is no Python on this
  machine (`python`, `python3`, `py` all absent). The registration flow ran
  against a PowerShell `HttpListener` stub of the Flask contract, which proves
  the **.NET half only**. `servers.py` and `models.py` are reviewed, not run.
- **The launcher has never been run against a real game launch.** Its pieces are
  individually proven — injector, DLL and agent are all exercised by
  `Test-CombatOutbound.ps1` — but the launcher's own sequencing of them has been
  reviewed, not observed. The `WHGame.dll` wait is a reasoned choice, not a
  measured one.
- **Schema migration.** `models.py` gains a column and a unique constraint.
  There is no `migrations/` directory, so a **fresh** database gets them from
  `db.create_all()`. An **existing** database needs `migrate.sh` — `create_all`
  does not alter tables that already exist.
- **No second real client, still.** Everything cross-client is proven with
  synthetic TCP peers.

---

## Traps added to the record

- **A duplex pipe used from two threads requires overlapped I/O on both
  handles.** Not an optimisation. A user-mode lock does nothing about it.
- **An unchecked write result** is the same class of mistake as an unchecked
  `variant::is_valid`: `send_frame` discarded its return, so a blocked write
  looked exactly like a delivered one.
- **A narrow catch filter on a background task** turns a crash into silence and
  costs more time than the bug it hides.
- **A PowerShell range index returns `Object[]`, not `byte[]`.**
  `[Guid]::new($bytes[1..16])` picks the `string` overload and throws.
- **`appsettings.Development.json` shadows `appsettings.json`** in the dev
  environment. Fixing only the base file changes nothing.
- **Both game builds ship `KingdomCome.exe` and `WHGame.dll`.** Neither
  distinguishes retail from Modding Tools.

---

## Open items for the next work order

1. **Run `KCDMP_launcher` against a real launch** and confirm the
   game → wait → inject → agent sequence. Highest-value unknown remaining.
2. **Run the real Python master server** end to end with the relay and launcher.
   Needs a Python environment; mind the migration.
3. **A real second client.** Everything is proven against synthetic peers.
4. **`kdcmp.lua` ghost and `esModularBehaviorTree=""`.** A ghost with a
   behaviour tree genuinely perceives (it appears in `PerceptionHistory`), but
   the empty tree exists deliberately so the scheduler does not fight
   `ForceMount` during horse riding. A real trade-off, not an oversight.

Still settled, still not to be re-derived: Lua cannot mutate world state; the
engine can be mutated via rttr from native code; `SharedSoulGuid` is the
cross-client key; **aggro is not achievable**; faction manipulation is
off-limits. See `HANDOFF-WO4-combat.md` and `NATIVE-PLUGIN-findings.md`.
