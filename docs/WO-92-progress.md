# WO-92 progress

Read `docs/WO-92-findings.md` first — it carries the evidence. This file is the
state-of-play.

Investigation only. **No feature code. No `VERSION` change. No live game
touched.**

## Status

| Item | State |
|---|---|
| Phase 0 — ground truth | **Done.** `main` at `05c9cb3` (WO-90's head), clean. WO-90 read in full. **No `WO-91` doc or commit exists on any branch** — WO-91 was written but never run, so this was fresh ground. |
| Phase 1 — Track A, the surface check | **Done, and it is NOT empty.** All 6,852 documented commands/cvars parsed and cross-validated. No quest/objective *setter* exists in either build — but `wh_concept_HasteTrigger` ("Fires a Haste trigger using its debug name") does, on the build players run. |
| **The correction that unlocked it** | **WO-90 gated every lever on the RETAIL binaries. The mod only ever runs on the Modding Tools build** — retail is hard-refused by the installer and twice by the launcher, and the field logs confirm it. A retail-absence result does not disqualify a lever. WO-90's gate produced a false negative, and Haste is what it hid. |
| Phase 2 — Track B, going native | **Genuinely attempted on three fronts, all answered.** RTTR write route: **not viable**, two independent blockers. QuestModule exports: dead end. ConceptModule exports: a real read + trigger-pulse surface, but **no state setter exists anywhere**. |
| Phase 3 — world consistency | **Answered, and it is the decisive result.** Haste is genuinely better than a state write — it injects at the same graph edge the real event drives, so the one-shot consumers fire. But seven things stay unreconstructed, and **six live paths carry B's replay onto A's machine**. |
| Verdict | **Exists but produces an inconsistent world** (inconsistency named exactly), **plus read works / no safe write found** for the native track. For the multiplayer question specifically: **no**, as things stand. |
| STOP-rule compliance | **Seven live-game boundaries reached, seven stops.** Enumerated individually in findings §8. Nothing was launched, attached to, injected, called or modified. |
| Adversarial verification | **Survey pass verified** (24 claims: 7 CONFIRMED, 14 OVERSTATED, 3 REFUTED). **Deep pass NOT verified** — all 20 verifiers failed on a session limit, so findings §5 and §6 are single-source. Recorded as such rather than presented as settled. |
| `VERSION` | **Unchanged.** |

## The answer in six lines

1. A sanctioned story-advance lever exists: **`wh_concept_HasteTrigger`**,
   Warhorse's own jump facility, reachable through the console channel the mod
   already has, with **zero new plumbing**.
2. Coverage is excellent — 3,745 entry points, 93.6% of Final quests, **all 32
   main-story quests** including `prepadeni`.
3. It is **not** a counter-write: it drives the real transition, so the
   edge-triggered one-shots genuinely fire. A raw state write would not.
4. Track B's write routes are all dead. RTTR `set_value` exists in this engine
   for exactly one purpose — deserializing authored graphs from XML at load.
5. But Haste leaves the dialogue ledger, rewards, crime, schedules,
   exploration, elapsed time and ordering unreconstructed.
6. And in this mod's shared world it is not contained: teleports, NPC deaths,
   the world clock, autosaves, streaming and cutscene suspension all cross to
   the other player.

## What changed

| File | Change |
|---|---|
| `docs/WO-92-findings.md` | New. The evidence. |
| `docs/WO-92-progress.md` | New. This file. |

Nothing else. No source file, no data file, no `VERSION`, no pak, no native
DLL. Neither game install was modified and no save file was touched — the one
save inspected was copied to a scratch directory first.

## What a follow-up work order should do

In priority order:

1. **Rung 0 of the probe ladder** (findings §10) — send `wh_concept_HasteEnable`
   as a bare cvar query and grep `kcd.log`. Zero risk, mutates nothing, and it
   answers the single question gating everything: does a `VF_CHEAT` command
   execute at all as the launcher starts the game? Static reading says yes
   (dev mode defaults on, launcher passes no arguments) but it has never been
   observed. If it fails, the fix is one line in
   `KCDMP_launcher/Pages/Home.razor.cs:521`.
2. **Take the `CutscenePlayer` module-path signal** (findings §7.2). It is
   *already in the log*, fires ~2.3x more often than the shipped
   `questNameOverride` marker, and carries the quest's internal concept-graph
   name rather than a localisation key. Cheapest real improvement to story
   telemetry; needs no engine cooperation and no live testing to build.
3. **Build the readiness prompt on reads, not writes.** The work order that
   follows this one was scoped to build a readiness-prompt mechanism. This
   session's evidence says that mechanism should *detect and communicate*
   divergence — which is well-supported — and should **not** try to converge it
   by advancing anyone's story.
4. **Do not pursue Haste convergence without a no-emit quarantine.** The gate
   is not "does Haste work" — assume it does. It is "can the replaying client
   be fully silenced for the duration", emitter and claims and death-announce
   all frozen, with a forced save/reload afterwards. Even then findings §6.3
   stands.
5. **Re-run the deep pass's 20 adversarial verifiers.** They never ran.

## Traps recorded for future sessions

* **The retail gate is wrong for this project.** Ask "does it ship on the
  Modding Tools build", not "does it ship on retail". This session found one
  false negative caused by the old gate; there may be more in WO-90-era work.
* **`wh_sys_LoadGame` is absent from retail** — the apparent hit is a substring
  of `wh_sys_LoadGameFilter`. WO-73's headless result is Modding-Tools-only.
* **The pre-extracted string dumps hide 4-character strings** (5-char minimum)
  and carry **file offsets, not RVAs**. Several first-pass claims quoted
  offsets as addresses and were corrected in verification.
* **A case-insensitive search for `quest` matches `Request`** — 46 of 54 raw
  name hits were false positives. Use `(?<![A-Za-z])[Qq]uest`.
* **Never set `wh_concept_HasteOnly`** — it empties the concept-graph load list
  entirely, so the game loads no quest content at all.
* **`TestModule.dll` is not a unit-test binary** — it is a data-driven autotest
  command framework and imports nothing from `QuestModule.dll`.
