# KCD2-MP 0.22.8

The label for everything on `main` as of WO-99.5 (2026-09-17), packaged as
`KCDMP-Setup-0.22.8.exe`. Setup exe only — there is no DirectInstall ZIP
(retired in 0.22.0).

**Native change.** `KCDMP.dll` is rebuilt and is *not* source-identical to
0.22.7. Deploy the whole set together as usual.

**Verification status, stated plainly.** This release is unusual: most of it was
exercised live, with the maintainer at the keyboard, and one headline item came
back **negative**. Nothing here has run across two machines — the second player
still needs this build before any of the joint work can be measured.

---

## What is actually in this build

### Native: the player-soul pointer is refreshed (WO-99.5 Phase 0)

`g_player` was captured once during the RTTR walk and never refreshed
(code-verified). It is now re-read from `SoulList.PlayerSoul` on every rescan,
along with `g_combat`, and `g_rpg`/`g_souls` are re-read too so that a move
would be logged loudly instead of going quiet.

Damage credited on a peer's behalf is now carried across the 3-second tracked-set
rebuild, keyed by guid instead of by array slot. Health and dead-state are
carried with it deliberately: carrying credit alone would have been *worse* than
the original bug, because the cancelling health drop would still never be
observed and the stale credit would silently swallow the next genuine local hit.

**The honest part.** The mechanism WO-99 blamed for the `Dude` bug — "a save
load rebuilds the player soul at a new address" — **did not reproduce**. Three
within-process save loads, one of which changed the world substantially, left the
pointer at the identical address, verified live rather than merely unchanged
(WUID intact, positive and negative controls both behaving). The stale-pointer
defect is real and worth fixing; the trigger attributed to it is not established.
`docs/WO-99.5-findings.md` §1.4 names the alternative hypothesis to test next.

### Native: the quest concept port surface (WO-99.5 Phases 1–2)

`C_Node::GetPort`, plus the concrete slot-15 `Trigger` and slot-16 `Read`, are
implemented for the first time, driven by a `kcdmp-concept.txt` file watcher so
it can run during a live session without disconnecting the client.

**Nothing is fired.** The trigger is gated behind an explicit token *and* a
step-0 check that refuses unless the port's slot 15 really is the propagating
implementation. Both of this WO's targets were refused, which is the gate
working — and the probe corrected the static model in two places (six port
classes carry a real `Trigger`, not two; `GetDirection` returns a value the
documented model has no room for).

### Native: ghost situation isolation (WO-99.5 Phase 3a)

`DisableSituationParticipation` added to the ghost isolation context list. The
name was verified live against the running script-context database with both
controls behaving. Whether it reduces the ghost NPC-registration count needs a
connected peer and is unmeasured.

### Everything from 0.22.7

Unchanged and carried forward.

---

## What is NOT in this build

- No quest state is written. Phase 1 never fired.
- No cutscene gating. `Movie.PauseSequences` was shown live not to hold a
  prerendered cutscene.
- Nothing from the deferred two-player list.

---

## For the field session

`docs/WO-99.5-findings.md` §7 lists what to run. The short version: both machines
on 0.22.8, then the yield A/B and the first-reads list carried over from WO-99.
