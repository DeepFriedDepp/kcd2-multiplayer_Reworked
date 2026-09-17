# WO-100 — replicate input and state, not animations

Session 2026-09-17. Modding Tools build 1.5.5.0 (`ReleaseSteamLTO_DLL`), the
same binaries WO-42/44/45 keyed to.

Evidence marks are used strictly. **(observed)** = seen in a log or on screen
this session. **(code-verified)** = read out of a binary, a decompilation or a
shipped data file. **(synthetic)** = a test harness, not a live game.
**(inconclusive)** = exactly that.

---

## 0. Answer first

| phase | outcome |
|---|---|
| 0 — Mannequin tag state readable? | **REACHABLE — live-verified** (S10.1). Pace/direction/stance all confirmed against on-screen behaviour, `unknownTags=0`, no refusals. Animation speed reachable on an NPC but **overridden on the player** (S10.3). **Airborne still no** (S1.5) |
| 1 — attack acceptance point | **found and LIVE-VERIFIED** (S4, S10.4): 20 of 20 properties read back their own registered name, and a whole accepted-input event was captured in flight. Replayability answered **read-only: yes, structurally**; acting on it is a native write, so **Phase 5 is a STOP and did not proceed** |
| 2 — wire format | **designed, not implemented** (S6). Additive continuous fields behind a flag bit, one discrete shape for every action, a gen triple, name-keyed enums throughout. Reserved 0x3B/0x3C |
| 3 — locomotion replication | **not built, but the gate is now PASSED** (S10.1/S10.2). Tags are continuous state at 50 ms, so the continuous channel can publish them directly. Item 4's premise is still out of date: ghost smoothing **already exists** and so does the snapshot-buffer variant on the puppet path; what is missing is correction-magnitude and snap-count logging |
| 4 — unconditional improvements | **landed**, all five items + one defect found while reading (§3). 111 tests green, **(synthetic)** — no live session |
| 5 — combat replication | **not run -- STOP.** The blocker is named precisely rather than vaguely: every remaining step is a native write (S4.2) |
| 6 — AI-less puppet class | **found: `NPC_NAI`**, and **live-confirmed** (S5, S10.6): it spawns, is a full actor with a soul, and has its own Mannequin action controller **sharing the player's tag definition object**. Needs a faction or it spams every frame. Applicability stated both ways in S5.3. Investigation only, nothing rebuilt on it |

---

## 1. Phase 0 — the Mannequin tag surface

### 1.1 The tag vocabulary is shipped data, not an inference

Every tag this WO wants to publish is declared in a shipped XML inside
`Data/Animations.pak`, readable with an ordinary zip reader (**code-verified**).

`Animations/Mannequin/ADB/kcd_male_tags.xml` — the human tag definition the
player and every humanoid NPC use (`kcd_male_controllerdefs.xml` names it):

| group | tags | what WO-100 wants it for |
|---|---|---|
| `MoveSpeed` | `walk` `run` `sprint` `dash` `steps` | **locomotion pace** |
| `MoveDir` | `forward` `backward` `left` `right` | **movement direction** |
| `Stance` | 38 tags — `stealth` `sitting` `lying` `horse` `leaning` `sittingGround` `surrender` … | **stance**; upright is the *absence* of a Stance tag |
| `ManTypeLeft` / `ManTypeRight` | 26 / 36 held-item classes | what is in each hand |
| ungrouped | `combat` `player` `alerted` `charge` `stair` `prime` `injured` … | modifiers |

A **group** is mutually exclusive and packs as a small ordinal; an ungrouped tag
is a single bit. There is no `jog` — the engine's three paces are
`walk`/`run`/`sprint`, with `dash` reserved for horses (`horse+dash+…` overrides
in the controller def).

`wh_female_controllerdefs.xml` / `wh_female_tags.xml` is the female equivalent;
`kcd_combat_tags.xml` imports pose/rpgcontext/combo tags and adds the combat
vocabulary (§2).

### 1.2 Where the live tag state lives — the chain, decompiled

Anchor: `wh::animationmodule::C_AnimationController::QueueAction`
(AnimationModule RVA `0x20410`), found by its own `__FUNCTION__` string —
WO-42's identification rule (**code-verified**). Its trace line is
`" %s.QueueAction[%d](%s) -> %s [GlobalTags=%s]"`, so it reads the live global
tag state to log it, and the decompilation shows exactly how:

```c
ctrl = (**(code**)(**(longlong**)(param_1 + 0x10) + 0x130))();  // IAnimatedCharacter vtbl +0x130
ctx  = (**(code**)(*ctrl + 0xb0))(ctrl);                        // IActionController vtbl +0xB0
defs = *(void**)(*(void**)ctx + 0x10);                          // SControllerDef + 0x10
ctx2 = (**(code**)(*ctrl + 0xb0))(ctrl);
FUN_18001fa90(out, ctx2 + 0x10, defs);                          // TagState bytes at ctx + 0x10
...
(**(code**)(*ctrl + 0x98))(ctrl, action, layer);                // IActionController::Queue
```

| fact | evidence |
|---|---|
| `IActionController::GetContext()` = vtbl **+0xB0** | the call above, **plus** `CActionController::vftable` (CryAction RVA `0x483D98`) slots 22 **and** 23 are the *same* function `0x2B1A80` — the const/non-const overload pair — and that function is `return *(this + 0x28);` (**code-verified**, decompiled) |
| `IActionController::Queue` = vtbl **+0x98** | the call above, and WO-44 reached the same offset independently from `C_Player::PlayAnim` |
| `CActionController + 0x28` = `SAnimationContext*` | `GetContext` body, above |
| `SAnimationContext + 0x00` = `const SControllerDef&` | dereferenced as a pointer before `+0x10` |
| `SAnimationContext + 0x08` = `const CTagDefinition&` (the `CTagState`'s own `m_defs`) | layout implied; **cross-checkable at runtime** against `*(SControllerDef+0x10)` — the probe asserts they are equal rather than assuming it |
| `SAnimationContext + 0x10` = the **TagState bytes** | passed straight to the stringifier |
| TagState is **20 bytes** | `FUN_18001fa90` builds a `{ptr, 0x14}` pair around it before passing it on (**code-verified**); independently, `STagState<$0BE@>` = `STagState<20>` appears in CombatModule's RTTI, and WO-44's `ParseFragmentSpec` out-struct already carried two 20-byte tag blocks |

### 1.3 How to decode 20 bytes into tag names — without reimplementing anything

`FUN_18002aa30` (AnimationModule RVA `0x2AA30`) is
`CTagDefinition::FlagsToTagList(state, out)` — the function the stringifier
calls. Decompiling it yields `CTagDefinition`'s layout directly
(**code-verified**):

| offset | contents |
|---|---|
| `+0x08` | tag array; count at `[-4]`; **stride 0x20**; `+0x04` = `groupID` (int, `-1` = ungrouped); `+0x18` = `const char* name` |
| `+0x18` | per-**tag** `(byteIndex, mask)` pairs, **2-byte stride**, indexed by TagID |
| `+0x20` | per-**group** `(byteIndex, mask)` pairs, 2-byte stride, indexed by groupID |

and the membership test it performs:

```c
mask = tagBits[i*2 + 1];
if (mask == 0) continue;                       // tag carries no bits
gid = tags[i].groupID;
if (gid == -1) v = state[ tagBits[i*2] ] & mask;        // ungrouped: a bit
else           v = state[ grpBits[gid*2] ] & grpBits[gid*2+1];  // grouped: the field
if (v == mask) -> tag i is set
```

`CTagDefinition::AssignBits` (CryAction RVA `0x26A1C0`, found by its own
`__FUNCTION__` string) is the producer side and agrees: group values are
ordinals `1..N` shifted into a mask, `0` means "no tag from this group", and a
group never straddles a byte boundary (**code-verified**).

**Consequence that matters:** the bit layout never has to be replicated in our
code. It is *data* in the live `CTagDefinition`, so a decode written against
these three arrays is immune to the tag XML changing between builds. The tag
**name** is right there too, which is what the wire should carry (§3).

### 1.4 What is NOT reachable from Lua

The shipped scriptbind reference (`Tools/modding/docs/script_bind/script_bind.zip`,
5,017 pages) has **no reader** for the tag state (**code-verified**). It does
carry writers — `AI.SetAnimationTag` / `AI.ClearAnimationTag`,
`Action.PersistantEntityTag` / `ClearEntityTags` / `ClearStaticTag` — and those
method-name strings are present in `CryAISystem.dll` and `CryAction.dll`
respectively. Being a string is not being registered: `type()` must probe them
live (WO-65's rule — `pairs()` is blind to scriptbind methods).

`Entity.GetVelocity` / `Entity.GetSpeed` exist but are the physics-settled
values, not the animation-driven ones. So Phase 0 item 2d has no Lua route.

---

### 1.5 What is and is not in the global tag state — the honest boundary

The tag state reached above is the **global** one, defined by
`kcd_male_controllerdefs.xml` → `kcd_male_tags.xml`, which has **no
`<Imports>`**. So §1.1's table is the whole of it.

| Phase 0 item | verdict | where |
|---|---|---|
| locomotion pace (walk / jog / sprint) | **reachable** | `MoveSpeed` group. The engine's paces are `walk`/`run`/`sprint` (+`dash`, `steps`) — there is no `jog`; `run` is the middle pace |
| movement direction | **reachable** | `MoveDir` group |
| stance | **reachable** | `Stance` group. `stealth` is crouch/sneak; upright is the *absence* of any Stance tag, which the probe reports as `stance=upright` |
| animation-driven velocity | **reachable as a scalar, not a vector** | `C_Actor::GetPseudoSpeed` = `*(float*)(*(void**)(actor+0x7E8)+0x18)` — the AI-animation component's speed, distinct from `Entity.GetVelocity`'s physics-settled value (**code-verified**). Named precisely: this is a *speed*, and the direction comes from the `MoveDir` tag, not from it |
| airborne flag | **NOT reachable here** | the `ActorState` group (`idle guard attack block jump ledge ladder minigame itemInteraction shooting unconscious carryCorpse stoneThrowing hit fall land standingUp dying dead trackview`) lives in `kcd_pose_tags.xml`, which the **combat** tag definition imports and the global male definition does **not**. So `jump`/`fall`/`land` are not in the 20 bytes this probe reads |

The airborne answer is a genuine gap, not a shortfall of effort. It is also
worth noting what it *would* have given: `jump`/`fall`/`land` are state-machine
values, so the debouncing the WO asked about would likely have been
unnecessary — `land` is an explicit state rather than a per-frame physics
sample. Finding the second tag context that carries them is a **WO-101
candidate**, not this WO's budget.

The global definition does carry `stair`, which is the shape the stair-step
flicker question was really about.

### 1.6 The probe, and the live known-answer runbook

`native/KCDMP/mannequin_read.cpp` — strictly read-only. Three SEH-isolated
virtual getters the game itself calls every frame, then plain memory reads.
No hook, no write, no queued action.

It refuses rather than guessing, on five independent gates:

1. the actor resolves (the `combat_construct.cpp` route, unchanged);
2. `GetAnimatedActor` / `GetActionController` return non-null;
3. **the controller's vptr equals `CActionController::vftable`** — the WO-99.5
   step-0 discipline. On any other class `+0xB0` would return something else
   and print a plausible lie;
4. **the two routes to the tag definition agree** — `ctx+0x08` (the
   `CTagState`'s own `m_defs`) against `ctx+0x00 → +0x10` (the controller
   def's). Disagreement means the layout premise is wrong on this build, and
   the probe says so instead of picking one;
5. the `CTagDefinition` arrays read as a tag definition (count in range, every
   byte index inside the 20 bytes).

Consecutive identical lines are collapsed with an explicit
`(previous line repeated N times)` when the state finally changes — so "the
player stood still" and "the probe stopped" stay distinguishable (WO-99.5
§1.5's lesson).

**Runbook — needs the maintainer, ~2 minutes in game.**

> **Superseded by §10.** This runbook was written before the live session and
> assumes the DLL has to be deployed by copying it into `%LocalAppData%`. It
> does not. Launch the Modding Tools game normally and inject straight from the
> build directory:
>
> ```
> KCDMP_LauncherInjector.exe --pid <pid> --dll <abs path>
ativeuild\KCDMP\KCDMP.dll
> ```
>
> Verify by `ModuleMemorySize` on the **loaded module**, never by the file on
> disk (WO-99.5 §6.1). Nothing is installed, and the DLL's own log lands beside
> it inside the repo. The trigger file below is unchanged.

1. In the **game root** (`…\KCD2Mod\`, next to `kcd.log`), create
   `kcdmp-mannequin.txt` containing one line:

   ```
   player 300 defs
   ```

   (`300` = sample period in ms; `defs` = dump the whole tag definition once,
   so the log shows every tag and its bit assignment.)
2. Watch `kcdmp-native.mirror.log` in the same directory.
3. Stand still → walk → jog/run → sprint → crouch (`stealth`) → walk backwards
   → draw a weapon → mount a horse.
4. **The check that matters:** `pace=` must read `walk`/`run`/`sprint` in the
   order performed, `stance=` must read `upright` then `stealth` then `horse`,
   `dir=` must read `forward` then `backward`, and `pseudoSpeed=` must rise and
   fall with the pace. A plausible-looking number that does not track the
   screen is **not** a read.
5. Clear the file to stop.

Expected refusals worth reporting rather than ignoring: a `controller vptr
… != CActionController::vftable` line means the animated-actor hop lands on a
class this WO did not map, and the whole Phase 0 verdict is
**(inconclusive)** rather than positive.

---

---

## 2. Phase 1 — where an attack is accepted

### 2.1 The combat vocabulary is also shipped data

`Libs/Tables/combat/*` in `Data/Tables.pak` (**code-verified**):

| table | rows | shape |
|---|---|---|
| `combat_input_class` | 8 | `id` −1..7, `name` ∈ {`none`,`attack_light`,`attack_heavy`,`attack_special`,`move_left`,`move_right`,`move_back`,`move_forward`,`block`}, plus `mn_tag` |
| `combat_zone` | 7 | `id` −1..5, `name` ∈ {`undefined`,`head`,`upper_left`,`upper_right`,`lower_left`,`lower_right`,`lower`}, with `attack_mn_tag` `aZ0`…`aZ5`, `defense_mn_tag` `dZ0`…, `start_mn_tag` `sZ0`…, and `master_strike_combat_zone_id` |
| `combat_attack_type` | 11 | `id` −1..9, `name` ∈ {`stab`,`slash`,`smash`,`throw`,`kick`,`punch`,`hook`,`direct`,`bite`,`backoff`} |
| `combat_action_type` | ~35 | `attack`=3, `block`=6, `perfectBlock`=14, `syncAttack`=16, `dodge`=25, `comboAttack`=18 … |
| `combat_action_attack` | **221** | the attack database itself |

**Phase 1 item 2, answered: the combat-star zone is a row index into a
game-owned table, and the table carries a name column.** `combat_zone_id` 0..5
is `head / upper_left / upper_right / lower_left / lower_right / lower`. It is
not a computed value; the angles (`angle_from`/`angle_to`) are *columns on the
row*, not the identity.

### 2.2 The attack row carries a GUID — so it needs no row index

Every `combat_action_attack` row has 59 columns, among them:

```
mn_fragment_guid = 840a4cef-ab44-727a-03d4-d81a171dca77
mn_fragment_id   = CombatAttack
mn_option_index  = 0
mn_tags          = oppLying+aZ1+bite+attack_heavy+oppMale+oppFemale
input_class_id   = 1      attack_zone_id = 1     attack_type_id = 8
action_type_id   = 3      charged_attack = false  combo_step = -1
actor_class_hash = 20967892   player = false
```

There is **no `combat_action_attack_id` column**. A row is identified either by
its `mn_fragment_guid` (16 bytes, authored, build-stable) or by the selector
tuple the game itself matches on. **Phase 1 item 3, answered: an attack row is
not addressed by index, so a build mismatch cannot silently select a different
attack** — provided the wire carries the guid or the *names*, never the small
integer ids, which are table positions.

> **Phase 1 continues in §4**, after the Phase 4 section. §2 is the
> shipped-data half (the vocabulary); §4 is the engine half (the live
> model). They were written at different points in the session and are
> left in place rather than renumbered.

---

## 3. Phase 4 — the unconditional improvements

These depend on neither Phase 0 nor Phase 1 and landed regardless. Everything
below is **(synthetic)** — 111 tests green, no live session this WO.

### 3.1 A defect found while reading the pipe, not looked for

`CombatPipe` held one `_lastReply` slot plus a `SemaphoreSlim`. When a command
timed out (5 s), its reply still arrived afterwards, wrote the slot and released
the semaphore. The **next** command's wait then returned immediately with the
**previous** command's answer — and stayed one reply behind for the rest of the
session. Every damage apply, death apply, faction toggle, isolation toggle and
swing after one timeout was reported against the wrong request.

The DLL has echoed a per-request sequence byte in the Result frame
(`body[1]`) since WO-20. Nothing read it (**code-verified**).

Fixed: the reader hands replies through a bounded channel; the sender drains
leftovers before writing, and drops any reply whose sequence is older than the
one it is waiting for — counted (`StaleRepliesDropped`) and logged. A reply
*ahead* of the expectation resyncs rather than hanging. `Ping` advances the
expectation too, because it consumes a sequence number in the DLL even though
it answers with `Pong` rather than `Result`.

### 3.2 Item 3 — a specific failure vocabulary

`ghost_swing` already logged a precise reason on each of its fourteen failure
paths, into the **native** log. The pipe collapsed all of them into one bool, so
the **agent** log — the one a field session reads — showed only `ok=0`.

`SwingResult` (`native/KCDMP/combat_swing.h`) now travels as a third byte on
the Result frame; `PipeReason` (`dotnet/KcdMp.Client/PipeResult.cs`) mirrors it.
Additive: a pre-WO-100 agent reads `body[0]`/`body[1]` and never looks further;
a pre-WO-100 DLL sends two bytes and the agent reports `reason=unknown`.

The WO's required vocabulary maps onto it directly:

| the WO asks for | code |
|---|---|
| engine refused the action | `15` `engine-refused` |
| target missing | `5` `target-missing` |
| row not present on this build | `12` `row-not-on-this-build` |
| body in the wrong state | `6` `body-wrong-state` |
| out of order / duplicate | `205` `stale-or-duplicate` (agent side) |
| expired | `204` `expired` (agent side) |

Agent-side reasons start at 200 so the two vocabularies cannot collide as
either side grows. Codes are **append-only**; renumbering one would make a
mismatched pair misreport instead of saying "unknown".

### 3.3 Items 1, 2 and 4 — `SwingInbox`

The inbound swing path was:

```csharp
if (_ghostEntityIds.TryGetValue(source, out uint id))
    _ = _combat.GhostSwingAsync(id, spec, ct).ContinueWith(t => log(ok));
// else: silently downgrade to the Lua cue, forever
```

Four defects, one per Phase 4 item:

1. **No validity counter.** The entity id was resolved at apply time, so a
   swing that crossed a respawn played on whatever body now held that ghost
   slot. WO-88 already used "the entity id changed" to invalidate appearance
   sets; nothing used it for events in flight.
2. **No bounded wait.** A swing arriving in the window between a ghost
   spawning and its `ghostid` event was downgraded to the Lua cue
   *permanently* — "we do not know the entity id" was treated as final rather
   than as "not yet".
3. **One generic failure** — §3.2.
4. **No bound on pending work.** Fire-and-forget tasks piled up against a
   single pipe gate with a 5 s wait each.

`SwingInbox` owns all four. The body generation is **one counter, not the
incarnation/epoch/revision triple the WO describes**: on this client all three
of that triple's causes (death, respawn, save reload) replace the ghost body and
therefore change its CryEngine entity id, so the second and third fields would
carry no information the first does not. Stated as a decision, not an omission.

The precondition deadline is **750 ms — a guess, not a measurement**, and the
give-up line prints the real waited time so a field session can tune it with
evidence.

Two choices worth naming:

* `BoundedChannelFullMode.Wait` with a **non-blocking** `TryWrite`. Both `Drop`
  modes make `TryWrite` return **true** while discarding the item, which is
  exactly the silent loss this class exists to remove. (Found by a test that
  failed: the first version used `DropWrite` and the refusal never happened.)
* An **expired** swing does not fall back to the Lua cue. The body it described
  is gone, and playing a cue on the body that replaced it is the wrong
  animation on the wrong character. Every other failure still falls back, as
  before.

Counters land in `MP-SUMMARY section=swinginbox`:
`accepted / applied / refused / expired / waited / gaveup / dropped /
peak_depth / bound`.

### 3.4 Item 5 — the stable-identity audit

**No CryEngine entity id crosses the wire anywhere.** Audited every packet pair
in `Protocol.cs` (**code-verified**):

| packet | identity on the wire | stable across machines? |
|---|---|---|
| `0x01/0x02` Position/Ghost | relay-assigned player id, 1 byte | yes — relay-assigned, not engine. **But it is a byte and the relay reuses it**; the wrap is a known, still-unfixed hazard (WO-75) |
| `0x12/0x13` Damage | 16-byte guid | **NO.** Documented as `SharedSoulGuid`; WO-39 Phase 3 proved it is the **per-save Soul Guid**, and WO-40 field-confirmed it resolves on some NPCs and not others (571/571 failures on one machine, 176/176 successes on another) |
| `0x14/0x15` Death | the same per-save guid | **NO**, same reason. Additionally WO-86 found no client ever sent one |
| `0x1A/0x1B` Appearance | ItemClass GUIDs | yes — authored class guids |
| `0x26/0x27` NpcState | entity **name** | yes — authored names are byte-identical per install |
| `0x2A/0x2B` HorseInfo | entity **name** | yes; runtime-spawned horses are excluded by design rather than sent with an unstable name |
| `0x2C/0x2D` CombatEvent | ghost id + event + `sid` | the id is fine; **`sid` is a counter, not an identity** — it correlates logs and cannot express validity. That is the gap §3.3 fills locally and §4 would fill on the wire |
| `0x30/0x31` NpcDamage | entity **name** | yes — this layer exists *because* the guid route was not |
| `0x32–0x35` ItemDrop/Claim | agent-minted `dropId`, per connection | yes within a connection, by construction |
| `0x37/0x38` StoryBeat | quest/objective key strings | yes — authored keys |

**Two violations, both already known and both still live:** `0x12` and `0x14`
carry a per-save guid. `0x30/0x31` superseded `0x12` for NPC damage and
`0x14`'s job moved onto a flag there, but the guid-addressed pair remains as a
fallback "for whenever the guids happen to match". On the evidence that is a
path that silently does nothing on the majority of NPCs. **Removing the `0x12`
fallback, or gating it behind a name-lookup failure that is itself logged, is a
WO-101 candidate** — not taken here because it is a behaviour change on the
damage path and this WO had no live session to verify it.

---

## 4. Phase 1 — where an attack is accepted (continued)

### 4.1 The game already separates "requested" from "resolved"

`I_CombatActor + 0x2F0` is the **combat model** — the object WO-42 recorded
under the vaguer name "combat state block" (`kOffCombatStateBlock = 0x2F0` in
`combat_construct.cpp`), and the same offset the shipped assertion
`combatActor->GetModel().RequestedAtkZoneId.Get()` walks (**code-verified**,
decompiled from `CombatModule` `0x49FAF0`).

The model is a flat struct of uniformly-laid-out named properties. One
function, `CombatModule` RVA `0xD8E50`, registers all of them, and decompiling
it yields every offset (**code-verified**). Each property occupies `0x40` bytes:

```
  base + 0x00   vptr          (the property is polymorphic; Get() is a vtable slot)
  base + 0x08   the value     (int / enum / bool, readable as a plain field)
  base + 0x10   owner back-pointer (set from model + 0x1100)
  base + 0x20   the registered debug name
```

The properties this WO cares about — **the accepted input, before the animation
is chosen**:

| property | base (model +) | what it is |
|---|---|---|
| `RequestedInputClass` | `0x300` | `combat_input_class_id`: `attack_light` 0, `attack_heavy` 1, `attack_special` 2, `move_*` 3–6, `block` 7 |
| `RequestedAtkZone` | `0x200` | `combat_zone_id` 0–5 — **the combat star** |
| `RequestedGuardZone` | `0x180` | `combat_zone_id` |
| `RequestedPreparedToAttack` | `0x380` | the press/hold request |
| `ReqEndGuardType` | `0xC0` | |

and the resolved half, for comparison:

| property | base (model +) |
|---|---|
| `InputClass` | `0x340` |
| `AttackZone` | `0x1C0` |
| `AttackType` | `0x2C0` (`combat_attack_type_id`) |
| `AttackStrength` | `0x280` |
| `AttackHandSlot` | `0x240` |
| `PreparedToAttack` | `0x3C0` |
| `GuardZone` / `GuardType` / `GuardStance` | `0x140` / `0x80` / `0x100` |
| `State` | `0x40` |
| `ComboState` / `RiposteState` | `0x480` / `0x4C0` |
| `BlockZoneId` / `BlockHandSlot` / `BlockMode` / `PerfectBlockState` | `0x7C0` / `0x800` / `0x868` / `0x8A8` |

**This is the WO's design conclusion already present in the engine.** The game
does not derive "what the player asked for" from the animation; it holds it as
first-class state, and the animation is chosen from it. Publishing
`RequestedInputClass` + `RequestedAtkZone` + the press/commit/cancel phase is
publishing exactly what the game itself calls the accepted input.

**Phase 1 items 1–3, answered.** What is available at the acceptance point: an
input class, a zone, a hand slot, a strength, a charged flag, a combo step — all
of them **row ids in shipped tables that carry name columns** (§2.1), and the
attack row itself carries a GUID (§2.2). Nothing here is a computed value or a
positional index without a name.

### 4.2 Item 4 — can the accepted input be replayed? Answered read-only: yes, structurally

Two shipped functions settle it without attempting anything:

1. **`C_CombatPlayerController::SetStandardGuardRequest`** (`0x33F110`) writes a
   model property through a generic setter, `CombatModule` RVA **`0xF4C20`**,
   called as `set(model + 0xEE8, 0, 1)` — `(propertyBase, value, flag)`
   (**code-verified**). So the model properties have a single, generic write
   entry.

2. **`C_CombatAutomationBlock::FireAction`** (`0x126800`) requests a whole
   combat action from **AI code, with no player input anywhere in the call**:

   ```c
   FUN_180076500(combatActor, &outAction, 6, zone, handSlot, packed(1, -1));
   //                                     ^ combat_action_type_id 6 == "block"
   ```

   The `6` is a row id in `combat_action_type` (§2.1), so the same entry with
   `3` is `attack`. The function returns a smart pointer to the queued action,
   and the caller logs `"Automated block was not triggered - anim queue failed!"`
   when it comes back null — i.e. **the engine already reports this action's
   failure at this level**, which is the reporter WO-98/WO-99 went looking for
   at the fragment level and could not find.

**So the acceptance path is not input-only.** Every NPC in every fight in the
shipped game reaches it without a device, and a ghost is an NPC-class entity
whose combat actor WO-45 already created and queued through.

**But acting on it is a native write, so Phase 5 is a STOP and did not
proceed.** What a future session is handed, precisely:

* the request entry `CombatModule` **`0x76500`**, signature approximately
  `(I_CombatActor*, smart_ptr<Action>* out, int actionTypeId, int zoneId, uint8 handSlot, int64 packed(strength, -1))` — the argument roles are read off **one** call site and are **(inconclusive)** until a second call site agrees;
* the property setter `CombatModule` **`0xF4C20`**, `(propertyBase, value, flag)`;
* the model at `I_CombatActor + 0x2F0` with §4.1's offsets;
* and a hard prerequisite: prologue-verify both RVAs before the first call, as
  `ghost_swing` already does, so a build mismatch disables the path rather than
  calling into the wrong bytes.

### 4.3 What this means for the WO's design conclusion

The conclusion holds, and is now evidenced rather than argued:

* the engine has a first-class "accepted input" representation
  (`Requested*` on the combat model) that is **upstream of the animation**;
* its vocabulary is table rows with **names and, for attacks, GUIDs** — so it
  crosses a wire as stable identity, not as a positional index;
* there is a shipped **non-input** path into it, used by the AI every fight;
* and that path reports its own failure at the action level, which is the
  reporter the fragment-queue design lacked.

The missing "fragment played/failed" reporter really is an artefact of the
fragment-queue design. One level up, the engine has one.

---

## 5. Phase 6 — the AI-less human class. It exists, it is `NPC_NAI`

### 5.1 Confirmed, and spawnable

`WHGame.dll`'s `InitGameFactory` registers, in one run of strings
(**code-verified**):

```
NullAI | AIFACTORY_DEBUG_registered | GameFactory.cpp | AddEntityClassFlag |
NPC_Female | NPC_NAI | DummyTarget | PlayerFemale | Animal | WildDog | Wolf |
InventoryDummyHorse | ... | NPCActor
```

`NPC_NAI` — "NPC, no AI" — sits exactly where the WO said it would, beside the
ordinary NPC classes and a dummy-target class. Its script is
`Scripts/Entities/AI/NPC_NAI.lua` in `Scripts.pak`, and it ends with

```lua
function NPC_NAI:RegisterAI(bForce)
	-- do nothing (null AI don't have AI objects)
end
...
EntityCommon.MakeSpawnable(NPC_NAI)
```

So: **the class exists, it declares its own AI-lessness in a shipped comment,
and it is explicitly spawnable** (**code-verified**). `NullAI` is a separate
thing — an AI-factory registration name in
`Scripts/Entities/AI/XML/AIFactoryRegistration.xml` — not this class.

### 5.2 What it keeps and what it loses, by diff against `NPC.lua`

Both are the same shipped file family, so this is a literal diff, not an
inference.

**Keeps — and these are the ones that matter for this WO:**

| kept | why it matters |
|---|---|
| `ActionController = kcd_male_controllerdefs.xml` | **the same Mannequin controller def as `NPC`** — so the same global tag definition §1.1 describes, and the same tag state §1.2 reads |
| `AnimDatabase3P = kcd_male_database.adb` | the same animation database, so every fragment a real NPC can play, it can play |
| `fileModel = …/male.cdf`, `fileHitDeathReactionsParamsDataFile` | the same body and the same hit/death reactions |
| `esClothingConfig = "male2"` | dressable — the appearance layer applies unchanged |
| `defaultSoulArchetype = "NPC"`, `esFaction = "Civilians"` | it still gets a soul and a faction |
| `UseMannequinAGState = true` | the Mannequin-driven animation state, which is the whole premise of Phase 3 |

**Loses — `NPC` has these properties and `NPC_NAI` does not:**

| lost | consequence |
|---|---|
| `bWH_PerceptorObject` | it perceives nothing |
| `bWH_PerceptibleObject` | **other NPCs cannot see it.** A guard will not react to it, a crowd will not part for it |
| `bWH_ListenerObject` | it hears nothing |
| `bWH_CreateSituationSubsystem` | no situation participation — the very thing WO-99.5 shipped a script context to *disable* on ghosts, absent here by construction |
| `bWH_RequiresHome` | no home, no schedule |
| `ProceduralContextLook` | **no head/look tracking.** It will not turn to look at anything |
| `OpponentMnTag = "relatedMale"`, `CombatOpponentMnTag = "oppMale"` | **it is not an opponent to the combat tag system.** Combat fragments that tag on the opponent's kind have nothing to key on |
| the full `AIMovementAbility` (cover, avoidance, accel/decel) | no pathfinding, no obstacle avoidance |
| `eiSoundObstructionType`, `perInstanceStreamingPriority` | minor |

### 5.3 Where this helps, and where it cannot

**It removes the contention problem completely, for any body we are willing to
replace rather than possess.** WO-98's sub-metre tug-of-war is a local brain and
a remote stream writing the same transform; a body with no AI object has no
local brain to contend with, so the stream is the only writer. WO-99's yield
rule (0.30 m over 10 ticks) exists to arbitrate a fight that would simply not
happen.

**Where it applies:**

* **Ambient crowd NPCs** — most of the contention volume, by count. A
  market crowd, villagers on a road, idlers in a tavern. Nobody's quest turns
  on them and nobody talks to them.
* **Possibly our own ghosts.** Ghosts already spawn as `NPC` /
  `NPC_Female` (`facePick.className`, `kdcmp.lua:4065`), so this is a one-word
  class change with the same Mannequin databases. It would end the ghost's own
  brain fighting the stream.

**Where it cannot apply, stated plainly:**

* **Any quest-relevant NPC that must remain itself.** Replacing the body
  replaces its soul, its home, its schedule and its perception. It is not the
  same character any more.
* **Anything another NPC must react to.** `bWH_PerceptibleObject` is gone, so
  it is invisible to the perception system. A crowd of `NPC_NAI` bodies would
  be a crowd nobody in the world can see.
* **Ghosts, if the shipped reactive-combat behaviour is to be kept.** WO-26
  established that a ghost already engages reactively with no toggle — that
  comes from the brain this class does not have. Swapping the class trades
  "ghosts fight back" for "ghosts never contend". That is a product decision,
  not a technical one, and it is the maintainer's.

**Investigation only, as instructed. Nothing was rebuilt on it.** The next
step, if it is ever taken, is small and cheap: spawn one `NPC_NAI`, confirm it
renders and animates, and measure whether the WO-98 tug-of-war disappears —
which is a live test, not a code change.

---

## 6. Phase 2 — the wire format, designed

Conditional on Phase 0, whose live check has not run, so this is **design
only**; nothing here is implemented. Bytes are *reserved* rather than spent —
`0x3B` is the next free one (WO-98 left `0x3A` as the last used).

### 6.1 Continuous channel — additive on Position/Ghost

The pattern is WO-99's `0x02 STALE` bit exactly: a new flag bit, new fields
appended, and an older receiver **ignores the extra bytes rather than dropping
the packet** — which is what the existing length-dispatch already does
(`payloadLen == PositionPayloadLen || payloadLen == PositionPayloadLenV2`).

```
flags bit 2 (0x04)  BODYSTATE   -- the packet carries the four fields below
  pace      : 1   0 none, 1 walk, 2 run, 3 sprint, 4 dash, 5 steps
  dir       : 1   0 none, 1 forward, 2 backward, 3 left, 4 right
  stance    : 1   0 upright, then a mod-owned enum keyed on the TAG NAME
  animSpeed : 2   pseudo-speed, fixed point, 0.01 m/s units, clamped 0..655
```

Five bytes. Three choices worth defending:

* **Enums keyed on tag NAMES, not on the engine's TagIDs.** A TagID is a
  position in a `CTagDefinition`, and §1.3 shows the whole table is rebuilt
  from XML per build. The name is the authored, stable thing. The sender maps
  name → our enum; the receiver maps our enum → *its own* TagID by name, and a
  name its build does not have is a **specific** rejection
  (`row-not-on-this-build`, §3.2), never a silently different tag.
* **Not the raw 20-byte TagState.** It is build- and definition-specific, four
  times larger, and would make a mismatch undetectable.
* **`stance` is a mod-owned enum, not a raw ordinal.** §1.1's Stance group has
  38 tags, most of them scene furniture (`hanushRailing`, `sittingVariation03`).
  Replicating all 38 is neither useful nor honest about what we can drive; the
  enum covers the ones that change how a body reads at a distance — upright,
  stealth, sitting, lying, horse, leaning — and everything else maps to the
  nearest of those with the real tag name logged.

### 6.2 Discrete channel — one shape for every replicated action

One packet pair, not one per action kind, so a new action costs a payload and
not a protocol:

```
C->S  0x3B  ActionUp:   [kind:1][seq:2][phase:1][gen:4][len:1][payload:len]
S->C  0x3C  ActionDown: [sourceGhostId:1] + the upstream body verbatim

kind   : attack=1, jump=2, emote=3, …  (append-only)
seq    : monotonic per sender, per kind
phase  : press=0, commit=1, cancel=2, complete=3
gen    : the validity counter, §6.3
payload: kind-specific. For attack, the accepted input from §4.1:
         [inputClass:1][zone:1][attackType:1][flags:1]
         -- all three are TABLE-ROW NAMES resolved to our own append-only
            enums, never the engine's row ids
```

`phase` is what makes this the input rather than the result: a press that is
never committed is a real thing the remote body should show and then abandon,
and a cancel is a first-class message rather than the absence of one.

### 6.3 Validity counters — `gen`

Four bytes: `[incarnation:2][epoch:1][revision:1]`.

* **incarnation** — the sender's body identity. Increments on death, respawn,
  save load, level change.
* **epoch** — the connection. Increments on reconnect, so an event that
  survived a relay round trip across a drop is discarded.
* **revision** — reserved, 0 for now; the field exists so a future need does
  not cost a protocol bump.

A receiver drops any event whose `gen` does not match what it currently holds
for that sender, counts it, and logs `reason=expired`. §3.3 already implements
exactly this shape locally with a single counter; the wire version is the same
rule made cross-machine.

**Why the triple here but a single counter in §3.3:** locally, all three causes
change the ghost's CryEngine entity id, so one observable covers them. Across
the wire there is no such shared observable — the sender must say which kind of
discontinuity happened, because the receiver cannot see it.

### 6.4 Ordering

Per `(sender, kind)`: keep the last dispatched `seq`; drop anything not greater
than it; count and log duplicates and out-of-order arrivals separately
(`stale-or-duplicate`, §3.2). `seq` wraps at 16 bits, compared modulo with a
half-range window — the same comparison §3.1 already uses for the pipe's
sequence byte.

### 6.5 Stable identity — the rule this format is built to keep

§3.4's audit is the input. The rule, stated once: **nothing that is a position
in a table, an engine handle, or a per-save identifier crosses the wire.** Names
and authored GUIDs do. Every field in §6.1–§6.3 obeys it; the two existing
violations (`0x12`, `0x14`) are named there and are not extended by this design.

---

## 7. Phase 3 — the gate, and a finding that changes item 4

**Not built. Phase 0's live known-answer check has not run** (§1.6), and Phase 3
drives a remote body from that read. Building it on a mapped-but-unverified read
is precisely the forced positive this WO's own instructions warn against.

One finding worth recording, because it changes what Phase 3 should do:

**Item 4's premise — "ghost smoothing, now unblocked" — is out of date. Ghost
smoothing already exists.** `KCD2MP_UpdateGhost` maintains a per-ghost velocity
estimate from real packet inter-arrival, lerps toward it, and snaps on a
displacement over 5 m (**code-verified**, `kdcmp.lua`). That is the WO's first
option — damped correction with an explicit teleport threshold — already
shipped. The *second* option, time-based snapshot interpolation-behind, also
already exists, on the **puppet** path (`mp_npc_smooth`, WO-77, from WO-75's
design).

So the WO's "pick one, do not build both" is not a choice still to be made;
both already exist, one per body kind. **Building a third would be the error the
instruction exists to prevent.**

What is genuinely missing is the **logging** item 4 asks for, and only part of
it. Agent-side, per-ghost inter-arrival and position delta are already
aggregated (WO-98's `GhostAgg`: `IaSum/IaMax/DSum/DMax/Stale`). **Correction
magnitude and snap count are not recorded anywhere.** Those two are the ones
needed to tune the existing smoothing, they cost nothing, and they are the
concrete next step for Phase 3 whether or not Phase 0 verifies.

---

## 8. Deviations

| deviation | taken or dropped |
|---|---|
| Imported four DLLs into Ghidra rather than the one the WO implied — CryAction, AnimationModule, EntityModule, CombatModule | **taken.** The chain crosses all four and no single one answers Phase 0 |
| Followed `C_Actor::GetPseudoSpeed` and `C_ActorStanceManager::GetCurrentLogicalSpeedTag`, which the WO did not name | **taken.** They are the animation-side speed the WO asked for, and Lua has no route to it |
| Did not call the engine's own `CTagDefinition::FlagsToTagList` in the probe, though it is right there | **dropped.** It needs a `CryStackStringT` with a heap-growth path through the module allocator; a pure field decode has the same result with no allocation and no engine-side state |
| Fixed `CombatPipe`'s stale-reply defect, which no phase asked for | **taken.** Found while reading for Phase 4 item 2; it silently corrupted every pipe result after one timeout |
| Phase 3 not built | **dropped**, on the Phase 0 gate — stated in §7 rather than worked around |
| Phase 5 not attempted | **dropped**, on the STOP rule — §4.2 |

## 9. WO-101 candidates

1. **Airborne.** Find the tag context that carries `kcd_pose_tags.xml`'s
   `ActorState` group (`jump`/`fall`/`land`) — §1.5. Likely a scope context
   rather than the global one.
2. **The `0x12`/`0x14` per-save-guid fallback.** Remove it, or gate it behind a
   logged name-lookup failure — §3.4.
3. **Correction magnitude and snap count** on the ghost smoothing — §7.
4. **`NPC_NAI` as a puppet body.** One live spawn, and a measurement of whether
   WO-98's tug-of-war disappears — §5.3.
5. **Phase 5**, when a maintainer is at the keyboard for the write: `0x76500`,
   `0xF4C20`, the model offsets in §4.1 — §4.2.

---

## 10. THE LIVE SESSION — 2026-09-17, 16:38–16:46

Maintainer at the keyboard, single player, **no relay and no agent**. The
Modding Tools game was launched normally and `KCDMP.dll` injected straight from
the build directory with `KCDMP_LauncherInjector.exe --pid 16644 --dll <path>`,
so **no deploy was needed at all** and the AppData redirect (WO-74/WO-99.5 §6.1)
never entered into it. The loaded module was verified the only admissible way:

```
ModuleMemorySize = 397312  ==  SizeOfImage of the 16:31 build   -- MATCH
```

**This supersedes the "maintainer must copy the DLL" step every native WO since
WO-45 has assumed.** The injector takes an absolute path; the DLL's own log
lands beside it (inside the repo, fully readable from the coding shell) and the
mirror still lands in the game root. For a solo native probe, nothing has to be
installed.

### 10.1 Phase 0 — **REACHABLE.** Known-answer check passed

Not a single `REFUSING` line in the whole session. All five gates held: the
controller vptr matched `CActionController::vftable`, and the two independent
routes to the tag definition agreed on every sample.

286 tags decoded, **`unknownTags=0` on every sample** — every tag in the
definition resolved through the `(byteIndex, mask)` arrays, with no leftovers.

The known-answer check, against what was on screen (**observed**):

| on screen | `MANN:` line |
|---|---|
| standing, unarmed | `pace=- dir=- stance=upright tags=l_noweapon+r_noweapon+r_equip_sword+player` |
| walking forward | `pace=walk dir=forward` |
| jogging forward | `pace=run dir=forward` |
| moving backwards | `pace=run dir=backward` |
| sprinting | `pace=sprint dir=forward` |
| crouched, moving | `stance=stealth` + `stealth+run+forward` |
| sword drawn | `r_noweapon` → `r_sword` |
| sword sheathed | `r_sword` → `r_noweapon+r_equip_sword` |
| in combat | `+combat +relatedMale` appear |

An independent cross-check of the decode itself: the raw state bytes read
`00 00 4C 0F 00 00 00 00 10 00 …`, and byte 8 = `0x10` is exactly what the
probe's own definition dump lists for the ungrouped `player` tag. The decode
agrees with the engine's own bit table, not merely with expectations.

### 10.2 The 300 ms "flicker" was the sampling, not the engine — and this matters

The first pass at 300 ms showed `pace=` dropping to `-` between movement
samples, which would have been fatal for Phase 3: a continuous channel cannot
publish a signal that is only intermittently true.

Re-armed at **50 ms** (live, by rewriting the watched file — no game restart)
and held a steady jog:

```
16:43:12.290  run+forward
    …          (repeats collapsed; only stopLegLeft/stopLegRight alternate)
16:43:18.597  run+forward
```

**6.3 seconds of unbroken `run+forward`.** In combat, at 50 ms, the same:
`run` → `sprint` → `run` → `walk` in clean continuous transitions.

**The MoveSpeed/MoveDir tags are stable continuous state.** The earlier gaps
were 300 ms sampling over tapped keys. This is the answer Phase 3 needed and it
is the good one: the continuous channel can publish these directly, at the
position stream's own cadence, with no smoothing or debouncing.

One detail for the wire: `stopLegLeft`/`stopLegRight` alternate at footfall rate
(~370 ms apart at a jog). They are per-footstep tags and should **not** be
published — the receiver's own animation system generates its own footfalls.

### 10.3 `pseudoSpeed` — both halves of the caveat proven

The player always read the `-1.000` sentinel. The `NPC_NAI` body read
**`0.000`** standing still. So `C_Actor + 0x7E8 → +0x18` is the right offset and
is populated on an ordinary actor; the **player** simply does not use it,
because `C_Player` overrides `GetPseudoSpeed` — exactly what the base
implementation's own trace line ("Forgot to override GetPseudoSpeed?") implies.

The probe's sentinel therefore means "this actor overrides it", not "the offset
is wrong". For the player specifically, the animation-side speed needs the
vtable override rather than the field. **Named, not hidden** — and it costs
Phase 3 nothing, because pace and direction come from the tags.

### 10.4 Phase 1 — **LIVE-VERIFIED.** 0 of 20 offsets failed their own name check

Every combat-model property read back the name the engine registered for it.
`RequestedInputClass` at `model+0x300` calls itself `RequestedInputClass`, live,
and so do the other nineteen. The map in §4.1 is confirmed, not inferred.

Two more cross-checks fell out for free:

* At rest, `AttackZone=upper_right` — which is the row `combat_zone.xml` marks
  `default_zone="true"`. The symbolic decode agrees with the shipped table.
* `State` takes values `1, 2, 4, 8, 16, 64, 128, 256` — it is a **bitmask**, not
  an enum. Worth knowing before anything keys on it.

**An entire accepted-input event, caught in flight** (16:41:08.810 → 09.762,
300 ms apart, so this is three consecutive samples of one attack):

```
08.810  RequestedInputClass=none          InputClass=attack_heavy AttackZone=head       AttackType=slash State=4
09.128  RequestedInputClass=none          InputClass=attack_heavy AttackZone=head       AttackType=slash State=8
09.445  RequestedInputClass=attack_heavy  InputClass=attack_heavy AttackZone=head       AttackType=slash State=8
        RequestedAtkZone=upper_left  RequestedPreparedToAttack=1
09.762  RequestedInputClass=none          InputClass=attack_heavy AttackZone=upper_right AttackType=slash AttackStrength=0.952
```

The `Requested*` triple is present and distinct from the resolved half, and
`RequestedPreparedToAttack=1` is the commit. **This is the WO's design
conclusion, observed rather than argued.**

### 10.5 A real defect the live data caught: the value width is part of the map

Three properties printed numbers that looked like data and were not —
`CombatMode=925523968`, `PerfectBlockState=1156810496`,
`PreparedToAttack=-1813265152`. They moved by **exactly 1 in the low byte** when
combat and blocking began, with three constant high bytes.

They are **one-byte bools**, and a 4-byte read was spanning into the
neighbouring field. `AttackStrength` is the mirror case: `1064546718` and
`1059833454` are nonsense as ints and **0.952** and **0.671** as floats — a
charge level, which is exactly what it should be.

Reading the wrong width does not fail, it lies. The probe now carries a
`PropType` per row (`I32` / `F32` / `Bool8`) so the width is part of the table
rather than an assumption. **This is the trap this project keeps meeting in a
new costume** (WO-96 §7, WO-97 §2, WO-99.5 §2.3): a read that returns something
plausible is not a read.

### 10.6 Phase 6 — `NPC_NAI` spawns, and has a full Mannequin controller

```lua
System.SpawnEntity({class="NPC_NAI", name="wo100_nai_probe", position=p})
  -> true, entity 0x1C05CC
  -> class=NPC_NAI human=true actor=true soul=true
```

Spawnable, and a full actor with a soul (**observed**). Then the probe was
pointed at it:

```
MANN: pace=- dir=- stance=upright pseudoSpeed=0.000 unknownTags=0 tags=l_noweapon+r_noweapon
MANN:   ctx=000002158B8F3320 defs=0000021291DDFD00
```

**It has its own action controller** (`ctx` differs from the player's
`00000214E43BCB00`) and **shares the player's tag definition object**
(`defs=0000021291DDFD00`, byte-identical pointer). `unknownTags=0`.

So an AI-less body is a **drop-in target for Phase 3's locomotion
replication**: same tag definition, same animation database, its own controller,
and no brain to contend with. That is the strongest possible version of §5.3's
claim, and it is now observed rather than diffed out of a script.

Two caveats found by doing it, not by reading:

* A bare `NPC_NAI` spawn with no faction logs `NPC <name> does not have a
  faction.` **every frame**. It is spawnable but not usable bare — the same
  bare-spawn starvation family WO-56 named. A real use needs a soul and faction
  assigned, exactly as ghost spawning already does.
* The Lua `entity.AI` member reads non-nil, but that is the `self.AI = {}` the
  shipped script assigns in `NPC_NAI_ResetCommon`. It is an empty table, not an
  AI object, and `RegisterAI` is a documented no-op. **Do not read `entity.AI`
  as evidence of a brain.**

The test body was removed and the faction spam stopped; the probe was disarmed.

### 10.7 What this changes in the verdicts above

| section | was | now |
|---|---|---|
| §1 Phase 0 | mapped, live check pending | **REACHABLE, live-verified.** Pace/dir/stance confirmed against on-screen behaviour; tags are continuous state |
| §1.5 pseudo-speed | "reachable as a scalar", caveat noted | caveat **proven both ways**: works on an NPC, overridden on the player |
| §4 Phase 1 | code-verified map | **live-verified**, 20/20 name checks, plus a captured attack |
| §4.1 property layout | offsets only | offsets **plus widths** — three bools and one float were being misread |
| §5 Phase 6 | class exists per shipped script | **spawns, and has a Mannequin controller sharing the player's tag definition** |
| §7 Phase 3 gate | blocked on Phase 0 | **gate passed.** Phase 3 is now unblocked on evidence |

**Still not verified, and still unverifiable solo:** everything in Phase 4 — the
swing reason codes, the inbox counters, the body-generation rule. Those need two
machines. Phase 5 remains a STOP regardless.
