# WO-116 — progress: what ran, what did not, what blocked it

Session 2026-09-23, solo. Findings: `docs/WO-116-movement-layer.md`.
**No shipped code. No pak rebuilt. No installer. No VERSION bump. Nothing ran
two-player.** Paths: `<install>`, `<saves>`, `<scratch>` (the session
scratchpad, not committed), `<ENGINE_REF>`.

## 1. What ran

| phase | status | note |
|---|---|---|
| read-first docs | done | WO-107 (whole), WO-108 (whole), WO-105 §4–§7, §16–§19, WO-106 native migration, WO-111 findings + progress, WO-110/112/113 state. **`docs/DECISIONS-coop-design.md` does not exist** in the tree or in git history; not read |
| 0 — seat test | **done** | seated vs walking vs lean, 1 m and 3 m, the mod's own detectors and an independent phase-locked recorder; three release levers tried, one works. Findings §1 |
| 1 — the movement layer | done | the chain order → body with RVAs, keep/replace/bypass, player, threads and one frame's order (probe DLL). Findings §2 |
| 2 — ways to give an order | done | seven candidates plus two non-routes. Findings §3 |
| 3 — live probes | **done except activities** | one order, speed classes, 10 Hz follow ×8, overwrite comparison ×2, drift snap, drawn weapon, 10 NPCs at once, release ×2. Sit / workstation not produced (§5.6) |
| 4 — host intent reads | done | the queue chokepoint (WUID, target, speed, exact, source) live on an awake NPC; stance/activity native read not decoded |
| 5 — design | done | findings §7, fallback §9, effort §10 |
| docs | done | this file + findings |

## 2. Live probes (solo, throwaway save)

Launch: Steam already running; `<install>` `KingdomCome.exe` started directly
(API up in ~25 s). `kcd.log` and `logbackups/kcd.log` copied to `<scratch>`
before the first launch; `kcd.log` copied again before the relaunch and at
the end.

Session 1: `wh_sys_LoadGame 1 quicksave027` (WO-112's clean throwaway) →
clock advanced to 09:30 next day (`Calendar.SetWorldTime`), world-time ratio
1, `death_protection_cutscene` added to the player (the WO-111 guard,
non-persistent) → **fresh throwaway `quicksave032` written at once**
(`wh_sys_TestSaveGame`). `quicksave024/026/028` untouched. Session 2 (fresh
process, for the probe v2): `wh_sys_LoadGame 1 quicksave032`, ratio 1, guard
re-added.

| # | probe | result |
|---|---|---|
| P0-B′ | `ttkc_man_10` (walking) streamed to a 1 m point that was inside furniture | constant 0.352 m +X push each tick; `MP-NPCFIGHT` / `…VIOLATION kind=contention` fired — a detector false positive |
| P0-B | `tzda_man_10` suspended while walking, free 1 m / 3 m | 0.0000 m per tick; stays where written after release |
| P0-A | `ttkc_man_22` suspended seated, free 1 m / 3 m | 4.1 %/tick toward the seat, cos 1.00; exponential return after release |
| P0-C | `StandUp()` (suspended and not); movement order on a seated NPC (suspended and not); `wh_ai_NPCStateResetElement … Stance` then stream | no effect; stuck + snap-back; **pull 0.0000 m** |
| P0-W | lean activity, then `… Unstance` | no pull; reset to `MotionIdle` |
| M1 | debug order on a suspended *seated* NPC | stuck loop; cancelled with `wh_ai_CancelDebugMovement` |
| M2 | debug order on a suspended walker | walked 9.3 m with transitions and a turn, 4 cm |
| R1 | resume walker and the seated one | walker off in ~1 s |
| F1–F3 | 10 Hz follow, walk / run class | 0.39 m lag at 1.4 m/s; too-slow classes lose ground |
| — | probe DLL v1 injected (16/16 hooks) | thread map; speed override; queue log |
| S3, S7 | run / sprint through `+0xF8` | 3.0 / 5.0–5.5 m/s |
| speeds | classes 0–11 | table in findings §5.2 |
| F4–F8 | sprint class 3.5 m/s, with and without a 0.25 s lead | no lead 0.86 m constant; lead → limit cycle (three runs) |
| OW1–OW2 | same route through `KCD2MP_ApplyNpcState` | 0.22 / 0.57 m lag, engine `MotionIdle` throughout, Z pinned |
| RF1 | debug order on an unsuspended seated NPC | same stuck + snap-back |
| RS | suspended seated NPC, `Stance` reset, stream 1 m / 3 m | 0.0000 m |
| W | lean, `Unstance` reset | as above |
| — | quit, relaunch, probe v2 injected (24/24 hooks) | main-thread frame order |
| H1 | watch the awake bartender's own orders (WUID) | order targets matched arrivals to 0.2 m and 1 cm |
| multi-10 | ten suspended NPCs, 10 Hz each | ~3 % frame rate; lag 0.5–1.1 m mean |
| release-10 | resume the ten | back to activities in 5–20 s |
| D1, D2 | 2 m snap mid-follow; weapon drawn | recovered in 3.5 s; armed walk 1.47 m/s |
| seated-3 | reset + follow with `wh_ai_MovementSystemDebugLogErrors 1` | followed, no stuck report |

Every NPC suspended or reset was resumed before the end (§6).

## 3. Static work

* **Ghidra 12.1.3 headless, Java post-scripts** (PyGhidra unavailable, as
  WO-107/111 noted). Reused read-only the analysed projects from earlier
  sessions for XGenAIModule (WO-107), EntityModule, CryAction +
  AnimationModule + CombatModule (WO-100), CryEntitySystem + CryAISystem
  (WO-102), RPGModule / PlayerModule / WHGame / Framework / GUIModule
  (WO-111) — the binaries are unchanged since 2026-08-26, older than every
  project. Fresh imports: CryAnimation, CryPhysics, XBehaviorModule,
  CrySystem (1–3 min each, serially).
* The WO-111 tool script, extended with an `xref` mode (references to raw
  addresses, with an operand-scan fallback). String anchors found by a
  Python PE string dump with RVAs, then decompiled in Ghidra.
* **capstone** (present in the local Python) disassembled hook prologues
  straight from the DLL files and picked safe patch lengths (no
  RIP-relative operand, no branch in the patched run).
* **PE import/export tables** read in Python: CryAISystem exports 86 stock
  `Movement::` symbols; XGenAIModule imports 36 of them.
* **Stock source**: `<ENGINE_REF>` read by a read-only subagent for the
  movement request path, the animated character, the AI movement system,
  exact positioning, player input and the frame; the report was prose and
  identifiers only. Nothing from it is reproduced here.
* **Data**: `Tables.pak` (`NPCStateActionDatabase.xml`,
  `NPCStateUnstanceDatabase.xml`, `NPCStateStanceAnimDatabase.xml`),
  `Scripts.pak` (`playeraction_setdialoganimationstate.xml`), and the
  Warhorse scriptbind docs, cross-checked live with `type()`.

## 4. The probe DLL (research only)

* Built with the VS Build Tools toolchain from one `.cpp` in `<scratch>`,
  injected with the project's `KCDMP_LauncherInjector --pid --dll`. Two
  versions, two file names (a second `LoadLibrary` of the same name is a
  no-op).
* Inline hooks, each checked against its expected first bytes (a mismatch
  skips the hook), patched with every other thread suspended; a
  register-preserving thunk (rcx/rdx/r8/r9 and xmm0–3) counts calls per
  thread and, on the main thread, stamps entries into a ring for frame
  order. The animation job body needed a 5-byte jump through a near stub.
* The speed override applied only to requests that came through the debug
  door on the same thread (a thread-local flag set at the door's worker),
  so no brain order was ever altered.
* Neither version was shipped, copied into the repository or installed.

## 5. Decisions taken

* **Phase 0 on the mod's real puppet path**, not a hand-rolled writer, so
  the numbers are the ones the peer test's detectors produce; plus an
  independent recorder, because the first recorder ran phase-locked just
  after the puppet's write and read 0 while the detector read 0.35 m.
* **Free-space targets by ray**, after the first target landed inside a table
  and produced a push-out that looked like a fight.
* **The debug door as the order stand-in**, because it is the engine's own
  queue with typed arguments one call below; the native reach is the
  worker it calls (findings §11).
* **A probe DLL for speed and threads.** The prompt allowed probe detours;
  there was no other way to set `+0xF8` or to see thread IDs and frame
  order.
* **Position-follow as the design base**, not order relay, because it was
  the variant proven live and it corrects drift by construction.
* **Stopped at R5 (NPC-state requests).** Decoding the state-search request
  is its own RE session; the live criterion-6 answer is left inconclusive
  rather than guessed.

## 6. Not done, inconclusive, stated plainly

* **Two-player: everything.**
* **Sit down / stand up with animation / use a workstation** on a suspended
  copy (R5). Only the instant reset (R6) ran.
* Native reads of stance / unstance / location object (NPC context layout).
* R4 (per-frame controller input) — timing window observed, not probed.
* How the suspension cancels the in-flight move (the WO-108 tail): observed
  stop, mechanism not traced.
* The alignment solver's per-frame pull: strings found, the solver not
  traced; the default of `IsAligned` for unstances that omit it.
* Orders from the DLL's frame hook (all live orders came from Lua timers on
  the main thread).
* Scale above 10 NPCs at 10 Hz; frame cost without the debug door's
  per-order log line.
* Body-orientation / strafing fields in the Warhorse request (combat
  footwork on a copy).
* Whether `wh_ai_*` debug commands exist on retail.
* Where the walk throttle (0.8) is applied (the brain's walk 1.41–1.44 m/s
  vs the door's 1.70).

## 7. Side effects on the machine (disclosed)

* **Saves written** in `<saves>/playline1`: `quicksave032` (fresh throwaway,
  09:30, written right after `SetWorldTimeRatio(1)`; if the ratio is saved,
  loading it gives real-time clock speed). Safe to delete. Nothing else in
  `<saves>` was written.
* **NPC state in the running sessions:** about fifteen NPCs were suspended,
  moved and/or had their `Stance`/`Unstance` element reset; all were
  resumed and walked back to their activities. None of this was saved.
* **`kcd.log` rotated once** (the relaunch); the pre-session log, both
  session logs and both probe logs are in `<scratch>`.
* The probe DLLs, their logs, the Ghidra projects and every probe script
  stay in `<scratch>` only.
* The game was quit with `System.Quit()` at the end.
