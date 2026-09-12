# WO-84 — progress

Started and completed 2026-09-11. Investigation of three symptoms from the
0.20.6 two-player field session: a ghost reported faction-less 265–266 times, an
animation-queue overflow storm of ~9,000 errors on one entity, and a chain-leak
event whose signature matched nothing WO-78 fixed.

Full evidence and verdicts: [WO-84-findings.md](WO-84-findings.md).

---

## Phase 0 — read first

- `git pull` — `main` already current at `b39799f`.
- Read `KCD2MP_SpawnGhost`'s faction block, `chainMayStart`,
  `KCD2MP_NpcPuppetTick`, `KCD2MP_UpdateAnimation`, `KCD2MP_ReconcileGhosts`.
- Read the historical inert-`esFaction` record in full:
  `WO-34-findings.md` §1.3 (property write takes, changes nothing — live),
  `WO-16-findings.md` (reads `nil` off real NPCs),
  `WO-26`/`WO-56-findings.md` (the error is a non-fatal null return from
  `C_NPCFactionNode::GetFactionPtr`), `WO-54-findings.md` §5.2,
  `WO-64`/`WO-65`/`WO-68` (civic isolation went to script contexts instead),
  `NATIVE-PLUGIN-findings.md` (the native `SetParent` route).
- **No `docs/WO-83-*.md` exists.** Nothing in this project has concluded
  anything about `ttac_man_9` or Guard-class behaviour; that question is
  unasked. Recorded rather than inferred.

## Phase 1 — the faction gap

Root cause found, and it is not where the prompt pointed. A faction-assignment
attempt **does** exist in the spawn code; it is unverifiable rather than absent.
But the 265–266 errors are a **different entity**: a ghost body serialised into
the savegame by a previous session, restored soul-less on every entity
reconcile pass. Universal, not soul-specific — nothing in the path branches on
soul or class.

WO-58 had already described this exact failure and written the fix
(`KCD2MP_SweepStrayGhosts`); the fix was only reachable from `mp_remove_all`
and `KCD2MP_Stop`, neither of which ran in any of the three sessions.

New measurement nobody had made: the **horse** spawn path, running the same
`AI.ChangeParameter("Civilians")` in its own `pcall`, makes the engine print
`AI: Unknown faction 'Civilians' being set...`. The value is rejected. The
ghost path never prints it across eight spawns, which is now instrumented.

## Phase 2 — the consequences

| Hypothesis | Verdict |
|---|---|
| Missing faction causes the animation overflow | **Ruled out** — both machines' live ghosts overflow, on different souls and clips, and neither ever throws a faction error |
| The storm is specific to `ttac_man_9` | **Ruled out** — no soul branch exists; the host's ghost uses `ttro_man_59` |
| The storm is a per-tick `StartAnimation` supply problem | **Confirmed** (code-verified, plus git provenance: commit `57f13f5` removed the original guard) |
| A local menu amplifies it | **Confirmed** (observed, 15–20× enrichment, and the agent's own pump-rate lines) |
| A menu is *required* for it | **Ruled out** — the earlier session stormed with zero overflows inside any menu window |
| What stops the queue draining outside a menu | **Not identified** — engine-side, needs a live probe |
| The leak is a new mechanism, not WO-78's | **Confirmed** (code-verified self-stop race) |
| No timer suspension occurred in the leak window | **Refuted** — 19.19 s clock gap and `tickstat max=19187.0ms` |
| The camera teleport is connected to the leak | **Common cause, not a link** — both follow the map screen closing |

## Phase 3 — fixes

1. **Ghost animation throttle** (`mp_anim_loop`). Restart a looped clip on a
   change plus a keep-alive, across all four looped ghost call sites. Guards on
   clip name as well as tag; a pumped frame never takes the keep-alive.
   Rollback: `mp_ghost_anim_refresh 0`.
2. **Puppet-chain generation retirement.** A generation that stops itself
   retires its in-flight timer, which then exits silently instead of being
   reported as a leak. Real leaks still report. Same retirement applied
   preventatively to the interp chain at `KCD2MP_Stop` — **never field-observed
   there**, and labelled as such.
3. **Leak firings are counted** separately from the once-per-session report, so
   a second leak is not hidden behind the first.
4. **The stray sweep runs during play**, off the agent's existing 5 s reconcile
   call, throttled to 30 s, ids widened to 0..63, removal confirmed over two
   sweeps, horse branch removal now verified. Toggle: `mp_ghost_sweep on|off|now`.
5. **The faction attempt is logged**, split out of its shared `pcall`, including
   whether the entity has an AI object. No behaviour change.

Scoped and deliberately **not** done: changing the `"Civilians"` string to a
real faction id, and any native faction attach. Reasons in the findings §1.6
and §5.

## Phase 4 — verification

Synthetic only. No live game was available this session.

| Suite | Result |
|---|---|
| `tools/Test-GhostInterpSynthetic.ps1` (WO-78) | 35 passed, 0 failed |
| `tools/Test-NpcSmoothSynthetic.ps1` (WO-77) | 48 passed, 0 failed |
| `tools/Test-WO84Synthetic.ps1` (new) | 72 passed, 0 failed |

The new suite extends the existing MoonSharp harness rather than inventing a
style: same driver, same stubs, same fake clock, new scenario file. Headline
numbers it pins:

- 2 s of 20 ms ticks on a stationary ghost: **101 → 3** `StartAnimation` calls.
- 2 s of 80 Hz pumping: **160 → 1**.
- The self-stop race reproduced end to end, the orphan absorbed with no leak
  line, no toast, no write and no reschedule.
- Landing from a jump re-asserts the locomotion loop on the very next tick.
  Writing that test found a real regression the first cut of the throttle
  introduced: the vz-driven jump branch is the one one-shot site in the file
  that sets no `oneShotUntil`, so nothing cleared the loop guard for it, and a
  ghost running before and after a jump would have held the jump pose until the
  next keep-alive. Fixed and covered.
- An unretired stale generation still reports, still toasts, and a second leak
  is still counted behind the latch.

**Unverified, stated plainly:** that the game's animation queue actually stops
overflowing; that a ghost still looks right to a person; that the reported
"animation not smooth" complaint is resolved by this rather than by the
separate WO-69/WO-75 jitter work; and whether a save-restored body really
stands in a loaded world. The first live session answers all four, and the
sweep and faction lines are written to report themselves when it does.

## Housekeeping

- `VERSION` unchanged at `0.20.6` — the maintainer owns version numbers.
- Next free wire byte unchanged at `0x32`; no protocol change in this WO.
- **`kdcmp.pak` was deliberately NOT rebuilt.** Editing `kdcmp.lua` changes
  nothing in a running game until `tools\Build-And-Install-Mod.ps1` repacks it
  and the game restarts. The project's own pattern is to land Lua changes and
  repack at release time alongside the version bump — WO-82's
  "version 0.20.6, pak rebuild for WO-78/80/81" did exactly that for the three
  WOs before this one. **These four fixes are therefore not live until the
  maintainer rebuilds the pak.**
- No live game was reachable from this session, and installs from here land in
  a redirected AppData sandbox, so nothing was installed or verified in-game.
