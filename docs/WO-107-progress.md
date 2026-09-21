# WO-107 — progress: what ran, what did not, what blocked it

Session 2026-09-21. Findings: `docs/WO-107-ai-suppression.md`.
**No code written. No pak rebuilt. No installer. No VERSION bump.**

## 1. What ran

| phase | status | note |
|---|---|---|
| 0 — vanilla catalogue | **partial** | 2 rows measured, 1 non-discriminating, 9 not run. §2 |
| 1 — find the tick | **done** | located and classified; addresses in findings §1 |
| 2 — trace `NoAI` | **done** | answered **no** (not reversible), with the offset named; sibling `SuspendedAI` found |
| 3 — autopsy `wh_ai_PauseNPC` | **done** | lever works; bitmask decompiled; no clearer exists |
| 4 — find the chokepoint | **superseded** | §3 |
| 5 — sweep the surface | **done (static) / partial (live)** | 790 CVars+commands extracted; 5 confirmed live; scriptbind dumped |
| 6 — architect our own | **not needed** | recorded as not-recommended, findings §7/§8 |

### Method notes

* **Ghidra 12.1.3 headless**, full auto-analysis of `XGenAIModule.dll`
  (51 MB), ~50 min. No PDBs exist for any KCD2 binary. Functions were
  located by searching memory for embedded `__FUNCTION__` / literal
  strings and taking the containing function, then decompiling.
* **PyGhidra is not available in this install** — headless refused the
  `.py` post-script with *"Ghidra was not started with PyGhidra"*. The
  trace script was rewritten in **Java**, which headless compiles on the
  fly. Worth remembering for the next RE session.
* Live probing used the WO-106 §2 transport shape
  (`curl -G .../ExecuteString --data-urlencode "command=…"`), which
  worked unchanged.
* Measurement deliberately did **not** rely on the mod's own `npc_state`
  stream after the first attempt: NPCs drop out of the tracked set
  mid-window and produced a confounded reading (n=10 vs n=121). All
  quantitative results come from direct `GetWorldPos`/`GetWorldAngles`
  polling over the console.

## 2. Phase 0 — what was not done, and why

Measured (observed): **suspended-via-`wh_ai_PauseNPC`**, **unconscious**.
Attempted but non-discriminating: **conversation partner** — the NPC the
maintainer talked to (`ttkc_barbora`) was already stationary before the
dialogue started, so there was no self-direction to suppress; the row is
recorded as (inconclusive) rather than dressed up.

**Not run: dead, cutscene actor, scripted scene participant, sleeping,
sitting/working idle loop, bound/pillory/prisoner, companion wait order,
minigame participant, mount being ridden, trespass freeze / arrest.**

Reason, stated plainly: these each need the maintainer to drive the game
into a specific state, and the session's budget went instead into Phases
1–3, which found the mechanism directly. That was the right trade for
answering the WO's single question, but it does mean **the definition of
done's first bullet is not met.** Phase 0's stated purpose was to point
Ghidra at the right function; the 790-symbol string sweep did that job
first, so the catalogue lost its instrumental value before it lost its
deliverable value.

If a future session wants the catalogue, the harness is reusable: a
background recorder polling every soul-bearing NPC within 25 m of the
player at ~1.2 s, correlated against `kcd.log` afterwards, worked well and
needs no coordination with the player beyond "go do the thing now".

## 3. Phase 4 — superseded, not skipped

Phase 4 asked whether the stickiest vanilla states converge on a single
Warhorse suppression primitive. **They do, and Phase 1 found it directly**:
`C_IntelligentObject::Suspend`/`Resume` with a per-context bitmask is
demonstrably that primitive — it is multi-owner precisely because many
game subsystems assert it independently, which is what a convergent
chokepoint looks like from the inside. Tracing individual vanilla states
down to it would have confirmed a conclusion already reached by reading
the primitive itself. Recorded as a judgment call, not an omission.

## 4. Blocked / not attempted

* **Two-machine behaviour: not tested.** No peer. Every criterion-4 result
  is solo. The WO's own warning applies in full — a 38 Hz single-machine
  stream is a stream, but it is not the two-client case, and WO-104's
  result came from the joiner. **This is the single most important
  follow-up.**
* **Save/reload survival of a suspension: not tested.** Would have
  disrupted the maintainer's live session. Unknown whether the context bit
  persists across a load; `memory/kcd2mp-save-reload-behaviour.md` says
  Lua globals survive and timer chains die, which says nothing about
  engine-side AI state.
* **`wh_ai_UpdateEnabled 0`: deliberately not flipped.** It is global; the
  maintainer was mid-session with guards actively fighting them. Scored on
  its scope (fails criterion 3) rather than on an untaken measurement, and
  marked as such.
* **Root cause of the §4 position-relax: not established.** Ruled out the
  brain, the mod, and (via the unconscious control) a pure
  physics→entity-writeback explanation. Left open.
* **The crime/perception divergence** (attacking a paused NPC raised no
  guard response) is recorded as an observed side effect with **no
  mechanism established**.

## 5. Corrections this WO makes to the record

* **WO-104 §2's "the pause lever does not work under a live stream"** — the
  lever works. The `paused=1` field reports a Lua table, not engine state,
  and the `dist_m` it fired on is the position-relax, not a brain. Live
  re-test this session: pause held through a 38 Hz stream, melee damage,
  mid-combat application, a proximity change, and ~50 minutes.
* **WO-105 §7.5's "treat §7 as the shape of the problem Warhorse solved
  differently, not as a description of KCD2"** — the budgeted, time-sliced
  update model *is* present in the Warhorse fork
  (`floorf(frameDelta * k)` in `UpdateIntellects`). §7.2 carries over; §7.1
  (stock CryAI actor registration) still does not.
* **`mp_probe_npc_pause`'s shipped-off default** rests on the WO-104
  reading above. The mechanism behind it is sound; the maintainer owns
  whether the toggle flips.

## 6. Session hygiene

Everything touched was restored before the session ended:

* `wh_ai_ResumeNPC` issued for `tneb_man_31`, `ttkc_man_4`,
  `ttkc_woman_17`, and `Dude`. `tneb_man_31` verified recovered — walked
  27.32 m in 10 s with normal turning and navigation after ~50 minutes
  suppressed (observed).
* Test entities removed: `kcd2mp_w107_susp`, plus `mp_remove_all`.
* `mp_npc_sync on` restored (it had been switched off for one control).
* **`ttkc_barbora` was left ~4.8 m from where she fell** — she was knocked
  unconscious by the maintainer and then driven as the unconscious-state
  probe. She was not otherwise altered and wakes on her own.
