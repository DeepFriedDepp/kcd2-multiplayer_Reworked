# WO-42 — the native combat-animation route, disassembled

Reverse-engineering session, 2026-08-21. **No mod code was written or changed
this session** (that is WO-43's job, deliberately separated). Everything below
comes from static disassembly of this machine's own installed binaries with
Ghidra 12.1.3 headless; the game was never launched and no process was touched.

Read this together with `docs/WO-40-findings.md` (Phase 1 / Phase 6 — the
scripting-layer attempts already closed out) and
`docs/WO-42-libkcd2-reference.md` (the community claims this session was
measuring against). Where this document and that reference disagree, **this
document wins** — it is derived from the binaries actually installed here.

**This session resolves WO-41's stated blocker.** `docs/WO-41-progress.md`
("The real difficulty, stated honestly") stopped at: the combat-attack
construction path is built by free dispatch functions that are not exported, so
"reaching them means **disassembling CombatModule.dll to re-derive the
equivalents**". That is exactly what this session did. WO-41's independent
version finding (Modding Tools 1.5.5 vs retail 1.5.6, non-monolithic vs
monolithic) is reproduced here in §1 from a second direction.

**Evidence classes used below**, per this project's convention:

- **observed** — read directly out of the disassembly/binary this session.
- **read-but-unrendered** — a mechanism traced in code but never executed in a
  running game, so its *behaviour* is unverified.
- **inferred** — a reading that goes a step beyond what the bytes say; every one
  is labelled.

Reproduction assets (kept, reusable): `native/ghidra_scripts/DumpWo42Anchors.java`,
`DumpWo42Fns.java`, `DumpWo42Asm.java`, `DumpWo42Callers.java`, `DumpWo42Vtbl.java`.

---

## 0. The one fact that made this session cheap, and changes the method

The community reference resolves addresses by byte-pattern scanning because
retail is a stripped monolith. **This install is not that.** Three properties of
the Modding Tools build, all **observed**:

1. **The engine is split into per-subsystem DLLs.** `CombatModule.dll` (8.93 MB)
   and `AnimationModule.dll` (2.15 MB) exist as separate images, instead of
   retail's single `WHGame.dll`.
2. **Asserts and trace logging are compiled in, with `__FUNCTION__` strings and
   full source paths retained.** Every function of interest carries a literal
   copy of its own fully-qualified name:

```
1805AA700  "wh::combatmodule::C_CombatActorActionSyncAttack::EnterImpl"
1805AA690  "d:\buildagent\work\7ffb7f119a855ecb\code\game\modules\combatmodule\Actions\CombatActorActionSyncAttack.cpp"
180169B08  "wh::animationmodule::C_AnimationController::QueueAction"
```

3. **MSVC RTTI is present**, so Ghidra's RTTI analyzer recovers real class names
   and vftable labels (`wh::combatmodule::C_CombatActorActionSyncAttack::vftable`,
   `IAction::vftable`, `TAction<SAnimationContext>::vftable`, …).

**Method consequence, and it is the important one:** identification here is
*not* pattern matching. A function that references the string
`"wh::animationmodule::C_AnimationController::QueueAction"` **is** that function
— the compiler put its own name inside it. Every address in this document is
anchored either to such a string or to an RTTI-recovered vftable, and then its
**body was read** to confirm it does what the name says. That is the
"verify, don't assume" bar the WO set, met by construction.

**Correction to a WO-40 assumption.** WO-40 Phase 1 recorded that "our Modding
Tools build exports mangled C++ symbols, so these entry points may be directly
`GetProcAddress`-able here — strictly better than retail's address library."
**That is false for these functions.** Full export dumps (`dumpbin /exports`):
`AnimationModule.dll` exports **90** names, `CombatModule.dll` exports **63**,
and the great majority of both are `boost::optional<bool>` template noise.
`QueueAction` is not exported. No combat action class is exported. The only
export in scope is `??0C_AnimationController@animationmodule@wh@@QEAA@XZ` (the
controller's default constructor, RVA `0x20150`) — which is not what we need to
call. **WO-43 must resolve by module base + RVA, not by name.** §7 gives the
verification recipe that makes that safe.

---

## 1. Phase 1 — the version baseline: **MISMATCH. Everything was re-derived.**

| | Modding Tools (this project's target) | Retail (what the reference documents) |
|---|---|---|
| Install | `D:\SteamLibrary\steamapps\common\KCD2Mod` | `…\KingdomComeDeliverance2` |
| `KingdomCome.exe` FileVersion | **1.5.5.0** (observed) | **1.5.6.0** (observed) |
| Build preset (`whdlversions.json`) | `kcd2_release_1_5_moddingtools_pc` | `kcd2_release_1_5_game_pc` |
| Binary config | `ReleaseSteamLTO_DLL`, build `1166656_117`, 2026-04-16 | `MasterMasterSteamPGO`, build `1308617`, 2026-06-15/19 |
| Link shape | per-module DLLs (`CombatModule.dll`, `AnimationModule.dll`, …) | monolithic `WHGame.dll` |
| Asserts / `__FUNCTION__` strings | present | (retail: PGO master, stripped) |

The mismatch is not a point release — it is a **different build number, a
different optimisation configuration, and a different link topology.** The
reference's addresses are offsets into a `WHGame.dll` that does not exist in
this install. **Nothing was carried over numerically.** Everything in §2–§6 was
re-derived from these binaries.

What the reference *did* buy us — and it was worth real time — is the map: the
class names, the existence of a paired attack/hit mechanism, and the
`m_pSyncPartner` idea. Those told us where to look. Three of its structural
claims came back confirmed, two came back wrong:

| Reference claim | Verdict here | Detail |
|---|---|---|
| `QueueAction(IAction&, float, bool)` takes a constructed action, not a name | **CONFIRMED** (observed) | §2 |
| `QueueAction` at animation-controller **vtable slot [1]** | **CONFIRMED** (observed) | §2.2 |
| `IActionController::Queue` at **vtable+0x98** | **CONFIRMED** (observed twice, independently) | §2.3 |
| `IAnimatedCharacter::GetActionController()` at slot **[37]** | **WRONG for this build** | it is at byte offset **+0x130** = slot **[38]** (observed) |
| `C_CombatActorActionAttack` is **`sizeof 0xB0`** | **WRONG for this build** | it is **`0xC0`** (observed at the allocation site, §4.3) |
| A `SyncAttack`/`SyncHit` pair linked by a back-reference | **CONFIRMED, and both ends located** | §5.1 |

---

## 2. Phase 2.1 — `QueueAction`: address, calling convention, body

### 2.1 Identity and address

**`wh::animationmodule::C_AnimationController::QueueAction` = `AnimationModule.dll`
RVA `0x00020410`** (image base 0x180000000 → `0x180020410`). **Observed.**

Anchors, all three inside the function body:

| RVA of anchor | Content |
|---|---|
| `0x169B08` | `"wh::animationmodule::C_AnimationController::QueueAction"` |
| `0x169B40` | `" %s.QueueAction[%d](%s) -> %s [GlobalTags=%s]"` |
| `0x169B80` | `"…\animationmodule\AnimationController\AnimationController.cpp"`, line `0x34` (52) |

### 2.2 It is vtable slot [1] — and of *which* subobject

`C_AnimationController`'s constructor (RVA `0x20150`, an exported symbol, so
this part is certain) installs **two** vptrs:

```
180020170  LEA RAX,[0x180168758]      ; C_AnimationController::vftable  (A)
180020177  MOV [RDI], RAX             ;   -> object + 0x00   (primary)
18002017E  LEA RAX,[0x180168720]      ; C_AnimationController::vftable  (B)
180020189  MOV [RDI+0x40], RAX        ;   -> object + 0x40
```

Table **B** at RVA `0x168720` is the `I_AnimationController` interface table.
Its slots (observed):

| offset | slot | target |
|---|---|---|
| +0x00 | [0] | `0x18002F274` |
| **+0x08** | **[1]** | **`0x180020410` — QueueAction** |
| +0x10 | [2] | `0x180021080` |
| +0x18 | [3] | `0x180021060` |
| +0x20 | [4] | `0x180020CF0` |
| +0x28 | [5] | `0x180020C30` |
| +0x30 | — | the next table's RTTI complete-object locator, so this interface has exactly 6 virtuals |

`0x180020410` is referenced from **exactly one** vtable slot in the whole module:
`0x180168728` = table B + 0x08. (The other four data references to it — at
`0x1801F8DB8`, `0x1801B1278`, `0x1801B128C`, `0x1801B129C` — are 4-byte-aligned
32-bit RVAs: `.pdata`/EH `RUNTIME_FUNCTION` entries, not vtables. Checked by
dumping those regions; they decode as packed RVA pairs, e.g.
`0x000204CC`/`0x00020410`.)

**So `I_AnimationController` is the base subobject at `C_AnimationController + 0x40`,
and `QueueAction` is slot [1] of it.** This also resolves an oddity in the
decompilation: `QueueAction` reads `[this - 8]`, which is only sane because
`this` is the +0x40 subobject and `object + 0x38` is the member immediately
before it. Consistent, not a decompiler artefact.

### 2.3 Calling convention — register-level, from the instruction stream

```
180020410  PUSH RBX / R13 / R14 / R15 ; SUB RSP,0xD8
180020439  MOV  R13, RCX              ; RCX = this  (the +0x40 subobject)
18002043C  MOVZX EBX, R9B             ; R9B = bool  restartInstalled
180020447  MOVAPS XMM6, XMM2          ; XMM2 = float time   (saved across the log calls)
18002044A  MOV  R14, RDX              ; RDX = IAction* action
...
180020637  MOVAPS XMM2, XMM6          ; restored immediately before the real call
18002064E  MOV  AL, 0x1               ; returns bool, unconditionally true
180020676  RET
```

```c
// CONFIRMED, observed at register level
bool __fastcall C_AnimationController_QueueAction(
        void*  this_,             // RCX  — the I_AnimationController subobject (object + 0x40)
        void*  action,            // RDX  — IAction*
        float  time,              // XMM2 — the game passes -1.0f
        bool   restartInstalled); // R9   — the game passes false
```

Standard MS x64. The `float` really is in **XMM2** (argument slot 3), not R8 — an
implementer who declares the third parameter as `int`/`void*` will corrupt the
call. This is the single most easily-got-wrong detail in the whole document.

### 2.4 What the body actually does

```c
IActionController* ac = this_->[+0x10] /*IAnimatedCharacter*/ ->vtbl[0x130]();  // GetActionController
if (!ac) return true;

int status = action->[+0x28];
if (status == 0 || status == 4) {
    // ---- logging block only (builds two CryStrings, then trace::Write) ----
    //   reads: ac->vtbl[0xB0]()          context; its +0x10 feeds the global-tags string
    //          action->[+0x38]           fragmentID
    //          action->[+0x3C .. +0x4F]  20-byte TagState
    //          action->[+0x24]           the "[%d]" (priority — see §3)
    //          action->vtbl[0xB0]()      action name
    // ---- the real work ----
    ac->vtbl[0x98](ac, action, time);           // IActionController::Queue(IAction&, float)
}
else if (restartInstalled && status == 2) {     // 2 == already installed
    uint32 f = action->[+0x2C];
    action->[+0x2C] = f | 0x80;
    if (!(f & 0x40)) {
        action->[+0x2C] = f | 0xC0;
        void* obj = ((void**)action->[+0x30])->vtbl[0x20]();   // rootScope -> action controller
        obj->vtbl[0xA0](obj, action);                          // IActionController::Requeue(IAction&)
    }
}
return true;
```

**Confirmed derived vtable offsets** (observed):

| interface | offset | meaning | how confirmed |
|---|---|---|---|
| `IAnimatedCharacter` | **+0x130** | `GetActionController()` | used identically in two independent functions (`0x20410` in AnimationModule, `0xF3C00` in CombatModule) |
| `IActionController` | **+0x98** | `Queue(IAction&, float)` | the sole real call in the success path, in both those functions |
| `IActionController` | **+0xA0** | `Requeue(IAction&)` | the restart path; adjacent to Queue |
| `IActionController` | **+0xB0** | context getter (result's `+0x10` feeds the global-tags string) | both functions |
| `IAction` | **+0x08 / +0x10** | AddRef / Release (`_smart_ptr` interface) | the SyncHit factory's tail, §5.1 |
| `IAction` | **+0xB8** | release/destroy virtual | every release site: `if (--refcount < 2) action->vtbl[0xB8]()` |

**Nothing about `QueueAction` is speculative.** It is a thin wrapper: resolve the
action controller off the animated character, filter on the action's status, log,
and forward to `IActionController::Queue`.

---

## 3. `IAction` / `TAction<SAnimationContext>` — the confirmed memory layout

This is the layout an implementer needs, and it is **observed from the constructor
itself**, which Ghidra identified by RTTI (it writes `IAction::vftable` and then
`TAction<SAnimationContext>::vftable`):

- `CombatModule.dll` RVA **`0x10BA90`** — 6-parameter form
- `AnimationModule.dll` RVA **`0x100250`** — 7-parameter form (one extra field)

Both are per-module copies of the same template body (LTO/DLL split).

```c
// AnimationModule RVA 0x100250 — the fuller of the two
void* TAction_ctor(void* this_,       // RCX
                   uint32 priority,   // EDX
                   uint32 fragmentID, // R8D
                   const void* tags20,// R9   — pointer to 20 bytes of TagState
                   uint32 flags,      // [rsp+0x20]
                   uint32 arg6,       // [rsp+0x28]
                   uint32 scopeMask); // [rsp+0x30]  (7-arg form only)
```

| offset | size | set to | reading |
|---|---|---|---|
| +0x00 | 8 | `IAction::vftable`, overwritten at the end with `TAction<SAnimationContext>::vftable` | vptr |
| +0x08 | 8 | 0 | |
| +0x10 | 4 | 0 | |
| +0x14 | 4 | `0xBF800000` = **-1.0f** | a float (name *inferred*) |
| +0x18 | 4 | `arg6` | |
| +0x1C | 4 | 0 | |
| +0x20 | 4 | `0xFFFFFFFF` | |
| **+0x24** | 4 | `priority` | **priority** — the `[%d]` in `QueueAction`'s log |
| **+0x28** | 4 | 0 | **status** (`0` = none; `QueueAction` accepts 0 and 4; `2` = installed) |
| +0x2C | 4 | `flags` | flags (`QueueAction`'s restart path sets bits 0x40/0x80) |
| +0x30 | 8 | 0 | **root scope / director** (used by the Requeue path) |
| **+0x38** | 4 | `fragmentID` | **FragmentID** |
| **+0x3C** | 20 | `memcpy` from `tags20` (two qwords + one dword) | **TagState — 0x14 bytes** |
| +0x50 | 4 | `0xFFFFFFFE` | |
| +0x54 | 4 | `scopeMask` (7-arg form) / 0 (6-arg form) | name *inferred* |
| **+0x58** | 4 | 0 | **intrusive refcount** (`_smart_ptr`) |
| +0x5C | 4 | `0x3F800000` = 1.0f | |
| +0x60 | 4 | `0x3F800000` = 1.0f | |
| +0x68 | 8 | a static empty-array sentinel | **named-parameter array** (§6.3) |
| +0x70, +0x78 | 8+8 | 0 | |
| +0x80 | 4 | 0 | |
| +0x88 | 8 | a second static sentinel | second container |

**`TagState` is 20 bytes (0x14) in this build.** Corroborated three independent
ways: the constructor copies exactly 20 bytes; `QueueAction`'s logging block
reads exactly `MOVUPS xmm0,[action+0x3C]` plus `MOV eax,[action+0x4C]`; and
`C_CombatAnimActionManager::QueueAction` reads the identical five dwords.

**`+0x24` is definitively priority**, not something else — the constructor takes
it as the parameter that the call sites pass literal `5`, `6`, `7` for, and
`QueueAction` logs that same field as `QueueAction[%d]`.

---

## 4. Phase 2.2–2.4 — the combat action classes, constructors and factories

All in `CombatModule.dll`, image base `0x180000000`.

### 4.1 Address table (every row **observed**, anchor named)

| RVA | What | Anchor used to identify it |
|---|---|---|
| `0x0F3C00` | `C_CombatAnimActionManager::QueueAction(this, _smart_ptr<C_CombatAnimAction>&, float)` | own `__FUNCTION__` @ `0x5CB3D0` + fmt `"Combat %s.QueueAnimAction[%d](%s) -> %s [GlobalTags=%s]"` |
| `0x0F26F0` | `C_CombatAnimAction` constructor, **sizeof `0x1A8`** | writes `C_CombatAnimAction::vftable`; size read at its allocation sites |
| `0x10BA90` | `TAction<SAnimationContext>` ctor (CombatModule copy) | writes `IAction::vftable` / `TAction<SAnimationContext>::vftable` (RTTI) |
| `0x05BDB0` | **factory** for `C_CombatActorActionSyncAttack` (allocates `0xC0`, constructs, wires descriptors) | sole non-data caller of `0x53E00` |
| `0x053E00` | `C_CombatActorActionSyncAttack::C_CombatActorActionSyncAttack(I_CombatActor&)` | writes all four `C_CombatActorActionSyncAttack::vftable`s, after the base ctors |
| `0x054010` | its destructor | writes the same four vptrs within the first 0x36 bytes |
| `0x0543D0` | `C_CombatActorActionSyncAttack::EnterImpl` — **with `C_CombatActorAnimatedAction<SyncAttackParams,1,…>::Queue` inlined into it** | references *both* `__FUNCTION__` strings (`0x5AA700` and `0x5AE6E0`) |
| `0x054FA0` | `C_CombatActorActionSyncAttack::ExitImpl` | `__FUNCTION__` @ `0x5AA740` |
| `0x055430` | `C_CombatActorActionSyncAttack` member that **creates and pairs the SyncHit** (§5.1) | sole non-data caller of the SyncHit factory |
| `0x088990` | **factory + constructor** for `C_CombatActorActionSyncHit`, **sizeof `0xD8`** | writes the three `C_CombatActorActionSyncHit::vftable`s; size at its own inline allocation |
| `0x055640` | `C_CombatActorActionSyncHit` destructor | same vptrs, written immediately at entry |
| `0x055710` | `C_CombatActorActionSyncHit::EnterImpl` — **Queue inlined** | both `__FUNCTION__` strings (`0x5AA7E0`, `0x5AE790`) |
| `0x056420` | `C_CombatActorActionSyncHit::ExitImpl` | `__FUNCTION__` @ `0x5AA818` |
| `0x084D20` | **factory + constructor** for `C_CombatActorActionAttack`, **sizeof `0xC0`** | writes the four `C_CombatActorActionAttack::vftable`s |
| `0x084F30` | a second `C_CombatActorActionAttack` factory variant | also calls the helper ctor `0x61470` |
| `0x044140` | `C_CombatActorActionAttack` destructor | vptrs at entry |
| `0x044300` | `C_CombatActorActionAttack::EnterImpl` | `__FUNCTION__` @ `0x5A9450` |
| `0x0450D0` | `C_CombatActorActionAttack::ExitImpl` | `__FUNCTION__` @ `0x5A9598` |
| `0x044AB0` | `C_CombatActorAnimatedAction<AttackParams,1,…>::Queue` — **a real separate function here**, not inlined | `__FUNCTION__` @ `0x5ACFF0`; called from `0x044749` inside `EnterImpl` |
| `0x061470` | `C_CombatActionHelperAttack` constructor, **sizeof `0x50`** | writes `C_CombatActionHelperAttack::vftable`; size at all five call sites |
| `0x061890` | `C_CombatActionHelperAttack::EnterImpl` | `__FUNCTION__` @ `0x5AB290` |
| `0x0813F0`, `0x084470` | `C_CombatActionHelperAttack::FillSyncHitInfo` (two template instantiations) | `__FUNCTION__` @ `0x5ACCC0` |
| `0x092520`, `0x0955C0`, `0x0457C0` | `C_CombatActionHelperAttack::FillTimeToHit` instantiations | `__FUNCTION__` @ `0x5ACE40` |
| `0x0CBAD0` | installs a `std::function` delegate at `C_CombatAnimAction + 0x120` | body reads `+0x158`, writes `+0x120` |
| `0x0CB740` | installs a `std::function` delegate at `C_CombatAnimAction + 0x0A0` | body reads `+0x0D8`, writes `+0x0A0` |
| `0x655430` | the float constant **`-1.0f`** (`0xBF800000`) passed as `time` | read out of the file |

Relevant vftable RVAs (RTTI-recovered labels): SyncAttack `0x5C0E60` / `0x5C10D0`
/ `0x5C1098` / `0x5C0E18`; SyncHit `0x5C0B60` / `0x5C0D98` / `0x5C0DD0`; Attack
`0x5C3A58` / `0x5C3A90` / `0x5C3AD0` / `0x5C3B18`; `C_CombatActionHelperAttack`
`0x5BFEF0` and `0x5BFF08`; `C_CombatActionEarlyExitHelper` `0x5BFF70`;
`I_CombatActionHelperAttackOwner` `0x5C41C0`.

**`C_CombatActionEarlyExitHelper` has no separate constructor function** — it is
**constructed inline** (five stores) inside both the SyncAttack constructor and
the SyncHit factory. **sizeof `0x18`.** Initialisation, verbatim (observed):

```c
void* h = alloc(0x18);
h[0x00] = C_CombatActorObject::vftable;
h[0x08] = actor;
FUN_1800723A0(actor, h);          // RVA 0x723A0 — registers h with the actor
*(uint8*)(h + 0x10) = 0;
h[0x00] = C_CombatActionEarlyExitHelper::vftable;   // RVA 0x5BFF70
*(uint32*)(h + 0x14) = 0;
```

### 4.2 Class layouts

All **observed** from the constructors, then cross-checked against the field
reads in the corresponding `EnterImpl`.

**`C_CombatActorActionSyncAttack` — sizeof `0xC0`**

| offset | contents |
|---|---|
| +0x00 | vptr → vftable `0x5C0E60` |
| +0x10 | vptr → vftable `0x5C10D0` |
| +0x14 … +0x88 | the `TAction<SAnimationContext>` base fields of §3 |
| +0x40 | `C_CombatActorAction` state (ctor sets **2**) |
| +0x44 | priority (ctor sets 0) |
| +0x48 | `wh::framework::C_ActionDirector*` (taken from `actor + 0x2E0`) |
| +0x58 | `S_CombatActorActionSyncAttackParams::vftable` — the params are embedded here |
| **+0x60** | **attack descriptor** (params field 1) — written by the factory |
| **+0x68** | **hit descriptor** (params field 2) — written by the factory |
| +0x70 | vptr → vftable `0x5C1098` (the `C_CombatActorObject` chain) |
| **+0x78** | **`I_CombatActor*`** — the constructor's second argument |
| +0x8C | flags (factory sets from the request; `\|0x1000` if no hit descriptor, `\|4` conditionally) |
| **+0x90** | **`C_CombatAnimAction*`**, refcounted; 0 until `EnterImpl` |
| +0x98 | vptr → vftable `0x5C0E18` (the `I_CombatActionHelperAttackOwner` chain) |
| **+0xA0** | **`C_CombatActionHelperAttack*`** — 0x50 bytes, ctor `0x61470(mem, actor, this+0x98)` |
| **+0xA8** | **`C_CombatActionEarlyExitHelper*`** — 0x18 bytes, inline |
| **+0xB0** | **`_smart_ptr` to the paired `C_CombatActorActionSyncHit`** — 0 in the ctor |
| +0xB8 | bool, 0 in the ctor; set to 1 when the pair is created |

**`C_CombatActorActionSyncHit` — sizeof `0xD8`**

| offset | contents |
|---|---|
| +0x00, +0x10, +0x68, +0x98 | the four polymorphic subobjects |
| +0x40 | state (**2**); +0x44 priority (0); +0x48 `C_ActionDirector*` |
| **+0x58** | **hit descriptor** — 0 in the factory, written by the pairing code |
| +0x60 | a bool, written by the pairing code |
| **+0x70** | **`I_CombatActor*`** — *the victim*, not the attacker |
| +0x84 | u32, 0 in the factory; overwritten by the pairing code |
| +0x88 | `C_CombatAnimAction*` |
| +0x90 | u32 = 2; +0x94 = `0x100` |
| +0x98 | a helper subobject, initialised by `0x636C0(this+0x98, actor)` |
| **+0xC8** | `C_CombatActionEarlyExitHelper*` |
| **+0xD0** | **raw back-pointer to the partner `C_CombatActorActionSyncAttack`** — 0 in the factory |

**`C_CombatActorActionAttack` — sizeof `0xC0`** (**not** the reference's `0xB0`)

Same shape as SyncAttack minus the sync machinery: +0x58 params vptr,
**+0x60 attack descriptor**, +0x68 u32 = `0x101` (the caller then writes bytes at
+0x68/+0x6A/+0x6B), +0x70 vptr, **+0x78 actor**, +0x8C flags,
**+0x90 `C_CombatAnimAction*`**, +0x98 vptr, +0xA0 = 0, +0xA8 = 0,
**+0xB0 `C_CombatActionHelperAttack*`**. No early-exit helper, no sync partner.

**`C_CombatAnimAction` — sizeof `0x1A8`**, constructor RVA `0x0F26F0`:

```c
// register-level, read off the call site at 0x180054820
void* CombatAnimAction_ctor(
        void*  this_,       // RCX  — freshly allocated 0x1A8 block
        void*  same,        // RDX  — the same pointer again; the body never reads it
        void*  actor,       // R8   — I_CombatActor*
        uint32 priority,    // R9D  — 5 for attack/sync-attack, 7 for sync-hit
        uint32 fragmentID,  // [rsp+0x20]
        const void* tags20, // [rsp+0x28]
        uint32 flags);      // [rsp+0x30] — the game passes 0
// body: TAction_ctor(this_, priority, fragmentID, tags20, flags, 0);
//       this_[+0x00]  = C_CombatAnimAction::vftable
//       this_[+0x90]  = 0 (u32);   this_[+0x98] = 0 (u8)
//       this_[+0xD8]  = this_[+0x118] = this_[+0x158] = this_[+0x198] = 0
//       this_[+0x1A0] = 0
//       this_[+0x94]  = flags
//       this_[+0x9C]  = *(u32*)(*(void**)(actor + 0x2D8) + 0x30)
```

The four zeroed qwords at 0x40-byte stride are the "callable" slots of **four
`std::function` delegates at +0x0A0, +0x0E0, +0x120, +0x160** (each 0x40 bytes,
its callable pointer at +0x38 within). Confirmed by the two installer helpers:
`0x0CB740` writes +0x0A0 (reads +0x0D8) and `0x0CBAD0` writes +0x120 (reads
+0x158). **Observed.**

Field **`+0x84 … +0x93` (16 bytes) of `C_CombatAnimAction` is an asset GUID** the
engine fills in — *not* the constructor — and it is load-bearing; see §5.3.

### 4.3 Where the sizes come from

Every `sizeof` above is read directly off the allocation instruction immediately
preceding the constructor call, e.g.

```
1800547B0  MOV RAX,[0x18080F930]     ; the module allocator
1800547BF  MOV ECX,0x1A8             ; <-- sizeof(C_CombatAnimAction)
1800547C4  CALL RAX
```

and for the actions: `0xC0` at `0x18005C08B` (SyncAttack factory), `0xD8` at
`0x1800889B0` (SyncHit factory), `0xC0` at `0x180084D30` (Attack factory), `0x50`
for the attack helper, `0x18` for the early-exit helper. **Observed.**

### 4.4 `I_CombatActor` member offsets used by these paths

Every row below is a field the traced code actually dereferences, so each is
**observed** — but the *names* are read off how the field is used, and are
therefore **inferred** except where a call resolves the type unambiguously.
This table is what WO-43 will actually need to navigate from an actor pointer.

| offset | what the code does with it | reading |
|---|---|---|
| +0x2D8 | `(*(void***)(actor+0x2D8))->vtbl[0x490]()` → the `%s` in every "Actor: %s" log; `->vtbl[0x2D0]()` → an `IAnimatedCharacter`; `+0x30` read as a u32 into `C_CombatAnimAction+0x9C` | the owning entity / animated entity |
| +0x2E0 | passed as the first argument of the base `C_Action` ctor; used as the `C_ActionDirector*` argument to `wh::framework::C_ActionDirector::SetAction` | **`C_ActionDirector*`** (type confirmed by the imported symbol) |
| +0x2F0 | `+0x1118` → the current opponent's actor; `+0xF40` → a flags object (`vtbl[0x08]()`); `+0x40`, `+0xD28`, `+0xE28`, `+0xD68`, `+0x80`, `+0x100`, `+0x140`, `+0x540`, `+0x5C0`, `+0x580`, `+0xB18`, `+0xF40` all read | the combat state block |
| +0x300 | first argument of `FUN_180161CF0` during Enter | — |
| +0x478 | passed to `FUN_180374CD0` during attack selection | — |
| **+0x490** | **the `C_CombatAnimActionManager`** that `QueueAction` is called on | confirmed by the call site |
| +0x498 | `+0x08` → an `I_CombatActor*` (the victim, in the pairing path); `+0xB8` → an attack-selection object | an action/attack owner |
| +0x4B0 | target of `FUN_1800E4170` in the post-queue block | — |
| +0x4D0 | `FUN_1800E07B0(that, 6)` after queueing | — |
| +0x4D8 | `FUN_1800E80E0(that)` during attack selection | — |

**Not checked here:** WO-41's note that `C_Actor::m_pCombatActor` sits at
`C_Actor + 0x278` and `C_CombatActor::m_pActionManager` at `+0x3A8`. Those are
`libKCD2` structural claims about *different* classes (`C_Actor` in
`EntityModule.dll`), and this session did not open `EntityModule.dll`. They
remain unverified. What *is* verified is that once you hold an `I_CombatActor*`,
the animation manager is at `+0x490` and the director at `+0x2E0`.

---

## 5. Phase 2.3 / Phase 3 — the pairing, and the real construction sequence

### 5.1 The pairing mechanism, fully traced

`CombatModule.dll` RVA **`0x055430`** — a member of
`C_CombatActorActionSyncAttack`, identified by its field accesses (`+0x60`,
`+0x68`, `+0x78`, `+0xA8`, `+0xB0`, `+0xB8` — exactly the SyncAttack layout) and
by being the sole non-data caller of the SyncHit factory. Reconstructed body,
**observed**:

```c
bool SyncAttack__CreateAndPairSyncHit(C_CombatActorActionSyncAttack* self)   // RCX
{
    if (self->hitDescriptor /*+0x68*/ == nullptr)
        return true;                                   // nothing to pair

    void* combat   = *(void**)((char*)self->actor /*+0x78*/ + 0x2F0);
    void* opponent = *(void**)((char*)combat + 0x1118);
    if (!opponent)
        return true;                                   // no victim -> no pair

    uint32 fA = (*(void***)((char*)combat + 0xF40))->vtbl[0x08]();   // attacker flags
    self->[+0xB8] = 1;                                 // "sync hit created"

    void*  owner  = *(void**)((char*)opponent + 0x498);
    void*  victim = *(void**)((char*)owner + 0x08);    // the victim's I_CombatActor
    uint32 fB     = (*(void***)((char*)*(void**)((char*)self->actor + 0x2F0) + 0xF40))->vtbl[0x08]();

    _smart_ptr<C_CombatActorActionSyncHit> hit;
    MakeSyncHit(&hit, victim);                          // RVA 0x088990 — allocates 0xD8

    hit->[+0x58] = self->hitDescriptor;                 // the SHARED hit descriptor
    hit->[+0x60] = (uint8)((fB >> 2) & 1);
    hit->[+0x84] = (fA & 0x80) ? 0x100u : 0u;
    hit->vtbl[0x08](hit);                               // AddRef
    hit->vtbl[0x10](hit);                               // Release

    // store into the attacker's partner slot, releasing whatever was there
    if (self->[+0xB0]) self->[+0xB0]->vtbl[0x10]();
    self->[+0xB0] = hit;                                // <-- attacker -> hit action

    if (fB & 8)
        FUN_1800DC060(*(void**)((char*)opponent + 0x2F0), 0x20);

    C_ActionDirector* dir = *(C_ActionDirector**)((char*)opponent + 0x2E0);
    hit->vtbl[0x08]();                                  // AddRef for the call
    bool ok = wh::framework::C_ActionDirector::SetAction(dir, &hit);   // imported symbol
    hit->vtbl[0x10]();                                  // Release
    if (!ok) { self->[+0xB0] = nullptr; hit->vtbl[0x10](); return false; }

    hit->[+0xD0] = self;                                // <-- hit action -> attacker

    if (**(int**)((char*)self->attackDescriptor /*+0x60*/ + 0x128) == g_someId)
        self->earlyExitHelper /*+0xA8*/ ->vtbl[0x38](self->earlyExitHelper, &nullSmartPtr);

    return true;
}
```

**This is the `m_pSyncPartner` mechanism, both ends located:**

| direction | field | kind |
|---|---|---|
| attacker → victim's hit action | `C_CombatActorActionSyncAttack + 0xB0` | owning `_smart_ptr` |
| victim's hit action → attacker | `C_CombatActorActionSyncHit + 0xD0` | raw back-pointer |

And the load-bearing detail the reference does not contain: **the hit action is
not queued by the attacker.** It is handed to the *victim's own*
`wh::framework::C_ActionDirector` (`victim's I_CombatActor + 0x2E0`) via
`C_ActionDirector::SetAction`. That director then enters it, and *its*
`EnterImpl` (`0x055710`) performs its own `QueueAction`. **The two animations
correspond because both sides are driven from the same shared hit descriptor
(`SyncAttack+0x68` → `SyncHit+0x58`) through two independent directors** — not
because one side drives the other's animation directly.

Cross-check that this reading is right: `SyncAttack::EnterImpl` uses `+0xB0` as
`partner->[+0x70]`, and `+0x70` is exactly where the SyncHit factory stores its
`I_CombatActor*`. Two independently-derived layouts agree. **Observed.**

### 5.2 The construction sequence — `C_CombatActorActionSyncAttack::EnterImpl`

RVA `0x0543D0`, with `C_CombatActorAnimatedAction<…>::Queue` inlined. This is the
WO's Phase-3 deliverable: a real, in-context call site in the game's own compiled
combat code. Annotated reconstruction, **observed** (register-level details taken
from the disassembly, not the decompiler's parameter guesses):

```c
bool C_CombatActorActionSyncAttack__EnterImpl(
        C_CombatActorActionSyncAttack* self,   // RCX
        void* enterArg)                        // RDX  (forwarded to the attack helper)
{
    trace::ScopedLog scoped(4, 0x400000, "…CombatActorActionSyncAttack.cpp", 0x89,
                            "…::EnterImpl", "%s [FrameID: %d]");

    // ---- 1. guard: an attack descriptor must exist -------------------------
    if (self->attackDescriptor /*+0x60*/ == nullptr) return false;

    // ---- 2. guard: a live opponent must exist ------------------------------
    void* combat = *(void**)((char*)self->actor /*+0x78*/ + 0x2F0);
    if (*(void**)((char*)combat + 0x1118) == nullptr) {
        trace::Write(2, …, "Sync attack action on '%s' was interrupted because of "
                           "missing opponent.");
        return false;                       // <-- no opponent, no sync attack. Hard stop.
    }

    // ---- 3. gate: a descriptor flag, or a virtual predicate ----------------
    if (!(*(uint8*)((char*)self->attackDescriptor + 0x20C)) &&
        !self->vtbl[0x120](self))
        return false;

    // ---- 4. pre-roll combat state -----------------------------------------
    FUN_1800541B0(self);                        // RVA 0x541B0: pokes combat +0xD28/+0xE28/+0xD68
    FUN_180080D40((char*)combat + 0x40, 4);

    // ---- 5. initialise the attack helper ----------------------------------
    uint32 g = (*(void***)((char*)combat + 0xF40))->vtbl[0x08]();
    // a 16-byte blob is built on the stack from a literal 0x01000001 plus (g >> 15)
    memcpy((char*)self->helperAttack /*+0xA0*/ + 0x28, blob16, 16);
    self->helperAttack->vtbl[0x38](self->helperAttack, enterArg);

    FUN_180161CF0(*(void**)((char*)self->actor + 0x300),
                  (*(uint8*)((char*)self->attackDescriptor + 0x1FC) == 0), 0,
                  self->vtbl[0x88](self));

    // ---- 6. allocate and construct the anim action -------------------------
    void* mem = g_alloc(0x1A8, &actualSize, 0);          // allocator ptr at [0x18080F930]
    C_CombatAnimAction* anim = nullptr;
    if (mem) {
        const void* desc = self->attackDescriptor;       // +0x60
        uint8 tags20[20];
        memcpy(tags20 +  0, (char*)desc + 0x24, 16);     // MOVUPS xmm0,[desc+0x24]
        memcpy(tags20 + 16, (char*)desc + 0x34,  4);
        anim = CombatAnimAction_ctor(
                   mem, mem,                              // RCX, RDX
                   self->actor,                           // R8
                   5,                                     // R9D   priority
                   *(uint32*)((char*)desc + 0x0C),         // [rsp+0x20] fragmentID
                   tags20,                                // [rsp+0x28] TagState
                   0);                                    // [rsp+0x30] flags
    }

    // ---- 7. refcounted assignment into self->+0x90 -------------------------
    if (anim != self->animAction) {
        if (anim) ++*(int*)((char*)anim + 0x58);
        C_CombatAnimAction* old = self->animAction;
        self->animAction = anim;
        if (old && --*(int*)((char*)old + 0x58) < 2) old->vtbl[0xB8](old);
    }

    // ---- 8. install the two lifecycle delegates ----------------------------
    SetAnimDelegate_120(self->animAction, bind(&Self::OnAnimFinished /*0x054F50*/, self));
    SetAnimDelegate_0A0(self->animAction, bind(&Self::OnAnimEntered  /*0x054F20*/, self));

    // ---- 9. AddRef, then the optional verbose log --------------------------
    ++*(int*)((char*)self->animAction + 0x58);
    if (g_verboseAnim)
        trace::Write(2, 0x10, "…CombatActorAnimatedAction.inl", 0x6A,
                     "…C_CombatActorAnimatedAction<…SyncAttackParams…>::Queue",
                     "Queue actor animation action: %d %s fragment ID: %d %p on actor: %s");

    // ---- 10. QUEUE ---------------------------------------------------------
    _smart_ptr<C_CombatAnimAction> sp = self->animAction;   // stack slot at [rsp+0x70]
    C_CombatAnimActionManager__QueueAction(
        *(void**)((char*)self->actor + 0x490),   // RCX  the manager, off the actor
        &sp,                                     // RDX  reference to the smart pointer
        -1.0f);                                  // XMM2 loaded from [0x180655430]

    // ---- 11. post-queue ---------------------------------------------------
    if (self->[+0xB0] /*sync partner*/) {
        /* fills a 5-field struct from combat +0x540 / +0x5C0 / +0x580 and two
           globals, then FUN_1800E4170(partner->actor[+0x4B0], &struct) */
    }
    FUN_180075330(self->actor, 1);
    if (*(int*)(*(void**)((char*)self->attackDescriptor + 0x1C0) + 8) != g_someId)
        FUN_1800E07B0(*(void**)((char*)self->actor + 0x4D0), 6);

    return true;
}
```

**The two lifecycle delegates, resolved** (observed):

| slot | target | body |
|---|---|---|
| `anim + 0x120` (installer `0x0CBAD0`) | `0x054F50` | `FUN_180054210(self)` then `wh::framework::C_ActionDirector::OnActionDone(self->[+0x48], self->vtbl[0x80](self), 2)` — the **finished** hook |
| `anim + 0x0A0` (installer `0x0CB740`) | `0x054F20` | `FUN_1800F2CE0(anim, 6)` — the **entered** hook |

### 5.2b `C_CombatAnimActionManager::QueueAction` (RVA `0x0F3C00`)

```c
void C_CombatAnimActionManager__QueueAction(
        void*  self,                                  // RCX
        _smart_ptr<C_CombatAnimAction>* sp,           // RDX  (by reference)
        float  time)                                  // XMM2
{
    void* animChar = (*(void***)((char*)*(void**)self + 0x2D8))->vtbl[0x2D0]();
    IActionController* ac = animChar->vtbl[0x130]();          // GetActionController
    if (ac && ((*sp)->[+0x28] == 0 || (*sp)->[+0x28] == 4)) {
        /* the same logging block as C_AnimationController::QueueAction:
           reads (*sp)->[+0x38] fragmentID and (*sp)->[+0x3C..+0x4C] TagState */
        ac->vtbl[0x98](ac, *sp, time);                         // Queue(IAction&, float)
    }
    // then releases sp's reference: if (--(*sp)->[+0x58] < 2) (*sp)->vtbl[0xB8]()
}
```

Note the ownership rule an implementer must respect: **`QueueAction` consumes one
reference.** The call site at `0x180054A85` does `INC.LOCK [anim+0x58]`
immediately before the call and a matching decrement immediately after; the
manager itself drops one. **Observed.**

`C_CombatActorActionSyncHit::EnterImpl` (`0x055710`) and
`C_CombatActorAnimatedAction<AttackParams,…>::Queue` (`0x044AB0`) are
instruction-for-instruction the same idiom with different constants:

| class | priority passed to the anim-action ctor | descriptor field | anim-action field |
|---|---|---|---|
| `C_CombatActorActionAttack` | **5** | `+0x60` | `+0x90` |
| `C_CombatActorActionSyncAttack` | **5** | `+0x60` | `+0x90` |
| `C_CombatActorActionSyncHit` | **7** | `+0x58` | `+0x88` |

Three independent instances of the identical construction sequence, each reading
`fragmentID` from `descriptor + 0x0C` and the 20-byte `TagState` from
`descriptor + 0x24`, all queueing with `time = -1.0f`. That triple agreement is
why §3's layout can be stated as confirmed rather than inferred.

### 5.3 The one hard dependency that constrains WO-43

`C_CombatActionHelperAttack::FillSyncHitInfo` (`0x0813F0` / `0x084470`):

```c
void FillSyncHitInfo(C_CombatActionHelperAttack* self,  // RCX
                     C_CombatAnimAction* anim,          // RDX
                     int hitIndex,                      // R8D
                     I_CombatActor* victim)             // R9
{
    *(int*)((char*)self + 0x0C) = hitIndex;
    uint8 guid[16];
    memcpy(guid, (char*)anim + 0x84, 16);              // <-- an asset GUID on the anim action
    void* meta = LookupMannequinMeta(&g_metaTable /*0x18080CC30*/, guid);
    if (!meta) {
        trace::Write(1, …, "…CombatActionHelperAttack.h", 0xF5, "…::FillSyncHitInfo",
          "Error: Meta data for asset is missing in the table. Resave mannequine "
          "database to update the table content (%s, %s, %d, GUID: %s)");
        return;
    }
    void* hitInfo = FUN_1802AA830(meta, hitIndex);
    if (!hitInfo) {
        trace::Write(1, …, line 0xFD, "Error: Cannot find hit info with index %d. "
          "Resave mannequine database to update the table content (…)");
        return;
    }
    if (!victim) return;
    /* … resolves the victim's own animation set and computes the paired hit … */
}
```

**Read this as a constraint, not trivia.** The sync-hit half of the mechanism is
driven by **metadata baked into the Mannequin database (ADB) by
`C_MannequineGenerator`** — the exported class
`??0C_MannequineGenerator@generator@combatmodule@wh@@QEAA@XZ` at CombatModule RVA
`0x2AA940` — keyed by a **16-byte asset GUID at `C_CombatAnimAction + 0x84`**.
That GUID is **not** written by the anim-action constructor (§4.2 lists every
field the constructor touches; `+0x84` is not among them); it is filled in by the
engine when the fragment resolves.

Consequence for WO-43, stated plainly: **a hand-constructed `C_CombatAnimAction`
will queue and animate, but a hand-constructed *sync pair* will only produce
correct paired timing if the fragment it resolves to carries ADB metadata the
generator already baked.** Playing an arbitrary fragment name with no such
metadata will log the "Meta data for asset is missing" error and fall through
with no hit info. This is **observed** as a code path; it is
**read-but-unrendered** as a runtime behaviour.

---

## 6. The cheapest confirmed route: the game's own `PlayAnim` test command

Separate from the combat classes, `AnimationModule.dll` contains a complete,
minimal, self-contained "build an action and queue it" sequence — a shipped test
command. It is the shortest confirmed path from *a fragment name and tag string*
to *a playing animation*, and it needs none of §4/§5.

- `AnimationModule.dll` RVA **`0x12EF20`** = `wh::animationmodule::C_PlayAnim::Execute`
- registered in RTTR as `wh::tests::PlayAnim`, described in the binary as
  `"Play given animation fragment. Stops immediately. Use just for low level testing!"`,
  parameters `"Name of an entity to be tested."` and
  `"Name of the fragment to be played in format: 'FragmentId, tag1+tag2'"`, plus
  optional `AlignEntityName` / `TagPoint1`.
- the assert string that anchors it:
  `"[Test] Check 'actor->GetAnimationController()->QueueAction(*action.get())' has failed: "`
  (RVA `0x186F60`).

### 6.1 The sequence (observed)

```c
void C_PlayAnim__Execute(C_PlayAnim* self)   // RCX
{
    // 1. name -> entity -> I_AnimatedActor
    entityId = C_EntityHelper::Resolve(self->entityName /*self+0x70*/);
    I_AnimatedActor* actor = GetGameIface()->[0x188]->vtbl[0x18](entityId);
    if (!actor) { fail("[Test] Check 'actor' has failed: "); return; }

    // 2. the actor's class / anim-database key
    void* actorClass = actor->vtbl[0x498](actor);
    if (!actorClass) { fail("… 'actorClass' … Could not get actor class"); return; }

    // 3. load the animation database
    void* x      = GetGameIface()->[0x08]->vtbl[0xB0]();
    void* y      = x->vtbl[0x18](x);
    void* animDB = y->vtbl[0x20](y, *(void**)((char*)actorClass + 0x28));
    if (!animDB) { fail("… 'animDB' … Could not load animation database"); return; }

    // 4. parse "FragmentId, tag1+tag2" -> fragmentID + 20-byte TagState
    uint32 fragmentID = 0xFFFFFFFF;
    uint8  tags20[20] = {0};
    ParseFragmentSpec(animDB, self->fragmentSpec /*self+0x78*/, &scratchString);  // RVA 0x12DB00

    // 5. allocate and construct a C_CallbackAction  (sizeof 0x268)
    void* a = alloc(0x268);                                        // RVA 0x1A410
    TAction_ctor(a, /*priority*/ 6, fragmentID, tags20,
                 /*flags*/ 0, /*arg6*/ 0, /*scopeMask*/ 0xD888);    // RVA 0x100250
    *(uint32*)((char*)a + 0x258) = 0;
    *(void**)a = C_CallbackAction::vftable;
    // zero the "callable" slot of each of the seven std::function delegates:
    *(void**)((char*)a + 0x0C8) = 0;   // delegate 1
    *(void**)((char*)a + 0x108) = 0;   // 2
    *(void**)((char*)a + 0x148) = 0;   // 3
    *(void**)((char*)a + 0x188) = 0;   // 4
    *(void**)((char*)a + 0x1C8) = 0;   // 5
    *(void**)((char*)a + 0x208) = 0;   // 6
    *(void**)((char*)a + 0x248) = 0;   // 7
    *(void**)((char*)a + 0x250) = 0;
    *(void**)((char*)a + 0x260) = 0;
    FUN_18012D830(a);                                              // RVA 0x12D830, extra init
    ++*(int*)((char*)a + 0x58);                                    // AddRef

    // 6. OPTIONAL: set a named QuatT parameter (only when AlignEntityName is given)
    //    SetParam("TargetPos", quatT)   -- see §6.3

    // 7. QUEUE
    I_AnimationController* ctrl = actor->vtbl[0x2F0](actor);        // GetAnimationController()
    bool ok = ctrl->vtbl[0x08](ctrl, a, -1.0f, false);              // QueueAction, slot [1]
    if (!ok) fail("[Test] Check 'actor->GetAnimationController()->QueueAction(*action.get())' has failed: ");

    // 8. release
    if (--*(int*)((char*)a + 0x58) < 2) a->vtbl[0xB8](a);
}
```

### 6.2 What this independently confirms

- `I_AnimatedActor::GetAnimationController()` is at **actor vtable +0x2F0**.
- `QueueAction` is **slot [1] (+0x08)** of the returned pointer — matching §2.2's
  vtable dump from a completely different direction (RTTI tables vs. this call).
- the argument shape `(action, -1.0f, false)` and the `bool` return.
- `sizeof(C_CallbackAction) = 0x268`, with **seven `std::function` delegates**
  laid out from +0x90 at 0x40 stride (callable slots at +0xC8, +0x108, +0x148,
  +0x188, +0x1C8, +0x208, +0x248) — the byte-level version of WO-40's note that
  `C_CallbackAction` carries "fragmentID +0x38, tags, priority, lifecycle
  delegates".
- **A fragment name plus tag string can be turned into `(fragmentID, TagState)`
  by the engine itself** — `AnimationModule.dll` RVA `0x12DB00`, given the
  actor's animation database. WO-43 does not have to compute Mannequin IDs by
  hand.

### 6.3 `IAction::SetParam` — the named-parameter array, byte-mapped

The optional align-target branch exposes the container at `action + 0x68`:

- entries are **0x20 bytes** each; the count lives at `array - 4`.
- entry layout: `[0x00] uint32 key`, `[0x04] float quat[4]`, `[0x14] float vec3[3]`
  — i.e. a `QuatT`.
- the key is a **CRC32 of the lowercased parameter name**; the code inlines the
  loop over `"TargetPos"` against the table at `0x1801689F0`, then stores `~crc`.
- growth is `FUN_18013F930(&action->[+0x68], newCount)` — RVA `0x13F930`.

Useful because Mannequin alignment/target parameters are exactly what a
cross-machine swing needs in order to place a hit.

### 6.4 A lead, explicitly not a claim

`C_PlayAnim` is **RTTR-registered** — the binary carries
`rttr::detail::constructor_wrapper<C_PlayAnim, …, as_std_shared_ptr, …>` for
zero-, two-, and three-`CryStringT<char>` argument forms, a `property_wrapper`
for a `CryString` member, a `destructor_wrapper`, and `type_converter`s to
`wh::tests::I_TestCommand` / `C_TestCommandBase` / `C_OneshotCommandBase`.
**Observed** in `.rdata`.

That means the same reflection surface this project already drives over
`localhost:1403` and `native/KCDMP/rttr_abi.cpp` *may* be able to construct and
run `wh::tests::PlayAnim` with no injected call at all. **This was not tested —
the game was never launched this session.** It is a concrete, cheap first probe
for WO-43 and nothing more than that until it runs.

---

## 7. Practical notes for WO-43

1. **Resolve by module + RVA.** `GetModuleHandleA("AnimationModule.dll")` /
   `"CombatModule.dll"` — both are real, separately-loaded images in this build —
   then add the RVA. Do **not** plan on `GetProcAddress` (§0).
2. **Verify before calling.** Because these are hardcoded RVAs against one local
   build, verify rather than trust. The cheapest strong check exploits §0: each
   target function contains a `LEA reg,[rel32]` pointing at its own
   `__FUNCTION__` string. For `QueueAction` that instruction sits at `fn + 0x1A9`
   (`48 8D 05 <rel32>`); resolve `fn + 0x1A9 + 7 + rel32` and `strcmp` against
   `"wh::animationmodule::C_AnimationController::QueueAction"`. A match proves
   both that the address is right *and* that it is the right function — far
   stronger than a prologue byte pattern. Prologue bytes are recorded below
   anyway, but they are generic MSVC prologues and must not be relied on alone.
3. **Get the float right.** Third argument, **XMM2**. The game passes `-1.0f`.
4. **Respect the refcount.** `action + 0x58`; `AddRef` = `vtbl[0x08]`,
   `Release` = `vtbl[0x10]`, destroy = `vtbl[0xB8]`; and
   `C_CombatAnimActionManager::QueueAction` consumes one reference.
5. **Ladder of increasing ambition** — each rung separately confirmed above:
   - **rung 0 (no injection):** try `wh::tests::PlayAnim` over the existing
     RTTR/REST surface (§6.4). Unverified, but free.
   - **rung 1:** replicate §6.1 — build a `C_CallbackAction`, parse the fragment
     spec with `0x12DB00`, queue via `actor->vtbl[0x2F0]()->vtbl[0x08]()`.
     Everything on this rung is confirmed, and the game's own code does exactly
     it.
   - **rung 2:** replicate §5.2 — a `C_CombatAnimAction` (0x1A8) built from a
     real attack descriptor and queued through the actor's own
     `C_CombatAnimActionManager` at `actor + 0x490`. Needs a valid descriptor
     pointer.
   - **rung 3:** the paired route of §5.1. Needs a live opponent
     (`actor+0x2F0 → +0x1118`), the victim's `C_ActionDirector`
     (`victim + 0x2E0`), and — per §5.3 — ADB metadata for the chosen asset.
6. **Prologue bytes** (first 24, for cross-checking that an RVA landed in a
   function at all):

```
AnimationModule.dll
 0x020410 QueueAction               40 53 41 55 41 56 41 57 48 81 EC D8 00 00 00 0F 29 B4 24 B0 00 00 00 48
 0x020150 C_AnimationController()    48 89 5C 24 08 48 89 74 24 10 57 48 83 EC 20 48 8B F9 48 8D 0D E7 08 1F
 0x100250 TAction ctor (7-arg)       48 89 5C 24 08 48 89 74 24 10 48 89 7C 24 18 41 56 48 83 EC 20 4C 8B F1
 0x12DB00 ParseFragmentSpec          48 89 5C 24 20 55 56 57 41 54 41 55 41 56 41 57 48 8B EC 48 81 EC 80 00
 0x12D830 CallbackAction extra init  48 89 5C 24 10 48 89 7C 24 18 55 48 8D AC 24 20 FF FF FF 48 81 EC E0 01
 0x12EF20 C_PlayAnim::Execute        48 8B C4 55 41 57 48 8D A8 D8 FE FF FF 48 81 EC 18 02 00 00 48 89 58 10

CombatModule.dll
 0x0F3C00 CombatAnimActionManager::QueueAction
                                     4C 8B DC 41 56 48 81 EC F0 00 00 00 48 8B 05 2D 24 65 00 48 33 C4 48 89
 0x0F26F0 C_CombatAnimAction ctor     48 89 5C 24 08 48 89 6C 24 10 48 89 74 24 18 48 89 7C 24 20 41 56 48 83
 0x10BA90 TAction ctor (6-arg)        48 89 5C 24 08 48 89 74 24 10 48 89 7C 24 18 41 56 48 83 EC 20 4C 8B F1
 0x05BDB0 MakeSyncAttack              48 89 54 24 10 55 53 56 57 41 56 41 57 48 8B EC 48 83 EC 68 4C 8B F9 49
 0x053E00 SyncAttack ctor             48 89 5C 24 18 55 56 57 41 56 41 57 48 83 EC 20 48 8B D9 48 8B F2 48 8D
 0x0543D0 SyncAttack::EnterImpl       48 89 5C 24 18 55 56 57 41 54 41 55 41 56 41 57 48 8D AC 24 20 FF FF FF
 0x055430 SyncAttack pair-the-hit     48 89 5C 24 20 57 41 56 41 57 48 83 EC 30 4C 8B F1 48 8D 0D DB 69 83 00
 0x088990 MakeSyncHit                 40 53 55 41 56 48 83 EC 30 4C 8B F1 48 8B EA 48 8D 0D 41 3C 80 00 E8 C5
 0x055710 SyncHit::EnterImpl          40 55 53 41 54 41 55 41 57 48 8D AC 24 80 FE FF FF 48 81 EC 80 02 00 00
 0x084D20 MakeAttack                  40 53 55 56 48 83 EC 30 48 8B F1 48 8B EA 48 8D 0D B2 78 80 00 E8 36 13
 0x044AB0 Attack::Queue                4C 8B DC 55 41 54 41 55 41 57 49 8D AB 28 FF FF FF 48 81 EC B8 01 00 00
 0x061470 HelperAttack ctor            48 89 5C 24 10 48 89 74 24 18 48 89 7C 24 20 41 56 48 83 EC 20 48 8B F1
```

7. **Every RVA in this document is valid only for the binaries fingerprinted in
   §1** — Modding Tools 1.5.5.0, `ReleaseSteamLTO_DLL` build 1166656_117;
   `AnimationModule.dll` 2,145,792 bytes, `CombatModule.dll` 8,928,768 bytes. If
   either file's size changes, re-run the pipeline: the scripts in
   `native/ghidra_scripts/` reproduce all of it in roughly ten minutes.

### 7.1 Reproducing the pipeline

```powershell
$env:JAVA_HOME = "C:\Program Files\Eclipse Adoptium\jdk-21.0.11.10-hotspot"
$g    = "<extracted ghidra_12.1.3_PUBLIC>"
$proj = "<a scratch directory>"
$bin  = "D:\SteamLibrary\steamapps\common\KCD2Mod\Bin\Win64ReleaseSteamLTO_DLL"

# one-time import + full auto-analysis (RTTI analyzer included)
#   AnimationModule.dll ~55 s, CombatModule.dll a few minutes
& "$g\support\analyzeHeadless.bat" $proj wo42 -import "$bin\AnimationModule.dll" `
    -analysisTimeoutPerFile 3600

# string-anchored identification: needles -> (string, referencing function, decompilation)
& "$g\support\analyzeHeadless.bat" $proj wo42 -process "AnimationModule.dll" -noanalysis `
    -scriptPath "native\ghidra_scripts" `
    -postScript DumpWo42Anchors.java "<outDir>" "QueueAction" "C_PlayAnim"
```

`DumpWo42Fns.java <out> <depth> <addr…>` decompiles addresses (optionally their
callees); `DumpWo42Asm.java <out> <addr…>` dumps raw disassembly with resolved
string/symbol comments (use this, not the decompiler, for anything ABI-shaped);
`DumpWo42Callers.java <out> <addr…>` lists callers; `DumpWo42Vtbl.java <out>
<count> <addr…>` dumps vtable slots with resolved targets.

Note for future sessions: `-analysisTimeoutPerFile` is the correct flag name;
`-analysisTimeout` is silently misparsed as another positional import path.

---

## 8. Where solid ground ends

**Confirmed by disassembly (observed):** every address, size, field offset,
vtable offset, calling convention and control-flow claim in §1–§6, plus the
pairing mechanism of §5.1 and the construction sequences of §5.2 and §6.1.
Phase 3 did not stall — a real in-context combat call site was found and fully
traced, three times over (attack, sync-attack, sync-hit), and a second, simpler,
fully-traced call site was found in the animation module.

**Read-but-unrendered (traced in code, never executed):** all of it, as runtime
behaviour. Nothing in this document has been observed running. In particular:
that a hand-built action queued this way actually *renders* a swing; that
`C_ActionDirector::SetAction` succeeds on a ghost/puppet actor rather than only
on a real brained combatant; and that a mod-supplied fragment carries the ADB
metadata §5.3 needs.

**Inferred, and flagged as such:**

- **The names of three fields.** `IAction + 0x14` and `+0x50`/`+0x54` are read as
  "a float initialised to -1.0f" and "scope mask" by analogy with public
  CryEngine Mannequin headers. The *values* and *offsets* are observed; the
  *names* are inferred, and nothing in this document depends on them.
- **`C_CombatAnimActionManager::QueueAction`'s first indirection.** The body
  reads `*(void**)self` and then `+0x2D8` off that. Whether `self` is the manager
  holding an actor pointer at offset 0, or something else, was not pinned down —
  and it does not matter, because the call site (`0x180054A79`) simply loads the
  manager from `actor + 0x490`, which *is* observed.
- **The `enterArg` parameter of `EnterImpl`** is forwarded to the attack helper's
  `vtbl[0x38]` and never otherwise examined; its type was not determined.
- **The 16-byte blob** written into `helperAttack + 0x28` in §5.2 step 5 is
  assembled from a literal `0x01000001` and a shifted flag word; the individual
  bit meanings were not decoded.

**Deliberately not attempted:** nothing was written to the game, no process was
opened, no mod code was changed, and the Mannequin database was not modified.
Licensing posture is unchanged from WO-40 Phase 1 — the community reference was
read as documentation, and every fact above was independently re-derived from
binaries this machine already owns.

---

## 9. De-risk assessment (added same session, after §8)

Two checks were run to size WO-43's risk before any code gets written. Both are
static — the game is still never launched.

### 9.1 Check 1 — the ADB metadata dependency: **not a blocker. It is shipped data, and it is complete.**

§5.3 flagged that sync-hit info depends on metadata "baked into the Mannequin
database". That framing was too pessimistic. The metadata is **not** opaque
binary inside an `.adb` — it is an ordinary Warhorse Tables XML, and the binary
names it outright. **Observed**, CombatModule string at RVA `0x5ACD00`:

> `"Warning for ViktorB: Please fill animation hit RPG for animation: %s,%s,%d (guid: %s), hit index: %d. These data can be filled in table 'combat_fragment_meta.xml'. See KCD2-A-8244."`

Backing code, all **observed**: `wh::combatmodule::C_CombatFragmentMetaDatabase`
(source `…\combatmodule\DB\Static\CombatFragmentMetaDatabase.cpp`), element type
`C_CombatFragmentMetaData` holding `std::vector<C_CombatHitInfo>`, persisted via
`wh::databasemodule::C_ObjectTreeDatabase<C_CombatFragmentMetaData, std::vector>::LoadFromXML / SaveToXML`.
The runtime table at `0x18080CC30` is populated by `FUN_1802B3720`; the lookup
`FUN_18008C810(&table, guid16)` inside `FillSyncHitInfo` reads it.

**The files, extracted and inspected from `Data\Tables.pak` (7.2 MB, 1738 entries):**

| file | size | entries |
|---|---|---|
| `Libs/Tables/combat/combat_fragment_meta.xml` | 176,009 | **766** `CombatFragmentMetaData`; 585 with at least one `CombatHitInfo`, 181 self-closing |
| `Libs/Tables/combat/combat_action_sync_attack.xml` | 812,456 | **470** rows |
| `Libs/Tables/combat/combat_action_sync_hit.xml` | 1,230,764 | **876** rows |
| `Libs/Tables/combat/combat_action_attack.xml` | 373,404 | **221** rows |
| `Libs/Tables/combat/combat_action_fragment_id_mapping.xml` | 20,855 | **114** rows |

Shape of a metadata entry, verbatim:

```xml
<CombatFragmentMetaData GUID="03f0183b-88be-3866-9fd7-22cb42a2e75b"
                        AnimDatabaseId="20967892" ObstacleTestEnabled="false">
  <CombatHitInfo BodySubpartId="55" AttackCoef="1" HandSlot="0" />
</CombatFragmentMetaData>
```

**The join coverage — the number that settles the risk:**

| descriptor table | distinct `mn_fragment_guid` | present in `combat_fragment_meta.xml` | of those, carrying `CombatHitInfo` |
|---|---|---|---|
| `combat_action_sync_attack` | 470 | **470 (100 %)** | **470 (100 %)** |
| `combat_action_attack` | 221 | 18 | 18 |
| `combat_action_sync_hit` | 876 | 107 | 0 |

**Every shipped sync-attack has its metadata row, and every one of those rows
carries hit info.** The asymmetry is exactly what the code predicts:
`FillSyncHitInfo` is a method of `C_CombatActionHelperAttack`, which lives on the
**attacker** (`SyncAttack+0xA0`, `Attack+0xB0`), so it looks up the *attacker's*
anim-action GUID. Victim-side (`sync_hit`) rows have no reason to be in the table
and mostly are not; unpaired `combat_action_attack` rows likewise.

**Verdict: rung 3 is not data-blocked for any attack the game itself ships.** It
would be blocked only for a *new* fragment a mod authored, which needs a row
added to `combat_fragment_meta.xml` — an ordinary, moddable Tables edit, not a
database resave. §5.3's warning stands only for that case, and should be read
with this section.

### 9.2 The unexpected payoff — the descriptors are shipped, readable data

Worth more to WO-43 than the risk answer itself. What
`SyncAttack + 0x60` / `+ 0x68` point at is a row of these tables, and every row
carries its Mannequin coordinates **in exactly the format `ParseFragmentSpec` —
and therefore `wh::tests::PlayAnim` — already accepts.** A real human
sync-attack row, verbatim:

```
mn_fragment_id          = "CombatAttackSyncGen"
mn_tags                 = "l_halberd+r_halberd+clinch1+eZ1+aZ2+attack_special+oppMale"
mn_fragment_guid        = "bc5d77a5-c2e9-3fdc-9da7-6063a3501379"
mn_option_index         = "0"
actor_class_hash        = "1578932418"      (the human class)
opp_actor_classes       = "NPC"
animation_duration      = "2.166667"
attack_time_to_start    = "0.3"
attack_time_to_hit      = "0.666667"
attack_time_to_withdraw = "1.023994"
attack_time_to_end      = "2.166667"
anim_hit_count          = "1"
attacking_hand          = "0"
r_weapon_class_id       = "7"
init_align0/1, init_sec_align0/1  = QuatT alignment pairs
```

`mn_fragment_id` plus `mn_tags` **is** the `'FragmentId, tag1+tag2'` string. So
**rung 1 can play the game's real combat swings with the game's real tags**, read
straight out of `Tables.pak`, without constructing a single combat class. That
collapses most of rung 2's value into rung 1. The per-row timings
(`attack_time_to_hit`, `animation_duration`) are also exactly what a wire
protocol needs in order to schedule a remote swing.

Fragment vocabulary actually shipped (human class `1578932418`; counts are rows):

| table | top `mn_fragment_id` values |
|---|---|
| `sync_attack` | `CombatAttackComboGen` 158, `CombatAttackComboDeathGen` 82, `CombatStopMaster` 75, `CombatStealthAttackSuccess` 50, `CombatAttackSyncGen` 33, `CombatRiposteSyncGen` 23, `HorseCombatAttackSync` / `HorseCombatAttackSyncFail` 14 each |
| `sync_hit` | `CombatHitComboGen` 232, `CombatHitComboDeathGen` 232, `CombatStopSlave` 99, `CombatHitSyncGen` 93, `CombatStopDeathSlave` 78, `CombatStealthHitSuccess` 51, `CombatHitSyncDeathGen` 34 |
| `attack` (unpaired) | `CombatAttackSpecialGen` 84, `FreeAttack` 50, `CombatAttackGen` 41, `CombatAttackRiposteGen` 24, `CombatAttackMercy` 17 |

Class hashes: **`1578932418` = human** (451 of 470 sync-attacks, 822 of 876
sync-hits, 719 of 766 metadata rows); `20967892` = Dog; `1008263269` and
`474619276` are two further small sets. `AnimDatabaseId` in the metadata table and
`actor_class_hash` in the descriptor tables are the same identifier space —
**observed**: the Dog rows carry `actor_class_hash="20967892"` and their metadata
rows carry `AnimDatabaseId="20967892"`.

`combat_action_fragment_id_mapping.xml` additionally maps `action_type_id` to
`fragment_id` (114 rows, e.g. `0 → CombatHitMovement`, `3 → CombatAttack`), with a
`sync_hit` boolean per row.

### 9.3 Check 2 — the entity → `I_CombatActor*` path: partly answered, one hop still open

`EntityModule.dll` is far richer in exports than the animation and combat
modules: **827 export lines**, including a usable entry chain (**observed**):

| export | RVA | note |
|---|---|---|
| `?m_Instance@C_EntityModule@entitymodule@wh@@0PEAV123@EA` | `0x12E5B10` | **the singleton pointer itself is exported** — `C_EntityModule* m = *(C_EntityModule**)(base + 0x12E5B10)` |
| `?I@C_EntityModule@entitymodule@wh@@…` | — | the singleton accessor |
| `?GetPlayerActor@C_EntityModule@entitymodule@wh@@UEBAPEAVC_Actor@23@XZ` | `0x71B330` | `C_Actor* GetPlayerActor() const` |
| `?GetPlayer@…`, `?GetScriptBindHuman@…`, `?GetScriptBindActor@…` plus ~120 further `C_EntityModule` getters | — | all name-resolvable |

**But `C_Actor` itself exports zero members.** So the last hop —
`C_Actor` → `I_CombatActor*` — is not name-resolvable, and WO-41's
`C_Actor::m_pCombatActor @ +0x278` (a libKCD2 claim) remains **unverified**.

The anchor that settles it is located: **`wh::entitymodule::C_Actor::InitCombatActor`,
`__FUNCTION__` string at EntityModule RVA `0xD43A30`** — the function that creates
and stores the combat actor will show the real member offset. `EntityModule.dll`
(20 MB) was still auto-analysing when this section was written; finishing it is
the same one-command pipeline as §7.1. **This is the one open item, and it is a
ten-minute job, not a research risk.**

Two further leads found in `EntityModule.dll` while looking — both **observed**
(string/RTTI anchored), neither followed yet:

- **`PlayAnim`** as a plain Lua method-name string at RVA `0xE9FB98`, adjacent to
  `wh::entitymodule::C_ScriptBindHuman::SetAnimMotionParam` at `0xE9FE40`, i.e.
  inside the `C_ScriptBindHuman` registration block. Its xref leads to the native
  implementation of `human:PlayAnim(fragment, tags)` — the call WO-40 already
  proved **renders** a Mannequin fragment on a ghost. Reading it yields the game's
  own entity→animation-controller walk *and* how it turns a tags string into a
  `TagState`, from a class reachable through an exported getter
  (`GetScriptBindHuman`). Probably the highest-value remaining read.
- **`C_ActorActionCombat`** (EntityModule) carries pointer-to-member types
  `void (C_ActorActionCombat::*)(I_CombatActor&, const int&, const _smart_ptr<I_CombatActorAction>&)`
  and `(I_CombatActor&, E_CombatActorStateId::Type, …)`, mirroring the descriptors
  on `C_CombatActorActionAttack` in CombatModule. That makes it the **bridge that
  accepts an already-constructed `I_CombatActorAction`** — a higher-level
  insertion point than queueing the anim action directly.

### 9.4 Revised risk picture for WO-43

| rung | risk before this assessment | after |
|---|---|---|
| 0 — RTTR `wh::tests::PlayAnim` | unknown | unchanged: free to try, needs the game running |
| 1 — build `C_CallbackAction`, queue it | low | **lower, and much more valuable** — §9.2 supplies the real combat fragment IDs and tag strings, so rung 1 can render actual swings rather than placeholders |
| 2 — `C_CombatAnimAction` via the actor's manager | "needs a valid descriptor pointer" | descriptors are **shipped, enumerable XML** (§9.2); the remaining unknown is only the runtime pointer to a loaded row |
| 3 — the paired sync route | thought to be data-gated | **not data-gated** for shipped attacks (§9.1); the real remaining gates are a live opponent, the victim's `C_ActionDirector`, and whether `SetAction` accepts a ghost/puppet actor |
| all rungs | needed a verified entity→`I_CombatActor*` path | **one open hop** (`C_Actor` → combat actor), anchor located at EntityModule `0xD43A30` |
