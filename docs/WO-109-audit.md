# WO-109 — full codebase audit (0.26.4)

Session 2026-09-22, solo, against the 0.26.4 tree (`f4aabfa`). Progress and
gaps: `docs/WO-109-progress.md`. Read first: WO-108 findings / toggle
inventory / runbook, WO-107, WO-106 findings + native-migration, WO-105
contradictions.

Evidence marks: (observed) / (code-verified) / (synthetic) / (inconclusive).
**Audit only: no code, pak, installer or VERSION change.** One live read ran
(§1.4, the determinism probe). **Nothing here ran two-player.** Every
two-player statement below is a prediction. Paths: `<repo>` = working tree,
`<install>` = the Modding Tools install, `<saves>` = the KCD2 saves folder.

---

## §0 Answer first

* **The host streams NPC positions from a snapshot refreshed every 2 s.**
  With `readNative` on (the default since 0.26.0), the 100 ms emitter sends
  the native scan's position, and the agent pushes that scan only every 2 s.
  A walking streamed NPC therefore sends about one position every 2 s. The
  joiner holds it about 2 s, then plays a 0.12 s dash, or snaps if the jump
  is over 5 m. The pause lever cannot touch this.
  (code-verified: `kdcmp.lua:4612-4619`, `3964-3966`,
  `GameBridge.cs:304,1885`; the on-screen effect is derived from the
  renderer code, not observed.)
* **Every argument-taking `mp_*` console command has failed since 0.26.3.**
  The templates are `'KCD2MP_X("%line")'`, and the engine substitutes
  `%line` *with its own quotes* (observed in WO-106 §1.1:
  `PROBE line=["hello world"]`). So `mp_puppet_rate 1000` runs
  `KCD2MP_SetPuppetRate(""1000"")`, which is a Lua syntax error; bare
  commands still work. 38 templates are affected. The "sinking unchanged from
  50 ms to 1000 ms" observation is void unless that session's kcd.log shows
  `NPC-PUPPET-RATE set=1000ms`. (code-verified; the failing call itself was
  not run live, see §1.6.0.)
* **The host owns at most 40 NPCs: the first 40 in engine walk order, not
  the nearest.** The agent truncates the native scan push to 40 names
  (`GameBridge.cs:334,5752`). The Lua rescan then tracks only pushed names
  and untracks everything else (`kdcmp.lua:4313-4321,4386-4392`). The comment
  at `GameBridge.cs:329-331` says the rest "fall back to the live Lua read";
  they do not. Applied to this WO's live entity walk in Troskovice, at most
  14 of 26 and 9 of 19 NPC/horse entities within the 30 m streaming radius
  would be tracked; the pool was the 250 m set, and the owner's 300 m set is
  larger, so the real share is lower. (code-verified cap; the coverage
  estimate is (inconclusive): it assumes the DLL iterator walks in the same
  order as `System.GetEntitiesInSphere`.)
* **Host authority is not sticky.** The relay grants authority to the
  lowest ready id (`ClientHandler.cs:157-170`) and recycles ids in FIFO order
  (`:29,101-127`). A host-agent reconnect therefore hands NPC and damage
  authority to the joiner for the rest of the session. At session start,
  whichever agent connects first is the authority. (code-verified)
* **Identity is sound for authored NPCs. §1.4 answers §1.2.** Name, entity
  id and soul WUID were identical across two loads of one save (74/74). They
  were also identical across two *different playthroughs* (72/72 live;
  offline, 519/519 same-named authored entities share entity id and 64-bit
  GUID between the two saves). Only runtime-spawned event NPCs (caravan,
  brawl) and `SpawnedAnimal_*` get a new entity id and WUID on every load.
  The runbook rule "different wuid for the same name = wrong body" therefore
  holds for authored NPCs. It is a false alarm for event NPCs, whose entity
  id is ≥ 0x70000. (observed)

---

## §1 Predictions — committed 2026-09-22, before the 0.26.4 two-player session

Written before the session so they cannot be fitted afterwards. Scope: both
players on 0.26.4, launched through the launcher, in a town crowd, runbook
followed, nothing else typed unless stated. "Joiner" means the machine
without damage authority (check the `HIT_SENSOR` line, P8).

**§1.6.0 Before the session (zero code, optional, recommended):**

1. Type `mp_entity_id Dude`. If kcd.log shows `[KCD2-MP] Dude id=…`,
   console arguments work and finding R2 is wrong. If it shows a Lua error
   and no id line, R2 holds. In that case enter every numeric command as
   `#KCD2MP_SetPuppetRate("200")`, `#KCD2MP_SetResumeDwell("0")`, and so on.
2. Note which machine logs `[KCD2-MP] HIT_SENSOR on (this client holds NPC
   damage authority)`. That machine is the NPC owner, whoever runs the relay.
3. Optional A/B for R1: partway through the crowd walk, the **owner** types
   `mp_npc_read_native_off` (argless, so it works). Write down the time.

**Numbered predictions (P = my probability):**

| # | prediction | P |
|---|---|---|
| P1 | The runbook verdict comes back as "jitter substantially reduced within the streamed radius" on the joiner, 0.26.4 defaults | **0.35** |
| P1a | …the high-frequency vibration component ("teleporting thousands of times a second") is substantially reduced | 0.70 |
| P1b | …walking streamed NPCs visibly *step*: stand about 2 s, then dash or snap forward (R1) | 0.60 |
| P1c | …P1, given the owner types `mp_npc_read_native_off` before the crowd walk | 0.60 |
| P1d | Clean pass ("jitter gone, no sinking") | 0.05 |
| P2 | Sinking substantially reduced | **0.10** (P(visibly worse, from frozen activity poses) = 0.20) |
| P3 | The two-controllers diagnosis is wrong *as a mechanism*: no meaningful second writer ever existed | **0.20** |
| P3a | Two-controllers is *not the dominant cause* of what the testers call jitter in 0.26.x (single-writer artifacts R1/R3/R6 dominate) | 0.60 |
| P4 | Every joiner `MP-PAUSE … event=pause` line carries `exec=ok` | 0.95 |
| P5 | For authored NPCs (eid < 0x70000), the joiner's `eid=`/`wuid=` on `MP-PAUSE` lines equal the authored constants, e.g. `ttkc_barbora eid=…2F836 wuid=…0007`, `ttkc_woman_10 …2F835/…0123`, `ttkc_man_5 …80D6/…01DC` | 0.95 |
| P6 | With both players in a town, the owner logs `MP-NPCTRACK tracked=` at or below 40 every 15 s, and `MP-NPCSCAN dir=consume verdict=native pushed=40` | 0.90 |
| P7 | NPCs standing next to the players have **no** `NPC-SYNC puppet start <name>` line on the joiner: unsynced, smooth, but in different places on the two screens | 0.80 |
| P8 | The damage authority sits on the non-relay machine at some point in the session (first-connect or reconnect, R4) | 0.30 |
| P9 | On the owner, `WO103-READNATIVE off -- known-answer check failed closed` appears within the first 10 minutes in town, triggered by a running NPC or moving horse, and R1's stepping stops after it | 0.40 |

**Top failure modes, ranked, with the line that identifies each in a
post-session read:**

1. **Stepping from the 2 s snapshot (R1).**
   - Owner: `MP-NPCREAD path=native …` lines (the snapshot is in use), and no
     `WO103-READNATIVE off` line before the complaint.
   - Joiner: `NPC-SYNC packet cadence: moving n=… mean=~1900-2100ms …` (a
     smooth 100 ms stream reads ~100-200 ms).
   - Joiner: `NPC-SYNC anim <npc> -> sprint spd=<large>` followed within
     about 0.2 s by `-> idle`, for NPCs that were only walking.
2. **Coverage gaps (R3).**
   - Owner: `MP-NPCSCAN dir=consume verdict=native pushed=40 resolved=40`
     every 2 s, and `MP-NPCTRACK tracked=40`.
   - Owner agent log: `MP-NPCSCAN dir=native … matched=<M> pushed=40` with
     M > 40.
   - Joiner: a named NPC next to the players with no `NPC-SYNC puppet start`.
3. **Something other than the brain still moves paused bodies.** This is
   the unexplained WO-104 pattern: 148 contentions at about 0.41 m, lever on,
   2026-09-18.
   - Joiner: `MP-AUTHORITY-VIOLATION npc=<n> kind=contention … pause_issued=1 pause_exec=ok`
     (not `kind=relax`).
   - Joiner: `MP-NPCFIGHT npc=<n> n=<≥50> mean_m=<≥0.05>` for a paused name.
   - If most of these are tagged `kind=relax` with `anchor_m` of 3-15 m, the
     WO-107 §4 relax does act under a *moving* stream, even though WO-108
     §5.3's *stationary* hold could not provoke it.
4. **The pause did not take.** The joiner has `MP-PAUSE npc=<n> event=pause … exec=ok`
   but no engine `Node status inconsistency. Can't update suspended node!` for
   that NPC afterwards. That engine line is the only engine-side suspension
   signal available (WO-108 §1).
5. **Role inversion (R4).**
   - `[KCD2-MP] HIT_SENSOR on …` on the machine the testers call the
     joiner, or on the joiner partway through the session.
   - The host's agent log shows `Connected! Assigned id=<n>` a second time,
     with n above the joiner's id.
   - `MP-PAUSE … event=pause` lines in the *host's* kcd.log.
6. **Cull and slot churn snaps.**
   - Joiner: `MP-PAUSE npc=<n> event=cancel why=stream-back-inside-dwell`
     repeating for the same name.
   - Joiner: `NPC-SYNC puppet start <n>` more than once a minute for one name.
   - Owner: frequent `WO1025-CULL re-entry <n>`.
7. **Post-load bookkeeping (R7), only if anyone loads a save.**
   - Joiner: `MP-AUTHORITY-VIOLATION … kind=diverge` within a few seconds of
     a load. This is an artifact.
   - Joiner: `NPC-DEATH <n> died here (by puppet …) -- witnessed alive->dead, announcing (npc_death)`
     right after a joiner load, i.e. a false FATAL sent to the owner.
   - Joiner: `MP-PAUSE … event=cancel` after a load, followed by
     `kind=contention … pause_issued=1` for the same name.
8. **Wrong body.** A joiner `MP-PAUSE … eid=<E>` with E < 0x70000 that
   differs from the authored eid for that name (P5). This is predicted rare
   (1 − P5).

**What would show the two-controllers diagnosis wrong (P3 and P3a).**
Players still report jitter while all of the following hold on the joiner:
- `MP-NPCFIGHT` and `kind=contention` are near zero for paused puppets.
- The packet-cadence line reads about 2 s, or its min/max spread is wide.
- `pause_exec=ok` appears everywhere.

Together those mean the body goes exactly where the mod writes it, and the
jerkiness is in the write sequence itself (R1, R6), not a second writer.
Conversely, sustained `MP-NPCFIGHT` at 5-10 cm per tick on paused puppets
means a second writer survives the suspension.

**Sinking (P2): no log line exists.** Every displacement detector is XY-only
(R14). Sinking can only be judged by eye, with a timestamp and the NPC name.

---

## §2 The ranked list

| # | finding | component | evidence | blast radius | effort | verdict | proposed WO |
|---|---|---|---|---|---|---|---|
| R1 | Host streams NPC position/yaw from the 2 s native-scan snapshot whenever it is "fresh" (≤ 6 s). Moving NPCs update ≤ 0.5 Hz; the joiner holds ~2 s then dashes or snaps. WO-103 §2.3 named this risk and answered a different question (the fallback's cost). The known-answer tolerance `1 + 3·age` m (`kdcmp.lua:4066`) passes every walker. | Lua emitter + agent scan cadence | code-verified; screen effect derived, not observed | every moving streamed NPC, every session since 0.26.0 | S | fix: `readNative` default off, or keep the native path for enumeration only. Today: `mp_npc_read_native_off` on the owner | WO-110 |
| R2 | 38 argument-taking console templates wrap `%line` in quotes, but the engine inserts it already quoted. Any argument becomes `f(""x"")`, a Lua syntax error. Bare commands work. Covers `mp_puppet_rate`, `mp_resume_dwell`, `mp_authority_radius`, `mp_together_params`, `mp_npc_yield` thresholds, `mp_quest_*`, dice, weather. No doc records WO-106 §3.6's post-deploy checklist being run. `Test-WO106ConsolePlaceholder.ps1` checks case, not quoting | Lua console registration (`kdcmp.lua:11490-11641`) | code-verified + observed substitution (WO-106 §1.1) | all numeric field tuning; voids the 50→1000 ms sinking A/B unless `NPC-PUPPET-RATE set=` appears | S | fix (unquoted `%line`, handle nil for bare); extend the static test to forbid `"%line"` | WO-110 |
| R3 | Ownership cap: the native push is truncated to 40 names in iterator order (not by distance), and the rescan tracks only pushed names. The comment at `GameBridge.cs:329-331` is wrong. The only recorded tracked counts (78-457, WO-103 §5.1, `path=lua`) exceed any push cap, so they came from the sphere-walk fallback; the cap has no live record | agent + Lua rescan | code-verified; coverage estimate (inconclusive) | roughly half the NPCs inside the streaming radius are never streamed or paused (desync, not jitter) | S (sort by distance first) / M (chunk the push) | fix | WO-110 |
| R4 | Authority = lowest ready relay id, and ids are recycled FIFO. A host reconnect makes the joiner the owner for the rest of the session; first connect decides at start. (`ClientHandler.cs:29,101-127,157-170`). The Ack is also queued after the session is marked ready, so a broadcast can precede it and make the agent drop the connection (`ClientSession.cs:124-142`, `GameBridge.cs:1247-1260`) | relay | code-verified; frequency (inconclusive) | NPC ownership, pause side, damage rule, weather silently invert; the runbook reads backwards | S-M | fix: a sticky owner (relay-local client, or reuse the lowest free id); queue the Ack before marking ready | WO-111 |
| R5 | Identity layer: the wire keys on authored entity names only. Names, entity ids and WUIDs are deterministic across loads and across playthroughs for authored NPCs. Event spawns change ids and WUIDs every load. One duplicate authored name exists map-wide. The host logs no identity on `MP-AUTHORITY … acquire` (`kdcmp.lua:3171,4383`) | Lua + wire | observed (§1.4) + code-verified | post-session diagnosis only | S | keep name keying; log `wuid`/`eid` on the host's acquire line; amend the runbook rule for eid ≥ 0x70000 | WO-110 |
| R6 | The receiver renders by *arrival* time: 0x26/0x27 carry no timestamp or sequence. Samples are stamped at the Lua batch apply (`kdcmp.lua:5309`). The render delay is 120 ms. Arrivals are quantized by the agent loop: `Task.Delay(10)` + a frame-bound native read + an ExecuteString flush (`GameBridge.cs:1844,1920,1926`), 2 s scan stalls on the shared pipe, and Nagle (NoDelay never set). Inline and main-loop flushes can be in flight at once, unordered | Lua renderer + agent + wire | code-verified; magnitude (inconclusive) | residual micro-jitter on every streamed NPC; the burst case is untested (`Test-NpcSmoothSynthetic.lua:197-233` skips same-stamp bursts) | S (pass the agent's receive time into `ApplyNpcState`) / M (seq+ms in 0x26, protocol v7) | measure first (cadence min/max), then fix | WO-112 |
| R7 | Save-load leaves Lua acting on stale bookkeeping. (a) `_npcDeathSeen` is never reset, so an NPC dead in the loaded save is announced as a fresh death and killed on the peer (`kdcmp.lua:2745-2779`). (b) The dwell-cancel path assumes the engine bit survived, so an NPC in its dwell during a load ends up believed paused but active: the WO-104 misread shape (`3264-3271`, `3365`). (c) Stale `lastWroteX` produces a false `kind=diverge` plus a toast (`5689-5811`, `3462`) | Lua | code-verified | cross-machine NPC deaths from one player's reload; misleading violation counts | S | fix (clear on the confirmed-dead restart stamp) | WO-111 |
| R8 | Engine suspend state is unreadable. `pause_exec`, `paused_npcs=`, `auth_paused_now` and `pause_issued` are all Lua bookkeeping (`kdcmp.lua:3128,3200-3203`) | Lua + DLL | code-verified | every conclusion about the lever | M | move native: read `C_IntelligentObject+0x128/+0x129` (WO-107 §3.2). Until then, grep the engine's `Can't update suspended node!` | WO-113 |
| R9 | Exact-length checks on nearly every type in the relay and the client. Drops are silent with no counter. The release version is never enforced: 0.26.3 and 0.26.4 connect silently, and only the launcher compares, for the first peer, within 5 minutes | relay + agent | code-verified | the next wire extension (e.g. R6's timestamps) repeats 0.23.1 silently in a mixed session | S | fix before any wire change: drop counters, a protocol bump, relay refusal on a release mismatch | WO-112 |
| R10 | The release gate runs 4 suites only: relay round-trip, agent unit, WO-102, WO-104 (`Build-Installer.ps1:72-91`). Never gated: WO-108's own suite, WO-86, WO-99, NpcSmooth, GhostInterp, WO-106 static, and WO-90, which is failing. The merged publish folder (flat copy; later projects overwrite shared DLLs, `Publish-Release.ps1:70-80`) is never executed by any gate | build pipeline | code-verified | regressions ship; the WO-90 failure sat unnoticed as "pre-existing" | S | fix: run every `Test-*Synthetic.ps1`, fix the WO-90 mock, and add a smoke run of the published agent/relay from the payload folder | WO-110 |
| R11 | Disconnect cleanup is queued, not sent. `KCD2MP_RemoveAllGhosts()` and `KCD2MP_Wo102ResumeAll` go into the batch in the `finally` (`GameBridge.cs:1996-2002`), which is flushed only by the next connected main loop or a clean dispose. They are never sent on a kill (the launcher's stop path) or a crash. WO-108 §5.4's "code-verified (call site present)" row is not the thing happening | agent | code-verified | the peer's ghost stays frozen after a relay drop; NPC resume relies on Lua's silence path (which works) | S | fix (`ExecuteNowAsync`) | WO-111 |
| R12 | Pipe hardening. A late reply after a 5 s timeout can be taken as the next command's answer, since the seq is not advanced (`CombatPipe.cs:486-521`). Agent and DLL deadlines are both 5 s. Two handlers capture stack locals by reference (`pipe_server.cpp:473,501`). The DLL never replies to an unknown command. A faulted task replies default-OK (`T value{}` + SEH swallow): an empty scan would untrack everything | agent + DLL | code-verified; frequency (inconclusive), windows open during ≥ 5 s main-thread stalls, i.e. loads | wrong results after loads; a rare corrupt stack slot | M | fix (advance the seq on timeout, DLL deadline < agent's, capture by value, reply to unknown, explicit fault codes) | WO-113 |
| R13 | The joiner runs the native NPC scan every 2 s for nothing: there is no authority gate (`GameBridge.cs:1885,5709`), and a non-authority's Lua never consumes the push. That is a main-thread entity walk, plus a pipe hold that delays the joiner's flush of inbound NPC packets | agent | code-verified; cost unmeasured | periodic delivery hiccup on the machine that renders puppets | S | fix (gate on authority) | WO-110 |
| R14 | No Z telemetry. The fight, violation and yield detectors are XY-only (`kdcmp.lua:5693-5711`). The smooth renderer takes Z from the newer sample while XY interpolates (`p.cz = b.z`, `2574`), a small rate-independent downhill sink / uphill float. The WO-105 collider-release mechanism is **not** refuted, because the rate A/B may never have run (R2) | Lua | code-verified | every sinking report is unfalsifiable from logs | S | measure first: log readback-vs-written Z per puppet (throttled); re-run the rate A/B with the `#` form | WO-112 |
| R15 | Name handling. Peer names are logged raw into kcd.log, and the tail matches `[KCD2-MP-EVT]` anywhere in a line, so a name can forge events such as NPC deaths (`LogTailGameTransport.cs:600-605`). `EscapeLua` escapes only `\` and `"`, so a newline breaks whole batches. The inbound exclusion is case-sensitive while `GetEntityByName` is not (`kdcmp.lua:3709-3717`) | relay + agent + Lua | code-verified | griefing or a stall; needs an odd or malicious peer name | S | fix: sanitize at the relay handshake, anchor the tag, case-fold the exclusion | WO-111 |

Not ranked, closed or noted: the WO-90 failure (§2.9), the relay gate flake
(§4.6), six orphaned Lua helpers (§2.6), Lua's 200-locals cliff (§5.1), the
relay's 512-entry queue under a bigger radius (§4.3).

---

## Phase 1 — will the 0.26.4 jitter fix work?

### 1.1 The joiner path, end to end

| step | function | file:line | what can go wrong |
|---|---|---|---|
| owner picks NPCs | `mp_npc_rescan` (every 2 s) | `kdcmp.lua:4258` | only pushed names count, ≤ 40 in walk order (R3). The name gate `^[%w_]+$` drops names like `horse[animalcare/…]` (observed in §1.4) (code-verified) |
| owner reads the NPC | `KCD2MP_NpcSyncTick` (100 ms) | `4595-4625` | position is the 2 s snapshot (R1); every tracked NPC, culled ones included, gets ~6 bind calls per tick (§3) (code-verified) |
| owner culls | same | `4689-4700` | cull distance is measured to anchors captured at the last 2 s rescan (`_lastAnchors`, `4296`), so boundary NPCs flip in 2 s steps (code-verified) |
| owner emits | `KCD2MP_EmitEvent("npc_state")` | `4725-4727` | `%.3f`/`%.4f`/`%.1f`/`%d`; format is safe (code-verified) |
| owner agent → relay | tail poll ≤ 5 ms → `SendNpcStateAsync` → 0x26 | `LogTailGameTransport.cs:568`, `GameBridge.cs:5025-5053,3724` | fire-and-forget send; `NpcStateOut` counts handed-off events, not sent packets (code-verified) |
| relay → joiner | route + fan-out as 0x27 | `ClientSession.cs:318`, `TcpBroadcastService.cs:129-133` | exact nameLen check, silent drop; per-client queue of 512 → disconnect (code-verified) |
| joiner receive | `ReceiveLoopAsync` 0x27 | `GameBridge.cs:4239-4341` | name regex; `ExecLuaAsync` only enqueues, but a full batch (4000 chars) flushes inline and stalls the loop; death and swing paths await the DLL inline (code-verified) |
| joiner → Lua | main-loop `FlushAsync` | `GameBridge.cs:1920` | an 800 ms timeout drops the whole batch silently; it may still run late (code-verified) |
| name → body | `KCD2MP_NpcBody` → `System.GetEntityByName` | `kdcmp.lua:4884-4895` | first match, case-insensitive (WO-105 entry 10); sound for authored NPCs (observed, §1.4) |
| puppet created | `KCD2MP_ApplyNpcState` | `5219-5243` | ring seeded at the local body; arrival-time stamp (R6); a first sample > 5 m away snaps (code-verified) |
| pause issued | `mp_wo102_pause` → `System.ExecuteCommand("wh_ai_PauseNPC <name>")` | `3249-3281` | refused on the authority; `exec` is only the pcall verdict (R8); the engine resolves the name with the same by-name index (WO-102 findings) (code-verified) |
| writes applied | `KCD2MP_NpcPuppetTick` (50 ms) | `5930-5932` | one table per write; no writes during `oneShotUntil` (0.9-2.5 s in combat, `7640,7686,7701`) (code-verified) |
| stream stops | silence > `releaseS` = 3 s | `5505-5511` | idle heartbeat is 2 s, so ~1 s of delivery slack; a host menu stops every stream (code-verified) |
| dwell | `mp_wo102_release` → `_npcResumePending` | `3301-3309` | a stream back inside 10 s cancels; after a load the cancel is wrong (R7b) (code-verified) |
| resume | `mp_wo102_pending_tick` → `mp_wo102_resume` | `3318-3329,3284-3293` | runs only inside the joiner's `KCD2MP_NpcSyncTick`, which the agent re-arms only if `npcSync.enabled` (`GameBridge.cs:1682`) (code-verified) |

### 1.2 Identity — what the mod keys on

* **On the wire:** the NPC's entity name, nothing else. 0x26/0x27 carry
  `[nameLen][name][x][y][z][rotZ][hp][flags]`, plus a source id on 0x27.
  0x30/0x31 damage is name-addressed too. `npcid` is agent-local only.
  (code-verified: `NpcStateCodec.cs`, `Protocol.cs:1047`)
* **Receiver mapping:** `System.GetEntityByName(name)`: first match,
  case-insensitive, class-agnostic. The engine's `wh_ai_PauseNPC` resolves
  through the same by-name index. (code-verified here; engine side per WO-102
  / WO-105 entry 10)
* **Duplicates:** zero among the 80 NPC/horse entities within 250 m at both
  probe spots, and `GetEntityByName` returned the walked entity for all 80.
  Across the whole map (the 456 NPC/NPC_Female/Horse entities a 20 km sphere
  returned) there is exactly one duplicate authored name,
  `tbuk_neoznaceneHroby_man_1` (2 entities). Both saves' entity records show
  the same pair, and the lookup returns the second record (eid 0x7C1F).
  (observed)
* **Stable across two machines:**
  - Authored NPCs: name, entity id and WUID are the same across loads and
    across playthroughs, i.e. two different saves (observed, §1.4).
  - Nothing guarantees it on another *game build*; each release re-verifies.
  - Runtime event spawns keep their *name*, but get a new entity id and
    WUID every load (observed). On two machines the same event-NPC name may
    be a different individual, or absent.
  - Absent is safe: the stream is ignored.
* **The known gap, confirmed:** `mp_auth_log` (`kdcmp.lua:3164-3175`)
  prints `npc/event/owner/via/held_s/model` and no identity. The host's
  acquire call sits at `4383`. **To make a cross-machine diff possible:**
  - The owner should log `mp_pause_identity(name)`'s `wuid/eid/body`
    tuple on `acquire` and on its first emit per name.
  - Until then, compare the joiner's `eid=` against the owner's save
    offline. Authored entity ids are stored in the `.whs` next to the name;
    this WO's parse script is in the session scratchpad and the method is in
    the progress doc.

### 1.3 Everything else that can move a streamed NPC's body on the joiner

| path | where | fires on a suspended, streamed NPC? |
|---|---|---|
| puppet tick write | `kdcmp.lua:5930-5932` | yes, it is the intended writer (code-verified) |
| corpse one-shot follow | `5642-5651` | only if the *stream* says dead/KO (code-verified) |
| carried follow | `5625-5641` | only if the stream says dead/KO and carried (code-verified) |
| resync snap | `5166-5200` | no. Only with no puppet for the name; it can hit a released NPC in its dwell (code-verified) |
| replica swap | `4908-5035` | no, off since 0.26.4 (code-verified) |
| drag sensor | `4408` | no. The non-authority returns first under host authority, `4541` (code-verified) |
| ghost interp / horse transforms | `8540`, `7112` | no, unless a ghost or adopted horse shares the name. Adopted horses are skipped at `5157`; a horse adopted while already a puppet gets ≤ 3 s of two writers (code-verified) |
| swing, takedown cues, native swing | `7629-7704`; DLL | animation only; they *stop* writes for 0.9-2.5 s. Whether a Mannequin action applies root motion to a suspended body: (inconclusive) |
| locomotion loops | `5985` | animation; root motion (inconclusive) |
| WO-107 §4 relax | engine | observed after writes stop; not provoked under a stationary 100 ms stream (WO-108 §5.3); under a moving stream or in combat write gaps (inconclusive), see failure mode 3 |
| physics after each write | engine | stock releases the ground collider and sets flying on any > 1 % capsule move (WO-105 entry 7). KCD2: (inconclusive) |
| player/ghost collision push | engine | a suspended NPC cannot step aside; is a living-vs-living push applied? (inconclusive) — relevant to "walk into a crowd" |
| dialogue with a suspended NPC | engine | the dialogue system may orient or position it (inconclusive) |
| quest scripts (F11/F12 catch-up) | engine | scripted teleports are direct writes, so yes if a fired beat moves the NPC (inconclusive, rare) |
| move request in flight at suspension | engine | ≤ ~1 m tail within 10 s of the pause (observed, WO-108 §2) |

### 1.4 The determinism probe (the one live read)

Method: the Modding Tools build launched as the launcher does it, the 0.26.4
pak loaded, no agent. Console transport per WO-106 §2. For every NPC,
NPC_Female and Horse entity within 250 m of the player, the probe logged
name · class · entity id · `soul:GetId()` WUID · position · distance ·
same-name entity count (any class) · whether `GetEntityByName(name)` returns
that entity.

Runs:
- `pl1-a`: `wh_sys_LoadGame 1 quicksave023` from the menu.
- `pl1-b`: the same command again, in-process ("Quick-loading … ignoring delay").
- `pl2-a`: `wh_sys_LoadGame 2 save021`, a *different playthrough* in the
  same village, 25 m from the pl1 spot.

| comparison | common names | same class | same entity id | same WUID | differs |
|---|---|---|---|---|---|
| pl1-a vs pl1-b (same save, 2 loads) | 80 | 80 | 74 | 74 | 6, all runtime event spawns: `karavanyVeSvete_*` ×3, `rvacka_apprentice_1..3`; eid 0x7FFDx→0x7FE9x, WUID 0x5Dx→0x61x (observed) |
| pl1 vs pl2 (different playthroughs) | 72 | 72 | 72 | 72 | none (observed) |
| offline: `.whs` entity records, same two saves | 564 | — | 519 | — | 45, all `SpawnedAnimal_*` (observed; entity id and 64-bit entity GUID parsed from the save) |

* WO-108's live eids match the stored ones byte for byte: `ttkc_barbora` =
  `0x2F836`, `ttkc_woman_10` = `0x2F835`, `ttkc_woman_2` = `0x2472`.
  (observed)
* WUIDs are **not** in the save (no LE u64 hit in either file). They are
  assigned at load, deterministically for authored souls. Two other process
  lifetimes logged the same values: WO-108 (2026-09-21, `MP-PAUSE` lines)
  and WO-106 §1.4 (2026-09-19). (observed)
* Correction to the prompt: a same-save identity test *had* been run once
  (`docs/NATIVE-PLUGIN-findings.md` §3, soul Guid / SharedSoulGuid). It
  covered neither WUIDs nor entity ids. The soul Guid history also shows why
  same-save stability alone proves nothing: it was stable across restarts
  and unstable across installs (WO-40). Hence the cross-playthrough run.
* Verdict: **§1.2 matters less than feared.** The identity layer works for
  authored NPCs across machines on the same build. It is inherently loose
  only for event spawns, where a missing name is the safe case.

### 1.5 Sinking — does anything in code explain it?

* **Ground collider:** every puppet write is `e:SetWorldPos({…})` with no
  flags. No Lua bind passes `bRecalcBounds` bit 32 (WO-105 §17.1), and the
  DLL has no transform-write path at all. So on stock semantics every move
  over ~1 % of capsule height releases the collider. Only one writer exists
  per path; `5930` is the one that matters. (code-verified)
* **Z without ground reconciliation:** yes, by design (WO-63 dropped the
  floor raycast).
  - The smooth renderer interpolates XY but sets `p.cz = b.z`, the *newer*
    sample (`2572-2575`). While moving, Z leads XY by up to one segment.
  - That is ≤ slope × 0.14 m at a 100 ms walk, and up to a step height on
    stairs: a small, rate-independent downhill sink and uphill float.
    (code-verified)
  - Corpse and carry follows write stream Z directly. (code-verified)
* **Combat vs non-combat:**
  - Combat inserts write gaps (`oneShotUntil`) of 0.9-2.5 s, during which
    anything else (relax, physics, animation root motion) owns the body.
  - A drawn weapon swaps the idle loop for a combat-guard CAF.
  - No Z difference between the two. (code-verified)
* **The premise:** "sinking survived 50 ms → 1000 ms" is exactly what R2
  predicts if the rate was set with `mp_puppet_rate <ms>`: the command never
  ran. (inconclusive until that session's kcd.log is checked for
  `NPC-PUPPET-RATE set=`)
  - If the A/B did run (the `#` form), rate independence argues against
    WO-105 entry 7 as the cause, and points to a static pose/state mismatch.
  - That mismatch would be an activity pose (sit, kneel, work) held while
    the stream places the entity at walking height, or a raw
    `StartAnimation` loop that does not override a Mannequin activity
    fragment.
  - 0.26.4's suspension freezes whatever pose the NPC had when paused, so P2
    stays low.
* **Instrument first (R14):** readback Z vs written Z per puppet, throttled.
  Without it, no sinking hypothesis can be tested from logs.

---

## Phase 2 — what is wrong (by bug class)

2.1 **Numeric precision / formatting.**
- Every event payload uses `%.Nf`, `%.0f` or `%d` on small flag sums; no
  parsed field uses `tostring` (code-verified).
- The agent formats with InvariantCulture and F3/F4 throughout, so it never
  emits an exponent or a comma decimal, and the native CSV pattern cannot
  drop an NPC (code-verified).
- No `GetFlags` read-modify-write exists (code-verified).
- World time still crosses the float bridge as a number:
  `%.0f` fixed the text, not the precision (`kdcmp.lua:939-977`), and the
  REST Calendar `GameTime` read in this probe was 15,486,516, 8 % under
  2^24 (observed). Its only reader, `HttpGameTransport.IsGameReadyAsync`,
  tests `> 0`, so the precision loss past 2^24 is harmless (code-verified).
- `mp_set_no_save`'s return is ignored at all 8 call sites (code-verified).

2.2 **String formatting and case.** R15. The console-quoting bug R2 is this
class's live instance: the fix for the `%LINE` typo re-broke the same
commands one layer down.

2.3 **Error swallowing that reports success.**
- `HttpGameTransport.FlushAsync` drops a batch on any failure, and one
  syntax error fails the whole batch before any per-statement `pcall` runs
  (`HttpGameTransport.cs:210-220`).
- `KCD2MP_QuestFire` marks the beat used and toasts success whatever
  `ExecuteCommand` did (`kdcmp.lua:12850-12865`).
- The NPC death dedupe is stamped before the apply, so a failed `ApplyDeath`
  blocks the second route for 60 s (`GameBridge.cs:3265-3268`).
- DLL tasks that fault reply default-OK (R12).
- `IsInDialog` guards default to "not in dialogue" silently (`kdcmp.lua:4193,4669,4931,5179`).

(all code-verified)

2.4 **Metrics that do not measure their name.**
- `WO102-STATUS paused_npcs=` and `MP-SUMMARY-MOD auth_paused_now` count the
  Lua table. WO-108 fixed the violation line only (`kdcmp.lua:3124-3128`).
- The cadence line hard-codes "apply tick is 50ms" and prints the
  *receiver's* `emitMs` as "emitter is" (`5462-5469`).
- A status line says "interp tick=50ms"; it runs at 20 ms (`9170` vs `7091`).
- `hasSoul`/`hasHuman`/`IsMounted` print `pcall`'s success flag (`11034-11036`).
- `NpcStateOut` counts hand-offs, not packets (`GameBridge.cs:5053`).
- A comment claims replicas ship on (`GameBridge.cs:4851`).

(all code-verified)

2.5 **Timer / chain liveness.**
- The agent re-arms the emit, interp, label, item and NPC-sync chains, the
  last only if `npcSync.enabled` (`GameBridge.cs:1675-1690`).
- The puppet chain restarts only on a packet (`kdcmp.lua:5359`).
- Dwell resumes and the reconcile live only in `KCD2MP_NpcSyncTick`. With
  `mp_npc_sync off` plus a load, a pending resume can never fire until
  `mp_resume_all` (not default; code-verified).

2.6 **Orphans.** Nothing is orphaned on the wire: every Up/Down type has a
handler, all 69 agent-called `KCD2MP_*` exist, and all 30 event names are
handled (code-verified, two independent sweeps). Six unreferenced Lua
helpers (dice seat checks, ghost audit, riding probes, `kdcmp.lua:2024,
2053,6092,9692,10598,10640`) are dead code with no effect.

2.7 **Save/load.** R7 (a/b/c). Also: the item-sync reload heuristic treats
"a ghost is alive" as "no reload", so a duplicate drop is possible
(`kdcmp.lua:11130-11139`) (inconclusive race).

2.8 **Other silent ones.**
- R11 (unflushed disconnect cleanup).
- R12 (pipe).
- R13 (joiner scan).
- While disconnected, `aggro_toggle`, `npc_deathsync`, `authority_radius`
  and `wo102_toggle` events are dropped (`GameBridge.cs:4856`), and the
  2.5 s re-arm then overwrites Lua's console state for the three pushed
  toggles (code-verified).

2.9 **Known open item — `Test-WO90Synthetic.ps1` "(i): no swallowed Lua
errors": CLOSED, harness mock gap.**
- The mock entity (`Test-WO90Synthetic.lua:108-137`) has no `SetFlags`.
  WO-106 added `mp_set_no_save`'s `e:SetFlags(...)` and patched only the
  WO-104 harness.
- The error is `attempt to call a nil value`, at the assembled script's line
  mapping to `kdcmp.lua:222`.
- Run in a scratch copy: 69/70 as shipped, 70/70 with a one-line stub.
  (observed, harness run; not a mod bug)
- It stayed hidden because WO-90 is not in the release gate (R10).

2.10 **Known open item — the relay gate flake: CLOSED, load flake (§4.6).**

---

## Phase 3 — Lua vs C++

Start point: WO-106 Phase 6. Dispatch is thin, so reach, measured cost,
correctness and observability are the only reasons to move code.

| candidate | reasons that apply | expected gain | cost | verdict |
|---|---|---|---|---|
| puppet write with `bRecalcBounds` bit 32 / xform flags | reach | the sinking fix *if* WO-105 entry 7 is the cause; unproven and possibly refuted (R14) (inconclusive) | new DLL write path; hooks the entity transform per puppet per tick; untestable in MoonSharp; patch-fragile | **measure first**: Z telemetry plus a valid rate A/B (R2's `#` form) before any native write |
| engine suspend-state read (`+0x128/+0x129`) | observability (4) | makes `pause_exec` a real `paused`; closes the WO-104 misread class | entity → intelligent-object path to find (RE, M); fail-closed vptr check; 1 pipe call per paused NPC per 5 s reconcile | **move** (R8) |
| native NPC position read (`readNative`, exists) | frequency×cost claimed, not measured | WO-103 §2.4: "small or even negligible" (its words); as built it *harms* (R1) | already built | **don't move**: turn it off; the Lua read is two binds on an entity already in hand |
| NPC state reads (hp/dead/KO/drawn), WO-103.5 | frequency×cost | measured ~1.5 ms per 100 ms at 78 tracked, ~7 ms at 450 (WO-103 §5.1, observed); R3 currently bounds tracked at ≤ 40 | offsets unmapped; untestable in MoonSharp | **don't move**; first reorder in Lua (skip culled NPCs' state reads) and measure `MP-NPCREAD` |
| native NPC scan (enumeration, exists) | reach (engine iterator), cost | kills the per-anchor sphere walk | exists | **keep**; fix the push (R3); gate it to the authority (R13) |
| puppet renderer / tick | none | Lua cost unmeasured; the problem is stamping (R6), not language | — | **don't move** |
| receiver timestamping | correctness (3) | removes arrival-time jitter | agent + protocol change, no native | **don't move** (it is not a native question) |
| **inverse:** policy in C++/C# | — | tuning without a rebuild | small | **move to config/Lua:** the 40-name cap and its ordering (C#, `GameBridge.cs:334`); the native class filter NPC/NPC_Female/Horse and `kMaxNameLen=59` (`npc_scan.cpp:36,203-206`); the 0.5 hp damage-noise floor (`GameBridge.cs:1421`) |

"Nothing else is worth moving" is the honest remainder.

---

## Phase 4 — the relay

### 4.1 Protocol

- Frames are `[type][len u16 LE][payload]`, read fully, so a bad frame never
  desyncs. Unknown types and wrong lengths are consumed and dropped with no
  log or counter (`ClientSession.cs:576-586`; client `GameBridge.cs:4555-4562`).
- Exact-length (`==`) checks: about 14 whole-payload checks and 7 inner
  length fields on the relay, the same on the client (0x27 at
  `GameBridge.cs:4249`). Only session packets use `>=` and log. Each is a
  0.23.1 sibling for the next extension (R9).
- A mid-body stall blocks forever; only the header wait is timed. (all
  code-verified)

### 4.2 Mixed versions

- The relay refuses any protocol version ≠ 6 (`ClientSession.cs:98-105`).
- The release string is logged, forwarded (0x1E) and shown by the launcher
  for the *first* peer, and only within 5 minutes of agent start. It is
  enforced nowhere. So 0.26.3 + 0.26.4 connect silently, and 0.26.3's pause
  lever stays off on its side. (code-verified)
- The runbook's "no test" is advice, not a gate.

### 4.3 Bandwidth

**Frame sizes.**
- Up = 25 + L bytes, Down = 26 + L (`NpcStateCodec.cs`).
- The mean name length in this probe is L = 13.9 (observed, 80 names), so
  **Up ≈ 39 B and Down ≈ 40 B**.
- TCP/IP adds ≤ 40 B per segment. That doubles the figures at one frame per
  segment; Nagle normally coalesces.

**Per NPC, down to each other client (fan-out n−1 = 1 for two players):**
- Moving at 10 Hz: 400 B/s.
- Idle at 0.5 Hz: 20 B/s.
- Moving under today's `readNative` (R1): ~20-40 B/s.

**Mix.** 14/46 were moving (WO-108 §2, observed) → ~30 % moving →
**~134 B/s per streamed NPC**, or 3.35 frames/s.

| streaming radius | NPCs, uniform from WO-108's 46 @ 60 m | typical B/s | all-moving B/s | NPCs, measured (Troskovice, 2 spots) | typical B/s | frames/s typical |
|---|---|---|---|---|---|---|
| 30 m (today) | 12 | 1.5 K | 4.5 K | 19-26 | 2.5-3.5 K | 64-87 |
| 60 m | 46 | 6.0 K | 18 K | 45-48 | 6.0-6.4 K | 151-161 |
| 100 m | 128 | 16.7 K | 50 K | 57-60 | 7.6-8.0 K | 191-201 |
| 150 m | 288 | 37.6 K | 112 K | 67-76 | 9.0-10.2 K | 224-255 |

Arithmetic: typical = N × (0.3 × 400 + 0.7 × 20). All-moving = N × 400.
Measured counts are observed NPC/NPC_Female/Horse entities with conforming
names (§1.4 runs).

**Verdict: the relay is not the first wall.** Even the dense-town upper
bound at 150 m, all moving, is ~112 KB/s (~0.9 Mbit/s). The walls, in order:

1. **R3's 40-name cap.** Streamed = tracked (≤ 40) ∩ radius. Raising the
   cull radius adds little until R3 is fixed. (code-verified)
2. **The joiner's Lua ingress** (code-verified mechanism; timing
   (inconclusive)).
   - Each `ApplyNpcState` statement is ~110 chars + 32 accounted, so ~28 fit
     in the 4000-char batch.
   - One batch goes per main-loop pass (~50-90 ms with `posNative`), plus
     inline flushes from the receive loop when a batch fills.
   - Estimated ceiling: ~0.3-1.5 k statements/s.
   - The dense bound at 150 m all-moving (2,875 frames/s) exceeds it.
     Backlog then fills the socket buffers and the relay's 512-entry
     per-client queue, which **disconnects** the joiner
     (`ClientSession.cs:23,1047-1104`).
   - If ExecuteString cannot complete during a loading screen, each flush
     waits the full 800 ms timeout (~33 statements/s), and even the 60 m case
     backs up (inconclusive: whether ExecuteString blocks during loads is not
     measured).
3. **The joiner's puppet tick:** N × 20 Hz × ~8 binds. Unmeasured; the
   host's analogous read loop costs ~1.5 ms/100 ms at 78 (WO-103 §5.1)
   (inconclusive).

### 4.4 Reliability and ordering

- One FIFO queue per receiver, single writer. Order is preserved except:
  - a coalesced Ghost packet keeps its old slot, so the newest position
    overtakes later packets;
  - broadcasts can precede the Ack (R4).

  (code-verified)
- Must-arrive messages sent once with no retry: 0x30/0x31 hits and FATAL,
  0x14, 0x21, 0x23, TimeSkip start/done, item claims, NpcRequest, CombatRole.
  They are lost only on a disconnect (TCP), including the §4.3 overflow
  disconnect, or on a relay-side drop (§4.1).
- Self-healing by heartbeat: position, NPC state (the dead bit rides every
  heartbeat), appearance, weather.
- **Pause and resume are not wire messages.** They follow stream silence on
  the joiner, so neither a "dropped release" nor a "reordered pause/resume"
  can happen on the wire. The live risks:
  - a false release from a ≥ ~1 s delivery stall on idle NPCs (2 s
    heartbeat vs 3 s release);
  - out-of-order Lua batches when an inline flush and a main-loop flush are
    in flight together (R6).

  (code-verified)

### 4.5 Clock skew

- ClockSync (0x39/0x3A) is NTP-style, the median of 15 samples. It feeds
  only `MP-CLOCK`, a per-line log stamp and the Lua ping display. Nothing
  aligns gameplay, and no NPC packet carries a sender time. (code-verified)
- Should it align? **Not wall clocks for gameplay.** WO-95 (Group C) found
  nothing in the mod schedules a cutscene.
- **Use it where it matters:**
  - subtract `MP-CLOCK`'s offset in every cross-machine log comparison;
  - map sender-relative sample times if R6 adds them.
- **Caution, from WO-95's own numbers (inconclusive):**
  - The corrected cutscene offsets (+0.81 s and −0.81 s) equal the 0.80 s
    skew in magnitude.
  - `socky_2_gate`'s *raw* difference is therefore ≈ 0 s, and
    `zachrana_prespani`'s ≈ 1.6 s.
  - Re-derive both from raw logs with the `MP-CLOCK` estimate before 0.8 s
    is treated as a gameplay constant.

### 4.6 The flaky gate — flake (load)

- `Combat_event_round_trips_in_both_lengths`: 5 s Ack read, 100 ms settle,
  5 s `ReadUntilAsync` (`RelayRoundTripTests.cs:118,186,199,422`).
- The relay path is synchronous and unthrottled, and both lengths are
  accepted (`ClientSession.cs:444-453`). A timeout needs a ≥ 5 s in-process
  stall, which fits the fresh-clone build beside a 7.5 GB game.
  (code-verified path; cause (inconclusive))
- The harness's one real race (broadcast-before-Ack) would fail the Ack
  assertion, not time out.
- **No code change warranted.** Keep re-running, never bypass.

### 4.7 Improvements, by payoff

| improvement | payoff | effort |
|---|---|---|
| sticky owner + Ack before ready (R4) | ends silent role inversion and intermittent failed joins | S-M |
| per-type drop counters + one `MP-RELAY-DROPS` line every 60 s + release-version refusal (R9) | the next 0.23.1 is loud, not invisible | S |
| `TCP_NODELAY` on both ends | removes coalescing delay from 40-byte frames (payoff (inconclusive)) | S |
| sender seq + ms on 0x26/0x27, protocol v7 (R6) | real snapshot interpolation; loss/reorder visible | M |
| per-client queue sized in bytes with a stale-NPC-state drop policy (drop old 0x27 for a name before disconnecting) | a slow joiner degrades instead of disconnecting | M |

---

## Phase 5 — structure

5.1 **`kdcmp.lua` as one 13,109-line file: real problems, not fashion.**
- **Load-order locals.** A file-level `local` is invisible above its
  definition. The code carries workarounds for it: `kdcmp.lua:2434-2436`
  (functions moved because `mp_auth_log` is defined later) and
  `5915-5917` (`getFloorZ` "would bind to a nil global"). (code-verified)
- **A hard compile cliff.** The main chunk declares **180 top-level locals**
  (counted from column-0 `local` names). Stock Lua 5.1 caps a function at 200
  (`LUAI_MAXVARS`). Twenty more top-level locals and the mod fails to compile
  in-game. MoonSharp, which every synthetic suite uses, does not enforce the
  cap, so no gate would see it. (code-verified count; the fork's limit:
  (inconclusive))
  - Upvalues are fine: at most ~16 per function, against a limit of 60.
  - Mitigation: fold scratch tables and constants into a few tables. S.
- **Whole-file harness coupling.** Every suite loads the whole file with
  hand-written stubs. One new engine call anywhere (WO-106's `SetFlags`)
  silently broke an ungated suite (§2.9). (observed)
- Merge and review risk is real but secondary. `loadfile` makes live
  testing possible, since the file exceeds the ExecuteString budget.
- **Verdict:** don't split yet. Fix the 200-local cliff and gate every suite
  (R10) first; both are S.

5.2 **High-blast paths with no test at all.**
- `CombatPipe` (including the precedent stale-reply bug).
- Batching, flush order and timeouts.
- Log-tail parsing (including R15).
- Main-loop cadence.
- The disconnect path (R11).
- `EscapeLua`.
- The relay under load or with more than two peers.
- The merged release payload.
- The DLL.
- The renderer under bursty, same-stamp arrivals (R6).
- The console argument path: its static test checks case only (R2).

(code-verified)

5.3 **Pipeline fragility beyond WO-106/WO-108's list.**
- R10 (ungated suites; the unexecuted merged payload).
- `KCDMP.dll` is built only if missing (`Publish-Release.ps1:97-100`). Only
  the fresh-clone discipline prevents a stale DLL. There is no DLL/agent
  version handshake.
- The version is sourced twice (`-Version` and `VERSION`), and the `.iss`
  falls back to `0.0.0` (`KCDMP.iss:17`).
- `-SkipPublish` skips every gate yet still stamps a new pak.

(code-verified)

---

## Appendix A — Phase 0 map

**Components**

| component | language | lines | owns | talks to | boundary |
|---|---|---|---|---|---|
| mod (`kdcmp.lua`) | Lua 5.1 | 13,109 | all game-side logic: emitters, puppets, ghosts, pause lever, quests, items, dice | agent | kcd.log lines out; ExecuteString in |
| agent (`KcdMp.Client`) | C# .NET 8 | 12,695 | wire I/O, batching, native reads, damage routing, time/weather/quest arbitration | mod, DLL, relay, launcher | log tail · HTTP :1403 · named pipe · TCP · local IPC |
| relay (`KcdMp.Server`) | C# .NET 8 | 3,496 | sessions, fan-out, claim table, authority = lowest id, clock sync replies | agents, master | TCP (default 7778) · HTTP announce |
| protocol (`KcdMp.Protocol`) | C# | 1,952 | message types, lengths, v6 | agent + relay | shared assembly |
| native DLL (`KCDMP.dll`) | C++ | 9,843 | damage/death apply, swings, Mannequin reads, local-state read, NPC scan, concept read | agent | named pipe; main-thread work via `C_ModulesManager::Update` IAT hook |
| injector | C++ | 127 | injects the DLL | launcher | process |
| launcher | C# WPF/Blazor | 3,536 + 310 web | start/stop, host/join, version display | game, agent, relay, master | processes, IPC |
| master server | C# | 835 | server list | relays, launcher | HTTP |
| installer | Inno Setup | 1,596 | install, closed-set manifest | — | — |
| synthetic suites | Lua (MoonSharp) + PS | 6,475 Lua | stubbed-engine tests of `kdcmp.lua` | — | — |
| unit tests | C# | 1,739 client + 536 relay | codecs, round trip, idle timeout | — | — |

**Cross-boundary messages (NPC-relevant; full list in `Protocol.cs`)**

| message | direction | format | rate |
|---|---|---|---|
| `[KCD2-MP-DATA] v2 <seq> <t> x y z rot flags hp st` | mod → agent (log) | text | 20 ms |
| `[KCD2-MP-EVT] v1 <seq> npc_state <name> x y z rot hp flags` | mod → agent (log) | text | ≤ 10 Hz per tracked moving NPC (today ~0.5 Hz, R1), 0.5 Hz idle |
| `npcid`, `npc_target`, `npc_death`, `wo102_toggle`, `authority_radius`, … | mod → agent (log) | text | on event |
| `#pcall(function() KCD2MP_ApplyNpcState(...) end)`… | agent → mod | batched Lua over HTTP GET | once per main-loop pass (~10 ms + one native read + one RTT) |
| `KCD2MP_ApplyNativeScan("name:x:y:z:yaw:h,…")` | agent → mod | Lua, ≤ 40 entries | every 2 s |
| 0x26 NpcStateUp / 0x27 NpcStateDown | agent ↔ relay | binary, 25+L / 26+L B | as the events |
| 0x30/0x31 NpcDamage (FATAL bit) | agent ↔ relay | binary | on hit/death |
| 0x39/0x3A ClockSync, 0x04/0x05 ping | agent ↔ relay | binary | periodic |
| 0x25 CombatRole | relay → agent | binary | on authority change |
| kScanNpcs / kReadLocalState / kReadBodyState / kGhostSwing / kApplyDeath … | agent ↔ DLL | pipe frames, seq-echoed | scan 2 s; local state every loop pass (`posNative`); others on event |

**Where the per-tick work runs today**

| path | where | rate |
|---|---|---|
| player emit (`KCD2MP_EmitTick`) | Lua | 20 ms |
| ghost interp + labels | Lua | 20 ms / 8 ms |
| owner NPC read + emit (`KCD2MP_NpcSyncTick`) | Lua; position from the native snapshot (R1) | 100 ms |
| NPC enumeration | native (DLL walk) → Lua resolve by name | 2 s |
| joiner puppet tick (render, write, anim, contention) | Lua | 50 ms (`mp_puppet_rate`) |
| pause / resume | Lua → console command → engine queue | per puppet start / release |
| local position / body state | native (DLL, main-thread marshalled) | every agent loop pass |
| swings (ghost + NPC) | native (Mannequin) | on cue |
| batching, flush, wire | agent | ~10 ms loop + awaits |
