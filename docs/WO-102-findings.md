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
