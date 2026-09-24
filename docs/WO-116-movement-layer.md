# WO-116 — steer the body, don't overwrite it

Session 2026-09-23, solo, against the running Modding Tools build (0.27.0 pak,
no KCDMP.dll, no agent). Progress, method and gaps: `docs/WO-116-progress.md`.
Read first: `docs/WO-107-ai-suppression.md`, `docs/WO-108-findings.md`,
`docs/WO-105-cryengine-reference.md` (§4, §5, §6, §16), `docs/WO-106-native-migration.md`,
`docs/WO-111-death-respawn.md`.

Evidence marks: (observed) / (code-verified) / (synthetic) / (inconclusive).
"The call succeeded" is never used as "the thing happened": every live row
below was read back from the body (position, yaw, animation state) or from
the engine's own log.
**No shipped code. No pak, no installer, no VERSION bump. Nothing ran
two-player.** A research-only probe DLL was built and injected from the
session scratchpad; it is not in the repository.
Paths: `<install>` (Modding Tools install), `<saves>`, `<scratch>` (session
scratchpad), `<ENGINE_REF>` (the CRYENGINE 5.7.1 checkout, WO-105 §0.1).
RVAs are against this install's binaries (image base 0x180000000, dated
2026-08-26). Stock CRYENGINE is described in prose and identifiers only
(WO-105 §0.2).

---

## 0. Verdict

**Yes. A suspended NPC's own movement layer takes orders natively, and the
body walks, turns, runs and stops under its own locomotion and animation,
on the ground, driven by a stream.**

* **The door already ships.** `wh_ai_RequestDebugMovement <npc> <x> <y> <z>`
  ("doesn't consider what NPC is doing and just queues a movement request")
  queues a Warhorse movement request into the per-NPC `C_MovementTask`,
  which runs a stock CryAI MovementSystem plan. It does not need the brain.
  (code-verified, observed)
* **On a suspended walker** (brain off, `Can't update suspended node!`, held
  0.00 m for 6 s): start transition `IdleToMove`, a real ~180° turn, walk,
  stop transition, arrival **4 cm** from the target; then 14 s of idle with
  no self-direction. (observed)
* **Following a moving target, orders re-issued at 10 Hz:** constant lag
  **0.39 ± 0.01 m at 1.4 m/s** and **0.86 ± 0.01 m at 3.5 m/s**, body speed
  equal to the target speed, one continuous `MotionMovement` state, **no
  stop-start**, Z on the terrain. (observed)
* **Speed is one field.** Request `+0xF8` is the movement-speed enum
  (0 relaxedWalk … 3 run, 4 fastRun, 7 sprint …). The debug door hard-codes
  1 (walk); a probe detour set it: run 2.94 m/s, fastRun 3.30, sprint 5.19.
  (code-verified, observed)
* **Release is clean.** Resume → the brain walked on within ~1 s; ten NPCs
  released at once were back at their own activities within 5–20 s.
  (observed)
* **Activities are the gap.** A seated or aligned NPC is held by its seat, so
  an order gets `Agent is stuck`. The shipped console door
  `wh_ai_NPCStateResetElement <npc> Stance|Unstance` frees it instantly
  (no animation), and after that it takes orders. **Sitting down / using a
  workstation through this route was not achieved**: the native entry is
  named (`C_NPCContext::RequestStateChange`), its request was not decoded.
  (observed / code-verified / inconclusive)

**The seat hypothesis is confirmed, with a number.** A seated-then-suspended
NPC is pulled **4.1 % of its distance to the seat per 50 ms tick, straight at
the seat (cos 1.00, 91/91 ticks)**; a walking-then-suspended NPC is pulled
**0.0000 m** on every tick. `…ResetElement … Stance` before streaming removes
the pull (0.0000 m). That is a short-term fix for today's overwrite path
regardless of the rest. (observed, §1)

**Ranking (§4):** R1 the movement-request route ranks first on criteria 1–5
and 7, partial on 6. ~~The fallback (a late per-frame transform write) is
designed in §9 and not needed as the primary path.~~ **Corrected by the
same-day follow-up (§14): the late per-frame write is the direct fix for the
jitter and comes first; R1 is the later fix for gait, turns and activities.**

**Follow-up (§14): the jitter is the write's rate and moment, not its
thread.** Per-frame render-time traces, one NPC each, solo:

| | today's puppet (Lua, 50 ms) | Lua forced to every frame | DLL, every frame, at its frame hook |
|---|---|---|---|
| walking NPC, 1.4 m/s | **0, 0, 0, 76 mm** repeating — 75 % of frames frozen | 19 mm every frame (sd 0.8 mm) | 19 mm every frame (sd 0.8 mm) |
| seated NPC held 3 m off its seat | **0 → 42 → 83 → 123 mm** toward the seat, snap, repeat | 42 / 0 / 42 / 0 mm flicker | **0 mm, every frame** |

(observed) The Lua write runs on the right thread (main) but lands early in
the frame and at 20 Hz; the DLL's existing frame hook already sits after the
engine's per-NPC movement and before render.

---

## 1. Phase 0 — the seat test

Method: the WO-108 scratch-driver pattern. A Lua driver called the mod's own
receiver `KCD2MP_ApplyNpcState` every 100 ms with this machine as the joiner
(`hitSensorOn=false`, host authority on, pause lever on), so the real puppet
path ran: puppet start → `mp_wo102_pause` (`wh_ai_PauseNPC`) → 50 ms
`SetWorldPos` tick → `MP-NPCFIGHT` / `MP-AUTHORITY-VIOLATION`. An independent
recorder wrapped `KCD2MP_NpcPuppetTick` and sampled the body **at the puppet
tick's own phase**, just before its write, with no 5 cm floor. Targets were
picked in a direction checked free by `Physics.RayTraceCheck` (static +
terrain, knee and chest height, floor under the end point).

| # | subject | state at suspension | stream | per-tick displacement from the last write | direction | evidence |
|---|---|---|---|---|---|---|
| A | `ttkc_man_22` | `SittingIdle` (guard spot, seated) | free point 1 m | **0.041 m** (ratio 0.041) | **cos 1.00 to the seat**, 91/91 ticks | observed |
| A | same | same | free point 3 m | **0.123 m** (ratio 0.041) | cos 1.00, 90/90 | observed |
| B | `tzda_man_10` | `MotionMovement` (walking) | free point 1 m / 3 m | **0.0000 m** | — (540 ticks) | observed |
| B′ | `ttkc_man_10` | `MotionMovement` | 1 m point **inside furniture** | constant **0.352 m, +X** every tick | cos 0.19 to the anchor | observed — collision push-out, not a pull |
| W | `ttkc_man_5` | `Leaning_Left_Loop` (non-aligned activity) | free point 1 m | 0.0000 m after 2 transient ticks pointing *away* | — | observed |

What the mod's own detectors said on the same runs (observed):

* A at 1 m: no `MP-NPCFIGHT` — 4 cm is under the detector's 5 cm floor.
  A at 3 m: `MP-NPCFIGHT n=179–189 mean_m=0.12` per 10 s. At the measured
  ratio the pull crosses the contention threshold (0.30 m for 10 ticks) once
  the stream is ≳ 7.3 m from the seat, and it points at the anchor inside
  the relax band (1.5–12 %), which is exactly the peer test's
  "122/198 violations pointed straight back at where the NPC was paused".
* B′: `MP-NPCFIGHT n=180 mean_m=0.35` and `MP-AUTHORITY-VIOLATION
  kind=contention cos=0.19` — **a target inside geometry reads as a fight**.
  That is a false-positive mode of both detectors, recorded for the peer
  logs.

**After the stream stops** (release at +3 s): the seated body slid back to
the seat on a clean exponential, 2.88 m → 0 in ~6 s (≈ 0.6 per 0.5 s
sample), matching WO-107 §4's relax. The walking body stayed exactly where it
was written and walked off ~1 s after the dwell's resume. (observed)

**Release first — making the NPC leave its seat before suspending:**

| lever | result | evidence |
|---|---|---|
| `actor:StandUp()` (registered) | accepted, **nothing happens** — suspended or not | observed |
| a movement order on a seated NPC | `IdleToMove`, turn, ~1.3 m slide while still `SittingIdle`, snaps back to the exact seat point, `Agent is stuck` — **suspended or not** | observed |
| **`wh_ai_NPCStateResetElement <npc> Stance`** | `SittingIdle` → `MotionIdle` in 0.5 s, instant (no stand-up animation), body rose 0.45 m at the seat point; **pull afterwards 0.0000 m at 1 m and 3 m** (70/70 ticks, five windows) | observed |
| `wh_ai_NPCStateResetElement <npc> Unstance` | `Leaning_Left_Loop` → `MotionIdle` instantly | observed |
| on resume after a reset | the brain seats the NPC again: 4 of 5 previously seated NPCs were seated within 20 s, one caught in `SitDown` | observed |

**Mechanism.** EntityModule has an alignment subsystem
(`C_AlignmentManager`, `C_PositionAlignmentSolver`: "Alignment on target %s
is interrupted because velocity is too high / because jump"). A seated NPC
is held to its location object; a teleport-style write carries no velocity,
so nothing interrupts the solver and it keeps pulling. (code-verified strings;
the solver's per-frame pull itself not traced — inferred from the measured
exponential.) The pull belongs to the **sitting stance** and to **aligned
unstances**: `NPCStateUnstanceDatabase.xml` marks 8 unstances
`IsAligned="true"` (e.g. `slouchedBack`, `sittingInjured`, the wagon pushes)
and 313 `IsAligned="false"`; ~333 leave it unspecified, and whether the
default is aligned was not settled. (data-verified; default inconclusive)

**Short-term fix for today's overwrite path** (independent of everything
else, not shipped): at puppet start, right after `wh_ai_PauseNPC`, issue
`wh_ai_NPCStateResetElement <name> Stance` and `… Unstance`. Cost: the NPC
pops upright at its seat without an animation; on release its brain
re-seats it normally. `wh_ai_*` debug commands are Modding Tools commands;
the mod already requires that build. (observed; retail availability not
checked)

---

## 2. Phase 1 — the movement layer

### 2.1 The chain, order to body

| # | layer | where | what it does | evidence |
|---|---|---|---|---|
| 1 | brain decides | XGenAI BT `C_MoveBase` (build request `0x506840`, `RequestNPCStateChange` `0x504fd0`); activity system `MoveBaseActivity` (`0x155ccf0`); NPC-state "subsequent movement" (`0x1630c30`) | builds a Warhorse movement request: speed enum from the node's `movementSpeed`, optional exact positioning, a path-finding request | code-verified; call sites resolved live from return addresses (BT 95 %, activity 3 %, NPC-state 2 % of 1,801 sampled brain orders) |
| 2 | **the hand-off** | XGenAI `0x1a6dd60` (movement-task manager queue) | finds or creates the NPC's `C_MovementTask` (keyed by the soul WUID), **cancels the current request**, assigns a new id, starts the task | code-verified; observed on every order |
| 3 | task | `C_MovementTask` start `0x1a6a350` | copies speed (`+0x160`, with a stamina fallback check), path request (`+0x18`), exact direction; derives the logical speed (`+0x16C`) | code-verified |
| 4 | plan | **stock CryAI `MovementSystem`**, in CryAISystem.dll | plans and runs blocks: stock `FollowPath`, `UseExactPositioningBase` (CryAISystem exports 86 `Movement::` symbols; **XGenAI imports 36 of them**) plus Warhorse blocks (door, ladder, ledge, smart area) | code-verified (PE import/export tables) |
| 5 | proxy | CryAction `CAIProxy::Update` `0x29d40` | every frame, builds a `CMovementRequest` from the AI object state and calls the movement controller's vtable slot 1 (`RequestMovement`), retrying once; a Warhorse "delta movement" computer is grafted in | code-verified; ~70 calls per frame, main thread only (observed) |
| 6 | controller | EntityModule `C_ActorMovementController::Update` `0xb18d0` | Warhorse's movement controller (the string "PlayerMovementController Output" is inside it) | code-verified; observed on main + 8 workers |
| 7 | finalize | EntityModule `C_ActorStateUtil::FinalizeMovementRequest` `0xcbd80` | fills the animated character's move request (actor `vtbl[0x2D0]` = animated character, WO-100) | code-verified |
| 8 | body | CryAction `CAnimatedCharacter` — `GenerateMovementRequest` `0x640b0`, `RequestPhysicalEntityMovement` `0x67c80`, `PostProcessingUpdate` `0x66200`, `Update` `0x60d60` | stock animated character: movement-control method, locomotion parameters, `pe_action_move` to the living entity | code-verified (profiler labels); observed |
| 9 | physics | CryPhysics `CLivingEntity::Action` `0xb16c0`, `CLivingEntity::Step` `0xa4360` | the living entity takes the requested velocity and keeps ground contact | code-verified; observed thread (§2.4) |

**What finished the WO-108 tail.** On suspension the in-flight move stops:
the walker in M2 moved 0.20 m and was `MotionIdle` within 0.26 s — a stop
transition under its own animation, not a continued path. The movement
layer keeps executing *new* orders (§5), so the suspension must cancel the
current task (mechanism not traced; inferred). (observed / inferred)

### 2.2 Keep, replace or bypass

* **Kept (modified):** the stock movement system, path follower, AI proxy,
  animated character and living entity. Warhorse grafted CVars into them
  (`wh_ai_MovementActorSleep`, `wh_ai_LimitSpeed*`, collision avoidance,
  `wh_ai_ExactPositioningOnFailedMoveTransitionBuffer`). (code-verified)
* **Replaced:** the request layer. Orders come from XGenAI BT nodes, the
  activity system and the NPC-state system, not from stock goal pipes; the
  movement controller is Warhorse's `C_ActorMovementController`.
  (code-verified)
* **Added:** the NPC-state layer (stance, unstance, location object;
  `C_NPCContext`, `NPCStateActionDatabase.xml`) and the alignment
  subsystem. Seats and workstations live here, above the movement layer.
  (code-verified, data-verified)

The other developer's advice holds exactly on the boundary the prompt
drew: motion execution is stock; the requests are Warhorse's.

### 2.3 Player locomotion

The same controller and finalizer drive Henry. `FinalizeMovementRequest`'s
callers include the player movement states
(`PlayerMovement_PressJumpWhileNotAllowedToJump`), the animation-controlled
state (button mashing) and fly mode; the controller carries the player's
output label. The NPC input is `CAIProxy::Update`; the player's is input.
The player also has an NPC-state context: a "Player state handler" calls
the same `C_NPCContext::RequestStateChange` (benches, beds). So a body
driven from outside is modelled by an **input source into the shared
controller and the shared NPC-state context**, not by a special class —
consistent with WO-56's "Henry is a slot, not a class". (code-verified)

### 2.4 Threads and the frame

A probe DLL (research only, §11) counted calls per thread on every function
this WO touched. Eight minutes, 35,774 frames (observed):

| function | threads |
|---|---|
| `C_ModulesManager::Update` (the DLL's frame hook), `CAIProxy::Update`, `CAnimatedCharacter::Update`, `CharacterManager::SyncAllAnimations`, `CSystem::Update / Render / RenderBegin / RenderEnd / UpdateAfterSystem`, `CCryAction::PreSystemUpdate / PostUpdate`, `CEntitySystem::Update` | **main only** |
| `C_ActorMovementController::Update`, `FinalizeMovementRequest`, `CAnimatedCharacter::GenerateMovementRequest / RequestPhysicalEntityMovement / PostProcessingUpdate`, `SFinishAnimationComputations` | **main + 8 job workers** (Warhorse parallelised the per-character pre-physics update — not stock) |
| animation job (`CommandBufferExecute`) | 8 workers only |
| `C_NPCManager::UpdateIntellects`, **brain orders into the queue** | workers only (the brain queues its orders from job threads) |
| debug-door orders into the queue | main |
| `CLivingEntity::Step` | one physics thread |
| `CLivingEntity::Action` | physics thread + main + workers |

One main-thread frame, 13.07 ms (observed, entry timestamps):

```
+0.00  CCryAction::PreSystemUpdate, CSystem::RenderBegin, CSystem::Update
+0.95  pre-physics character update (main's share):
       C_ActorMovementController::Update -> FinalizeMovementRequest
       -> CAnimatedCharacter::GenerateMovementRequest -> RequestPhysicalEntityMovement
       -> CLivingEntity::Action                                   (to +1.75)
+1.87  CAnimatedCharacter::PostProcessingUpdate
+2.59  CAIProxy::Update x70          (RequestMovement for the next frame)
+2.70  CEntitySystem::Update, CAnimatedCharacter::Update x45
+3.61  C_ModulesManager::Update      <- the DLL's frame hook
+4.70  CCryAction::PostUpdate
+4.72  CharacterManager::SyncAllAnimations, SFinishAnimationComputations
+4.94  CSystem::Render ... +9.05 RenderEnd ... +12.88 UpdateAfterSystem
```

Consequences:

* An order issued at the frame hook reaches the body in the next frames:
  the movement system and proxy run at +2.6 ms of frame N+1, the controller
  consumes at +1 ms of N+2. (inferred from the order)
* The frame hook sits **after** the proxy pass and **before** the animation
  sync. A later main-thread point exists: after `SyncAllAnimations`
  (+4.72) and before `CSystem::Render` (+4.94). (observed)

---

## 3. Phase 2 — ways to give it an order

| # | route | native reach | needs the brain? | fragility |
|---|---|---|---|---|
| **R1** | **queue a Warhorse movement request** (what the debug door does) | typed worker `QueueMovementRequest(I_NPC*, Vec3* target, bool exact, Vec3* dir)` `0x19b5ad0`, or replicate it: request ctor `0x1a6ee50` + `S_PathFindingRequestDefault` + queue `0x1a6dd60`; `I_NPC*` from the NPC manager (§13) | **no** (observed) | two non-exported functions and one field offset; all string-anchored (`MovementRequestDebug.cpp`, `Request movement for NPC`) |
| R2 | swap the scheduler proxy (`C_SchedulerManager::ChangeSchedulerProxy` `0x1994ec0`) | native call | **yes** — it replaces the *entity whose activity links the scheduler subbrain follows* (it fetches subbrain 9 and fails "while it has no scheduler subbrain") | n/a |
| R3 | a BT move node / smart-object "use" without the decision layer | BT nodes only tick inside the brain; the move node is "NPC-state change, then R1" (`C_MoveBase::RequestNPCStateChange`) | yes, as a node; no, if unpacked into R1 + R5 | high |
| R4 | per-frame `RequestMovement` on the NPC's `C_ActorMovementController` (the literal "feed the controller" technique) | controller vtable slot 1; timing window exists (proxy at +2.6 ms, our hook at +3.6 ms, consumer next frame) | no | the proxy rewrites the request every frame; bypasses path finding; request layout unverified |
| R5 | NPC-state change request (`C_NPCContext::RequestStateChange` `0x1881090`) | native call; request struct not decoded | no, as far as the entry shows (the player's handler uses it) | high until the request is decoded |
| R6 | reset one NPC-state element (`wh_ai_NPCStateResetElement` → `C_NPCStateDebug::ResetCurrentStateElementCommand` `0x189ad70`) | console door; native through the console interface or by replicating the handler (npc `vtbl[0x1D8]` → `vtbl[0xB70]` → element reset) | no (observed) | debug command |
| R7 | fallback: a late per-frame transform write | native, §9 | no | the overwrite path's known problems, minus the ones the flags fix |
| — | `wh_ai_NPCStateSearchDebug*` | plans and draws a state path; **executes nothing** on the NPC ("Search result %s in %d updates", "Cost … Action %s") | — | not a route |
| — | test framework "move" command (`moveComponent.Start`, with a speed) | reachable only from test scripts | — | not a route |

---

## 4. Ranked routes on the seven criteria

1 accepts orders while suspended · 2 motion is the engine's own · 3 runtime,
any world NPC · 4 follows a moving target, drift measurable · 5 10 Hz without
stop-start · 6 activities · 7 clean release.

| rank | route | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
|---|---|---|---|---|---|---|---|---|
| **1** | **R1 movement request** | **PASS** (obs) | **PASS** (obs: transitions, turns, gait by speed class, terrain Z) | **PASS** (obs, 12 distinct NPCs, 10 of them in one batch measured in aggregate; seated ones after R6) | **PASS** (obs: 0.39 / 0.86 m constant lag) | **PASS** (obs: no stop-start; fails only if the order is led, §5.4) | **PARTIAL** — walks to the spot and faces it (exact positioning); sitting/working not produced; seated NPCs need R6 first | **PASS** (obs, 1 and 10 NPCs) |
| 2 | R6 element reset (as R1's companion) | PASS (obs) | instant, no animation | PASS (obs) | n/a | n/a | stand-up only | PASS (obs: re-seated on resume) |
| 3 | R5 NPC-state request | (inconclusive) | presumably yes (the engine's own actions) | (inconclusive) | n/a | n/a | the route for sit / stand / work | (inconclusive) |
| 4 | R4 per-frame controller input | (inconclusive) | (inconclusive) | (inconclusive) | (inconclusive) | (inconclusive) | no | (inconclusive) |
| — | R7 transform write (today, Lua; or native late write) | PASS | **FAIL** (obs: engine state `MotionIdle` throughout, Z pinned to the stream, seat pull) | PASS | PASS (tighter: 0.22 / 0.57 m) | PASS | FAIL | PASS |
| — | R2 scheduler proxy | **FAIL** (needs the scheduler subbrain) | — | — | — | — | — | — |
| — | R3 BT node | **FAIL** as a node | — | — | — | — | — | — |

R1 wins because it is the engine's own model of "a body told where to go":
the same request, queue, planner, proxy, controller and animated character
the brain uses, minus the brain.

---

## 5. Phase 3 — live probes on a suspended NPC

Subject for the single-NPC series: `ttkc_bailiffSon` (soul WUID
`0500000000000567`), suspended mid-walk with `wh_ai_PauseNPC`, a street in
Trosecko. Orders through `wh_ai_RequestDebugMovement`; speed through the
probe DLL's `+0xF8` write (stand-in for setting the field in our own
request). Positions, yaw and `actor:GetCurrentAnimationState()` polled at
4–10 Hz from Lua.

### 5.1 One order

| run | order | result | evidence |
|---|---|---|---|
| M2 | walk, 9.3 m behind him | `IdleToMove` (turn 1.68 → −1.46 rad in 0.8 s), `MotionMovement` 1.72 m/s, stop transition, **4 cm** from the target in 5.75 s, 14 s idle after | observed |
| S3 | run (`+0xF8=3`), 14 m | 3.0 m/s, 10 cm | observed |
| S7 | sprint (`=7`), 24 m | 5.0–5.5 m/s, path bent around an obstacle, 0.2 m | observed |
| D2 | walk, weapon drawn first (`human:DrawWeapon`) | armed gait 1.47 m/s, 6 cm | observed |
| M1 | walk, NPC **seated** when suspended | `IdleToMove` attempts, snaps back to the seat every ~5 s, `Agent is stuck` | observed |

Z followed the terrain in every run (e.g. 108.18 → 106.68 m over the
street). (observed)

### 5.2 Speed classes (`+0xF8`), steady speed on this NPC (observed)

| id | name | m/s | | id | name | m/s |
|---|---|---|---|---|---|---|
| 0 | relaxedWalk | 1.76 | | 4 | fastRun | 3.30 |
| 1 | walk (door default) | 1.70 | | 5–7 | slowSprint … sprint | 5.18–5.20 |
| 2 | alertedWalk | 1.76 | | 8–11 | slowestDash … dash | 5.18–5.20 |
| 3 | run | 2.94 | | | | |

The brain's own walk was 1.41–1.44 m/s (this NPC and the bartender), near the door's walk × `wh_ai_MovementSpeedThrottleWalk` 0.8 = 1.36; where the throttle is applied was not traced (inconclusive).
Brain orders sampled: walk 67 %, run 33 %, relaxedWalk < 1 %. Dash classes
reach this NPC's top speed and no further. (observed)

### 5.3 Moving target at 10 Hz, same street, 39 m

| run | class | target | along-track lag | body speed | states | evidence |
|---|---|---|---|---|---|---|
| F1 | walk | 1.4 m/s | **0.39 ± 0.01 m** | 1.40 (sd 0.07) | one start blip, then `MotionMovement` 27 s | observed |
| F2 | walk | 3.5 m/s | grows to 21 m | 1.67 | continuous | observed — class too slow |
| F3 | run | 3.5 m/s | 2.1 → 7.9 m | 2.92 | continuous | observed — class too slow |
| F4, F7 | sprint | 3.5 m/s | **0.86 ± 0.01 m** | 3.50 (sd 0.12 / 0.10) | continuous | observed |
| F5, F6, F8 | sprint | 3.5 m/s, **order led by 0.25 s** | up to 10 m | 0–5.6 | `MoveToIdle` / `IdleToMove` every ~6 s | observed, three runs, both directions, identical timings |

Two findings that shape the design:

* **The movement system is the follower.** Its end-of-path slowdown turns
  "move to where the host NPC is now" into a proportional controller with a
  ~0.25–0.28 s time constant, as long as the speed class can reach the
  target speed.
* **Never lead the order.** With the goal ahead of the target the body
  sprints, closes inside its stopping distance, commits to the stop
  transition (~2 s) and starts again: a limit cycle.

### 5.4 Against today's overwrite path — same NPC, same street

The same synthetic path fed through `KCD2MP_ApplyNpcState` at 100 ms
(the puppet's 50 ms `SetWorldPos` tick plus its walk/run loop).

| | lag | speed | engine animation state | Z | evidence |
|---|---|---|---|---|---|
| overwrite, 1.4 m/s | 0.22 m | 1.40 | **`MotionIdle` the whole run** (mod tag `walk`) | pinned to the stream: −0.22 … +0.16 m against the terrain the movement run followed | observed |
| R1, 1.4 m/s (F1) | 0.39 m | 1.40 | `MotionMovement`, transitions | terrain | observed |
| overwrite, 3.5 m/s | 0.57 m | 3.51 | **`MotionIdle`** (mod tag `run`) | pinned | observed |
| R1, 3.5 m/s (F7) | 0.86 m | 3.50 | `MotionMovement` | terrain | observed |

The overwrite path tracks tighter; the engine never leaves idle under it.
"Mannequin legs" is that measurement: a looped clip over an idle state
machine.

### 5.5 Drift, scale, release

| run | what | result | evidence |
|---|---|---|---|
| D1 | mid-follow, `SetWorldPos` 2 m sideways | `IdleToMove`, walked back, 0.10 m from the target 3.5 s later — a snap does not break the layer | observed |
| multi-10 | 10 suspended NPCs (5 had been seated or working, reset first), each on its own 4 m ping-pong at 1.4 m/s, all re-ordered at 10 Hz (100 orders/s) | **75 → 72–73 fps (~3 %)**, lag mean 0.5–1.1 m, max ≈ 3.7 m at the instant reversals | observed |
| seated-3 | 2 seated NPCs, reset, then 3 m ping-pong with movement-error logging on | both followed (lag 0.5–1.8 m), **no `Agent is stuck`** | observed |
| release-1 | `wh_ai_ResumeNPC` on the walker | walking his own route ~1 s later | observed |
| release-10 | resume all ten | back at their anchors and activities within 5–20 s (fence repair, carpentry, begging, transcribing, eating); 4 of the 5 previously seated were seated again, one caught in `SitDown`; the others moved on to new schedule items | observed |
| brain off | 671 queue calls for the walker's WUID during the suspension | all from the debug door, none from his brain (brain orders sampled 1 in 25 — supporting, not conclusive) | observed |

WO-107 §10's "~14 s to first motion" did not reproduce: ~1 s (walker) and
5–20 s (activity NPCs walking back). (observed)

### 5.6 Activities through this route

* Stand up: R6, instant, observed.
* Sit / use a workstation: **not achieved.** The debug door never changes
  NPC state. The BT's move node does "NPC-state change, then movement";
  the state change goes through `C_NPCContext::RequestStateChange`
  (`0x1881090`, shared by the BT move node, the follower, the combat
  helper, "Clear state change" and the player's state handler). Its
  request (a state *search*: required stance, unstance, location object)
  was not decoded. (code-verified entry; live inconclusive)
* Whether sitting down through R5 avoids Phase 0's pull cannot be answered
  until R5 runs. The engine's own seated state *is* the pull, so a seated
  copy should hold still on its own instead of fighting a stream. (inferred)

---

## 6. Phase 4 — reading intent on the host

The queue call (`0x1a6dd60`) is a chokepoint every brain order passes.
Read there (probe, observed):

| field | where | example |
|---|---|---|
| NPC | `request+0x00` → `I_NPC`; its `+0x10` is the **soul WUID** (matches `MP-PAUSE wuid=` and Lua `soul:GetId()`) | `050000000000026B` |
| target | path request `+0x80` (Vec3); some orders carry a segment list instead (target 0,0,0 in 38 of 1,801 samples) | `2360.75, 2081.68, 112.26` |
| speed class | `request+0xF8` (task copy at `+0x160`) | 1 walk |
| exact positioning | `request+0xBC` (6.8 % of brain orders; the activity system's orders set it) | 1 |
| source | caller: BT move node / activity system / NPC-state subsequent move | activity system |

**One order predicts the walk.** Watching the awake bartender
`ttkc_woman_1`: order → arrival **0.2 m** from its target 11 s later, then
`HousekeeperFirewoodPutToStove`; next order, 40 m away → she walked 40 s
and stopped **1 cm** from its target, then `Picking`. (observed)

| intent | native read | status |
|---|---|---|
| move target, speed class, exact flag | queue chokepoint (a detour), or the NPC's `C_MovementTask` (`+0x18`, `+0x160`) — note `0x1a6e870` *creates* a task when missing, so a reader must walk the manager's map instead | observed (detour); task read not built |
| path | the path request / plan inside the task | not traced |
| stance, activity | `actor:GetCurrentAnimationState()` returns the Mannequin fragment (`SittingIdle`, `Bartender_CleaningTable`, `Scribe_TableListeningLoop`); natively the NPC context's elements | Lua read observed; native layout **not decoded** (inconclusive) |
| weapon drawn | `human:IsWeaponDrawn()`; native per WO-47 | observed |
| combat action | the combat model (WO-100 §Phase 1, live-verified there) | not re-probed |

What cannot be read natively today: stance / unstance / location object —
infer from the fragment name (Lua) or from position (stationary at a known
smart object) until the NPC context is decoded.

---

## 7. Phase 5 — design

### 7.1 Shape: position-follow on the joiner, intent where it's cheap

The live data favour **the host's current position as the order**, not a
relay of the host brain's orders:

* it is proven at 10 Hz with constant lag and no stop-start (§5.3);
* it corrects drift by construction — every order *is* the correction;
* it needs no capture on the host beyond what is streamed today.

Order relay (host brain order → same order on the joiner) is the later
optimisation: fewer messages and the engine's own path from the copy's own
position, but it misses motion that is not a path (combat footwork,
alignment micro-moves, pushes) and still needs the position stream for
correction.

### 7.2 The intent message

Today, `0x26/0x27` (WO-108 §3.1, `Protocol.cs`):
`[nameLen:1][name][x y z rotZ health: 5×f32][flags:u8][seq:u16][senderMs:u32]`
— 27 B + name (~40–50 B), 10 Hz while moving, a 2 s heartbeat when still.

Proposed, protocol v8, the same packet plus 6 bytes:

| field | bytes | source on the host | use on the joiner |
|---|---|---|---|
| everything in v7 | 27 + name | unchanged | position = order target; yaw = exact direction when stopped |
| `speedClass` | 1 | the NPC's task `+0x160` (or derived from measured speed) | request `+0xF8` |
| `stance` | 1 | NPC context, or mapped from the fragment name | R6 reset on entry/exit; R5 when decoded |
| `activity` | 4 | hash of the fragment / unstance name | R5 when decoded; logged meanwhile |

≈ 33 B + name at the same rates. No new message byte is needed; if the
relay optimisation is built later, `NpcOrderUp/Down` would take the next
free pair, **0x44 / 0x45** (`Protocol.cs`: 0x43 is the highest in use).

### 7.3 Joiner apply rules (native, on the frame hook)

* On a sample: if the target moved ≥ 0.25 m from the last ordered point, or
  the speed class changed, queue an order; cap 10 Hz per NPC. A still NPC
  costs nothing.
* Speed class: the host's class when streamed; otherwise the smallest class
  whose top speed ≥ 1.15 × the host's measured speed (walk 1.70, run 2.94,
  fastRun 3.30, sprint 5.19).
* **Order point = the latest sample. Never extrapolate** (§5.3 limit cycle).
* Host stopped (< 0.1 m/s for 0.3 s): a final order with `exact=1` and the
  host's yaw.
* Z is never written except on a snap.

### 7.4 Drift correction and snap thresholds

Nominal lag λ = 0.28 s × v (0.39 m at 1.4 m/s, 0.86 m at 3.5 m/s).

| condition | action |
|---|---|
| \|err\| ≤ λ + 1.0 m | nothing — the next order is the correction |
| \|err\| > λ + 1.0 m for 1.5 s | promote the speed class one step until \|err\| < λ + 0.3 m |
| \|err\| > 8 m, or no progress (< 0.2 m in 3 s while \|err\| > 2 m), or a path failure, or \|Δz\| > 1.5 m | **snap**: native teleport to the host position (keep the ground: bit 32, §9), then keep ordering; at most once per 5 s per NPC |
| host NPC enters an aligned state (seat, aligned activity) | order the copy to the spot with `exact=1` and the host's yaw, keep it released (R6) and standing; log the stance until R5 exists |

The last row is the open end: until R5 works, a host NPC sitting down leaves
the joiner's copy standing at the spot, facing the right way. Resuming the
copy's brain is not an answer (the brains diverge).

### 7.5 Combat

* Swings: unchanged. The swing cue flag drives the native swing (WO-46/49);
  a Mannequin action on the combat scopes, independent of the locomotion the
  order produces. Hits stay name-addressed damage (0x30/0x31).
* Movement in combat: orders work with the weapon drawn (armed gait, §5.1
  D2). Strafing, circling and guard footwork come from brain-side movement
  modifiers (`C_CombatMove`, `C_TargetFollower` in XGenAI's
  `C_ModifierCollection<…, CMovementRequest&>`) that do not run on a
  suspended copy; the copy will walk straight to each sample. A facing
  target (the opponent) is the needed addition; the request field for body
  orientation was not identified. (inconclusive)
* Engaged NPCs remain under the WO-60 claim/hold model.

### 7.6 What it replaces

* the puppet transform write (`SetWorldPos` / `SetWorldAngles` at 20 Hz) —
  kept only as the snap;
* the generic locomotion loops (`relaxed_idle_both`, `3d_relaxed_*`) — the
  engine picks its own gait, turns and transitions;
* the relax tagger and the sinking mitigations — no write, no ground
  release, no seat fight on a released copy;
* the planned "activities on the wire" work becomes: stream stance and
  activity (above), apply them through R6 now and R5 later.

What stays: the pause lever (suspension is the precondition), host
authority, the leash, the claim model, name/WUID identity.

---

## 8. What the implementation WO must still establish

* Decode `C_NPCContext::RequestStateChange`'s request, or find a narrower
  NPC-state action entry, and prove sit-down / stand-up / workstation on a
  suspended copy (criterion 6).
* Queue orders from the DLL's frame hook, not from Lua (all live orders here
  came from Lua timers on the main thread; the hook is also main-thread and
  outside the brain's parallel section — inferred equivalent).
* Scale beyond 10 NPCs at 10 Hz (the ~3 % includes one debug log line per
  order, which a native call avoids).
* Two-player: everything.

---

## 9. The native per-frame transform write — the direct jitter fix

Written as a fallback; **promoted by §14**: it is the fix for the reported
jitter, and it comes before R1.

* **Where:** the DLL's existing frame hook (`C_ModulesManager::Update`,
  +3.61 ms, main thread) — after the engine's per-NPC movement pass and
  before the animation sync and render. **Observed in §14 to hold the body
  exactly** (0 mm at render every frame). ~~The frame hook is too early (the
  animated character re-bases after it)~~ — that was an inference and it
  was wrong. A later point (after `SyncAllAnimations`, before `CSystem::Render`)
  exists but was not needed.
* **Threads:** animation runs on 8 job workers (`CommandBufferExecute`), its
  finish step on main + workers; physics steps on its own thread and writes
  back at the next frame's event pump. Write only from main, only after the
  sync. (observed)
* **How:** the entity write with the transform flags Lua cannot pass
  (WO-105 §17.1: ignore-physics / user) and a living-entity position change
  with `bRecalcBounds` bit 32, so the ground collider is kept.
* **Seats:** with a late per-frame write the seat pull is invisible (§14:
  the engine pulls the body 3.3 cm toward the seat before each write; the
  renderer never sees it). R6 before suspending still stops the fight
  underneath (physics and collision follow our position instead of lagging it).
* **Animation:** still wrong — the engine's AI fragment stays idle under
  writes (§5.4). Whether `human:SetAnimMotionParam` or queuing the move
  fragment directly fixes that was not tested (inconclusive); without it the
  per-frame write keeps mannequin legs. That is R1's job.

---

## 10. Effort for the implementation WO

| piece | days |
|---|---|
| native order API in KCDMP.dll: WUID/name → `I_NPC` (NPC manager), build and queue the request with speed and exact direction, string-anchored, fail-closed | 2 |
| agent → DLL pipe for NPC samples; per-NPC follow state; apply rules §7.3 on the frame hook | 2.5 |
| drift / snap (§7.4), native teleport with bit 32 | 1.5 |
| R6 element reset at puppet start (native, or the console door from the DLL) | 0.5 |
| protocol v8 tail (speed class, stance, activity), host-side reads | 1.5 |
| R5 NPC-state requests for sit / stand / work (RE + probe + wiring) | 3–5 |
| synthetic suites, solo live gates (the §5 runs as regressions), one two-player run | 2–3 |
| **total** | **≈ 13–16**, splittable: (a) follow + speed + snap + reset ≈ 7; (b) activities ≈ 4–6; (c) order relay later ≈ 2 |

**Do first (added by §14):** the per-frame native write (§9) — agent → DLL
pipe for NPC samples, the snapshot-interpolation ring ported to the DLL,
a native write per puppet per frame from the frame hook, Lua keeps only
toggles and policy; plus the R6 reset at puppet start. ≈ 3–4 days, and it
fixes the jitter on its own. The table above then follows for gait and
activities.

---

## 11. Stand-ins and their native reach

| probe stand-in | native reach |
|---|---|
| `wh_ai_PauseNPC` / `ResumeNPC` (console) | `C_IntelligentObject::Suspend/Resume` `0x1612290` (WO-107) |
| `wh_ai_RequestDebugMovement` (console) | `QueueMovementRequest` worker `0x19b5ad0` (typed args), or its body: request ctor `0x1a6ee50`, path request, queue `0x1a6dd60`; the worker logs one trace line per call |
| probe DLL write of `+0xF8` | a field in the request the DLL builds itself |
| `wh_ai_NPCStateResetElement` (console) | `C_NPCStateDebug::ResetCurrentStateElementCommand` `0x189ad70`; element names parsed by `0x141ba10` (`Stance`, `LeftHand`, `RightHand`, `Unstance`, `ChangeEquipment`, `Minigame`, …) |
| `actor:GetCurrentAnimationState()` (Lua) | the actor's current Mannequin fragment; native read not traced |
| `entity:SetWorldPos` (D1 snap) | `IEntity` world transform (+ bit 32, §9) |
| `human:DrawWeapon` | native draw path (WO-47) |
| the probe DLL itself | research only: inline hooks on 24 functions with a register-preserving thunk, per-thread call counts, a main-thread entry ring for frame order, a queue-chokepoint log. Never shipped; not in the repository |

---

## 12. Corrections and additions to the record

* **WO-105 §6.3 / §19 ("IMovementController on KCD2 — inconclusive"):**
  answered. The stock movement pipeline is present and live; Warhorse's
  controller is `C_ActorMovementController`; the reachable door is one level
  up, at the movement request.
* **WO-107 §9 (`SchedulerProxy` as "a body scheduled by something outside
  the AI"):** it is the entity whose activity links the scheduler subbrain
  follows — a decision-layer input. Not a body-driving route.
* **WO-107 §10 ("~14 s between ResumeNPC and first motion"):** ~1 s for a
  walker and 5–20 s for NPCs walking back to activities, this session.
* **WO-107 §4 (the position-relax, root cause open):** for seated NPCs it is
  the seat's alignment (4.1 %/tick toward the seat), absent for walkers and
  for non-aligned activities, removed by a stance reset.
* **WO-105 §16 (stock frame, "main-thread entity phases"):** on this build
  the per-character pre-physics update runs on main + 8 job workers, and the
  brain queues movement from workers.
* **`MP-NPCFIGHT` / `MP-AUTHORITY-VIOLATION`:** a stream target inside
  geometry produces a constant push-out that both detectors count as a
  fight (§1, B′).
* `actor:GetCurrentAnimationState()` is a working, cheap Lua read of what an
  NPC is doing (fragment names); `QueueAnimationState`, `SetAnimationInput`,
  `SetSpeedMultiplier` and `ChangeAnimGraph` are documented but **not
  registered** on this build. (observed with `type()`)
* `Physics.RayTraceCheck` returns **true for a clear segment** and only tests
  static geometry and terrain (stock semantics; observed).
* No detail from the other project's developer was passed on this session;
  §7 applies the technique as described in the prompt (target and speed fed
  to the character's own movement, occasional corrections).

---

## 13. Address index

| what | binary | RVA |
|---|---|---|
| `C_MovementRequestDebug::RequestDebugMovement` (console) / `QueueMovementRequest` (worker) / `CancelDebugMovement` | XGenAIModule | 0x19b3b80 / 0x19b5ad0 / 0x19b48b0 |
| movement request ctor / dtor / exact-pos setter | XGenAIModule | 0x1a6ee50 / 0x507cd0 / 0x1a6ef30 |
| movement-task manager: queue / get-or-create task / start / cancel | XGenAIModule | 0x1a6dd60 / 0x1a6e870 / 0x1a6a350 / 0x1a6aa80 |
| speed enum → name / throttle CVars | XGenAIModule | 0x1a367f0 / 0x1a36400 |
| BT `C_MoveBase` request build / `RequestNPCStateChange` | XGenAIModule | 0x506840 / 0x504fd0 |
| activity `MoveBaseActivity` order / NPC-state subsequent move | XGenAIModule | 0x155ccf0 / 0x1630c30 |
| `C_NPCContext::RequestStateChange` / `ClearCurrentSearchState` | XGenAIModule | 0x1881090 / 0x1883590 |
| `C_NPCStateDebug::ResetCurrentStateElementCommand` / element-type parser | XGenAIModule | 0x189ad70 / 0x141ba10 |
| `C_SchedulerManager::ChangeSchedulerProxy` / `C_NPCManager::InitializePlayerSchedulerProxy` | XGenAIModule | 0x1994ec0 / 0x161bf70 |
| `C_NPCManager::UpdateIntellects` (WO-107) | XGenAIModule | 0x1619be0 |
| globals: gEnv / NPC manager (`vtbl+0x20` = NPC by entity id) / movement root (`vtbl+0xA8` → `vtbl+0x110` = task manager) | XGenAIModule | 0x2e46b88 / 0x2e52f08 / 0x2e55858 |
| `CAIProxy::Update` | CryAction | 0x29d40 |
| `CAnimatedCharacter::Update / GenerateMovementRequest / PostProcessingUpdate / CalculateAndRequestPhysicalEntityMovement / CalculateWantedEntityMovement / RequestPhysicalEntityMovement / AcquireRequestedBehaviourMovement / UpdateMCMComponent` | CryAction | 0x60d60 / 0x640b0 / 0x66200 / 0x66e30 / 0x670b0 / 0x67c80 / 0x65660 / 0x6cc60 |
| `CCryAction::PreSystemUpdate` / `PostUpdate` | CryAction | 0x85230 / 0x85d60 |
| `C_ActorMovementController::Update` / `C_ActorStateUtil::FinalizeMovementRequest` | EntityModule | 0xb18d0 / 0xcbd80 |
| `SFinishAnimationComputations` / animation job body / `CJob::Begin` / `SyncAllAnimations` | CryAnimation | 0xac6b0 / 0xac2e0 / 0xace00 / 0xc55e0 |
| `CLivingEntity::Step` / `CLivingEntity::Action` | CryPhysics | 0xa4360 / 0xb16c0 |
| `CSystem::Update / RenderBegin / Render / RenderEnd / UpdateAfterSystem` | CrySystem | 0x1e7290 / 0x209180 / 0x20bdd0 / 0x209400 / 0xe3830 |
| `CEntitySystem::Update` | CryEntitySystem | 0xe7eb0 |
| `C_ModulesManager::Update` (export) | Framework | 0x8d550 |

Warhorse movement request (ctor `0x1a6ee50`), fields used: `+0x00` `I_NPC*` ·
`+0x08` path request (`S_PathFindingRequestDefault`, 0xA0 B: `+0x08` agent
type, `+0x58` start, `+0x64` flags, `+0x80` target) · `+0x10` segment list ·
`+0xBC` exact flag · `+0xF8` speed enum (default 1) · `+0xFC` 7 ·
`+0x110` −1.0f · `+0x114` −2.0f · `+0x258` debug name.
`C_MovementTask` (0x2B0 B, one per NPC, keyed by soul WUID): `+0x08` `I_NPC*` ·
`+0x10` current request id (−1 none) · `+0x18` path request · `+0x160` speed ·
`+0x16C` logical speed · `+0x2A0` cancel flag. (code-verified)

---

## 14. Follow-up — per-frame render traces: the write's rate and moment

Run the same day at the maintainer's request, after a note from the
OblivionMP developer (julkiewicz): jitter usually means the overrides land at
the wrong point of the frame or on the wrong thread; receive at network rate,
interpolate, apply every frame exactly before the value is used. Solo, fresh
process, `quicksave032`, no agent.

**Method.** A third research probe DLL hooked two main-thread points: the
DLL's own frame hook (`C_ModulesManager::Update` entry, +3.6 ms) and
`CSystem::Render` entry (+4.9 ms). For one tracked NPC it logged, **every
frame**, the entity's world position at the hook and at render (read from the
entity's world matrix; cross-checked once against the engine's
`GetWorldPos`: identical). Optionally it wrote the position every frame at
the hook with `IEntity::SetPos` (vtable 0x138, **no flags** — the same
unflagged write Lua's `SetWorldPos` makes, so only rate and moment differ).
Three writers on the same line, same NPC:

* **today** — the mod's own puppet path, `KCD2MP_ApplyNpcState` at 100 ms,
  its 50 ms Lua tick, interpolation-behind ring, walk loop;
* **Lua every frame** — the same, with `npcPuppetTickMs = 10`;
* **DLL every frame** — the probe's write at the frame hook.

**Walking NPC** (`ttkc_slama`, suspended mid-walk, no seat), a clear 10 m
line at 1.4 m/s, ~74 fps, ~420 frames scored each (observed):

| writer | per-frame step at render | frozen frames | per-frame speed | pattern |
|---|---|---|---|---|
| today (Lua, 50 ms) | mean 1.88 cm, sd 3.28, max 7.78 | **315 / 419 (75 %)** | 1.33 m/s, **sd 2.32** | `0 0 0 75 0 0 0 76 0 0 0 78 …` mm |
| Lua every frame | mean 1.91 cm, sd 0.08 | 0 | 1.40, sd 0.06 | `19 18 19 20 18 18 21 …` |
| DLL every frame | mean 1.90 cm, sd 0.08 | 0 | 1.40, sd 0.01 | `19 20 19 19 18 19 20 …` |

**Seated NPC** (`ttkc_woman_2`, suspended in her seat), held 3 m from the
seat on a clear point, ~70–72 fps (observed):

| writer | rendered offset toward the seat, per frame | frames that move |
|---|---|---|
| today (Lua, 50 ms) | **0 → 42 → 83 → 123 mm, snap, repeat** (mean 6.2 cm) | 432 / 432 |
| Lua every frame | **42 / 0 / 42 / 0 mm** (mean 2.1 cm) | 435 / 435 |
| DLL every frame | **0 mm** | 0 / 417 |

At the DLL's hook, before its write, the engine had already pulled the
body 3.3 cm toward the seat each frame (10.2 cm at 28 fps in a run taken while
the game window was unfocused); the renderer never saw it. (observed)

**What it shows.**

* **Rate.** A 50 ms Lua tick against ~74 fps leaves three of four rendered
  frames unwritten. On a free NPC that is a stair-step (frozen, frozen,
  frozen, jump); on a seated NPC the engine's pull shows in the unwritten
  frames as a sawtooth. This is the jitter the testers saw. (observed)
* **Moment.** Writing every frame from Lua fixes the free NPC but not the
  seated one: the Lua write lands early in the frame, and on alternate
  frames the engine's own update (the physics write-back, on the frames
  physics stepped — inferred from the 1-on/1-off pattern; stock order puts
  the script update before the physics event pump, WO-105 §16) replaces it
  before render. The same write at the DLL's frame hook — after the engine's
  NPC movement, before render — holds exactly. (observed; the mechanism for
  the alternation inferred)
* **Thread.** Not the problem: Lua runs on main, which is where entity
  positions are set. The OblivionMP failure mode ("overrides landing at
  random times relative to the game's update") is reproduced here by the
  *phase and rate* of a main-thread script timer.
* **Engine fight underneath.** The late write wins at render, but the
  engine still acts in between: the seated body is pulled 3.3 cm per frame
  before each write, and on the walker the physics body lags ~0.9 cm per
  frame. Invisible on screen; it matters for collisions and ground contact —
  hence the R6 reset for seats and the bit-32 write (§9) in the
  implementation.

**Caveats.** Solo, a locally generated stream (no network timing noise —
the DLL port must keep the WO-110 sender-clock ring), constant Z (sinking not
examined), one walking and one seated NPC, the DLL writer ran without the walk
loop (position only — gait is unchanged by this fix). The first DLL seat run
happened at 28 fps (window unfocused) and was repeated at matched frame rate.

**Artefacts** (in `<scratch>`, not committed): the probe source, both
per-frame CSVs per run, the probe log, the session `kcd.log`.
