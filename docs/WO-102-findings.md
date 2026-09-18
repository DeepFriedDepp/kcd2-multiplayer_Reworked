# WO-102 — host-authoritative NPCs

Session 2026-09-18. Modding Tools build 1.5.5.0 (`ReleaseSteamLTO_DLL`), the
binaries every native RVA in this repo keys to. Working tree at `4d720cf`
(0.23.2) when the session opened.

Evidence marks, strict: **(observed)** = a log or a screen; **(code-verified)**
= read out of source, a binary or a shipped data file; **(synthetic)** = a
test harness, no game; **(inconclusive)** = exactly that. Nothing is rounded up.

Field-log source for every 2026-09-17 figure: the maintainer's HOST and
JOINER bundles (`agent.log`, `kcd.log`, `kcdmp-native.log`, host
`relay20260917.log`), read in this session. No identifying detail from them
is reproduced here.

---

## 0. Phase 0 — toggles and revertability

### 0.1 The toggle set

| toggle | console (argless pair) | agent flag | mod field | session default | phase |
|---|---|---|---|---|---|
| host NPC authority | `mp_authority_host_on` / `_off` | `--authority-host` / `--no-authority-host` (`HostAuthorityEnabled`) | `KCD2MP.wo102.authorityHost` | **off** | 4 |
| native position | `mp_pos_native_on` / `_off` | `--pos-native` / `--no-pos-native` (`NativePositionEnabled`) | `KCD2MP.wo102.posNative` | **off** | 1 |
| status | `mp_wo102_status` | — | — | — | 0 |

Mechanics (code-verified, synthetic 15/15 in `tools/Test-WO102Synthetic.ps1`):

* One setter, `KCD2MP_Wo102Set(name, on, source)`. A console flip logs
  `WO102-TOGGLE name= state= was= source=console` and emits **one**
  `wo102_toggle <name> on|off` event line; the agent's `OnGameEvent` mirrors
  it into `_hostAuthority` / `_posNative` (volatile, read at tick time).
* The agent pushes its configured defaults into the mod at connect with
  `source="agent"`, which mirrors the flag and emits nothing back (no echo
  loop). So the **shipped default lives in `ClientConfig`**, the mod's own
  `false` is only what an older agent leaves behind — i.e. 0.23.2 behaviour.
* Argless by construction: the console drops arguments from Lua-registered
  commands on this build (WO-94, live). The synthetic test asserts no
  `%LINE` in any WO-102 command body.
* `MP-SUMMARY section=wo102 authority_host= pos_native= authority=` is
  printed with every session summary so a field bundle states which model
  it ran under.

### 0.2 With every toggle off the build is 0.23.2

Phase 0 adds no behaviour behind either toggle; the flags exist, are logged
and are mirrored, and nothing reads them yet. The synthetic test pins the
0.23.2 defaults the later phases must not disturb: `npcSync.enabled`,
`npcProx.enabled`, `npcDiverge`, `npcYield.enabled` all `true`.

### 0.3 Wire compatibility with 0.23.2 (stated per phase, revised as phases land)

* **Phase 0:** no wire change. The toggle travels on the kcd.log event
  channel (game → agent, same machine). A 0.23.2 / new-build pair behaves
  exactly as 0.23.2 / 0.23.2.
* Later phases update this list in place.

### 0.4 One commit per phase

`git revert <sha>` of any one phase commit undoes that phase alone. No phase
relies on an earlier one being irreversible; a reverted Phase 0 would take
the toggle *plumbing* with it, so later phases fall back to their flags'
compile-time `false`.

---

## 1. Phase 1 — position off the log tail

### 1.1 What the log path actually costs (observed, §2.1 table)

The mod emits a `[KCD2-MP-DATA]` line every 20 ms; the agent saw a *fresh*
line every 58–59 ms typical (p50) with p95 127–139 ms and a mean of 75–80 ms
on both machines. The spread is the file: buffered writes, a tail polling at
`emitIntervalMs/4`, and a 10 ms agent tick. Nothing in that chain is
per-frame.

### 1.2 The native read — established, not guessed (code-verified)

Ghidra 12.1.3 headless, fresh imports of `CryEntitySystem.dll` and
`EntityModule.dll` (this build), plus MSVC RTTI parsed straight out of the
PE files:

| fact | evidence |
|---|---|
| `CScriptBind_Entity::GetWorldPos` reads the position out of the entity's world matrix, no virtual call: `x = *(float*)(e+0x64)`, `y = e+0x74`, `z = e+0x84` | decompile of handler `FUN_18000c990`, registered under the string `"GetWorldPos"` |
| `CScriptBind_Entity::GetWorldAngles` reads the same `Matrix34` at `e+0x58` and yaws by `atan2(m10, m00)` (`e+0x68`, `e+0x58`), with CryEngine's `Ang3::GetAnglesXYZ` gimbal branch `atan2(-m01, m11)` | decompile of `FUN_18000d170` |
| `SetWorldPos` writes the same matrix through `CEntity::SetWorldTM` (`FUN_180090620`) — so this IS the entity's transform, not a cache | decompile of `FUN_18000c8f0` |
| `CEntity::vftable` = `CryEntitySystem.dll + 0x14FA18`; its RTTI complete-object locator names `.?AVCEntity@@` at offset 0; `CEntity`'s only base is `IEntity` at 0 | Ghidra symbol + RTTI COL parse |
| `C_Actor` (and `C_Human`, `C_Player`) is `CGameObjectExtensionHelper<C_Actor, IActor, 64>` → `IActor` → `IGameObjectExtension` → `IComponent` (+ `enable_shared_from_this` at +0x8, `IGameObjectView` at +0x40, `IGameObjectProfileManager` at +0x48) | RTTI base-class arrays in `EntityModule.dll`, all `mdisp` values read |
| so the engine entity is the extension's `m_pEntity` member; by the CryEngine layout it sits at `actor+0x28` (vptr, weak_ptr ×2, `m_pGameObject`, `m_entityId`) | layout inference — **not** trusted alone, see the gate below |
| `FUN_180B3C2D0` (WO-42's "resolve actor by id") is `IActorSystem::GetActor(id)` (`bind+0x70 → vtbl+0xC8 → vtbl+0x18(id)`) behind an `IActor` predicate (`vtbl+0x2A8`), not an entity lookup — corrects the reading that it returns an entity | decompile |

**The hop is gated, not assumed.** `native/KCDMP/local_state.cpp` scans
`actor+{0x28,0x30,0x38,0x18,0x20}` and accepts only a slot whose pointee's
vptr equals `CEntity::vftable`; no match refuses with `EntityHopUnmapped`.
Only the *offset* is cached and it is re-checked on every read (WO-99.5
§1.3). The position and yaw are then the same bytes `player:GetWorldPos()` /
`GetWorldAngles()` return, so the log line is an exact oracle for them,
modulo frame timing.

### 1.3 What was built (code-verified; synthetic 139/139 agent tests incl. 12 new)

* **Pipe `0x0A ReadLocalState → 0x86 LocalState`** (40 bytes, one shape for
  refusal and success): frame counter, x/y/z, yaw, flags (bit 0 riding =
  Mannequin `Stance` reads `horse`), and the WO-100.5 body block byte-for-byte
  as `0x85` carries it. One request per tick replaces the `0x09` request the
  tick already made, so the pipe carries **the same number of round trips as
  0.23.2** when the native path is on; `0x09` is still issued on the log
  path. `nMaxInstances=1` and the agent's `_gate` serialisation are
  untouched; the WO-100 sequence matching applies unchanged (`seq` at
  `body[1]`).
* **Agent, behind `mp_pos_native_on`** (`_posNative`): the tick reads
  `0x0A`, dedupes by frame, and sends position + yaw + riding + body from that
  one read. Vitals stay on the log line; the STALE heartbeat still keys on the
  emitter's silence (a paused game never streams "live" frames). Two
  independent fail-closed verdicts: **gave-up** after 20 consecutive
  refusals (older DLL / unmapped hop), and **oracle-mismatch** after 20
  consecutive samples more than 3.0 m from the log line's position — a
  plausible wrong position is worse than the log path. Both print
  `MP-POSNATIVE verdict=…` once and fall back for the session;
  `mp_pos_native_off` then `_on` retries.
* **Instrumentation** (`CadenceStats`, 1 ms buckets, exact p50/p95):
  `MP-POSCADENCE path=log|native n= mean_ms= p50_ms= p95_ms= max_ms=
  window_s=30`, every 30 s for **both** paths at once (the log path is free
  to measure whatever the toggle says — a seq change is a fresh line), plus a
  `scope=session` line each in `MP-SUMMARY`; `MP-POSNATIVE oracle n=
  delta_mean_m= delta_max_m=` every 30 s. `[pos]` lines carry `path=`.
* **Wire: unchanged.** The Position packet is the same 17/22 bytes with the
  same fields; the WO-101 relay round-trip gate covers it as-is (10/10).

### 1.4 The measurement — NOT DONE. Runbook for the maintainer

No game ran this session; the DLL was built (`native/build/KCDMP/KCDMP.dll`,
383,488 bytes) and not injected. The interval comparison the phase exists
for is therefore **(inconclusive)** until this runs:

1. Launch the Modding Tools game normally, connect the agent as usual, and
   inject the *build-directory* DLL: `KCDMP_LauncherInjector.exe --pid <pid>
   --dll <repo>\native\build\KCDMP\KCDMP.dll`; verify `ModuleMemorySize`
   on the loaded module equals the build's `SizeOfImage` (WO-99.5 §6.1).
2. Walk, jog, sprint, mount, ride and dismount for ≥ 2 minutes with
   `mp_pos_native_off` (the default). Read two `MP-POSCADENCE path=log`
   windows. There will be no `path=native` lines.
3. `mp_pos_native_on`. Expect within seconds in `kcdmp-native.mirror.log`:
   `LOCALSTATE: entity hop = actor+0x28 (pointee vptr == CEntity::vftable)`
   (the offset may differ; **any** offset is fine, `EntityHopUnmapped` is
   not) then `LOCALSTATE: first read OK … pos=(…) yaw=…`. In `agent.log`
   expect `[pos] … path=native` and, at the first 30 s mark,
   `MP-POSNATIVE oracle … delta_max_m=` **well under 3 m** — that is the
   known-answer check passing. Repeat the same movement set for ≥ 2 minutes.
4. **The decision:** compare `p50_ms` and `p95_ms` of `path=native` against
   `path=log`. The native path earns its default only if p95 is measurably
   lower; if it is not, the honest result is "no measurable improvement" and
   the default stays off. `max_ms` on both paths will show menu/load gaps —
   compare p95, not max.
5. Riding: `[pos] … riding=True path=native` while mounted; if the flag
   disagrees with the log path's (`riding=` on the same line before the
   flip), that is a finding, not a fix — report both.
6. Peer side, optional: a second machine's `MP-GHOSTPKT ghost=<id> ia_mean_ms=`
   for your ghost before and after the flip is the receiver's view of the same
   cadence.

### 1.5 Wire compatibility (Phase 1)

No wire change. Pipe change is additive: a 0.23.2 DLL answers nothing to
`0x0A`, the agent counts 20 no-answers (~100 s at the 5 s reply deadline) and
prints `MP-POSNATIVE verdict=gave-up … no_answer=20`, staying on the log
path — **so on a 0.23.2 DLL the toggle costs ~100 s of the tick blocking on
the reply deadline before it gives up.** That is the one rough edge of a
mixed pair and it only exists while the toggle is on; the shipped default
decides whether anyone meets it (end gate).

---

## 2. Phase 2 — baseline the claim model (done before Phase 1; independent of it)

### 2.1 The 2026-09-17 figures, reproduced and corrected in place (observed)

The prompt's figures come from the host's `relay20260917.log`, which covers
the **whole day**: a solo 0.22.7 session (14:19–15:18), the 0.23.1 session
WO-101 diagnosed (19:24–19:45, in which the joiner reconnected and was
reassigned id 2 at 19:34), and the 0.23.2 session (20:16 onward). The mod
and agent logs in the bundles are the 0.23.2 session only. Both cuts:

| figure | prompt | whole day (what the prompt counted) | 0.23.2 session only (20:16→, log cut at bundle time 20:23) |
|---|---|---|---|
| `[CLAIM] granted` | 52, "every one to owner=1" | **52: 44 owner=1, 8 owner=2** — owner=2 is the joiner's reconnected id in the 19:34 window, not a third player | **22, all owner=1** |
| grants to owner=0 | 0 | **0** | **0** |
| releases | 27: 19 expiry, 8 disconnect | **27: 19 expiry, 8 disconnect** | 5, all expiry (the log ends mid-session) |
| held time (s) | min 9.0 / median 44.9 / max 171.9 | min **9.0**, median **47.4** (the 14th of 27; 44.9 is the 13th), max **171.9** | 18.3 / 65.9 / 171.9 (n=5) |
| `[WO66-REJECT]` denials | — | **0** | **0** |
| `[CLAIM] reassigned` / `CONTESTED` | — | **0** | **0** |

So: "zero to owner=0" **holds**, and the mechanism WO-98 §2 named holds
(code-verified again this session, `ClientHandler.RouteNpcState`: the damage
authority's packets never create claims). "Every one to owner=1" is wrong
only in that 8 of the day's 52 went to the same joiner under a second id.
"Claims expire mid-fight" holds: 19 of 27 releases are `reason=expiry` and
every expiry means the owner stopped refreshing for > 5 s (15 s if engaged)
while the name was still being sent by someone — with the relay muting the
authority's stream for that name until then.

Divergence figures (observed, mod logs, both machines):

| line | host | joiner |
|---|---|---|
| `MP-NPCFIGHT` lines / `MP-NPCDIVERGE` releases | 15 / 2 | 19 / 3 |
| `ttkc_man_20` | `n=8 mean_m=36.44 max_m=97.09`, released at 97.1 m | — |
| `ttkc_woman_6` | `n=56 mean_m=1.87 max_m=95.99` (never released: only 1 far hit inside the 30 s window) | — |
| `ttkc_horse_3` | `max_m=31.81`, released at 11.2 m | `max_m=20.92`, released at 10.1 m |
| `ttkc_man_5` | — | `max_m=34.98`, released at 35.0 m |
| `ttkc_woman_14` | — | `n=57 max_m=24.42`, released at 24.4 m |
| `ttkc_man_33` (not in the prompt) | — | `n=86 mean_m=1.13 max_m=86.10`, **not released** |
| `MP-NPCYIELD` lines | 19 | 20 |
| puppet starts / silence releases / tracking starts | 22 / 14 / 40 | 28 / 25 / 22 |

Every prompt figure reproduces; two were incomplete (`ttkc_woman_6` and
`ttkc_man_33` reached 96 m and 86 m without ever tripping the 3-hits-in-30-s
release, so the WO-90 net let the two worst divergences after `ttkc_man_20`
through).

Position cadence, for Phase 1's baseline (observed, agent `[pos]` lines,
which print only when the sample changed; 0.23.2 session):

| | host | joiner |
|---|---|---|
| samples | 3200 | 3376 |
| interval mean / p50 / p95 / max (ms) | 80.2 / 59 / 139 / 1849 | 74.9 / 58 / 127 / 1539 |
| min (ms) | 13 | 12 |

The mod emits at 20 ms; the agent sees a fresh sample every ~59 ms typical
with a p95 more than twice that. That spread is what Phase 1 measures
against, with proper per-path instrumentation instead of the console line.

### 2.2 What is instrumented now (code-verified, synthetic)

* **Relay.** `[CLAIM] muted npc= owner= authority= claimAgeSec=` — the
  damage authority's own stream for a claimed name being dropped, logged once
  per claim and counted per packet (`AuthorityMutedClaims`,
  `AuthorityMutedPackets` appended to `GET api/information/npc-claims`, both
  new record fields default 0). This is the event the prompt calls the
  "request" the relay never logged: the authority cannot ask, so its denied
  packets are its request. `[CLAIM] released … reason=expiry` gains
  `packets=` (owner refreshes accepted), `silentSec=` and `noticedBy=`;
  `reason=disconnect` gains `packets=`. Denials were already
  `[WO66-REJECT] stale-owner|speed|reserved-name`; grants and
  reassignments were already logged (WO-81). Nothing in the routing decision
  changed — the WO-66 invariant (a rejected packet mutates nothing) is intact
  because the new bookkeeping sits on the accepted paths only.
* **Agent.** `KCD2MP_ApplyNpcState` now receives the sending ghost id as an
  appended 8th argument (an older pak ignores it; an older agent leaves it
  `nil`).
* **Mod.** `MP-AUTHORITY npc= event=acquire|release|owner-change owner=
  via= held_s= model= [from=]` at every ownership transition: tracking start
  (`via=authority-default` / `via=claim`), drag claim, puppet start
  (`via=stream`), owner change mid-puppet (a claim moved at the relay),
  re-pin, and every release (`untrack`, `drag-idle`, `silence`, `diverge`,
  `yield`). Counters in `MP-SUMMARY-MOD` (`auth_acquire= auth_release=
  auth_owner_changes= auth_model=`). Format in `docs/WO-98-log-format.md`.
  Synthetic 31/31 (Phase 0 + Phase 2 scenarios g–l); the puppet-path suites
  unchanged: NpcSmooth 48/48, WO-84 72/72, WO-86 47/47, WO-90 70/70, WO-99
  39/39.

### 2.3 Wire compatibility (Phase 2)

No wire change. New relay log lines and two additive JSON fields on an
HTTP diagnostics endpoint. A 0.23.2 agent against this relay, or this agent
against a 0.23.2 relay, behaves as before.

---

## 3. Phase 3 — can the local AI be suppressed? (native search, read-only)

### 3.1 What was searched (code-verified)

* Identifier sweeps over `WHGame.dll`, `XGenAIModule.dll` (51 MB — the
  Warhorse brain), `EntityModule.dll`, `CryAISystem.dll`, `CryAction.dll`,
  `AnimationModule.dll`, `CryEntitySystem.dll` for brain / puppet /
  locomotion / movement / possess / pause / suspend / enable / disable
  families (the MT build keeps `__FUNCTION__` strings and RTTI).
* The shipped console reference `ConsoleHTMLHelp/CONSOLEPREFIX.html` (46
  files, WO-73's "unmined authoritative command+cvar reference").
* Warhorse's scriptbind reference (`Tools/modding/docs/script_bind`, 5,017
  pages): `CScriptBind_AI` (315 methods), `C_ScriptBindActor`,
  `CScriptBind_Entity`, `C_ScriptBind_XGenAIModule` method lists.
* MSVC RTTI of `C_NPC`, `C_IntelligentObject`, `C_AIPuppet`,
  `C_MovementControllerAdapter` parsed from `XGenAIModule.dll`.
* Not searched: a decompile of the XGenAI candidates — the 51 MB import
  crashed once in Ghidra's FID analyzer (two headless instances shared one
  FID database) and the retry was still analysing when this phase closed.
  What that decompile would add is stated in §3.4.

### 3.2 Candidates, with verdicts

| candidate | where | what it is | verdict |
|---|---|---|---|
| **`wh_ai_PauseNPC <name>` / `wh_ai_ResumeNPC <name>`** | XGenAIModule, `C_XGenAICommands::PauseNPCInternal`; help text: *"Pauses the execution of the NPC with given name. Debugging of the pausing system only"* | a shipped, per-NPC, by-name pause/resume of "the execution of the NPC" — the brain's owner. `wh_ai_NPCPauseRequestDebugDraw` (*"NPC pause requests … resume requests as well"*) shows the engine pauses NPCs through the same system in normal play, so the paused state is a first-class engine state, not a debug hack | **the lever. Exists (code-verified); live behaviour UNVERIFIED** — §3.3 is the proof |
| `wh_ai_UpdateEnabled 0` | XGenAIModule cvar: *"Controls XGenAI module update. 1 - on, 0 - off"* | every brain off at once | global, so not the lever; a useful control for the probe |
| update suspender (`C_UpdateSuspender`, `C_IntelligentObject::Suspend`, `wh_ai_UpdateSuspenderEnabled/RemoveAll`) | XGenAIModule | the engine's own per-NPC update suspension *"during profile streaming"* | internal; only debug remove-all is exposed. The mechanism PauseNPC most likely drives; not directly addressable |
| `Entity.Activate(0)` | `CScriptBind_Entity::Activate`: *"if false will deactivate and stop being updated every frame"* | stops the whole entity update | probably freezes animation too, not just the brain; untested (WO-64's pilot never ran). Second probe if PauseNPC fails |
| `AI.SetBehaviorTreeEvaluationEnabled`, `AI.StopModularBehaviorTree`, `AI.RequestToStopMovement`, `AI.SetForcedNavigation`, `AI.AutoDisable`, `AI.IsEnabled` | `CScriptBind_AI` (CryAISystem) | CryAISystem MBT / goal-pipe levers | WO-21 established the CryAISystem trees are inert for KCD2 NPCs (the brain is XGenAI); `RequestToStopMovement` is a one-shot request, not a suppression. Not the lever |
| `Actor.SetMovementRestriction(bAllowSprint, bAllowRun)`, `Actor.SetMovementControlledByAnimation(bool)` | `C_ScriptBindActor` | speed-class restriction; root-motion switch | neither removes the writer. `SetMovementControlledByAnimation(true)` is a possible *driving* aid for puppets later, not this phase |
| `XGenAIModule.SpawnEntity{NoAI=true}` | WO-100.5 | spawn-time only | not applicable to an existing NPC |
| `C_MovementControllerAdapter`, `C_MovementTaskManager`, `C_FakeMovementManager` (`WH_AI_LOD_MLUseFakeMovementMinimalDistance`), `C_ActorMovementController::Update` | XGenAI / EntityModule natives | the brain→body movement path and its LOD "fake movement" | **the deeper native lever if PauseNPC fails**; needs the XGenAI decompile (§3.4). Not attempted: read-only phase, and a shipped command was found first |

Established negatives were not re-derived: Lua behaviour trees (WO-21),
`DisableSituationParticipation` (social only, WO-99.5/WO-100).

### 3.3 The runbook — one machine, ~3 minutes, reversible

`mp_probe_npc_pause` (argless) does the whole sequence and logs
`MP-PAUSEPROBE step=0..5`. Synthetic 75/75 covers its sequencing; the engine's
answer is what the run is for.

1. Solo Modding Tools game, any town. Stand within 15 m of an ambient NPC
   that is walking or working (not seated). Console: `mp_probe_npc_pause`.
2. Read `kcd.log`:
   * `step=1 … execute_ok=true` — the command was accepted (a refused or
     unknown command still returns `true` from `ExecuteCommand`; the engine
     prints its own "unknown command" line right above if so — **report it**).
   * `step=2 … moved_m=` — how far the NPC moved in the 1 s after the pause.
     Near 0 = the brain stopped driving.
   * `step=3 … verdict_pos=HELD` — the body stayed where the probe put it
     (2 m off) for 3 s. **This is the lever working.** `SNAPPED BACK` = the
     brain (or its movement controller) still writes the body = **not a
     lever**, exactly the WO-32 1.5 s snap-back.
   * `step=4 … anim_after=3d_relaxed_walk_turn_strafe` (or any change from
     `anim=` at step 0) — the body still animates while paused. If the name
     did not change, the pause also froze animation: **usable for statues
     only**, and Phase 4's pause toggle must stay off.
   * `step=5 … moved_since_resume_m=` a few seconds after `wh_ai_ResumeNPC`
     — the NPC walks off again = clean resume.
3. While paused (between steps 1 and 4, or a second run with a longer manual
   pause: `wh_ai_PauseNPC <name>`), hit the NPC once. The engine's own
   `Skirmish event: HitTarget on Dude (target <name>)` line means a paused
   body is still a hittable combat participant — required for the request
   channel (Phase 5) to resolve through the existing damage path.
4. Optional: `wh_ai_NPCPauseRequestDebugDraw 2` before step 1 shows the
   pause request the engine registered.
5. Everything is undone by the probe itself (`wh_ai_ResumeNPC`, body put
   back). If the game were to crash mid-probe, restart it — pause state is
   process-local as far as the console reference says; whether it is saved
   with a savegame is **(inconclusive)** and the probe should be run on a
   disposable save.

**Pass** = HELD + animation changes + hit registers + clean resume. Then
`mp_authority_pause_on` is safe to try in a two-machine session (Phase 7).
**Fail on HELD** = the deeper native lever (§3.4) or the `NPC_NAI` replica
path (Phase 4 fallback) is the next work order; Phase 4 ships with the
pause toggle off regardless.

### 3.4 Verdict

**A lever exists, and it is a shipped console command, not a hook.**
`wh_ai_PauseNPC <name>` pauses the execution of one named NPC through the
engine's own NPC-pause-request system. What is *not* known until the runbook
runs: whether "execution" stops at the brain (locomotion, schedule — what
we want) or also stops animation and hit registration (statue — not
enough). Phase 4 therefore builds on it **behind its own toggle, off**, and
a negative probe result leaves Phase 4's other half (single ownership,
claim bypass, violation logging) intact and switches this half off for
good — the honest "no" the prompt asked for, deferred to the one test that
can give it. The XGenAI decompile of `PauseNPCInternal` and
`C_MovementControllerAdapter` (started, not finished this session) is the
follow-up if the probe fails.

### 3.5 Addendum — the XGenAI decompile landed (code-verified, Ghidra 12.1.3 on `XGenAIModule.dll`)

The 51 MB import finished after Phase 3 closed; three functions were read.

* **`wh_ai_PauseNPC` handler (`0x1AE58E0`)**: requires exactly one argument
  (else *"Wrong number of arguments. Expected one argument"*), copies it into
  a `CryString`, and calls `PauseNPCInternal(name, 1)`; `wh_ai_ResumeNPC`
  (`0x1AE59F0`) is the same with `0`.
* **`PauseNPCInternal` (`0x1AE5200`)**: `gEnv->pEntitySystem->FindEntityByName(name)`
  → `IEntity::GetId()` → the WUID registry maps the entity id to a `WUID` →
  builds a pause request `{ callback, WUID, resume = !pause, context = 8 }`
  and hands it to the **NPC pause-request manager** (`vtbl+0x40`). The
  callback logs *"Testing NPC pause request ended with %s"*. So the command
  is a thin console front to the engine's own request system, addressed by
  WUID, in its own context id (8).
* **`C_IntelligentObject::Suspend` (`0x1612290`)** — the consumer. Per queued
  request: on **suspend** it ORs the request's context bit into a mask at
  `obj+0x129`, and on the first bit calls `vtbl+0x1C0(obj, true)` and the
  brain host's `+0x68()`; on **resume** it clears the bit and only when the
  mask reaches zero calls `vtbl+0x1C0(obj, false)` and `+0x70()`. Its own
  trace strings say the rest: *"Trying to resume intelligent object %s in
  context (%d), but it is still suspended in other contexts (%d)"*, *"Cannot
  suspend intelligent object %s (%s), because it is in state %s"* (a
  three-valued state at `obj+0x128`).

What this establishes: the pause is a **refcounted, per-context suspension
of the `C_IntelligentObject`** (the brain host, `C_NPC : I_NPC :
C_IntelligentObject : C_AIObject`, RTTI) — not of the `CEntity`. Nothing in
this path touches the entity, its character or its physics. That is the
shape the lever needs; what it still does not prove is what `vtbl+0x1C0`
does to the movement controller, which only the §3.3 runbook can answer.
The multi-context mask also means our pause cannot be undone by an engine
resume in another context, and an engine suspend in another context is not
undone by ours — the two coexist by design.

---

## 4. Phase 4 — permanent host authority (behind `mp_authority_host_on`, default off)

Approach taken: **Phase 3 found a lever**, so this is the "suppress the local
brain, drive the bodies from the owner's stream" path — with the suppression
half behind its own toggle (`mp_authority_pause_on`, default off) because
the lever is unverified live, and the ownership half standing on its own.
The `NPC_NAI` replica fallback was **not built** (§4.4).

### 4.1 Who owns

The damage-authority holder (Rule 2, relay-assigned lowest ready id,
`KCD2MP.hitSensorOn` on that client) owns every NPC. "Permanent and single"
holds for as long as that client is connected; if the authority disconnects
the relay re-assigns Rule 2 to the next lowest id (0x25 `CombatRole`) and
ownership moves once, with it — the only migration that exists.

### 4.2 What changes, exactly (code-verified; synthetic 75/75)

| where | claim model (`_off`, 0.23.2) | host authority (`_on`) |
|---|---|---|
| non-authority emitter (`KCD2MP_NpcSyncTick`) | drag sensor claims downed bodies; proximity emitter claims NPCs near its player (WO-39/60) | **returns before both** — never emits `npc_drag` or `npc_claim`. Flipping on drops the running claim streams at once (`MP-AUTHORITY … release via=host-authority-on`, `WO102-AUTHORITY … dropped N claim stream(s)`) |
| authority rescan (`mp_npc_rescan`) | sphere around the local player, cap `maxTracked`=5 | sphere around the local player **and every peer ghost** (the ghost entity's position, `istate.tx/ty/tz` as fallback), cap `maxTracked × anchors`, distance = nearest anchor; `WO102-AUTHORITY scan anchors= cap=` logged on change |
| relay | per-name claims, expiry, engaged hold | **unchanged and bypassed**: with no claim packets arriving the table stays empty and the authority's default stream broadcasts every name. A stale claim from before the flip expires on the ordinary 5/15 s path |
| receiver: WO-90 divergence release (≥ 8 m, 3 hits / 30 s) | releases the puppet for 180 s | **refused.** The stream stays the truth; `MP-AUTHORITY-VIOLATION npc= kind=diverge dist_m= owner= paused= n=` (one line per NPC per 10 s, exact count) + one native toast per 5 min |
| receiver: WO-99 yield (0.30 m × 10 ticks) | stops writing, hands the body to the local brain | **refused**: no second writer is allowed; sustained contention logs `kind=contention` |
| receiver: pause lever (`mp_authority_pause_on`) | — | on puppet start: `wh_ai_PauseNPC <name>` (`MP-AUTHORITY event=pause via=wh_ai_PauseNPC`); on silence release, toggle-off or host-authority-off: `wh_ai_ResumeNPC <name>` (`event=resume`). A puppet that predates the flip is paused on its next tick. Counted as `auth_pauses= auth_resumes=` in `MP-SUMMARY-MOD` |
| `MP-AUTHORITY` | `model=claim` | `model=host` — a non-authority must only ever log `acquire via=stream` and never `owner-change`; anything else under `model=host` is a defect |

Everything is a gate at tick time, so both toggles flip mid-fight without a
restart, and off is the 0.23.2 code path line for line (scenarios m–s, and
the eleven older suites unchanged: NpcSmooth 48, WO-84 72, WO-86 47, WO-90
70, WO-94 101, WO-95 32, WO-96 160, WO-98 50, WO-99 39, WO-100.5 33, ghost
interp 35).

### 4.3 The `NPC-DIVERGE` rule under host authority

It cannot fire silently: the release is not taken and the event is logged
as a violation instead. It still *detects* — deliberately. With the pause
lever off, the local brain is still a writer and violations are expected
(that is the A/B's "off" arm of the pause toggle: contention visible, not
hidden). With the pause lever on and working, the violation count must go
to zero; a non-zero count with `paused=1` in the line means the pause does
not stop the writer — the loud log the prompt asked for.

### 4.4 What this costs, and which NPCs it covers

* **Nothing is replaced.** The pause approach keeps every NPC's soul, home,
  schedule, perception and quest state; it is paused and then resumed. That
  is why the `NPC_NAI` replica (WO-100 §5.3: no perception, no home, not a
  crime victim, a different character) was not built: it would have been a
  second, worse answer to a problem the lever addresses, and it destroys
  identity for exactly the quest-relevant NPCs the prompt says cannot be
  promoted. It stays the fallback **if** the probe fails on HELD.
* **Ownable:** every world NPC and horse the authority's game has loaded
  within 45 m (`radius × 1.5`) of the authority's player or any peer ghost,
  up to 5 per anchor.
* **Not ownable, stated plainly:**
  * an NPC only the joiner's game has loaded (the joiner far from the host,
    beyond the host's streaming range) — the host cannot scan what it has
    not loaded. It runs on the joiner's local AI, unsynced, until the two
    players are near enough for the host to have it; then it is owned. The
    Phase 6 resync covers position/life state when it becomes visible.
  * the mod's own bodies (`kcd2mp_*`) and the engine's conversation
    stand-ins (`DialogTwin_*`) — excluded as before (WO-90).
  * a **quest-divergent NPC** (WO-90's Hans at the lake vs the camp) is owned
    like any other, which means the joiner's copy stands where the *host's*
    story has it. Under the claim model the release handed it back so the
    joiner's quest could use it; under host authority it will not. That is
    the design — one world decides — and the WO-94/96 quest layer is what
    tells the joiner why. If the joiner's own quest needs that NPC
    elsewhere, it is blocked until the host catches up or the toggle is
    flipped off. **Stated as a cost, not hidden.**
* The per-anchor cap means crowd scenes still stream at most 5 NPCs per
  player; the rest run on local AI on every machine, as in 0.23.2.

### 4.5 Wire compatibility (Phase 4)

No wire change. A mixed pair degrades, it does not fail: a 0.23.2 joiner
still claims (its Lua predates the gate), the unchanged relay grants, and
the new host's stream is muted for those names — i.e. that joiner runs the
claim model. A new joiner against a 0.23.2 host never claims and the old
host streams only its own neighbourhood (no anchors) — the joiner's nearby
NPCs are then unsynced. Both directions are 0.23.2-or-less, never a crash.
