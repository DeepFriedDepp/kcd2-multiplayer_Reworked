# WO-88 — post-reload reconciliation + dialogue pause detection

Field session: 2026-09-12, two players on 0.21.1, ~17:00–17:31 local. Logs:
`kcd.log`, `agent.log`, `kcdmp-native.log` from both machines plus the relay
log from the host machine. "Host" = the player whose machine ran the relay
(relay id 2; its peer's ghost is `kcd2mp_1`). "Joiner" = the other player
(relay id 1; its peer's ghost is `kcd2mp_2`). Line numbers are into each
machine's `kcd.log`; wall times are the agent logs' timestamps. Nothing
identifying either person is reproduced here.

Every claim is tagged **(observed)** — read directly in these logs;
**(code-verified)** — traced in the tree at `04006bd`; **(inferred)** — the
only reading consistent with both, but not itself in a log line;
**(inconclusive)** — the logs do not decide it.

---

## 0. Phase 0 — the logs, before any theory

### 0.1 Death / reload timeline (observed)

Both players reloaded the same exit save on every death (`Loading saved game
... exit.whs`, each machine). Host deaths: 5. Joiner deaths after the host
connected: 6 (a seventh at 16:58:51 predates the host's connection and the
joiner restarted its game at 17:00:29, so its current `kcd.log` starts there).

| Wall (agent) | Event | Host `kcd.log` | Joiner `kcd.log` |
|---|---|---|---|
| 17:07:42 | joiner dies | `GHOST_DEATH id=1 dead=true` 41202 | `[death] local player died` |
| 17:07:57 | joiner alive again (vitals 100) | `dead=false` 43181 | reload → `RECONCILE id=2` 45408, respawn 46219, `ApplyTimeSkip 568912 -> 579354` 46267 |
| 17:08:34 | host dies | `GameOver.gfx` 47271 | `GHOST_DEATH id=2 dead=true` 49056 |
| 17:08:51–58 | host reloads | `RECONCILE id=1` 56311, respawn 56320, `ApplyTimeSkip 568987 -> 579497` 56646 | `dead=false` 50403 |
| 17:09:18 / 17:09:42 | joiner dies / host dies | 58373→60597; reload 62514, respawn 69195, `ApplyTimeSkip -> 580093` 69444 | 61898→62536; reload 55087, respawn 61692, `ApplyTimeSkip -> 580854` 61793 |
| 17:12:45 | host dies | reload 83050, respawn 89631, `ApplyTimeSkip -> 582390` 89820 | 72573→72590 (17 lines apart) |
| 17:14:40 / 17:14:42 | both die within 2 s | 97653 `dead=true`; reload 99917; `ApplyTimeSkip -> 583740` 106448; `dead=false` 106449; respawn 106620 | 83325 `dead=true`; reload 83334; `dead=false` 90050; respawn 90057; `ApplyTimeSkip -> 585662` 90458 |
| 17:16:01 | host dies | reload 114794, respawn 120843, **no `ApplyTimeSkip` line** | — |
| 17:17:32 → 17:18:23 | joiner dies, 51 s death screen, reloads | 129733 `dead=true` … 133308 `dead=false` (0 locomotion lines for ghost 1 in between) | reload 107895, `ApplyTimeSkip -> 588672` 114386 |
| 17:20:47 → 17:21:03 | joiner dies, reloads | 141413 `dead=true`, **141416 `dead=false`** (3 lines) | reload 125444, `ApplyTimeSkip -> 591077` 132027 |
| 17:24:43–53 | joiner "waits" manually | `ApplyTimeSkip: 576492 -> 662681` 156600 | `clock jumping (594226 -> 629641)`, `sent done kind=1 t=662681` |
| 17:27:37 → 17:27:54 | joiner dies, reloads | 164600 `dead=true`, **164632 `dead=false`** (32 lines) | reload 157797, `ApplyTimeSkip -> 664313` 164532 |

### 0.2 Finding 1 — ghost death-state (observed)

- Every one of the host's six `GHOST_DEATH id=1 dead=true` lines is followed
  by a `dead=false`; every one of the joiner's five `dead=true` lines is too.
  Ghost-1 locomotion on the host (`Anim: 1 …` lines, which only run when
  `mp_ghost_is_corpse` is false — code-verified, `kdcmp.lua` interp tick
  `if frozen … else KCD2MP_UpdateAnimation`) resumed after each clear: 542,
  423, 389, 277 lines in the four segments after 133308.
- **The reported symptom — a ghost that stays dead after its owner reloads —
  is not present in either machine's Lua state in this session.** The one
  state the logs do show persisting is the correct one: the 51 s death screen
  at 17:17:32–17:18:23, frozen with the tag up, cleared when the joiner's
  vitals resumed at 17:18:23.9.
- What the logs do show is the **inverse** defect, twice: `dead=true` cleared
  3 lines (141413→141416) and 32 lines (164600→164632) later, while the
  joiner was still on its death screen. Joiner agent 17:20:47.975 `[death]
  local player died` then 17:20:48.053 `[vitals] sent health=0.0`; and
  17:27:37.964 both in the same millisecond.
- `DeathAnim: false` on both machines: none of the twelve death-pose
  candidates exists on this build, so no body pose is ever played; the only
  death cues are the nameplate tag and the locomotion freeze.
- (inconclusive) what the host saw as "still dead". The tag and freeze both
  cleared within one relay round trip of the joiner's first alive vitals,
  which themselves arrive only once the WO-78 restart gate has re-armed the
  joiner's emit chain after the load (`CHAIN emit confirmed dead … 48.2s --
  restarting` 114393 for the 17:18 reload). That lag is bounded by the gate's
  probe cadence (~10 s in these logs), not indefinite.

### 0.3 Finding 2 — appearance (observed)

- Before either machine's first reload, outfit changes applied both ways
  with no retries: host sent 6/3/4/7 items at 17:02:40–49, joiner applied
  `+0 -1`, `+0 -3`, `+1 -0`, `+3 -0`.
- After the host's first reload (17:08:51, respawn of `kcd2mp_1` at 56320),
  every appearance line on the host for ghost 1 is a **delta**: `+0 -1`
  (17:09:21), `+1 -0`, `+0 -1/-2/-2` (17:10:16–22), `+3 -0` with three
  `still not applied, retrying` (17:10:37–41), `+2 -0`, then only the
  weapon toggling `-1`/`+1` at each joiner death/reload for the rest of the
  session (17:14:40, 17:14:55, 17:15:26, 17:17:33, 17:18:25, 17:20:47,
  17:21:02). Symmetrically on the joiner after its first reload (respawn of
  `kcd2mp_2` at 46219): `+0 -2`, `+0 -2`, `+0 -1`, `+4 -0` with six
  retries, `+1 -0`, then weapon toggles only.
- Both peers kept sending the full set every 30 s (`sent 7 item class(es)
  (heartbeat)`, 53 times each) and **no heartbeat ever produced a `+N` on the
  receiver after the receiver's first reload** — the diff was empty.
- No `never equipped … suppressing` line on either machine: the WO-58/59
  blacklist never fired this session. Every retry run ended in a verify read
  that reported the delta items present.
- One direct REST failure inside a load window: host 17:14:55.915 `equip …
  on kcd2mp_1 failed: Response status code …`; joiner 17:14:47.201 `unequip
  … on kcd2mp_2 failed: The request was can[celled]`.

### 0.4 Finding 4 — world time (observed)

- Each reload's convergence: joiner 7 of 7 landed (`ApplyTimeSkip … (written)`
  at 15333, 46267, 61793, 90458, 114386, 132027, 164532). Host **4 of 5**:
  56646, 69444, 89820, 106448 — and nothing for the 17:16:01 death. Host
  agent at 17:16:13.984 logged `reload: converging forward to session clock
  584692 (reloaded to 568884, was 584692)`; the next `time_now` readings in
  `kcd.log` are `568884` (120959) and `568956` (121956). The write never
  ran. No second `clock went backward` was ever logged for it.
- Host `[appearance] local equipped-set read failed` 17:16:09.243 →
  `recovered` 17:16:16.908 brackets that send: the game's REST API was
  refusing requests when the batch carrying the convergence was flushed.
- Size of the loss: 584692 − 568884 = **15,808 game-seconds** (4.4 game
  hours). At 17:24:43 the joiner read 594226 while the host, 8.5 real
  minutes after the missed write, sat at 576492 (156600): a gap of 17,734
  game-seconds ≈ 4.9 game-hours. The joiner's manual wait to 662681 was
  applied by the host (`ApplyTimeSkip: 576492 -> 662681`), which is the
  "self-resolved when the other player waited" in the report.
- The remaining ~1,900 s of that gap is the convergence target itself:
  host targets were always its own pre-death reading (`was` == target in all
  five host lines) because the only peer clock it held was the joiner's
  connect-time announce of `118800` (the joiner was at its main menu at
  17:01:46 — `clock went backward (573601 -> 118800)`), which extrapolates
  below anything. Joiner targets were the host's 17:02:18 announce
  (`574201`) extrapolated at ratio 15 for up to 25 minutes, hence always a
  few hundred seconds ahead of its own `was` (571481/571123 … 591077/590687).
  Each side converged to a different private clock.

### 0.5 Finding 3 — the dialogue incident (observed)

Real player conversations are identifiable as `Dialog ending` lines whose
participants are both `Ex` and whose flags are not the bark values
(9104/9105/9112). There were six in the session; the only long one is the
joiner's **arrest dialogue** with `ttkc_man_6` (`STRAZ_ZATYKANI`, runtime id
729): joiner `kcd.log` 33367 (t=387.7, ≈17:06:50) → 36804 (t=436.1,
≈17:07:39), 48 s, ending 3 s before the joiner's 17:07:42 death. The host's
matching window is host-t 415.8–464.2 (offset host-t = joiner-t + 28.1,
anchored on the `GHOST_DEATH`↔`[death]` pairs, ±1 s).

What each machine was doing inside that window:

- **Joiner (in the dialogue) — its emitters did not stop.** `[KCD2-MP-DATA]`
  lines continued through the whole conversation (1,939 lines in t 384–437,
  largest step 1.7 s, no gap ≥ 3 s anywhere near it). Its NPC stream for
  `ttkc_man_4` ran at 0.11 s spacing until t=413.3, then **exactly the
  2.0–2.1 s heartbeat for 22.7 s** (11 packets, t 415.4–436.0), then 0.11 s
  again from t=436.5. Code-verified: that is the emitter's `heartbeatS = 2.0`
  branch — the joiner's copy of `ttkc_man_4` moved less than `moveEps`
  (0.05 m) for those 22.7 s. Every other NPC around the joiner went the same
  way: 157 `npc_state` events in the 5 s bucket at t=385 fell to 10–15 per
  bucket at t=415–430 and jumped back to 96 at t=435.
- **Host (watching) — inbound cadence collapsed to heartbeats.** `NPC-SYNC
  packet cadence` mean 171 ms (t=413.9) → 343 → 511 → 1076 → **2064 ms,
  n=7** (t=449.1) → 2081 (454.2) → 2064 (459.2) → 1379 (464.2) → 192 ms
  (469.2). `puppet start ttkc_man_6` at host-t 420.8 and `puppet start
  ttkc_man_4` at 424.9 — the two guards became puppets during the dialogue.
  No `NPC-FIGHT … displaced` line for either guard in that window.
- The same pattern is absent from every other pause type here: the death
  screens and inventories DO show DATA gaps (12–20 s, bracketed by
  `sqc_ptag_silence`/`ApseOpen` markers); the six conversations show none.

### 0.6 Phase 0 verdict on "one shared gap" for findings 1 / 2 / 4

**Separate defects with one trigger, not one gap.** They share the
death→reload event and nothing else:

- Finding 1 is a packet-ordering race on the receiver (two independent
  senders, one clears what the other set).
- Finding 2 is receiver-side state that outlives the entity it describes
  (the ghost respawn edge never reaches the appearance diff).
- Finding 4 is a lost one-shot write on the reloader plus a convergence
  target computed from stale private data.

Three different layers (relay packet order, agent per-ghost cache, agent→Lua
command delivery), three different machines' roles (receiver, receiver,
reloader). No single fix touches more than one.

---

## 1. Phase 1 — the reconciliation path in code

### 1.1 What already existed (code-verified)

- `KCD2MP_ReconcileGhosts` (`kdcmp.lua`), called by the agent every 5 s
  (`ReconcileGhostsInterval`): detects a ghost whose entity is gone or dead
  and clears the bookkeeping so the next position packet respawns it. It
  drops `ghosts`, `labelCache`, `horseGhosts`, `ghostHpSeen/Skip` — it
  deliberately keeps `ghostDead`, `ghostHealth`, names and menu tags ("still
  correct for that player"). Fully wired since WO-84.
- `KCD2MP_SetGhostDead(id, dead)`: sets/clears `KCD2MP.ghostDead[id]`, logs
  the transition, tries the death pose (none exists). Cleared by
  `GameBridge.ApplyGhostVitalsAsync`, which sent `SetGhostDead(false)` on
  **every** `PlayerStateDown`.
- `SendDeathIfNewAsync` (0x23) and `SendPlayerStateAsync` (0x1F) are two
  independent senders fed by the same emit line; on the dying tick both fire.
- Appearance: `ApplyAppearanceAsync` diffs the incoming set against
  `_ghostAppearance[ghostId]` (seeded with the spawn preset), creates only
  classes not in `_ghostKnownItemClasses[ghostId]`. Both are cleared on
  connect (`GameBridge.cs` ~716) and on a peer's `Disconnect` (~2653) — and
  **nowhere else**. The `ghostid` event from `KCD2MP_SpawnGhost` fires on
  every (re)spawn and WO-68 already uses it as "the ghost-ready edge" to
  re-apply civic isolation; appearance was never attached to it.
- Time: `OnReloadDetectedAsync` computes `candidate = max(preReloadTime,
  peerWorldTime + elapsed×15)`, sends one batched `KCD2MP_ApplyTimeSkip`,
  then sets `_lastPolledWorldTime = candidate`. It is invoked fire-and-forget
  from `OnWorldTimeReading`, whose own tail then sets `_lastPolledWorldTime =
  worldTime` (the reloaded value) — so when the batch does not run there is
  no baseline left that could re-detect it. `HttpGameTransport.FlushAsync`
  swallows the HTTP failure (`catch { /* fire-and-forget */ }`). `_peerWorldTime`
  is only ever set from a peer's `TimeSkipDown` done/quiet packet: connect-time
  and new-peer announces, or a real skip. Nothing refreshes it otherwise.
- WO-80's pump (`StartInterpPump` → `KCD2MP_InterpPump`, which runs the
  interp tick and the NPC puppet tick) reacts to `ProcessPauseMarkers`'
  aggregate of menu / inventory / skip-time / rendered-cutscene markers. It
  never ran during the arrest dialogue — and per §0.5 nothing on the
  dialogue machine needed pumping.

### 1.2 Finding 1 — death state

**Root cause (code-verified, observed twice):** `ApplyGhostVitalsAsync`
cleared the death tag on any vitals packet, including `health=0`. The 0x23
and the `health=0` 0x1F leave the dying client in the same tick; whichever
the relay delivers second wins. The two 3-/32-line clears are exactly the
vitals-second ordering. This is the "GHOST_DEATH flag flapping" WO-78 §5
named and no WO took.

**The reported "remained dead" is not reproduced** in these logs (§0.2). The
receiver does get told "alive again" — by the first alive vitals, gated on
the emit chain restart after the load. Left as inconclusive with the
bounded-lag observation; the fix below removes the one death-state defect the
logs do prove.

### 1.3 Finding 2 — appearance

**Root cause (code-verified, timing observed on both machines):** the
appearance diff runs against per-ghost state that survives the ghost body it
was applied to. A local save load destroys the entity; `RECONCILE` respawns
it in the spawn preset; `_ghostAppearance` still lists the peer's outfit as
applied, so the 30 s heartbeat diffs to nothing (§0.3: zero `+N` from any
heartbeat after the receiver's first reload) and only later deltas reach the
new body. `_ghostKnownItemClasses` compounds it: a class first created on
the old body is "known", so a later re-equip goes `EquipItem` without
`CreateItems` — the retries at 17:10:37–44 on both sides. It is the same
shape as WO-58's sweep before WO-84 and WO-68's isolation before it was
attached to `ghostid`: the edge exists, the consumer was never wired.

Not the cause: the WO-58/59 blacklist (never fired), aliasing (all alias
lines resolve), send-side partial reads (WO-59's guard held: every failed
local read was skipped, and `sent N` counts track real changes).

(inferred) The visible result on each screen: the respawned ghost in preset
armour plus whichever pieces changed afterwards — read by both players as
"default armour only". The logs show what was and was not re-equipped; they
cannot show the render.

### 1.4 Finding 4 — time

**Primary root cause (observed once, code-verified):** the reload
convergence is one batched ExecuteString with no confirmation, and the
batch flush drops silently on HTTP failure. Host reload #5's flush met the
post-load REST outage (§0.4) and was lost; the baseline overwrite in
`OnWorldTimeReading` guaranteed nothing noticed. Loss: 15,808 game-s.

**Secondary root cause (code-verified, visible in every convergence
line):** the "session clock" each reloader converges to is private and
stale — its own pre-death reading, or a connect-time announce extrapolated
for up to 25 minutes — because peers only announce their clock at connect /
new-peer / real skip. Two clients that both died several times therefore
converged to two different clocks even when every write landed; the sum of
those offsets is the ~1,900 s remainder of the 17,734 s gap. The first field
session's "desync after deaths" report has the same shape and is the same
mechanism; it was never investigated then.

Not the cause: ExecuteString truncation (0 `[Lua Error]` lines in either
`kcd.log` this session, versus 1,582 in WO-78's), the joiner's bogus 118800
announce (correctly refused: `ApplyTimeSkip: already at 573726 >= 118800`),
or the WO-40 forward-only rule itself (every landed convergence went the
right way).

### 1.5 Phase 1 verdict

Confirms §0.6: **three separate defects**, now each with a named code site —
`ApplyGhostVitalsAsync` (1), the `ghostid` edge vs `_ghostAppearance` (2),
`OnReloadDetectedAsync`/`FlushAsync`/peer-clock freshness (4). Shared
trigger only.

---

## 2. Phase 2 — dialogue (finishing WO-80 §5)

### 2.1 Step 1 — `human:IsInDialog()` live probe

**Not possible this session (observed):** no game process; ports 1403 and
4600 closed. Per WO-65's rule the bind stays unverified. What ships instead
is the probe itself: `mp_probe_dialog` → `KCD2MP_ProbeDialog()` (read-only;
logs the bind's type, its pcall result, and the `Dialog.IsSoulInDialog`
alternative). The next live session runs it inside and outside a
conversation.

### 2.2 Step 2/3 — should the pump get a dialogue input?

**On this session's evidence, no — and this is the load-bearing result.**
WO-78 and WO-80 assumed a dialogue suspends the `Script.SetTimer` chains the
way menus, inventories, skip-time and rendered cutscenes demonstrably do
(DATA gaps bracketed by their markers, §0.5). The one long real conversation
in these logs shows the opposite: the dialogue machine's DATA stream, NPC
emitter and heartbeats all kept running for 48 s. Six of six conversations
show no DATA gap. Pumping the interp tick on the dialogue machine would have
pumped a tick that was already ticking.

So the WO-80 step-2 build (extend `ProcessPauseMarkers`' aggregate with a
dialogue term) is **deliberately not done**: it would add a pause type the
logs say is not a pause. If the live probe in §2.1 ever shows a build where
dialogue does halt the chains, the pump is one aggregate term away, exactly
as WO-80 left it.

### 2.3 What the watcher actually saw (observed + inferred)

The inbound NPC cadence on the watching machine went to pure 2 s heartbeats
for every NPC around the dialogue player because **those NPCs stood still in
the authority's world** during the conversation (the guard is talking, the
bystanders wait). The two guards became puppets on the watcher mid-dialogue.
On a heartbeat-only stream the puppet tick (code-verified: `SetWorldPos`
every 50 ms to the held snapshot) pins the body where the authority last put
it; any local-brain locomotion between writes is undone each tick. Which NPC
the watcher perceived as "approaching", and whether its local brain moved it
(no `NPC-FIGHT` line fired for either guard), the logs do not decide —
**(inconclusive)**. What they do decide is that the cure is not a pump: it
is either brain suppression on puppets (WO-64's `Activate(false)` pilot) or
a puppet render that treats a heartbeat-only stream as "hold, do not fight"
— both already-scoped work behind the WO-63 gate, not a WO-80 remainder.

---

## 3. Phase 3 — what changed

| Site | Change |
|---|---|
| `dotnet/KcdMp.Client/ReloadReconcile.cs` (new) | Pure decisions: `VitalsClearDeathTag`, `RespawnInvalidatesAppearance`, `EvaluateConvergence`, `QuietSyncWorthApplying`. |
| `GameBridge.ApplyGhostVitalsAsync` | Clears the death tag only when the vitals say `health > 0`. |
| `GameBridge` `AppearanceDown` handler | Keeps the peer's last raw outfit per ghost (`_ghostLastAppearance`). |
| `GameBridge` `ghostid` event | A new entity id for an already-seen ghost drops that ghost's applied/known/blacklist sets and re-applies its last outfit immediately (WO-68's edge, now also feeding appearance). Logged as `[appearance] ghost N: body respawned …`. |
| `GameBridge.OnReloadDetectedAsync` + `SendReloadConvergenceAsync` | The target stays outstanding (`_reloadConvergeTarget`, 120 s window); the baseline keeps the reloaded value on purpose. |
| `GameBridge.OnWorldTimeReading` | Every reading checks the outstanding target first: `Resend` while behind (extends jump suppression), `Satisfied` at/past target − 900 s, `Expired` after the window. |
| `GameBridge` position loop | Sets `_timeSyncPending` every 60 s while a live peer exists → a quiet clock announce rides the next poll. |
| `GameBridge.ApplyTimeSkipAsync` | Quiet applies within 900 game-s of our own extrapolated clock are logged and skipped; announced skips are never gated. |
| `kdcmp.lua` | `KCD2MP_ProbeDialog` + `mp_probe_dialog` (read-only). No behaviour change. |
| `dotnet/KcdMp.Client.Tests` (new, in the solution) | 21 xunit tests pinning the four decisions to the field numbers. |

Not changed, on purpose: `Protocol.cs` (no wire change — the periodic
announce is the existing `TimeSkipPhaseSync`), the relay, the native DLL,
`ProcessPauseMarkers`, `VERSION`, the pak.

---

## 4. Phase 4 — verification

| Check | Result |
|---|---|
| `dotnet build` KcdMp.Client.Tests (builds Client + Protocol) | 0 errors; 7 pre-existing warnings, none in changed code |
| `dotnet test` KcdMp.Client.Tests | **21/21** |
| `tools/Test-WO86Synthetic.ps1` (real `kdcmp.lua` under MoonSharp) | 47/47 |
| `tools/Test-WO84Synthetic.ps1` | 72/72 |
| `tools/Test-NpcSmoothSynthetic.ps1` | 48/48 |
| `tools/Test-GhostInterpSynthetic.ps1` | 35/35 |
| Live death + reload (tag, outfit, clock) | **not run** — no game this session |
| Live `mp_probe_dialog` in/out of a conversation | **not run** — same |
| Relay forwarding of the periodic sync | unchanged path (`TimeSkipPhaseSync → BroadcastDoneQuiet`), not re-exercised |

What the synthetic side does not prove: that `ghostid` arrives before the
REST API will answer for the new soul (the existing 10 s verify/retry and the
30 s heartbeat are the safety net if it does not); that a re-sent
convergence is accepted by the game once the REST API is back (the Lua path
is the same one that landed 11 of 12 times); that two live clients settle on
one clock under the periodic announce. Those are the next live session's
three checks, alongside the probe.

---

## 5. Named, not attempted

1. Puppet handling of a heartbeat-only stream (hold vs fight), and brain
   suppression on puppets — the actual mechanism behind finding 3 (§2.3);
   WO-63 gate / WO-64 pilot.
2. The death tag's clear is still gated on the peer's emit-chain restart
   after a load (§0.2 last bullet) — a faster "I am back" signal would be a
   protocol addition; not evidenced as needed beyond ~10 s.
3. `HttpGameTransport.FlushAsync` drops a whole batch on HTTP failure with
   no line logged. Made survivable here for the one command that cannot be
   lost; the transport itself is unchanged.
4. The joiner's main-menu clock announce (118800) is harmless under
   forward-only but is noise; not touched.
