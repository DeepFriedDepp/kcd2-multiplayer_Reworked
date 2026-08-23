# WO-41 progress (live — updated as work proceeds)

Worked 2026-08-21. Combat-swing fidelity first (native), then Phases 2–11
verification. This file is updated incrementally as crash insurance.

## Environment confirmed (before Phase 1)

- Game not running at session start; save declared disposable by the human.
- **Two installs on D:\SteamLibrary\steamapps\common\**:
  - `KCD2Mod` (Modding Tools) — `KingdomCome.exe` **1.5.5.0**, non-monolithic:
    40+ module DLLs (CombatModule 8.5MB, AnimationModule 2MB, EntityModule 20MB,
    RPGModule 18MB, XGenAIModule 49MB, CrySystem 6.5MB…). **This is the injection
    target** (LAUNCHING.md: mod runs here).
  - `KingdomComeDeliverance2` (retail) — `KingdomCome.exe` **1.5.6.0**, monolithic
    `WHGame.dll` 89MB.
- Native DLL (`native/KCDMP.dll`) already builds; RTTR ABI layer
  (`rttr_abi.{h,cpp}`), main-thread marshalling, named-pipe channel all present
  and proven from prior WOs.

## Phase 1 — combat-swing fidelity (IN PROGRESS)

### Step 1 (version match) — ANSWERED, and it is a mismatch that matters

**libKCD2's addresses are pinned to retail WHGame.dll 1.5.6 (`kd7u`), monolithic,
base 0x180000000.** Every RVA in its headers/`REL::ID` map is an absolute VA
inside that single DLL (e.g. `GetOrCreateCombatActor` = `sub_18072DC90`).

This project injects into the **Modding Tools 1.5.5 build, which is
non-monolithic** — the same code is split across separate module DLLs, each with
its own base. So:

- **libKCD2's raw addresses are NOT directly usable here** — different version
  (1.5.5 vs 1.5.6) AND different module layout (per-DLL bases, not one WHGame).
  This is exactly the "confirm the build matches before trusting any address"
  check the WO demanded first. It does not match.
- **What DOES transfer**: libKCD2's *structural map* — class layouts, vtable slot
  numbers, method signatures, field offsets, inheritance spines. Those are
  version-robust to a point and are the real value of the repo.
- **The transfer lever unique to this project** (NATIVE-PLUGIN-findings §1): the
  Modding Tools DLLs **export mangled C++ symbols**. So where libKCD2 names a
  method, this project can `GetProcAddress` the actual address from the owning
  module DLL — strictly better than retail's address-library approach, and
  version-proof because it resolves by name at load time.

### Exported anchors CONFIRMED present in Modding Tools DLLs (dumpbin)

- `C_EntityModule::I()` (singleton) and `C_EntityModule::GetPlayerActor()`
  → `C_Actor*`, `GetPlayer()` → `C_Player*` — **EntityModule.dll, exported**.
  A direct, name-resolved route to the local player's actor with no gEnv walk.
- `C_GameInterface::GetInstance/GetWritableInstance` — Shared.dll (already used).
- Structural (from libKCD2, layouts to trust): `C_Actor::m_pCombatActor` @ +0x278;
  `C_CombatActor::m_pActionManager` @ +0x3A8; action manager's
  `m_pAttackFactory` @ +0x50; `I_AnimationController::QueueAction` = vtable
  slot [1] `QueueAction(IAction&, float time, bool restartInstalled)`.

### The real difficulty, stated honestly (matches WO's recalibration)

The combat-attack construction path (`C_CombatActorActionAttack`, 0xB0, +
helper sub-objects) is built by **free dispatch functions that are NOT exported**
(`sub_18164ED68` build/enumerate/create; factory `sub_18091590C`). On retail
libKCD2 reaches them via its address library; here those addresses don't exist
(wrong version, wrong module) and the functions aren't exported — so reaching
them means **disassembling CombatModule.dll to re-derive the equivalents**, the
"same disassembly discipline as the SetParent fix" the WO explicitly flags as its
own task.

Two candidate routes under evaluation:
1. **Animation QueueAction route** (simpler action object): reach the actor's
   animation action controller and queue a Mannequin fragment action. WO-40
   already proved `human:PlayAnim('MotionJump')` RENDERS a Mannequin fragment on
   a ghost — so the fragment-action machinery works; the open question is
   reaching a *combat* fragment/context.
2. **Combat-action route** (sync-paired `C_CombatActorActionSyncAttack`): the WO's
   preferred prize but requires the non-exported factory dispatch — the larger RE
   lift.

NEXT: investigate the animation-controller route and the ScriptBindHuman/PlayAnim
underlying bind, since a fragment action already provably renders.
