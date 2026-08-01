# WO-13 findings — retiring the broadcast slowdown, and the real ghost-freeze bug

Investigated and built 2026-07-31 against the live KCD2 Modding Tools build,
with a human at the keyboard for every visual confirmation. Evidence
discipline: observed / read-but-unrendered / inconclusive, as in WO-11/WO-12.

---

## Phase 0.1 — the broadcast slowdown was **already built**, not just proposed

The WO's expected result was "nothing, it was only ever a WO-11 proposal,
never implemented." **That is wrong, and it was checked rather than assumed.**

A real grep across the wire protocol and both the client and server projects
found a complete, working, tested implementation sitting uncommitted in the
working tree — roughly 370 added lines across 9 files:

| File | What was there |
|---|---|
| `Protocol.cs` | `PauseUp 0x1C`, `PauseDown 0x1D`, `PausedPeerTimeScale = 0.3f`, and `Version` bumped **5 → 6 specifically for this feature** |
| `ClientSession.cs:176` | accepts `PauseUp`, exact-length validated |
| `TcpBroadcastService.cs:104` | `BroadcastPause` — forwards to every other ready client |
| `GameBridge.cs` | `ApplyPeerPauseAsync` → `SetTimeScaleAsync(0.3f)` on receipt; `_pausedPeers` edge tracking; disconnect restore |
| `LogTailGameTransport.cs` | `ProcessPauseMarkers` — `kcd.log` detection |
| `HttpGameTransport.cs` / `IGameTransport.cs` | `SetTimeScaleAsync` |
| `kdcmp.lua:3440` | `mp_slow_time` console command |
| `tools/Test-Pause.ps1` | 10 relay-level tests, all passing |
| `Test-Combat/Dice/Sessions.ps1` | version pins bumped to 6 *only* because of this |

`docs/WO-11-progress.md` documents it as built and live-verified, including a
real `t_scale 1 → 0.3` round trip against the running game.

So "retire it" meant **deleting working code**, not confirming an absence.
That was taken back to the user rather than decided unilaterally, and the
chosen scope was: **kill the response, keep the signal.**

## Phase 0.2 — a player's own game can no longer slow because someone else paused

Two independent confirmations.

**Static — there is no longer any code that can do it.** `SetTimeScaleAsync`
was removed from `IGameTransport`, `HttpGameTransport` and
`LogTailGameTransport`; `PausedPeerTimeScale` was deleted from `Protocol.cs`.
A search of every `.cs` and the mod's `.lua` for `t_scale|SetTimeScale|
PausedPeerTimeScale` now returns **four hits, all of them prose in doc
comments explaining the retirement — zero executable references.** Nothing in
the codebase can change the local time scale any more.

**Live — an actual peer-paused cycle changed nothing.** During the Phase 1
verification below, a synthetic peer sent `PauseUp(entered)`, the relay
forwarded it, and the real agent logged `[menu] ghost 9 entered a menu`. The
peer then sent `PauseUp(exited)`. `t_scale` read **`1`** afterwards, having
never been written.

This is evidence, not architecture-by-assertion: the packet demonstrably
arrived and was acted on, and the action was a nameplate tag rather than a
simulation change.

## Phase 0.3 — WO-11's recommendation marked superseded

`docs/WO-11-findings.md`'s "Recommendation for Phase 1" now carries a dated
superseded banner explaining that broadcasting a slowdown to everyone
penalises the whole session for one person's menu. **The original reasoning is
kept unedited below it**, and the banner explicitly preserves what is still
true: §0.4's `t_scale` finding is real (it just has no caller), the addendum's
`kcd.log` markers are still in use, and 0x1C/0x1D still exist.

---

## Phase 1.1 — is there any Lua scheduler that survives a local menu? No.

Checked against Warhorse's own shipped scriptbind reference
(`Tools/modding/docs/script_bind/script_bind.zip`, 5,014 pages) before
guessing, then tested live. Three candidates, all closed:

**(a) `Script.SetTimer`'s undocumented-in-our-code 4th parameter.** The
reference documents:

```
Script.SetTimer( nMilliseconds, luaFunction [, userData [, bUpdateDuringPause]] )
    bUpdateDuringPause  (optional) will be updated and trigger even if in pause mode.
```

`kdcmp.lua` only ever passed two arguments, so this looked like a one-line
fix. **It is inert in this build.** Three timers were run side by side —
plain, `(…, nil, true)`, and `(…, table, true)` — across a real ~10 s
inventory window: plain went **421 → 422**, and *both* flagged variants also
went **421 → 422**. Identical. Same shape as `System.DrawTriStrip`: documented,
not honoured. (Consistent with WO-11 §0.2 — a menu is not the engine's "pause"
state, so the flag has nothing to key off.)

**(b) Entity `OnUpdate` via `Activate(1)`.** A probe entity was spawned,
`e.OnUpdate` assigned, `e:Activate(1)` called — returned true, and
`type(e.OnUpdate)` read `function` afterwards. The counter stayed at **`uf=0`**.
Never called, *with no menu open at all*.

**(c) Entity `OnTimer` via `Entity.SetTimer`.** `e:SetTimer(0, 200)` returned
true. **Zero callbacks**, again with no menu open.

(b) and (c) fail in ordinary play, so they are not schedulers in this build
regardless of menus. 1.1 is a clean negative and forces 1.2.

## Phase 1.2 — what was built, and a deliberate departure from the WO

**The WO said to move ghost updates onto the native tick. That was not done,
and the reason is a flaw in its stated justification.**

The WO argued "RTTR reflection writes are proven extensively… not new
capability, just a new use of it." That conflates two different surfaces.
Soul *property* writes are proven — `rpg` is richly reflected. But ghosts are
`AnimObject` **entities**, and `docs/NATIVE-PLUGIN-findings.md` records the
`ent` module as **three properties and no methods**. Writing an entity
transform from C++ is not a proven capability on this project; it is open
research with a real chance of not landing.

**What was built instead: the agent pumps the existing tick from outside.**
This rests entirely on something WO-12 already proved — §0.4 showed an
`ExecuteString`-driven Lua statement executes immediately while a menu has
focus and `Script.SetTimer` is frozen (the write marker appeared in the log
while the timer index was stationary). The agent is already connected and
already parses the menu markers, so the whole fix is:

- `kdcmp.lua`: `KCD2MP_InterpTick(arg)` skips its self-reschedule when called
  with the sentinel `"ext"` (compared against the sentinel, not tested for
  truthiness — `Script.SetTimer` passes a *truthy timer id* as argument 1).
  Without this, every pumped call would queue a timer that fires as one burst
  when the menu closes.
- `KCD2MP_InterpPump()` = `InterpTick("ext")` + `KCD2MP_ApplyHorseTransforms()`.
- `GameBridge`: starts/stops the pump on the local menu signal, using a new
  unbatched `IGameTransport.ExecuteNowAsync` (which replaced the retired
  `SetTimeScaleAsync`).

### Scope of the fix, stated plainly

**Moved onto the pump — everything `KCD2MP_InterpTick` does:** dead-reckoning,
position lerp, the >5 m teleport guard, floor-snap raycasting, on-foot
animation selection, riding/gallop animation, horse transform application, and
the label *cache* update.

`KCD2MP_ApplyHorseTransforms` had to be split out of `KCD2MP_LabelTick` to
achieve this. `InterpTick` only computes `horseData.render*`; `LabelTick` is
what applies it. Pumping `InterpTick` alone would have left a mounted ghost's
horse standing still while the rider slid along on top of it — precisely the
"fixed the position but it still looks broken" failure the WO warned about.

**Not moved — the nameplate/HUD drawing half of `KCD2MP_LabelTick`.**
`System.DrawLabel` and `System.DrawText` are immediate-mode: one frame per
call. The pump runs at a **measured 35–86 Hz** but is not frame-locked to the
60 fps render, so pumping the draws would strobe rather than render.
Nameplates therefore stay hidden while *your own* menu is open — which is
exactly what already happened before this change, so nothing regressed. This
fix is about ghost bodies moving.

## Phase 1.3 — reproduced first, then fixed, human at the keyboard

The A/B changed **exactly one variable**: the same rebuilt mod and the same
agent were used for both passes, with the pump disabled for Pass A by nulling
`KCD2MP_InterpPump` at runtime, so its calls became no-ops.

A synthetic peer (`tools/Bot-WalkingGhost.ps1`, new) walked a 4 m circle at
10 Hz so that "the ghost stopped" could not be confused with "the peer stopped
walking."

**Pass A — bug reproduced, and better characterised than the WO stated it.**
The human reported the ghost in the identical world position after a ~10 s
inventory, and then, on a repeat: *"I enter inventory with the bot on the
right, wait 2-3 seconds, and when exiting it snaps really fast and the bot is
on the far left."*

So the symptom is **freeze plus catch-up snap**, one cause: batched Lua keeps
executing during the menu (WO-12 §0.4), so `istate.tx/ty` keeps advancing while
the body does not move; on menu close `InterpTick` resumes, finds the target
>5 m away, and takes its teleport branch.

**Pass B — fixed, measured on both menus.** An external sampler recorded the
ghost entity's own world position throughout:

| Menu | Ghost movement *during* the menu | Distinct sampled positions |
|---|---|---|
| Inventory | **6.09 m** | 11 / 11 |
| Pause menu | **7.19 m** | 14 / 14 |

The human could only corroborate the pause menu by eye — *"The inventory is
not transparent, so I cannot tell… However, when I press pause, or ESC, I see
the bot continuing to move as if I didn't."* — because KCD2's inventory is
opaque. Eyes and instrument agree on the case where both could see; the
instrument covers the case where they could not.

For contrast, WO-12 §0.3 measured the *local player* as bit-identical across
~100 samples under the same conditions. The ghost moving 6–7 m is not noise.

## Phase 2 — in-menu indicator

`KCD2MP.ghostInMenu[id]` appends `[in menu]` to the ghost's nameplate;
`KCD2MP_SetGhostMenuState(id, bool)` is driven by the agent from the already-
received `PauseDown (0x1D)`. Cleared on `KCD2MP_RemoveGhost` so a player who
disconnects mid-menu cannot leave a stale tag on a reused ghost id.

No pose work was needed: `KCD2MP_UpdateAnimation` already settles a stationary
ghost into its idle animation.

Verified live by the human, watching the rendered nameplate while
`Bot-WalkingGhost.ps1 -MenuAtSec` made the peer stop and report a menu:
*"The bot stopped walking and showed [In Menu] next to its name. Then it
continued walking after about 20 seconds, no more In Menu next to the
nameplate."*

*(A log-based check run at the same time appeared to show the tag absent. That
was a bad instrument, not a bad result — the tail window read was too short
against a log the emitter writes to continuously. The rendered nameplate is
the thing the feature actually promises, and it was observed directly.)*

---

## Two bugs found along the way that were not in the WO

### 1. A save load permanently freezes every ghost — bigger than the menu bug

**Observed live, and it masked the bug this WO is about.** After the user
loaded a save mid-session, the ghost stood still with no menu open at all.
Diagnosis:

```
istate.tx/ty  : 2362.97,2151.83 -> 2360.06,2149.01   (updating - packets fine)
istate.cx/cy  : unchanged                            (interp not running)
entity pos    : unchanged
TICK_ALIVE    : 0 heartbeats
emitRunning   : true      <- flag says running
interpRunning : true      <- flag says running
```

**Loading a save destroys every pending `Script.SetTimer` while leaving the
`*Running` globals set.** And `KCD2MP_StartInterp` / `KCD2MP_StartEmitter`
both early-returned on exactly those flags — so once the chain died, nothing
could ever restart it. Permanent, menu-independent, and only recoverable by
restarting the game.

Fixed on both sides:
- `kdcmp.lua`: each loop stamps `KCD2MP._{interp,label,emit}AliveAt`; the
  `Start*` functions now test liveness (`tickAlive`, a 1 s staleness window)
  rather than the flag. A *pumped* `InterpTick` deliberately does **not**
  stamp, or the pump would make a dead chain look healthy.
- `GameBridge`: the position loop re-arms `KCD2MP_StartInterp()` every 250
  ticks. Now idempotent and cheap, so recovery is automatic rather than a
  restart.

### 2. The log-tail transport can be lost to one swallowed request

Observed once at agent startup: the emitter-start call did not take effect
(`emitRunning=false`), while the identical call issued by hand seconds later
worked immediately. The batched send swallows its own exceptions, so there is
nothing to catch upstream.

This matters more than a performance downgrade: `PauseStateChanged` and
`GameEvent` **only exist on the log-tail transport**, so a spurious fallback
to HTTP silently disables the local menu signal, the interp pump *and* the
`[in menu]` tag — i.e. all of WO-13. `SelectTransportAsync` now re-issues the
start once (`LogTailGameTransport.ResetEmitterStart`) before falling back.

Root cause not isolated — recorded as observed behaviour with a retry, not as
a diagnosed defect.

---

## Verification summary

```
Test-Combat.ps1   : 14 passed, 0 failed
Test-Sessions.ps1 : 22 passed, 0 failed
Test-Dice.ps1     : 10 passed, 0 failed
Test-Pause.ps1    : 10 passed, 0 failed
```

Run against an isolated relay on port 7779 (HTTP 5299) so the user's own
instance on 7778 was never touched.

**`Test-Pipe.ps1` was not run.** It deals real damage to a live NPC and needs
`KCDMP.dll` injected, which it was not after the game restart. `native/` is
untouched by this WO (`git status native/` is empty), so it exercises nothing
that changed — skipped deliberately rather than run for a checkbox.

**No `SessionManager.cs` change.** This is presence-layer work, not a paired
interaction; the only server files touched are WO-11's existing relay
forwarding, which this WO did not modify.

The mod's Lua was syntax-checked before the game was restarted, by calling
`loadfile` on the real source file from inside the running game — the engine's
own Lua 5.1 compiler, compiled but not executed, so a typo could not cost a
reload cycle.
