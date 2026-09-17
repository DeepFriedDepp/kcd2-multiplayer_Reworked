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
| 0 — Mannequin tag state readable? | **surface mapped, partially**: pace/direction/stance yes, animation speed yes as a scalar, **airborne no** (§1.5). Live known-answer check **not run** — needs the maintainer, runbook in §1.6 |
| 1 — attack acceptance point | **found** (S4): `I_CombatActor+0x2F0` is the combat model; `RequestedInputClass` / `RequestedAtkZone` / `RequestedPreparedToAttack` are the accepted input, offsets mapped. Replayability answered **read-only: yes, structurally** -- the AI uses the same entry -- but acting on it is a native write, so **Phase 5 is a STOP and did not proceed** |
| 2 — wire format | not reached |
| 3 — locomotion replication | not reached |
| 4 — unconditional improvements | **landed**, all five items + one defect found while reading (§3). 111 tests green, **(synthetic)** — no live session |
| 5 — combat replication | **not run -- STOP.** The blocker is named precisely rather than vaguely: every remaining step is a native write (S4.2) |
| 6 — AI-less puppet class | not reached |

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

**Runbook — needs the maintainer, ~2 minutes in game.** The DLL is
maintainer-deploy (WO-45); verify it by `ModuleMemorySize` on the loaded
module, never by the file on disk (WO-99.5 §6.1).

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
