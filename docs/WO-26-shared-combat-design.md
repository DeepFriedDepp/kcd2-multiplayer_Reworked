# Shared combat — protocol design

Written 2026-08-06 at the end of WO-26, at the human's direction ("Design it
now, implement next session"). **Nothing here is implemented.** This is the
plan the next session should argue with before building.

Goal, in the human's own words: *"true shared aggro and shared combat… as
seamless as we can make this… so the host and all joining players can partake
in small battles to giant ones."*

---

## 1. What already works, and what is actually missing

WO-26 Phase 0 established that the AI half is **already done** and has been
since WO-22. A shipped ghost is a real NPC with a real soul and brain: hostile
NPCs pick it as a target, it registers attackers, it arms itself, it fights,
and it can be killed. None of that needs building.

WO-26 Phase 3 established what stops that from being *shared*. Two things:

**(a) A ghost cannot move itself, by design.** `KCD2MP_InterpTick` writes
`SetWorldPos` every 20 ms. Measured: a ghost went from 100 HP to dead over 21 s
with a byte-identical position in all 14 samples while its combat AI was fully
engaged. This is correct and should not be "fixed" — the ghost must mirror its
owner's real footwork, not fight it. But it means **the ghost's own AI must
never be the thing that decides a fight.**

**(b) Nothing about a ghost's health reaches its owner.** The outbound emitter
(`kdcmp.lua:128-140`) sends exactly:

```
[KCD2-MP-DATA] v1 <seq> <clock> <x> <y> <z> <rotZ> <flags>
                                       flags: 1=riding, 2=sneaking
```

Position, rotation, two booleans. When the test ghost was killed, the player it
represented would have kept playing at full health.

The existing `0x12`–`0x15` Damage/Death messages **cannot** be reused for this,
and `Protocol.cs` already says why in its own comments: `targetGuid` is a
`SharedSoulGuid`, valid as a cross-client key only because it is authored
content byte-identical on every install — *"only hand-placed souls may be
addressed here."* A ghost is runtime-spawned. Worse, every player's real Henry
carries the **same** `SharedSoulGuid` (`4c2dcffb-…` = `player_henry`, confirmed
live in WO-26 Phase 1), so a soul GUID cannot distinguish one player from
another even in principle. Players must be addressed by `ghostId`.

---

## 2. The constraint that shapes everything: worlds are not shared

This has to be stated before any packet layout, because it is the thing most
likely to make a naive design fail.

**Each peer runs an independent single-player simulation.** NPC positions,
schedules, aggro state and combat decisions are not synchronised and never have
been. The existing damage replication works around this rather than solving it:
one player lands a blow, and the *hit* is replicated by soul GUID so every
peer's own copy of that NPC loses the same health. It replicates **outcomes**,
not the fight.

Consequences that must be designed for, not discovered later:

- A bandit attacking your ghost in the host's world **does not exist** in your
  world. There is no local event to react to.
- If every peer's local NPCs independently attack their local copy of every
  ghost, then N peers generate N independent damage streams for the same
  conceptual fight. Applying all of them multiplies damage by N.
- "Giant battles" in the sense of *everyone seeing the same battle* is a much
  larger problem than damage replication — it would need NPC position and state
  sync, which nothing in this project has ever attempted. **This design does not
  deliver that, and should not be described as if it does.**

What this design *can* deliver: every player can be hurt and killed by NPC
combat, consistently, with one agreed answer about who is hurt and who is dead.
That is the difference between "players can fight alongside each other" and
"players watch separate movies."

---

## 3. Authority model

Two rules, and everything else follows from them.

**Rule 1 — a player's health is authoritative on that player's own machine.**
Only your client decides your health. Everyone else displays a copy. This is
the only rule that cannot produce a disagreement that fails to self-correct.

**Rule 2 — NPC-versus-player combat is authoritative on the session host.**
Only the host's NPC simulation is allowed to generate NPC→player hits.
Non-host peers must suppress their local equivalent. This is what stops the
N-peers-N-damage-streams problem, and it is the smallest possible authority
claim that does so.

Rule 2 is a real commitment with a real cost: if the host's game is paused,
stuttering, or the host is far away and the NPCs there are not ticking (WO-26
observed AI going quiet at 340 m with the player airborne), then NPC combat
stops mattering for everyone. That is a genuine downside and the next session
should weigh it against the alternative — per-region authority — before
building. Host authority is recommended because it is simple and debuggable,
not because it is obviously best.

---

## 4. The three flows

### Flow A — a player's health, continuously (new)

Needed so every peer can render a ghost at the right health, and so death is
visible. Cheap, and it makes ghost health correct regardless of how it changed
(NPC hit, fall damage, poison, starvation).

Extend the emit line to `v2` and add health/stamina:

```
[KCD2-MP-DATA] v2 <seq> <clock> <x> <y> <z> <rotZ> <flags> <health> <stamina>
```

`v1` must keep parsing — `LogTailGameTransport` should accept both and treat a
`v1` line as "health unknown, leave it alone", so a mixed-version session
degrades instead of breaking.

On the wire, rather than widening `Position` (`0x01`) and `Ghost` (`0x02`) —
which are the hottest packets in the protocol and are size-sensitive — add a
separate, lower-rate pair. Health changes far less often than position:

```
C→S  0x1F  PlayerStateUp:   [health:4f][stamina:4f][flags:1]              (9)
S→C  0x20  PlayerStateDown: [ghostId:1][health:4f][stamina:4f][flags:1]   (10)
                              flags bit 0: isUnconscious
                                   bit 1: isBleeding
```

Send on change beyond a threshold (say 0.5 HP) or at most ~4 Hz, not every
tick. Receivers set the ghost's health from this and do not compute it.

### Flow B — an NPC hurts a player (new, the actual gap)

Host-side detection is the "damage sensor" role. `KCD2MP_InterpTick` already
iterates every ghost every 20 ms; sampling `ghost.entity.actor:GetHealth()`
there and diffing against the previous value costs almost nothing and needs no
native hook.

```
C→S  0x21  PlayerHitUp:   [targetGhostId:1][health:4f][stamina:4f][flags:1]  (10)
S→C  0x22  PlayerHitDown: [health:4f][stamina:4f][flags:1]                   (9)
```

`PlayerHitUp` says "the ghost representing player N lost this much in my
world." The relay routes it to player N and drops the `targetGhostId` — the
recipient does not need to be told it is about themselves.

Guards, in order of how easily they are got wrong:

1. **Only the host sends `PlayerHitUp`.** Rule 2. A non-host client that
   computes a ghost-health delta must discard it.
2. **A delta caused by an inbound `PlayerStateDown` is not a hit.** When the
   owner's authoritative health arrives and the host writes it onto the ghost,
   that write will show up as a delta on the next sample. It must be
   suppressed, or every real hit echoes forever. This is the same loop-
   prevention problem `Protocol.cs` already solves for `0x12` by keeping it as
   local state, and it should be solved the same way: mark the ghost
   "externally written, skip next delta."
3. **Only negative deltas are hits.** Regeneration is not a hit.
4. The recipient applies the damage to their real Henry and then their normal
   Flow A broadcast tells everyone the new authoritative health. The host must
   **not** keep its locally-damaged ghost health — it will be corrected by
   Flow A, which is the point.

### Flow C — a player dies (new)

Death gets its own packet for exactly the reason `Protocol.cs` already gives
for `0x14`: two clients computing "dead" from slightly divergent health will
eventually disagree, and that disagreement does not self-correct.

```
C→S  0x23  PlayerDeathUp:   []                    (0) -- "I died"
S→C  0x24  PlayerDeathDown: [ghostId:1]           (1)
```

Sent by the **dying player's own client** (Rule 1), never inferred by a peer
from health hitting zero. Idempotent; a repeat for an already-dead player is
ignored. What death should actually *do* in KCD2 multiplayer — reload, respawn,
unconsciousness — is a game-design question this document deliberately does not
answer.

Next free type byte after this design: **`0x25`**.

---

## 5. What the ghost's own combat AI should do

This is the design decision WO-26 makes unavoidable, and it is not obvious.

The ghost's AI currently fights on its own. That is what makes it a valid
target and it must be kept — but a ghost that *lands blows on NPCs* is a second
player-shaped combatant acting without its owner's input, and the damage it
deals is not replicated (the existing `0x12` path fires from the DLL's
`LocalHit` hook on the real player, not on ghosts). So today a ghost hurts NPCs
in the host's world only, invisibly to everyone else.

Two options, and the next session should pick deliberately rather than inherit:

- **(i) Leave it.** Simple, and the divergence is bounded — NPCs are already
  unsynced. Costs: a ghost can kill NPCs its owner never attacked, and WO-25's
  concern about NPC deaths nobody chose applies with more force.
- **(ii) Suppress ghost-initiated attacks**, keeping only the ability to be
  targeted and hurt. Truer to "the remote player is the one fighting", but no
  lever for this is currently known — it would need something narrower than
  `NoAI`, which would also stop the ghost being a target.

Recommendation: **(i) for now, revisit after Flow B works.** (ii) is a research
task of its own, and shipping it is not on the path to the human's stated goal.

---

## 6. What to build first, and how to know it works

Deliberately ordered so each step is testable without the next one existing.

1. **Flow A only.** Emit `v2`, add `0x1F`/`0x20`, render ghost health. Testable
   with the existing synthetic-peer harness (`Test-AppearanceE2E.ps1` is the
   closest template) — no second machine needed.
2. **Flow C.** Small, and makes Flow A's failure modes visible.
3. **Flow B**, with the loop guard, host-only gate, and negative-delta rule.
   This is the one that genuinely needs two real players, because the whole
   point is a hit crossing machines.
4. Only then revisit §5.

**Fix the ghost leak before any of this.** WO-26 found three registered ghosts
for one player, actively regenerating, all stacked on the host. Flow B keyed on
`ghostId` will send damage to the wrong player, or three times, while that bug
is live. It is already filed separately.

## 7. Honest limits of this design

- It does **not** synchronise NPCs. Each peer still sees its own battle. What
  is shared is who got hurt and who died.
- Host authority means NPC combat stops mattering when the host's world is
  paused or its NPCs are not ticking.
- Polling ghost health at 20 ms detects *that* damage happened, not what caused
  it — no attacker attribution, which `NATIVE-PLUGIN-findings.md` already
  records as unavailable anyway (`TakeDamage`'s `Attacker` creates no combat
  history).
- None of this is measured. Every number and mechanism above is derived from
  WO-26's observations and the existing protocol, not from a working prototype.
