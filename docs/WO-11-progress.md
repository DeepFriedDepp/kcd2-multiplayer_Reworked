# WO-11 progress — pause/world-halt mitigation

2026-07-31. Branch: `main`. Read `docs/WO-11-findings.md` first — this is the
build log for the Phase 1 it authorized.

---

## Phase 0 result (see findings doc for full evidence)

**(B): a time-scale control, no true veto.** `SetPauseWorldTime` (the WO-6
dice hook) never fires outside dice, and neither dice nor inventory/pause-
menu/tutorial has a sibling exported symbol to hook instead — closed,
cleanly, for every state checked. `t_scale`, CryEngine's global simulation
time-scale CVar, is real, live, and writable through the debug console's
`ExecuteString`/`GetCvarValue` — verified by round-tripping `1 → 0.3 → 1`
against the running game before any code was written.

An addendum to the same doc, found while answering the user's own follow-up
question about verbose logging, closed the one open sub-question Phase 0 had
left: **detecting** entry into a pausing state needs no new native hook
either. `kcd.log` under `log_Verbosity 4` carries distinct, unambiguous
marker pairs for the three states isolated live:

| State | Enter | Exit |
|---|---|---|
| ESC/system pause menu | `PlayAudio: MenuOpen` + `'sqc_ptag_menu' will be 1` | `PlayAudio: ui_menu_close` + `'sqc_ptag_menu' will be 0` |
| Inventory | `PlayAudio: ApseOpen` | `PlayAudio: ApseClose` |
| Skip-time (sleep/wait) | `Readiness observer 'AfterSkipTime' ... started async waiting` | `...is ready` |

Tutorial popups and photo mode were never isolated (not confirmed to emit a
marker, not confirmed absent either) — covered by the manual override below.

---

## What was built

Per the WO's Phase 1 instructions for a (B) result: broadcast local
pause-state transitions over the existing relay, remote clients slow down
via `t_scale` while any peer is reporting paused and restore when none are,
plus a manual console command for states automatic detection doesn't catch.

### Wire protocol (`Protocol.cs`, v5 → v6)

```
C→S  0x1C  PauseUp:   [state:1]                   (1 byte)
S→C  0x1D  PauseDown: [sourceGhostId:1][state:1]   (2 bytes)
```

`state`: 1 = entered, 0 = exited. No heartbeat (unlike Appearance) — a late
joiner missing a transition isn't compounding anything, since the source's
own tick was never actually halted (Phase 0's 0.3 finding). Version bumped
because every prior wire layer bumped it on a new packet type; the relay's
exact-match handshake means there is no partial-support case to design for.
`PausedPeerTimeScale = 0.3f` lives in `Protocol.cs` too, shared between the
client and the test script rather than duplicated.

### Relay (`ClientSession.cs`, `TcpBroadcastService.cs`)

Mirrors Death exactly: exact-length validation, `BroadcastPause` to every
other ready client, no echo to the sender. No `SessionManager.cs` changes —
this isn't a paired-session feature, it's a presence-layer broadcast like
Damage/Appearance.

### Detection (`LogTailGameTransport.cs`)

`ProcessPauseMarkers` runs on every raw (non-`[KCD2-MP-...]`-tagged) line
the tail loop already reads — no second file handle, no second read of
`kcd.log`. Three independent booleans (`_menuOpen`, `_inventoryOpen`,
`_skipTimeActive`) OR into one `PauseStateChanged` event, so two overlapping
states don't produce a spurious "exited" when only one of them closes.

### Response (`IGameTransport.SetTimeScaleAsync`, `HttpGameTransport`)

A new transport primitive, deliberately separate from `ExecuteAsync`:
`ExecuteAsync` always wraps its argument as Lua (`#pcall(...)`) through the
existing batched channel, and `t_scale` is a raw console CVar, not a
reflected call — the same distinction Phase 0's 0.4 had to work out. Sent
immediately, unbatched: a peer applying this on `PauseDown` needs it to take
effect now.

### `GameBridge.cs`

Two local sources OR'd into one broadcast state (`_localAutoPaused` from the
tail transport's event, `_localManualPaused` from `mp_slow_time`), sent only
on a change of the OR'd result. Remote side tracks a `HashSet<byte>` of
currently-paused peer ghost ids so `t_scale` is only touched on the set's
empty↔non-empty edge — two peers pausing overlapping don't fight each other
over the restore. A peer disconnecting mid-pause is treated as an implicit
exit (confirmed live, see below) so a crash can't leave a receiver
permanently slowed.

### Manual override (`kdcmp.lua`, `mp_slow_time`)

Same shape as WO-9's `mp_sync_appearance`: a console command emits a
`[KCD2-MP-EVT]` line, `GameBridge.OnGameEvent` picks it up. Toggles rather
than one-shot, since Lua has no way to know the agent's current state.

---

## Verification

### Relay-level (`tools/Test-Pause.ps1`, no game needed)

Same synthetic-TCP-peer approach as `Test-Combat.ps1`. All green:

```
PASS  observer receives PauseDown (0x1D) on enter
PASS  downstream payload is 2 bytes
PASS  tagged with the pauser's ghost id
PASS  state byte preserved (entered)
PASS  pauser does not receive its own state back
PASS  observer receives PauseDown (0x1D) on exit
PASS  state byte preserved (exited)
PASS  zero-length PauseUp payload is dropped, not forwarded
PASS  stream still usable after a malformed packet
PASS  a pre-WO-11 agent is refused rather than silently dropping pause state
```

### Full required suite

Bumping `Protocol.Version` to 6 required updating the hardcoded version in
`Test-Combat.ps1`, `Test-Dice.ps1`, `Test-Sessions.ps1` (all were pinned to
5). Run against an isolated test-only relay instance (ports 7779/5299, not
the live 7778/5273 the user's own session was using) so as not to disturb
it:

```
Test-Combat.ps1   : 14 passed, 0 failed
Test-Sessions.ps1 : 22 passed, 0 failed
Test-Dice.ps1     : 10 passed, 0 failed
Test-Pause.ps1    : 10 passed, 0 failed
```

`Test-Pipe.ps1` was **not** re-run: it deals real damage to a live NPC, and
this WO touched no native/pipe code (`native/KCDMP/*` and `pipe_server.*`
are untouched), so it exercises nothing this WO changed. Skipped rather than
run for a checkbox against the user's in-progress save.

### Live, human-observed, against the actually-running game

With the user's explicit go-ahead to restart their live agent/relay
connection for this — checked first, since `KcdMpServer.exe`/
`KCDMP_launcher.exe` were already running. `netstat` showed the live relay
(port 7778) had zero established connections at the time (listening only),
so nothing was actually mid-session; verification ran on an isolated test
relay (7779) against the same already-injected game process, and the user's
own launcher/relay/game were never touched or restarted.

**Real agent (`KcdMp.Client`, not a synthetic stub) connected to the real,
already-injected game** via `dotnet run -- --host localhost --port 7779
--name WO11TestAgent --no-voice`, log-tail transport, confirmed live:
position streaming, combat pipe connected, appearance sent.

**Synthetic peer → real `t_scale` on the real game:**

```
t_scale before                    : 1
synthetic peer sends PauseUp(1)   : (broadcast)
t_scale after                     : 0.3
```

**Disconnect safety, found for free rather than by a scripted test:** the
synthetic peer's PowerShell process ended between commands, dropping its
TCP connection while still "paused." The real agent's console logged
`[pause] all peers unpaused -- t_scale 1.0` on its own — the
`ApplyPeerPauseAsync(ghostId, paused: false, ...)` call wired into the
`Disconnect` packet handler fired exactly as designed, with no forced-exit
packet ever sent.

**Automatic detection, live, human-in-the-loop** — asked the user to open
and close their inventory/pause menu twice more with the real agent
running and watching `kcd.log`:

```
[pause] local state -> entered
[pause] local state -> exited
[pause] local state -> entered
[pause] local state -> exited
```

Confirms the full loop end to end: real UI action → log marker → detection
→ broadcast → remote `t_scale` response → restore, plus the crash/disconnect
path — all against the real game, not a stub.

**Cleanup confirmed:** `t_scale` read back `1` after the test agent and test
relay were stopped; the user's own `KCDMP_launcher`/`KcdMpServer`/game
processes were running, untouched, throughout.

---

## What is NOT verified

- **Tutorial popups and photo mode.** No log marker was isolated for either
  (WO-11-findings.md's addendum flagged this already). `mp_slow_time` covers
  them as a manual fallback; automatic detection does not.
- **Two real human players.** This session has one machine, one copy of the
  game — same environment constraint as every other WO in this project.
  Verified with a real agent against the real game plus a synthetic peer,
  the same standard `Test-CombatOutbound.ps1` etc. already use.
- **Whether `PausedPeerTimeScale = 0.3` is the right value for actual play**
  — it's the value already round-tripped live in Phase 0, not separately
  tuned. A real two-player session may want it lower or higher.

---

## Files touched

- `dotnet/KcdMp.Protocol/Protocol.cs` — wire layer, v6
- `dotnet/KcdMp.Server/Features/ClientHandling/ClientSession.cs`,
  `Features/Tcp/TcpBroadcastService.cs` — relay broadcast
- `dotnet/KcdMp.Client/IGameTransport.cs`, `HttpGameTransport.cs`,
  `LogTailGameTransport.cs`, `GameBridge.cs` — detection, response, wiring
- `kdcmp/Data/Scripts/Startup/kdcmp.lua` — `mp_slow_time` console command
- `tools/Test-Pause.ps1` — new relay-level test
- `tools/Test-Combat.ps1`, `Test-Dice.ps1`, `Test-Sessions.ps1` — protocol
  version bump only
- `docs/WO-11-findings.md`, `docs/WO-11-progress.md`

No `SessionManager.cs` (session-framework) changes — this is a presence-
broadcast feature, not a paired-interaction one, so it didn't need any.
