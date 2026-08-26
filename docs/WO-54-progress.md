# WO-54 — progress (cleaned incremental notes)

Live-observed 2026-08-25, local wall-clock ~16:16–17:26 PDT (system `date`
used throughout; `kcd.log` itself carries no wall-clock timestamps — see
methodology note below). Pure observation for the live portion — no
code/config/`VERSION` changes were made during observation. This is the
cleaned version of the incremental journal kept during the session
(`WO-54-live-notes.md`); see `WO-54-findings.md` for the analysis, including
the post-session cross-check against both players' own exported logs.

Privacy: no real IP, DDNS hostname, or personal name appears below.
`<host>` / `<joiner>` used throughout in place of anything identifying.

## Methodology note (read once)

Three channels tailed live, each with its own clock behaviour:
- `agent.log` (the installed client's own tee — real HH:MM:SS.mmm
  wall-clock timestamps).
- `kcdmp-native.mirror.log` (game root, native DLL) — real
  `[HH:MM:SS.mmm]` wall-clock timestamps.
- `kcd.log` (game root) — **no wall-clock timestamps on most lines**
  (CryEngine console log default). Correlated to wall-clock only via
  proximity to a mirror-log/agent-log line seen in the same tail window, or
  the `[KCD2-MP-DATA] v2 <seq> ...` emitter sequence number (relative timing
  only). Any timestamp attributed to a kcd.log-only line is inferred/
  approximate, flagged as such.

## Pre-session state (reconstructed, not observed live)

- Launcher, master server, and relay were already running when this
  observer session started; the game had been sitting at the main menu
  unable to reach Steam for some time (background noise, unrelated to the
  mod).

## Timeline

**~16:15:23–16:15:29** — native DLL hooked into the running game process
(RTTR ABI validated, dice hook installed, `PIPE: agent connected`) — the
first sign this session's plumbing was starting up.

**~16:16:2x** — `<host>`'s client resumes; the Lua mod's ticks start
(`State emitter`, `Interp tick`, `HIT_SENSOR on` — `<host>` holds NPC damage
authority, i.e. this is the host/authority vantage point). `ghosts=0` — no
peer yet.

**16:17:39–16:18:05** — `<host>` opens/closes the pause menu twice; each
close restarts the mod's own timer chains (interp/state-emitter/NPC-sync/
item-sync all log fresh "started" lines) rather than resuming them — a
menu-adjacent variant of WO-13's standing timer-death finding. Mid the
second close, `[combat] pipe reader exited` fires for the first time this
session, with no immediate consequence.

**16:18:37 → ~16:19:07 — first full game-process restart**, confirmed three
ways (new PID via WMI `CreationDate`, `kcd.log` rotated to `logbackups\`,
fresh `MOD INIT`). No BugSplat dump. `agent.log` shows no
disconnect/reconnect signal at all — it only learns of the restart
indirectly via the mod's game-clock resetting to 0 at 16:19:07. `ghosts=0`
throughout — no peer yet, so this restart is not attributable to a joining
player.

**16:20:42–16:20:46** — native DLL re-injected into the post-restart
process, a fresh `<host>` client starts. A `DiscordRPC.Assets.Merge`
`NullReferenceException` fires (the known WO-50 bug, project memory) —
non-fatal.

**16:20:48–16:22:12+ — solo siege combat** (`zoufalaObranaZaBohutu`, still
no peer): two real native fatal kills captured end-to-end (agent →
mirror-log `LocalHit 100.00 (fatal)`, confirming the HIT_SENSOR/Flow-B
sender path fires correctly on real kills); and a sustained near-zero
`LocalHit 0.01–0.09` stream against one stationary siege prop
(`..._sideWallSubstitute_4`) for 70+ seconds — a live recurrence of WO-40's
documented zero-damage-hit-flood signature. (Correction, 16:23:46: that same
prop eventually took a real `36.82 (fatal)` hit and died, weakening the
"pure sensor artifact" reading — left open, not resolved.)

**16:25:57.835 — the joining player connects for the first time**, spawning
as `ghost 6` **inside the same siege** `<host>` had been fighting solo —
the first live multi-human moment of the session. Stood still ~6 s (later
shown to be ordinary load-in, not a stutter — it resumed a ~15 m walk and a
climb up the siege structure over the next minute). A `DiscordRPC` NRE
recurs a third time, coincident with the join.

**16:26:43.491 — four fatal hits at the identical mirror-log timestamp** on
four different siege-defender guids — reads more like a scripted
siege/AOE moment than four discrete swings; not attributable to either
player from logs alone.

**~16:27 — the WO-48 item drop/claim pipeline fires live** for the first
time this session, on real spent crossbow bolts, ending in one
single-claimant pickup (`item_claim 1276324444`) with no competing claim —
confirms the pipeline works end-to-end in real play; not a race.

**16:29:57.617–16:30:46.120 — a live firing of the `Reconcile`
ghost-recovery path** (`kdcmp.lua:4811`): the joiner's ghost lost its world
entity while standing still, and the mod detected and respawned it at the
identical position — invisible to an observer, no error, no disconnect.
Cause of the entity loss is not visible in the logs; a siege-scripting
interaction is the most plausible unconfirmed candidate.

**16:41:xx — second full game-process restart, this time costing the live
session its peer.** `[combat] pipe reader exited` fires during an open
pause menu; the menu closes; `<host>`'s client drops straight to
`Removing all ghosts...` and solo state. New PID confirmed via WMI. No
BugSplat dump.

**Shortly after restart #2 — the WO-26/WO-56 "no faction" signature
recurs live, on a real ghost, for the first time outside WO-26's original
crash and WO-56's disassembly.** ~52 lines of `[Error] NPC kcd2mp_0 does
not have a faction.`, then `kcd2mp_0 deleted 0 reconciled changes`. **The
process did not crash** — same PID throughout, normal play resumed,
DLL/agent reconnected cleanly within seconds. Read against the actual spawn
code (`kdcmp.lua:2658–2690`): this ghost *was* soul-backed (unlike WO-26's
starved spawn); only a separate, unlogged `pcall` around
`AI.ChangeParameter(entity.id, AIPARAM_FACTION, ...)` appears to have
failed or no-op'd. This is a live confirmation of WO-56's theory that the
fatal path is specific to `C_Player`-class entities and mechanically
unreachable for an NPC-class ghost.

**16:45:59 — third full game-process restart, ~4 minutes after the
second.** Precursor confirmed directly from `agent.log` this time: pause
menu open (16:44:59.814) → `[combat] pipe reader exited` (16:45:01.756) →
menu closed (16:45:02.396) → new process ~57 s later. **Three-for-three**
on the same menu→pipe-exit→restart order — at this point read as a real
pattern, not coincidence (later revised, see below). The no-faction burst
recurred identically a second time.

**~16:49:2x — the game process exited fully** (not another bounce — no
`KingdomCome.exe` at all for a stretch), while the client looped
`Reconnecting in 3 s...`. This one is contextual rather than purely
observed: it followed immediately after the human asked this observer a
live networking question (DDNS hostname + port-forwarding for the remote
player), making a deliberate quit-to-check-settings a reasonable inference
— stated as inference, not verified. One new error type appeared here:
`[version-ipc] request failed: Could not load file or assembly
'System.IO.Pipelines, Version=10.0.0.0...'` — an assembly-version-mismatch
shape matching WO-46's own "partial publish" bug class; hit a peripheral
endpoint, not the main relay connection. The no-faction burst recurred a
third time once the game came back (~16:50:35).

**~16:55:37 — the peer reconnects cleanly as `ghost '3'`**, mounted, at a
location far from the siege — session context had moved on. No no-faction
recurrence for this particular spawn (it appears specific to ghost id `0`
/ first-spawn timing, not universal).

**16:55:33.215 — correction: the "menu opens the pipe" theory does not
survive a fifth look.** `[combat] pipe reader exited` fires again, this
time during active gameplay (the peer's ghost smoothly riding) with no
menu open anywhere nearby. **This falsifies "opening the pause menu" as a
necessary trigger** — three-for-three was real but coincidental. What
holds across all five restarts: every one was preceded by a pipe-reader
exit; what causes *that* is still unknown. One concrete, unconfirmed lead
from this exact window: `<host>`'s own appearance-sync HTTP calls (to the
game's local debug API) started missing their 0.8 s timeout repeatedly,
across six different items in a few seconds — a real local
responsiveness stall coincident with the pipe-exit, and a plausible shared
cause for both.

**16:58:48.387 — fifth full game-process restart**, ~3m15s after that
pipe-exit (longer than the ~30–60 s gap on restarts 1–3). Still no BugSplat
dump. The no-faction burst fired a fourth time, identically, non-fatal.

---

## Session end and hand-off to the findings document

The human ended the live-observation phase here and shared four exported
log bundles (two incremental snapshots from each side) plus their own
written notes describing a separate, earlier "New Game / tutorial" attempt
with heavier crashing. That material — including things this live tail
could not see (the joiner's own ping numbers, the joiner's own crash/
reconnect log lines, the two machines' different OS locales, and the
authority hand-off that happened on the joiner's side while `<host>`'s game
was down) — is analyzed in `WO-54-findings.md`, which is the authoritative
write-up. This document is the incremental record; that one is the
synthesis.
