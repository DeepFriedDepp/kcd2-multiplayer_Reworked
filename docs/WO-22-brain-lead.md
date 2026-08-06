# WO-22 §1 — the brain lead, tested live

Investigated 2026-08-06 against KCD2 (Modding Tools build) with a real save
loaded in the Troskovice area, the `kdcmp` mod loaded, and the human present at
the machine throughout. Source material: `muyuanjin/kcd2-mod-docs`, cloned
locally (retail `Scripts.pak` + `Tables.pak` extracted from `release_1_5`, an
offline mirror of Warhorse's official KM wiki, a `lua_dump_state` symbol dump,
and the scriptbind HTML shipped with the official Modding Tools).

**Bottom line up front: the door is open. A1 is fixed.**

The lever is not a behaviour-tree name. It is that
`XGenAIModule.SpawnEntity`'s documented parameter table takes a **top-level
`SharedSoulGuid`** and a **`SchedulerProxyName`**, and this project has been
passing neither — it nests `guidSharedSoulId` inside a `Properties` sub-table,
which binds no soul at all. Spawned the documented way, a ghost gets a real
Warhorse brain, a real faction, and real behaviour.

A ghost spawned this way **walks, patrols, flees, bleeds, gets drunk, dies —
and, knocked unconscious, wakes up again.** WO-21's A1 (`an aggro'd ghost
knocked unconscious never wakes`) does not reproduce under this configuration.

---

## §1.1 — what the official documentation actually says

### There is no XGEN AI article

The offline wiki mirror is 78 articles. **None of them documents behaviour
trees, brains, or how either is assigned to an entity.** The only mention of
the layer at all is one sentence in KM-A-15:

> Entities and their basic functionality in KCD2 are scripted in LUA together
> with XGEN AI and Skald (so not everything is modifiable just via LUA).

So the official docs do *not* describe NPC behaviour trees as moddable. They
name XGEN AI as a layer and then document Lua, RPG tables, Skald quests,
events, and visuals instead. On the specific question the WO asked — "does the
official documentation describe how a behaviour tree is assigned to an entity"
— the honest answer is **no, it does not describe it at all.**

### But two articles describe the real mechanism, indirectly

**KM-A-12 (Database tables)** lists the `ai/` tables and their formats.
Critically, `old`/`new`/`unused` are *format* labels, not deprecation:
`ai/brain`, `ai/subbrain`, `ai/brain2subbrain`, `ai/subbrain_behaviour_tree`
are all `old` (= KCD1 flat format, still live). Only `ai/brain_interpreter*`,
`ai/brain_sensor*` and friends are marked `unused`. So the brain/subbrain
tables WO-21 found are real, current, and — per this article — patchable like
any other table.

**KM-A-93 (Links)** is the one that matters:

> Scheduler is a system that selects NPC activities, both for quests and
> openworld behaviors. Scheduler searches for a behavior using links between
> entities, starting at the NPC (**or "scheduler proxy" for player and spawned
> NPCs**).

That is the mechanism, stated by Warhorse: a *spawned* NPC has no links of its
own, so it needs a **scheduler proxy** to inherit an activity search from. A
spawned NPC without one has a brain but nothing for the brain to select. This
is what "the ghost does nothing" has actually been, all along.

### How a brain is bound to an entity: via the soul row

Found by reading extracted `Tables.pak` directly, not inferred:

```
Libs/Tables/rpg/soul__ttkc.xml
  <soul brain_id="4b914d1c-724a-a92d-3e6b-d183d35b8b98"
        factionName="trosecko_settlements_troskovice_soldiers_guards"
        combat_level="0.5"
        soul_id="4b4c6520-21a6-6125-d814-564837f165a2"
        soul_name="ttkc_man_3" ... />
```

`4b914d1c-…` is `npc_basic` — exactly the brain WO-21 identified. Across all
351 `soul__*.xml` parts, 5417 souls carry it, 1773 carry a second brain, 903 a
third. **The brain is a column on the soul row.** An entity gets a brain by
getting a soul, and it gets a soul by `SharedSoulGuid`.

Confirmed live: `ttkc_man_5`'s reflected `SharedSoulGuid` is
`40cb757e-63dc-f5d0-b3a3-848c7ca29e82`, byte-identical to its `soul_id` in
`soul__ttkc.xml`. The roster GUIDs this project already ships in
`KCD2MP.faceRoster` are soul-table `soul_id`s.

### WO-21's `IdleSeq` finding: independently confirmed, twice

- Enumerating every `<BehaviorTree name="…">` in extracted `Scripts/AI/` gives
  **3235 distinct tree names** (4038 including function trees). `IdleSeq` is
  **not one of them.** There is a real namespace of tree names; the value this
  project uses is not in it.
- `lua_dump_state/LuaState.txt`, taken from a loaded retail save, shows
  `esModularBehaviorTree=IdleSeq` on **every** AI entity dumped, without a
  single exception. It is a constant, on retail data, exactly as WO-21 said.
- There is no `npc_basic_scheduler` *tree*. `npc_basic_scheduler` is a
  **subbrain** (`Libs/Tables/ai/subbrain.xml`, `subbrain_type="9"` =
  `Scheduler`). WO-16's speculated tree name does not exist as a tree.

**So §1.2's originally-planned test — "set `esModularBehaviorTree` to a real
tree name" — was not run, because the data says it cannot work.** Only
`subbrain_type="1"` (BehaviorTree) subbrains name a tree file, and they are
reached through the brain, not through the CryEngine MBT property. The lever
below was tested instead.

---

## §1.2 — the lever that was found, and what it does

### The documented signature, from the shipped scriptbind docs

`script_bind_2025_01_14/C_ScriptBindXGenAIModule__SpawnEntity@…html`:

```
int SpawnEntity(IFunctionHandler* ph, SmartScriptTable params);

  Name                [string]
  SharedSoulGuid      [string]
  SoulArchetypeName   [string]  (only needed when SharedSoulGuid is nil)
  ClassName           [string]  (only needed when both of the above are nil)
  LayerName           [string]  only works for streamed layers
  SpawnPointName      [string]
  Pos                 [Vec3]
  Rot                 [Vec3]
  NoAI                [bool]    disabled AI, default false
  IdleUntilFirstPatch [bool]    default false
  PerceptorObjectAI   [bool]    default true
  PerceptibleObjectAI [bool]    default true
  SchedulerProxyName  [string]
  SoulPoolName        [bool]    when spawning from pool, instead of SharedSoulGuid
  Difficulty          [int]     only applied when spawning from pool
```

It is a **flat** table. There is no `Properties` key in it.
`kdcmp.lua:1336` passes `Properties = { …, guidSharedSoulId = … }`.

`XGenAIModule.SpawnEntity`, `AddLink` and `FindLinks` are all registered in
this build (`type()` = `function`, checked live). `TryEndCombat` is not.

### What each spawn shape actually produces — read back, not assumed

Two ghosts, same donor soul `4b4c6520-…` (`ttkc_man_3`, a Troskovice guard),
same class, spawned 1 m apart:

| read back over REST | `Properties.guidSharedSoulId` (what the mod ships) | top-level `SharedSoulGuid` (documented) |
|---|---|---|
| `SharedSoulGuid` | `00000000-0000-0000-0000-000000000000` | **`4b4c6520-21a6-6125-d814-564837f165a2`** |
| `FactionNode.UIName` | `""` | **`soul_ui_name_guard`** |
| `FactionNode.Log` | empty | **full inherited reputation log** (the guards' own propagated entries) |
| `CombatLevel` | `-1` | **`0.5`** (the soul row's `combat_level`) |
| body/head | arbitrary | the donor soul's own |

**The shipped shape binds no soul.** `SharedSoulGuid` reads back as all-zeroes
— which is precisely the "plain ghost, `SharedSoulGuid=0`" WO-21 observed and
attributed to ghosts in general. It is not a property of ghosts; it is a
property of the parameter name being wrong.

*Correction this forces on WO-20:* the faces WO-20 confirmed are real,
distinct, engine-built faces — that observation stands — but they are **not the
roster soul's face**. The roster GUID is being discarded and the engine is
generating an appearance of its own. `KCD2MP_PickFaceForPlayer`'s determinism
is therefore currently determinism over a value the engine never reads.

### Adding `SchedulerProxyName` makes the ghost live

`SchedulerProxyName='ttkc_man_5'` (a real, hand-placed NPC used as the proxy):

| ghost | shape | movement over 75 s |
|---|---|---|
| `wo22C` | `Properties.guidSharedSoulId` | position **byte-identical** |
| `wo22D` | top-level `SharedSoulGuid` | position **byte-identical** |
| `wo22E` | `SharedSoulGuid` + `SchedulerProxyName` | **2352 → 2324 → 2300** — ~70 m under its own power |

A soul alone gives identity, faction and stats but no activity. A soul **plus a
scheduler proxy** gives behaviour. That is KM-A-93's sentence, reproduced.

### What a soul-backed, scheduler-linked ghost actually does

`wo22J` (guard soul + proxy), dropped from 6 m up: landed clean at 100 hp, then
patrolled a loop of its own choosing over 2 minutes —
`crime_interrupt_confronting`, `crime_interrupt_searching` (branches of
`npc_basic_switch`, the subbrain WO-21 identified as the one a ghost lacks),
and eventually picked up `npc_drunkenness`. It went for a drink.

`wo22H` (bandit soul `29f8bb4d-…`, faction
`trosecko_enemies_bandits_prepadeniAmbushers_group1`, + proxy), spawned in
town: was confronted within seconds by a real guard who drew a shield, **fled
~150 m across terrain** with 3–4 attackers in pursuit, took `injured_torso`,
started `bleeding`, kept running, and died. `wo22F`/`wo22G` (same soul) had
already done the same before the watcher was attached.

Note what that removes: the hostile faction came **from the soul row**, with no
native `SetParent` attach, no DLL injection, and no dependence on a donor NPC
being loaded in the save — WO-21's `prepadeni_bandit_1`-not-loaded blocker
disappears, because the GUID comes from table data, not save data.

---

## Gate — A1, tested at WO-17/WO-21's own conditions

WO-21's A1: *an aggro'd ghost knocked unconscious never wakes; health frozen to
the decimal; held 9 and 16 minutes until removed.*

`wo22L` — commoner soul `4209f87f-…` + `SchedulerProxyName`, health set to 4 via
the RTTR REST `SetState` path so an unarmed hit would knock it out rather than
kill it, then knocked unconscious by the human with fists:

```
08:41:08  hp=4.0  unc=false  pos=2329.35,2194.10,120.69   buffs=[low_health]
08:41:14  hp=4.0  unc=TRUE   pos=2327.36,2190.81,120.39   buffs=[unconscious,
                                        buff_infinite_blindness,low_health]
   ... 45 consecutive samples: position byte-identical to 7 decimal places,
       health frozen at exactly 4.0 -- the WO-21 signature, precisely ...
08:48:38  hp=4.0  unc=true   pos=2327.2751,2190.7922,120.37466   (last)
08:48:49  hp=4.1  unc=FALSE  pos=2327.1636,2190.1660,120.08308   MOVED
08:48:59  hp=4.1  unc=false  pos=2326.9800,2188.0918,119.81277   MOVED
08:49:10  hp=4.1  unc=false  pos=2326.6028,2180.7249,118.95262   MOVED
   ... still walking two minutes later ...
08:51:14  hp=4.1  unc=false  pos=2312.6357,2098.9810,111.59904   MOVED
```

**It woke up.** Unconscious for **7 minutes 35 seconds**, then conscious,
upright and walking away from the exact spot it fell — 90 m away by 08:51 — and
its health had started regenerating (4.0 → 4.1), the other thing WO-21 recorded
as frozen forever.

The duration matters for the comparison: WO-21's ghosts were held for **9 and
16 minutes** and never recovered. This one recovered inside that window, so the
difference is a genuine recovery, not a longer observation.

**A1: WORKED.** Stated as precisely as WO-21's own gates: the identical
knockdown that produced a permanent, health-frozen unconsciousness on a
brainless ghost produces an ordinary recoverable unconsciousness on a
soul-backed, scheduler-linked one. WO-21's re-root-cause ("the wake-up
branches live in `npc_basic_switch`, the subbrain the ghost does not have") was
correct, and giving the ghost that subbrain is what fixed it.

### Recovery on the *shipped* path is inferred, not measured

The fix was applied, built, installed and verified live through the real
unmodified `KCD2MP_SpawnGhost` (see the commit trail): a ghost spawned by the
mod now reads back its roster soul's `SharedSoulGuid`
(`40fd3055-…` = `ttro_man_30`, previously all-zeroes), `CombatLevel` 0.6488
instead of `-1`, `FactionNode.UIName` = `soul_ui_name_soldier`, the white/red
armour preset still applied, and position byte-stable across 45 s.

**A knockdown-and-recovery cycle on a mod-spawned ghost was attempted and could
not be completed.** A1's recovery evidence therefore remains `wo22U`'s two
cycles — same spawn shape, but spawned directly rather than through
`KCD2MP_SpawnGhost`, and without the armour preset and `DrawWeapon` calls the
real path adds. Nothing observed suggests those interfere. Stated plainly: the
shipped path's recovery is **inferred from an identical spawn shape, not
measured on the shipped path itself.**

The reason it could not be completed is itself a finding, and a
product-relevant one:

**A shipped ghost is a `Civilians`-faction NPC standing in a settlement, so the
player cannot attack it without committing a crime.** The attempt drew guard
aggro onto the player and had to be abandoned. This is not a testing
inconvenience to work around — it is what will happen to real players who
punch each other's ghosts in a town, and it is new since ghosts started
carrying real souls and real faction identity. Worth its own look before this
reaches users.

Anyone closing this gap later should **not** do it by punching a ghost in a
settlement. Better options: do it well outside any settlement's guard
coverage, or let a hostile NPC do the knocking down instead of the player.

## Gate — A2, and the WO-20 binds

**A2: PARTIAL, and not via the WO-20 binds.**

What is now true and was not before: a ghost **acts**. It moves under its own
decisions, confronts, evades, flees a fight, and runs crime-reaction branches.
`HasMeleeWeapon=true` throughout, `AttackersCount` up to 7. It is a
participant in combat rather than a prop in it.

What was not observed: a ghost landing a blow. Every hostile ghost this session
chose to **flee** rather than fight — a real behavioural decision (bandit
soul, `morale_context` buff, outnumbered 4:1 by armed guards), not the old
inertness. No real NPC's health was seen to drop. So "the ghost fights back"
is **not demonstrated**; "the ghost is no longer inert" is.

`AddPersonallyHostile` / `SetAttentiontarget` (WO-20's two proven-writable
binds) were **not re-tested this session** — the hostility came from the soul
row instead, which made them unnecessary for getting a fight started. Whether
a real brain now makes those writes actionable is the obvious next experiment
and is **flagged, not answered.**

## Gate — the two regression risks WO-21 flagged

**2a — `ForceMount`: NO REGRESSION.** Tested against the same real horse.

| ghost | shape | `IsMounted` after `ForceMount` |
|---|---|---|
| `wo22N` | plain (mod's current shape) | **true** |
| `wo22S` | `SharedSoulGuid` only | **true** |
| `wo22T` | `SharedSoulGuid` + `SchedulerProxyName` | **true** |

*One intermediate reading in this session showed the soul-backed ghosts
failing to mount. That was a confound, not a result: the horse was already
carrying the control ghost. Re-run against a free horse, all three mount.*
Horse riding survives the brain.

**2b — fighting the mod's position sync: REAL, and confirmed by
construction.** A scheduler-linked ghost moves continuously and of its own
accord — that is the whole point of the change, and it is exactly what
`KCD2MP_InterpTick` exists to override. `wo22K` walked 9 m away from where it
was placed within two minutes; `wo22E` walked 70 m in 75 s; `wo22J` patrolled
a loop and wandered off for a drink. Every one of them would be fighting a
position stream in a live session.

**The important sub-finding: the two are separable.** A ghost with
`SharedSoulGuid` and **no** `SchedulerProxyName` (`wo22D`, `wo22Q`, `wo22S`)
holds its position byte-identically and never moves on its own — while still
carrying the real soul, real faction, real reputation log and real combat
level. There is a middle configuration between "inert prop" and "autonomous
NPC", and it is one parameter wide.

### The soul-only configuration also recovers — tested, n=2

Run at the human's direction immediately after the above, as the one test that
gated turning this into a shipped change.

`wo22U` — commoner soul `4209f87f-…`, top-level `SharedSoulGuid`, **no
`SchedulerProxyName`**, health set to 4, knocked out unarmed by the human.
Soul binding verified first (`SharedSoulGuid` reads back the donor,
`FactionNode.UIName` = `soul_ui_name_varlet`), and stationarity verified for a
full minute before the knockdown — position byte-identical across 6 samples.

| cycle | went unconscious | conscious again | upper bound on recovery |
|---|---|---|---|
| 1 | 09:00:41 | 09:01:35 | **≤ 54 s** |
| 2 | 09:07:08 | 09:07:34 | **≤ 26 s** |

Both times it stood back up — Z returned to exactly ground level — and then
**stayed put**: byte-identical position for the following 3½ minutes, with no
independent movement at any point in either cycle.

**This is the configuration the project wants.** A1's fix, with none of the
position-sync cost, and `ForceMount` already confirmed working on this same
shape (`wo22S`, above).

Two honest caveats:

- Recovery here was **much faster** than the proxied case (≤54 s and ≤26 s
  versus 7 m 35 s). n=1 proxied against n=2 soul-only, single location, single
  session. The plausible reading is that a proxied NPC has a scheduler activity
  to re-acquire before it counts as recovered while a proxy-less one simply
  stands up, but that is inference, not measurement.
- Health did **not** regenerate here (held at exactly 4.0 through both cycles),
  where the proxied ghost ticked 4.0 → 4.1. Whatever drives regen appears to
  sit on the scheduler side. Minor, but it means "health frozen" is not by
  itself the A1 signature — the unconsciousness ending is.

---

## §1.3 — secondary items

**`DISASSEMBLY.md`** — a byte-signature route to `gEnv` (via the
`'exec autoexec.cfg'` string xref), plus vtable indices verified against
V1.2.2 with an explicit warning that current retail is `release_1_5` and RVAs
should be re-derived by signature scan. Several indices differ from public
CryEngine headers by exactly one unknown virtual (`IScriptSystem::CreateTable`
14th not 13th; `IScriptTable::SetValueAny` 8th not 7th; `AddFunction` 23rd not
22nd; `IGameFramework::RegisterListener` 101st). Useful to a future native
attempt; **no native work was done or started this session.** The repo also
ships `DLL/WHGame_release_1_5.dll` — a current-version binary to diff against.

**`lua_dump_state/LuaState.txt`** — 29,582 lines from a loaded retail save.
Two things this project's own probing had not surfaced:
`XGenAIModule.AddLink()` and `XGenAIModule.FindLinks()` — the KM-A-93 AI-link
surface, registered and callable, never tried here. `AddLink(fromWUID, toWUID,
'TagName')` is documented as creating a real entity link with a tag that "must
exist". That is a second, finer-grained route to giving a ghost a scheduler
link than borrowing another NPC as proxy, and it is **untested.**

**`script_bind_2025_01_14/`** — this is where the session's whole result came
from, so it is emphatically *not* redundant with what the project already has.
The delta worth recording: `SpawnEntity`'s parameter table (above), and
`SetBrainVariable(WUID, char*)` / `(WUID, char*, SmartScriptTable)` — a
two-argument overload WO-21 did not try. Also present in the docs but **not**
registered in the retail Lua state: `SpawnEntity` is (checked live, it is),
but `TryEndCombat`, `LootBegin`, `ForceSyncFromLua` and `RemoveDaycyclePatch`
are not — so the shipped docs describe a superset of what this build
registers, and existence must be checked per call rather than assumed.

---

## What this changes, and what it does not

**Nothing shipped was changed.** `KCD2MP_SpawnGhost`'s defaults, the aggro
toggle, `VERSION` and the installer are untouched. Every test spawn was
runtime-only and removed at the end of the session (verified: none remain).

**Follow-up decisions, not this WO's to make:**

1. `KCD2MP_SpawnGhost` passes `guidSharedSoulId` in a `Properties` sub-table
   where the documented parameter is a top-level `SharedSoulGuid`. This is a
   one-line fix that turns the face roster from decorative into real. It also
   confers faction and combat level, which has consequences worth thinking
   about before shipping.
2. **`SchedulerProxyName` should not be passed.** It is not what buys A1's
   fix — the soul alone does that — and it is the sole cause of the
   position-sync conflict. Ship `SharedSoulGuid`, omit the proxy.
3. `PROJECT-STATE.md`'s A1 entry ("an aggro'd ghost knocked unconscious never
   wakes up") is now conditional on the brainless spawn shape, and should say so.
4. Aggro could come from the soul row's own `factionName` rather than the
   native `SetParent` attach. Untested as a replacement, but it would remove
   the DLL-injection dependency and the "donor not loaded in this save"
   fragility in one move. Worth a WO of its own.

## Licensing

Nothing was copied from `muyuanjin/kcd2-mod-docs` into this repo. The repo
carries **no LICENSE file**; its contents are largely extracted retail game
data and a mirror of Warhorse's wiki, neither of which is the uploader's to
relicense. The only things taken from it here are **facts** — a documented
function signature, a database column name, a sentence of official
documentation — which is the intended use of a docs repo. Any future reuse of
actual files from it needs a licensing answer first.

## Files touched

- `tools/wo22-lua.ps1` (new) — ExecuteString driver + `[WO22]` log reader
- `tools/Wo22-Watch.ps1` (new) — telemetry watcher with per-sample movement delta
- `docs/WO-22-brain-lead.md` (this file)

No changes to `kdcmp.lua`, `native/`, `dotnet/`, `VERSION`, or the installer.
