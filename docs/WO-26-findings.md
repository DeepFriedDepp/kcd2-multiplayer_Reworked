# WO-26 — can players be Henry? If not, reactive brained-ghost hostility

Investigated 2026-08-06, live against KCD2 (Modding Tools build), save
`playline2`, human present at the machine throughout. Save backed up to
`playline2_wo26backup` before any live combat. The human re-confirmed at the
start of the session that `playline2` remains disposable for destructive
testing ("Yes, still disposable"), rather than this being inherited silently
from WO-25.

Test location: an isolated field at `~2620,2755,141` — **0 actors within
60 m**, verified by sphere query before the first spawn, not assumed.

**Bottom line up front: the goal is already met by the shipped default, and
nobody had tested for it. A plain soul-backed ghost — no hostile faction, no
`AI.*` binds, no toggle — already fights back when attacked and already joins
real combat happening near it. Separately, "a player can be Henry" is closed:
a second `Player`-class entity crashes the game, observed.**

---

## Phase 0 — does a plain soul-backed ghost already fight back?

The spawn shape under test is the **exact shipped default** of
`KCD2MP_SpawnGhost` (`kdcmp/Data/Scripts/Startup/kdcmp.lua:1348`): flat
`XGenAIModule.SpawnEntity{Name, ClassName="NPC", Pos, SharedSoulGuid}`,
followed by `Properties.esFaction = "Civilians"` +
`AI.ChangeParameter(AIPARAM_FACTION, "Civilians")` and the `white_red` armour
preset. The one deliberate omission is registration in `KCD2MP.ghosts`, so
`KCD2MP_InterpTick` did not stream a position over the top — see the caveat at
the end of this section, which is the single most important limitation here.

`KCD2MP.aggroEnabled` was **`false`** for every test in this phase, read live
before the first spawn. Nothing in this phase used the aggro toggle, the native
`SetParent` faction attach, or any `AI.*` hostility bind.

### 0a — direct attack by the player

`wo26A`, roster soul `40fd3055-48be-a9f5-de48-0b882695cca5` (`ttro_man_30`).
Binding verified by read-back before the test, not assumed:
`SharedSoulGuid` = the roster GUID exactly, `CombatLevel` = `0.648769617`,
`FactionNode.UIName` = `soul_ui_name_soldier`. Baseline: 4 samples over 12 s,
position byte-identical, `HasMeleeWeapon=false`, `AttackersCount=0`.

The human then attacked it with a real weapon:

```
16:24:51  hp=100.0  php=100     melee=false atk=0   buffs=[item_gloves,item_bigger_dread]
16:24:55  hp=99.4   php=100     melee=false atk=0   d=0.80m
          buffs=[... injured_head, crime_interrupt_confronting]
16:24:59  hp=99.4   php=100     melee=TRUE  atk=0   d=4.85m
16:25:03  hp=99.4   php=100     melee=true  atk=0   d=7.24m
16:25:08  hp=99.4   php=100     melee=true  atk=1   d=3.24m
16:25:12  hp=99.4   php=57.48   melee=true  atk=0   d=7.97m   <-- PLAYER HIT
16:25:16  hp=99.4   php=57.31   ... crime_interrupt_searching
16:25:41  hp=99.4   php=56.32
```

Read in order: the first hit registers as a **crime**
(`crime_interrupt_confronting`) and an injury (`injured_head`);
`HasMeleeWeapon` flips **true on the ghost's own initiative** four seconds
later (no `DrawWeapon` was called — that call is gated behind
`KCD2MP.aggroEnabled`, which was false); `AttackersCount` reaches 1, so the
ghost registers the player as an attacker; and then **the player's health goes
100 → 57.48 in a single exchange**, with a slow bleed afterwards.

The damage attribution is the human's own eyewitness account, asked as an open
question rather than a leading one, with fall damage and self-inflicted damage
offered as alternatives: *"The ghost hit me"*, and separately *"one hit took
half my health."*

The `crime_interrupt_searching` tail and the ~90 m of travel afterwards are
**not** the ghost fleeing. The human disengaged: *"I used the F3 command to fly
away, because one hit took half my health and I didnt want to die while the
investigation was ongoing."* The ghost lost its target and searched. No
conclusion is drawn here about whether it would have broken off on its own.

### 0b — combat nearby, ghost not the target

Two runs. The first was uninstrumented by a tooling bug of mine — passing
`-Ghosts wo26B,wo26C` through `powershell -File` collapses the array into the
single literal name `"wo26B,wo26C"`, so every REST lookup 404'd and the whole
window sampled nothing. The human's eyewitness account of that run stands on
its own (*"I did not fight the bandit at all whatsoever. The soldier killed the
bandit before anything could happen"*), and the **end state was read directly
from the API afterwards, which is real evidence independent of the lost
telemetry**:

| entity | soul | faction | end state |
|---|---|---|---|
| `wo26B` | roster `40fd3055-…` | `soul_ui_name_soldier` | alive, `2284.31,2811.02,150.51` |
| `wo26C` | bandit `75ec27f8-…` | `soul_ui_name_bandit` | **`IsDead=true`**, `2285.36,2810.82,150.76` |

They finished **1.07 m apart, 340 m from where both were spawned** — the
soldier ghost pursued the bandit ghost across a third of a kilometre and killed
it, with the player uninvolved.

The instrumented re-run (`wo26B` vs a fresh bandit `wo26D`, 12 m apart, human
on the ground within ~20 m under instruction to watch and not attack) captured
the mechanism. **The player's health is frozen at `47.2655` in every single
sample**, which is what makes this a clean bystander test rather than a
three-way fight:

```
16:35:00  wo26D  ... crime_interrupt_looking
16:35:04  wo26B  atk=1  melee=false | wo26D  melee=TRUE  d=3.89m  crime_interrupt_confronting
16:35:08  wo26B  atk=1                | wo26D              d=8.28m
16:35:13  wo26B  atk=1  melee=TRUE  morale_context | wo26D  atk=1  melee=true  morale_context
16:35:17  wo26B  hp=92.6  injured_head
16:35:26  wo26B  hp=76.7  injured_torso
16:35:30  wo26B  hp=64.7  combat_riposte_probability_penalty_on_master_strike
16:35:43  wo26B  hp=48.0
16:35:48  wo26B  hp=48.0  bleeding, low_health, 7x riposte-penalty stacks
```

That is a real KCD2 sword duel between two ghosts: mutual `AttackersCount=1`,
mutual `HasMeleeWeapon`, `morale_context` on both, master strikes landing
(the riposte-probability penalty stacks are the engine's own master-strike
bookkeeping), and graduated wound buffs. The human's eyewitness line for this
run: *"Soldier attacked the bandit."*

One negative worth recording from the same data: while both ghosts were 340 m
from the player and the player was airborne in flycam, **nothing happened at
all** — 16 consecutive samples, byte-identical positions on both, over ~70 s.
Engagement resumed within ~25 s of the human landing nearby. This is consistent
with AI activity being gated on player proximity, but it was not isolated as a
variable (distance and flycam changed together), so it is recorded as
**observed but not attributed**.

### Two corrections this phase forces on prior findings

**1. `AI.GetAttentionTargetType` and `AI.GetPeakThreatLevel` are not
engagement indicators.** Both read exactly `0` in **every sample of every run
above**, including the samples where a ghost was landing master strikes and
taking `injured_torso`. WO-25's Phase 2 read those two getters staying at 0 as
part of its evidence that the `AI.*` binds produce no engagement. That specific
inference is unsound — the getters read 0 during genuine, damage-dealing
combat. WO-25's conclusion still stands, because it also rested on the ghost
never moving and no health ever changing on either side, which is real
evidence; but the getters should not be cited again.

**2. WO-22's "a soul-only ghost is byte-stationary" holds only while idle.**
It is exactly right for an unengaged ghost — reproduced here in every baseline.
In combat it is false by two orders of magnitude: `wo26B` travelled **340 m**.
The `SchedulerProxyName` omission buys stationarity in peace, not in war.

**3. WO-22's A2 gate is superseded.** A2 recorded "the ghost fights back is
**not demonstrated**; the ghost is no longer inert is." It is now demonstrated:
a ghost landed enough damage to take a real player from 100 to 57 in one
exchange, and a ghost killed another ghost.

### Gate 0 — stated plainly

**Under direct attack:** a plain soul-backed ghost defends itself for real. It
treats the attack as a crime, arms itself unprompted, registers the attacker,
and deals heavy damage. Observed.

**Under nearby combat:** it is drawn in as a genuine participant, engaging a
hostile it was not told about, pursuing it, and killing it, with the player
neither involved nor targeted. Observed.

**Consequence for the WO's actual goal.** The stated goal was: ignored until a
fight starts, drawn into real combat when it does, released back to being
ignored once it ends — no manual toggle, no permanent hostile flag, no face
conflict. Of those, **"ignored until a fight starts" and "drawn into real
combat when it does" are already true of the shipped default today**, with the
roster face intact (`SharedSoulGuid` is the roster soul, so WO-25's Phase 4
face/soul conflict never arises), with `aggroEnabled=false`, and with zero new
mechanism.

**The one clause not tested is "released back to being ignored once it ends."**
No ghost in this session was observed completing a fight and returning to
neutral — 0a ended with the human flying away, 0b ended with a kill. Stated as
unknown, not rounded up.

### The caveat that matters most

Every ghost in this phase was spawned **directly**, not through
`KCD2MP_SpawnGhost`, and so was never registered in `KCD2MP.ghosts` and never
had `KCD2MP_InterpTick` streaming a position onto it. In a real session
InterpTick overwrites a ghost's position every 50 ms from the remote player's
packets. A ghost that fights back moves — `wo26B` moved 340 m — and every metre
of that would be fought by the position stream.

So Phase 0's result is best stated as: **the AI capability is present and real
in the shipped spawn shape.** Whether it survives contact with the position
stream is a different question, untested here, and is the genuine remaining
engineering problem. It is not obviously fatal — a remote player's own ghost
*should* be driven by that player's real position, and the interesting case is
what the ghost does in the seconds between packets — but it is unmeasured.

---

## Phase 1 — can a player actually be Henry?

### Is the player a distinct engine-level class? Yes, at three independent layers.

| layer | player | generic NPC | how established |
|---|---|---|---|
| entity class | `Player` — own script `Scripts/Entities/actor/player.lua`, declaring `type = "Player"` and `defaultSoulClass = "player"` | `NPC` — `Scripts/Entities/AI/NPC.lua`, which declares **no `type` field at all** | extracted `Scripts.pak` from the local install |
| AI object | `AIOBJECT_PLAYER` = **100** | `AIOBJECT_ACTOR` = **5** | `AI.GetTypeOf`, read live on the real player and on a control ghost in the same call |
| RPG soul class | `player` (`soul_class_id="5"`) | various | `Libs/Tables/rpg/soul_class.xml` |

There is also a `PlayerFemale` class (`type = "PlayerFemale"`), so the player
class is a small family, not a singleton class.

Exactly **three** souls in the whole shipped table data carry
`soul_class_id="5"`: `player_henry` (`4c2dcffb-dea1-6263-72d7-b39f4db2d8b5`),
`player_bohuta`, and `player_naked`. These are alternates for one role, not
concurrent occupants — the game swaps which one is active.

### Does anything assume singularity? Yes.

`SoulList` exposes **`PlayerSoul`, a single `wh::rpgmodule::Soul*`, ReadOnly**
(from `/api/rpg/SoulList?info`). Read live, it holds
`Guid = 4c2dcffb-dea1-6263-72d7-b39f4db2d8b5` — byte-identical to
`player_henry` in the shipped soul table. Every RPG-layer system that asks "who
is the player" resolves through that one pointer.

Corroborating, from the extracted scripts: `g_localActor` is a single Lua
global that `player.lua` dereferences unconditionally in a dozen places;
`g_gameRules` is `Scripts/GameRules/SinglePlayer.lua`, with player.lua's own
comment *"we are using singleplayer.lua"*; and `Player.Client` is the CryEngine
local-client hook table.

One dead end worth recording so it is not re-mined:
`Scripts/FeatureTests/found_checkpoints.csv` names real C++ source files and
line numbers and looks like a goldmine, but it is **stale Crysis 3 SDK
boilerplate** shipped in the pak (`Game03`, `Nanosuit`, `MPSpawningWithLives`,
`GameRulesObjectiveHelper_Carry`). It describes CryEngine's ancestor, not
Warhorse's code. It was not used as evidence for anything above.

### The live test: a second `Player` entity crashes the game

On the static evidence I recommended stopping. The human directed the live test
anyway (*"Run the spawn test"*), with the save backed up. That was the right
call — it turned an inference into an observation, and the observation is
stronger than the inference was.

`XGenAIModule.SpawnEntity{Name="wo26P", ClassName="Player", Pos=…}`, 4 m from
the real player. From `kcd.log`, the last non-faction line in the entire file:

```
[Warning] no archetype found for 'wo26P' of class 'Player', returning 0
[Error] NPC wo26P does not have a faction.      x52
```

Then the log ends. `BugSplatAttachments/2026-08-06_16_46_26_501kcd.log` was
written at 16:46:26 — the crash handler fired — and `KingdomCome.exe` was gone
from the process list.

Three things this establishes:

- **`Player` is a genuinely registered, spawnable entity class.** The engine
  accepted the class name and got as far as looking for an archetype for it.
  This is not "unknown class, call rejected."
- **A second instance is created in a broken state.** No archetype, and — note
  the engine's own wording — it logs the new `Player`-class entity as
  **"NPC wo26P"**, with no faction, every frame.
- **It is fatal.** ~52 error frames after the spawn, the process died. This is
  precisely the shape the WO named as the stop condition, and the same shape as
  the `SetParent` bug before it was understood.

Honest limits on this: the crash is **immediately and exclusively downstream of
this spawn** (nothing else was issued in that window; the preceding minutes of
identical `NPC`-class spawns were all stable), but no dump was analysed and no
faulting frame was recovered, so the causal chain from "no faction" to
"terminate" is **inferred from adjacency, not read from a stack**. It was not
re-run — one crash is enough, and a second would cost another restart for no
new information.

### Gate 1 — STOP, with the reason recorded so nobody re-derives it

- **Distinct class: yes**, at the entity, AI-object and soul-class layers.
- **Second instance: created, immediately malformed, and fatal within
  seconds** — observed, not predicted.
- **This phase stops here.** It does not continue to further live work, and
  "make a connected player be Henry" is closed for the Lua/reflection surface.

Anyone reopening this should know that the barrier is not the entity class —
that part works. The barrier is that everything downstream of it (`PlayerSoul`,
`g_localActor`, faction assignment, archetype lookup) is single-slot, and the
second instance falls through all of it at once. A future attempt would need to
supply an archetype and a faction to a `Player`-class entity *before* the first
AI frame runs, and would still face the single `PlayerSoul` pointer. That is a
native-plugin-scale problem, not a Lua one.

---

## Phase 2 — reactive hostility without a face conflict

Reached, and answered by Phase 0 rather than by new work — which is exactly the
outcome Gate 2 lists first.

**A real, working reactive-engagement lever was not needed, because no lever is
missing.** The capability the WO set out to add is already present in the
shipped spawn shape:

- Engagement is **automatic and reactive**, not toggled — `aggroEnabled` was
  `false` throughout Phase 0.
- It requires **no hostile-faction membership** — `wo26A`/`wo26B` were
  `soul_ui_name_soldier` on the ordinary `Civilians` esFaction path.
- It therefore has **no face conflict** — the ghost keeps its WO-20 roster
  `SharedSoulGuid`, which is the whole reason WO-25's Phase 4 stopped.
- Combat **ends and the ghost returns to ordinary behaviour** — not observed,
  see Gate 0. This is the open clause.

Phase 2 step 2 (hunting for a narrower "capable of self-defence" flag, and
testing whether an ordinary commoner NPC fights back) was **not run**, because
its premise — that the ghost shows no engagement — is false. Recorded as
deliberately skipped, not overlooked.

The WO-25 VIP guardrail is **reused, not re-derived**: `soul_vip_class_id` is
native, live-verified in WO-25 against real lethal damage, and nothing in this
session touches it. Ordinary NPCs stay killable by the human's own recorded
decision. No custom kill-prevention was written or considered.

**Gate 2: confirmed that Phase 0's result already covers it.**

### What this changes about the shipped product, stated as risk not as win

This capability is **already live for every user of the current build**. It was
not added this session and it is not behind the aggro toggle. Since WO-22 gave
ghosts real souls, every connected player's ghost has been able to fight back
when attacked and to join nearby fights, and nobody knew. Combined with WO-22's
own side-finding that attacking a ghost is a real crime, the practical
situation for a player who punches a friend's ghost in a settlement is: it is a
crime, guards respond, **and the ghost fights back.**

---

## Phase 3 — not started

No code was written. `KCD2MP_SpawnGhost`, the aggro toggle, `kdcmp.lua`,
`native/`, `dotnet/`, `VERSION` and the installer are **untouched**. The
human's blanket *"Do absolutely everything you need to do to achieve the WO
request"* is not treated as the explicit, mechanism-specific sign-off that the
WO's Phase 3 gate requires, particularly since Phase 0 changed what the
decision is even about — the question is no longer "which aggro mechanism do we
ship" but "what, if anything, should change now that engagement already
works." That decision is recorded as pending.

---

## Cleanup

All WO-26 test entities removed and confirmed by name sweep before the crash:
`wo26A`, `wo26B`, `wo26C`, `wo26D`, `wo26T` — **0 remaining**. `wo26P` (the
`Player`-class spawn) died with the process and never existed in a saved state.

Real-world casualties: **none.** No real, hand-placed NPC was damaged or killed
this session — unlike WO-25, every combatant was a mod-spawned test entity.
`playline2` was never saved over; `playline2_wo26backup` is intact.

## What is now known that was not before

1. The shipped default ghost already fights back and already joins nearby
   combat, with no toggle, no hostile faction and no face conflict. This was
   never tested and is the WO's own goal, already met.
2. A ghost can land real damage on a real player (~43 in one exchange) and can
   kill another combatant outright — WO-22's A2 is superseded.
3. A second `Player`-class entity crashes the game. The class is spawnable; the
   instance is malformed and fatal.
4. `SoulList::PlayerSoul` is a single read-only pointer holding `player_henry`
   — the structural reason (3) is not fixable from Lua.
5. `AI.GetAttentionTargetType` / `GetPeakThreatLevel` read 0 through real
   combat and must not be used as engagement evidence.
6. Soul-only ghosts are stationary only while idle; in combat they range
   hundreds of metres, which is a real and unmeasured `InterpTick` conflict.

## Files touched

- `tools/wo26-lua.ps1` (new) — ExecuteString driver + `[WO26]` log reader
- `tools/Wo26-Watch.ps1` (new) — telemetry watcher adding AI engagement
  readings, player health, and per-sample distance in metres
- `docs/WO-26-findings.md` (this file)
- `docs/WO-26-progress.md`

No changes to `kdcmp.lua`, `native/`, `dotnet/`, `VERSION`, or the installer.

**Known bug in `tools/Wo26-Watch.ps1`'s invocation, not the script:** launch it
with `powershell -Command '& ".\tools\Wo26-Watch.ps1" -Ghosts a,b'`, never
`powershell -File … -Ghosts a,b` — `-File` passes the comma list as one string
and the watcher silently samples a nonexistent entity. This cost one run.
