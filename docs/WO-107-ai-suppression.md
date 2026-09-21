# WO-107 — every way to suppress an NPC brain

Session 2026-09-21, solo, against the running 0.26.3 Modding Tools build.
Progress/gaps: `docs/WO-107-progress.md`. Prerequisites read:
`docs/WO-105-cryengine-reference.md`, `docs/WO-105-contradictions.md`,
`docs/WO-106-findings.md`.

Evidence marks: (observed) / (code-verified) / (synthetic) / (inconclusive).
**No code was written, no pak rebuilt, no version bumped.**
**Nothing in this WO ran two-player.**

---

## 0. Answer first

**The mechanism exists, it is shipped, and it already had a console door
we were using. `wh_ai_PauseNPC` was never broken.**

* `wh_ai_PauseNPC <name>` routes to **`C_IntelligentObject::Suspend`**
  (`Brain/IntelligentObject.cpp:155`), a **multi-owner, latched,
  per-context suspend** on the NPC's intelligent object. (code-verified)
* Live, on four arbitrary world NPCs: self-direction stops dead, the body
  stays fully driveable, and it **latches** — one subject held **0.00 m /
  0.00 rad for ~50 minutes** across a 38 Hz transform stream, a melee
  beating, and the player leaving and returning. (observed)
* **WO-104's "0/155" was a misdiagnosis.** The `paused=1` field means *the
  mod believes it issued a pause*, and the thing it then measured as "the
  local brain still writes" is **not the brain**: it is an engine
  position-relax that happens **identically to paused, unpaused and
  `NoAI` bodies, and with the mod's own NPC sync switched off.** (observed,
  §4)
* **Phase 2: `NoAI` is NOT reversible** — it is a construction-time bool
  port (offset `0x188`) on the spawn action's port table, read once.
  (code-verified) **But the question is moot**: the port table's immediate
  sibling is **`SuspendedAI` (offset `0x1C0`)**, and that state's runtime
  setter is exactly the `Suspend`/`Resume` pair above. The spawn-time flag
  we have been relying on has a runtime twin we had never found.

**Recommendation: `wh_ai_PauseNPC` / `wh_ai_ResumeNPC`, i.e.
`C_IntelligentObject::Suspend`/`Resume`. Scores 5/5 on criteria observed
solo.** Runner-up and losing reason in §8.

---

## 1. Phase 1 — the tick

| what | address | evidence |
|---|---|---|
| `C_NPCManager::UpdateIntellects` | RVA **0x1619BE0** (VA 0x181619BE0) | code-verified |
| …delegates the real work to | RVA **0x161A4E0** | code-verified |
| `C_NPCManager::RegisterNPCInternal` | RVA **0x160C620** | code-verified |
| `C_NPCManager::UnRegisterNPC` | RVA **0x160D5F0** | code-verified |
| `C_IntelligentObject::Suspend` **and** `::Resume` (one function) | RVA **0x1612290** | code-verified |
| pause/resume request queue drain (`"NPC pause/resume request for %zu NPCs"`) | RVA **0x161C800** | code-verified |
| `C_XGenAICommands::PauseNPCInternal` (the console command) | RVA **0x1AE5360** | code-verified |
| spawn-action port table (`NoAI`, `SuspendedAI`, …) | RVA **0x5EFED0** | code-verified |

Module: `XGenAIModule.dll` (51 MB) from the Modding Tools build, image
base 0x180000000. Ghidra 12.1.3 headless, full auto-analysis. There are no
PDBs, but **the DLL embeds fully-qualified `__FUNCTION__` strings and
source paths**, so functions are identifiable by the literals they
reference — this is the WO-42 memory fact, and it is what made the whole
phase tractable. 4,933 `wh::xgenaimodule::*` names recovered.

**Shape: budget-driven batch loop (shape 1 of the four).**
`UpdateIntellects` is a thin profiler wrapper; it computes
`floorf(frameDelta * k)` — a per-frame update budget — and passes it down.
(code-verified) That is WO-105 §7.2's time-sliced model surviving into the
Warhorse fork, which §7.5 had explicitly flagged as *unverified* for this
build. It is now verified.

**Decision vs locomotion — separable, and this matters.**
Suppressing the intelligent object stops decision-making; the log says so
in the engine's own words (`Node status inconsistency. Can't update
suspended node!` — observed). It does **not** stop the lower layer that
relaxes a body toward its anchor (§4). Those are different layers, exactly
as the WO predicted — but the residual layer turns out **not** to be a
brain writing, and not to need suppressing at all.

---

## 2. Phase 2 — `NoAI`, traced

The `NoAI` string exists **once** in the entire module, inside a spawn
parameter cluster (code-verified):

```
EntityClass@0x40 · Pos@0x78 · SharedGuid@0xB0 · LayerReferenceEntity@0xE8
TagPoint@0x110 · … · NoAI@0x188 · SuspendedAI@0x1C0
PerceptorObjectAI@0x1F8 · PerceptibleObjectAI@0x230 · SchedulerProxy@0x290
```

These are registered as **input ports on a BehaviorTree spawn action node**
(RVA 0x5EFED0), each by name and struct offset. `NoAI`, `SuspendedAI`,
`PerceptorObjectAI` and `PerceptibleObjectAI` all register through the
*same* registrar function, i.e. they are the same type (bool ports).
(code-verified)

**Answer: no, `NoAI` is not reversible at runtime.** It is not a flag read
every tick; it is a construction parameter consumed once when the spawn
action builds the entity. No runtime setter for it exists anywhere in the
module's symbol set. (code-verified)

**But the answer that matters is the sibling.** `SuspendedAI` is the
spawn-time form of the *runtime* suspend state, and that state has a
first-class runtime API — §3. `XGenAIModule.SpawnEntity{SuspendedAI=true}`
is accepted by the Lua bind and the resulting body did not self-direct over
8 s (observed, weak — a freshly spawned NPC standing still is not strong
evidence, and it was not driven or held).

Also recovered, not pursued: **`SchedulerProxy` is a spawn parameter**, the
player is set up through `C_NPCManager::InitializePlayerSchedulerProxy`,
and `scheduler::C_SchedulerManager::ChangeSchedulerProxy` exists as a
runtime call. That is "how the engine models a body a human drives." It is
the most interesting unexplored lead in this WO (§9).

---

## 3. Phase 3 — `wh_ai_PauseNPC`, autopsied

### 3.1 What it is

Console help, from the binary (code-verified):

> `wh_ai_PauseNPC` — *"Pauses the execution of the NPC with given name.
> **Debugging of the pausing system only**"*
> `wh_ai_ResumeNPC` — *"Resumes the execution of the NPC with given name…"*

It takes a **name argument**, and it is explicitly a *debug door into a
pausing system* — the system is the product, the command is the handle.
Adjacent literals: `"Testing NPC pause request ended with %s"`,
`"NPC pause/resume request for %zu NPCs"` (plural — it is a batch request
queue), and the CVar `wh_ai_NPCPauseRequestDebugDraw` — *"Enables debug
draw of NPC pause requests. This include resum request as well."*

### 3.2 What it gates — the bitmask

`C_IntelligentObject::Suspend`/`Resume`, RVA 0x1612290 (code-verified):

* the intelligent object carries a **state enum at `+0x128`**
  (0 = running, 1/2 = suspended) and a **suspend-reason bitmask at
  `+0x129`**;
* a request record carries **type at `+0x48`** (`0` = suspend, `1` = resume)
  and the requester's **context bit at `+0x4C`**;
* **suspend**: `mask |= bit`; if the object was in state 0, call vtable
  `+0x1C0` with `1` and notify the object at `[0x17]` via vtable `+0x68`;
* **resume**: `mask &= ~bit`; **only when the mask reaches zero** does it
  call vtable `+0x1C0` with `0` and notify via `+0x70`. Otherwise it logs
  *"Trying to resume intelligent object %s in context (%d), but it is
  still suspended in other contexts (%d)."*
* resuming a context that never suspended logs *"…in context (%d) in which
  it was not suspended."* and does nothing.

**This is a multi-owner latched suspension keyed by requester context.**
It is why the state is robust: the game's own subsystems suspend and resume
NPCs constantly for their own reasons, and they cannot clear *our* bit.

### 3.3 What clears it — **nothing did**

The WO asked which of five candidates re-enables the brain. Tested live,
each against a subject that stayed suppressed throughout:

| candidate clearer | result |
|---|---|
| the mod's own transform write | **does not clear it** — 150 writes at 38 Hz then 40 more; still 0.00 m (observed) |
| damage / being struck | **does not clear it** — beaten in melee, flinched, bled, screamed, never fought back (observed) |
| combat entry | **does not clear it** — applied *to an NPC mid-fight*: 6.05 m → 0.12 m, 1.46 → 0.00 rad (observed) |
| proximity change | **does not clear it** — player walked away and returned; still 0.00 m (observed) |
| the AI system resetting it on its own update | **no self-resume** — held ~50 minutes (observed) |
| needing continuous re-issue | **no** — issued once, latched (observed) |

**So the honest Phase 3 answer is: the clearer was never found, because on
this build there is nothing to find.** The lever is latched and it holds.

### 3.4 Why WO-104 read 0/155

`mp_wo102_pause` sets `KCD2MP._npcPaused[name]` and then calls
`System.ExecuteCommand`. The `paused=1` in `MP-AUTHORITY-VIOLATION` reports
**the Lua table**, not engine state — so the field can only ever say "we
tried". What the violation detector then saw at `dist_m=0.41` was the §4
position-relax, which is not the brain. **Both the Lua path and the HTTP
console path were re-tested this session and both work** (6.08 m → 0.00 m
via `System.ExecuteCommand`, observed), so the mod's call site was never
the problem either.

---

## 4. The position-relax — what WO-104 actually measured

Not an AI mechanism. Recorded here because it has been misread twice.

Write a live NPC's transform and stop writing: the body returns to its
pre-write anchor on a **clean exponential decay**, yaw frozen throughout.
Measured sample-to-sample: 1.68 → 0.54 → 0.185 → 0.059 → 0.017 → 0.005 m,
ratio ≈0.32, settling in ~5 s. (observed)

It is **not** the brain and **not** the mod:

| subject | pulled back? | evidence |
|---|---|---|
| paused NPC | yes | observed |
| unpaused NPC | yes, identically | observed |
| paused NPC, mod `mp_npc_sync off` | yes | observed |
| **unconscious** NPC | **no — stays exactly where put** | observed |
| `NoAI` mod ghost | yes (but the mod pins its own ghosts — confounded) | (inconclusive) |

The unconscious row is the discriminator: the relax is tied to the
**living/animated** state, which rules out plain physics→entity writeback
(WO-105 §4.5) as a complete explanation — a ragdoll has a physics proxy
too. Root cause not established this WO. (inconclusive)

**It does not block the architecture.** Under a stream the writes win
outright: 40 consecutive write-then-readback pairs on a paused NPC
returned **err = 0.000, every one**. (observed) The relax only appears when
the stream stops, which is precisely when you want the body released.

---

## 5. Phase 0 — the vanilla catalogue

**Substantially incomplete — see `docs/WO-107-progress.md` §2.** Rows that
were actually measured, not inferred:

| state | 1 stops self-direction | 2 body driveable | 3 runtime/arbitrary | 4 survives events | 5 clean release | evidence |
|---|---|---|---|---|---|---|
| **suspended (`wh_ai_PauseNPC`)** | **yes** 21.45→0.42→0.00 m | **yes** err=0.000, anim on, visibly idle-animating | **yes**, 4 world NPCs | **yes** stream/damage/combat/proximity | **yes**, ~14 s to first motion | observed |
| **unconscious** | yes (trivially) | **NO** — `anim=false`; transform writes land err=0.000 and there is **no** relax, but it is an inert body | no (needs a takedown) | untested | wakes on its own | observed |
| conversation partner | **(inconclusive)** — subject was already stationary before the dialogue, so there was nothing to suppress | animation stays on (`anim=true` throughout) | n/a | n/a | n/a | observed but non-discriminating |
| dead (control) | — | fails by definition | — | — | — | not run |
| cutscene actor · scripted scene · sleeping · sitting/working · bound/pillory · companion wait · minigame · mount ridden · trespass freeze | — | — | — | — | — | **not run** |

The catalogue's *instrumental* purpose — pointing Ghidra at the right
function — was served by the string/symbol sweep instead (§1), which found
the primitive directly. Its *deliverable* purpose is not met.

---

## 6. Phase 5 — the surface sweep

**790 distinct `wh_ai_*` symbols** extracted from `XGenAIModule.dll`
(code-verified); the ones that touch the tick are here. `wh_ai_*` lives
essentially only in this module (132 string hits vs 1 in `WHGame.dll`,
1 in `EntityModule.dll`, 11 in `CryAISystem.dll`).

Verified live as registered on this build (observed):
`wh_ai_UpdateSuspenderEnabled = 1`, `wh_ai_UpdateEnabled = 1` (CVars);
`wh_ai_PauseNPC`, `wh_ai_ResumeNPC`, `wh_ai_UpdateSuspenderRemoveAll`
(commands, all accepted a bare invocation).

| symbol | what it actually is | candidate? |
|---|---|---|
| `wh_ai_PauseNPC` / `ResumeNPC` | the recommendation | **yes** |
| `wh_ai_UpdateSuspenderEnabled` | help: *"Enables update suspension during profile steaming"* [sic] — tied to navmesh **profile streaming**, global, not per-NPC | no |
| `wh_ai_UpdateEnabled` | global AI on/off | no — fails criterion 3 (not per-NPC); **untested live**, deliberately: flipping it would have frozen every NPC in the maintainer's live session |
| `wh_ai_suppressAddingActorsIntoCryAI` | registration into the *stock* CryAI, which KCD2 does not use for behaviour | no |
| `wh_ai_NPCDryUpdateMode` | the cheap non-full update from WO-105 §7.2 — confirms the pattern exists here | no (global mode) |
| `wh_ai_LOD_Hide`, `wh_ai_NPCHideCheck`, `wh_ai_NPCHidePPU` | AI LOD hiding | not pursued |
| `wh_ai_scheduler_corpseDisablingRange` | the game disables brains near corpses — an existence proof, not a handle | not pursued |
| `wh_ai_PlayerSchedulerProxy`, `wh_ai_PlayerHorseSchedulerProxy` | how the engine models a human-driven body | **§9 lead** |
| `wh_ai_TransformManager*` | an **area notifier** (`RegisterArea`/`ReportMovementImpl`) — observation, not restoration; **not** the §4 relax | no |

**Lua scriptbind surface** (`C_ScriptBindXGenAIModule`, code-verified) —
21 methods, and **no suspend among them**:
`AddLink FindLinks GetBrainVariable GetEntityByWUID GetOwner GetResourceId
IgnorePerception IsOneshotAvailable IsOneshotBlocked IsPointInAreaWithLabelWUID
IsStanceAvailable IsStanceBlocked IsUnstanceAvailable IsUnstanceBlocked
MakeTableFromType ProduceSound ProduceSoundWUID SetBrainVariable
SetPlayerDogMode SpawnPerceptibleVolumeOnWUID _GetDataVariable _SetDataVariable`

So the runtime door really is the console command — which is fine, because
`System.ExecuteCommand('wh_ai_PauseNPC <name>')` from Lua was re-verified
working this session (observed). `IgnorePerception` and
`Get`/`SetBrainVariable` are unexplored and relevant to §10's side effects.

---

## 7. The ranking

| mechanism | reachability | 1 | 2 | 3 | 4 | 5 | side effects | effort |
|---|---|---|---|---|---|---|---|---|
| **`wh_ai_PauseNPC` → `C_IntelligentObject::Suspend`** | console cmd; **Lua via `System.ExecuteCommand` (proven)**; native RVA 0x1612290 | **PASS** obs | **PASS** obs | **PASS** obs | **PASS** obs (solo); two-machine + save/reload **(inconclusive)** | **PASS** obs | withdrawn from skirmish; attacked-while-paused did **not** raise a guard crime response; ~14 s resume latency | **none — already wired, toggle exists** |
| `SuspendedAI=true` at spawn | Lua spawn param | PASS obs (weak) | untested | **FAIL** spawn-only | untested | n/a | same family as above | low |
| `NoAI=true` at spawn | Lua spawn param | PASS (prior WOs) | PASS (prior WOs) | **FAIL** spawn-only, **not reversible** (code-verified) | n/a | n/a | known | n/a |
| unconscious | not programmatic | PASS obs | **FAIL** — `anim=false`, inert body | **FAIL** | untested | wakes on its own | a visibly unconscious body cannot be a walking puppet | n/a |
| `wh_ai_UpdateEnabled 0` | CVar | presumed | presumed | **FAIL** — global | untested | untested | freezes every NPC | n/a |
| `wh_ai_UpdateSuspenderEnabled` | CVar | — | — | **FAIL** — profile-streaming scope | — | — | — | n/a |
| `C_NPCManager::UnRegisterNPC` | **hook-only**, RVA 0x160D5F0 | untested | untested | untested | untested | untested | unknown; likely breaks damage/dialogue/quest wiring | high |
| native detour on `UpdateIntellects` (Phase 6) | hook-only, RVA 0x1619BE0 → 0x161A4E0 | — | — | — | — | — | batch loop ⇒ needs a filter *inside*, not a skipped call | high — **and unnecessary** |

---

## 8. Recommendation

### Use `wh_ai_PauseNPC` / `wh_ai_ResumeNPC`.

It is the engine's own shipped suppression primitive, it is latched and
multi-owner so the game cannot clear our bit, it leaves the body fully
driveable and animating, it applies to any already-spawned world NPC at
runtime, it survives everything this WO could throw at it solo, and it
releases cleanly after ~50 minutes of suppression. **The mod already calls
it** (`mp_wo102_pause`), already has a toggle (`mp_authority_pause`), and
already has a resume-on-disconnect path. Nothing needs building.

**What should change is the belief that it does not work, and the metric
that produced that belief** — `MP-AUTHORITY-VIOLATION`'s `paused=` field
reports a Lua table, and its `dist_m` is measuring the §4 relax, not a
brain. Per `memory/kcd2mp-ship-new-features-on.md` this argues for turning
`mp_authority_pause` **on**, but that is the maintainer's call and this WO
ships nothing.

### Runner-up: `SuspendedAI=true` at spawn — and why it lost

It reaches the same engine state and is the honest answer to "what is
`NoAI`'s reversible sibling". It lost on **criterion 3**: it is a spawn
parameter, so it only helps bodies the mod creates, and the architecture
needs suppression on **NPCs the world already spawned**. It is worth
keeping in mind for replica spawns, where it is strictly better than
`NoAI` because the body can be resumed.

### Not recommended: the Phase 6 native detour

`UpdateIntellects` is a **budget-driven batch loop**, so suppression there
means filtering *inside* the loop rather than skipping a per-entity call —
more invasive, and it would sit on top of a shipped primitive that already
does the job correctly. Recorded, not pursued.

---

## 9. The one lead worth a future WO

**`SchedulerProxy`.** It is a spawn parameter (offset 0x290); the player is
initialised through `C_NPCManager::InitializePlayerSchedulerProxy`; there
is a runtime `C_SchedulerManager::ChangeSchedulerProxy`; and there are
CVars `wh_ai_PlayerSchedulerProxy` / `wh_ai_PlayerHorseSchedulerProxy`.
That is the engine's own model of *a body scheduled by something outside
the AI*, which is exactly what a puppet is. Untouched this WO.
(code-verified that the symbols exist; nothing else)

---

## 10. Side effects to carry forward

* **Attacking a paused NPC did not raise a crime response.** The victim
  screamed (`COMBAT_VICTIM_SCREAM_RECEIVED_HIT`, three times) and bled, but
  a nearby guard treated the player as swinging at air rather than at an
  NPC. (observed) This is the opposite of
  `memory/kcd2mp-ghost-vanilla-systems.md` (a ghost is a full crime
  victim) and it is a real behavioural divergence. Mechanism not
  established — `IgnorePerception` and the `PerceptibleObjectAI` port are
  the obvious places to look.
* **`Removing skirmish soul` / `Soul … disconnection from npc`** appeared
  immediately after a mid-combat pause — but both lines occur **92 and 184
  times** respectively across the session on NPCs never touched, so they
  are routine churn and **cannot be attributed to the pause**.
  (inconclusive — recorded because the temporal coincidence is misleading.)
* **`wh_ai_PauseNPC Dude` (the player) did nothing** — the player kept
  moving 56.6 m. (observed, accidental)
* **~14 s between `ResumeNPC` and first motion.** The brain re-plans before
  it moves. Acceptable for "snap back to local control", but it is not
  instantaneous and a release should not be timed against it.
