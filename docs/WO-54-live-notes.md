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

**16:18:37.868 → ~16:19:07 — the game process itself restarted mid-session
(observed, cross-checked three ways).** Evidence:
- `tasklist`/WMI: `KingdomCome.exe` PID changed 5568 → 2312,
  `CreationDate = 2026-08-25 16:18:37.868823` — a genuinely new process, not
  a stale PID read.
- `kcd.log` was rotated: the pre-restart log (2.7 MB) was moved to
  `logbackups\kcd.log` at 16:18, and a fresh `kcd.log` started from
  `BugSplat initialized` / `CPU Information` (i.e. engine boot) — this is
  what the kcd.log monitor's `BugSplat` keyword actually caught; it is the
  crash-reporter **initializing**, not firing. No corresponding entry
  appeared in `BugSplatAttachments\` (checked, empty of anything new) — **no
  BugSplat crash report was generated for this restart.**
- Fresh `=== MOD INIT ===` fired again in the new kcd.log (mod reloaded
  clean).
- `agent.log` (the .NET client) shows **no disconnect, no reconnect, no
  error** across this transition — ping/stat ticks are continuous
  16:18:0x→16:19:05 — then at 16:19:07.468: `[timeskip] clock went backward
  (571172 -> 0) -- save reload detected`, `reload: no live peers -- leaving
  the reloaded clock alone`. So the *agent* only learned of the restart
  indirectly, via the mod's game-clock resetting to 0, not via any
  process/connection-level signal — worth flagging: the agent's reload
  detection is clock-based and silent about the underlying process bounce
  itself.
- Immediately pre-restart, the mirror log's last readable sample
  (16:18:01.963) read `tracking 2 souls within 60 m` — up from 1 for the
  preceding ~5 minutes (transition at 16:17:25). **Whether that second soul
  was the second player's ghost or an ordinary wandering NPC is not
  determinable from this log alone** — the mirror log stopped there because
  of the restart, before anything could disambiguate it. Marked
  **inconclusive**.
- **No BugSplat dump, no `[Error]` stack trace, no "has no character"/"does
  not have a faction" lines seen anywhere around this transition** — i.e.
  nothing resembling WO-26's crash signature. This looks like either a
  deliberate restart by whoever is at the keyboard, or a silent
  crash-without-report; cannot distinguish the two from logs alone.
- `ghosts=0` still held immediately after (`[KCD2-MP-EVT] v1 1 time_now 0`
  is the first post-restart event line) — no peer has joined as of the
  restart.

Narration was not yet available for this session (no live human commentary
channel open to this observer at start) — this restart's cause is recorded as
unknown/inconclusive rather than guessed.

**16:20:42–16:20:46 — native DLL re-injected + a fresh agent process
started on the host/authority machine (observed).**
- `kcdmp-native.mirror.log`: `KCDMP.dll attached, pid=2312` — the *same* PID
  as the post-16:18:37-restart game process, so this is re-injection into
  the already-running post-restart process, not a second engine restart.
  RTTR ABI re-validated exactly as before (`GetState`/`SetState`/
  `TakeDamage` signatures match); `SoulCount` this time 4911 (vs 1494 before
  the restart) — consistent with a different/larger area now loaded.
- `agent.log`: a **new** client process started at 16:20:44.174 (fresh
  `agent output tee ->` banner, meaning the prior ticking process from
  §16:19 was replaced/relaunched around this point, not merely reconnected).
  Connection banner: `Server: 127.0.0.1:7778` (this machine's own local relay
  — matches the standing port convention), `Voice: on`, `Protocol: v6`. This
  client identified itself via a Steam display name and, moments later, a
  Discord account handle — **both redacted here per the privacy rule**
  (`<host Steam name>`, `<host Discord handle>`); neither is written to any
  committed file in full.
- **16:20:46.362 — a DiscordRPC exception fired**, caught by the agent's own
  handler (logged as `ERR :`, process did not appear to die — ping/stat
  ticks are expected to resume next, to be confirmed): `System.
  NullReferenceException` inside `DiscordRPC.Assets.Merge(Assets other)` →
  `RichPresence.Merge` → `DiscordRpcClient.ProcessMessage`. This is the
  **same signature as the already-documented WO-50 `DiscordRPC 1.6.1
  Assets.Merge` NRE bug** (project memory). Whether the WO-50 fix is present
  in this build and simply didn't cover this code path, or wasn't deployed
  here, was **not checked live** (would require reading the installed
  agent's DLL/source — out of scope for a pure-observation session); recorded
  as a recurrence, not re-diagnosed.
- Still no peer ghost as of this point (not yet re-confirmed post-reinject;
  watching).

**16:20:48–16:22:12+ — solo siege combat (WO-15's `zoufalaObranaZaBohutu`), still no
peer. Two things worth keeping, both solo-only:**

1. **A real native fatal kill, captured end-to-end, twice.** `agent.log`
   `[combat] sent hit 100.0 on '...frontWallShooter_5'` (16:20:59.667) and
   again on `...attackers_frontWallStationaryShooter_5` (16:22:07.843),
   matched 1:1 in the mirror log as `PIPE: LocalHit 100.00 (fatal)`. This is
   the native `HIT_SENSOR`/Flow-B-sender path (WO-28/51) actually firing on a
   real kill in real (non-synthetic) siege combat — confirms the sending
   side works; says nothing about the never-verified cross-machine apply
   side since there is no peer yet.
2. **A sustained near-zero "hit" stream matching WO-40's documented
   zero-damage-hit-flood signature, reproduced live.** From ~16:20:59 through
   at least 16:22:11 (~70+ s, hundreds of frames), `agent.log`/mirror log
   show a continuous `LocalHit 0.01`–`0.09` (drifting up/down slowly) against
   one single stationary target,
   `zoufalaObranaZaBohutu_defenders_sideWallSubstitute_4` (guid
   `15aae88d-...`), at roughly 5–15 Hz, essentially the entire time the
   player was near it with a weapon drawn — not discrete swings. Read
   plainly: this looks like continuous weapon/collider contact against a
   static "wall substitute" prop being reported through the same sensor as a
   real hit, not a combat animation artifact. WO-51's table already flags
   "zero-damage hit floods (engine stall → anim collapse)" as
   mitigated-not-proven; this is a live, named recurrence of exactly that
   signature, now tied to a specific prop class, not re-diagnosed further.
   Not connected to any of the four open questions directly (no peer to
   receive/attribute it), but relevant to "general stability" (priority
   item 4) and worth a future WO's attention re: whether `sideWallSubstitute`
   colliders should be filtered from the hit sensor.

Both observations are solo-only — `ghosts=0` held throughout this entire
combat episode. Full per-frame detail lives in `kcd.log` /
`kcdmp-native.mirror.log` on this machine if anyone wants to re-derive exact
counts; not reproduced line-by-line here to keep this readable.

**Correction, 16:23:46.438:** the `sideWallSubstitute_4` target of the
near-zero hit stream above eventually took `LocalHit 36.82 (fatal)` — i.e. it
died. This weakens the "static collider / pure sensor artifact" reading:
either the near-zero stream was genuine (if small) chip damage against a
defender NPC that doesn't fight back, accumulating to a real kill, or it is
still a flood artifact and the 36.82 was an unrelated discrete swing that
happened to land the killing blow on an already-near-dead entity. Not
resolved from logs alone — recorded as still open, not settled.

*(monitors retightened here to drop per-tick NPC-position and hit-flood
spam — see methodology note; full detail remains in the source logs)*

*(entries continue below as observed)*
