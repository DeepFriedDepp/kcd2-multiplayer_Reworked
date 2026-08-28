# WO-73 progress — making the headless world tick

Session 2026-08-28, continuing straight from WO-72. Evidence classes as before:
**observed** (a live run), **code-verified** (decompiler/disassembler, or a
shipped generated reference, with the source named), **inferred** (flagged every
time).

Experiment code lives in `native/experiments/wo73_worldtick/` (new directory;
the WO-72 probe is reused unchanged as the early-cvar mechanism). No product
code was touched and no file inside the game install was modified.

---

## Where WO-72 left it

A CPU-only instance boots to `Entering game loop` on WARP and answers REST on
`:1403`, but **no world had ever been loaded**. `Calendar.GetWorldTime()` read
`0`, and WO-72 §1b closed four load routes as dead ends, concluding that "there
is just no Lua entry point that loads a *named* save" and that the remaining
candidates were UIAction name discovery or a native `C_Game::OnLoadGame` call.

## Phase 0 — the route that was never on the list

Route 0 as briefed (make a quicksave on a GPU boot, then `Game.QuickLoad()` on
WARP) was not needed, because a cheaper route turned up first.

The game install ships **`ConsoleHTMLHelp/`** — 46 HTML files, a complete
generated reference for every console command and cvar in this exact build,
including flags and help text. Nothing in WO-71/72 had read it. Grepping its
command index for load-related names produced, in one pass:

| name | shipped help text | flags |
|---|---|---|
| `wh_sys_LoadGame` | *"Loads save specified by playline number and file name"* | none |
| `wh_sys_AutoLoadLastSave` | *"Newest game is auto loaded on game start"* | `REQUIRE_APP_RESTART` |
| `wh_sys_TestLoadGame` | *"Loads test quick load. Non-master configuration only"* | none |
| `wh_sys_SwitchLevel` | *"Switches to level according to param (level ID, keepFadedOut)"* | none |
| `wh_ui_PauseGameOnFocusLoss` | *"Pause game when player switches focus to another window. Default true."* | none |
| `wh_game_pauseDebug` | *"Shows info about game pause sources."* | none |
| `wh_game_unpause` | *"Debug command to unpause game for developers."* | none |

`wh_sys_LoadGame` is the named-save load entry point WO-72 concluded did not
exist. It is a shipped console command with **no flags** — not `RESTRICTEDMODE`,
not `DEPRECATED` — so it is callable over the same `:1403` REST console the mod
already uses. Routes 1 (UIAction name discovery) and 2 (native `OnLoadGame`)
were therefore never needed and were not attempted.

Why WO-72 missed it: it swept `DumpVars`, which dumps *variables*. `map` and
`wh_sys_LoadGame` are *commands*. The generated reference lists both.

### Confirming it live

`wh_sys_LoadGame` with no arguments answered from the game's own validator
(**observed**):

```
[CONSOLE] Executing console command 'wh_sys_LoadGame'
[Error] Load command - wrong number of arguments.
```

and with arguments it drove a real level load through
`LEVEL_LOAD_PREPARE → … → LEVEL_LOAD_OBJECTS → LEVEL_LOAD_CHARACTERS →
LEVEL_LOAD_STATIC_WORLD`, ending in a populated world: **1494 souls, 22619
entities** on the REST/Lua surface.

The playline argument is the **on-disk directory index**, not the UI's 1-based
number: the save the launcher shows as "Playline 2" lives in
`%USER%/saves/playline1/`, and `wh_sys_LoadGame 1 exit` is what loads it. The
file argument is the basename, without `.whs`.

## Phase 2 — the tick, and the trap that nearly buried it

The first save loaded (a tutorial-mission save) produced this, stable across
three minutes:

```
gameTime=1172  worldTime=239400  day=2 hour=18.5 ratio=15 paused=true
gameTime=1214  worldTime=239400  day=2 hour=18.5 ratio=15 paused=true
```

`GetWorldTime()` frozen — which, read alone, is exactly what a failed load looks
like, and is what this WO's acceptance criterion is written against. It was not
a failed load. The shipped scriptbind reference
(`Tools/modding/docs/script_bind/.../C_ScriptBindCalendar`) documents **two
different clocks and an explicit pause flag**:

* `GetGameTime()` — *"whole seconds from start of level"*, the simulation tick.
* `GetWorldTime()` — *"whole seconds from start of level"* of **world** time,
  which runs at `GetWorldTimeRatio()` (15× here).
* `IsWorldTimePaused()` — *"Returns true if world time is paused."*

`gameTime` was advancing 1:1 with real time the whole while: the world was fully
alive. The in-world **clock** was paused, and quests pause it — this save sat
inside a tutorial mission. Neither `wh_ui_PauseGameOnFocusLoss 0`, nor giving the
window focus, nor `wh_game_unpause`, nor `Calendar.SetWorldTimePaused(false)`
lifted it; the quest re-asserts it. Loading a non-tutorial save cleared it
immediately.

**Do not read a frozen `GetWorldTime()` as a dead instance.** Read
`GetGameTime()` and `IsWorldTimePaused()` in the same breath. The harness now
always reads all three.

## Traps found this session

- **A save lock taken at the menu does not survive `wh_sys_LoadGame`.**
  `Game.AddSaveLock("name","desc")` was applied before the load and logged
  (`Adding script save lock 'WO73'`); the load ran; a checkpoint autosave landed
  anyway (`[SAVE GAME] Quick-saving to '…/autosave004.whs' immediately ignoring
  delay`). Take the lock **after** the world is up, and read it back.
  `Game.AddSaveLock` takes two **string** arguments — calling it bare raises
  *"expect parameter 1 of type String (Provided type Null)"*.
- **`wh_game_pauseDebug` is a cvar, not a command.** Invoking it bare prints its
  value; its pause-source report is debug-draw, not log output.
- **The game mirrors its whole log to stdout.** Launched with an inherited
  stdout it floods the caller's transcript. Redirect to a *file* (not a pipe —
  nothing drains it, and a full pipe blocks the game).
- **`r_overrideDXGIAdapter` is `REQUIRE_APP_RESTART` but NOT `DUMPTODISK`**, so
  it cannot persist. `r_HeadlessStartup` **is** `DUMPTODISK`, and so are
  `r_Width` / `r_Height` — the small-render-target row is therefore a
  *persistence* risk on this machine, not just the adapter override. WO-72
  described both cvars as DUMPTODISK; only one is.
- **The default render target on this box is 1704×959, not 1920×1080.** The
  probe reports it when overriding: `early cvar r_Width: was 1704, set 320`.
  WO-72's idle measurement is labelled "full 1920×1080"; it was not.
- **Mid-load the instance reports `worldTime=118800, ratio=0, gameTime=0`** — a
  transient that is *not* a loaded world. An acceptance check of "worldTime is
  non-zero" fires on it and reports a load roughly 2× too fast. Require
  `ratio != 0` and `gameTime != 0` too. (This bug was live in the harness for
  one run; that run's reported load time was discarded and the state-machine
  sum from `kcd.log` used for every row instead.)
- **A `tail -f` on the run report from Git Bash locks the file** against the
  script's own `Add-Content`, killing the run with an `IOException`. Poll with
  `cat`, don't tail.
- Dot-sourcing a library that sets `Set-StrictMode` imposes it on the calling
  session and breaks unrelated tooling. Don't.

## The throttle that makes the cost table readable

Both the GPU and WARP instances run **unfocused** for the whole measurement, and
KCD2 caps the frame rate when it is. The mechanism is shipped and named
(`ConsoleHTMLHelp`, **code-verified**):

```
sys_MaxFPS            0 = on PC if vsync is off auto throttles fps while in
                      menu or game is paused (default)
sys_MaxFPSThrotteled  The FPS limit that applies when sys_MaxFPS is set to 0
                      and the game is in menu, loading screen or unfocused
```

This matters for reading the table honestly. The GPU control column's
**0.17 cores** is not "the cost of simulating this world" — it is a
frame-throttled instance comfortably hitting a low FPS cap. The right comparison
is not "WARP costs 45× the GPU"; it is that **both are asked for the same
throttled frame rate, the GPU meets it at 0.17 cores, and WARP misses it by ~55×
while spending 7.6 cores trying.** A headless host is always unfocused, so this
throttle is always in play — it is a deployment advantage that WARP still cannot
exploit.

## Two WO-72 numbers that did not reproduce

- **"~7× the CPU to boot on WARP" did not reproduce.** Measured to the debug API
  answering, from a cold process, on the same build: GPU **34.4 s wall / 15.5
  CPU-s**, WARP **34.2–36.3 s wall / 25.9–26.2 CPU-s**. That is ~1.7× the CPU
  and essentially identical wall time, not 7×. Two differences from WO-72's
  measurement: it timed to `Entering game loop` rather than to the API, and its
  WARP boot was the first ever on this machine, so the D3D12 pipeline cache
  (`Saved Games/kingdomcome2/shaders/cache/d3d12/pipelinecache.dat`) was cold.
  The cold-cache explanation is **inferred**, not tested — but the ~7× figure
  should not be carried forward without re-measuring.
- **"full 1920×1080" was 1704×959.** See the trap above.

## Runs performed

Five live runs, every one hard-killed, every one verified after:

| # | config | outcome |
|---|---|---|
| 1 | GPU, exploratory | Found `wh_sys_LoadGame`'s argument shape; hit the tutorial-save world-time pause; ruled out focus/cvar/unpause as its cause. Loaded two saves in one process, so its cost numbers were discarded. |
| 2 | WARP, 1704×959 | World loaded and ticked. Script died mid-run to a self-inflicted file lock; the instance was unaffected and driven manually. 0.018× real time, 7.8 cores. |
| 3 | WARP, 320×240 | Cost captured (7.62 cores) but the tick rate was lost to the log-tail and short-wait bugs. Rate discarded, re-run as #5. |
| 4 | GPU, control + features-off | Clean control column: 1.003× real time, 0.17 cores. |
| 5 | WARP, 320×240, + features-off *after* load | Clean: 0.061× real time, 6.88 cores. The features-off half was invalid — see below. |
| 6 | WARP, 320×240, features-off *before* load, + NPC motion | Clean: 0.067× real time, 6.4 cores. Closed both remaining gaps. |

Runs 3 and 5 disagree slightly on cores (7.62 vs 6.88) for nominally identical
configurations — a ~10% run-to-run spread on this machine. Both are reported.

### Why run 6 was needed

Run 5 was declared finished, and it was not. Two things were wrong with it:

1. **The features-off measurement was taken the wrong way round.** Six render
   cvars were toggled on an *already-loaded* world and sampled for 90 s
   immediately after. Toggling `e_Vegetation`/`e_Shadows` at runtime forces asset
   and render-resource churn, so the sample measured the disruption, not the
   configuration — and it spanned 2 whole game-seconds, ±25% quantisation on its
   own. It read as "features-off made it 3× slower", which is false. Run 6 sets
   the same six cvars **at the menu, echoed back as `= 0` before
   `wh_sys_LoadGame`**, so the world loads with them off: **6.88 → 6.40 cores,
   0.061 → 0.067×, load 202–224 s → 169.8 s.** Marginal, real, and in the
   opposite direction to the artifact. **Runtime cvar toggling is not a valid way
   to measure a render configuration on this engine.**
2. **Simulation evidence had only ever been collected on the GPU.** The WO asks
   for an NPC position change *or* an AI log line, and the GPU run had both
   (`tvez_man_22`, 18 m in 25 s). WARP had neither — only the clock. Run 6 added
   a positional probe and captured the AI-log alternative.

The positional probe also carried a trap worth recording: the NPC names were
initially copied from the *tutorial* save, and those entities do not exist in
this one. `System.GetEntityByName` returns nil for an absent name, which the
probe would have rendered as "did not move" — a false negative indistinguishable
from a frozen world. Names must come from the loaded save's own log lines. With
correct names the six returned real coordinates and were genuinely unchanged over
~14 game-seconds, which is an underpowered window, not a finding.

## Safety discipline actually run

- Full copy of `Saved Games/kingdomcome2/{saves,profiles}` (200 files) taken
  before anything loaded, with an MD5 manifest, and re-compared after each run.
- Every run **hard-killed**, never allowed a clean shutdown.
- `system.cfg` MD5 `11583718DD1B14712A7AFE5B304C3DDA` verified unchanged after
  each run; no `user.cfg` created. **Observed clean after every run.**
- One unintended write occurred and is accounted for above
  (`playline3/autosave004.whs`, a new file; no existing save was modified).
