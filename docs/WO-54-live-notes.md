# WO-54 — live notes (append-only, timestamped)

Observer session started 2026-08-25, local wall-clock ~16:16 PDT (system `date`
used throughout; kcd.log itself carries no wall-clock timestamps — see note
below). Pure observation. No code/config/VERSION changes made or will be made
this session regardless of what is seen.

Privacy: no real IP, DDNS hostname, or personal name is written here.
Placeholders used throughout (`<host>`, `<joiner>`, `<address>`).

## Methodology note (read once)

Three channels tailed live, each with its own clock behaviour:
- `agent.log` (`C:\Users\Jonasty\AppData\Local\KCDMP\agent.log`, the installed
  client's own tee — real HH:MM:SS.mmm wall-clock timestamps).
- `kcdmp-native.mirror.log` (game root, native DLL) — real
  `[HH:MM:SS.mmm]` wall-clock timestamps.
- `kcd.log` (game root) — **no wall-clock timestamps on most lines** (CryEngine
  console log default). Correlated to wall-clock only via: (a) proximity to a
  mirror-log/agent-log line seen in the same tail window, or (b) the
  `[KCD2-MP-DATA] v2 <seq> ...` emitter sequence number, which increments
  ~1/20ms once the emitter is running — usable for *relative* timing within a
  session, not absolute. Any timestamp attributed to a kcd.log-only line below
  is explicitly marked as inferred/approximate.

## Pre-session state (reconstructed from log history, not observed live)

- `KCDMP_launcher.exe`, `KcdMpMasterServer.exe`, `KcdMpServer.exe` already
  running when this observer session started.
- `agent.log` showed a prior run ending 11:33:18 (`Removing all ghosts...`,
  clean-looking shutdown) and a second, separate dev-build run
  (`dotnet/KcdMp.Client/bin/Debug/net8.0/agent.log`, name
  "WO55-HostnameTest") from 11:44:04–11:44:29 — this looks like WO-55's own
  hostname-fix verification, not the two-human session, and is unrelated to
  tonight's run.
- Between then and observer start, the game sat at the main menu unable to
  reach Steam (`kcd.log`: repeated `[Pros] 3=Disconnecting with error
  520='Steam token validation failed'`, reconnect loop) — background noise,
  not mod-related.

## Live timeline

**~16:15:23–16:15:29 (mirror log, real timestamps)** — native DLL
(`KCDMP.dll`) hooked into the running game process: RTTR ABI validated against
`Soul::GetState/SetState`, `CombatSoul::TakeDamage`; `IAT[C_ModulesManager::Update]`
hooked; RPGModule walk succeeded (`SoulCount=1494`); dice hook installed;
`[16:15:29.095] PIPE: agent connected`. This is DLL injection + the .NET
agent attaching to the native pipe, i.e. late-session-start plumbing, not
per-fight instrumentation.

**~16:16:2x (agent.log, real timestamps, inferred kcd.log correlation)** —
agent.log ping/stat ticks resume (installed client, same file as the 11:33 run
— it was reused/reappended). kcd.log shows the Lua side spinning up in the
same window: `State emitter started (20ms)`, `CombatViz: IsWeaponDrawn
readable, initial=false`, `Interp tick started (20ms)`, `HIT_SENSOR on (this
client holds NPC damage authority)`, `NPC-SYNC emit tick started (250ms)`,
`ITEM-SYNC tick started (750ms)`. **This machine holds NPC→player damage
authority (Rule 2) for the session** — i.e. this is the host/authority
observer vantage point, not the joining peer's.

**As of the last `TICK_ALIVE` before this note was written: `ghosts=0`** — no
peer ghost has appeared yet. The second player has not connected, or has not
loaded within range, as of this line.

Monitors armed (persistent, running in background, filtered to exclude
per-tick heartbeat noise): kcd.log (`[KCD2-MP]`/`[KCD2-MP-EVT]` tags + crash
signatures), kcdmp-native.mirror.log (all lines except `SAMPLE:`), agent.log
(all lines except `[stat]`/`[ping]`).

---

**16:17:39.580–16:18:05.924 (agent.log, real timestamps)** — player opened
and closed the pause/menu twice in quick succession:
- Open 16:17:39.580 → close 16:17:55.499 (`pumped 1426 frames in 15.9s,
  89.6 Hz`). Position held static (`2351.3 2140.2 117.4`) through the
  following ~3 s while rotation alone changed rapidly (`rot=2.46` →
  `rot=-1.19` across 16:17:55.775–16:17:57.986) — read as camera look-around
  right after unpausing, not movement; consistent with WO-12's finding that
  position writes/reads continue but this is the player's own local pos, not
  a peer.
- Open again 16:17:58.105 → close 16:18:05.924 (`pumped 403 frames in 7.8s,
  51.5 Hz`).
- Each menu close is followed in kcd.log by a fresh round of `Interp tick
  started (20ms)` / `Label render loop started (8ms)` / `State emitter
  started (20ms)` / `NPC-SYNC emit tick started (250ms)` / `ITEM-SYNC tick
  started (750ms)` — i.e. **the mod's own timer chains are being restarted on
  every menu close**, not just resumed. This is consistent with WO-13's
  standing finding (timer chains die and must be re-armed) but here the
  trigger is an ordinary pause menu, not a save load — worth flagging since
  the interp-pump fix (WO-40 Phase 2) was described as keeping ticks alive
  *through* menus, not restarting them each time. Not diagnosed further
  (observation only, no code inspection during a live session).
- At 16:18:05.110, mid this second menu-close window, agent.log logged
  `[combat] pipe reader exited` — the same message seen in this morning's
  historical logs immediately preceding a clean agent shutdown. Here it was
  **not** followed by a shutdown; ticks and pings continued after. Whether
  the native combat pipe reconnected silently or stayed down was not checked
  live (would require a read-only pipe-status probe not yet identified) —
  flagged as **inconclusive**, watch for combat-cue effects later if this
  player fights before any reconnect message appears.
- Still `ghosts=0` throughout — no second player has joined yet as of
  16:18:05.

*(entries continue below as observed)*
