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
