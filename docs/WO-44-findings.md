# WO-44 — combat-swing fidelity, Phase 2: why rung 1 stalls, decompiled. Direction B is required.

Worked 2026-08-22 (Fable 5). This is the Phase 2 handoff WO-43 called for: a
disassembler pass on the one function WO-42 traced *to* but never read *into* —
`EntityModule.dll+0xAE17A0`, the concrete target `C_Actor` vtable slot `+0xE48`
resolves to, which WO-43 live-tested three times and found produces a
reproducible, broken partial swing. WO-43 was forbidden a disassembler; this
session was told to open one, and did (Ghidra 12.1.3, the WO-42 pipeline, the
WO-42 projects reused — §7).

**Evidence classes, as elsewhere in this project:** observed (read directly out
of the disassembly this session) / read-but-unrendered (a mechanism traced in
code but never executed in a running game) / inferred (a step beyond the bytes,
labelled). No game was launched this session — everything below is static, and
the one new native artifact is a *precondition probe* that a future session with
a human at the machine will run (§6).

---

## 0. Verdict

**Direction A is closed, decisively and by decompilation: rung 1 (the
`PlayAnim` / `vtbl+0xE48` call) fundamentally cannot produce a complete combat
swing, and no cheap precondition salvages it.**

`EntityModule.dll+0xAE17A0` is `C_Player::PlayAnim`. It is a **generic
single-fragment player**: it parses the fragment name into a fragment ID, parses
the tag string into a 20-byte `TagState`, allocates a **bare
`TAction<SAnimationContext>` (0x90 bytes)**, and queues it through
`IActionController::Queue` (+0x98). It **never constructs a combat action, never
touches the combat-actor state machine, never resolves an attack descriptor, and
never installs the combat lifecycle delegates.** (§1, observed.)

That is exactly why a combat swing stalls partway. A self-contained fragment
(a jump — `MotionJump`, WO-40) plays to completion as a bare `TAction` because
nothing else has to drive it. A combat attack is **not** self-contained: in the
game's own code it is entered by `C_CombatActorActionAttack::EnterImpl`
(WO-42 §5.2), which builds a `C_CombatAnimAction` (0x1A8, ten times the machinery
of a bare `TAction`) and queues it through the actor's **`C_CombatAnimActionManager`**,
wrapped in combat-state pre-roll, an attack helper, lifecycle delegates and
post-queue attack selection. Queue the same fragment ID + tags as a *bare
`TAction`* and the character enters the motion (draws the weapon, begins the
swing) but nothing advances the combat scopes/transition tags to completion — a
stuck partial pose. **This is precisely WO-43's three-times-reproduced
observation, now explained.** (§3.)

There is **no branch** in `0xAE17A0` that would ever build a combat action; it
unconditionally allocates the 0x90 bare `TAction`. So "add one precondition and
rung 1 works" is ruled out: the primitive is the wrong primitive, not a
correctly-shaped call missing a flag.

**Therefore Phase 2 must take direction B** — build and queue a real combat
action object. This session re-verified direction B's entry points against the
installed binaries (§4), wrote a complete rung-2/rung-3 construction spec (§5),
and shipped a **safe precondition probe** (`combat_construct.cpp`, §6) that
resolves the ghost's `I_CombatActor*` and logs every pointer the construction
route consumes — so the next session can confirm the inputs resolve on a live
ghost before allocating or queueing anything.

**One correction to WO-43's framing, carried honestly:** WO-43 (and this
session's brief) call `0xAE17A0` "the concrete implementation `C_Actor::vtbl[+0xE48]`
resolves to." That is exactly right for the **player** — `0xAE17A0` is
`C_Player`'s `+0xE48` and the only vtable in the whole module that carries it
(§2). It is **not** literally the same function for a non-`C_Player` actor: the
byte offset `+0xE48` is a `C_Player`-specific slot (`C_Human`'s primary vtable is
shorter and has nothing there). What ran on the *ghosts* in WO-43 was therefore
either a `C_Player`-layout actor's `0xAE17A0`, or a class-sibling of it — the
same *kind* of bare-fragment player (the observed behaviour was identical). The
probe in §6 settles which, by logging the ghost actor's vptr. This does not
change the verdict — a bare-fragment player, of whatever class, cannot complete a
combat swing — but the project's evidence discipline requires the distinction be
stated, not rounded over.

---

## 1. `EntityModule.dll+0xAE17A0` = `C_Player::PlayAnim`, fully read

RVA `0xAE17A0`, image base `0x180000000` → `0x180AE17A0`. **Observed** (the
Ghidra decompilation and disassembly are reproduced in the scratch outputs;
`native/ghidra_scripts` regenerates them, §7). It is not string-anchored — the
`PlayAnim` Lua-registration string lives in the *caller*
(`C_ScriptBindHuman`), not here — but it is reached unambiguously three ways:
it is `C_Player::vftable` slot `[457]` = byte `+0xE48` (§2); it is what
`C_ScriptBindHuman::PlayAnim` (`0xB3D5C0`) calls at `+0xE48` (§2); and WO-43's
native diagnostic on the actual player logged `actor->vtbl[+0xE48] =
EntityModule.dll+0xAE17A0` at runtime (WO-43 §4).

Annotated reconstruction (register/offset facts from the disassembly, not the
decompiler's parameter guesses):

```c
void C_Player__PlayAnim(longlong* self,           // RCX  the C_Player (C_Actor)
                        const char* fragmentName,  // RDX
                        byte*       tags)          // R8   "tag1+tag2+..." or null
{
    // ---- 1. fragment name -> fragment ID -----------------------------------
    uint32 nameCrc   = crc32_lower(fragmentName);                 // FUN_180123C40
    void*  animChar  = self->vtbl[0x2D0](self);                   // GetAnimatedCharacter
    void*  animCtrl  = animChar->vtbl[0x130](animChar);           // GetActionController
    void*  ctx       = animCtrl->vtbl[0xB8](animCtrl);            // controller context
    int    fragmentID = FindFragmentIndex(ctx->[+0x18], nameCrc); // FUN_180123CB0
    if (fragmentID == -1) return;                                 // unknown fragment: no-op

    // ---- 2. tag string -> 20-byte TagState ---------------------------------
    uint8 tagState[20] = {0};
    if (tags && *(int*)(tags - 8) /*len*/ != 0) {
        // split on '+', CRC32-lower each tag, look it up in the context's tag
        // definition table, and set/clear the corresponding TagState bits.
        // (This is the whole middle of the function -- it works: the fragment
        //  DOES start playing, so the parse is correct.)
        ... per-tag: local_60[group] |= bit; ...
    }

    // ---- 3. stop whatever is currently playing -----------------------------
    self->vtbl[0xE50](self);         // C_Player slot [458] = clears self+0xD50

    // ---- 4. allocate a BARE action -- 0x90 bytes ---------------------------
    void* action = CryMalloc(0x90);                              // <-- the tell
    void* built  = nullptr;
    if (action)
        built = TAction_ctor(action, /*priority*/ 5, fragmentID, tagState); // FUN_180121300

    // ---- 5. refcounted store into self+0xD50 (self[0x1AA]) ------------------
    if (built != self->[0x1AA]) { AddRef(built); Release(self->[0x1AA]); self->[0x1AA] = built; }

    // ---- 6. QUEUE via the plain action controller --------------------------
    void* ac = self->vtbl[0x2D0](self)->vtbl[0x130]();           // GetActionController
    ac->vtbl[0x98](ac, self->[0x1AA], -1.0f);                    // IActionController::Queue
}
```

The load-bearing facts, all **observed** in the disassembly:

| fact | where | value |
|---|---|---|
| allocation size | `MOV ECX,0x90` before `CryMalloc` (dec. line `lVar11 = (*DAT_1812cebd0)(0x90,...)`) | **0x90** |
| the constructor called | `FUN_180121300` | writes `IAction::vftable` then **`TAction<SAnimationContext>::vftable`** — a *bare* Mannequin action (RTTI-labelled) |
| priority | ctor arg 2 | **5** |
| fragment ID | ctor arg 3 | from the name-CRC lookup |
| TagState | ctor arg 4 (20 bytes, `local_60`) | from the tag-string parse |
| queue call | `ac->vtbl[0x98](ac, action, 0xBF800000)` | **`IActionController::Queue(IAction&, -1.0f)`** |

`FUN_180121300` (the `TAction<SAnimationContext>` ctor, EntityModule's copy at
RVA `0x121300`) is **field-for-field the same** ctor WO-42 §3 documented in
AnimationModule (`0x100250`) and CombatModule (`0x10BA90`): priority at `+0x24`,
fragmentID at `+0x38`, `-1.0f` at `+0x14`, 20-byte TagState memcpy'd to `+0x3C`,
scope mask at `+0x54`, refcount at `+0x58`, the two static container sentinels at
`+0x68`/`+0x88`. **Observed** — this session read its body and it matches WO-42
exactly. That is the strongest possible confirmation that what `PlayAnim` builds
is the *bare base action*, with none of the combat subclass on top.

**The comparison that makes the verdict crisp.** `PlayAnim` and the correct
combat route parse the *identical* `(fragmentID, TagState)`. The only
differences are the action **type** and the queue **path**:

| | `C_Player::PlayAnim` (rung 1, closed) | `C_CombatActorAction*::EnterImpl` (the game's real swing) |
|---|---|---|
| action object | `TAction<SAnimationContext>`, **0x90** | `C_CombatAnimAction`, **0x1A8** |
| built by | `TAction_ctor` (`0x121300`) | `C_CombatAnimAction` ctor (`0xF26F0`), which calls the *same* TAction ctor then adds the combat vftable + four lifecycle `std::function` delegates + the asset-GUID slot |
| queued through | `IActionController::Queue` (+0x98) **directly** | `C_CombatAnimActionManager::QueueAction` (`0xF3C00`) — which *also* ends at `Queue` (+0x98) but is reached only after the full combat pre-roll |
| combat state | **none** | pre-roll of `combat+0xD28/0xE28/0xD68`, attack-helper init, attack selection, post-queue hooks (WO-42 §5.2 steps 4-11) |
| lifecycle | none | `OnAnimEntered`/`OnAnimFinished` delegates drive the transition |

A combat fragment's later scopes and transition tags (the `eZ1`/`aZ2`/`slash`
"attack-zone" tags in the real rows, WO-42 §9.2) are advanced by that combat
machinery. Strip it and the fragment enters but never transitions out of its
entry — the stuck partial pose. **This is direction A's answer.**

---

## 2. The class-dispatch subtlety (settles WO-43 §9.6's open boundary)

WO-42 §9.6 flagged, and WO-43 inherited, an open question: *which concrete
class's vtable does `+0xE48` resolve to?* WO-42 noted a probe of `C_NPCActor`'s
table at `+0xE48` "landed on an unrelated getter." This session resolves it.

**Observed:**

- `C_Player::vftable` is at RVA `0xE96F78`. Its slot `[457]` = byte `+0xE48` =
  **`0xAE17A0`** (`PlayAnim`). Confirmed two independent ways: a full 470-slot
  vtable dump, and walking back from the raw slot address `0xE97DC0`
  (= `0xE96F78 + 0xE48`) to its owning vtable label.
- **`0xAE17A0` is referenced by exactly one real vtable slot in the entire
  module** — that C_Player one. (The four other data-refs to `0xAE17A0` decode
  as packed 32-bit RVA pairs, i.e. `.pdata`/EH `RUNTIME_FUNCTION` triples — the
  exact trap `native/ghidra_scripts/README.md` warns of; verified by reading
  them: they yield the nonsense "pointer" `0xAE182A00AE17A0`, two glued RVAs.)
- `C_Human`'s **primary** vtable (the one its ctor at `0x7D7CA0` writes to
  `[this+0]`, RVA `0xE44C58`) is **shorter than C_Player's**: the next vtable
  begins at `0xE459D0`, only ~431 slots in. So byte `+0xE48` (slot 457) is
  **past the end** of `C_Human`'s primary vtable — reading it lands in adjacent
  data. `C_Human` has no `PlayAnim` at `+0xE48`; its `PlayAnim`, if virtual, is
  at a lower slot.
- `C_NPCActor`'s primary vtable (ctor `0xACBEE0` writes `0xE98340` to `[this+0]`)
  has a 28-byte stub returning a static pointer at `+0xE48` — again not
  `PlayAnim`.

**Consequence, stated precisely.** `C_ScriptBindHuman::PlayAnim` (`0xB3D5C0`)
hard-codes `actor->vtbl[+0xE48]` (re-read this session — the guard and call are
exactly as WO-42 §9.6 gave them: `actor[+0x28]->vtbl[0x80]() != 0`, then
`actor->vtbl[0xE48](actor, fragment, tags)`). That offset is calibrated for
`C_Player`. For it to have rendered on WO-40's and WO-43's ghosts, those ghosts'
actors must present a `C_Player`-compatible layout at `+0xE48` — i.e. the ghost's
resolved `C_Actor*` is (or is laid out like) a `C_Player`, **not** a `C_NPCActor`
whose `+0xE48` is a stub. **This is a live-checkable claim, not a settled one**;
the §6 probe logs the ghost's vptr and compares it to `C_Player::vftable`
(`0xE96F78`) to decide it directly. Either way the direction-A verdict holds:
whatever the ghost's `+0xE48` is, WO-43 observed it produce a bare partial swing,
consistent with a bare-fragment player.

This also means direction B should **not** rely on `+0xE48` or any other
vtable-slot offset that varies by leaf class. It should use `C_Actor`'s
*non-virtual* combat entry point, `GetOrCreateCombatActor` (§4), which works from
any `C_Actor*` regardless of concrete class.

---

## 3. Why a bare `TAction` stalls a swing but not a jump (read-but-unrendered)

Stated as a mechanism, one step beyond the bytes and labelled as such
(**inferred** from the combat construction sequence WO-42 §5.2 observed, plus §1
observed here):

- A Mannequin **fragment** is a set of animation clips keyed by scope + tags. A
  bare `TAction<SAnimationContext>` installed via `IActionController::Queue`
  gets the fragment's *entry* onto the scopes the fragment declares, at
  priority 5, and the action controller plays it.
- A **jump/motion** fragment (`MotionJump`, confirmed live WO-40) is
  self-terminating on its default scope — entry plays through to its natural end,
  so a bare `TAction` renders it fully. This is exactly what `PlayAnim` is *for*:
  its own binary description (AnimationModule `C_PlayAnim`) is *"Play given
  animation fragment. Stops immediately. Use just for low level testing!"*
  (WO-42 §6) — a low-level, fire-and-forget fragment player.
- A **combat attack** fragment carries transition tags (`eZ1`, `aZ2`, `slash`,
  `attack_heavy`, WO-42 §9.2) whose advancement is driven by the
  `C_CombatActorAction` state machine and its lifecycle delegates
  (`OnAnimEntered`→`FUN_1800F2CE0(anim,6)`, `OnAnimFinished`→`OnActionDone`,
  WO-42 §5.2). With no combat action object present, nothing fires those
  transitions; the fragment enters and holds. Result: weapon drawn, swing begun,
  frozen mid-motion — WO-43's observation, three times over.

This is **read-but-unrendered** as a runtime claim: it is the only reading
consistent with (a) `0xAE17A0` building a bare `TAction` (observed), (b) the
combat route building a `C_CombatAnimAction` with delegates (WO-42 observed), and
(c) the live partial-swing (WO-43 observed). It is not independently re-run here.

---

## 4. Direction B entry points, re-verified against the installed binaries this session

Every address below was **re-decompiled this session** from the WO-42 Ghidra
projects (which survived — §7) and matches WO-42's findings. Re-verifying rather
than trusting, per the project bar.

**`C_Actor::GetOrCreateCombatActor` — EntityModule RVA `0x92260`.** The
class-agnostic way to get an `I_CombatActor*` from any `C_Actor*`. Reconstructed,
**observed**:

```c
I_CombatActor* GetOrCreateCombatActor(C_Actor* self) {          // RCX
    if (!self->vtbl[0x988](self)) return nullptr;               // combat-capable?
    if (self->[+0x300] == nullptr) {                            // m_pCombatActor
        void* cls = self->vtbl[0x498](self);                    // GetActorClass
        if (cls->vtbl[0x28](cls)) {                             // class combat-capable
            self->[+0x300] = GetGameIface()->[0x100]            // combat module iface
                                ->vtbl[0x58](module, self);     // CreateCombatActor(C_Actor&)
            if (InitCombatActor(self)) { ... }                  // RVA 0x92310
        }
    }
    return self->[+0x300];
}
```

Confirms, this session: `C_Actor::m_pCombatActor` is at **`+0x300`** (WO-41's
`+0x278` is wrong, as WO-42 §9.5 already found); `vtbl[0x988]` is the
combat-capability predicate; `vtbl[0x498]` is `GetActorClass`; `vtbl[0x490]` is
`GetName` (used in `InitCombatActor`'s error string, RVA `0x92310`, anchored by
its own `__FUNCTION__` at `0xD43A30`). `__fastcall`, `this` in RCX, returns the
pointer in RAX.

**`C_CombatAnimAction` ctor — CombatModule RVA `0xF26F0`.** Re-decompiled,
**observed**, matches WO-42 §4.2:

```c
C_CombatAnimAction* ctor(void* mem,          // RCX  freshly CryMalloc'd 0x1A8 block
                         void* /*unused*/,    // RDX
                         void* combatActor,   // R8   I_CombatActor*
                         uint32 priority,     // R9D  5 for attack/sync-attack
                         uint32 fragmentID,   // [rsp+0x20]
                         const void* tags20,  // [rsp+0x28]  20-byte TagState
                         uint32 flags) {      // [rsp+0x30]  game passes 0
    TAction_ctor(mem, priority, fragmentID, tags20, flags, 0);  // the same base ctor
    mem->[0]     = C_CombatAnimAction::vftable;
    mem->[0x90]  = 0; mem->[0x98] = 0;
    mem->[0xD8]  = mem->[0x118] = mem->[0x158] = mem->[0x198] = 0;  // 4 delegate slots
    mem->[0x94]  = flags;
    mem->[0x9C]  = *(uint32*)(*(void**)((char*)combatActor + 0x2D8) + 0x30);
    return mem;
}
```

**`C_CombatAnimActionManager::QueueAction` — CombatModule RVA `0xF3C00`.**
Re-decompiled, **observed**, matches WO-42 §5.2b:

```c
void QueueAction(void* manager,                              // RCX
                 _smart_ptr<C_CombatAnimAction>* sp,          // RDX  by reference
                 float time) {                                // XMM2  -1.0f
    void* animChar = (*(void***)((char*)*(void**)manager + 0x2D8))->vtbl[0x2D0]();
    void* ac       = animChar->vtbl[0x130]();                 // GetActionController
    if (ac && ((*sp)->[+0x28] == 0 || (*sp)->[+0x28] == 4)) { // action status gate
        ... trace log (reads fragmentID +0x38, TagState +0x3C..+0x4C) ...
        ac->vtbl[0x98](ac, *sp, time);                        // IActionController::Queue
    }
    // consumes one reference on sp
}
```

Ownership rule an implementer must respect (WO-42 §5.2b, re-confirmed):
`QueueAction` **consumes one reference**. AddRef = `action->vtbl[0x08]`,
Release = `vtbl[0x10]`, refcount at `action+0x58`, destroy virtual `vtbl[0xB8]`.

---

## 5. The direction-B construction spec (ready to implement; not built this session)

Two rungs, both feeding off the pointers the §6 probe confirms. Presented with
the trade-off explicit, because they differ in confidence, not just effort.

### Rung 2 — build a `C_CombatAnimAction`, queue it through the actor's own manager

The smallest step up from rung 1 that adds real combat machinery. **Same
`(fragmentID, TagState)` parse rung 1 already does correctly** — the only changes
are the action *type* (`0x1A8` `C_CombatAnimAction` instead of `0x90` bare
`TAction`) and the queue *path* (the combat manager instead of the plain action
controller).

```
1. combatActor = GetOrCreateCombatActor(actor)         // EntityModule 0x92260
2. (fragmentID, tags20[20]) = parse "FragmentId, tags" // see "the parse" below
3. mem = CryMalloc(0x1A8)                               // CrySystem CryMalloc export
4. anim = C_CombatAnimAction_ctor(mem, mem, combatActor, /*priority*/5,
                                  fragmentID, tags20, /*flags*/0)   // CombatModule 0xF26F0
5. ++*(int*)(anim + 0x58)                               // AddRef (QueueAction consumes one)
6. _smart_ptr<C_CombatAnimAction> sp = anim            // an 8-byte stack slot holding anim
7. manager = *(void**)(combatActor + 0x490)            // C_CombatAnimActionManager
8. C_CombatAnimActionManager_QueueAction(manager, &sp, -1.0f)   // CombatModule 0xF3C00, time in XMM2
```

- **The float in XMM2 is the classic trap** (WO-42 §2.3): the third argument is
  a `float` in XMM2, value `-1.0f` (`0xBF800000`), *not* an int/pointer in R8.
- **Confidence: medium.** A `C_CombatAnimAction` is the correct combat action
  type and carries the lifecycle delegate *slots* — but this route does **not**
  run `C_CombatActorActionAttack::EnterImpl`'s pre-roll (WO-42 §5.2 steps 4-5,
  10-11) and does not *install* the delegates (the ctor only zeroes their slots;
  `EnterImpl` binds `OnAnimEntered`/`OnAnimFinished` into them). So rung 2 may
  render *more* of the swing than a bare `TAction` but may still not complete it.
  It is the cheapest experiment; run it first and observe.

### Rung 3 — construct a `C_CombatActorActionAttack` and let the game's own `EnterImpl` drive it

Highest fidelity, because the game does the orchestration end-to-end. Hand a
constructed attack action to the actor's own `C_ActionDirector` via
`C_ActionDirector::SetAction`; the director enters it and *its* `EnterImpl`
(CombatModule `0x44300`) runs the full WO-42 §5.2 sequence.

```
1. combatActor = GetOrCreateCombatActor(actor)
2. mem = CryMalloc(0xC0)                                // sizeof C_CombatActorActionAttack (WO-42 §4.3)
3. attack = MakeAttack(mem, combatActor, descriptor)   // CombatModule factory 0x84D20
4. director = *(void**)(combatActor + 0x2E0)           // wh::framework::C_ActionDirector*
5. C_ActionDirector::SetAction(director, &attack)      // imported symbol; enters it -> EnterImpl runs
```

- **The one open runtime unknown (WO-42 §9.4 rung-2 note):** step 3 needs a
  valid **attack descriptor pointer** (`S_CombatActorActionAttackParams`, stored
  at `attack+0x60`). The *data* is shipped, enumerable XML — WO-42 §9.1/§9.2:
  every one of the 470 shipped sync-attacks (and 221 unpaired attacks) is a row
  in `combat_action_attack.xml` / `combat_action_sync_attack.xml`, each carrying
  `mn_fragment_id` + `mn_tags` + timings, and each sync-attack has its
  `combat_fragment_meta.xml` metadata row (so rung 3 is **not** data-gated). What
  is not yet in hand is the *runtime pointer* to a loaded descriptor row. The
  attack-selection code (`I_CombatActor + 0x478`/`+0x4D8`, WO-42 §4.4) is where
  the game gets one; a future session should trace that to a lookup that takes a
  fragment ID or descriptor key. **This is the real remaining research item for
  direction B, and it is bounded.**
- **`SetAction` on a ghost is the second unknown** (WO-42 §8): whether
  `C_ActionDirector::SetAction` accepts a puppeted-ghost actor as it does a real
  brained combatant. The §6 probe confirms the director pointer resolves; only a
  live run confirms `SetAction` succeeds.

### The parse (both rungs need `(fragmentID, TagState)` from `"FragmentId, tags"`)

The engine already does this; do not hand-compute Mannequin IDs. Two confirmed
sources:

- **AnimationModule `ParseFragmentSpec`, RVA `0x12DB00`** (WO-42 §6.1): given the
  actor's animation database and the string `"FragmentId, tag1+tag2"`, yields
  `fragmentID` + the 20-byte `TagState` directly. The cleanest option.
- **Replicate `0xAE17A0`'s own inline parse** (§1 steps 1-2, now fully
  decompiled): CRC32-lower the name, look it up in the action controller's
  context fragment table (`FUN_180123CB0`); then split tags on `+`, CRC32-lower
  each, look up in the tag-definition table, set the `TagState` bits. More code,
  but self-contained and proven (the fragment *does* start playing under rung 1,
  so this parse is already known-correct).

---

## 6. What was built this session — `native/KCDMP/combat_construct.cpp` (new file)

A **precondition probe**, not a constructor. It resolves the ghost's
`I_CombatActor*` and logs every pointer/offset rung 2 and rung 3 consume, so the
next session can confirm the route's inputs resolve on a live ghost *before* any
allocation or queue. It is the direct analogue of WO-43's `combat_playanim.cpp`:
same conventions (PE export prefix-resolution via `pe_exports.h`; every raw
dereference in its own tiny SEH-guarded helper with no destructible locals, per
the MSVC C2712 trap WO-43 documented; the opt-in trigger-file pattern).

**Everything it does is a read or an idempotent engine call the game itself
makes routinely** — it constructs nothing and queues nothing. The one non-read is
`GetOrCreateCombatActor` (only in `create` mode), which the engine calls whenever
combat begins; it creates the combat actor if the ghost has none yet, which is a
*precondition* for a swing, not a mutation of game state.

**Trigger (opt-in, matching `kcdmp-faction.txt` / `kcdmp-playanim.txt`):**
`kcdmp-combat.txt` beside the deployed `KCDMP.dll`. Absent = skip entirely.

```
line 1: player            (or a decimal CryEngine entity id -- the ghost's,
                           obtainable live via the mp_entity_id console command
                           WO-43 added to kdcmp.lua)
line 2: probe             (default -- raw read of actor+0x300, zero mutation)
        create            (call GetOrCreateCombatActor if the ghost has no
                           combat actor yet)
```

It logs, each `describe()`d as `module+0xRVA` (WO-43's idiom):

1. the resolved `C_Actor*`;
2. **the actor's vptr, and whether it equals `C_Player::vftable`
   (EntityModule `0xE96F78`)** — this settles §2's live question directly;
3. `GetName()` (a cheap sanity read);
4. `actor->vtbl[0x988]()` combat-capability;
5. `actor+0x300` (`m_pCombatActor`) raw; and, in `create` mode, the
   `GetOrCreateCombatActor` result;
6. off the `I_CombatActor`: `+0x2D8` (owning entity — with a **round-trip
   assertion that it equals the `C_Actor` we started from**), `+0x2E0`
   (`C_ActionDirector`, rung-3's `SetAction` target), `+0x490`
   (`C_CombatAnimActionManager`, rung-2's queue target), `+0x2F0` (combat state
   block) and `state+0x1118` (**current opponent** — present ⇒ rung-3 paired
   route viable; absent ⇒ rung-2 unpaired still fine).

Wired into `dllmain.cpp` immediately after `probe_play_anim()` in the existing
startup `run_sync` block, and into `CMakeLists.txt`. **Built clean**
(`native/Build-Native.ps1`, Release): `KCDMP.dll`, **289,280 bytes**, zero
errors, zero new warnings.

### 6.1 Live-test run sheet (for a future session with a human at the machine)

The method is WO-43 §5/§7's, which worked: drive the game via
`localhost:1403/api/System/Console/ExecuteString` from the coding shell, read
`D:\SteamLibrary\steamapps\common\KCD2Mod\kcd.log` directly (never
`%LocalAppData%\KCDMP` — sandboxed for this shell), and spawn ghosts under
**fresh, never-reused ids** (WO-43 §6: reused ids corrupt the ghost). First
confirm the game is up: `curl http://localhost:1403/api/rpg/Calendar?depth=1`.

The probe fires once at DLL attach, so `kcdmp-combat.txt` must be in place
*before* launch. Because the probe reads the trigger once at attach, testing a
ghost means: get the ghost's entity id from a *previous* run (or the
`mp_entity_id <name>` console command), write it into `kcdmp-combat.txt`, then
relaunch. (A future iteration could move the probe behind a pipe command to
avoid the relaunch; out of scope here.)

**Test A — the player, read-only (proves the mechanism end-to-end, zero risk):**

`kcdmp-combat.txt`:
```
player
probe
```
Launch, load a save, then read `kcd.log` / `kcdmp-native.log` for `COMBAT:` lines.

**Test B — the player, create mode (proves the combat-actor path):**
```
player
create
```

**Test C — a ghost (the real target):** get a ghost's entity id, then
`kcdmp-combat.txt`:
```
<ghost entity id>
create
```

**Outcome → verdict table:**

| `kcd.log` shows | verdict |
|---|---|
| `actor vptr ... IS C_Player` | ghost is C_Player-layout — explains why `PlayAnim`/`+0xE48` rendered on it (§2 resolved) |
| `actor vptr ... NOT C_Player's vtable` | ghost is another class; the `module+0xRVA` in the line identifies it — hand that RVA to a Ghidra pass to name it and find its real PlayAnim slot |
| `combat-capable = 0` | this actor cannot host a combat action at all — rung 2/3 are impossible on it; investigate why the ghost isn't combat-capable |
| `m_pCombatActor (raw) = null` in `probe` mode, then non-null after `create` | expected for a ghost not in combat; `create` is the right mode for rung 2/3 |
| `combatActor+0x490 (...manager...) = <non-null, CombatModule+0xRVA>` | **rung-2 queue target confirmed live** — proceed to implement rung 2 |
| `combatActor+0x2E0 (C_ActionDirector) = <non-null>` | **rung-3 SetAction target confirmed live** |
| `combatActor+0x2D8 ... MATCH (round-trip ok)` | the `I_CombatActor ↔ C_Actor` offset pair is correct on this live object — the whole offset map is trustworthy for this build |
| `state+0x1118 (current opponent) = <non-null>` | ghost has a live opponent — rung-3 paired route is viable; else use rung-2 unpaired |
| any `... faulted` line | that specific offset/call is wrong for this actor on this build — do **not** proceed to construction until it reads clean; report the faulting line |

Nothing in any of these paths constructs or queues an action, so no test here can
produce (or fail to produce) a swing. The probe's job is only to prove the inputs
are all present and correct before the next session writes the construction code
from §5.

---

## 7. How this session ran (reproduction)

WO-42's three Ghidra projects **survived** in the prior session's scratchpad and
were reused as-is (no re-import, ~9 min saved each):

```
<prior scratch>\gproj\wo42.gpr    -> AnimationModule.dll
<prior scratch>\gproj2\wo42c.gpr  -> CombatModule.dll
<prior scratch>\gproj3\wo42e.gpr  -> EntityModule.dll
```

(Found via a recursive `*.gpr` search under the temp tree; the imported program
data is intact — `EntityModule.dll` ~843 MB of analysis in `gproj3`.) Ghidra
`12.1.3` and Temurin JDK 21 are at the paths WO-42 §7.1 records. The WO-42
scripts (`native/ghidra_scripts/DumpWo42{Fns,Asm,Callers,Vtbl,Anchors}.java`)
ran unchanged; this session added one small helper,
**`native/ghidra_scripts/DumpWo44Owner.java`** — given a raw slot address, it
walks back to the nearest `vftable` symbol and reports the slot's byte offset,
which is what identified `0xAE17A0` as C_Player `+0xE48` and unmasked the four
`.pdata` false refs.

Representative command (re-run `0xAE17A0` against the surviving project):

```powershell
$env:JAVA_HOME = "C:\Program Files\Eclipse Adoptium\jdk-21.0.11.10-hotspot"
$g    = "C:\Users\Jonasty\Downloads\ghidra_12.1.3_PUBLIC_20260817\ghidra_12.1.3_PUBLIC"
& "$g\support\analyzeHeadless.bat" <prior scratch>\gproj3 wo42e `
    -process "EntityModule.dll" -noanalysis `
    -scriptPath "native\ghidra_scripts" `
    -postScript DumpWo42Fns.java "<out>\ae17a0.txt" 1 0x180AE17A0
```

If the projects are ever gone, WO-42 §7.1 re-imports all three in ~10 min each.
Every RVA here is valid only for the binaries WO-42 §1 fingerprints (Modding
Tools 1.5.5.0, `ReleaseSteamLTO_DLL` build 1166656_117; `EntityModule.dll`
20,977,664 bytes, confirmed this session).

---

## 8. Where solid ground ends

**Observed (read from the disassembly this session):** `0xAE17A0` builds a bare
`0x90` `TAction<SAnimationContext>` (via the RTTI-labelled TAction ctor
`0x121300`) and queues it via `IActionController::Queue` (+0x98) — §1; the
`C_Player` vtable identification and the fact `0xAE17A0` sits in no other vtable
— §2; the shorter `C_Human`/`C_NPCActor` primary vtables — §2; the re-verified
`GetOrCreateCombatActor` (`0x92260`), `C_CombatAnimAction` ctor (`0xF26F0`) and
`C_CombatAnimActionManager::QueueAction` (`0xF3C00`) — §4; the `C_ScriptBindHuman::PlayAnim`
guard+call at `+0xE48` — §2.

**Read-but-unrendered (traced, never executed):** the mechanism in §3 (that the
missing combat state machine is *why* the fragment holds); all of §5's
construction (nothing was built or queued this session); whether rung 2 alone
completes a swing; whether `SetAction` accepts a ghost.

**Inferred, labelled:** the swing-vs-jump reasoning in §3 (a reading over three
observed facts, not a fourth observation); the claim that WO-43's ghosts were
`C_Player`-layout (consistent with all evidence but not yet directly observed —
the §6 probe is written specifically to confirm it).

**Deliberately not done:** no game launched, no process touched, no combat action
constructed or queued, no `VERSION` change, no Mannequin data modified. Licensing
posture unchanged — WO-42's binaries this machine already owns, read statically.

---

## 9. Handoff

- **Direction A is closed by decompilation** — rung 1 (`PlayAnim`/`+0xE48`) is a
  bare-fragment player and cannot complete a combat swing; do not re-attempt it,
  and do not look for a "one more precondition" fix (there is no branch to enable).
- **Direction B is the path**, and its entry points are re-verified (§4). The
  next session, with a human at the machine, should:
  1. Run the §6 probe (Tests A→C) to confirm the ghost has a combat actor and
     that the manager/director/opponent offsets resolve live, and to settle the
     ghost's class (§2). This is safe and needs no new code.
  2. Implement **rung 2** (§5) as the cheapest experiment — build a
     `C_CombatAnimAction`, queue via the actor's manager — and observe whether it
     completes the swing.
  3. If rung 2 is still partial, implement **rung 3** (§5) — construct a
     `C_CombatActorActionAttack` and hand it to the actor's `C_ActionDirector`
     via `SetAction`, resolving the one remaining open item: the **runtime attack
     descriptor pointer** (trace the attack-selection path off
     `I_CombatActor+0x478`/`+0x4D8`, WO-42 §4.4).
- The two orthogonal bugs WO-43 §6 flagged (console argument parsing, ghost
  respawn corruption under reused ids) remain real and out of scope; flagged
  again so they aren't lost.
