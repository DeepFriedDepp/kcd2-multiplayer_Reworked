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
| 1 — attack acceptance point | *in progress* |
| 2 — wire format | not reached |
| 3 — locomotion replication | not reached |
| 4 — unconditional improvements | not reached |
| 5 — combat replication | not reached |
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
