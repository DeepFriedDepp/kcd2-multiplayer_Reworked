# WO-108 — findings: 0.26.4, suppression on by default

Session 2026-09-21, solo, against the running Modding Tools build (0.26.3
pak at the start, the rebuilt 0.26.4 pak from Phase 5 on). Progress and
gaps: `docs/WO-108-progress.md`. Toggle inventory:
`docs/WO-108-toggle-inventory.md`. Field page:
`docs/WO-108-peer-test-runbook.md`. Prerequisites read:
`docs/WO-107-ai-suppression.md`, `docs/WO-107-progress.md`,
`docs/WO-106-findings.md`.

Evidence marks: (observed) / (code-verified) / (synthetic) / (inconclusive).
**Nothing in this WO ran two-player.** 0.26.4 ships on solo evidence as a
stated risk: the build exists to collect the two-player evidence.
**Nothing was deleted.** Three defaults changed; every toggle keeps its door.

Console transport: the WO-106 §2 shape, unchanged. Windows paths passed to
Lua with forward slashes. Every `[KCD2-MP]` line quoted below is from
`kcd.log`.

---

## 0. Answer first

* **Phase 0 passed: the engine suspension does not survive a save load on
  any path tried** — quick-load, `wh_sys_LoadGame`, and a cold relaunch
  from the desktop. (observed, §1) The default flip proceeded.
* **The trigger was already blanket and joiner-only** (§3.1, code-verified,
  observed solo). The Phase 2 rewiring the prompt scoped as "this WO's
  largest real change" was not needed; what was added is the invariant's
  guards, the dwell, the gap detector and the reload re-assert.
* **Bulk (the maintainer's mid-session request): 46 NPCs suspended in one
  1.0 ms Lua batch, all 46 motionless from 10 s to 30 s, no measurable
  frame hitch, 21 walking again within 60 s of the bulk resume.** (observed,
  §2)
* **Three defaults flipped, each cited** (§4): pause lever off→on, replicas
  on→off, yield on→off. Presets `mp_preset_clean` / `mp_preset_legacy`
  round-trip, logging 16 values each. (observed, §7.5)
* **Every Phase 5 smoke item ran live against the shipped pak** (§7), with
  one honest half: the relax tag is (synthetic) only — no relax-shaped
  contention could be provoked live in this session.
* **What a suspended NPC loses** is now written from the wire format, not
  from expectation (§3.2). The wire carries position, yaw, health and six
  flags; the receiver already synthesises generic locomotion loops from
  speed, so "gliding" is the wrong expectation — "mannequin legs and a
  generic idle" is the right one.

## 1. Phase 0 — the save-reload hazard (GATING) — PASSED

Method: `wh_ai_PauseNPC` on two walking town NPCs (`ttkc_woman_10`,
`ttkc_woman_2`), a walking control (`ttkc_man_27`) left alone. Suppression
confirmed by position polling, not by a write (the WO-107 §4 relax makes a
write-then-readback ambiguous once the write stops): both subjects 0.00 m
over 20 s while the control walked 13 m. (observed) The engine also logged
`Node status inconsistency. Can't update suspended node!` for each subject
— an engine-side signature of the suspended state that turned out to be the
most useful persistence probe of the session.

| load path | how | result | evidence |
|---|---|---|---|
| in-process quick-load | `wh_sys_TestSaveGame` → `quicksave023.whs` (4.46 MB, full save); `wh_sys_TestLoadGame` (0.56 s) | both subjects walking within 25 s (7 m / 3 m at +0, 20+ m by +20 s); **zero** "suspended node" lines after the load vs 1 before | observed |
| in-process full load | `wh_sys_LoadGame 1 quicksave023` — took the same "Quick-loading … ignoring delay" path, 0.57 s | walking within 20 s; zero suspended-node lines | observed |
| **cold relaunch** | `System.Quit()`, process gone in 3 s; `KingdomCome.exe` restarted from the shell (no args, same as the launcher's command line); API up after 18 s; `wh_sys_LoadGame 1 quicksave023` from the main menu (0.44 s) | both walking within 20 s; **zero** suspended-node lines in the entire fresh log; fresh Lua state (`_npcPaused` empty) | observed |
| UI-driven load (Continue / load slot) | — | not exercised; every path above went through the console loader | (inconclusive) |

Consistent with WO-102.5 §1.3.2 (same result, quick-load only, 2026-09-18).
**Branch taken: bit does not persist → proceed.** The resume-all-on-load
sweep the prompt reserved for the other branch was therefore not the
mitigation built; what WAS built for loads is the opposite problem
(§5.4): the *Lua* table survives an in-process load while the engine
forgets, so live puppets are re-asserted after a confirmed-dead chain
restart.

`wh_ai_ResumeNPC`'s own reply ("…in which it was not suspended") **does not
reach kcd.log** at `log_Verbosity 4` / `log_WriteToFileVerbosity 4` (tested
on the never-paused control, before and after raising verbosity). The
console gives Lua no reply either. Hence §5.2's field naming.

## 2. Bulk suppression (added at the maintainer's request mid-session)

46 soul-bearing `NPC`/`NPC_Female` entities within 60 m of the player (the
whole town square), `wh_ai_PauseNPC` issued for each from one Lua loop.

| | value | evidence |
|---|---|---|
| batch issue time (Lua side, 46 × `System.ExecuteCommand`) | 1.0 ms | observed |
| moving in the 10 s before the pause | 14 / 46 | observed |
| "moved" at +10 s after the pause | 10 / 46, max 1.02 m — the tail of a step already in progress | observed |
| movement between +10 s and +30 s | **0.00 m, all 46** (the three polls are byte-identical) | observed |
| engine `Can't update suspended node!` lines in the window | 43 | observed |
| emitter clock gaps around the batch (20 ms `[KCD2-MP-DATA]` stream) | baseline max 56 ms (n=505); pause window max 62 ms; resume window max 52 ms | observed — no hitch distinguishable from baseline |
| bulk `wh_ai_ResumeNPC`, 46 issued | 1.0 ms | observed |
| walking again after the resume | 17 at +15 s, 18 at +30 s, 19 at +45 s, **21 at +60 s** (mean displacement 11.3 m, max 72.8 m) | observed |

The 25 that had not moved by +60 s include every NPC that was stationary
before the pause (32 of 46 were); no claim is made that they "resumed" in
any observable sense, only that nothing froze that was not already still.
No `NPC pause/resume request for %zu NPCs` line appeared at verbosity 4.

## 3. Phase 1.2 — the NPC wire inventory

### 3.1 What is on the wire about an NPC (code-verified: `kdcmp.lua`, `GameBridge.cs`, `Protocol.cs`)

| field | carried by | sender / rate | receiver applies |
|---|---|---|---|
| name | every NPC packet | — | `System.GetEntityByName`; excluded families refused (`kcd2mp_*`, `DialogTwin_*`) |
| x, y, z | `npc_state` → 0x26/0x27 | authority; every 100 ms while moved > 0.05 m, else a 2 s heartbeat | 3-deep ring, interpolation-behind 1.2 × emit period, `SetWorldPos` every 50 ms tick (`mp_puppet_rate`) |
| yaw (rotZ) | same packet | same | `SetWorldAngles` each tick (lerped on the legacy path) |
| health | same packet | same (also on a > 0.5 change) | stored (`p.hp`); death/KO handled via flags |
| flag 1 dead | same | on transition + heartbeat | stop driving; corpse follow only for a stream that is itself dead |
| flag 2 unconscious | same | same | same as dead (WO-38 P6) |
| flag 4 weapon drawn | same | on transition | `DrawWeapon` / `HolsterWeapon`, re-asserted every 1.5 s against the real state |
| flag 8 swing cue | same | when the authority's NPC lands a hit within 4 m | one-shot swing on the puppet (native via `npcid`/DLL, Lua fallback) |
| flag 16 carried | same | drag sensor (claim model) | smooth per-tick follow |
| flag 32 engaged | same | armed NPC within 12 m of a player | relay claim hold; cull exemption |
| flag 64 resync | `npc_state` burst | `mp_resync_npcs`, sleep/fast-travel/reload nets | one-shot snap of a non-puppet copy (never within 2 m of the player, never in dialogue) |
| NPC death (FATAL) | `npc_death` event → 0x30/0x31 name-addressed damage | killer's side, once | local copy killed through the DLL pipe |
| name-addressed damage | 0x30/0x31 | a client hitting a puppet | owner applies health/stamina |
| entity id of this world's copy | `npcid` event (agent-local) | receiver, at puppet start | agent addresses the body for native swings |
| attack target | `npc_target` event → NpcRequest | joiner, on change | owner applies the joiner's committed attack to the real NPC |

### 3.2 What is NOT on the wire — the local brain supplied it, and it is now suspended for driven NPCs on the joiner

| behaviour | on the wire? | what the joiner sees for a driven NPC |
|---|---|---|
| locomotion animation selection | **partly synthesised locally**: the receiver plays `relaxed_idle_both` / `3d_relaxed_walk_turn_strafe` / run / sprint loops from rendered speed (WO-32/77), combat idle when drawn, horse gaits for `Horse` | generic mannequin gait, no turn animations, no gait matched to the NPC's own (limp, carry, elderly); a **standing** driven NPC shows a generic idle instead of its activity (sweeping, sitting, working). Whether the loop reliably plays on a *suspended* body under a live two-player stream: **(inconclusive)** — `GetCurAnimation()` returned nil on the smoke subjects, so it could not be read; WO-107 §5 observed a paused NPC "visibly idle-animating" |
| head-look / gaze | not on the wire | none |
| gestures, facial animation | not on the wire | none |
| barks, ambient lines, dialogue initiation | not on the wire | none (the joiner's copy is `Suspend`ed, and the engine's own `RestrictDialog` state is untouched) |
| door / chair / bench / prop interaction (smart objects) | not on the wire | walks to the door and stops where the host's copy opened it |
| sitting / standing transitions, activity poses | not on the wire | generic idle (above) |
| combat target selection, blocking, dodging | not on the wire (only the swing cue and drawn flag are) | swings when cued, otherwise stands in guard; never blocks or dodges on its own |
| reactions to the joiner (perception: look, greet, step aside, flee) | not on the wire | none |
| crime / guard response to being attacked | not on the wire | may not fire on the joiner (WO-107 §10, observed solo); the two clients may disagree |
| schedule / destination (where it is going and why) | not on the wire | irrelevant while driven; on resume the brain re-plans (~14 s, WO-107 §10) |
| horse riding by NPCs, animals | not on the wire | out of scope (animals are not tracked) |

This table is the source of Phase 4's known-issues section.

## 4. Phase 2 — trigger audit and the defaults

### 4.1 Audit (three questions)

1. **Reactive or blanket?** Blanket. `mp_wo102_pause` is called from
   `KCD2MP_ApplyNpcState` the moment a puppet is created (first inbound
   packet for the name) and from `KCD2MP_NpcPuppetTick` for a puppet that
   pre-dates the lever being switched on. Not from a violation, not from a
   claim event. (code-verified) Live: three streamed NPCs → three
   `event=pause why=puppet-start` lines on the first packet. (observed, §7.1)
2. **Symmetric or joiner-only?** Joiner-only by construction: under host
   authority the non-authority never emits `npc_state`/`npc_claim`/`npc_drag`
   (`KCD2MP_NpcSyncTick` returns before both), the relay does not echo a
   sender's own stream, so puppets — and therefore pauses — exist only on
   the non-authority. (code-verified) Two-machine confirmation:
   **(inconclusive)** — it is the peer test. WO-108 adds an explicit guard
   anyway: `mp_wo102_pause` refuses when `KCD2MP.hitSensorOn` (this machine
   is the authority), logged once as `event=refused
   why=this-machine-is-authority`, counted every time. (synthetic)
3. **What resumes it, and when?** Silence release (3 s without a packet),
   the 5 s reconcile sweep (paused but not a puppet), lever off, host
   authority off, `mp_stop`, the agent's disconnect path
   (`KCD2MP_Wo102ResumeAll`, `GameBridge.cs` line ~2002, code-verified).
   Under host authority the divergence rule never releases. WO-108 routes
   the silence release through a dwell (§5.5) and adds the gap detector
   (§4.2) and `mp_resume_all` (§5.4).

**So no rewiring was needed.** The prompt's "largest real change" did not
materialise; the invariant's guards are the real code change.

### 4.2 The suspend-set invariant (§2.2) — implemented

* Pause only from puppet creation / an existing puppet; `mp_wo102_pause`
  refuses a name with no `KCD2MP.npcPuppets` entry (`event=refused
  why=not-a-puppet`, counted). Never from radius, roster scan or authority
  bookkeeping. (code-verified, synthetic)
* Resume when writes stop, via the dwell (§5.5).
* **Coverage-gap detector**: in the 5 s reconcile, a believed-paused name
  with a puppet whose last packet is older than `releaseS + 5 s` (= 8 s)
  is logged `MP-PAUSE-GAP npc=… reason=no-writes age_s=…`, its stale puppet
  dropped and the brain resumed; a believed-paused name with no puppet and
  no pending dwell is `reason=untracked` (the WO-102.5 reconcile line is
  kept verbatim under it). Live: puppet chain flag cleared with a stream
  running → `MP-PAUSE-GAP npc=ttkc_barbora reason=no-writes age_s=11.2` →
  `event=resume … why=gap-no-writes`. (observed, §7.6)

### 4.3 Defaults changed — each with its citation

| flag | 0.26.3 → 0.26.4 | justification |
|---|---|---|
| `KCD2MP.wo102.authorityPause` (`mp_authority_pause_on/off`) | off → **on** | WO-107 §3 (`C_IntelligentObject::Suspend`, latched, multi-owner, held solo through stream/damage/combat/~50 min), WO-107 §3.4 (WO-104's `paused=1` was a Lua table; its `dist_m` was the §4 relax), WO-108 §1 (no save-load persistence), §2 (46 at once), `memory/kcd2mp-ship-new-features-on.md` |
| `KCD2MP.npcReplica.enabled` (`mp_npc_replica_on/off`) | on → **off** | WO-106 §5: `SharedSoulGuid` indexes an authored database a live WUID is never in — 36/36 refusals, never promoted; the reconcile sweep still ran a refusal path per violation for nothing. The 5 s orphan sweep still runs regardless (cleanup must not depend on the switch) |
| `KCD2MP.npcYield.enabled` (`mp_npc_yield_on/off`) | on → **off** | WO-102 P4: under host authority the flag is never consulted (the same displacement becomes a violation); a no-op flip that stops `mp_npc_yield`'s status line claiming a live mechanism. `dispM`/`ticks`/`repinM` stay live as the contention detector's thresholds |

Considered and **not** flipped (`docs/WO-108-toggle-inventory.md` §1/§2):
`mp_npc_cull` (live-and-wanted, WO-102.5 P3, nothing supersedes it);
`mp_npc_diverge` (inert under host authority, not established as the
snap-jitter source → left on, unresolved, per the prompt's rule);
`mp_npc_proximity`, `npcSync.radius/maxTracked`, the drag sensor (only
reachable with `mp_authority_host_off`, where they ARE the rollback);
smoothing layers (`mp_npc_smooth` is an if/else against the legacy lerp,
not a stack — nothing to turn off).

### 4.4 Presets

`mp_preset_clean` / `mp_preset_legacy` (`KCD2MP_ApplyPreset`). Each sets
16 values through the existing setters (so side effects — resume-all on
lever off, demote-all on replica off — happen exactly as a console flip
would), logs one `MP-PRESET name=<p> set=<key> from=<v> to=<v>` per value,
then `MP-PRESET applied … authority_model=untouched (…)` and a
`WO102-STATUS` line. `authority_host`, `pos_native`, `npc_scan_native` are
never touched. (observed, §7.5)

## 5. Phase 3 — the call site made trustworthy

### 5.1 Identity on both sides

Every pause/resume/release/cancel/reassert/refused now logs

```
MP-PAUSE npc=<name> event=<e> wuid=<hex16> eid=<hex> body=<class> exec=ok|err:<msg>|none why=<via> owner=<id> held_s=<F1>
```

`wuid` = `soul:GetId()`'s hex tail (WO-106 §1.4's ScriptHandle), `eid` =
the entity id's hex tail (the WO-49 idiom). Live, three subjects:
`ttkc_barbora wuid=0500000000000007 eid=000000000002F836`,
`ttkc_woman_10 wuid=0500000000000123 eid=000000000002F835`,
`ttkc_woman_2 wuid=05000000000001C4 eid=0000000000002472` — distinct,
stable across the session's pause/resume cycles, and `ttkc_woman_10`'s wuid
matches WO-106 §1.4's reading of the same soul two days earlier. (observed)
Cross-machine agreement: **(inconclusive)** — a single-machine log says the
fields populate, not that two machines agree. The host has no `MP-PAUSE`
lines by design; its nearest pair is `MP-AUTHORITY … acquire owner=self`.

### 5.2 `paused=` is gone

`MP-AUTHORITY-VIOLATION` now reads
`… pause_issued=0|1 pause_exec=ok|err:…|none …`. `pause_issued` is what the
old field always was (the Lua table); `pause_exec` is the pcall verdict of
the `System.ExecuteCommand` call. **Neither is engine state.** Engine-side
suspend state (`C_IntelligentObject+0x128/+0x129`, WO-107 §3.2) is not
readable from Lua on this build, the console command returns nothing to
Lua, and its reply text does not reach `kcd.log` (§1). A native read is a
DLL-side follow-up, not this WO. Live: `kind=diverge dist_m=20.00 …
pause_issued=1 pause_exec=ok`. (observed, §7.3)

### 5.3 The relax tag

`kind=relax` when the tick-to-tick displacement points at the puppet's
creation anchor (cos ≥ 0.90) with magnitude 1.5–12 % of the distance to
it (scaled with `mp_puppet_rate`). Tagged lines still log, with `anchor_m`
and `cos` for audit, count in `pause_relax`, and never feed the replica
trigger. A perpendicular 0.6 m push stays `kind=contention`; a 131 m yank
stays `kind=diverge`. (synthetic, 87/87 suite) **Live: no relax-shaped
contention could be provoked** — holding `ttkc_woman_10` 3 m (25 s) and
10 m (20 s) off her anchor under a 100 ms stream produced zero
contention violations of any kind; the writes won outright, exactly as
WO-107 §4 recorded for a 38 Hz stream. The heuristic therefore ships
having tagged nothing real yet: (inconclusive) live, and stated as a
heuristic in the code. Root-causing the relax remains out of scope.

### 5.4 Belt-and-braces resume

| exit path | mechanism | evidence |
|---|---|---|
| peer disconnect / stream stops | silence release (3 s) → dwell → resume | observed §7.1 |
| authority radius exit / cull | same path (the stream stops) | code-verified |
| agent shutdown / disconnect | `KCD2MP_Wo102ResumeAll` from `GameBridge.cs` | code-verified (call site present), synthetic |
| mod stop | `KCD2MP_Stop` → resume all | synthetic (WO-102 suite aa) |
| game exit | not hookable from Lua; **moot** — the suspension does not survive the process (§1) | observed |
| NPC leaves the tracked set | silence path | code-verified |
| chain dead / stuck puppet | `MP-PAUSE-GAP reason=no-writes` | observed §7.6 |
| bookkeeping lost the name | `MP-PAUSE-GAP reason=untracked` (the WO-102.5 sweep) | synthetic |
| save load (in-process) | engine forgets, Lua remembers → live puppets **re-asserted** once after a confirmed-dead chain restart (`event=reassert why=chain-dead-restart`); Suspend is idempotent (`mask |= bit`, WO-107 §3.2) | synthetic (the stamp is set in `chainMayStart`'s confirmed-dead branch, code-verified) |
| **panic** | `mp_resume_all` (`KCD2MP_ResumeAllPaused`): lever OFF first (so nothing re-pauses 50 ms later), then `wh_ai_ResumeNPC` for every name ever paused this Lua session — a no-op on an unsuspended context | observed §7.4 |

### 5.5 Release hysteresis

`KCD2MP.wo1025.resumeDwellS = 10.0`, `mp_resume_dwell <s>` (0–120, bare
reports). A silence release logs `event=release why=silence+dwell`, holds
the pause, and `mp_wo102_pending_tick` (every NPC-sync tick) resumes
`why=dwell` when the deadline passes; a packet inside the dwell logs
`event=cancel why=stream-back-inside-dwell` and issues nothing. Same shape
as the WO-102.5 co-location dwell (`togetherDwellS`, also 10 s), not a
second pattern. **Why 10 s**: longer than the cull-boundary flapping a
joiner produces walking a town (30 m cull radius around moving anchors),
equal to the co-location dwell it mirrors, and bounded — an NPC that really
left the stream is back under its own brain in releaseS + 10 = 13 s, plus
the brain's ~14 s re-plan. Live: release at +3.0 s after the last packet,
resume at exactly +10.0 s, first motion of the two mobile subjects within
16 s of the resume; one live `event=cancel` when a stream returned at
+6.7 s into a dwell. (observed, §7.1/§7.6) 0 = the 0.26.3 behaviour
(`mp_preset_legacy` sets it).

## 6. What Phase 1.2 says about the "gliding" expectation

The prompt expected driven NPCs to glide. The wire inventory says otherwise:
`KCD2MP_NpcPuppetTick` already restarts a locomotion loop on every tag
change (idle/walk/run/sprint, 1 s keep-alive), derived from rendered speed
— WO-32's "without this the NPC slides in its current activity pose" was
solved for puppets long before suspension. The honest expectation is
**mannequin legs**: a generic gait, no turn animations, and a generic idle
for a standing driven NPC. Whether those loops reliably play on a
*suspended* body under a live two-player stream is (inconclusive) — see
§3.2 row 1 — and is the judgement the runbook asks the session to make.

## 7. Phase 5 — solo smoke test against the shipped pak (all observed)

Run against the rebuilt `kdcmp.pak` (844,471 bytes) installed by
`tools\Build-And-Install-Mod.ps1`, game relaunched cold, `quicksave023`
loaded. The extracted `Scripts/Startup/kdcmp.lua` from the installed pak is
byte-identical to the working tree (`cmp`). Inbound streams were played by
a scratch Lua driver calling `KCD2MP_ApplyNpcState` at 100 ms with
`hitSensorOn=false` (this machine as the joiner), restored afterwards; the
agent was not running, so `KCD2MP_StartNpcSync()` was issued by hand.

| # | item | result |
|---|---|---|
| 1 | suspend 2–3 world NPCs through the real path; identity fields | 3 `event=pause` lines, each with distinct `wuid`, `eid`, `body=NPC_Female`, `exec=ok`, `why=puppet-start`, `owner=7` (observed) |
| 2 | `pause_issued=`/`pause_exec=` report what their names say | `kind=diverge dist_m=20.00 owner=7 pause_issued=1 pause_exec=ok n=1 body=npc` after a 20 m yank of a paused puppet (observed); no `paused=` anywhere |
| 3 | relax tagged, genuine diverge still a diverge | diverge: observed (above). Relax: **not provoked live** (3 m and 10 m off-anchor holds produced zero contention); tagging is (synthetic) — §5.3 |
| 4 | `mp_resume_all` | with 2 live puppets paused and a third name in the ever-set: `WO102-TOGGLE authority_pause off source=resume-all`, 2 × `event=resume why=pause-lever-off`, 3 × `event=resume why=mp_resume_all-sweep`, `resume-all … swept=3 lever_was=on lever_now=off`; 3 s later `paused=0` while both puppets kept streaming — **no re-pause**; `mp_preset_clean` then re-paused both (observed) |
| 5 | presets round trip | `legacy`: 16 `MP-PRESET name=legacy set=…` lines, `WO102-STATUS … authority_pause=off … pause_dwell_s=0.0 npc_replica=on npc_yield=on`; `clean`: 16 lines, status back to `on / 10.0 / off / off`; `authority_model=untouched` on both (observed) |
| 6 | the no-writes assertion | stream running, puppet-chain flag cleared and stream dropped → `MP-PAUSE-GAP npc=ttkc_barbora reason=no-writes age_s=11.2`, `event=resume … why=gap-no-writes` (observed) |
| 7 | fresh load, nothing typed, pause on in the shipped pak | `[KCD2-MP] WO108-BUILD pause_lever=on npc_replica=off npc_yield=off resume_dwell_s=10.0 -- 0.26.4 defaults (mp_preset_legacy = 0.26.3) t=26.560`, two lines after `MOD INIT` (observed) |

Also observed in the run: `NPC-SYNC release … (stream silent)` at exactly
+3.0 s, `event=release why=silence+dwell held_s=27.9`, `event=resume
why=dwell held_s=37.9` at exactly +10.0 s; `MP-SUMMARY-MOD … auth_pauses=7
auth_resumes=7 auth_paused_now=0 auth_violations=1`.

Synthetic: `tools\Test-WO108Synthetic.ps1` 87/87 (scenarios a–k, header of
the `.lua`); WO-102 196/196 and WO-104 92/92 after their default assertions
were updated; WO-77/84/86/94/95/96/98/99/100.5/ghost-interp unchanged and
green. `Test-WO90Synthetic.ps1` fails one assertion (`(i): no swallowed Lua
errors`) **identically against HEAD's `kdcmp.lua`** — pre-existing, not
this WO's.

## 8. Corrections this WO makes to the record

* WO-104 §2 / the 0.26.2–0.26.3 default: the pause lever was never broken
  (WO-107) and is now on. The comment blocks in `kdcmp.lua` that carried
  the wrong reading are corrected in place, with the original kept under
  an `ORIGINAL:` marker at the WO-104 replica header.
* WO-107 progress §4 "save/reload survival: not tested": tested on three
  load paths, does not survive.
* The prompt's Phase 4 expectation "expect gliding": the receiver already
  synthesises locomotion; the expectation is mannequin gait / generic idle.
* `mp_probe_npc_pause`'s "SNAPPED BACK (brain still writes)" verdict: it
  measures the WO-107 §4 relax; the help text now says so.

## 9. Open, carried forward

* Two-player: everything. This build's purpose.
* Cross-machine name→body identity (§5.1) — evidence now logged, not
  chased (next WO).
* Locomotion loops on a suspended body under a real stream (§3.2/§6).
* The relax heuristic has tagged nothing real (§5.3).
* Crime/perception divergence for a suspended victim (WO-107 §10).
* `SchedulerProxy` (WO-107 §9).
* Engine-side pause state is not readable from Lua; a native read would
  make `pause_exec` a real `paused`.
