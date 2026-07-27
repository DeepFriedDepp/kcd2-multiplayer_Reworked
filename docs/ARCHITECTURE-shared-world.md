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
