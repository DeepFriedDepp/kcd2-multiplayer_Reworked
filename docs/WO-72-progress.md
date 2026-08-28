# WO-72 progress — headless bring-up

Opened 2026-08-28, directly after WO-71 closed. WO-71 was findings-only and
fenced off topology and implementation; the human then asked to carry on and
get a headless boot working, so this is its own work item.

**Status: in progress.** Three blockers found, two cleared, boot depth roughly
quadrupled. Everything here is experiment code under
`native/experiments/wo72_nullrenderer/` — **no product code changed**, nothing
installs it, and no file in the game install was edited at any point.

## Where WO-71 left it

`-dedicated` skips renderer module loading and device/window creation cleanly
(`gEnv->bDedicated`, `gEnv+0x3d4`), then dies at `CryAnimation`'s
character-manager init on an unconditional
`if (!pSystem->GetIRenderer()) CryFatalError(...)`. The open question was how
many *more* consumers sit behind that one.

## Method

A throwaway probe DLL, injected with the project's existing
`KCDMP_LauncherInjector.exe`, in two modes:

- **`MODE=scan`** — passive, on a *normal* boot. Walks `gEnv` for the slot
  holding an object whose vtable lives inside `CryRenderD3D12.dll`, and
  censuses every `gEnv` pointer slot with its owning module.
- **`MODE=stub`** — active, on a `-dedicated` boot. Installs a stub
  `IRenderer` whose 1024 vtable slots are each a distinct logging thunk, so the
  log names every renderer method a headless boot actually calls, in order.

Plus a vectored exception handler that reports the faulting address as
module+RVA, the register state, the last 32 stub slots called, and a scan of
the raw stack for candidate return addresses.

The accelerator that makes this tractable: **`CryRenderD3D12.dll` exports its
C++ symbols**, so the renderer vtable at RVA `0x50F5D0` resolves to real method
names in Ghidra. Slot indices from the probe become method names for free.

## Results so far

### Settled: `gEnv+0x108` is `pRenderer` (observed)

The static route was ambiguous — Ghidra's vtable dumps for `CSystem` are
unreliable here (they run into the next table's RTTI meta pointer), leaving two
candidate offsets. `MODE=scan` settled it on a live process: `gEnv+0x108` holds
an object whose vtable is inside `CryRenderD3D12.dll`. `gEnv+0x110` holds a
second renderer-owned object (heap-allocated, renderer vtable).

### Blocker 1 — `CryAnimation` null `IRenderer` — CLEARED

Any non-null object at `gEnv+0x108` satisfies it. Installing the stub gets past
`CryAnimation.dll +0xAF900`.

### Blocker 2 — null `ICVar` in the spec auto-detect — CLEARED

`CrySystem.dll` `FUN_18008f400` (the `sys_auto_detect_spec_override` /
super-resolution path) caches `ICVar*` lookups once and then calls `Set()` on
them unconditionally. The `r_SuperResolution_*` cvars are registered **by the
renderer module**, so with no renderer they never exist, the cache holds null,
and it derefs — access violation at `CrySystem.dll +0x8F5D6`.

This is the upscaler landmine the FIKA developer warned about, arriving as a
missing cvar rather than a missing DLL. Note it is *not* avoidable by passing
`+r_SuperResolution_Mode 0`: the cvar does not exist to be set.

Cleared by registering seven stand-in cvars through `gEnv->pConsole`
(`IConsole::RegisterInt` at vtbl `+0x18`, `RegisterFloat` at `+0x28`,
`GetCVar` at `+0xb8`) before the cache is primed.

### Depth reached with blockers 1 and 2 cleared

`kcd.log` now gets through, with **no renderer, no device and no window**:

```
Renderer initialization      (enters InitRenderer, loads nothing)
Font initialization
Network initialization
Lobby initialization
MovieSystem initialization
Console initialization
Time initialization
Initializing Animation System
Init 3D Engine  ->  Initializing module Cry3DEngine done, MemUsage=12204Kb
Script System Initialization
Entity system initialization
LiveCreate initialization
Dynamic Response System initialization
   ... then Warhorse game-module data load (AI brain/subbrain tables)
```

That is past the whole CryEngine layer and into
`wh::game::C_GameStartup::InitInternal`.

### The IRenderer methods a headless boot actually calls (observed, named)

| order | slot | vtbl | method |
|---|---|---|---|
| 1 | 338 | +0xA90 | `EF_QueryImpl` |
| 2 | 59 | +0x1D8 | `TryFlush` |
| 3 | 5 | +0x028 | `PostInit` |
| 4 | 154 | +0x4D0 | `EF_RefreshTextures` |
| 5 | 310 | +0x9B0 | `ClearPerFrameData` |
| 6 | 1 | +0x008 | (slot 1) |
| 7 | 179 | +0x598 | `EF_SetPostEffectParam` |
| 8 | 157 | +0x4E8 | `EF_LoadTexture` — ~900 calls |
| 9 | 48 | +0x180 | `GetRefreshRateFromOutput` |
| 10 | 64 | +0x200 | `GetGammaDelta` |

Ten methods, out of a 420-slot vtable, to get this far. That is the concrete
size of the "stub `IRenderer`" job up to this point — far smaller than the
whole interface.

### Blocker 3 — OPEN

Access violation in `XGenAIModule.dll +0x13CB030`, reading address 0 with
`RCX = 0` — a virtual call on a null `this`. Reached via
`KingdomCome.exe` → `C_GameStartup::InitInternal` (`WHGame.dll +0x16A395`) →
`Framework.dll +0x4EBAC` (module manager) → `WHGame.dll +0x15A4D0 / +0x13FF00`
→ XGenAIModule init.

Ruled out by experiment, not by reasoning:

- **Not an `IRenderer` return value.** Making *every* stub slot return a valid
  object instead of null (`RETURN_SELF=all`) reproduces the identical fault.
- **Not a missing `gEnv` pointer.** A full `gEnv` slot census in both
  configurations, taken at a comparable point, differs in exactly three slots:
  `+0x110` (renderer-owned), `+0x168` (CrySystem-owned), `+0x170`
  (`CryAudioImplFmod.dll`-owned — the FMOD implementation, absent because the
  dedicated path installs `CNULLAudioSystem`). Stubbing all three reproduces
  the identical fault.

So the null is internal to the Warhorse game-module stack. Naming it needs
`XGenAIModule.dll` (51 MB) analysed in Ghidra — running at time of writing.

## Traps

- MSVC cannot parse a 1024-wide fold expression (`fatal error C1026: parser
  stack overflow`); a log-depth binary-tree template does the same job.
- `fopen` locks the log against readers for the whole run. `_fsopen(..., "w",
  _SH_DENYWR)` is required to tail it live.
- The stack scan reports allocator frames (`CryMalloc`, `CryFree`) as plausible
  callers. They are false positives — read the chain, not the innermost line.
- `-noCrashHandler` suppresses the BugSplat dialog, which makes iteration much
  faster. No crash report from any of these runs was sent.

---

## Continued 2026-08-28 — blocker 3 cleared, blocker 4 named, stubbing exhausted

### Blocker 3 — the AI system — CLEARED, and by a *shipped* switch

The `XGenAIModule` fault decoded from the raw PE bytes (faster than waiting for
a 51 MB Ghidra pass):

```
call qword ptr [rip+0xD8361F]   ; Shared.dll!wh::GetGameIface()
mov  rcx, [rax+0x1A0]           ; RCX = gameIface->field_0x1A0   <-- NULL
mov  rax, [rcx]                 ; FAULT (XGenAIModule +0x13CB030)
call qword ptr [rax+0x128]
```

A census of `wh::GetGameIface()` in both configurations, phase-matched, names
the field: **`GI+0x1A0` is `IAISystem`** (vtable in `CryAISystem.dll`).

WO-71 §5 had already recorded that `CSystem::Init`'s AI condition gains a
`gEnv->bDedicated` term. The rest of that condition is the escape hatch — it
also passes when the shipped cvar **`sv_AISystem`** is non-zero. So KCD2's
engine *does* have a supported way to run the AI system on a dedicated server.

`+sv_AISystem 1` on the command line is **too late**: AI init is
`SystemInit.cpp:0xec8`, which runs before `CryAnimation` loads. Setting it from
the probe as soon as `gEnv->pConsole` exists works — log shows
`sv_AISystem: was 0, now 1`, and `AI initialization` then appears in `kcd.log`.

### Depth now reached (observed)

With blockers 1–3 cleared, and still **no renderer, no device, no window**:

- every engine subsystem, `Cry3DEngine` included;
- **all 18 game modules** created — `TestModule`, `UtilsModule`,
  `DatabaseModule`, `AnimationModule`, `EntityModule`, `CombatModule`,
  `DialogModule`, `SoundModule`, `MusicModule`, `EnvironmentModule`,
  `RPGModule`, `PlayerModule`, `ShopModule`, `QuestModule`, `GUIModule`,
  `XBehaviorModule`, `XGenAIModule`, `ConceptModule`;
- `AI initialization`;
- and on into **Lua entity-script registration**
  (`Scripts/Entities/...` — hundreds of files).

`kcd.log` goes from ~440 lines at WO-71's CryAnimation death to **~1800 lines**.

Worth noting for the mod specifically: `GUIModule` loads and logs
`UISetting uses undefined CVar: r_VSync / r_MotionBlur / r_HDROutput / ...` —
errors, not fatals. The UI layer survives a renderer-less boot, complaining.

### Blocker 4 — OPEN, and it is where stubbing stops working

`Cry3DEngine.dll FUN_1801317a0` (the default-material path, the function
holding `"%ENGINE%/EngineAssets/TextureMsg/ReplaceMe.tif"`):

```c
plVar2 = pRenderer->vtbl[+0x590](pRenderer, 0);   // EF_CreateInputShaderResource
if (plVar2 != NULL) { plVar2->AddRef(); }         // null-checked...
*(float*)(plVar2 + 0x240) = 1.0f;                 // ...but this is NOT
...
FUN_180026910(plVar2 + 0x250, "%ENGINE%/.../ReplaceMe.tif", 0x2e);  // CryString assign
```

Two distinct faults, both from the same cause:

- returning **null** → `WRITE` to address `0x240` (`Cry3DEngine +0x131872`);
- returning a **zero-filled stub** → `READ` of `0xFFFFFFFFFFFFFFF4`
  (`Cry3DEngine +0x26937`, `FUN_180026910`): that is a `CryString` assign
  reading its destination's `{refcount,len,capacity}` header at `ptr-12`, and
  the destination `CryString` inside our block is zeroed rather than
  constructed.

This is the wall. Tried and did not move it: returning a valid object from
**every** one of the 1024 slots; enlarging the stub object to 64 KB so field
writes are absorbed; handing out a **distinct** 4 KB zeroed block per call from
a 32 MB arena (so unrelated objects stop aliasing). All three land on the same
fault.

The reason is structural, not a missing offset: `EF_CreateInputShaderResource`
must return a **properly constructed** `SInputShaderResources` — C++ members,
including `CryString`s pointing at the empty-string singleton. A zero-filled
buffer cannot fake a constructed object, and no amount of stub geometry will.

### Where that leaves it

- The **engine** half of a headless boot is done and needs nothing new: the
  branch works, and the three things blocking it were one null check, seven
  cvars and one shipped cvar.
- The **renderer-substitute** half now begins in earnest, and is exactly the
  project WO-53 §2.3 described. It is no longer open-ended, though: init needs
  ten named `IRenderer` methods (progress table above), and the first one
  needing *real* behaviour rather than a stub is
  `EF_CreateInputShaderResource` (vtable slot 178, `+0x590`).
- Nothing here is product code, nothing is installed, and no file in the game
  install was modified in any run.

---

## Continued — the CPU-only route, and a real renderer without a device

See `docs/WO-72-findings.md` for the verdict. Summary of what was added here:

- **`MODE=warp`** — IAT-patches `CryRenderD3D12`'s statically-imported
  `CreateDXGIFactory1` (IAT RVA `0x4B0FB8`) and swaps
  `IDXGIFactory1::EnumAdapters1` (vtable slot 12) so the renderer can only see
  the WARP adapter. Built to prove the CPU-only route on a box that *has* a
  GPU. In the end it was not needed: the shipped cvars do the job.
- **`KCDMP_WO72_EARLY_CVARS="name=value,..."`** — generalised from the
  `sv_AISystem` fix. Sets cvars the moment they are registered, which is the
  only way to beat renderer init; `+cvar` on the command line is applied too
  late (see findings §1).
- **`KCDMP_WO72_REAL_RENDERER=1` / `KCDMP_WO72_NEUTER="<slots>"`** — installs
  the real static `CD3D9Renderer` from `CryRenderD3D12.dll` (confirmed
  CONSTRUCTED by static init) as `gEnv->pRenderer`, with a *copy* of its vtable
  so chosen slots can be replaced by logging thunks. Slot 4 (`Init`) is always
  neutered, since that is what creates the window and device.

### Fault-to-slot workflow that made iteration fast

1. VEH logs the fault as `module +RVA`, the registers, and a raw-stack scan.
2. For a fault inside `CryRenderD3D12`, look the RVA up in the vtable dump —
   the largest slot entry at or below it names the method (`+0x2F079D` →
   `TryFlush`). Only valid when the faulting function *is* a vtable target;
   otherwise name it in Ghidra (`+0x283E7` → `CBaseResource::GetResource`).
3. Add the slot to `KCDMP_WO72_NEUTER`, rerun.

### Further traps

- `+cvar` command-line arguments are applied after renderer init. WO-53 read
  this as a property of `r_Driver`; it is general.
- `r_HeadlessStartup` and `r_overrideDXGIAdapter` are `DUMPTODISK`. Hard-kill
  before clean shutdown and verify the install afterwards, or a persisted
  adapter override will force software rendering for normal play. Every run in
  this WO was killed and verified; `system.cfg` is untouched and no `user.cfg`
  exists.
- The VEH logs first-chance exceptions, including benign C++ throws
  (`0xE06D7363`) raised inside `D3D12Core.dll` during normal WARP device setup.
  A logged exception is not necessarily fatal — check whether the process is
  still alive before chasing it.
