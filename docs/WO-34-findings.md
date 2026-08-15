# WO-34 — the first two-player bug report: crime, factions, and a walking corpse

Investigated 2026-08-13 against the live KCD2 Modding Tools build, human at the
machine, with the shipped v0.11.5 pak loaded for the reproduction phase.
Evidence discipline as in WO-11/13/26/27/28: **observed / read-but-unrendered /
inconclusive**, never rounded up.

Source: a bug report from two real humans on two real machines — the first this
project has ever had. Discord, user `.littytitty`, testing v0.11.5, verbatim:

> We can rob and be hostile to each other, likely due to the NPCs spawned for
> each player. This caused us to be locked in combat, then when one of us
> surrendered he was taken to the pillory. Then after reloading to test again he
> was attacked by the NPCs around due to being a Ruffian, and was automatically
> hostile to me, the other player, constantly talking smack and trying to fight
> me. Very comedic but not too good for the intended purpose. Also once the NPC
> killed his stand in the dead body moved around where he did.

A screenshot from the same session shows a body labelled **"Ruffian"** with
`Grab body (F)` / `Loot (E)` prompts.

---

## Bottom line up front

**Four reported symptoms, two causes, and only one of them is a design
question.**

1. **The face roster shipped five bandit souls.** `KCD2MP.faceRoster.male` had
   24 entries and five of them were `trosecko_enemies_bandits_*` — public
   enemies. One of them, `tbuk_man_5`, resolves in the running engine to
   `soul_ui_name_ruffian` → **"Ruffian"**. That single fact accounts for the
   cross-player hostility, the ambient NPCs attacking him, the bandit barks,
   and the screenshot's label. It is not reputation bleed and it is not a
   re-roll on reconnect. **Fixed** — the five are removed.
2. **Position sync had no death check.** A dead ghost kept having
   `SetWorldPos` written onto it every 20 ms. **Fixed and verified.**

Issues A (player-vs-ghost crime) and B (arrest/pillory) are the *same* vanilla
machinery, deliberately not resolved here — see §5.

---

## §1 — the systems audit: what a soul-backed ghost actually plugs into

The WO asked for this before chasing symptoms, and it is what reframed the
whole report. WO-22 gave ghosts a real `SharedSoulGuid`, which was scoped as
"fix A1, give them faces". Identity is not a per-feature switch. Everything
below is read from the shipped `Tables.pak` / `English_xml.pak` unless marked.

### 1.1 Crime — a ghost is a full-rights victim

`Libs/Tables/rpg/crime.xml` keys crimes off the victim being a real soul. Every
row applies to a ghost. The ones a player can commit on another player's ghost:

| crime | fine | jail (days) | confiscation | scales with victim's class |
|---|---|---|---|---|
| `pickpocket` | 550 | 2 | yes | **yes** |
| `theft` | 500 | 3 | yes | no |
| `assault` | 1500 | 5 | no | **yes** |
| `murder` | 20000 | **7** | yes | **yes** |
| `corpseViolation` | 2000 | 5 | yes | **yes** |
| `aggression` | 750 | 1 | no | **yes** |
| `drawnWeapon` | 250 | — | no | no |

`scalingWithSocialClass` matters more than it looks: the roster still contains
three `trosecko_settlements_trosky_nobility_lordsAndLadies` souls, so assaulting
or killing *those* players' ghosts costs more than assaulting a peasant's.
Nobody chose that; it is a side effect of picking souls for visual variety.

### 1.2 Reputation — crimes against a ghost damage a *real* settlement

`reputation_change.xml` routes crime penalties by
`reputation_change_target_id`, resolved in `reputation_change_target.xml`:

- `14` = *faction + nearbyfactions + superfaction*
- `15` = *all*

So `crime_murder_reported` is **-1.5** and `crime_theft_reported` **-0.15**
against the whole faction the victim belongs to and its neighbours. A ghost
belongs to a real settlement faction (it inherits the donor soul's
`factionName`), so **killing another player's ghost in Troskovice damages your
standing with Troskovice.** Permanently, on your real save, from an entity that
only exists because multiplayer is running. This was never evaluated.

### 1.3 Faction hostility — the mechanism, and why the mod's override loses

`FactionTree.xml` is a 1,028-node tree. Relations are declared per node and
inherited. The relevant node:

```
enemies / trosecko_enemies                       Labels="publicEnemy"
    Relations: trosecko_settlements  = -1
               trosecko_outskirts    = -1
               trosecko_millers      = -1
               trosecko_allies       = -1
               eventNPCs_civilians   = -1
    Children:  trosecko_enemies_bandits
                   campBukovina / campKopanina / campZdar   (roster slots)
```

`KCD2MP_SpawnGhost` tries to neutralise this with
`entity.Properties.esFaction = "Civilians"` and
`AI.ChangeParameter(entity.id, AIPARAM_FACTION, "Civilians")`. **Observed live:**
the property write takes (`props.esFaction` reads back `Civilians`) and changes
nothing — the engine's own `FactionNode` still resolves to the bandit node, and
the ghost is still killed by ambient NPCs (§3). `AI.GetFactionOf` does not exist
in this build (`nil`), which is why nothing had ever verified the override.

### 1.4 Protection — none of it applies

`soul_vip_class.xml` tiers (`immortality`, `attack_protection`,
`untouchable`, …) were live-verified in WO-25 Phase 3 to genuinely intercept
lethal damage. **Every one of the 48 roster souls carries
`soul_vip_class_id="0"`.** No ghost is protected from anything. That is
consistent with the human's WO-25 decision (ordinary NPCs stay killable) and is
recorded here because it means a ghost has no floor at all.

### 1.5 Crime role — bandit souls are flagged *renegade*

`social_class.xml` → `soul_crime_role.xml`:

```
tkop_man_1  social_class_id=38 -> "bandit"  -> soul_crime_role_id=3 -> "renegade"
ttkc_man_3  social_class_id=101 -> "guard"  -> soul_crime_role_id=2 -> "soldier"
```

`soul_crime_role.xml`'s own comment on role 2: *"Only socialClasses that are
authority figures are supposed to have this; affects wanted icon."* The roster
contains four `_soldiers_guards` / `_soldiers_militia` souls, so some players
are walking around as authority figures in the crime system. Consequence
unmeasured; flagged, not claimed.

### 1.6 Voice and dialogue — the "talking smack" is authored content

The bandit soul row carries `voice_group_name="Bandits"` and
`skald_character_name="char_GENERIC_MAN_ENEMY_BANDIT_01"`. The hostile barks
the reporter heard are the game's own bandit voice set, selected by the soul.
Nothing in this project generates dialogue.

### 1.7 What was checked and found *not* to be a problem

- **Quest triggers near a ghost** — no roster soul appears in any quest table;
  they were chosen from ambient settlement populations. Not exhaustively
  proven, but no positive evidence of quest participation was found.
- **The female roster** — all 24 entries traced to commonFolk / nobility /
  millers / romani / tavern / farms factions. **No `publicEnemy` anywhere in
  any of their ancestries** (verified by walking the full faction tree after
  the fix). The bandit problem was male-only.

### 1.8 Audit verdict

The right fix is **narrow for what was reported and broad for what was
found.** The reported symptoms are one bad data set (five roster entries), now
removed. But §1.1/§1.2 are a genuinely wider unevaluated surface: *every* ghost,
including every corrected one, is a full crime victim whose mistreatment costs
the offender real money, real jail time and real standing with a real
settlement. That is not fixed here and is not this session's to decide (§5).

---

## §2 — Issue C: the "Ruffian", closed live with no hypothesis needed

The WO offered two hypotheses (a reconnect re-roll of the roster pick; vanilla
reputation status bleeding onto the ghost). **Neither is required and neither is
what happened.** The roster simply contained a Ruffian.

### 2.1 The five bandit slots

`KCD2MP.faceRoster.male`, resolved GUID-by-GUID against `soul__*.xml`:

| slot | `factionName` |
|---|---|
| `tbuk_man_5` | `trosecko_enemies_bandits_campBukovina` |
| `tkop_man_1` | `trosecko_enemies_bandits_campKopanina` |
| `tkop_man_2` | `trosecko_enemies_bandits_campKopanina` |
| `tzda_man_6` | `trosecko_enemies_bandits_campZdar` |
| `tzda_man_9` | `trosecko_enemies_bandits_campZdar` |

`KCD2MP_PickFaceForPlayer` is `isFemale = h%2==0`, `idx = floor(h/2) % #list`.
Five of 24 male slots ⇒ **~1 player in 10 got a public enemy.**

### 2.2 Live: the engine's own answer

Ghosts spawned through the **real, unmodified `KCD2MP_SpawnGhost`**, read back
over the RTTR reflection API — not inferred from tables:

| ghost | roster soul | `SharedSoulGuid` read back | `FactionNode/UIName` | English string |
|---|---|---|---|---|
| `wo34C` | `ttkc_man_26` (control) | `cfa65480-…` ✓ | `soul_ui_name_varlet` | "Hired hand" |
| `wo34D` | `tkop_man_1` | `f5587d56-…` ✓ | `soul_ui_name_bandit` | "Bandit" |
| `wo34F` | `tzda_man_9` | `aefb7006-…` ✓ | `soul_ui_name_bandit` | "Bandit" |
| `wo34E` | `tbuk_man_5` | `82d455d8-…` ✓ | **`soul_ui_name_ruffian`** | **"Ruffian"** |

**`tbuk_man_5` is the reporter's screenshot.** Male roster index 1 — the first
entry in the list. The affected player's name key hashed to it, and it would
have done so on his *first* connect, every session, deterministically. The
arrest/reload cycle did not create the state; it moved him somewhere with guards
who could act on it.

*A wrong turn worth recording, because it looked right:* `social_class.xml`
has a `social_class_name="ruffian"` row (id 51) and `soul_ui_name.xml` a
matching `soul_ui_name_ruffian`, so "bandit social class → ruffian" reads as a
clean chain on paper. It is not the chain. The label comes from
**`FactionNode.UIName`**, and the three bandit camps do not all resolve the
same: Kopanina and Zdar give "Bandit", Bukovina gives "Ruffian". Only the live
read separates them.

### 2.3 Live: they die, and the control does not

Same spawn path, same moment, same place, ~8 m apart:

```
kcd2mp_wo34B  tkop_man_1  (bandit)     hp=0    IsDead=true    body later despawned
kcd2mp_wo34D  tkop_man_1  (bandit)     hp=100 for 12s, then hp=0  IsDead=true
kcd2mp_wo34C  ttkc_man_26 (commoner)   hp=100  IsDead=false   untouched throughout
```

Both bandit-soul ghosts were killed by ambient NPCs. The commoner control
standing 8 m away was never touched. `fa_combat_idle_*` / `fa_combat_gesture_*`
facial-animation requests appear in the log across the same window, which is
independent evidence real NPCs entered combat.

*Honest limit:* n=2 bandits vs n=1 control, one location, one session, and
attacker identity was not captured (`GetAttackersCount` is not bound on this
build — it returned `?`). "Bandit-soul ghosts get killed and commoner ones do
not, here" is what was observed. The causal step from `publicEnemy` to the kill
is read from `FactionTree.xml`, not instrumented.

### 2.4 The fix

The five are removed from `KCD2MP.faceRoster.male`. Verified after the edit by
walking the full 1,028-node faction tree: **no remaining roster soul has
`publicEnemy` anywhere in its ancestry** (43 souls checked, 19 male + 24
female).

**Cost, stated plainly:** `KCD2MP_PickFaceForPlayer`'s modulus is over `#list`,
so taking male from 24 to 19 changes **every** male player's face on this build,
not only the five affected. Chosen deliberately by the human over replacing the
five in place. Appearance stability across a version was already broken once by
WO-22 for the same underlying reason.

---

## §3 — Issue D: the walking corpse, reproduced and fixed

### 3.1 Root cause

`KCD2MP_InterpTick` wrote `SetWorldPos`/`SetWorldAngles` on every ghost every
20 ms, unconditionally. `KCD2MP.ghostDead[id]` — the WO-28 Flow C death flag —
was consulted in exactly **one** place in the whole mod: the nameplate string.
The ghost entity's own `actor:IsDead()` was never read at all.

The prompt framed this as "position packets arriving after a death packet". The
reported case is the *other* one, and it involves no packet: **an NPC killed the
ghost in that peer's world.** Worlds are not shared
(`docs/WO-26-shared-combat-design.md` §2), so the owner never died and no
`0x23`/`0x24` was ever sent. Nothing in the mod had ever looked at a ghost's own
death state, which is why this survived WO-28.

### 3.2 Reproduced, on the shipped build, before any fix

A bandit ghost killed by NPCs (`IsDead=true`, confirmed), then fed a position
stream through the ordinary `KCD2MP_UpdateGhost` entry point:

```
BEFORE corpse at 2355.19,2089.98,111.64  dead=true
drive 1  target_x=2356.19   corpse_x=2355.19
drive 2  target_x=2357.19   corpse_x=2356.19
drive 3  target_x=2358.19   corpse_x=2357.19
drive 4  target_x=2359.19   corpse_x=2358.19
drive 5  target_x=2360.19   corpse_x=2359.17
drive 6  target_x=2361.19   corpse_x=2360.18
drive 7  target_x=2362.19   corpse_x=2361.18
drive 8  target_x=2363.19   corpse_x=2362.17
```

The corpse tracked the stream one-for-one across **7 metres**, one interp tick
behind. That is the reporter's *"the dead body moved around where he did"*,
instrumented.

### 3.3 The fix, in two halves

**Freeze.** New `mp_ghost_is_corpse(id, ghost)` returns true if either
`KCD2MP.ghostDead[id]` (the owner died) or the ghost entity's own
`actor:IsDead()` (an NPC killed it here). `KCD2MP_InterpTick` skips the position
write and skips animation when frozen, and takes the nameplate's anchor from the
body's **actual** world position instead of the incoming stream — otherwise the
label flies off and leaves a nameless corpse, which is exactly the WO-28 Q3
failure shape.

`actor:IsDead()` was **verified present and correct on a ghost entity** before
the fix depended on it — the same call returned `true` on the dead ghost and
`false` on the live control in the same probe. It is one extra native call on a
path that was already calling `GetHealth()` on the same object.

**Recycle.** Freezing alone leaves the owner permanently invisible in that
peer's world, because death is a one-way transition (WO-25 Phase 3). So
`KCD2MP_ReconcileGhosts` — the existing 500-tick sweep that already recycles a
ghost whose entity was destroyed by a save load — now also treats *entity
present but dead* as needing recycling: the corpse is removed via
`mp_remove_entity_verified` and the bookkeeping dropped, so the next position
packet respawns a fresh body through the ordinary path.

Only the **entity** being dead triggers recycling. A ghost whose **owner** died
(`[dead - reloading]`) is a perfectly good standing body and is deliberately
left alone — WO-28 chose that so a player back in seconds does not cost a full
spawn cycle, and nothing here changes that reasoning.

The corpse is removed rather than abandoned. An untracked ghost body is what
WO-27 spent a session cleaning up, and it is also a real lootable object another
player can commit `corpseViolation` on (§1.1).

### 3.4 Gate D — **PASSED**, live, on the installed build

Isolating the freeze needed one piece of test scaffolding worth naming: the
recycle half fires on the agent's ~10 s cadence and kept removing the corpse
before a stream could be driven at it. So `KCD2MP_ReconcileGhosts` was
temporarily stubbed to a no-op for the freeze test and restored immediately
after (restoration verified: `type(KCD2MP_ReconcileGhosts) == "function"`).

**Positive control first** — a *live* ghost must still track position, or a
"passing" freeze test would just be a broken sync:

```
ALIVE drive 1  target_x=2352.17  ghost_x=2351.17  dead=false
ALIVE drive 2  target_x=2353.17  ghost_x=2352.17  dead=false
ALIVE drive 3  target_x=2354.17  ghost_x=2353.17  dead=false
ALIVE drive 4  target_x=2355.17  ghost_x=2354.17  dead=false
ALIVE drive 5  target_x=2356.17  ghost_x=2355.17  dead=false
```

**Then killed through the real combat path** — `CombatSoul/TakeDamage`
`?Stamina=0&Health=400&SuppressHitReaction=true`, the entry point WO-25 Phase 3
established actually applies damage. Health 100 → 0, `IsDead=true`,
`mp_ghost_is_corpse` → `true`. Same drive:

```
PRE  dead=true  frozen=true  corpse=2352.19,2090.33
DEAD drive 1  target_x=2352.81  corpse_x=2352.19  corpse_y=2090.33
DEAD drive 2  target_x=2353.81  corpse_x=2352.19  corpse_y=2090.33
DEAD drive 3  target_x=2354.81  corpse_x=2352.19  corpse_y=2090.33
DEAD drive 4  target_x=2355.81  corpse_x=2352.19  corpse_y=2090.33
DEAD drive 5  target_x=2356.81  corpse_x=2352.19  corpse_y=2090.33
DEAD drive 6  target_x=2357.81  corpse_x=2352.19  corpse_y=2090.33
DEAD drive 7  target_x=2358.81  corpse_x=2352.19  corpse_y=2090.33
DEAD drive 8  target_x=2359.81  corpse_x=2352.19  corpse_y=2090.33
```

**Byte-identical across all 8 samples while the target moved 8 m.** The same
drive on the shipped build moved a corpse 7 m (§3.2).

**Recycle round trip, reconcile restored:**

```
reconcile returned 1   ghostRow=false
RESPAWN entity dead=false hp=100.0 at 2361.81,2092.66 (target 2361.81,2092.66)
```

The corpse was removed, the bookkeeping cleared, and the next ordinary position
packet respawned a fresh, **alive, full-health** ghost at exactly the streamed
position. Freeze and recovery both work, end to end.

### 3.5 A real wrinkle the fix surfaced

```
[KCD2-MP] RECONCILE id=wo34G entity 'kcd2mp_wo34G' is DEAD in this world -- removing the body so a fresh ghost respawns
[KCD2-MP] RemoveEntity ghost corpse wo34G STILL ALIVE after 4 passes (entityId=userdata: 000000000010077A name=kcd2mp_wo34G)
[KCD2-MP] Reconcile: 1 ghost(s) had lost their entity; will respawn
```

`mp_remove_entity_verified` reported failure after all four passes — and the
entity was nevertheless gone by the next probe. **`System.RemoveEntity` on a
corpse completes later than it reports.** This is the same unreliability WO-25
recorded ("the first call returned `ok=true` but the entity was still alive on
the next lookup; the second worked"), now with a clearer shape: it is not that
the call fails, it is that removal is deferred past the point the verifier
checks.

Not papered over here, because the outcome is correct either way: the
bookkeeping is dropped regardless of what the verifier concluded, so the next
packet respawns, and if a corpse ever genuinely did survive, `KCD2MP_SpawnGhost`
already removes an untracked entity found under its own spawn name before
spawning (the WO-27 guard). Two independent safety nets, both pre-existing. The
log line is noise in this case and is left alone rather than silenced — a
persistent orphan and a deferred removal look identical from inside the
verifier, and silencing it would hide the one that matters.

---

## §4 — Issue A: the mechanism, stated; the decision, deferred

Robbing another player's ghost works because a ghost **is** a real soul-backed
NPC with a real inventory. The screenshot's `Grab body (F)` / `Loot (E)` prompts
are the game's own interaction verbs on an ordinary corpse, not anything this
project drew.

`docs/WO-22-brain-lead.md` predicted the whole class of problem in one line and
it was never followed up:

> **A shipped ghost is a `Civilians`-faction NPC standing in a settlement, so
> the player cannot attack it without committing a crime.** … it is what will
> happen to real players who punch each other's ghosts in a town, and it is new
> since ghosts started carrying real souls and real faction identity. Worth its
> own look before this reaches users.

It reached users. This is that look.

**Human's recorded decision:** *decide after the roster fix* — much of the
reported hostility should vanish once no player is a public enemy, and what
remains (deliberate player-on-player theft) may be rare enough to leave alone.
Re-test with two real players on the fixed build before deciding.

---

## §5 — Issue B: a real player was arrested, and what that actually was

### 5.1 The mod contains no crime code

Checked, not assumed: `kdcmp.lua` has **zero** occurrences of crime, wanted,
bounty, arrest, pillory or jail logic (the six textual hits are unrelated
comments). `dotnet/` has one, and it is a comment. Every consequence the tester
experienced came from vanilla systems reacting to a real NPC.

So it is **vanilla behaviour on an unusual trigger**, the same shape as WO-25's
ordinary-NPC killability — with one difference that matters: the trigger was
not a player's own choice, it was another player's ghost being a public enemy
by accident of the roster.

### 5.2 The human's question, answered

> *My intention is "if you reload a save/die, you are no longer a criminal" just
> like in the base game, assuming the save was before the crime was committed.*

**That already holds, and the mod does not interfere with it.** Crime state —
wanted status, witnesses, bounty — is save state in KCD2; loading a save from
before the crime restores the pre-crime state, and nothing in this project reads
or writes any of it (§5.1). *(Vanilla save-state behaviour is read/known, not
measured this session.)*

**What the reporter saw was not a criminal record surviving a reload.** It was
the *ghost's identity* being re-derived: `KCD2MP_PickFaceForPlayer` is a pure
function of the player's name key, so the same player gets the same soul on
every spawn, in every session, forever. A Ruffian reloads as a Ruffian. That is
why it looked like a persistent status and was not one.

Two multiplayer-specific wrinkles worth knowing before the synced-NPC goal:

- **Crime state is per-machine.** Player A's wanted status exists only in A's
  world. A reloading to clear it does nothing for B, and B's guards never knew
  about it in the first place. With NPCs synced, this becomes a real design
  question: whose crime state is authoritative?
- **A ghost cannot be arrested.** Guards can kill it, and did (§2.3), but the
  arrest/surrender/pillory flow is aimed at the *player*. So the punishment the
  tester received was for *his own* actions in *his own* world — the ghost's
  hostility is what started the fight, not what got him jailed.

**Not decided this session, by design.** Whether multiplayer-originated crime
deserves full vanilla consequences is a product call, and the human's answer was
to see whether it recurs on the fixed build first.

---

## §6 — verification

### The installed build is the fixed build

Read from the running game after `tools\Build-And-Install-Mod.ps1` and a
relaunch, rather than assumed from the source file:

```
roster male=19  female=24
mp_ghost_is_corpse=function
bandit slots remaining=0
```

The bandit check enumerates the live `KCD2MP.faceRoster.male` table by soul name
and looks for all five removed entries by name, so it would catch a stale pak,
a partial install, or an edit that missed one.

### Gate D

**Passed** — §3.4, both halves, with a positive control.

### Cleanup

All seven WO-34 test entities (`wo34B`–`wo34H`) removed, and the test
scaffolding cleared. Verified by count from the world, not from the mod's
bookkeeping agreeing with itself:

```
wo34 entities remaining=0   ghost rows=0   reconcileFn=function
```

Two ghosts were killed during this session — both mod-spawned test entities of
this WO's own making. **No real, hand-placed NPC was killed or damaged**, unlike
WO-25. The two bandit-soul ghosts that died in §2.3 were killed by ambient NPCs
in the course of ordinary self-defence; whether any real NPC took damage in
those fights was not measured.

### Not run

No `dotnet/` or relay code was touched, so the C# suites were not re-run. The
mod-side change is Lua-only and was verified against the real game directly,
which is the stronger test for it.

---

## §7 — what this session does not close

1. **The wider crime/reputation surface (§1.1–1.2).** Every ghost, including
   every corrected one, is a full crime victim whose mistreatment costs real
   money, jail and real settlement standing. Untouched. Needs its own WO once
   the fixed build has been played by two people.
2. **Noble and guard/militia souls in the roster (§1.1, §1.5).** Crimes against
   noble-souled ghosts scale up; guard-souled ghosts carry the `soldier` crime
   role, which the shipped table says affects the wanted icon. Consequences
   unmeasured. Not removed — unlike the bandits they are not hostile — but
   flagged as a second, smaller data-quality question.
3. **Attacker attribution.** `GetAttackersCount` is not bound in this build, so
   "who killed the ghost" was never captured. §2.3's causal step is read from
   the faction tree, not instrumented.
4. **Two real players on the fixed build.** Everything here was reproduced with
   one machine and mod-spawned ghosts. The report came from two humans; the fix
   should be confirmed by two humans.
