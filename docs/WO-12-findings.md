# WO-12 Phase 0 findings — can the local player move while a menu has focus?

Investigated 2026-07-31 against the live, currently-running KCD2 Modding Tools
build (pid 19904, `KCDMP.dll` from `native/build/KCDMP_wo10verify/` injected and
ticking throughout, debug REST API answering on `localhost:1403`,
`log_Verbosity` already at 4 from WO-11). Evidence discipline: observed /
read-but-unrendered / inconclusive, per the WO's instruction. Every claim below
is either a real export search or a real observed live test with a human at the
keyboard; nothing is inferred from a call returning success.

**Verdict: the WO's option (2) — input is dropped from movement, and direct
position writes work as a bypass.** Option (1) is ruled out by direct
measurement; option (3) is false.

---

## Premise correction, recorded first because it affects Phase 1

The WO states: *"Direct native-reflection writes to a player's position are
already proven — the WO-6 teleport work wrote position via the RTTR reflection
layer successfully."*

**This is not supported by the repository.** WO-6's Tier I (invite / accept /
teleport) was never built — `docs/WO-6-progress.md:131` records Tier I/II as
"fully unblocked and unaffected" pending a human decision, and no
local-player position write exists anywhere in `kdcmp.lua`, `dotnet/` or
`native/`. The only position writes in the codebase are Lua
`entity:SetWorldPos` calls against *ghost* entities (`kdcmp.lua:1643`, `:2007`).

The capability the WO was reaching for is nonetheless **real, and is now
proven directly by 0.4 below** — just by a different mechanism than the WO
named: Lua `player:SetWorldPos` driven through the console `ExecuteString`
transport, not an RTTR reflected setter. Phase 1 planning should use the
mechanism that was actually tested.

---

## 0.1 — export search (no game needed)

`dumpbin /exports` (MSVC 14.44, located via the same `vswhere` path
`native/Build-Native.ps1` uses) against **all 44 DLLs** in
`D:\SteamLibrary\steamapps\common\KCD2Mod\Bin\Win64ReleaseSteamLTO_DLL` —
wider than WO-11's catalogued set, deliberately, because the CryEngine input
layer lives in modules WO-11 had no reason to dump. Export tables cached to
scratch; counts range from 21 (`Quatmosphere`) to 5,505 (`EditorDll`).

**The WO's pattern list returns zero hits, anywhere:**

```
grep -inE "InputFocus|UIFocus|BlockInput|CaptureInput|InputBlock|
           ModalFocus|InputPause|IActionMapManager|EnableAction"  *.txt
  -> (no output)
```

Broadened the search myself rather than stopping at the given list — `Focus`,
`ActionMap`, `ActionFilter`, `Input`, `Movement`, `Locomot`, `Lock`, `Freeze`,
`Suppress`, `Disable*`, `Menu*`, `Modal`, `GameMode`. Results:

| What was searched for | What actually exists |
|---|---|
| `*Focus*` | 18 distinct names, **every one of them Qt/MFC editor UI** (`OnKillFocus`, `focusInEvent`, `QFocusEvent`, …) in `EditorDll`/`EditorCommon`. Zero in any game module. |
| `*ActionMap*` / `*ActionFilter*` | **one** hit total: `C_InteractionFilter::LoadFromXML` (`PlayerModule`) — an XML loader, not a runtime control. |
| `*Input*` | almost entirely D3D vertex-input-layout noise from `CryRenderD3D12`. The only real ones: `wh::entitymodule::C_PlayerInput::StopSprint(void)` and `C_RTTROnScreenDebug::OnInputEvent`. |
| `*Movement*` / `*Locomot*` | `C_ActorMovementController::GetMovementTransitionController`, plus behaviour-tree data-table glue in `XGenAIModule` (same `C_TypeLibrary` static-member pattern WO-11 §0.1 already characterised). |
| lock / freeze / suppress / disable-control shapes | **zero hits.** |
| `*GameMode*` | `C_SaveGameDescription::GetGameMode` and `SCVars::OnGameModeStart` — savegame and CVar plumbing, unrelated. |

**The decisive negative, and it is a hard one:** `CryInput.dll`,
`CryAction.dll`, `CryScriptSystem.dll` and `GUIModule.dll` export **nothing
but accidental `boost::optional<bool>` template instantiations** — 69, 79, 69
and 83 entries respectively, of which the only non-boost symbols are a single
class constructor apiece (`C_LayerEntityIdReservation`, `C_GUIModule`). These
are exports leaked by a `__declspec(dllexport)`-ed header, not an intentional
surface.

So **CryEngine's entire input and action-map layer — `CActionMapManager`,
`IActionMapManager::EnableFilter`, `CBaseInput`, the UI focus stack — is not
name-addressable at all in this build.** There is no export to hook, and no
export to resolve an instance from. This is a stronger negative than WO-11's:
WO-11 found one exported symbol that turned out never to fire; here there is
not even a symbol.

Two classes are proven real by a single exported method each and are the only
leads a Phase 0.5 could have followed:
`wh::entitymodule::C_PlayerInput` and `wh::entitymodule::C_ActorMovementController`.
Neither is a focus or input-block control by name or by signature.

## 0.2 — does our own input hook see anything with a menu open?

Instrumented live, human at the keyboard, in two passes. Pass 1 used the mod's
own `KCD2MP.logActions` flag (set remotely via `ExecuteString`). Pass 2 layered
an additional, **unfiltered** logger on top of both `Player.Client.OnAction`
and `Player.OnAction`, because the mod's own `handleAction` returns early on
`AXIS_ACTIONS` (`kdcmp.lua:3588`) and would have hidden exactly the movement
actions this test is about.

**Three things were observed, and the first was not anticipated by the WO:**

### (a) Movement input never reaches the Lua hook, even with no menu open

The control segment — hold `W` for 3 s, nothing open — moved the player
smoothly (position tracked continuously, `2138.43 → 2145.88`) and produced
**zero movement callbacks**. Not a movement action, not a movement axis event,
not one under a different name. The unfiltered logger recorded exactly 16
callbacks across that window and every one of them was `combat_zone_mouse_x`
or `combat_zone_mouse_y` — incidental mouse drift, nothing from the keyboard.

**So movement is consumed below the script layer during ordinary play.** The
`Player.OnAction` surface never sees it. This reframes 0.2's question: the
comparison "does it still fire with a menu open" has no positive baseline to
degrade from.

Incidental, and worth recording because two of the mod's hooks depend on it:
**`Player.Client.OnAction` never fired once** across either pass — every
callback observed arrived through `Player.OnAction`. The `Client.OnAction`
hook installed at `kdcmp.lua:3673` and `:3683` is dead code in this build.

### (b) Inventory — outcome (ii): fires, with a different action name

With the inventory open, holding `W` for 4 s produced, through the mod's own
handler:

```
ACT open_apse_inventory_keyboard  press
ACT open_apse_inventory_keyboard  release
>>>> PlayAudio: ApseOpen
ACT focus_prev  press
ACT focus_prev  hold      x41
ACT focus_prev  release
```

41 `hold` events at the hook's ~10 Hz cadence matches the 4-second hold
closely. **The same physical key that drives movement in the field is
re-routed to `focus_prev`, a UI navigation action, the moment the inventory
takes focus.** This is outcome (ii) as the WO defined it, observed directly.

### (c) Pause menu — outcome (iii) at the Lua layer, with rerouting proven elsewhere

With the system/pause menu open, holding `W` and tapping `A`/`S` produced
**no callback at any action name** through either hook. Exactly one callback
fired inside the whole menu window and it was `open_menu | release` — the
`ESC` key's own release, not a movement key. But the same window of `kcd.log`
contains:

```
PlayAudio: MenuOpen
Playlist tag RTPC 'sqc_ptag_menu' will be 1.000000
PlayAudio: ui_menu_change_focus      x41
PlayAudio: ui_menu_close
Playlist tag RTPC 'sqc_ptag_menu' will be 0.000000
```

41 focus-change sounds — the menu's own navigation feedback. **The keypresses
were consumed as menu navigation at a layer that never reaches Lua.**

So: (ii) for inventory, (iii) for the pause menu *as measured at the Lua hook*
— but given (a), (iii) here is not evidence of a block, because movement never
reaches that hook anyway. The honest combined reading is that **both menus
reroute the physical key into a UI action map**; only the inventory's version
happens to surface through `Player.OnAction`.

## 0.3 — does the character's position change, independent of rendering?

**This is the most important measurement in this phase and it required
throwing away the first instrument.**

The first attempt used a Lua `Script.SetTimer` sampler logging
`player:GetWorldPos()` at 10 Hz into `kcd.log`. It produced apparently clean
"position never changed" data — which was **wrong evidence**, caught by
checking sample-index continuity across the menu markers rather than trusting
the values:

```
[WO12] s=1311 pos 2353.3413 2138.4290 117.4100
PlayAudio: MenuOpen
Playlist tag RTPC 'sqc_ptag_menu' will be 1.000000
   ... 44x ui_menu_change_focus, ~10 seconds of real time, ZERO samples ...
PlayAudio: ui_menu_close
[WO12] s=1312 pos 2353.3413 2138.4290 117.4100
```

**The Lua `Script.SetTimer` layer halts completely while either menu is open.**
Consecutive sample indices either side of a ~10 s window. The sampler was not
observing stasis; it was not running. Same result checked independently for
the inventory window in the first run (`ApseOpen` → `ApseClose`, zero samples
inside). *(Direct consequence for WO-11, out of scope here but worth flagging:
`KCD2MP_InterpTick` — the ghost interpolation tick — halts too.)*

Re-measured with a channel that does **not** ride the Lua timer: the debug
REST reflection API, `GET /api/rpg/SoulList/SoulsByName/Dude/Position`, a
100-byte read at ~49 ms, polled at ~3.3 Hz from an external PowerShell watcher.
The same watcher tracked the Lua sample index as a self-synchronising
menu-open detector (Lua frozen ⇒ menu open), so no clock correlation was
needed.

**Result, human holding movement keys throughout:**

| Segment | Duration | Position |
|---|---|---|
| Control, nothing open, `W` held | ~3 s | `2138.4346 → 2145.8799` — tracked continuously, ~7 m travelled |
| **Inventory open**, `W` held | ~12 s | `2353.5652, 2145.8799, 118.04451` — **bit-identical, every sample** |
| **Pause menu open**, `W`+`A`+`S` held | ~19 s | `2353.5652, 2145.8799, 118.04451` — **bit-identical, every sample** |

The control segment proves the instrument sees real movement at this
resolution. The two menu segments then show not "small drift" or "position
updates suppressed" but the identical float bit pattern across ~100 samples.

**Conclusion: input is genuinely dropped from movement. This is not a
rendering or camera lock over a character that is really moving.** The WO's
best case — "Phase 1 becomes largely presentation" — is closed.

## 0.4 — can the mod write the local player's position with a menu open?

Run independently of 0.1–0.3's outcome, as the WO instructed.

**Baseline first, no menu open**, to establish the mechanism works at all:

```
REST pos BEFORE : 2352.4966, 2116.3413, 115.18379
  #player:SetWorldPos({x = p.x + 1.5, ...})
REST pos AFTER  : 2353.9966, 2116.3413, 115.18379      exactly +1.5
  #player:SetWorldPos(original)
REST pos RESTORED: 2352.4966, 2116.3413, 115.18379     exact
```

Written through Lua, read back through the independent RTTR reflection channel
— two different paths to the same number, so this does not rest on the write
reporting success.

**Then with menus open**, fully automated: the watcher detected each menu from
the Lua stall and fired the write itself, so there is no human-timing question
about whether the menu was really open. Which menu was which was confirmed
afterwards from `kcd.log`'s own audio markers rather than from the
instructions given.

### Episode 1 — pause menu (`PlayAudio: MenuOpen`, no close before the write)

```
pos before write        : 2353.5652, 2145.8799, 118.04451
console CVar path       : t_scale 1 -> 0.77 (restored to 1)     <- non-Lua, works
lua SetWorldPos request : sent
pos +300ms / +700ms / +1500ms / +3000ms : unchanged  (luaIdx frozen at 9018)
[WO12W] markers in log  : latest #1                              <- the Lua DID execute
LUA RESUMED  pos = 2355.5652, 2145.8799, 118.04451               <- exactly +2.0
```

### Episode 2 — inventory (`ApseOpen` was the last marker before the write)

```
pos before write        : 2355.5652, 2145.8799, 118.04451
console CVar path       : t_scale 1 -> 0.77 (restored to 1)
lua SetWorldPos request : sent
pos +300ms              : 2357.5652, 2145.8799, 118.04451        <- landed DURING the menu
pos +700 / +1500 / +3000ms : held at 2357.5652
```

**Three separate positives here, and one honest boundary:**

1. **The write is accepted and applied in both menu states**, with the exact
   +2.0 offset and no drift or rejection.
2. **With the inventory open it lands and is observable immediately** —
   within 300 ms, while the menu still has focus.
3. **The Lua VM itself is alive during both menus.** The
   `[WO12W] write #N executed` marker appears in `kcd.log` while the Lua timer
   index is still frozen — so `ExecuteString`-driven Lua runs immediately;
   it is the `Script.SetTimer` *scheduler* that is gated, not the interpreter.
   The console/CVar path (`t_scale`, non-Lua) also round-tripped cleanly
   inside both menus, so WO-11's whole response mechanism is unaffected by
   menu focus.
4. **Boundary — pause menu, inconclusive between two readings.** In episode 1
   the reflected `Position` did not change until the menu closed, then showed
   the full offset. This is equally consistent with (a) `SetWorldPos` itself
   being deferred to the next entity tick, or (b) the write landing
   immediately with the *reflected* `Position` being a cached value refreshed
   on a tick that is halted. The available data cannot separate these. It does
   not change the actionable conclusion — the write is accepted and lands
   exactly — but "position writes are observable live during the pause menu"
   is **not** proven, whereas for the inventory it is.

Player position was restored to `2353.5652, 2145.8799, 118.04451` exactly,
all probes disabled, `t_scale` confirmed back at `1`.

## 0.5 — not run, deliberately

The WO gates 0.5 on 0.1–0.4 leaving the question genuinely open. They do not:
0.3 answers the question outright, and 0.4 returns a working bypass. Beyond
that, 0.1 established there is **no exported input-routing function to
disassemble** — `CryInput`/`CryAction` export nothing but boost template
noise — so the `dice_hook.cpp` evidence standard (exported or resolvable
address, entry-byte disassembly, stolen-bytes safety analysis) could not be
met for any input-routing target even if it were attempted. Running 0.5 would
mean blind signature-scanning, which is exactly the fragile technique every
native change on this project has refused.

---

## 0-gate verdict

**Option (2): input is dropped, but direct position writes work as a bypass.**

- **Option (1) is closed by direct measurement.** Bit-identical position across
  ~100 samples over 12 s (inventory) and 19 s (pause menu) with movement keys
  held, on a channel proven in the same run to track real movement. Phase 1 is
  not a presentation problem.
- **Option (2) is real and verified**, on an already-working mechanism: Lua
  `player:SetWorldPos` through the console `ExecuteString` transport this
  project already uses. Applied exactly, in both menu states, reversibly.
- **Option (3) does not apply.** A bypass exists.

### What option (2) does and does not buy — read before scoping Phase 1

Position writes work. That is not the same as "you can strafe with your bags
open," and the gap is the whole of Phase 1's risk:

- **A position write teleports; it does not locomote.** No animation state, no
  ground snapping, no collision, no velocity. Driving it at 20 Hz would look
  like sliding, and the character controller re-asserts itself when the menu
  closes.
- **There is no input source to drive it from.** 0.2 showed the movement keys
  are rerouted into a UI action map the moment a menu takes focus — to
  `focus_prev` (inventory) or to menu navigation that never reaches Lua at all
  (pause menu). The mod cannot ask the game "does the player want to move
  forward" while a menu is open. Repurposing `focus_prev` would work
  mechanically but every step forward would also move the inventory cursor.
- **Camera yaw is equally unavailable**, so "forward" has no direction.

### The one path that could actually deliver the feature

Not attempted this session, and not recommended without an explicit decision,
but every ingredient is already proven on this project and it sidesteps the
action-map problem entirely:

1. **Read raw keyboard state natively.** `GetAsyncKeyState` from the injected
   `KCDMP.dll` never touches the game's action map, so menu focus is
   irrelevant to it. This is the piece the WO's framing did not consider —
   input does not have to arrive through the game's routing.
2. **Write position on the native main-thread tick.** WO-11 §0.3 proved the
   IAT-hooked `C_ModulesManager::Update` keeps executing during menus, and
   0.4 here proves position writes are accepted during menus.
3. **Reuse the ghost system's ground-snapping** for the crude locomotion.

The honest cost: this is reimplementing player locomotion by hand, against a
character controller that will fight it, for the payoff of moving while a menu
is open. That is a real feature but a large and fragile one, and it is a
judgment call rather than a research question.

**Stopping here per the WO's instruction to report before Phase 1.** Phase 1
was not pre-planned and depends on this gate; the three candidate scopes are
(a) close it as researched, (b) build only the input-free subset that option
(2) supports cleanly today — queued/tethered repositioning while a peer is in
a menu, no input needed — or (c) the native raw-input path above.
