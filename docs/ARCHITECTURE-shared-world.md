# Architecture decision: shared ambient world, private quest content

Supersedes the parallel-worlds design in the engineering brief §4 for everything
except quest content. Decided 2026-07-27.

## The decision

**Shared:** ambient and hostile NPCs — wildlife, townsfolk, guards, bandits,
generic combatants. Their AI state, awareness, aggro, health and death are
synchronised so all players fight the same enemies.

**Private:** quest-critical and unique named NPCs, and all per-player
progression — quests, dialogue, journal, reputation, discovered locations.

**Dropped:** physics object synchronisation. The channel is a debug REST
endpoint at roughly 24-75 inbound calls per second; physics is not a realistic
use of it.

## Why the boundary is here and not at "world vs progression"

The original request was to split shared *world* from private *progression*.
That is how MMOs work, but MMOs are built for it: quest mobs respawn, quest
drops are per-player, phasing shows different objects to different players, no
NPC is irreplaceable. KCD2 is the opposite — hand-placed unique NPCs, no
respawn, and quests that permanently mutate the world.

With shared NPCs and private quests, the contradiction is immediate: player A's
quest needs a unique NPC alive, player B kills him, and A's questline is
permanently broken through no fault of B's. Questing *is* world mutation in this
game, so the boundary cannot fall between world and progression. It falls
between **generic and unique** instead, which preserves the same feel — one
living world, independent progression — without letting players destroy content
each other has not reached.

## Can a siege or a town raid be done together?

Yes, with one rule that follows from the above: **joint content requires both
players to have independently reached it.**

A KCD2 siege is quest-gated, so it only exists in a world where that quest is
active. If both players have accepted it, both worlds spawn it, and the
rank-and-file soldiers — generic, replaceable — are shared. The named commander
is not. Same for raiding a town: the guards and townsfolk are generic and
shared; the blacksmith who gives you work is not.

This is deliberately MMO-shaped. You both go to the siege, you both fight the
same soldiers, your damage adds up, and your quest credit is your own.

> **STATUS 2026-07-27, after behavioural testing: shared combat is not
> achievable on this API surface.** The methods for writing NPC health exist but
> are inert. See "Behavioural test results" below. The shared-ambient design as
> specified cannot be built; what survives is presence plus shared world time
> plus opt-in bubbles. The rest of this document is kept because the reasoning
> about *where* to draw the boundary remains correct and will matter if a future
> game patch or a native plugin opens these APIs.

## Behavioural test results

Enumerating the API said one thing; calling it said another. **Existence of a
method proved nothing.**

### Verified working

| Capability | Evidence |
|---|---|
| Read health | `player.actor:GetHealth()` = **73.1132**, stamina 113.816 — real decimal values, not a stub. NPCs genuinely read 100/100 because they were at full health. |
| **Set world time** | `Calendar.SetWorldTime(t+3600)`: 388805 → 392405, hour 12.0015 → 13.0014. Restored afterwards. **This one genuinely works.** |
| Enumerate NPCs | `System.GetEntitiesInSphere` — 267 entities at 120 m |

### Re-tested in the open world — result unchanged

The first round ran during the tutorial, which was a fair objection: tutorial
sequences commonly make the player invulnerable and script-protect NPCs. Re-run
after leaving the tutorial, and the answer is the same.

| Test | Result |
|---|---|
| Player `SetHealth(90)` from 100 — **downward**, so no max-health clamping excuse | stayed **100** |
| Player `soul:DealDamage(5)` | stayed **100** |
| Live open-world pig (`SpawnedAnimal_Pig_*`), `SetHealth(40)` | stayed **100** |
| Same pig, `soul:DealDamage(30)` | stayed **100** |

The first open-world attempt was itself invalid — the player was at full health,
so a +0.4 nudge would have been clamped and unobservable either way. Repeating it
downward removed that ambiguity. **Health writes are inert regardless of game
phase.**

Also learned: `entity:EnableAI(false)` **raises an error** on a real NPC — the
`pcall` returned false. That method is not available here, whatever the mod's
existing horse-mount code hoped.

### AI suppression: still untested after four attempts

Not because the API refuses, but because **no genuinely mobile subject could be
found**. Sampling 102 nearby actors twice over 3 s, 17 showed *any* position
change and the largest was 0.16 m — idle drift, not locomotion. The pig that
drifted furthest was completely stationary by the time the suppression test ran,
so "before" and "after" are identical for the same reason as every earlier
attempt.

This is worth less than it looks. Suppression without damage writes buys shared
ambient *movement* only — and the NPCs near the player are barely moving, which
undercuts the payoff. It is parked rather than pursued.

### Verified NOT working

`actor:SetHealth` and `soul:DealDamage` are **inert**. Tested on three
independent subjects:

| Subject | Attempt | Result |
|---|---|---|
| mod-spawned ghost | `SetHealth(50)`, `DealDamage(10)` | stayed 100 |
| wild hare | `SetHealth(37)`, `SetHealth(0.4)`, `DealDamage(50)` | stayed 100, via both `actor:GetHealth` and `soul:GetState("health")` |
| **the player** | `SetHealth(73.5132)` | stayed **73.1132** exactly |

The player case is decisive: reads on that same entity return real fractional
health, so the read path is sound and the write simply does nothing.

**Corroborating signal:** `SetHealth()`, `DealDamage()`, `CreateStimulusEvent()`,
`SetBehaviorTreeEvaluationEnabled()` and `SetAlarmed()` were each called with
**zero arguments** and none raised an error. A real binding expecting a number
reports "bad argument #1 (number expected, got no value)". Accepting anything
silently is what an inert stub looks like.

### Unresolved — three invalid tests, all my own fault

AI suppression and stimulus injection are still genuinely unknown, because
every test of them was broken:

1. **Suppression, attempt 1** — subject had a static position for the whole run,
   so there was no motion to suppress.
2. **Stimulus** — the `CreateStimulusEvent` signature was *invented* rather than
   found, which the project's first rule explicitly forbids.
3. **Suppression, attempt 2** — the "find a moving NPC" filter used
   `if AI.IsMoving(id) then`, but **`AI.IsMoving` returns `0` and in Lua `0` is
   truthy**; only `nil` and `false` are falsy. So it picked the first NPC
   regardless and the earlier "25 moving NPCs" figure is meaningless.

To settle suppression properly, detect movement by **sampling positions twice
and comparing**, rather than trusting any `IsMoving` return convention. To
settle stimulus, recover the real signature from the game's own scripts
(`Scripts.pak`) instead of guessing.

Even if both worked, they would buy shared ambient NPC *movement*, not shared
combat — combat needs the damage writes that are confirmed inert.

## Verified capabilities

Probed against KCD2 v1.5.2 on 2026-07-27 (`tools/probe_sharedworld.lua`,
`tools/probe_damage.lua`). Method names were discovered by enumerating the API
rather than guessed, including walking metatable `__index` chains — `pairs()`
alone misses inherited methods, which is why an earlier pass wrongly found
nothing health-shaped.

| Capability | Status | API |
|---|---|---|
| Read NPC health | **verified** | `entity.actor:GetHealth()` / `GetMaxHealth()` returned 100 on real NPCs; `soul:GetState("health")` also works |
| Write NPC health / damage | **methods exist, untested** | `actor:SetHealth`, `actor:SetMaxHealth`, `soul:DealDamage`, `actor:RequestStealthKill`, `RequestMercyKill` |
| Suppress NPC AI | **candidates** | `AI.SetBehaviorTreeEvaluationEnabled`, `AI.AutoDisable`, `entity:EnableAI` |
| Inject awareness / aggro | **candidates** | `AI.SetAlarmed`, `AI.CreateStimulusEvent(InRange)`, `AI.VisualEvent`, `AI.UpdateTempTarget`, `AI.ClearTempTarget`, `AI.Hostile`, `AI.SetReactionOf`, `AI.NotifyGroup` |
| Shared world time | **available** | `Calendar.SetWorldTime`, `SetWorldTimeRatio`, `SetFakeTimeOfDay`, `IsWorldTimePaused` |
| Enumerate NPCs | **verified** | `System.GetEntitiesInSphere(pos, r)` — 267 entities at 120 m, 16 of them actors |

### Distraction does not need shared NPCs

The headline example — one player distracts a guard so the other slips past —
turns out not to require a shared NPC at all. Replicate the *stimulus*, not the
entity: player A throws a stone, and every other client calls
`AI.CreateStimulusEvent` at the same world position. Each guard is a separate
entity but they all turn to look at the same spot at the same moment. Identical
gameplay outcome, none of the authority problem.

The same applies to alarm states, combat alerts and body discovery. This is the
cheapest large win available and should be built before any NPC puppeting.

## Classifying an NPC at runtime

There is no "is this quest-critical" flag, but the naming convention is
informative. Observed live:

| Pattern | Meaning | Share? |
|---|---|---|
| `SpawnedAnimal_<Class>_<hash>_<n>` | ambient spawn | yes |
| `DialogTwin_*` | dialogue/quest scaffolding | **never** |
| `t<loc>_<name>` e.g. `tkop_ptacek` | hand-placed, location-coded | no — assume unique |
| class `Horse`, `Dog`, `RoeDeerHind`, … | animals | yes |

`Properties.esFaction` came back nil on real NPCs, so faction is not a usable
classifier from properties; use `AI.GetParameter(id, AIPARAM_FACTION)` instead.

**Default to private.** A misclassified ambient NPC costs a little shared
immersion; a misclassified quest NPC can destroy someone's playthrough. The
allow-list must be positive, never a deny-list.

## Still unverified — these gate the plan

1. **Writing health actually works.** The methods exist; nothing has been
   called. **Test on a mod-spawned ghost, not a live NPC** — setting health on a
   real NPC in a real save can kill a character and break a quest.
2. **AI suppression behaves.** Does `SetBehaviorTreeEvaluationEnabled(false)`
   freeze the brain while leaving the body standing, or does it drop the NPC
   into a broken state? Needs a human watching the screen.
3. **Stimulus injection actually makes an NPC react.** Also needs eyes on it.
4. **Suppressing an NPC does not break quests that later need it.** Even a
   correctly classified ambient guard may be referenced by content.

## What survives from the work already done

Everything structural. WO-1's transport (log tail out, batched `ExecuteString`
in) is what makes any of this possible, and WO-2's session layer is the right
shape for opting into joint content. The parallel-worlds *assumption* is what
changes, not the plumbing.

## Suggested order

1. **Shared world time.** Small, self-contained, immediately felt.
2. **Stimulus replication** — distraction, alarm, combat alerts. Large gameplay
   payoff, no authority model needed.
3. **Health write test on a spawned ghost**, then AI suppression and stimulus
   behaviour probes with a human observing.
4. Only then: NPC ownership, puppeting and damage synchronisation for a bounded
   ambient set.

Steps 1 and 2 are worth building regardless of how 3 turns out, which is why
they come first.
