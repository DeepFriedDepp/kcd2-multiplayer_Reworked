# WO-12 progress — local player movement while a menu has focus

2026-07-31. Branch: `main`. Read `docs/WO-12-findings.md` first — this is the
session log for the Phase 0 that produced it.

---

## Status: Phase 0 complete, stopped at the 0-gate. Nothing built.

Verdict is the WO's **option (2)** — input is dropped from movement, direct
position writes work as a bypass. Phase 1 was not pre-planned and depends on
this gate, so nothing was implemented and no code was changed.

**Files added:** `docs/WO-12-findings.md`, `docs/WO-12-progress.md`.
**Files modified:** none. No `.lua`, `.cs`, `.cpp` or test-script changes.

---

## How it was investigated

| Step | Method | Needed the human? |
|---|---|---|
| 0.1 | `dumpbin /exports` across all 44 game DLLs, cached to scratch, grepped for the WO's pattern list and then a much wider self-chosen set | no |
| 0.2 | `KCD2MP.logActions` + an additional **unfiltered** `OnAction` logger installed live via `ExecuteString` | yes, 3 runs |
| 0.3 | REST `/api/rpg/SoulList/SoulsByName/Dude/Position` polled at ~3.3 Hz by an external watcher | yes, 1 run |
| 0.4 | Watcher auto-detected each menu and fired the position write itself | yes, 1 run |
| 0.5 | not run — see findings, the gate for it was not met | — |

All instrumentation was installed into the **already-running** game through the
debug console; nothing was rebuilt, re-injected or restarted, and the user's
`KCDMP_launcher` / `KcdMpServer` / game processes were untouched throughout.

## Two instrument failures worth recording

Both were caught by checking the instrument rather than trusting its output,
and both would have produced a confidently wrong finding.

1. **The mod's own action logger hides movement.** `handleAction`
   (`kdcmp.lua:3588`) returns early on `AXIS_ACTIONS`, which is exactly the
   family movement would arrive in. Run A's data was therefore blind to the
   thing under test. Fixed by layering a second, unfiltered logger on top of
   `Player.OnAction` / `Player.Client.OnAction`.

2. **The Lua position sampler halts during menus.** A 10 Hz
   `Script.SetTimer` sampler produced beautiful "position never changed
   during the menu" data. It was not observing stasis — it was not running.
   Caught by checking sample-index continuity across the menu markers
   (`s=1311` → `s=1312` spanning ~10 s of real time), not by looking at the
   values. Re-measured on the REST channel, which is unaffected.

The second one also produced a real finding in its own right: **`Script.SetTimer`
callbacks are gated by menu focus, so `KCD2MP_InterpTick` halts whenever the
local player opens a menu.** Out of scope for this WO but directly relevant to
WO-11's design — flagged, not chased.

## Incidental findings, recorded because they outlive this WO

- **`Player.Client.OnAction` is dead code in this build.** Zero callbacks
  arrived through it across every run; everything came via `Player.OnAction`.
  The hooks at `kdcmp.lua:3673` and `:3683` never fire. Harmless, but it means
  the "x2" in `[KCD2-MP] Player hooks OK (OnInit + OnAction x2)` is really x1.
- **Movement input never reaches the Lua `OnAction` surface at all**, menu or
  no menu. It is consumed below the script layer during ordinary play.
- **The Lua VM is alive during menus even though its timer scheduler is not.**
  `ExecuteString`-driven statements execute immediately with a menu open.
- **The console/CVar path works during menus** — `t_scale` round-tripped
  `1 → 0.77 → 1` inside both the pause menu and the inventory. WO-11's
  response mechanism is unaffected by menu focus.
- **The CryEngine input layer is not name-addressable in this build.**
  `CryInput.dll`, `CryAction.dll`, `CryScriptSystem.dll` and `GUIModule.dll`
  export nothing but accidental `boost::optional<bool>` template
  instantiations. Worth remembering before any future WO plans to hook input.

## Verification / cleanup

No suites were run: nothing native, nothing in `dotnet/`, and no test script
was touched, so `Test-Combat` / `Test-Sessions` / `Test-Dice` / `Test-Pipe`
exercise nothing this session changed. Running them would have been a
checkbox, not a check.

Live-state cleanup, all confirmed by read-back rather than assumed:

```
player position : 2353.5652, 2145.8799, 118.04451   (exact original, restored)
t_scale         : 1
[WO12] probe    : disabled -- 0 sampler lines in the last 40 KB of kcd.log
KCD2MP.logActions : false
```

The player was deliberately moved during 0.4 (+1.5 m baseline, then +2.0 m
twice inside menus) with the user at the keyboard and forewarned; every move
was reverted.

One residue that cannot be undone without a game restart: the extra
`Player.OnAction` wrapper installed for 0.2 is still in the call chain. It is
gated behind `KCD2MP_WO12.alog`, which is now `false`, so it does nothing but
a boolean test per callback. It disappears on the next game restart.

## What Phase 1 would need a decision on

Three candidate scopes, in the findings doc's closing section:

- **(a) Close it as researched.** A complete, valid outcome — the question is
  now answered either way.
- **(b) Build only what option (2) supports cleanly today** — input-free
  repositioning (queued teleport, tether-to-peer) while a player is in a menu.
  Small, uses only proven mechanisms, but is not "strafe with your bags open."
- **(c) Native raw-input path** — `GetAsyncKeyState` in the injected DLL
  (immune to the action-map rerouting that 0.2 found) driving a position write
  on the main-thread tick that WO-11 proved keeps running. The only route to
  the actual feature, but it means hand-rolling locomotion against a character
  controller that will fight it.

Stopped here per the WO's instruction to report before Phase 1.
