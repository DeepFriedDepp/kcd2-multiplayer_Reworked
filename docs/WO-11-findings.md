# WO-11 Phase 0 findings — pause/menu world-halt mechanism

Investigated 2026-07-31 against the live, currently-running KCD2 Modding Tools
build (`KCDMP_wo10verify` copy of `KCDMP.dll`, injected, pipe/sampler live
throughout). Evidence discipline: observed / read-but-unrendered /
inconclusive, per the WO's instruction.

**Verdict: (B) — a time-scale control exists. No true veto (A) was found or
is needed; (C) does not apply.**

---

## 0.1 — export sibling search (no game needed)

`dumpbin /exports` against every catalogued module DLL —
`PlayerModule`, `CrySystem`, `RPGModule`, `WHGame`, `GUIModule`,
`EntityModule`, `XGenAIModule`, `XBehaviorModule`, `Framework`, `Shared`,
`CombatModule` — grepped for `Pause|TimeScale|WorldTime|SetPause|
FixedTimeStep|GamePause|PauseGame|SetTimeScale|t_scale|TimeStep`.

**Negative, real.** The only match anywhere is the already-known
`?SetPauseWorldTime@C_Dice@playermodule@wh@@QEAAX_N@Z`. `XGenAIModule`
has `s_CombatSimulatorGameData_movementTimeStep` and
`s_CrimeTrespassEscalation_pauseEscalationTimestamp`, but these are the
already-documented behaviour-tree data-table glue (`C_TypeLibrary` static
members with matching `_name` companions), not callable controls — same
pattern as everything else in that DLL's 1,804 exports. No sibling of
`SetPauseWorldTime` exists on any name-addressable surface. **No candidate
for a second inline hook.**

## 0.2 — live instrumentation of the existing hook, human at the keyboard

The dice pause hook (`native/KCDMP/dice_hook.cpp`) was already installed and
live in the running game (confirmed in `kcdmp-native.log`:
`DICE: hook installed at ...PlayerModule.dll+0x372D40`). With the human
playing normally, three real transitions were triggered, one at a time:

- opened **inventory**
- opened the **system/pause menu**
- triggered a **tutorial popup** (the game's own first-time dice tutorial,
  encountered by sitting down at a table for the first real game)

**Zero `DICE: C_Dice instance captured` lines across any of them** — grepped
the full session log, only the two install-time lines exist. This extends
WO-6's finding (which showed zero captures across real dice play itself) to
inventory, the pause menu, and a tutorial popup as well. **Photo mode was not
tried this session** — not blocking, since 0.1 already shows no sibling
export exists for a hook to generalize to in the first place, and the
question 0.2 was really answering (does *this* hook fire outside dice) is
already answered: no, for every state tried, including dice.

**Reading: (A) is closed, not just for dice (WO-6) but for every ordinary
pausing UI state tried.** There is no reachable veto/override point on this
name-addressable surface, full stop — not "closed for dice, open for menus."

## 0.3 — does the tick actually halt? (checked as a side effect of 0.2, not a separate live session)

Rather than a fresh probe, this reused data already being collected:
`dice_hook.cpp`'s `sample_instance_if_changed()` runs on
`main_thread::post_repeating`, which only fires when the IAT-hooked
`C_ModulesManager::Update` tick itself executes. It logs `SAMPLE: tracking
N souls within 60 m` on a ~3 s cadence for as long as the tick is alive.

Analyzed the full session log (1,648 `SAMPLE` lines, spanning the whole play
session including the three 0.2 transitions): **max gap between consecutive
samples was 3.10 s — no stall, ever.** The native main-thread tick did not
halt during inventory, the pause menu, or the tutorial popup.

**This is a real, positive measurement, not an assumption**, but it answers
a narrower question than "does world time advance": it shows the specific
hook point this plugin's marshalling rides on kept executing. It does not by
itself prove NPCs kept moving or that no downstream system froze — only that
this tick, and anything driven off it (including whatever a future
broadcast-on-pause-state message would ride on), stayed alive. Given (B)
below is a confirmed, working answer regardless of how this resolves, this
was not chased further with a dedicated GameTime-advancement probe.

## 0.4 — time-scale fallback, checked independently via the live debug REST API

`GET /api?depth=1` (already known) includes a `System` root not previously
walked in this project. `GET /api/System?depth=1` shows a `Console` child
(`XConsole`), itself empty at `depth=1` — same "registered type, zero
reflected properties" shape as `C_UIDice`/`XConsole` generally, a dead end
for RTTR reflection specifically.

But `docs/kcd2_lua_api.md` already documents two REST paths that are not RTTR
reflection at all — a direct bridge to the engine's `IConsole`/CVar system:

```
GET /api/System/Console/GetCvarValue?name=...
GET /api/System/Console/ExecuteString?command=...
```

Probed a list of plausible time-scale/pause CVar names. **Negative control
confirmed first**: a nonexistent name (`cl_timeScale`, `g_pauseGame`, etc.)
returns an empty `<string/>` element, not an error — same discipline as
`rttr::type::is_valid` returning false for a bogus type name.

**`t_scale` exists, live, and reads `1`:**

```
t_scale       = 1
t_FixedStep   = 0
(everything else tried: empty / not registered)
```

This is CryEngine's standard global simulation time-scale multiplier (used
across CryEngine titles for slow-motion effects) — a real, well-understood
engine primitive, not a guess or a name coincidence.

**Verified writable, round-tripped, immediately restored:**

```
before                          : t_scale = 1
ExecuteString "t_scale 0.3"     : (void)
read back                       : t_scale = 0.3
ExecuteString "t_scale 1"       : (void)
read back                       : t_scale = 1
```

**This is a real (B): a genuine, reachable, writable time-scale control.**
No inline hook, no offset, no fragile technique — a documented REST path
this project already knew about but had not pointed at `System/Console`
before. Whether the same CVar is reachable from Lua's `System.SetCVar`
surface was not separately re-tested — CVars are a single engine-global
table, not per-binding state, so there is no reason to expect it would
behave differently there, but this was not directly observed this session.

---

## R-gate: Tier verdict

**(B) — time-scale control found; (A) fully closed; (C) does not apply.**

- **(A) closed, cleanly, for the full set of UI states this project's
  own WO asked to check** (inventory, system/pause menu, tutorial popup,
  and — from WO-6 — dice itself). No sibling exported symbol exists anywhere
  in the catalogued DLLs (0.1), and the one real hook this project has never
  fires outside its own installation log line, for any of those four states
  (0.2). Photo mode is the one state not directly tried; low priority to
  chase given 0.1 already shows no second export exists to hook regardless
  of which UI state might use it.
- **(B) is real and already verified working**, independent of 0.1-0.3:
  `t_scale`, read and written through `/api/System/Console/{GetCvarValue,
  ExecuteString}`, exactly the mechanism the WO's fallback design needs —
  remote clients can apply (and restore) a time-scale reduction on receipt
  of a broadcast pause-state message.
- **(C) does not apply.** A working, verified mitigation exists; this is not
  a closed dead end the way aggro injection or `SetParent` are.

## Recommendation for Phase 1

> ## ⚠ SUPERSEDED 2026-07-31 by WO-13 — do not build or resurrect this
>
> **What is retired: the broadcast-slowdown *response* below** — every
> receiving client dropping its own `t_scale` for as long as any peer reports
> paused.
>
> **Why:** it is correct for two players and wrong at any real size. The design
> penalises the whole session for one person's menu — in a 20-person session,
> one player opening their inventory would visibly slow the other nineteen.
> There is no version of "slow everyone else down" that scales, so this is
> retired outright rather than tuned.
>
> **What survives, and is still true:**
> - **§0.4's `t_scale` finding is real and unretracted.** A writable global
>   time-scale CVar, reachable through `/api/System/Console/{GetCvarValue,
>   ExecuteString}`, round-tripped live. Only the *use* below is retired, not
>   the capability. It has no caller today.
> - **The addendum's `kcd.log` detection markers are still in use** — WO-13
>   keeps them as the local menu-state signal.
> - **The 0x1C/0x1D packets still exist**, repurposed by WO-13 as a pure
>   presence signal: a peer in a menu gets an "[in menu]" tag on their ghost's
>   nameplate. Nothing a receiver does touches its own simulation any more.
>
> **What WO-13 found the real bug to be:** `Script.SetTimer` halts while your
> *own* menu has focus (WO-12 §0.3), which stops `KCD2MP_InterpTick` and
> freezes every other player's ghost on *your* screen. That is local rendering,
> not shared simulation — the opposite end of the problem from the one this
> section was aimed at. See `docs/WO-13-findings.md`.
>
> The original reasoning is kept below unedited, because the Phase 0 evidence
> it rests on is sound and only the design conclusion was wrong.

Build the (B) path per the WO's Phase 1 instructions: broadcast local
pause-state enter/exit over the existing session/relay transport (same
shape as other presence broadcasts, next free wire-protocol byte per
`docs/PROJECT-STATE.md` is `0x1C`), remote clients apply `t_scale` reduction
via `ExecuteString`/`GetCvarValue` while active and restore on exit, plus a
manual `mp_slow_time`-style console command for when automatic detection of
the local pause state proves unreliable. Detecting *when* the local player
has entered one of inventory/pause-menu/tutorial/dice — since none of them
trip a native hook — will need to come from a different, cheaper signal
(the existing UI-state Lua/UIAction surface, not a new native hook); that
detection question is separate from and downstream of this Phase 0 report.

Stopping here per the WO's instruction to report before Phase 1.

---

## Addendum — detection signal found, closes the open sub-question above

The "how do we detect entry into a pausing state" question above was flagged
as unresolved and downstream of this report. It turned out to be cheap to
settle in the same session, with `log_Verbosity` raised to 4 (from its
default of 3) via `ExecuteString`, no native hook involved.

Diffed `kcd.log` across a human-triggered pause menu + inventory + a 2-hour
in-game skip-time. Real, human-in-the-loop test, not a guess:

**Menu open/close** — a matched audio + RTPC tag pair, present exactly once
per transition:

```
PlayAudio: MenuOpen
Playlist tag RTPC 'sqc_ptag_menu' will be 1.000000
...
PlayAudio: ui_menu_close
Playlist tag RTPC 'sqc_ptag_menu' will be 0.000000
```

**Inventory specifically** — its Flash element loads on open, distinguishing
it from the pause menu:

```
[Warning] <Flash> Warning: ExternalInterface.call - handler is not installed. [Libs/UI//ApseInventoryList.gfx]
```

**Skip-time (sleep/wait/bed)** — a readiness observer brackets the entire
skip, start to finish, cleanly:

```
Readiness observer 'AfterSkipTime' with category bitmask '16273' started async waiting
... (world-sim churn while the skip resolves)
Readiness observer 'AfterSkipTime' with category bitmask '16273' is ready
```

Tutorial popups and photo mode were not re-tested against this specific
diff, but the mechanism (`kcd.log` under raised verbosity) is generic —
worth a quick grep for their own marker lines rather than assuming absence.

**This means detection needs no new native hook at all.** WO-1's already-
proven log-tail transport (the same one carrying position/yaw) can watch for
these lines exactly as it watches for `[KCD2-MP-DATA]`. `log_Verbosity`
itself is a one-time `ExecuteString` at startup, same call already proven
against `t_scale` in §0.4. Phase 1's local-pause detection is therefore not
a research item — it is ordinary plumbing on an existing, working transport.
