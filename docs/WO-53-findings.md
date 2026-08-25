# WO-53 — the Mannequin source as a decode key, and the headless-mode precedent

Session 2026-08-25. Evidence classes as in WO-42: **observed** (bytes, or a live
run), **read (source)** (a fact read from the CRYENGINE fork's own files, cited
file:line), **read-but-unrendered**, **inferred** (flagged).

Licensing posture: the fork was **read as reference only**, sparse-cloned into
the session scratchpad (outside this repo), and nothing from it was copied into
this repo. Source of record for every Lead-1 citation:
`github.com/MergHQ/CRYENGINE`, branch `release`, commit
`8b63f61c6bb186fbee254b793775856468df47c5` (2023-05-10). Paths below are
relative to `Code/CryEngine/CryAction/`.

---

## Lead 1 — the real Mannequin source vs WO-42/44's disassembly

### 1.1 The `TAction`/`IAction` layout: WO-42 §3's table maps 1:1 onto the real member list

`IAction`'s member declarations (`ICryMannequin.h:1807–1825`, plus the private
`m_slaveActions` at `:1864`) are, in order: `m_context`, `m_activeTime`,
`m_queueTime`, `m_forcedScopeMask`, `m_installedScopeMask`, `m_subContext`,
`m_priority`, `m_eStatus`, `m_flags`, `m_rootScope`, `m_fragmentID`,
`m_fragTags`, `m_optionIdx`, `m_userToken`, `m_refCount`, `m_speedBias`,
`m_animWeight`, `m_mannequinParams`. Laid against WO-42 §3's observed
constructor writes (vptr at +0x00, KCD2's `TagState` widened to 20 bytes), the
order matches **field for field**:

| KCD2 offset (WO-42 §3, observed) | real member (read, source) | ctor value there | decodes |
|---|---|---|---|
| +0x08 = 0 | `m_context` | `NULL` (`:1405`) | |
| +0x10 = 0 | `m_activeTime` | `0.0f` (`:1406`) | |
| +0x14 = **-1.0f** ("a float, name inferred") | **`m_queueTime`** | `-1.0f` (`:1407`) | the inferred float, named |
| +0x18 = arg6 | **`m_forcedScopeMask`** | ctor param `scopeMask` (`:1404`, `:1408`) | see correction §1.2 |
| +0x1C = 0 | `m_installedScopeMask` | `0` (`:1409`) | |
| +0x20 = **0xFFFFFFFF** | `m_subContext` | `TAG_ID_INVALID` (`:1410`) | the mystery 0xFFFFFFFF |
| +0x24 = priority | `m_priority` (`:1813`) | | already confirmed in WO-42 |
| +0x28 = "status (0 = none, 2 = installed)" | `m_eStatus`, enum `EStatus` (`:1350–1357`) | `None` | **None=0, Pending=1, Installed=2, Exiting=3, Finished=4** |
| +0x2C = flags; "restart path sets 0x40/0x80" | `m_flags`, enum `EFlags` (`:1376–1392`) | | **0x40=Requeued, 0x80=TrumpSelf** (`:1383–1384`) |
| +0x30 = "root scope / director" | `m_rootScope` (`IScope*`, `:1816`) | `NULL` | |
| +0x38 / +0x3C | `m_fragmentID` / `m_fragTags` (`:1817–1818`) | | |
| +0x50 = **0xFFFFFFFE** | `m_optionIdx` | `OPTION_IDX_RANDOM = 0xfffffffe` (`ICryMannequinDefs.h:35`; ctor `:1417`) | the mystery 0xFFFFFFFE |
| +0x54 = "scopeMask (name inferred)" | **`m_userToken`** (`:1820`) | ctor param `userToken` | **correction, §1.2** |
| +0x58 = "intrusive refcount" | `m_refCount` (`:1821`; `AddRef`/`Release` `:1425–1438`) | `0` | confirmed |
| +0x5C / +0x60 = 1.0f / 1.0f | `m_speedBias` / `m_animWeight` (ctor `:1420–1421`) | | named |
| +0x68 = "named-parameter array (§6.3)" | `m_mannequinParams` (`CMannequinParams`, `:1825`) | | confirms WO-42 §6.3's reading — it is the by-CRC named-param store (`GetParam`/`SetParam`, `:1285–1325`) |

WO-42's mystery decode of "+0x28 accepts 0 and 4" now reads plainly: the
Warhorse `QueueAction` accepts an action that is `None` (fresh) **or
`Finished`** (re-queueable) — a sanity gate, not an oddity.

The Warhorse 7-arg `TAction` ctor (WO-42 §3) is the **stock `IAction` ctor
signature verbatim**: `IAction(int priority, FragmentID fragmentID, const
TagState& fragTags, uint32 flags, ActionScopes scopeMask, uint32 userToken)`
(`ICryMannequin.h:1404`). The 6-arg CombatModule copy is the same with
`userToken` defaulted.

### 1.2 One correction to WO-42 §3 (documentation-only)

**The field at +0x54 is not a scope mask — it is `m_userToken`.** The actual
forced scope mask is the field WO-42 left unnamed at **+0x18**
(`m_forcedScopeMask`), consumed at install:
`ActionController.cpp:666` — `scopeMask = action.GetForcedScopeMask() |
QueryScopeMask(fragmentID, fragTagState, subContext)`. WO-42 §8 stated nothing
depends on the inferred names, and that holds: grep of `native/` shows no code
touching +0x54 or any scope mask (the only "0x54" hit in
`native/KCDMP/combat_construct.cpp:94` is a prologue byte pattern). No shipped
behaviour changes; WO-42 §3's table should be read with this note.

### 1.3 `Queue`'s float parameter, fully decoded

- Signature confirmed again: `virtual void Queue(IAction& action, float time =
  -1.0f)` (`ICryMannequin.h:1230`) — as WO-52's spot-check found.
- Implementation (`ActionController.cpp:1712–1718`): `action.m_queueTime =
  time; action.Initialise(m_context); PushOntoQueue(action);`
- Semantics (`ICryMannequin.h:1538–1550`, `IAction::UpdatePending`): while an
  action sits **pending**, if `m_queueTime >= 0` and its accumulated
  `m_activeTime` exceeds it, the action is marked `Finished` — i.e. the float
  is a **pending-queue expiry timeout**, and `-1.0f` means "wait forever".
  WO-42/44 knew the value and default; the meaning is new. The shipped swing
  path effectively passes -1; if a queued ghost action ever wedges in Pending,
  a finite time here is the engine-native timeout.

### 1.4 The `m_pSyncPartner` mechanism: stock Mannequin has no such thing — and that strengthens WO-42 §5.1

`grep -r "SyncPartner\|m_pSync"` over the fork's `Code/` and `GameSDK/`:
**zero hits**. The name was only ever WO-42's working label. What stock
Mannequin actually provides for paired-character animation is **controller
enslavement**, a different mechanism at a different layer:

- `CActionController::SetSlaveController(target, targetContext, enslave,
  piOptionTargetDatabase)` (`ActionController.cpp:1317–1409`): the master
  binds the slave character into one of its own scope contexts — full
  enslavement registers ownership and syncs tags
  (`SynchTagsToSlave`, `:1443`), the ADB-swap variant pauses the slave's own
  controller update (`:1407`, `AC_PausedUpdate`).
- One action then drives both characters: `IAction::m_slaveActions`
  (`ICryMannequin.h:1864`), populated via `CreateSlaveAction(slaveFragID,
  fragTags, context)` (`:1740`); `Stop()`/`ForceFinish()` fan out to slaves
  (`:1626–1651`).

KCD2's observed mechanism (WO-42 §5.1) is **neither of these**: two
*independent* action directors, each queueing its own action, coupled only by
a shared hit descriptor (`SyncAttack+0xB0` smart_ptr / `SyncHit+0xD0` raw
back-pointer) and handed to the victim's own director via
`C_ActionDirector::SetAction`. Reading the stock source confirms WO-42's
"two independent directors" account **by contrast**: the stock alternative
exists, is structurally different (master-slave, single action, shared
scopes), and none of its fingerprints appear in the WO-42 trace. Warhorse
built their own pairing above Mannequin rather than using enslavement. WO-42's
inference stands; the "-equivalent" framing can be retired.

### 1.5 The ADB dependency, refined

WO-42 §9.1 already settled the Warhorse-side metadata
(`combat_fragment_meta.xml`, shipped and complete). The stock source adds one
engine-side mechanism WO-44 §3 could only gesture at: whether a fragment
self-terminates is **per-scope ADB data** — at install, the root scope's
`m_isOneShot` sets or clears `IAction::FragmentIsOneShot`
(`ActionController.cpp:626`, `:645–652`; flag meaning "will end itself at the
end of the sequence", `ICryMannequin.h:1373`). So a bare `TAction` over a
one-shot fragment ends itself with no game-side machinery — exactly why
`MotionJump` played to completion in WO-40 — while WO-43's frozen mid-swing is
what non-one-shot / transition-gated combat fragments do with nobody driving
them. WO-44 §3's reading stands as written; this names the engine switch
behind its first two bullets.

### Gate 1 — verdict

**Confirms prior work was already accurate, with one correction and useful
decodes; no new WO warranted.**

- **Corrects:** WO-42 §3's "+0x54 = scopeMask" → `m_userToken`; the real
  forced scope mask is +0x18. Documentation-only (§1.2).
- **De-risks/decodes:** +0x14 = `m_queueTime` incl. its pending-expiry
  semantics (§1.3); 0xFFFFFFFF = `TAG_ID_INVALID` (`m_subContext`); 0xFFFFFFFE
  = `OPTION_IDX_RANDOM` (`m_optionIdx`); status values named (Finished=4
  explains `QueueAction`'s accept set); restart-path flag bits =
  `Requeued|TrumpSelf`; +0x68 = `CMannequinParams` (confirms §6.3).
- **Confirms:** the entire §3 member map (order 1:1), the Queue signature, and
  §5.1's two-independent-directors reading (§1.4, by contrast with stock
  enslavement).
- **Shipped mechanism (WO-45–49):** no better approach revealed. The source
  validates the choice: a bare `Queue` has no combat lifecycle (§1.5), and the
  stock alternative for paired animation — whole-character enslavement — would
  fight the puppet architecture, not help it. The only nugget is the queue
  timeout (§1.3), not worth a WO alone.

---

## Lead 2 — does KCD2's own build have a headless/no-renderer mode?

### 2.1 Static: no null renderer exists in either shipped build (observed)

**Retail** (`D:\SteamLibrary\...\KingdomComeDeliverance2\Bin\`): monolithic —
`KingdomCome.exe` + `WHGame.dll` (89 MB) and support DLLs; `Win64Shared` is
all real-graphics third-party (DLSS, XeSS, FidelityFX, dxcompiler). No
`CryRender*.dll` of any kind.

**String scan of `WHGame.dll`** (byte offsets recorded for re-checks):

- The **only** `CryRenderNULL` occurrence (@74113368) sits in the stock
  `MemoryFragmentationProfiler.h` static module list, alongside
  `CryRenderD3D9.dll`, `CryRenderD3D10.dll` and `Editor.exe` — modules that do
  not exist in KCD2. Memory-stats bookkeeping, not a load path.
- The live selector region (`CSystem::OpenRenderLibrary` /
  `InitRenderer`) knows driver values `DX12`/`DX11` (@63079640, with console
  names `AGC`/`GNM`) and module names `CryRenderD3D11` (@74114056),
  `CryRenderD3D12` (@63129840, beside `EngineModule_CryRenderer`),
  `CryRenderAGC`/`GNM`/`Vulkan` (@74114360+), plus `"Unknown renderer type:
  %s"`, `"No renderer specified!"`, `"Error creating Render System!"`.
  **No NULL branch.**
- `r_Driver`'s help text (`"Sets the renderer driver ( DX11/DX12/GL/VK/AUTO )"`)
  is inherited stock text; the shipped selector strings above are the real
  accept set.
- The one `headless` string (@64967349): `"Selected device has no connected
  outputs. Running in headless mode."` — DXGI display-headless (a GPU with no
  monitor) with a **full renderer still created**. Not a null renderer.
- Stock dedicated-server CVars survive (`sv_DedicatedCPUPercent`/`Variance`,
  @64787436) — consistent with WO-52's "server half intact", and irrelevant to
  rendering.

**Modding Tools build** (`KCD2Mod\Bin\Win64ReleaseSteamLTO_DLL\`, the modular
45-DLL build): exactly **one** renderer module ships — `CryRenderD3D12.dll`.
Its `CrySystem.dll` tells the same story: `CryRenderNULL.dll` appears once, in
the same profiler list (@5368248, with D3D9/D3D10/Editor.exe); the
`CSystem::OpenRenderLibrary` region (@~5395320) knows `DX12`/`DX11` and no
NULL. So Warhorse's fork **stripped the NULL branch from renderer selection
and ships no null renderer module in any build** — this is what Crysis-era
precedent leaned on (`c1-launcher`'s headless server uses the
`CryRenderNULL.dll` that Crysis shipped).

### 2.2 Live test (observed, reverted)

1. Direct launch `KingdomCome.exe +r_Driver NULL -devmode` → exits before
   renderer init: `CSystem::Quit ... reason: Steam Service Quit - not started
   through Steam` (kcd.log). Flag never exercised — recorded so nobody
   mistakes this for a renderer result.
2. `steam.exe -applaunch 1771300 +r_Driver NULL -devmode` → game booted,
   `Renderer initialization` → `Initializing module CryRenderD3D12` →
   `Creating rendering device...` → real game window created. The CVar
   *exists* and *stored* the value, but only as a deferred set:
   `r_Driver = NULL [DUMPTODISK, REQUIRE_APP_RESTART]` (kcd.log line 580).
   The renderer choice ignored it this run.
3. Cleanup: the process was **hard-killed before clean shutdown** so the
   `DUMPTODISK` flag could not persist `NULL`; then verified — no `r_driver`
   in `user.cfg`, `system.cfg`, or anywhere under `Saved Games\kingdomcome2`.
   Nothing persisted; test fully reverted.

**Warning for future sessions:** do not set `r_Driver=NULL` persistently
(system.cfg/user.cfg, or by letting the game exit cleanly after a `+r_Driver
NULL` launch). Expected result at next boot — not observed, deliberately —
is `"Unknown renderer type"` / failed module load, i.e. a game that won't
start until the line is removed.

### 2.3 What a headless path would actually take (observation only, not a lead)

The MT build's selector still maps `DX11` → `LoadLibrary("CryRenderD3D11.dll")`,
which does not ship — so the engine *would* load a substitute DLL by that name.
But that substitute must implement the full renderer interface the game
consumes, and shader-target validation is live (`"r_driver MUST match shader
target flag."`, WHGame.dll @74255136). That is a from-scratch null-renderer
implementation project, not a found capability.

### Gate 2 — verdict

**Nothing found; the objection stands for KCD2's own build.** No null/no-op
renderer module exists in retail or Modding Tools, the renderer selector has
no NULL branch, and a live `+r_Driver NULL` launch booted D3D12 with a real
window anyway. The `c1-launcher`/`c1-headless` precedent does not transfer:
it depends on a `CryRenderNULL.dll` that Crysis shipped and KCD2 does not.
The only "headless" the build supports is a GPU with no connected displays —
a full renderer, no window guarantee, not a server mode. WO-51's inputs are
unchanged.

---

## What was not done

- Nothing from the CRYENGINE fork was copied into this repo; the sparse clone
  lives in the session scratchpad only.
- No implementation toward either lead; no `VERSION` change; no config or
  game-file edits (the one live launch passed CVars on the command line only
  and was verified to persist nothing).
