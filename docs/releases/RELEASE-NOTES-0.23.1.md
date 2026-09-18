# KCD2-MP 0.23.1

The label for everything on `main` as of WO-100.5 (2026-09-17), packaged as
`KCDMP-Setup-0.23.1.exe`. Setup exe only — there is no DirectInstall ZIP
(retired in 0.22.0).

---

## ⚠ BOTH MACHINES MUST RUN 0.23.1

This is the first release since 0.22.0 that changes the wire in a way a
mismatched pair **cannot** shrug off.

* The Position/Ghost packet grows five optional bytes behind a new flag bit. A
  0.22.x receiver sees an unrecognised payload length and **drops the packet
  whole** — so a mismatched pair loses *position sync*, not merely animation.
* The new action channel (`0x3B`/`0x3C`) is not forwarded by a 0.22.x relay, so
  it is simply absent.

Within one machine the **agent, the pak and `KCDMP.dll` are a matched set**.
Both directions degrade rather than break — an agent newer than the DLL logs
`MP-ANIM … disabled=1` once and falls back; a pak older than the agent ignores
the extra parameters and runs the old inference — but either way you are not
running what you think you are running.

**Native change.** `KCDMP.dll` is rebuilt and is *not* source-identical to
0.22.8.

---

## Verification status, stated plainly

Two things in this build were **live-verified** with the maintainer at the
keyboard. Everything else is **synthetic**, and nothing at all has run across
two machines.

| item | status |
|---|---|
| `NoAI` ghost bodies — what they keep and lose | **observed**, one solo session, two trials |
| The first native combat write | **live-verified** — it took, and the game consumed it |
| The native block *action* | **refused by the engine**, six argument combinations. Blocker named, not worked around |
| Locomotion replication (the body-state channel) | built, **synthetic only** — 33 checks |
| The discrete action channel | built, **synthetic only** — 16 tests |
| The guid-damage-fallback instrumentation | built, **synthetic only** |

`docs/WO-100.5-field-runbook.md` is the procedure for the two-machine session
this build exists to enable.

---

## What is actually in this build

### Ghosts can spawn without a brain (`mp_ghost_noai_on`, default **off**)

A ghost is the body representing the *other* player on your machine. It spawns
as an ordinary `NPC`, so the engine gives it a brain — and that brain
improvises: it gossips, greets, joins fights and walks off under its own power
(WO-26). That is the other player's body acting without the other player.

`mp_ghost_noai_on` passes the shipped `NoAI` parameter to the spawn call. The
body keeps its entity class, its soul, its face, its perception and its standing
as a crime victim, and loses the brain: **zero** situation registrations, zero
behaviour-tree activity, zero self-initiated dialogue.

**Default off**, for one reason stated plainly: with it on, a ghost no longer
defends itself. That is a product decision, and the thing it is meant to fix —
the sub-metre tug-of-war between a local brain and the remote position stream —
can only be measured with two machines.

The route not taken is worth recording, because it was the obvious one. Spawning
the ghost as the engine's own AI-less class `NPC_NAI` looks right and is not:

* the primary spawn call **silently builds `NPC` whatever class you ask for**
  (observed, 3 of 3), and the call that honours the class does not bind a soul —
  so you get the class or the soul, never both, and a soulless ghost is the old
  A1 unconsciousness bug;
* and where it *does* apply, it is worse than the problem. Across one session's
  log the engine booked **0** hit registrations on an `NPC_NAI` body against 7
  on a `NoAI` one — so it is not merely imperceptible, it is outside the combat
  bookkeeping, and a ghost would stop being a crime victim at all.

`mp_ghost_nai_on` ships anyway and says exactly that every time it is switched
on, rather than quietly doing nothing.

### Ghost locomotion comes from the peer's real animation state (default on)

Until now a ghost's walk/run/sprint was **inferred** from the distance between
two position packets — a guess about what the other player was doing, made from
the only signal available. The peer now sends what their body is actually doing:
the live Mannequin pace, direction and stance, read natively.

Five bytes on the existing position packet, behind a flag bit, published at the
position stream's own cadence with no smoothing — because the underlying tags
were live-verified as stable continuous state, not the intermittent signal an
earlier sampling rate made them look like.

`mp_anim_legacy_on` restores the inference. The new path is **fail-closed**: a
peer that sends nothing, a value this build cannot name, or a posture the
chooser declines all fall back to the old behaviour for that sample. So the
worst case is 0.22.8's behaviour, not a frozen ghost.

`mp_anim_stats` prints the channel's counters.

### A discrete action channel (`0x3B`/`0x3C`)

One packet pair for every replicated action, carrying the **input** rather than
the result — a press that is never committed is a real event the remote body
should show and abandon, and a cancel is a message rather than an absence.

Attack edges cross the wire now and are logged and dropped at the receiver,
marked `dispatch=dropped-no-receiver`. That is deliberate: the native write that
would perform them was refused by the engine, and sending anyway proves the wire
half independently, so that when the write lands the only new work is the
dispatch.

### The first native combat write — and an honest half-result

The engine's own "what did the player ask for" state can now be written, not
just read. Verified live: the write took, read back at the correct width, and
**the game consumed it thirteen seconds later on its own** — which is what
separates "we changed a byte" from "we reached a live system".

Requesting a whole combat action (a block) through the same machinery
**returned null every time**, across five combat-star zones and both hand slots,
so the refusal is not the arguments. It was tried on the player; every shipped
call site in the game uses it on an AI-driven body instead, and that is the next
step. No attack was attempted.

Two things the previous work-order handed over were wrong and are corrected in
the code: one function is not the property setter it was described as (calling
it that way would have written a stray byte into the combat model), and the
engine does *not* log this action's failure the way it was thought to.

### Better field visibility

* `MP-ANIM` — the body-state channel, outbound and per peer.
* `MP-ACTION` — the action channel, with a named reason for every refusal.
* `MP-GHOSTCORR` — **correction magnitude and snap count** for the ghost
  smoother. These were missing, and they are the two numbers that tune the
  smoothing that already exists.
* `MP-DMG route=guid-fallback` — the damage path that addresses targets by an
  unstable per-save id now says when it fires and whether it resolved. It was
  field-measured at 571 of 571 failures on one machine and 176 of 176 successes
  on another, and until now nothing in a log distinguished "fired and did
  nothing" from "never fired". Disable it entirely with
  `--no-guid-damage-fallback`.

### Closed, negatively: airborne animation state

Replicating jump/fall/land was a standing candidate. It is now answered from
shipped data and needs no further investigation: those tags are
**fragment-selection tags, not live state** — no animation context carries a
readable airborne bit, and the engine expresses being airborne by *which
animation is playing*. Ghost jumps stay inferred from the vertical rate of the
position stream, which is what they already did; that is now a considered choice
rather than a gap.

---

## Toggles and defaults

| toggle | default | command |
|---|---|---|
| Ghost `NoAI` spawning | **off** | `mp_ghost_noai_on` / `mp_ghost_noai_off` |
| Ghost `NPC_NAI` class swap | **off** (not recommended) | `mp_ghost_nai_on` / `mp_ghost_nai_off` |
| Legacy (inferred) ghost animation | **off** — the new path runs | `mp_anim_legacy_on` / `mp_anim_legacy_off` |
| Guid-addressed damage fallback | **on** | agent flag `--no-guid-damage-fallback` |

Console commands are argless: the console drops arguments.

---

## Tests

* 33 new synthetic Lua checks (the body-state channel and the ghost-class
  toggles), against the real `kdcmp.lua`.
* 16 new agent tests (the action channel: ordering, the 16-bit sequence wrap,
  the generation rule, the edge machine).
* **127 of 127** agent tests green.
