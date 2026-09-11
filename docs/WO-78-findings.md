# WO-78 — The chain leak, root-caused: suspended is not dead

Investigation + Lua-only fix session, 2026-09-11, informed by the first real
two-player field session's logs (same day). Companion: `docs/WO-78-progress.md`.

Evidence tiers, same discipline as WO-75/76/77:
**(observed)** seen this session — a log line counted, a suite executed ·
**(code-verified)** read directly in the source tree ·
**(read-but-unrendered)** stated by a prior doc, not re-checked here ·
**(inconclusive)** the evidence does not settle it.

Privacy: no real IP, hostname, personal name or user-specific path appears
here. The two field bundles are referred to as **host** (`kcd.log` 253,509
lines) and **joiner** (`kcd.log` 557,773 lines); their on-disk paths are not
quoted. Both ran **v0.20.2** (observed, agent log presence string), i.e. with
WO-77's puppet renderer and the WO-69 puppet-chain instrument in place.

---

## 0. Ground truth (Phase 0)

- (observed) `git pull` on `main`: already up to date at `9b51d8b`, WO-77's
  head plus the 0.20.2 version and VERSIONING commits. No newer work.
- (observed) `docs/WO-75-jitter-design.md` §2.5 read in full. It predicted
  the ghost-side result — `Interp tick started` increments after every menu
  ≥ 3.5 s and the `TICK_ALIVE` interval shrinks by the chain count — and named
  the fix shape (time-based advance). Nothing in §2.5 is re-derived below;
  where this session goes further is the **trigger set** (§2 item 3) and the
  **gate** (§3.1), which §2.5 did not address.
- (observed) `docs/WO-77-findings.md` read in full: Step 1's render state
  (ring, `cx/cy/cz/cr`, `segSpd`, `animTag`) lives on the per-entity `p`
  table; the only per-chain value is the WO-69 `gen` closure argument.

## 1. What the field logs say (the numbers this WO stands on)

All (observed), both bundles, `grep -c` unless stated.

| line | host | joiner |
|---|---|---|
| `Interp tick started` | 34 | 41 |
| `Label render loop started` | 34 | 42 |
| `State emitter started` | 34 | 41 |
| `NPC-SYNC emit tick started` | 34 | 42 |
| `ITEM-SYNC tick started` | 35 | 44 |
| `NPC-SYNC puppet tick started` | 67 | 80 |
| `NPC-SYNC puppet tick stopped (no puppets)` | 14 | 17 |
| `NPC-SYNC CHAIN LEAK CONFIRMED` | 1 (gen=1 alive at gen=8) | 1 (gen=5 alive at gen=9) |
| agent `[menu] local menu open` | 9 | 6 |
| `sqc_ptag_menu' will be 1` (ESC menu) | 2 | 2 |
| `PlayAudio: ApseOpen` (inventory) | 5 | 3 |
| `AfterSkipTime ... started async` | 2 | 1 |
| `TICK_ALIVE` heartbeats | 466 | 1,488 |

Three things fall straight out of that table:

1. **The four agent-re-armed chains restart together.** 34/34/34/34 on the
   host, 41/42/41/42 on the joiner. Whatever restarts one restarts all of
   them in the same batch — which is exactly what `GameBridge.cs`'s 2.5 s
   re-arm does (code-verified: `ReArmInterpInterval` = 2500 ms, one
   `ExecLuaAsync` each for `StartInterp` (which also starts the label loop),
   `StartEmitter`, `StartNpcSync`, `StartItemSync`).
2. **Menus explain a fraction.** 9 and 6 menu opens against 34 and 41
   restarts. Menu durations from the agent log (host: 8.6, 10.5, 0.4, 7.3,
   4.5, 1.2, 1.1, 6.5, 3.6 s; joiner: 11.2, 0.7, 6.8, 0.1, 1.6, 1.2 s) at one
   re-arm per 2.5 s beyond the first second account for roughly 14 host and
   7 joiner restarts. WO-69's purely menu-driven hypothesis is **incomplete**.
3. **The puppet chain restarts about twice as often** as the others, with only
   14/17 of its extra starts explained by clean "no puppets" stops.

### 1.1 Every restart followed a whole-timer-system stall

The emitter stamps `os.clock()` into every `[KCD2-MP-DATA]` line, so the gap
between the last DATA line before a restart and the first after it measures
how long **the emitter's own Script.SetTimer chain** was not firing.

(observed) Host: of 34 `Interp tick started`, 1 is the session's initial start
and **33 of the remaining 33** sit inside a DATA gap ≥ 1.0 s (2 in 1–2.5 s,
15 in 2.5–10 s, 16 ≥ 10 s). Joiner: 1 initial, **40 of 40** inside a gap
≥ 1.0 s (0 / 8 / 32). **Zero** restarts happened while the timers were
demonstrably running.

So the restarts are not chains dying one at a time. They are the agent's
re-arm arriving while *every* chain is suspended.

### 1.2 What suspended them — it is not only menus

(observed) The 60 lines before each restart, classified by engine marker
(a restart may hit several; "none" = no marker in the window):

| marker | host (34) | joiner (41) |
|---|---|---|
| inventory (`ui_apse_*`, `ui_inv_*`, `Apse*`) | 16 | 8 |
| dialog (`Dialog ends`, `Localization/dialog/...`, `InterruptDialogs`) | 7 | 4 |
| ESC menu | 1 | 5 |
| skip-time | 0 | 6 |
| cutscene | 0 | 2 |
| none within 60 lines | 13 | 21 |

The single largest event in either log (observed): joiner lines
159,386–159,723, **24 restarts of all five chains in ~340 lines**, inside a
DATA gap of **60.69 s**, immediately followed by
`CutscenePlayer::OnCutsceneEnd ... 'crime_pillory_trosecko_firstRun'`. 60 s ÷
2.5 s = 24. A pillory cutscene suspended every timer for a minute; the agent
re-armed 24 times; nothing was dead.

The agent's pause detector (code-verified, `LogTailGameTransport.cs
ProcessPauseMarkers`) knows the ESC menu, the inventory and skip-time. It
does not know dialogs or cutscenes, so during those (a) no interp pump runs —
the WO-13 freeze is back for the local player — and (b) nothing on the agent
side treats the interval as "suspended". The Lua side never knew either way.

### 1.3 The chains resumed; they did not die

(observed) `TICK_ALIVE` fires every 250 interp ticks, so its interval is
5.0–6.6 s for one chain and shrinks by the chain count (WO-75 §2.5's recipe,
timestamped by the nearest DATA line's `os.clock`):

- Host: interval 0.63–1.05 s (**5–8 concurrent chains**) from line ~30,700 to
  ~57,800; back to 1 after each save load; 1.1–1.9 s (**3–5 chains**) from
  ~83,600 to ~117,000; 1 again after the next load.
- Joiner: 1.5–2.3 s (2–4 chains) through the middle of the session; then,
  from the cutscene burst onward (line ~160,000 to the end of the log),
  **0.26–0.39 s = 14–21 concurrent interp chains**, never recovering.
- Save loads (`Loading level` clusters) reset the count to exactly 1 every
  time on both machines. Those really do kill the timers, as WO-13 said.
- (observed) The puppet instrument agrees: host gen=1 was still running when
  gen=8 started — the first seven puppet restarts all left the previous chain
  alive.

### 1.4 The puppet path's extra restarts are the same gate, called faster

(observed) Of the host's 67 puppet starts, **35 occur with zero DATA lines
since the previous puppet start** — i.e. inside the same stall; 32 follow at
least one DATA line. Joiner: 53 / 27. (code-verified) `KCD2MP_ApplyNpcState`
ends with `KCD2MP_StartNpcPuppet()` on **every** inbound packet, and packets
keep arriving through `ExecuteString` during a suspension, so the puppet gate
was asked every ~100 ms instead of every 2.5 s and started a new chain each
time the stamp had gone ≥ 1.0 s stale — roughly one per second of stall
against one per 2.5 s for the others. Same defect; more frequent caller.

## 2. Phase 1 verdict: (A), a shared root cause

**(code-verified)** Every `Start*` in `kdcmp.lua` gated on the same
`tickAlive(flag, stamp)`: "the stamp is older than 1.0 s, therefore the chain
is dead, therefore start another". `os.clock()` keeps running while
`Script.SetTimer` is suspended, so a suspension of ≥ 1.0 s is
indistinguishable from death **by looking at the stamp**. The callers are the
agent's 2.5 s re-arm (four chains, five with the label loop) and the puppet
path's per-packet entry. No caller on any path did anything different.

The menu pump was designed not to stamp the chain alive ("a pumped call must
not make a dead chain look healthy", WO-13) — correct for its purpose, and it
means the one code path that *did* run during a menu could not have helped
even for menus, let alone for the dialogs and cutscenes it never ran during.

**(B) is refuted on the evidence:** there is no ghost-specific or
puppet-specific second trigger. The puppet count is higher because the same
gate is polled ten times as often during the same stalls (§1.4), not because
a different mechanism restarts it.

### 2.1 The divergent-state question (Phase 1 step 4)

**(code-verified)** Puppet: all render state is on the shared per-entity `p`
table — `ring`, `cx/cy/cz/cr`, `segSpd`, `animTag`, `animRefreshAt`,
`lastWroteX/Y`. The only per-chain value is the `gen` upvalue. Two chains
therefore compute the same `renderAt` and write the same position; WO-77's
scenario (c) proves this synthetically and nothing found here contradicts it.

**(inconclusive → not evidenced)** The brief's premise that "tonight's puppet
flicker was still visible" has no support in either log or in the brief's own
symptom list (which names ghost movement, a horse teleport, and non-rendering
items). No puppet-side state divergence was found and none is fixed here. If
a future session reports puppet flicker under WO-77, the first thing to check
is the `NPC-FIGHT` lines (D2, the unsuppressed brain), not the chain count.

**(code-verified)** Ghost: state is shared too (`istate` per ghost), but
every step was **per-tick-factor** math — the 0.5/0.15 lerp, DR by
`ticksSincePacket × 20 ms`, `rendSpeed / 0.020`, the 0.4 speed smoother, the
horse's 0.25/0.35 Z/yaw smoothers, and `KCD2MP_UpdateAnimation`'s
`StartAnimation` every fire. N chains applied N ticks' worth per 20 ms. At the
joiner's 14–21 chains the lerp is a snap onto the DR-projected point every
frame and the anti-rubber-band damping (0.15) is defeated (0.85^18 ≈ 0.05
remaining). That is the reported "2 steps forward, jitter, 1 step back" in
mechanism; it is **not independently confirmed** as the cause of what the
player saw, only consistent with it.

**(inconclusive)** `Animation-queue overflow. More then 16 entries` — host
2,380 lines, 1,749 of them in the 80k–100k window where the interp chain count
was 3–5; joiner 18,816, the bulk after the count reached 14–21. Correlated with
chain count; the ghost path also restarts its looped animation every 20 ms
with a single chain, and the joiner logged 914 of them before any leak, so
the count is a plausible amplifier, not a proven cause.

## 3. Phase 2 — what was changed (all in `kdcmp/Data/Scripts/Startup/kdcmp.lua`)

### 3.1 The shared gate: probe-confirmed restart (`chainMayStart`)

Replaces the bare `tickAlive` early-return in all six `Start*` functions
(emitter, interp, label, npc-sync emit, puppet, item-sync). A stale stamp no
longer means "start". It means: arm a one-shot `Script.SetTimer` probe
(400 ms, then a 200 ms settle hop) and start **only if the probe fires while
the stamp is still stale**.

- Suspended chain: the probe is suspended too, fires when everything resumes,
  finds a fresh stamp, logs `CHAIN <key> was suspended, not dead ... restart
  skipped (#n)` and clears. Repeated re-arms while a probe is pending arm
  nothing (3 s guard, then a superseding probe — harmless if both fire).
- Dead chain (save load): a probe armed after the load fires into a working
  timer system, finds no heartbeat, logs `CHAIN <key> confirmed dead ...
  restarting` and calls the `Start*` function, which now passes.
- Flag false (never started, or the puppet chain's clean "no puppets" exit,
  or `KCD2MP_StopEmitter`): starts at once, as before.
- The settle hop exists because a resumed chain and its probe come due in the
  same frame and nothing says which the engine runs first.

Shared across ghost and puppet code deliberately: it is liveness plumbing,
like `tickAlive` already was. WO-70 constraint 1 is about rendering math.

Recovery latency after a real death: ≤ 2.5 s (next re-arm) + 0.6 s (probe),
against the previous ≤ 2.5 s + 1.0 s (stamp window). Comparable.

### 3.2 Ghost interp chain: time-based advance (WO-75 §2.5 for this path)

Per ghost per fire: `dt = now − istate.renderAt`; a fire < 2 ms after the last
render of that ghost **does nothing** (a same-frame duplicate; `os.clock` is
~1 ms on Windows); `dt` capped at 1 s; `steps = dt / 0.020`. Then: lerp
factor `1 − (1 − f)^steps` (exactly the old 0.5/0.15 at one nominal tick, and
two 10 ms fires compose to one 20 ms fire); DR by real seconds since
`lastPacketTime`, capped at 0.060 s (was 3 ticks); `rendSpeed = moved / dt`;
speed smoother `1 − 0.6^steps`; horse Z/yaw smoothers `1 − 0.75^steps` /
`1 − 0.65^steps`; the horse's velocity readback over `dt`. The ring-buffer
renderer was **not** ported — the ghost path keeps its lerp-toward-DR-target
shape, made time-based, which is what §2.5 prescribed. Nothing is shared with
the puppet renderer (constraint 1).

### 3.3 Ghost-side leak detector, mirroring WO-69's

`KCD2MP_StartInterp` claims `KCD2MP.interpGen`; the chain reschedules through
a closure carrying its generation; `KCD2MP_InterpTick(arg, gen)` logs
`GHOST CHAIN LEAK CONFIRMED: interp chain gen=A is still running while gen=B
is current` once per session, **toasts it** via `KCD2MP_ShowNativeToast`, and
exits the stale chain when `mp_ghost_chainfix` is on. The pump path
(`arg == "ext"`, `gen == nil`) is untouched.

### 3.4 `mp_npc_chainfix` reconsidered: both stale-chain exits default ON

WO-69's rule was observe-only until a log line showed two chains alive at
once. The 2026-09-11 session produced that line on both machines and the
toggle was never flipped — the design generated the observation and then
could do nothing with it. Decision:

- `mp_npc_chainfix` **defaults on**; new `mp_ghost_chainfix` **defaults on**.
  With §3.1 refusing the false restart, a stale chain can now only exist
  through a bug, and two chains writing one entity is never wanted. Both
  toggles remain as the rollback and the live A/B.
- Both `LEAK CONFIRMED` lines now also raise a **native toast**, so a human
  sees the condition mid-session instead of finding it in a grep afterwards.
  With the gate in place the toast should never appear; if it does, that is
  the regression alarm.
- Not done, named: a visible counter of *refused* false restarts
  (`KCD2MP._chainSuspendedN`, readable via `mp_ghost_chainfix` with no
  argument) would be the positive confirmation that the gate is doing its job
  in the field. It is a log line today.

### 3.5 What the .NET side would still want (not changed here)

- (code-verified) The agent's pause detector misses dialogs and cutscenes, so
  the interp pump does not run during them and ghosts freeze for the local
  player exactly as they did in menus before WO-13. Candidate markers seen
  this session: `CutscenePlayer::OnCutsceneStart/End`, the dialog `Dialog
  ends`/`Localization/dialog/` lines; or a Lua-side `human:IsInDialog()` poll
  (WO-57 documents the bind, unprobed). Separate WO — agent + a probe.

## 4. Phase 3 — verification

### 4.1 Synthetic (observed)

`tools/Test-GhostInterpSynthetic.ps1` (+ `.lua`): new, ghost-only scenario
file run through the WO-77 MoonSharp driver (which gained `-Scenario`/`-Title`
parameters; its default behaviour is unchanged). **35/35.**

| # | scenario | result |
|---|---|---|
| (ga) | single chain, 1.5 m/s, packets every 50 ms, fires every 20 ms, 2 s: monotonic, no step > one packet gap + DR, within 0.3 m of truth at t=2 | PASS |
| (gc) | 3 same-frame fires + 1 stale-generation fire per step: every write equals (ga)'s to 1e-9; `GHOST CHAIN LEAK CONFIRMED` logged exactly once, toasted once, stale chain never rescheduled | PASS |
| (gc2) | two chains 10 ms out of phase: within 5 cm of the single-chain trajectory while moving, never backwards, converge on the held DR point to 1 mm after the stream stops | PASS |
| (gd) | gate, suspension: stamp 8 s stale → `StartInterp` starts nothing, arms one probe per chain; repeated re-arms arm nothing more; on resume the probe logs "suspended, not dead" for interp and label, gen unchanged, entries cleared, refusal counter = 2 | PASS |
| (ge) | gate, real death: probe fires with no heartbeat → "confirmed dead" + one `Interp tick started` + one `Label render loop started`, gen +1; the next re-arm is a no-op; the new chain runs under the current gen | PASS |
| (gg) | menu pump entry: renders, never reschedules, never stamps alive; 80 Hz pumping never passes the DR target | PASS |

`tools/Test-NpcSmoothSynthetic.ps1`: **48/48** (was 39). Scenarios (a)–(i)
unchanged and passing against the gated `StartNpcPuppet`; new **(j)**: 10
packets through `KCD2MP_ApplyNpcState` during a 5 s suspension start no new
generation and arm exactly one probe; the probe finds the resumed chain and
restarts nothing; after a real death the probe restarts the puppet chain
exactly once; `mp_npc_chainfix` defaults on.

Every scenario also asserts zero swallowed `pcall` errors in the render path.

### 4.2 Live (not run)

No game was running this session (the launcher agent was, the game was not).
Nothing here was executed in the game's own Lua VM. The constructs added
(`^` on numbers, closures over `Script.SetTimer`, `KCD2MP[field]` indexing)
all appear elsewhere in the file already.

### 4.3 What remains unverified — honestly

- **That the ghost looks better to a human.** The arithmetic says a leaked or
  duplicated chain now renders the same trajectory as one; nobody has
  watched it. Next field session's job.
- **That the probe gate holds in the engine's actual timer ordering.** The
  settle hop is a defence against an unknown (which of a resumed chain and
  its probe the engine runs first in the same frame). If the engine ever
  delays a resumed chain by more than 600 ms after timers resume, the gate
  would confirm a false death once per suspension — far fewer than today's
  one per 2.5 s, and the stale-exit would then clean it up, but it is worth
  one grep for `confirmed dead` lines that are *not* adjacent to a
  `Loading level` cluster.
- **That the game's Lua VM accepts the code** (MoonSharp is not CryEngine's
  Lua 5.1).

## 5. Named, not attempted (out of scope for this WO)

1. **`GHOST_DEATH` flag flapping / the reload-attacking ghost body.** Host's
   own `GHOST_DEATH id=1` went true→false with one ~5,300-line gap (a real
   death + reload, during which the dead body reportedly attacked the other
   player with nobody controlling it) and two true→false pairs 18–31 lines
   apart. Death/combat state, own WO.
2. **Horse puppet teleport ~1,957 m in one 50 ms tick.** WO-69's "one soul,
   two live bodies" hazard, now with a field instance on a horse. Own WO.
3. **ExecuteString batch truncation.** (observed) host `kcd.log` has **1,582**
   `[Lua Error] Error executing lua [string ""]:12/13: ... expected near
   '<eof>'` lines (joiner 29). A batched Lua string is being cut mid-statement
   around its 12th–13th line and the whole batch is lost. Not investigated
   here; it would drop position/appearance/NPC updates silently. Own WO,
   agent-side (`GameBridge.cs` batching).
4. **Pause detector misses dialogs and cutscenes** (§3.5) — ghosts freeze for
   the local player during both. Own WO.
5. **Animation-queue overflow** correlation (§2.1) — worth revisiting once a
   post-WO-78 log shows what the count does with one chain.
6. From the brief's own list, all real and none touched: KO state not syncing
   to the knocked-out player; a villager's death not syncing; clothing /
   chestplate sync gaps; weather not syncing; time-skip not correcting a
   joiner's clock; multi-attacker lock-on confusion.

## 6. What this session did not do

- No .NET, protocol, relay, agent or native change. `git diff --stat` touches
  `kdcmp.lua`, `tools/Test-NpcSmoothSynthetic.{ps1,lua}`, two new `tools/`
  files, `README.md`, `docs/PROJECT-STATE.md` and the two WO-78 docs.
- No `VERSION` change (still `0.20.2`); the maintainer's call.
- No pak rebuild or install; editing `kdcmp.lua` does nothing live until
  `Build-And-Install-Mod.ps1` runs and the game restarts.
- No live game, no second two-player session.
