# WO-71 — does a headless-capable init path survive in our renderer init?

Session 2026-08-27 (Phase 0–1, static) and 2026-08-28 (**Phase 2, run and
live-observed** after the human approved the flip). §1–§10 are the branch map
the approval gate needed; §11 is the verdict; §13 is the boot result.

Evidence classes, as WO-42/WO-53:

- **observed** — bytes on disk in our install, or a live run.
- **code-verified** — read out of the decompiler/disassembler on *our* Modding
  Tools binaries, with address.
- **read-but-unrendered** — read somewhere authoritative but not exercised here.
- **inferred** — flagged as such every time.

Target of record: the Modding Tools build,
`...\steamapps\common\KCD2Mod\Bin\Win64ReleaseSteamLTO_DLL\` (45 DLLs + two
EXEs). Retail is a different binary and **no offset here transfers to it**
(WO-67). Code addresses are virtual, image base `0x180000000` for the DLLs
(subtract it for the RVA); string offsets marked "@file" are raw file byte
offsets, the same convention WO-53 used.

---

## 1. The WO-53 delta — what was settled, and what this WO tested

WO-53 §2 asked *"does a headless/no-renderer **mode** ship?"* and answered no.
Everything it established still stands and is not re-litigated here:

- No `CryRenderNULL.dll` (or any null-renderer module) ships in retail or in
  the Modding Tools build; the MT build ships exactly one renderer module,
  `CryRenderD3D12.dll`. **Re-confirmed observed** (§2 below).
- The renderer *selector* has no NULL branch: its accept set is
  `DX11/DX12/VK/GNM/AGC`. **Re-confirmed code-verified** (§4).
- `+r_Driver NULL` boots D3D12 anyway (deferred `REQUIRE_APP_RESTART` cvar).
- The one `headless` string in retail is DXGI display-headless, not a null
  renderer.

WO-53 never asked the question this WO asks: **is there a surviving *branch* —
a boolean the shipped code still reads — that skips renderer creation?** That
is a different claim, and the answer is different.

**Both claims are now settled, and they point opposite ways:** no shipped
headless *surface* (WO-53, stands) — but a **fully intact, reachable headless
*branch*** (this WO), which **fires correctly and then dies one subsystem
later** (§13). WO-53's §2.3 aside — that a real headless path would need a
from-scratch null-renderer implementation — turns out to be the exact and only
thing standing in the way, and is now empirically confirmed rather than
speculated.

---

## 2. Renderer-surface inventory (observed)

| item | finding |
|---|---|
| renderer modules in `Bin\Win64ReleaseSteamLTO_DLL\` | **`CryRenderD3D12.dll` only** (6.4 MB). No D3D11/Vulkan/NULL module ships. |
| device + window owner | `CryRenderD3D12.dll`, `CD3D9Renderer::Init` @ `0x180246590` — exported as `?Init@CD3D9Renderer@@UEAAPEAXHHHHIHHAEBUSSystemInitParams@@_N@Z`; its strings include `"Creating window called '%s' (%dx%d)"`, `"Creating rendering device..."`, `"Rendering device creation failed!"`. **code-verified** |
| init / module-selection owner | `CrySystem.dll` (6.8 MB) — `CSystem::Init`, `CSystem::InitRenderer`, `CSystem::OpenRenderLibrary`. **code-verified** |
| `system.cfg` (install root, 6038 bytes) | no `r_Driver`, no `r_HeadlessStartup`, no dedicated-related line. The only "dedicated" hit is a comment about the *render thread*. **observed** |
| `user.cfg` | **does not exist**. **observed** |
| `Saved Games\kingdomcome2\` | no `r_driver` / `headless` line anywhere. **observed** |
| Steam app id (MT build) | `2429020` (`steam_appid.txt` in the install root). Retail is `1771300`. **observed** |
| upscaler middleware | `Bin\Win64Shared\` **does** ship `nvngx_dlss.dll`, `libxess.dll`, `amd_fidelityfx_loader_dx12.dll`, `amd_fidelityfx_upscaler_dx12.dll` (plus AnselSDK64, Aftermath, bink2w64, fmod, dxcompiler). **observed** — this corrects a guess made in an earlier draft of §13 that the MT build might not carry them. They are loaded *by the renderer*, so a boot that never loads `CryRenderD3D12.dll` never reaches them; §13 confirms that empirically. |

---

## 3. String sweep — the branch-stump vocabulary (anchors, not conclusions)

`CrySystem.dll` (file offsets):

| @file | string | what it turned out to be |
|---|---|---|
| 5411936 | `simple_console` | live `CSystem::Init` cmdline arg (§5) |
| 5411952 | `daemon` | live `CSystem::Init` cmdline arg |
| 5411960 | `dedicatedarbitrator` | **live `CSystem::Init` cmdline arg** |
| 5411984 | `dedicated` | **live `CSystem::Init` cmdline arg** (VA `0x18052a890`) |
| 5411840 | `CryEngine - Dedicated Server - Version ` | live console title, `SetConsoleTitleA` |
| 5411880 | `CryEngine - Dedicated Server Arbitrator - Version ` | live, same site |
| 5310040 / 5310072 | `CNULLRenderAuxGeom::EndFrame` / `::BeginFrame` | null aux-geom compiled into CrySystem |
| 6372056 | `.?AVCNULLConsole@@` (RTTI) | vftable at `0x1805376f0`, **constructed by `CSystem::Init`** |
| 6347216 | `.?AVCNullInput@@` (RTTI) | vftable at `0x18051d8d0`, **constructed by `CSystem::Init`** |
| 6347480 | `.?AVCNULLAudioSystem@@` (RTTI) | vftable at `0x180533e78`, **constructed by `CSystem::Init`** |
| 5255776 | `r_HeadlessStartup` | a **live cvar** — but display-headless, see §8 |
| 5368248 | `CryRenderNULL.dll` | as WO-53 said: memory-profiler module list only, no load path |
| 5363400 / 5363424 / 5363912 | `sv_DedicatedCPUPercent` / `MaxRate` / `CPUVariance` | live cvars; their consumer **is constructed** under the dedicated flag (§5) |

`CryRenderD3D12.dll`: `r_HeadlessStartup` @file 5239312, `"Selected device has
no connected outputs. Running in headless mode."` @file 5239488,
`?IsShaderCacheGenMode@CRenderer@@QEBA_NXZ` @file 6008024 (exported, function
at `0x180018310`).

`KingdomCome.exe`: launcher args `-enslave`, `-no_splash`, `-noCrashHandler`,
`-unattended`, `-verbose_stdout`, `-disable_stdout`,
`-create_full_dump_on_crash`, `-multi_inst`, `-notrace`, `-tracenoserver`,
`-noprompt`, `-norandom`, `-crashOnAssert`, `-ignoreAssert`. **No `-dedicated`
here** — it is parsed inside CrySystem, not the launcher.

---

## 4. The call path, init → device creation (code-verified)

```
KingdomCome.exe RunGame @0x140003640
  |- LoadLibraryA("...\WHGame.dll")  ->  GetProcAddress("CreateGameStartup")
  |- builds SSystemInitParams as a stack local (cmdline copied to +0x58)
  \- IGameStartup::Init(startupParams)                       [vtbl +0x10]
       \- WHGame  wh::game::C_GameStartup::Init      @0x180169b70
            \- ...::InitInternal                     @0x180169e10
                 \- CrySystem  CSystem::Init         @0x1801f91c0
                      |- cmdline "dedicated" parse   @0x1801f98c1  <- FLAG WRITE
                      |- [initParams+0x1257 == 0] --------------------  guard G1
                      |    SystemInit.cpp:0xd5f  "Renderer initialization"
                      |    \- CSystem::InitRenderer  @0x1801f3f40
                      |         |- [gEnv+0x3d4 == 0] ------------------  guard G2
                      |         |    r_Driver string -> DX11/DX12/VK/GNM/AGC
                      |         |    \- CSystem::OpenRenderLibrary @0x1801f3790
                      |         |         |- [gEnv+0x3d4 != 0] -> true    guard G3
                      |         |         \- LoadDLL("CryRenderD3D12")
                      |         |              + "EngineModule_CryRenderer"
                      |         \- [m_env.pRenderer != 0] ---------------  guard G4
                      |              \- pRenderer->Init(...)  [vtbl +0x20]
                      |                   = CryRenderD3D12 CD3D9Renderer::Init
                      |                     @0x180246590
                      |                     -> window creation
                      |                     -> device creation (DeviceInfo.inl)
                      |                        [r_HeadlessStartup] -------  guard G6
                      |- font / input / audio / network / AI ...  (§5)
                      \- ...
```

---

## 5. The branch map

`gEnv` is the global pointer `DAT_180637260` in `CrySystem.dll`
(RVA `0x637260`); it is a distinct global in every module (recovered
per-module by the scanner, §6). Three adjacent flag bytes matter:

| offset | identity | how established |
|---|---|---|
| `gEnv+0x3d0` | `bDedicatedArbitrator` | written **only** together with `+0x3d4` on the `dedicatedarbitrator` arg; selects the "Arbitrator" console title. **code-verified** |
| `gEnv+0x3d2` | `bEditor` | `sys_float_exceptions == 3 && gEnv+0x3d2` disables float exceptions (`SystemInit.cpp:0xff8`) — the stock `IsEditor()` special case; also drives the 32x32 stub window in `InitRenderer`. **code-verified** |
| `gEnv+0x3d4` | **`bDedicated`** (`IsDedicated()`) | written on the `-dedicated` arg immediately after `m_bDedicatedServer`; read by both `OpenRenderLibrary` overloads. **code-verified** |

### G2 / G3 — `gEnv->bDedicated` at renderer selection — **LIVE BRANCH**

`CSystem::OpenRenderLibrary(ERenderType, ...)` @ `0x1801f3790`, first thing
after the profiler section:

```
1801f3843  MOV  RAX, qword ptr [0x180637260]      ; gEnv
1801f384a  CMP  byte ptr [RAX + 0x3d4], DIL       ; DIL == 0
1801f3851  JZ   0x1801f385a                       ; not dedicated -> normal path
1801f3853  MOV  BL, 0x1                           ; dedicated -> return TRUE
1801f3855  JMP  0x1801f3c8a                       ; ...loading nothing
```

Decompile of the same site:

```c
if (*(char *)(DAT_180637260 + 0x3d4) != '\0') { uVar9 = 1; goto LAB_1801f3c8a; }
```

`CSystem::InitRenderer` @ `0x1801f3f40` carries the same test around the whole
`r_Driver` selection block (the `char*` overload of `OpenRenderLibrary` is
inlined here):

```
1801f40a9  MOV  RAX, qword ptr [0x180637260]      ; gEnv
1801f40ba  CMP  byte ptr [RAX + 0x3d4], 0x0
1801f40c1  JZ   0x1801f40e0                       ; not dedicated -> stricmp chain
```

```c
if (*(char *)(DAT_180637260 + 0x3d4) == '\0') {
    /* _stricmp(r_Driver,"DX11"|"DX12"|"VK"|"GNM"|"AGC") -> OpenRenderLibrary
       ... else CryWarning("Unknown renderer type: %s") ; return false        */
} else {
LAB_1801f41c3:
    if (*(longlong *)(param_1 + 0x148) != 0) {  /* m_env.pRenderer - guard G4 */
        /* ... pRenderer->Init(...)  = window + device ... */
    }
    return 1;                                   /* success with no renderer   */
}
```

**Grade: live branch.** Neither side is degenerate. The dedicated side does not
error, does not exit, and does not fall through to a stub — it returns success
with `m_env.pRenderer == NULL`, and `CSystem::Init` carries on. This is the
stock CryEngine dedicated-server early-out, intact, except that Warhorse
replaced stock's *"load `CryRenderNULL.dll`"* with *"load nothing"* — which is
strictly better for this purpose: **no null-renderer module is needed.** That
is the precise thing WO-53 concluded was missing; it is missing because it is
no longer required, not because the branch was removed.

### The writer — the launch argument was **not** compiled away

`CSystem::Init` @ `0x1801f91c0` (`RSI` = `CSystem*`, `+0xa31` =
`m_bDedicatedServer`):

```
... iterate m_pCmdLine args of type eCLAT_Pre, _stricmp against "dedicated" ...
1801f98c1  MOV   RAX, qword ptr [0x180637260]
1801f98c8  MOV   byte ptr [RSI + 0xa31], 0x1      ; CSystem::m_bDedicatedServer
1801f98cf  MOV   byte ptr [RAX + 0x3d4], 0x1      ; gEnv->bDedicated
... same again for "dedicatedarbitrator" ...
1801f993f  MOV   byte ptr [RAX + 0x3d4], 0x1
1801f9946  MOV   byte ptr [RAX + 0x3d0], 0x1      ; gEnv->bDedicatedArbitrator
```

Those two stores are the **only** writes to `gEnv+0x3d4` anywhere in
`CrySystem.dll` (full-module instruction scan, §6) — nothing ever clears it,
and there is no cvar surface for it. So the flip mechanism is a command-line
argument: **`-dedicated`**, classified `eCLAT_Pre` because it starts with `-`,
parsed long before `InitRenderer`.

Corroborating live code immediately around it, all in `CSystem::Init`:

- `-daemon` / `-simple_console` select between the text-mode console
  (`operator new(0x210)` -> `0x18026d910`) and **`CNULLConsole`**
  (`operator new(0x40)`, vftable `0x1805376f0`, three sub-object vftables
  written) — the dedicated-server console pair.
- The console title is built in place as
  `"CryEngine - Dedicated Server - Version ..."`, or
  `"...Dedicated Server Arbitrator - Version..."` when `gEnv+0x3d0` is set,
  then `SetConsoleTitleA`.

### G1 — `initParams.bSkipRenderer` (`SSystemInitParams+0x1257`) — **LIVE BRANCH, NO SHIPPED WRITER**

`CSystem::Init` gates the whole renderer step on it:

```c
if (*(char *)((longlong)param_2 + 0x1257) == '\0') {
    CryLogAlways(/* "SystemInit.cpp", 0xd5f, */ "Renderer initialization");
    cVar8 = FUN_1801f3f40(param_1);          /* CSystem::InitRenderer */
    if (cVar8 == '\0') goto /* init failed */;
    /* ... */
}
```

and reads the same byte at six further sites — `r_Driver` `"Auto"` resolution,
`"Init 3D Engine"` (`:0xee3`), `"Script System Initialization"` (`:0xf27`), the
second `"Initializing Renderer..."` banner, and `sys_affinity`. So
`bSkipRenderer` is a *wider* switch than `bDedicated`: it also skips the 3D
engine and the script system, which would take the game with it.

**Writer: none found in the shipped binaries.** `KingdomCome.exe` builds the
struct as a stack local and sets only `bUnattendedMode` (`+0x1269`, from
`-unattended`) and the no-random flag (`+0x1267`, from `-norandom`);
`wh::game::C_GameStartup::Init`/`InitInternal` (`0x180169b70` / `0x180169e10`)
write only the two trailing *pointer* fields (`+0x1270`, `+0x1278`) and read
`+0x1254` — **they never touch `+0x1253` (`bDedicatedServer`) or `+0x1257`.**
So G1 is reachable only by patching, which is why G2/G3 is the preferred lever.

### Partial `SSystemInitParams` field map (code-verified, from use sites)

| offset | evidence | reading |
|---|---|---|
| `+0x0058` | `strcpy_s(..., 0x1000, cmdline)` in the launcher | `szSystemCmdLine[4096]` |
| `+0x124a` | -> `CSystem+0xa21`, gates the `r_Width/r_Height/r_ColorBits` block | `bEditor` |
| `+0x124c` | -> `CSystem+0xa19`, gates Scaleform / network / 3D engine / script | minimal-or-tool mode (**inferred**) |
| `+0x1251` | -> `CSystem+0xa2f`, gates `"Network initialization"` | `bSkipNetwork` |
| `+0x1253` | -> `CSystem+0xa31` = `m_bDedicatedServer` | `bDedicatedServer` |
| `+0x1256` | gates `"Font initialization"` | `bSkipFont` |
| `+0x1257` | gates `"Renderer initialization"`, 3D engine, script system | **`bSkipRenderer`** |
| `+0x1261` | -> `CSystem+0xa24`, used as the **default value of `r_HeadlessStartup`** | headless-startup default |
| `+0x1267` | set by launcher `-norandom` | `bNoRandomSeed` (**inferred from arg**) |
| `+0x1269` | set by launcher `-unattended` | `bUnattendedMode` (**inferred from arg**) |
| `+0x1270`, `+0x1278` | written by `C_GameStartup` | interface pointers |

Note `+0x1253` (`bDedicatedServer`) and `gEnv+0x3d4` (`bDedicated`) are **not**
the same switch: the init-param sets `m_bDedicatedServer` only (which is what
gates the audio system -> `CNULLAudioSystem`), and the `-dedicated` parse is
skipped when it is already set — so an init-param-only dedicated launch would
leave `gEnv->bDedicated` **false** and the renderer would still load. The
command-line argument is the one that sets both.

### What else the dedicated flag changes in `CSystem::Init` (the dependency preview)

All code-verified inside `0x1801f91c0`:

| subsystem | behaviour when `gEnv->bDedicated` |
|---|---|
| console | `CNULLConsole` / text-mode console instead of the graphical console |
| renderer | not loaded at all (G2/G3) |
| font | `"default"` font creation skipped entirely |
| input | `"Input initialization"` skipped; **`CNullInput`** instantiated (`operator new(0x28)`, vftable `0x18051d8d0`) |
| audio | `CNULLAudioSystem` + `CNULLAudioProxy` (this one keys off `m_bDedicatedServer`, `CSystem+0xa31`) |
| network | after `CryNetwork` loads, an extra `operator new(0x30)` object built from `(CSystem*, cpuCount)` — the `sv_DedicatedCPUPercent` throttle (**inferred** from the cvar set and the constructor shape) |
| AI | the AI-system init condition gains a `gEnv->bDedicated` term |
| `HotUpdate` | not registered |

`Cry3DEngine` and the script system are **not** gated on `bDedicated` — only on
`bSkipRenderer`. So a `-dedicated` boot still stands the 3D engine and Lua up,
with `gEnv->pRenderer == NULL`.

---

## 6. Breadth of readers — this is not a stump

Two independent measurements.

**(a) Ghidra, per module** — `DumpWo71GenvFlag.java` finds every instruction
whose memory operand is `[reg + 0x3d4]`, walks back for the `MOV reg,[global]`
that loaded the base, and tallies globals so `gEnv` self-identifies. Counting
only hits whose base provably came from that module's `gEnv`:

| module | distinct functions reading `gEnv->bDedicated` |
|---|---|
| `Cry3DEngine.dll` | 37 |
| `CryAction.dll` | 33 |
| `CrySystem.dll` | 24 (+ the 2 writes) |
| `CryAnimation.dll` | 8 |
| `CryNetwork.dll` | 5 |
| `WHGame.dll` | 5 |
| `CryEntitySystem.dll` | 4 |
| `GUIModule.dll` / `Framework.dll` / `CryScriptSystem.dll` / `CryMovie.dll` / `CryAISystem.dll` / `CryPhysics.dll` | 2 each |
| `CryInput.dll` / `CryFont.dll` | 1 each |
| `TestModule.dll` | 0 |

Named readers in `CrySystem.dll` include `CSystem::Update`,
`CSystem::RenderBegin`, `CFrameProfileSystem::Render`, the streaming-engine
setup, the `e_*` 3D-engine cvar sink, the `CXConsole` constructor, and the
SSE-support check. `CryFont.dll`'s single reader is
`CreateCryFontInterface` @ `0x180008da0` — the module entry point itself.

**(b) Byte-pattern census over all 45 shipped modules** — counting only the
exact `CMP byte ptr [reg+0x3d4], 0` encodings (`80 /7 D4 03 00 00 00`), i.e. an
undercount, since `MOVZX`/`TEST` forms are not counted:

```
Cry3DEngine 28  CryAction 27  CrySystem 22  EntityModule 12  CryRenderD3D12 11
EditorDll 8  CryAnimation 7  XGenAIModule 6  WHGame 4  PlayerModule 4
RPGModule 4  CombatModule 3  CryNetwork 3  CryEntitySystem 3  EditorCommon 3
CryAISystem 2  CryScriptSystem 2  DialogModule 2  EnvironmentModule 2
Framework 2  GUIModule 2  QuestModule 2  ... 1 each in AnimationModule,
ConceptModule, CryFont, CryInput, CryMovie, CryPhysics, MusicModule,
SoundModule, UtilsModule
```

34 of the 45 modules test it, **including Warhorse's own game modules**, not
just inherited engine code. The single most telling one:

> `wh::game::C_GameStartup::Run` @ `0x18016afc0`, `WHGame.dll` — Warhorse's own
> game-loop entry, immediately before the `"Entering game loop"` trace:
>
> ```c
> if (gEnv && gEnv->pSystem && *(char*)(gEnv+0x3d2) == '\0'    /* !IsEditor   */
>          && *(char*)(gEnv+0x3d4) == '\0' && ...) { /* renderer-side calls */ }
> ```
>
> the `+0x3d4` test at `0x18016b2c3`. Warhorse maintained a dedicated branch in
> their own top-level game loop.

**Method caveat, stated because it bites:** the generic scanner also reports
stack-frame accesses at the same displacement. `CryPhysics.dll` shows ten hits
of which only two are `gEnv`-based; the other eight are `MOVSS [RBP+0x3d4]`
float spills. Every number in table (a) is filtered on a recovered global.

---

## 7. Compiled-in unit tests (WO-68's lead) — nothing here

`TestModule.dll` is Warhorse's **in-game** test-command module
(`wh::tests::ai::perception::WaitUntilAwarenessChanges`,
`wh::tests::WaitUntilCheckPoint`, ..., source under
`code\game\modules\testmodule\Commands\`). It contains **no** occurrence of
`SSystemInitParams`, renderer selection, or dedicated-mode vocabulary, and zero
`gEnv->bDedicated` reads. There is no free init-param field map to be had from
it. **Clean negative.**

---

## 8. `r_HeadlessStartup` — a real but *different* capability

- Registered in `CSystem::CreateSystemVars` @ `0x180208980`, cvar creation at
  `0x180208d24`, help text **"Allow creating the render device without any
  connected monitors."**, flags `0x2100`, **default value taken from
  `SSystemInitParams+0x1261`**. **code-verified**
- Consumed in the DXGI adapter probe (`AutoDetectSpec.cpp`) @ `0x18008e1b0`,
  read at `0x18008e2db`, next to *"No display connected to DXGI adapter
  override %d. Adapter cannot be used for rendering."*
- Also present in `CryRenderD3D12.dll` (@file 5239312), beside *"Selected
  device has no connected outputs. Running in headless mode."*

This is Warhorse-authored and live, but it is **display**-headless: a full
D3D12 device is still created, on a GPU with no monitor attached. It is not a
renderer-less path and must not be conflated with one. Recorded because it
shows Warhorse actively maintained monitor-less startup — and because it is
the *other* thing a future decision session might want (a GPU-backed but
screenless host).

`CRenderer::IsShaderCacheGenMode` (exported, `0x180018310`, bit 3 of
`CRenderer+0x134`) exists but has **no launch surface** found — no
`-shadercachegen`-class string in `CrySystem.dll` or the launcher. Not pursued.

---

## 9. Retail, for completeness only — *does not transfer*

`WHGame.dll` in the retail monolith also carries `dedicatedarbitrator`
(@file 64779616), `CNullInput` (@file 77881468), `CNULLAudioSystem`,
`r_HeadlessStartup` (@file 61078216) and `"CryEngine - Dedicated Server"`
(@file 67793304). `simple_console` and `CNULLConsole` did **not** hit there.
These are **observed strings only** — no xref work was done on the retail
binary and, per WO-67, none of the Modding Tools addresses apply to it. Treat
this paragraph as "the vocabulary is present in retail too", nothing more.

---

## 10. What the static work did **not** establish

Written before Phase 2 ran, kept as written, annotated with what §13 then
settled.

- ~~**That it boots.**~~ → answered, §13: it boots ten-plus subsystems deep and
  then fatals. Tier 2.
- ~~**What breaks first.**~~ → answered, §13: `CryAnimation`'s character-manager
  init, `CryAnimation.dll` RVA `0xAF900`. The prediction that "the first
  unconditional `gEnv->pRenderer->...` on the boot path is the likely stop" was
  correct in kind.
- ~~**Whether Steam permits it.**~~ → answered, §13, and the framing was wrong:
  `steam -applaunch 2429020 <args>` does **not** launch the game at all, it
  launches the Modding Tools `WorkspaceSetup.exe` wizard. The MT
  `KingdomCome.exe` is started **directly** with the game root as working
  directory — which is what this project's own launcher already does
  (`KCDMP_launcher/Pages/Home.razor.cs:521`) — and Steam raised no objection.
  WO-53 §2.2's "not started through Steam" quit applies to the **retail** exe,
  not the Modding Tools one.
- **Still open — whether a dedicated boot reaches a world.** Stock CryEngine
  dedicated servers need `sv_map`/`sv_gamerules`; both cvar names exist in
  `CrySystem.dll` (@file 5296924 / 5383544) but nothing was traced from them to
  KCD2's own level-loading path, and the boot never got far enough to try.
- **Still open — what is behind the first blocker.** `CryAnimation` is the
  *first* consumer to fatal, not necessarily the only one. Everything after it
  in `CSystem::Init`, and the whole of `C_GameStartup::InitInternal`, is still
  unexercised with a null renderer.
- **`-dedicated` is safe to leave set** — it is a command-line argument, not a
  persisted cvar, so unlike WO-53's `r_Driver=NULL` warning there is no
  mechanism for it to stick in a config file. Confirmed in practice: the run
  left no config change behind (§13).

---

## 11. Verdict

> **Headless-capable branch exists, is reachable from a shipped launch
> argument, and fires — but is blocked at `CryAnimation`.**
>
> `gEnv->bDedicated` (`gEnv+0x3d4`) is written by the `-dedicated`
> command-line argument at `CrySystem.dll` `0x1801f98cf` and read at
> `0x1801f384a` / `0x1801f40ba` to skip renderer module loading and device
> creation entirely. Both sides of the branch carry real code; 34 of the 45
> shipped modules read the flag, Warhorse's own `C_GameStartup::Run` among
> them. Neither the flag nor its launch argument was compiled away.
>
> **Live-verified (§13):** with `-dedicated`, `CryRenderD3D12.dll` is never
> loaded, no rendering device and no game window are created, and
> `CSystem::Init` proceeds through console, audio (`NULL AudioSystem`), font,
> network, movie, time, animation-module and 3D-engine initialisation. It then
> takes a fatal error in `CryAnimation`'s character-manager init —
> `CryAnimation.dll` RVA `0xAF900`, fatal call at `0x1800af94e`:
> an **unconditional** `if (!pSystem->GetIRenderer()) CryFatalError(200,
> "CryAnimation: failed to initialize pIRenderer")`, with no `IsDedicated()`
> guard. Stock CryEngine never needed one, because a stock dedicated server has
> a *non-null* `IRenderer` — `CryRenderNULL.dll`. Warhorse's fork replaced
> "load `CryRenderNULL.dll`" with "load nothing", so the pointer is genuinely
> NULL and stock's null-check bites.

Against the WO's four grades: **tier 2 — "exists but blocked at
`CryAnimation` (character-manager init, `CryAnimation.dll` +0xAF900)"**. Not
"stump only", not "absent", not "boots".

The practical shape of the result: the *branch* is not the missing piece — a
no-op `IRenderer` object is. That is precisely what WO-53 §2.3 said a headless
path would take ("a from-scratch null-renderer implementation project, not a
found capability"), and it is now confirmed by a boot rather than reasoned
about. What changed versus WO-53 is the size of the gap: it is no longer
"the engine has no headless concept", it is "the engine has a complete headless
init path and is missing one interface implementation" — with the caveat in
§10 that `CryAnimation` is only the *first* consumer to fatal.

This reverses the *implication* people had been drawing from WO-53 without
contradicting WO-53 itself. WO-53's own words — "Warhorse's fork stripped the
NULL branch from renderer selection" — are accurate about the `CryRenderNULL`
*module* and are what made a surviving branch look unlikely. The branch they
stripped is the one that *loads a null renderer*; the branch that *skips the
renderer* is untouched.

## 12. If a decision session reopens the dedicated-instance idea, what it would weigh

*(Listing considerations, not making a recommendation — the topology decision
is explicitly out of this WO's scope.)* Phase 2 answered the first of these and
reshaped the rest. A future session would need: **the cost and risk of a
stub `IRenderer`** — the one thing now known to be missing, an interface with
a large vtable that must satisfy every consumer, of which `CryAnimation` is
only the first found (WO-53 §2.3 called this "a from-scratch null-renderer
implementation project", which is exactly what it is, though the surrounding
init path turns out to be free); **how many more blockers sit behind it** —
unknowable without either building the stub or auditing every
`gEnv->pRenderer->` on the init path; whether a `-dedicated` process would then
actually tick a world — game time advancing and an NPC moving, readable over
the existing REST surface — because a process that boots but does not simulate
is worth nothing here; its idle CPU and RAM against running a second full
client, which is the status quo this would replace; whether `sv_map`-class
level loading reaches a KCD2 level at all
or whether the host would still need a normal client to own the world; what the
`CNullInput` / `CNULLAudioSystem` / no-font configuration does to the Lua and
UIAction surfaces the whole mod is built on (WO-38's toasts, WO-6's dice UI,
WO-65's dialog isolation all assume a rendering client); how a renderer-less
host interacts with WO-51's finding that AI is proximity-gated and WO-60's
proximity claim/hold design, which currently assume every participant is a
player-shaped client; and the distribution question — a dedicated host that
needs the **Modding Tools** build rather than retail is a different install
requirement for users than anything shipped so far.

---

## 13. Phase 2 — the boot, run 2026-08-28 with human approval (observed)

### Setup

- **Flip mechanism**: preference (a) from the WO — an existing launch surface,
  no patch, no injection, no file edit. Argument set chosen by the human:
  `-dedicated -devmode -simple_console`, plus `+r_SuperResolution_Mode 0` as
  the middleware disable.
- **Middleware disabled**: `r_SuperResolution_Mode 0` on the command line — a
  cvar, not a file change. The upscaler DLLs themselves (`nvngx_dlss.dll`,
  `libxess.dll`, the two FidelityFX DX12 DLLs) were **left in place**: they are
  loaded by the renderer module, which this branch never loads. Nothing was
  renamed, moved, or edited anywhere in the install.
- **Baseline recorded before launch**: no game/mod/relay process running;
  `kcd.log` 5 768 017 bytes; one file in `logbackups`.

### First attempt — wrong launch route (recorded so nobody repeats it)

`steam.exe -applaunch 2429020 -dedicated …` **does not start the game.** It
starts the Modding Tools `WorkspaceSetup.exe` wizard (observed as a live
process); no `KingdomCome.exe` ever appeared and `kcd.log` did not move in 60 s.
App 2429020's Steam launch action is the workspace-copy tool, not the engine.

The working route is the one this project's own launcher already uses
(`KCDMP_launcher/Pages/Home.razor.cs:521`): start
`Bin\Win64ReleaseSteamLTO_DLL\KingdomCome.exe` **directly**, with the **game
root** as the working directory so `steam_appid.txt` is found. Steam running in
the background is enough; the retail-only "Steam Service Quit" objection from
WO-53 §2.2 did not appear.

### Result — **tier 2: boots partially, fatals at an identified subsystem**

`kcd.log` (fresh, `Log Started at 2026-08-28 07:30:11`) confirms the argument
reached the parser:

```
Cmdline: '"…\Win64ReleaseSteamLTO_DLL\KingdomCome.exe" -dedicated -devmode
          -simple_console +r_SuperResolution_Mode 0 '
```

**The branch fired, exactly as §5 predicted.** In the whole log there is:

- `Renderer initialization` — the `bSkipRenderer` gate (G1) passed, so
  `CSystem::InitRenderer` *was* entered;
- **no** `Initializing module CryRenderD3D12`, **no** `Creating rendering
  device...`, **no** `Creating window called '…'` — G2/G3 took the dedicated
  early-out and the renderer module was never loaded;
- `<Audio>: Running with NULL AudioSystem.` — the dedicated audio substitution
  fired;
- and init then continued normally through `Font initialization`,
  `Network initialization`, `Lobby initialization`,
  `MovieSystem initialization`, `Console initialization`,
  `Time initialization`, `Initializing Animation System`
  (`Initializing module CryAnimation done, MemUsage=38708Kb`), and
  `Init 3D Engine` (`Initializing module Cry3DEngine done, MemUsage=12220Kb`,
  including `Sky light: Optical lookup tables loaded off disc`).

`Cry3DEngine` — the module most likely to be renderer-coupled — **initialised
cleanly with a null renderer.** The process died immediately after:

```
=============================================================================
*ERROR
=============================================================================
CryAnimation: failed to initialize pIRenderer
```

followed by the BugSplat crash reporter. The report was **not sent**.

### The blocker, pinned

`CryAnimation.dll` `FUN_1800af900` — RVA `0xAF900`, fatal call at
`0x1800af94e`. Decompiled:

```c
if (DAT_1802dfc00 == NULL)                      /* g_pISystem  */
    CryFatalError(200, "CryAnimation: ISystem not initialized");
DAT_1802de4d8 = pSystem->GetIRenderer();        /* ISystem vtbl +0x2d0 */
if (DAT_1802de4d8 == 0)
    CryFatalError(200, "CryAnimation: failed to initialize pIRenderer");
DAT_1802de4e0 = pSystem->GetIPhysicalWorld();   /* vtbl +0x258 */
if (DAT_1802de4e0 == 0)
    CryFatalError(200, "CryAnimation: failed to initialize pIPhysicalWorld");
DAT_1802dfc10 = pSystem->Get3DEngine();         /* vtbl +0x268 */
if (DAT_1802dfc10 == 0)
    CryFatalError(200, "CryAnimation: failed to initialize pI3DEngine");
… then registers "CharacterManager" with the module manager
```

This is stock CryEngine's character-manager init null-check chain, verbatim and
unmodified — the string order (`ISystem not initialized` / `pIRenderer` /
`pIPhysicalWorld` / `pI3DEngine`, @file 2513720 / 2513672 / 2513808 / 2513760)
matches the stock sequence. `FUN_180011e20(200, …)` is the same severity-200
fatal helper `CrySystem` uses for `"Error creating Render System!"`.

**Crucially it is an unconditional null-check, not an `IsDedicated()` check.**
There is nothing to flip here. Stock never needed a guard because a stock
dedicated server *has* an `IRenderer` — the no-op one from `CryRenderNULL.dll`.
Warhorse's substitution of "load nothing" for "load `CryRenderNULL.dll`" is
what turns this into a fatal. (That stock dedicated servers load
`CryRenderNULL` is **read-but-unrendered** lineage knowledge, consistent with
WO-53 §2.1's `c1-headless` precedent; it was not verified against Warhorse
source.)

Note the log ordering: CryAnimation's *engine module* initialised fine — the
fatal is in the later character-manager step, which runs after `Cry3DEngine`
comes up. **observed**

### Steps 4 of the WO's Phase 2 — not applicable

No idle CPU/RAM measurement and no world-tick check were possible: the process
never reached a running state. Tier 2 stops there by definition.

### Cleanup / state left behind

Nothing. No file in the install was edited, renamed, or moved; `-dedicated` is
an argument, not a persisted cvar, so nothing can carry into the next launch.
The process is gone and no BugSplat process remains. `kcd.log` was rotated by
the engine itself in the normal way (the previous log went to `logbackups`, and
the run's own log is the current `kcd.log`). Crash artefacts were written by
BugSplat to the user's `%TEMP%` and were left alone.

---

## Appendix — reproducing this

Ghidra 12.1.3 headless, Temurin JDK 21, one project per concurrent job,
forward-slash import paths. Scripts added by this WO (read-only, static):
`native/ghidra_scripts/DumpWo71GenvFlag.java`, `DumpWo71FnStrings.java`,
`DumpWo71Range.java`. See `native/ghidra_scripts/README.md`.
