# WO-72 findings — a GPU-less KCD2 host

Session 2026-08-28, continuing straight from WO-71. Evidence classes as WO-71:
**observed** (a live run), **code-verified** (decompiler/disassembler on our
Modding Tools binaries, with address), **inferred** (flagged every time).

Two routes to a host with no GPU were pursued. **One of them works today.**

---

## 1. Headline — CPU-only rendering works, with two shipped cvars and no code

KCD2 boots to `Entering game loop` on **WARP**, Microsoft's CPU software
rasteriser, with **no GPU used at all**. No patch, no null renderer, no
modified game file.

The whole thing rests on something the shipped build already prints. On this
machine `kcd.log` enumerates two adapters (**observed**):

```
- AMD Radeon RX 6700 XT (vendor = 0x1002, device = 0x73df)
    - Adapter index: 0
    - Feature level: D3D 12_1 (SM 6.0)
    - Displays connected: yes
    - Suitable rendering device: yes
- Microsoft Basic Render Driver (vendor = 0x1414, device = 0x008c)
    - Adapter index: 1
    - Dedicated video memory: 0 MB
    - Feature level: D3D 12_1 (SM 6.0)
    - Displays connected: no
    - Suitable rendering device: no
```

"Microsoft Basic Render Driver" **is** WARP. Two things matter:

- it already reports **feature level 12_1**, which satisfies KCD2's own gate
  ("A GPU with support for D3D FeatureLevel 12.0 is required", WO-71 §5); and
- it is rejected **only** for `Displays connected: no` — which is exactly what
  `r_HeadlessStartup` was written to override ("Allow creating the render
  device without any connected monitors", WO-71 §8).

Set those two cvars and the device is created on the software adapter
(**observed**):

```
Creating rendering device...
D3D Adapter: Description:
D3D Adapter: VendorId = 0x0000
D3D Adapter: DeviceId = 0x0000
 Feature level: D3D 12_1
...
Entering game loop                       (kcd.log line 2451)
```

`VendorId = 0x0000` is the software adapter. The process then sat in its main
loop indefinitely, logging normally.

### Measured cost (observed)

Idle in the game loop, full **1920×1080** software rasterisation, on a 12-thread
Ryzen 5 5600:

| | |
|---|---|
| CPU | 35.5 CPU-seconds over 30 s wall = **~1.2 cores**, ~10% of a 12-thread box |
| RAM | **2.7 GB** working set |
| threads | 98 |

For a multi-Xeon VM that is a comfortable per-instance budget, and it is an
upper bound: nothing was done to shrink the render target, and a host has no
reason to rasterise 1080p.

### The trap: `+cvar` on the command line is too late

`KingdomCome.exe … +r_HeadlessStartup 1 +r_overrideDXGIAdapter 1` **does not
work**. The log shows the value stored and ignored:

```
r_HeadlessStartup = 1 [DUMPTODISK, REQUIRE_APP_RESTART]
```
…and the device still comes up on the AMD GPU.

This is the same behaviour WO-53 §2.2 hit with `+r_Driver NULL` and read as a
property of that cvar. It is not — it is general: **CryEngine applies `+`
command-line cvars late in `CSystem::Init`, after renderer init has already
read them.** WO-53's conclusion about `r_Driver` stands; the reason generalises.

The value must therefore be in place *before* renderer init. Two mechanisms:

1. **`system.cfg`** — read early in `CSystem::Init`, well before `InitRenderer`.
   This is the shipped, supported mechanism, and the engine's own `r_Driver`
   help text points at it: *"Specify in system.cfg like this: r_Driver =
   "DX11""*. This is the right production answer for a VM. **Inferred, not
   tested here** — deliberately, because it means editing a file in the game
   install and nothing in WO-71/72 has touched the install.
2. **Setting the cvar as soon as it is registered**, from injected code. This is
   what the WO-72 probe does (`KCDMP_WO72_EARLY_CVARS`), and it is how the
   result above was obtained without editing anything.

### What this does *not* establish

- **Not tested on an actual GPU-less VM.** This box has a GPU; WARP was
  selected by index. On a machine with no GPU the Basic Render Driver should be
  the only adapter and therefore index 0, so `r_HeadlessStartup=1` alone would
  likely suffice — **inferred**. The device did come up on an adapter reporting
  `Displays connected: no`, which is the substance of the headless case.
- **No world was loaded.** The measurement is the main loop with no save
  loaded. Whether simulation keeps up on WARP, and what a loaded world costs,
  is unmeasured.
- `r_HeadlessStartup` and `r_overrideDXGIAdapter` are `DUMPTODISK`. Every run
  here was hard-killed before clean shutdown and the install verified
  afterwards: `system.cfg` untouched, no `user.cfg`, nothing under
  `Saved Games\kingdomcome2`. **Do not let a run with
  `r_overrideDXGIAdapter` set exit cleanly on a machine you also game on** — a
  persisted adapter override would force the software renderer for normal play.

---

## 2. The other route — no renderer at all (`-dedicated`)

WO-71 ended at tier 2: the `-dedicated` branch fires, and `CryAnimation` fatals
on a null `IRenderer`. WO-72 pushed that from ~440 lines of `kcd.log` to
**~1800**, through every engine subsystem, all 18 game modules, AI init and
into Lua entity registration. Three blockers cleared, one open. Full detail in
`docs/WO-72-progress.md`; the load-bearing points:

| # | blocker | resolution |
|---|---|---|
| 1 | `CryAnimation` null `IRenderer` (`+0xAF900`) | any non-null object at `gEnv+0x108` |
| 2 | null `ICVar` deref, `CrySystem +0x8F5D6` — the `r_SuperResolution_*` family is registered *by the renderer* | register seven stand-ins via `gEnv->pConsole` |
| 3 | `GetGameIface()+0x1A0` (= `IAISystem`) null | **`sv_AISystem = 1`** — a *shipped* cvar; `CSystem::Init`'s AI condition passes when it is non-zero even under `bDedicated` |
| 4 | `Cry3DEngine FUN_1801317a0` writes `+0x240` and CryString-assigns `+0x250` into the result of `EF_CreateInputShaderResource`, unchecked | **open** |

Blocker 3 is worth calling out on its own: **KCD2's engine already supports
running the AI system on a dedicated server**, gated behind `sv_AISystem`. That
was not previously known.

### Why blocker 4 is structural

A stub cannot satisfy it. Returning null faults on the unchecked write to
`+0x240`; returning a zero-filled block faults reading `ptr-12`, the
`CryString` `{refcount,len,capacity}` header, because the string member inside
our block was never *constructed*. Returning a valid object from all 1024
slots, a 64 KB object, and a distinct 4 KB block per call from a 32 MB arena
all land on the identical fault.

### A real renderer without a device — promising, same tail

`CD3D9Renderer` is a **static object inside `CryRenderD3D12.dll`**
(image+0x76B200 — the MODE=scan run found `gEnv->pRenderer` pointing into the
DLL's own data, not the heap). `LoadLibrary` on the renderer runs its static
constructors, and the probe confirmed the object's vptr matches
`image+0x50F5D0` exactly: **CONSTRUCTED** (**observed**). So a genuinely
constructed renderer is available for free, and `Init()` — which creates the
window and device — can simply never be called.

That is structurally the right answer to blocker 4, and it moved the boot
along, but it trades one tail for another: the object's *internal* subsystems
are still uninitialised, because `Init()` is what sets them up. First fault
that way is `CBaseResource::GetResource` (`CryRenderD3D12 +0x283E7`) on a null
resource map. Each subsequent fault is another subsystem `Init()` would have
built.

**Verdict on this route:** viable but open-ended, and now clearly the *more
expensive* of the two.

---

## 3. Verdict

> **A GPU-less KCD2 host is achievable today, and does not require the null
> renderer.** Forcing the shipped renderer onto the WARP software adapter —
> `r_HeadlessStartup=1` plus, on a machine that also has a GPU,
> `r_overrideDXGIAdapter=<software adapter index>` — boots KCD2 to
> `Entering game loop` with no GPU, at ~1.2 cores and 2.7 GB idle. The only
> catch is that the cvars must be applied before renderer init, which
> `system.cfg` does and a `+cvar` command-line argument does not.
>
> The renderer-less (`-dedicated`) route is further along than WO-71 left it —
> three blockers cleared, one of them via the previously-unknown shipped
> `sv_AISystem` cvar — but its remaining blocker is structural and it is now
> the costlier path.

## 4. What a decision session would weigh

*(Considerations, not a recommendation.)* Whether ~1.2 cores and 2.7 GB per
instance at idle is acceptable per hosted session, and what those numbers become
with a world loaded and a render target smaller than 1080p — both unmeasured.
Whether the target VM enumerates the Basic Render Driver at all (it should; that
wants confirming on the actual machine before anything is built on it). Whether
`system.cfg` is an acceptable install change for a host deployment, given
nothing else in this project modifies the install. Whether a WARP host still
needs the `-dedicated` niceties it cannot have — no input, no audio, no window
— or whether a normal boot with a hidden window is fine. And, unchanged from
WO-71 §12: whether a host that needs the **Modding Tools** build rather than
retail is an acceptable deployment requirement, and how any of this interacts
with WO-51's proximity-gated AI and WO-60's claim/hold design.
