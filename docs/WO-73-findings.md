# WO-73 findings — does the headless world tick?

Session 2026-08-28, continuing straight from WO-72. Evidence classes:
**observed** (a live run on this machine), **code-verified** (a shipped
generated reference or a decompiler, with the source named), **inferred**
(flagged every time).

The WO asked for one number to change: `Calendar.GetWorldTime()` advancing on
the WARP (CPU-only) instance. It changed. The interesting result is what came
with it.

---

## 1. Headline

> **A save-backed world loads on the CPU-only instance and its clock runs.**
> `wh_sys_LoadGame <playline> <name>` — a shipped, unflagged console command
> that WO-72 concluded did not exist — loads a named save over the same
> `:1403` REST console, on WARP with no GPU. The loaded world ticks: world time
> advances at the configured 15× ratio with `IsWorldTimePaused()` false,
> observed repeatedly over ten minutes. **The WO's acceptance criterion is met.**
>
> **But the world runs 16–55× slower than real time.** At the default render
> target the WARP instance managed **0.018× real time while burning 7.8 CPU
> cores**; at 320×240 it managed **0.061× on 6.9 cores**. The GPU control holds
> **1.003× on 0.17 cores**. The simulation is correct and internally consistent
> throughout — the frame loop is simply gated on a software rasteriser that
> cannot close a frame fast enough (2126–2959 `WaitForFence(CPU) TIMED OUT`).
>
> So the world-load question WO-72 left open is **closed, and it was cheap**.
> The question it did not know to ask — can a CPU-only host run a world at
> wall-clock speed — is **answered no**, by a margin of more than an order of
> magnitude, and the render-target reduction expected to rescue it delivers a
> 3.4× speed-up that leaves it still 16× short.

---

## 2. The load route (observed)

WO-72 §1b closed four routes and named two expensive candidates (UIAction name
discovery; a native `C_Game::OnLoadGame` call). Neither was needed.

The game install ships **`ConsoleHTMLHelp/`** — a complete generated reference
for every console command and cvar in this exact build, with flags and help
text. It had never been read. One grep of its command index produced:

| name | shipped help text | flags |
|---|---|---|
| **`wh_sys_LoadGame`** | *"Loads save specified by playline number and file name"* | **none** |
| `wh_sys_AutoLoadLastSave` | *"Newest game is auto loaded on game start"* | `REQUIRE_APP_RESTART` |
| `wh_sys_TestLoadGame` | *"Loads test quick load. Non-master configuration only"* | none |
| `wh_sys_SwitchLevel` | *"Switches to level according to param (level ID, keepFadedOut)"* | none |
| `wh_ui_PauseGameOnFocusLoss` | *"Pause game when player switches focus to another window. Default true."* | none |

Usage, all **observed**:

```
wh_sys_LoadGame                  -> [Error] Load command - wrong number of arguments.
wh_sys_LoadGame 1 exit           -> full level load, ending in a populated world
```

* The playline argument is the **on-disk directory index**, not the launcher's
  1-based number: the save shown as "Playline 2" lives in `saves/playline1/`.
* The file argument is the basename without `.whs`.
* It works from the main menu, and also while another world is already loaded.
* Result on the GPU control instance: **1494 souls, 22619 entities** over the
  REST/Lua surface.

**Why WO-72 missed it:** it swept `DumpVars`, which dumps *variables*.
`wh_sys_LoadGame` and `map` are *commands*. The shipped reference lists both.
`wh_sys_AutoLoadLastSave` also directly contradicts WO-72's "`DumpVars` shows no
startup-load cvar", and would let a host load its world with no console traffic
at all — **untested here** (inferred to work from its help text and its
`REQUIRE_APP_RESTART` flag, which implies it is read during startup).

---

## 3. The tick — and the trap that nearly buried it

### Two clocks, not one

The shipped scriptbind reference (`Tools/modding/docs/script_bind/…/
C_ScriptBindCalendar`, **code-verified**) documents three things this WO's
acceptance criterion depends on:

| call | meaning |
|---|---|
| `GetGameTime()` | whole seconds from level start — the **simulation** tick, 1:1 with real time when the sim keeps up |
| `GetWorldTime()` | whole seconds of **in-world** time, advancing at `GetWorldTimeRatio()` (15× on this save) |
| `IsWorldTimePaused()` | *"Returns true if world time is paused."* |

The first save loaded produced a `GetWorldTime()` frozen at exactly `239400`
across three minutes — precisely what a failed load looks like, and what this
WO's success criterion is written against. It was not a failed load:

```
gameTime=1172  worldTime=239400  day=2 hour=18.5 ratio=15 paused=true
gameTime=1214  worldTime=239400  day=2 hour=18.5 ratio=15 paused=true
```

`gameTime` was advancing 1:1 the whole time — the world was fully alive, with
NPCs walking (one covered 18 m in 25 s), dialogue playing and idle-state
transitions firing in the log. The in-world **clock** was paused because that
save sits inside a **tutorial mission**, and quests pause world time.

Ruled out as causes, each **observed**:

| candidate | result |
|---|---|
| `wh_ui_PauseGameOnFocusLoss 0` | set and read back as `0`; clock still frozen |
| window focus | clock frozen with the game focused *and* unfocused |
| `wh_game_unpause` | no effect |
| `Calendar.SetWorldTimePaused(false)` | no effect — the quest re-asserts it |

Loading a non-tutorial save cleared it instantly. **A frozen `GetWorldTime()` is
not evidence of a dead instance. Read `GetGameTime()` and `IsWorldTimePaused()`
in the same breath.**

### The tick proof

**GPU control** (observed), two reads 195 s apart:

```
gameTime=14873  worldTime=569351  day=6 hour=14.1533  ratio=15  paused=false
gameTime=15068  worldTime=572283  day=6 hour=14.9676  ratio=15  paused=false
```

`gameTime` +195 over 195 s = **1.00× real time**. `worldTime` +2932 = **15.03×**,
matching the declared ratio. Simulation evidence beyond the clock: NPC positions
changing between reads, 1494 souls, 22619 entities.

**WARP, default render target** (observed), 46 reads over 604 s:

```
[w0]   gameTime=14863  worldTime=568892  ratio=15  paused=false
[w45]  gameTime=14874  worldTime=569061  ratio=15  paused=false
```

`paused=false`, and `worldTime/gameTime = 169/11 = 15.4` — the clock ratio is
intact, so the simulation is behaving correctly. But `gameTime` advanced **11 s
in 604 s of wall clock: 1.8% of real time, ~55× slower than real time.**

So the WO's acceptance criterion is met on WARP — world time advances, observed
many times over ten minutes — while the honest reading of the same data is that
the instance is not usable as a live host at this render target.

---

## 4. The cost table

All rows: Modding Tools build, `-devmode -noCrashHandler`, save
`playline1/exit` (level `trosecko`, day 6, ~14:00, ~1500 souls loaded),
12-thread Ryzen 5 5600, 32 GB. Each row is a **cold process**: launch, load one
save, measure, hard-kill. The `kdcmp` mod is installed in every row (it idles
until connected), so it is a constant, not a controlled variable.

### Read this table with the frame-rate throttle in mind

Every row runs **unfocused**, and KCD2 caps its frame rate when it is — shipped
and named (**code-verified**, `ConsoleHTMLHelp`):

```
sys_MaxFPS            0 = ... auto throttles fps while in menu or game is paused (default)
sys_MaxFPSThrotteled  The FPS limit that applies when sys_MaxFPS is set to 0
                      and the game is in menu, loading screen or unfocused
```

So the GPU column's tiny CPU figure is **not** "the cost of simulating this
world" — it is an instance comfortably meeting a low FPS cap. The honest
comparison is: *both* configurations are asked for the same throttled frame
rate; the GPU meets it, WARP misses it by ~55× while spending 7.6 cores trying.
A headless host is always unfocused, so this throttle is permanently in play —
a deployment advantage WARP still cannot exploit.

### Boot and load (observed)

| | boot → debug API | load → world RUNNING | total to a live world |
|---|---|---|---|
| **GPU**, 1704×959 | **34.4 s** wall / **15.5** CPU-s | **72.5 s** wall / 75 CPU-s | ~107 s |
| **WARP**, 1704×959 | **36.3 s** wall / **25.9** CPU-s | **251.7 s** wall | ~288 s |
| **WARP**, 320×240 | **34.9 s** wall / **23.9** CPU-s | **202–224 s** wall / ~2018 CPU-s | ~240–258 s |

Load wall-times are the sum of the engine's own `SetGlobalState` transitions in
`kcd.log`, which is the same clock for every row.

**Booting on WARP is not expensive** — near-identical wall time, ~1.7× the CPU.
WO-72's "~7× the CPU to boot" did not reproduce; see `WO-73-progress.md`.
**Loading is ~3.5× slower on WARP**, and shrinking the render target barely
helps it (251.7 → 223.7 s).

### Steady state — a loaded world, idle (observed)

| | cores | working set | threads | **sim rate** | fence timeouts |
|---|---|---|---|---|---|
| **GPU**, 1704×959 | **0.17** | 7.03 GB | 89 | **1.003×** | 0 |
| GPU, render features off | **0.13** | 7.08 GB | 87 | 0.997× | 0 |
| **WARP**, 1704×959 | **7.8** | 9.37 GB | 197 | **0.018×** | 2959 |
| **WARP**, 320×240 | **6.88** | 9.06 GB | 142 | **0.061×** | 2126 |
| WARP, 320×240, features off | 6.79 | 9.35 GB | 179 | *(inconclusive — see below)* | — |

"sim rate" is `GetGameTime()` advance ÷ wall-clock advance; 1.0 means the world
keeps up with real time. **It, not cores, is the number that decides whether a
host is usable.** Sample lengths: GPU 192 s, WARP-1704 604 s, WARP-320 212 s.
`GetGameTime()` is integer seconds, so the WARP rates carry roughly ±10%
quantisation error at these window lengths.

### The render target cuts throughput debt, not CPU cost (observed)

Dropping 1704×959 → 320×240 is a **21× reduction in pixels**. It bought:

* **cores: 7.8 → 6.88 — about 12%.** Nearly nothing.
* **sim rate: 0.018× → 0.061× — a 3.4× speed-up.** Real, and much larger.

So the WO's expectation ("the single biggest expected saving") is **half right,
and the half it gets wrong is the half that was being measured.** Shrinking the
back buffer barely changes what the instance *consumes*; it meaningfully changes
what the instance *achieves*. A CPU-only host is not paying for pixels — it is
paying for geometry, culling, shadow atlases and draw submission, none of which
scale with swap-chain size — but relieving the pixel path still lets the frame
loop close more often.

Even so: **0.061× is still 16× slower than real time.** The lever is real and
nowhere near sufficient.

### The features-off probe (exploratory, added because the row above under-delivered)

Six render features switched off at runtime on the **same loaded world**
(`e_Shadows 0`, `e_Vegetation 0`, `e_Particles 0`, `e_Clouds 0`,
`e_WaterOcean 0`, `r_PostProcessEffects 0`), all confirmed applied by console
echo:

* **GPU: 0.17 → 0.13 cores**, sim rate unchanged at ~1.0×. Those passes are
  ~24% of an already frame-throttled instance.
* **WARP: 6.88 → 6.79 cores; measured rate 0.018×.** **Do not read that as
  "turning features off made it slower."** The window was 114 s immediately
  after the cvar change, and toggling `e_Vegetation`/`e_Shadows` at runtime
  forces asset and render-resource churn — the sample is measuring that
  disruption, and it spans only **2 whole game-seconds**, so its quantisation
  error alone is ±25%. **This row is inconclusive.** Testing it properly means
  setting the features off *before* the world loads and measuring steady state;
  that was not done.

---

## 5. Sanity anchor — does the REST/Lua surface behave the same on WARP?

Three spot checks from the mod's daily calls, in-world, both configurations
(**observed**):

| check | GPU | WARP |
|---|---|---|
| soul read (`/api/rpg/SoulList/SoulCount`) | 1494 | 1500 |
| entity query (`#System.GetEntities()`) | 22619 | 21732 |
| `ExecuteString` round trip (Calendar probe) | works | works |

**Content is equivalent** — the small counts difference is streaming state at
slightly different in-world times, not a WARP artefact.

**Latency is not.** On the loaded WARP instance a single REST call took **50.4
seconds** to return (timed). Every REST/Lua call is serviced on the game thread,
and that thread is the one running at 1/55 speed. This is the one real
divergence, and it matters beyond measurement: any design that drives a headless
host over `:1403` inherits that thread's frame rate as its latency floor. It
also broke this WO's own harness once — a 600 ms wait for a log line that took
tens of seconds to appear produced a "DEAD" verdict on a live instance.

## 6. Routes not taken, and why (so nobody re-runs them)

- **Route 0 as briefed** (quicksave on a GPU boot, then `Game.QuickLoad()` on
  WARP) — **not run.** `wh_sys_LoadGame` loads a *named* save directly, which is
  strictly better: no GPU boot needed, no quicksave slot to prepare, and any
  save is reachable. `Game.QuickSave()` was never called.
- **Route 1, UIAction name discovery** — **not needed.** Not attempted.
- **Route 2, native `C_Game::OnLoadGame`** — **not needed.** No native call was
  made and nothing was wired. The WO-72 probe was used unchanged, only for its
  early-cvar mechanism.

## 7. What this does not establish

- **Not tested on an actual GPU-less VM.** This box has a GPU; WARP was chosen
  by adapter index, as in WO-72.
- **`wh_sys_AutoLoadLastSave` untested** — inferred from its help text and flag.
- **One save, one location.** `trosecko`, day 6, ~14:00, a settlement-adjacent
  spot with ~1500 souls loaded. Cost is location-dependent and this is a single
  sample.
- **The slowdown figures are rates, not floors.** They were measured with the
  frame loop fence-timing out. Nothing here decomposes the cost between
  rasterisation, simulation, and the fence stalls themselves — so "the sim is
  inherently too slow on CPU" is **not** established. What is established is
  that *this* configuration is.
- **The features-off lever was not tested properly** (see §4). Setting render
  features off before the load and measuring steady state is untried, and is the
  obvious next thing.
- Nothing here says anything about topology. That fence, from WO-71/72, stands.

---

## 8. Verdict

> **The world-load blocker is gone.** `wh_sys_LoadGame <playline> <name>` loads
> any named save over `:1403`, on WARP with no GPU, with no code, no install
> change and no native call. It cost one grep of a reference file shipped inside
> the game. WO-72's two expensive candidate routes are both moot.
>
> **The world ticks on the CPU-only instance, and that is now measured rather
> than hoped for** — `paused=false`, world time advancing at its declared 15×
> ratio, 1500 souls and ~22000 entities live, on a software rasteriser.
>
> **A CPU-only host is nevertheless not viable as built.** It runs the world at
> 0.018–0.061× real time on ~7 cores, against 1.003× on 0.17 cores with a GPU.
> That is not a tuning gap. The one reduction this WO was asked to measure —
> render-target size — helps throughput 3.4× and cost 12%, leaving it still 16×
> short of real time. Whether disabling render *passes* (rather than shrinking
> the target) closes a 16× gap is untested and is the single highest-value
> follow-up; the GPU column suggests those passes are only ~24% of the work,
> which would not be enough, but that is an inference from the wrong machine.

## 9. Inputs for the decision session

*(Numbers and constraints only. No topology recommendation — the WO-71/72 fence
stands.)*

Per-instance, one loaded world, `trosecko` at ~1500 souls, on a 12-thread
Ryzen 5 5600: **with a GPU**, 0.17 cores and 7.0 GB at 1.003× real time, ~107 s
from launch to a live world. **Without a GPU (WARP)**, 6.9–7.8 cores and
9.0–9.4 GB at 0.018–0.061× real time, ~240–290 s from launch to a live world;
boot itself is cheap (~35 s, ~1.7× the GPU's CPU, not WO-72's 7×), and the load
is ~3× slower. Memory is essentially render-independent — the world dominates —
so ~9.5 GB is the figure to size against for a CPU-only instance and ~7 GB with
a GPU. The debug/REST control surface is content-identical on both, but on a
loaded WARP instance a single call took **50.4 s** to return, because REST is
serviced on the game thread and that thread is the one running slow — any design
driving a host over `:1403` inherits its frame rate as a latency floor. Two
constraints that are properties of the build, not of this experiment: the cvars
that enable CPU-only rendering must be set *before* renderer init, which on an
unmodified install means injected code or a `system.cfg` edit; and world time is
paused for the duration of tutorial-mission saves regardless of focus, cvars, or
`Calendar.SetWorldTimePaused(false)`, so a host's starting save is not a free
choice. Unmeasured and material: any location other than this one, more than one
loaded world per host, and whether disabling render passes rather than shrinking
the render target changes the CPU-only picture.
