# WO-58 — Findings: the latency hypothesis, the restart cascade, and the wrong-gender ghost

Evidence tiers as in WO-54, never rounded up: **observed** (in a log, cited) /
**corroborated** (independently in more than one log) / **inferred** (code- or
log-shape read, labelled) / **inconclusive**.

Privacy: no real name, hostname, IP, DDNS name, Steam id, or Discord handle
appears below or in the committed log copies. The redacted bundle lives at
`docs/WO-58-test-logs/` — `HostBundle`/`PlayerA-1` are the host machine's two
exports, `PlayerB-1`/`PlayerB-2` the joiner's two. The joiner's clock runs
9 h ahead of the host's (WO-54 established the offset); all times below are
**host-clock** unless marked.

Two files that were in **no exported bundle** turned out to decide Phase 1,
because they happened to survive on the host machine's own disk: the engine's
`logbackups\kcd.log` (the frozen session's game log) and
`kcdmp-native.mirror.log` (the DLL's own per-frame log for that same
session). The bundle collector now exports both — see Fix 6.

---

## Gate 1 — verdict, stated plainly

**Latency hypothesis investigated and ruled out as the root cause. The real
cause was found: the game's main thread hangs inside mod-driven native ghost
operations at reconnect time — one instance pinned to the exact native call
(`ForceMount` onto a freshly-adopted world horse) and fixed; the other
instances are the same family (ghost `SpawnEntity`, appearance
`CreateItems`/`EquipItem`) with the trigger op identified but the faulting
instruction not recoverable from the available logs. Reports 1 and 2 are one
disease seen from two seats — but the synchronizer is the session lifecycle
(each side's freeze forces a restart, which forces the other side through a
reconnect-and-respawn cycle, which is exactly when the dangerous native ops
run), not a single shared error at a single shared moment.**

### 1.1 The cross-machine timestamp correlation, verified properly

The joiner's `HttpClient.Timeout of 0,8 seconds` bursts (1,639 lines total,
clustered; PlayerB-2 agent.log):

| burst | host-clock window | what it actually tracks |
|---|---|---|
| 1 | 16:30:46 – 16:42:32 | the **joiner's own** game freezing at 16:30:45, staying wedged ~10 min, being killed and relaunched at 16:40:58 (kcd.log launch header), then loading |
| 2 | 16:43:59 – 16:46:06 | the joiner's fresh game loading + respawning the host's ghost (their kcd.log ends at `Spawning ghost '4'`) |
| 3 | 16:47:29 – 16:49:26 | another joiner-side stall episode, ended by the relay dying at 16:49:26 (both agents log `Removing all ghosts... / Reconnecting in 3 s...` within one second — WO-54's corroborated pair, re-confirmed) |
| 4 | 17:00:16 – 17:00:42+ | the joiner's third game launch (16:59:17) freezing at the spawn of the host's ghost (kcd.log ends at `Spawning ghost '1'`) |

Host restarts (WO-54): 16:18:37, 16:41:49, 16:45:59, ~16:50:35, 16:58:48.

**The strict reading of the WO-58 prompt — "the same error at the same real
moment on both machines" — is refuted**: the joiner's timeout bursts do not
line up 1:1 with host restarts; they line up with the *joiner's own* game
freezes. **The loose reading is confirmed**: it is the same failure
signature on both machines (localhost:1403 stops answering inside 0.8 s +
`[combat] pipe reader exited` within ~2 s of each other), and the two
machines' failures chain each other — the joiner's game restarted at
16:40:58, the host's at 16:41:49; the host's restart 5 at 16:58:48 was
followed by the joiner's launch 3 at 16:59:17 freezing on the resulting
ghost respawn. "Constantly crashing" (report 2) is real and corroborated:
the joiner's game hard-froze and was relaunched at least twice inside the
35-minute window (kcd.log launch headers 01:40:58 and 01:59:17
joiner-clock), plus the initial launch's 10-minute wedge.

`[combat] pipe reader exited` — WO-54's common precursor — is hereby
**re-classified as a downstream symptom**, not a cause or trigger: on both
machines it lands 1–2 s *after* the local game stops answering HTTP, and on
the host it lands the same second the game's own per-frame native log stops.
What breaks the pipe itself during a hang is still not determinable from
these logs (noted, not load-bearing).

### 1.2 The pinned freeze: `ForceMount` onto an adopted world horse (observed, three independent logs)

Host freeze at 16:55:33 (the one that produced restart 5):

- `HostBundle/kcd.log` (= the engine's own `logbackups` copy on the host
  disk): final line of the entire file is
  `[KCD2-MP] MountNPCOnHorse id=3 hasHuman=true` — ghost 3 (the joiner,
  reconnected 16:55:22 **mounted**) had just been adopted onto the world
  horse the joiner's mount-identity packet named. The two WO-40 crash-guard
  deferrals (`0.4s old`, `1.9s old`) printed on the two prior attempts; on
  the third attempt the guard passed (age ≈ 3.4 s) and the next log line —
  `ForceMount ok=` — **never printed**.
- `kcdmp-native.mirror.log` (host disk, same session): the DLL's sampler
  runs on the game's main thread every ~3 s and logs each pass. Last entry
  **16:55:31.916**, then nothing, ever. The main thread never ran another
  frame.
- `HostBundle/agent.log`: pipe reader exited 16:55:33.215; every
  localhost:1403 call times out at 0.8 s from 16:55:35 on; inbound ghost
  positions and 0 ms relay pings keep flowing fine around the corpse —
  the network was healthy while the game was dead.

So the main thread entered `human:ForceMount(horse.id)` and never returned:
a hang, not a crash (no BugSplat, process alive and accepting TCP for 3+
minutes until the tester killed it). This was the **first live execution**
of WO-38 Phase 5's world-horse adoption. The adopted horse only had to
*exist* to pass the `GetEntityByName` check — and in the host's world the
same-named horse lived nowhere near the ghost (the ghost spawned at
142,2058; the host was playing ~2 km away, and the horse is that world's
own copy, wherever it happens to stand). ForceMounting an NPC onto a
distant, unstreamed, AI-owned horse hung the engine. WO-40's two 2026-08-18
crashes were this same mount path with a different (spawn-age) trigger; the
3-second guard moved the failure, it did not remove it.

**Fixed** (`kdcmp.lua`, `KCD2MP_SpawnHorse`): adoption now requires the
world horse to be within 60 m of the ghost; anything else falls back to the
proven proxy horse. The proxy path is the one every previously live-verified
ghost mount actually used.

### 1.3 The joiner's freezes: same family, trigger op identified, instruction not recoverable

- Freeze #3 (17:00:14): PlayerB-2's kcd.log final line is
  `Spawning ghost '1' at 2340.1,2080.8` — the very next statement after
  that log is the native `XGenAIModule.SpawnEntity` call, and the line that
  follows it (`face pick for ...`) never printed. Frozen inside or
  immediately after the native spawn. **Observed.**
- Freeze #1 (16:30:45): sudden — positions and 0 ms-read ticks healthy to
  16:30:45.2, first 0.8 s timeout at 16:30:46.758 on a **fresh appearance
  equip** (`[appearance] equip ... on kcd2mp_4 failed`), i.e. native
  `CreateItems`/`EquipItem` REST calls were the in-flight operation. That
  launch's kcd.log was overwritten before export, so this one is
  **inferred from the agent log**, not pinned.
- The relay link was healthy at both onsets (pings 186–396 ms, normal for
  this link) and the combat wire was quiet (last hit message 57 s before
  freeze #1). **Latency was not a participant in any observed freeze.**

### 1.4 The latency couplings that ARE in the code (real, but not what fired)

The prompt's specific questions, answered from the code:

- *Does the agent share a thread/queue/lock between remote traffic and local
  debug-API calls?* **Yes.** `ReceiveLoopAsync` is one serial loop that
  `await`s, per inbound wire message, both localhost:1403 HTTP calls
  (`ResolveLocalSoulGuidAsync`, 0.8 s timeout each) and DLL-pipe round trips
  that wait for a game frame (`main_thread::run_sync`, 5 s timeout). While
  the local game is stalled, *every* queued damage message costs seconds,
  and positions/pings queue behind them.
- *Can a backlog of slow network messages delay pipe reads?* **Yes.**
  `CombatPipe.ReadLoopAsync` awaits the `OnLocalHit` handler inline, and
  that handler does a local HTTP name-resolve plus a relay TCP send per
  frame. And on the DLL side, `send_local_hit` runs **on the game's main
  thread** with a blocking overlapped write into a 64 KB pipe buffer while
  holding the pipe write lock — a reader stalled long enough (~90 s at the
  observed 26 hits/s) would freeze the game outright.
- **But**: production and consumption are both tied to the same main thread
  (the hit sampler stops when the game stalls), the observed freezes began
  with the wire quiet and pings normal, and onset was instant, not a
  gradual choke. So these couplings are real *amplifiers* — they turn any
  stall into timeout storms and catch-up bursts, and a 169–1415 ms link
  makes the bursts deeper — and none of them is the root cause of what was
  observed. **Verdict on the 169 ms+ floor: contributing factor at most,
  root cause ruled out.**

### 1.5 The hit-report flood (real, live-observed, fixed)

The joiner's agent put **1,972 hit messages on the wire in under four
minutes** (16:26–16:29) — `[combat] sent hit 0,0 on 'zoufalaObranaZaBohutu_...'`
— all sub-0.05 hp contact-frame chips from the siege's NPC-vs-NPC battle
running in the joiner's *own* world (their save sat at the siege location;
their `[pos]` confirms it). WO-40's zero-damage filter only dropped *exact*
zeros; 0.01–0.09 hp chips sailed through at up to 26/s. Every one costs the
receiving peer a synchronous main-thread damage apply (`run_sync`) — a
direct, code-anchored FPS drag on the host while it fought the same battle
locally, and the strongest identified contributor to report 1's FPS drop
that the logs can actually see. (No frame-time counter ran this session, so
the 15 fps figure itself remains human-reported.)

**Fixed** (`GameBridge.OnLocalHit`): hits below 0.5 hp are dropped before
the wire (the DLL hardcodes stamina to 0 on this path; real player hits in
these same logs are 6.5–100 hp).

### 1.6 A shipped-release defect found on the way: version-ipc has never worked in the field (observed, both machines, fixed)

Both testers' clean 0.17.1 installs log
`[version-ipc] request failed: Could not load file or assembly
'System.IO.Pipelines, Version=10.0.0.0'` **every 3 seconds, all session** —
the launcher polls the agent's version endpoint and gets a 500 every time.
The file ships in the release folder; the failure is the WO-46 "partial
publish" class made permanent by `tools/Publish-Release.ps1` flattening four
self-contained publishes into one directory (the agent resolves the
launcher's System.Text.Json 10 but not its dependency chain). Consequence:
the launcher's version-mismatch notice — the thing meant to catch exactly
the "old version" situations in report 3 — has never fired in the field.

**Fixed** (`VersionIpcServer.cs`): the endpoint now hand-rolls its
two-field JSON and no longer touches System.Text.Json at all. The
launcher's parser is case-insensitive and unchanged. (The dice IPC server
still uses System.Text.Json for POST bodies and shares this deploy-layout
risk — scoped as follow-up, not hit in these logs.)

### Scoped for follow-up, deliberately not attempted here

- **Receive-loop decoupling**: applying inbound damage without blocking the
  wire loop (bounded queue + worker). Real design change; the flood fix
  removes the observed pressure.
- **Publish layout separation** (per-app subfolders): correct fix for the
  Json-10 class at the root, but it touches installer, launcher process
  paths and every deploy script — not a rushed patch.
- **DLL pipe backpressure**: `send_local_hit` should drop-on-full instead
  of blocking the game thread. Small native change, but native deploys
  can't be verified from this shell (WO-45), so it ships with the next
  native build cycle.

---

## Gate 2 — the wrong-gender/face ghost, stated plainly

**Confirmed mechanism found and fixed — and it needs no old save at all.**

### 2.1 What the four-day-gap bundle actually shows

The earlier-vs-later face-pick comparison the WO asked for is **not
recoverable**: the Aug-22 side of the gap survives only as launcher
`app20260822.log` files (component chatter, no game or agent telemetry —
kcd.log and agent.log are per-run files and were overwritten long before
export). No `face pick` line from the old version exists in any bundle.

What the Aug-26 logs show instead, twice, is the live bug:

- Both joiner kcd.logs carry
  `SpawnGhost id=N has no Steam nick yet -- reconnect dedupe cannot run`
  (ids 4 and 1) — the host's ghost spawning **before its name was known**.
- A nameless spawn is face-picked from the fallback key `"Player<id>"`
  instead of the player's nick, and gender is the hash's parity:
  `hash("Player4")` is odd (male, wrong face), **`hash("Player1")` is even —
  the host's ghost spawned as a woman on the joiner's screen at 17:00:13.**
  Observed; the arithmetic is reproducible from `KCD2MP_HashString`.

Root cause of the missing nick: the game restarting **mid-connection**. The
relay delivers each ghost's Name packet once, at handshake; a local game
restart wipes the mod's Lua state while the agent's relay session survives,
so every ghost respawned into the fresh Lua is nameless — and the old code
never re-delivered the name or corrected the face afterwards (`SetGhostName`
fixed the *nameplate* but kept the mispicked *body*). Given Phase 1's
restart cascade, this fired constantly this session.

The "old save" framing in the report is therefore most likely a coincidence
of timing (the returning player's first session landed in the middle of the
restart cascade), not the mechanism — with one real caveat, next section.

### 2.2 The save-embedded stale ghost (plausible, unhandled until now, fixed)

Code review confirms the WO's concern was real: a ghost is a physical world
entity, so a save made with one standing nearby captures it. On a later
session the relay hands out **different ids**, so the stale body defeats
both existing cleanups — `SpawnGhost`'s preexisting-entity check only fires
on the *same* spawn name (`kcd2mp_<sameId>`), and
`RemoveStaleGhostsForPlayer` only walks the in-memory tracked table, which a
game restart empties. A stale ghost (or its proxy horse) from an old
session/version would stand in the world indefinitely wearing whatever face
the old version picked — indistinguishable, from across a field, from "that
player joined as the wrong person". No direct log evidence of one this
session (the logs don't cover the players' save/load moments closely
enough), but the hole is real and cheap to close, so it is closed.

### 2.3 Fixes shipped

1. **Agent re-asserts every known ghost name** on its existing 2.5 s re-arm
   cadence (`GameBridge` re-arm block) — a fresh Lua gets the names back
   within seconds of any restart/reload; the Lua side no-ops when the name
   is already applied, so the steady-state cost is a string compare.
2. **Late name corrects the body, not just the nameplate**
   (`KCD2MP_SetGhostName`): a ghost that spawned on the fallback key and
   turns out to deserve a different face/gender is removed; the next
   position packet (≤50 ms later) respawns it through the normal path,
   which now has the name. Wrong-gender ghosts self-heal in seconds instead
   of persisting for the session.
3. **Stray sweep** (`KCD2MP_SweepStrayGhosts`): once per connection (and on
   every disconnect teardown), any `kcd2mp_<id>` / `kcd2mp_horse_<id>`
   entity the live tables don't own is removed — this is what cleans a
   save-embedded ghost from any older session or version, whatever id it
   wore.

### 2.4 Scoping the general "old save" problem

Inventory of what this mod leaves in a save: ghost bodies and proxy horses
(now swept), synced dropped items (real `PickableItem`s — harmless, a
legitimate item on the ground), puppeted real NPCs (positions self-heal
under their own AI, WO-32's release principle), weather/time (transient),
dice winnings (real money, intentionally kept). **Verdict: a general
"save predates version X" detector is not worth building** — the only
artifacts that go *wrong* are the ghost bodies, and self-healing cleanup
covers every vintage of save without version bookkeeping. If a future WO
adds a persistent world mutation, revisit then.

---

## Tester-facing guidance

- **Update both machines together** to the next release cut from this tree
  (client + mod pak are a matched set; partial updates recreate the WO-46
  deploy trap this WO just diagnosed in the field).
- **Old saves are fine.** No save deletion or new game needed; leftover
  ghost bodies from old sessions clean themselves up on the next connect.
- **Wrong face/gender on a player** should now self-correct within a few
  seconds. If one persists longer than ~10 s, that's a new bug — collect
  logs then.
- **If the game hard-freezes** (sound loops / stops, picture stuck): use the
  launcher's Collect Logs *before* killing the game if at all possible, and
  again after restarting it — the bundle now captures the frozen session's
  own kcd.log backup and the native DLL log, which is exactly the evidence
  that cracked this WO.
- **Riding near a peer**: the peer's ghost now only "borrows" a real world
  horse when that horse is genuinely standing nearby; otherwise it rides a
  generic proxy horse. Cosmetic downgrade, deliberate — the borrow path
  froze the host's game on its first live use.
- The mid-battle FPS drop while a peer is also near a battle should be
  reduced (the chip-hit wire flood is gone). It is *reduced*, not proven
  gone — no frame-time measurement exists yet; report what you see.

## Fixes shipped in this WO (summary)

| # | Where | What |
|---|---|---|
| 1 | `kdcmp.lua` `KCD2MP_SpawnHorse` | world-horse adoption requires ≤60 m proximity; else proxy (pinned freeze fix) |
| 2 | `GameBridge.OnLocalHit` | drop sub-0.5 hp chip hits before the wire (flood fix) |
| 3 | `GameBridge` appearance | never-equip blacklist per ghost lifetime — ends the infinite 404 retry churn (9 items cycled every ~30 s on both machines all session) |
| 4 | `GameBridge` + `kdcmp.lua` | ghost-name re-assert on the re-arm cadence + no-op guard (wrong-gender prevention) |
| 5 | `kdcmp.lua` `KCD2MP_SetGhostName` | fallback-keyed body respawns when the real name arrives (wrong-gender self-heal) |
| 6 | `LogBundle.cs` | bundle now collects `kcdmp-native.log`, `kcdmp-native.mirror.log`, and the two newest `logbackups` game logs |
| 7 | `VersionIpcServer.cs` | hand-rolled JSON — version-status endpoint works regardless of the deploy's DLL soup |
| 8 | `kdcmp.lua` `KCD2MP_SweepStrayGhosts` | save-embedded / cross-session stray ghost & horse cleanup, run per connect and on teardown |

All suites green (59/59). No `VERSION` change; releasing these fixes is the
user's call per `docs/VERSIONING.md`. The Lua changes take effect only after
`Build-And-Install-Mod.ps1` rebuilds the pak (WO deploy gotcha) and the
launcher/agent changes only via a full matched-set publish.
