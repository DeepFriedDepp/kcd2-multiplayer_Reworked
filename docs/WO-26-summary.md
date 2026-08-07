# WO-26 — session summary

**Date:** 2026-08-06 · **Branch:** `main` · **Commits:** `f49b396`, `9d2c4d0`, `e7b0250`, `e265a55`

**Shipped code changed: none.** `kdcmp.lua`, `native/`, `dotnet/`, `VERSION`
and the installer are untouched. Everything below is investigation and design.

This is the short, shareable version. The full evidence is in
[`WO-26-findings.md`](WO-26-findings.md); the implementation plan is in
[`WO-26-shared-combat-design.md`](WO-26-shared-combat-design.md).

---

## The question

Make NPCs treat a connected player the way they treat Henry — ignored until a
fight starts, drawn into real combat when it does, released afterwards. Two
candidate routes: make players actually *be* Henry (the bigger one), or give
ghosts reactive combat without a permanent hostile-faction flag (smaller, but
the obvious version of it breaks the WO-20 face roster).

## Headline: the goal was already met, and nobody had tested for it

A ghost spawned with `KCD2MP_SpawnGhost`'s **exact current shipped shape** —
roster `SharedSoulGuid`, `Civilians` faction, `aggroEnabled=false`, no `AI.*`
binds, no native `SetParent` attach — already does this.

**Attacked directly:** registers the hit as a crime
(`crime_interrupt_confronting`), flips `HasMeleeWeapon` true on its own
initiative four seconds later, registers the attacker, and **took the human
from 100 to 57 HP in one exchange.**

**Combat nearby, ghost not the target:** engaged a hostile bandit ghost it was
never told about and, in the first pass, **pursued it 340 m and killed it**
(`IsDead=true`, read from the API). The instrumented re-run captured a full
KCD2 sword duel between two ghosts — mutual `AttackersCount`, `morale_context`,
master strikes, `injured_head`/`injured_torso`/`bleeding`, 100 → 92.6 → 76.7 →
64.7 → 48.0 — with the player's health frozen at `47.2655` in every sample, so
it was a clean bystander test rather than a three-way fight.

Three prior sessions (WO-20/24/25) hunted for an aggro lever that was already
in the build. This has been live for users since WO-22 gave ghosts real souls,
undocumented.

**Untested clause:** whether a ghost de-escalates once a fight ends. Neither run
ended cleanly — one ended with the human flying away, one with a kill.

## "Can a player be Henry?" — closed, by crash

The player is a distinct class at three independent layers:

| layer | player | generic NPC |
|---|---|---|
| entity class | `Player` (own `player.lua`, `type = "Player"`) | `NPC` (**no `type` field**) |
| AI object | `AIOBJECT_PLAYER` = 100 | `AIOBJECT_ACTOR` = 5 |
| soul class | `player` (id 5) — only 3 souls shipped | various |

I recommended stopping on the static evidence. **The human directed running the
live test anyway, and was right to** — it turned an inference into an
observation. `XGenAIModule.SpawnEntity{ClassName="Player"}` produced:

```
[Warning] no archetype found for 'wo26P' of class 'Player', returning 0
[Error] NPC wo26P does not have a faction.      x52
```

…then BugSplat fired and the process died.

So `Player` is a genuinely registered, spawnable class — but the second
instance comes up malformed and it is fatal. The structural reason it cannot be
fixed from Lua: **`SoulList::PlayerSoul` is a single read-only `Soul*`** holding
`player_henry`. Everything downstream of it (`g_localActor`, faction
assignment, archetype lookup) is single-slot.

*Correction made mid-session:* after the tool call was rejected I said the spawn
had not run. It had — `wo26P` was in the log. Corrected as soon as I saw it.

## What actually blocks shared combat

Measured on the real shipped path (registered ghost, `InterpTick` streaming)
against a hostile bandit:

```
17:08:20  hp=100.0  atk=1  melee=true   pos=2379.8083,2256.4834,131.01125
17:08:32  hp=23.8   atk=1  melee=true   pos=2379.8083,2256.4834,131.01125
17:08:41  hp=0.0    DEAD                pos=2379.8083,2256.4834,131.01125
```

Byte-identical position in all 14 samples, from full health through death,
while the combat AI was fully engaged. **The ghost did not lose because it
cannot fight. It lost because it cannot move** — `InterpTick` overwrites its
position 50×/second, and KCD2 melee is almost entirely footwork.

That pin is *correct* and should not be removed: a ghost must mirror its
owner's real footwork rather than fight it. Which relocates the problem — the
ghost should be a damage **sensor**, and the outbound emitter
(`kdcmp.lua:128`) carries only `x y z rotZ flags`. No health, no damage, no
death. When the test ghost died, the player it represented would have kept
playing at full health.

**The AI half of shared combat has been solved since WO-22. What is left is a
wire-protocol change.**

## Deliverable: the shared-combat design

Written at the human's explicit direction ("Design it now, implement next
session"). Nothing implemented. Two constraints lead it, because they are what
would sink a naive build:

1. **The existing `0x12`–`0x15` damage messages cannot be reused.** They key on
   `SharedSoulGuid`, which `Protocol.cs` already documents as valid only for
   hand-placed souls — and every player's Henry carries the *identical*
   `player_henry` GUID, so a soul GUID cannot distinguish one player from
   another even in principle. Players must be addressed by `ghostId`.
2. **Each peer runs an independent world simulation; NPCs have never been
   synchronised.** So this delivers *one agreed answer about who got hurt and
   who died* — **not** everyone watching the same battle. That would need NPC
   position and state sync, which this project has never attempted.

Three flows, in build order:

| | mechanism | testable with |
|---|---|---|
| **A** player health, continuous | `0x1F`/`0x20` + a `v2` emit line | synthetic-peer harness, no second machine |
| **C** player death | `0x23`/`0x24`, sent by the dying client | as above |
| **B** NPC→player hits | `0x21`/`0x22`, polled from ghost health in `InterpTick` | needs two real players |

Death is a separate packet, never inferred from health hitting zero — the same
reasoning `Protocol.cs` already gives for `0x14`.

Authority: **you own your own health; the host owns NPC→player hits.** The
host-authority cost is recorded rather than buried — NPC combat stops mattering
when the host is paused or their NPCs are not ticking, which was observed
happening at 340 m.

## Bug found in passing — fix before implementing

`KCD2MP.ghosts` held **three registered ghosts that were all one player**:
distinct entity ids, all renamed to the same Steam nick by `ApplyGhostName`,
two `NPC_Female` and one `NPC` (so the face pick is not deterministic across
reconnects either), all streamed onto the host's own position. This is what the
human saw as "an NPC attached to me." Cleared them; **they regenerated within
minutes** — an active leak, not stale state.

Causes: `SpawnGhost`'s dedupe keys on connection id, so a reconnect orphans the
old ghost; and `ApplyGhostName`'s `SetName` renames the entity away from the key
the `SoulList` uses (`SoulsByName/Player91` 404s while `SoulsByName/kcd2mp_91`
resolves), so name-based removal cannot find it.

Filed as separate work. **Flow B routes by `ghostId` and would misroute or
triple-apply while this is live.**

## Corrections forced on prior findings

- **WO-22 A2** ("the ghost fights back is not demonstrated") — superseded.
- **WO-22** "soul-only ghosts are byte-stationary" — true only *while idle*;
  340 m in combat.
- **WO-25 Phase 2** — its conclusion stands, but
  `AI.GetAttentionTargetType`/`GetPeakThreatLevel` must never be cited for it:
  both read **0 through genuine, damage-dealing combat**.
- **WO-25 Phase 4's blocker is moot.** The face/soul conflict only exists if
  hostility requires swapping `SharedSoulGuid`. It does not.
- `Scripts/FeatureTests/found_checkpoints.csv` looks like a goldmine (real C++
  filenames and line numbers) but is **stale Crysis 3 SDK boilerplate**. Not
  used as evidence here; recorded so nobody re-mines it.

## Safety

Save re-confirmed disposable at session start (not inherited silently from
WO-25) and backed up to `playline2_wo26backup`. The first proposed test site was
refused — the human said they were clear of everything, the sphere query said 18
actors within 40 m; re-checked after they moved and got 0 within 60 m.
**No real NPC was damaged or killed** — unlike WO-25, every combatant was a
mod-spawned test entity. All test entities swept and confirmed at 0.

## Open, ranked

1. **Fix the ghost leak** — blocks the design.
2. **Implement the design** in its stated order (health → death → hits).
3. **Does a ghost de-escalate?** The one clause of the goal still unestablished.
4. **What the aggro toggle and the `SetParent` attach are still for**, now that
   engagement is automatic without them.
5. **Player-proximity gating of AI** — observed but not attributed (distance and
   flycam changed together).
6. **Should a ghost's own AI attack at all?** It currently kills NPCs its owner
   never touched, invisibly to peers.

## Caveat on the design

None of it is measured. Every mechanism in
`WO-26-shared-combat-design.md` is derived from this session's observations and
the existing protocol — not from a working prototype.
