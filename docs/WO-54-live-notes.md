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

---

## The second player joins — 16:25:57.835

**`ghost 6 = <second player>`** (name redacted per privacy rule — a real
first name appeared in the log; not written here in full), release
`0.17.1`, spawned at `760.83, 3346.42, 142.09` (`Spawning ghost '6' at
760.8,3346.4,142.1`, `kcd.log`) — **inside the same siege
(`zoufalaObranaZaBohutu`) the host had been fighting through solo** (the
host's own position samples in the preceding minutes ranged ~745–768 in the
same x, ~3345–3360 in the same y — this is the same battle, not a separate
area). `TICK_ALIVE` flipped from `ghosts=0` to `ghosts=1` at this point.
**This is the first live multi-human moment of the whole session — the
question this WO exists to answer (joint combat on a shared NPC) becomes
live from here on.**

Immediately after join:
- The ghost's interpolated position **did not change at all** across
  16:25:58.281–16:26:04.700 (~6.4 s, repeated identically at
  `760.83 3346.42 142.09`) while position packets kept arriving (multiple
  `[ghost 6]` lines per second). Read plainly: either the joining player was
  genuinely standing still (loading in, in a menu, at a siege-entry point),
  or this is the stutter/non-motion class from the WO-38/40 footage
  findings. **Not enough here to call it either way** — no narration
  available yet to say what the joining player was actually doing at this
  moment.
- Appearance sync had friction: `[appearance] ghost 6: +19 -10` then, 1.3s
  later, `2 item(s) still not applied, retrying` — the standing retry
  behavior, not obviously a new problem.
- The DiscordRPC `Assets.Merge` NullReferenceException (already noted
  above) recurred a third time at 16:26:00.011, coincident with the join;
  non-fatal, ticks continued.
- A fatal hit landed on a new NPC guid (`9CA9B6BC-...`, 9.11 dmg) at
  16:26:00.845 — almost certainly still the host's own solo siege kill
  (the joiner had not been observed to draw a weapon or move yet); not
  attributed to the joiner without more evidence.

Watching closely from here for: joint engagement on a shared siege NPC
(priority 1), item drops/claims if either player loots (priority 2), and
whether the joiner's hits on a shared NPC register for the host (priority
3, Flow B).

**16:26:08–16:26:47 — the ghost resumed normal movement** (walked a ~15 m
loop through the siege area, then climbed in elevation from z≈142 to
z≈149.7 over 16:26:41–44, consistent with climbing a ladder/tower/wall
section). So the earlier 6.4 s motionless window reads, in hindsight, as
ordinary load-in/orientation, not a stutter — retracting the "not enough to
call it either way" hedge in that direction, though still without narration
to confirm what the joiner was actually doing.

**16:26:43.491 — four fatal hits at the exact same mirror-log timestamp**
(guids `2F5C6209`, `B73F54DA`, `C6FC0AA4`, `60CEB64D`, each `LocalHit 100.00
(fatal)`). Four defenders dying in the same instant, right as the ghost was
partway up its climb, reads more like a scripted siege moment (an
explosive/AOE effect, a wall-collapse trigger — `zoufalaObranaZaBohutu` is
quest-scripted, WO-57 Phase 8) than four discrete player swings. **Not
attributed to either player** — no narration, and nothing in the logs
distinguishes "quest script killed them" from "one player's single AOE-style
action killed four." Two more solo-looking fatal hits followed
(16:26:45.676, 16:26:47.053) on distinct guids. Still no direct evidence of
two players hitting the *same* NPC yet — that is the thing to keep watching
for specifically.

**16:27:31–16:28:18 — more solo siege kills** (fatal hits on guids
`256D03B3`, `467646FE`, `5953FCCE`, `24834DF5`, `9DE95F04`, magnitudes
2.5–100), same pattern as before, not reproduced line-by-line.

**16:27:xx — the WO-48 drop/claim pipeline fired live, for the first time
this session, on real spent crossbow bolts.** Three `item_drop` events
carried the *same* leading id (`ad5bcf05-c082-4ead-be9c-2f16c6d3dde7`)
against three different ground entities
(`posledniPomazani_bohutaOpBolt001793/001811/001843`) — initially read as a
possible dropId-collision bug, but the field order matches WO-48's own spec
(`dropId, amount, health, x, y, z, entityName` — Q2, `WO-48-findings.md`)
where the **leading field is the item-*class* GUID, not the per-drop id**;
three spent bolts of the same class legitimately share it. **Correcting
myself before writing this down as a bug — it is not one on this reading.**
Shortly after: `combat sheathe` → `item_claim 1276324444` /
`ITEM-SYNC drop 1276324444 taken locally -> claim sent` → `combat draw` —
one player interrupted their swing to pick up a dropped bolt by its real
per-drop id, then resumed fighting. **This is a single-claimant pickup, not
a race** — no second claim attempt or "not mine" echo appeared. Still useful
as the first live confirmation this session that the WO-48 pipeline
actually fires end-to-end during real (not synthetic) play. Watching for an
actual two-player race if it happens.

**16:29:57.617–16:30:46.120 — a live, real-gameplay firing of the
`Reconcile` ghost-recovery path (mp_log "Reconcile: N ghost(s) had lost
their entity; will respawn", `kdcmp.lua:4811`), the same mechanism WO-40
built for the general case of a ghost losing its world entity.** Timeline,
cross-referenced kcd.log ↔ agent.log:
- The ghost walked to a natural stop at `755.72, 3355.70, 141.85` (smooth
  deceleration visible in the position stream, not an abrupt cut) and held
  exactly there for the full ~48.5 s window — consistent with the joiner
  standing still (at/near the same spot as the item pickup a few `v1`
  sequence numbers earlier), not a stutter artifact.
- At some point in that window the ghost's entity was lost; `kcd.log` logged
  the `Reconcile` line and then `Spawning ghost '6' at 755.7,3355.7,141.9` —
  i.e. **it respawned at the exact same position**, so from the position
  stream alone this recovery is invisible to an observer.
- `agent.log` confirms the moment the new entity became usable:
  `16:30:46.120 [combatviz] ghost 6 entity id 0x803AD cached for native
  swings` — a new native entity id, replacing whatever the ghost held
  before.
- **No error, no crash signature, no disconnect/reconnect banner** anywhere
  in this window — the connection itself never dropped; only the world
  entity did. Cause of the entity loss itself is **not visible from these
  logs** (no "why" is logged, only "it happened, so we're respawning").
  Given the siege setting, one plausible read is a streaming/despawn
  interaction inside the quest-scripted battle (WO-57 Phase 8 already flags
  siege NPC volume as untested territory) — **not confirmed, just the
  most likely candidate; recorded as inconclusive.**

Relevant to priority 4 (recurrence of a known footage-era failure class) and
worth noting for whoever eventually revisits WO-40's `Reconcile` design: it
worked, cleanly, on the first real-world trigger this project has observed
outside its own synthetic tests.

---

## Second full game-process restart — 16:41:xx, mid-session with a peer connected

**Observed (same three-way cross-check as the first restart, §above):**
`KingdomCome.exe` PID changed (`14380`, `CreationDate 16:41:49.440`); the
pre-restart `kcd.log` (24.8 MB — the whole siege session) was rotated into
`logbackups\`; fresh `=== MOD INIT ===` fired in the new log. **No BugSplat
crash dump was written** (checked, same as the first restart — the
directory itself shows only a bare mtime touch, no new file). `agent.log`:
`[combat] pipe reader exited` (16:41:37.424) → menu closed (16:41:38.225) →
`[discord] SetPresence ... state='v0.17.1 · solo'` and **`Removing all
ghosts...`** (16:41:39.833) — i.e. **this restart cost the live session its
peer presence**; the host's client dropped straight to solo state.

**A pattern is now visible across both restarts this session, worth
recording as a pattern rather than two isolated events:** both times, the
sequence was (1) player opens the pause/menu, (2) `[combat] pipe reader
exited` fires *during* that menu window, (3) menu closes, (4) shortly after,
the client logs a fresh `Connecting...`/reconnect sequence against a brand
new game process. First restart: menu 16:17:58→16:18:05, restart detected
~16:18:37 (~32 s later). Second restart: menu 16:41:31→16:41:38, restart
detected ~16:41:39–49 (near-immediate). **Stated as carefully as the
evidence allows: opening the pause menu is correlated, twice, with the
native combat pipe disconnecting and the game process subsequently
restarting — not proven as cause, since a deliberate human relaunch during
a menu would look identical in these logs, and no crash dump exists either
time to settle it.** No narration was available to say whether the human
intentionally restarted the game both times or it happened to them. If this
recurs a third time under the same menu-adjacent signature, that would be
much harder to attribute to coincidence.

**Impact on this WO's open questions:** neither restart happened *during* a
period of confirmed joint engagement on a shared NPC, so neither directly
answers priority 1 — but the second one demonstrates a real, live
multiplayer-session interruption mechanism (ghost presence lost mid-siege)
that any future joint-combat measurement needs to account for as a
confound.

---

## The WO-26/WO-56 "no faction" signature recurs live, on a real ghost, and does NOT crash

Shortly after the second restart, while the host's client was reconnecting,
`kcd.log` logged **52 consecutive `[Error] NPC kcd2mp_0 does not have a
faction.` lines**, then `kcd2mp_0 deleted 0 reconciled changes`, and later
**one more single recurrence** of the same error against the same name. This
is the exact per-frame error signature WO-26 died on and WO-56 traced
statically (`C_NPCFactionNode::GetFactionPtr`'s non-fatal null-return path,
`WO-56-findings.md` §1.2b) — but this time on a **real ghost respawn during
live play**, not a deliberately bare experimental spawn, and it is the first
time this project has seen this exact signature outside that one WO-26
crash and WO-56's disassembly.

**Confirmed: the process did not crash.** `KingdomCome.exe` stayed on the
same PID (`14380`) throughout, kcd.log kept logging ordinary gameplay
(dialogue, animations) immediately after, and moments later (in real time)
the native DLL re-attached (`16:43:53.386 KCDMP.dll attached, pid=14380`)
and the agent reconnected (`16:43:59.684 PIPE: agent connected`) — i.e. the
whole session kept recovering normally around this error. **This is a live
confirmation of WO-56's prediction**: the fatal path is specific to
`C_Player::Init`'s null-character check, which does not apply to an
NPC-class ghost; a ghost missing its faction is the WO-26 warning-spam
symptom without the WO-26 crash, exactly because it's the wrong class to hit
the fatal guard.

**Why the faction was missing this time — read from the actual spawn code,
`kdcmp.lua:2599-2690`:** unlike WO-26's original bare spawn, this path *does*
pass `SharedSoulGuid` at spawn time (the WO-22 fix — so the ghost is
soul-backed, not starved the way WO-26's was). Faction is set in a
**separate step immediately after**, inside its own `pcall` with no
success/failure logging:
```
pcall(function()
    entity.Properties.esFaction = "Civilians"
    AI.ChangeParameter(entity.id, AIPARAM_FACTION, "Civilians")
end)
```
If that call throws or silently no-ops (e.g. the entity not being fully
ready in the exact frame right after a reconnect-triggered respawn), nothing
would ever report it — this pcall swallows errors unconditionally, unlike
most others in this file. **This reads as plausible and code-consistent,
not confirmed** — no stack trace or pcall failure was logged, so the actual
reason `AI.ChangeParameter` didn't stick is inferred from the code shape,
not observed directly. First time this specific gap has been caught live;
worth a follow-up WO adding failure logging to that one pcall so the next
occurrence is diagnosable instead of inferred.

**Relevance:** this is squarely a "priority 4" recurrence (a known
crash-adjacent signature showing up again) and a genuinely new data point
for WO-56's file — its central claim (fatal-only-for-`C_Player`) now has a
live confirmation, not just a disassembly-based inference.

---

## Third full game-process restart — 16:45:59, ~4 minutes after the second

`KingdomCome.exe` PID changed again (`7700`, `CreationDate 16:45:59.919`).
**The precursor sequence matches the prior two restarts exactly, this time
confirmed from `agent.log` directly rather than inferred:**
```
16:44:59.814  [menu] local menu open -- pumping interp tick
16:45:01.756  [combat] pipe reader exited
16:45:02.396  [menu] local menu closed -- pumped 145 frames in 2.6s (56.2 Hz)
16:45:59.919  (new KingdomCome.exe process created, ~57 s later)
```
**This is now three-for-three**: every game-process restart observed this
session was preceded by opening the pause menu, during which the native
combat pipe reader exited, followed by the menu closing and then a fresh
process within roughly 30–60 s. Three independent occurrences of the same
three-step order is hard to keep calling coincidence, though the mechanism
connecting "menu open" to "process restart" is still not established from
logs alone — it could be the menu action itself destabilizing something
native-side, or an unrelated instability that happens to surface once the
pipe reader (which runs while the menu machinery pumps ticks) drops. No
narration exists to confirm whether the human deliberately restarted the
game each time; given the rapid cadence (three restarts in under 30
minutes, the last two only ~4 minutes apart) it reads more like an
involuntary crash-and-relaunch pattern than deliberate action, but this is
inference, not observation, and is flagged as such.

**And the `kcd2mp_0` no-faction burst recurred identically after this third
restart too** (~51 lines, then `kcd2mp_0 deleted 0 reconciled changes`, then
one more single recurrence — line-for-line the same shape as after restart
#2). `KingdomCome.exe` (pid `7700`) stayed alive throughout (RSS climbed
2.4→6.7 GB, consistent with continued ordinary play); native DLL re-attached
(`16:47:38.216`) and the agent reconnected (`16:47:43.712`) normally right
after. **This is now reproduced twice, identically, on the first ghost
respawn after every observed reconnect-following-restart** — no longer a
one-off. Still non-fatal both times, still consistent with WO-56's
Player-class-only fatal path theory, and still not diagnosed beyond the
code-shape inference already given (the unlogged `pcall` around
`AI.ChangeParameter`, `kdcmp.lua:2685`).

---

## 16:49:2x — the game process exited fully (not another restart), agent looping reconnect

Different from the prior three events: as of 16:49:53, `tasklist` shows
**no `KingdomCome.exe` process at all** — only the launcher, master server,
and relay (`KCDMP_launcher.exe`, `KcdMpMasterServer.exe`, `KcdMpServer.exe`)
are running. `agent.log`: `Removing all ghosts...` / `Reconnecting in 3
s...` (16:49:27.653) — the .NET client is alive and looping, waiting for a
game to reattach to, rather than having already found a fresh one the way
it did the previous three times.

**Context for this one, unlike the prior three: the human asked this
observer a live networking question in chat immediately beforehand** (how
a remote player should connect — DDNS hostname + port-forwarding, answered
16:48ish). It is a reasonable inference — stated as inference, not
observed fact — that this quit was the human closing the game to check
router/firewall settings, not an involuntary crash. Recorded as
context, not as something this observer verified.

**One new error line, not seen earlier this session:** `[version-ipc]
request failed: Could not load file or assembly 'System.IO.Pipelines,
Version=10.0.0.0, ...'. The system cannot find the file specified.`
(16:49:26.380) — an assembly-version-mismatch shape, the same class of bug
WO-46's own history notes ("partial publish broke the relay via
System.Text.Json 10", project memory). This hit the `version-ipc` endpoint
specifically (the launcher's version-check channel), not the main relay
connection, so it reads as a peripheral-feature failure rather than the
cause of the process exit. Not diagnosed further — no build/deploy action
taken or inspected, per this session's scope.

The 4th DiscordRPC `Assets.Merge` NullReferenceException also recurred at
16:49:29.571, same signature as every prior occurrence, still apparently
non-fatal to the client process (it kept logging afterward).

**And the `kcd2mp_0` no-faction burst fired a third time** on this
reconnect too (pid `16364` unchanged, RSS climbing normally) — three-for-
three now on "first ghost respawn after a reconnect," not tallying each
occurrence in full detail further unless the shape changes.

---

**~16:55:37 — the peer reconnected cleanly as `ghost '3'`**, mounted
(`riding=True`), at `142.0, 2058.9, 51.4` — a location far from the
`zoufalaObranaZaBohutu` siege the session had been centered on (~750–770,
3345–3360), consistent with either player having travelled or the outage
having been long enough for real repositioning. **No `does not have a
faction` recurrence for this spawn** — the bug appears specific to ghost id
`0` (or to whatever the very-first-spawn-after-restart timing is) rather
than a universal per-spawn defect; this cleaner spawn on id `3` is a useful
contrast data point, not fully explaining the difference. Session appears
to have stabilized post-troubleshooting; watching for renewed joint-combat
opportunity now that both are reconnected.

*(entries continue below as observed)*
