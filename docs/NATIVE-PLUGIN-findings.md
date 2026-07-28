# Native plugin — what the binary actually exposes

Investigated 2026-07-27 against KCD2 v1.5.2, Modding Tools build, game running.
Answers the five opening questions of the native-plugin brief.

> **Headline: shared combat is not blocked, and the blocker was never the
> engine.** Writing NPC health, dealing damage and killing an NPC through the
> game's own combat entry point all work today. They were verified live, by
> observing the effect, not by a call returning success. What is inert is the
> **Lua** surface specifically — a separate and much thinner binding than the one
> the engine actually runs on.

This supersedes the "shared combat is not achievable on this API surface" banner
in `ARCHITECTURE-shared-world.md`. The reasoning in that document about *where*
to draw the shared/private boundary stands; its capability conclusion does not.

---

## The thing that changes everything: an RTTR reflection ABI

The game is built on [RTTR](https://www.rttr.org/), a C++ runtime-reflection
library, and Warhorse registered a large part of the game object model with it.
Two consequences:

1. **The debug REST API on `localhost:1403` is a reflection browser.** Every
   `/api/...` path is a walk over reflected properties, and it can **invoke
   reflected methods and set reflected properties**, not just read them.
2. **`CrySystem.dll` exports the entire RTTR runtime by name** in the Modding
   Tools build. An injected DLL can `GetProcAddress` its way to the whole object
   model and drive it **by name** — no offsets, no signature scans, nothing that
   silently breaks on the next patch.

Exports confirmed present in `CrySystem.dll` (1087 named exports total):

| Mangled export | Meaning |
|---|---|
| `?get_by_name@type@rttr@@SA...` | `rttr::type::get_by_name("wh::rpgmodule::CombatSoul")` |
| `?get_method@type@rttr@@QEBA...` | look a method up by name |
| `?invoke@method@rttr@@QEBA...` | invoke it — overloads for 0–6 args |
| `?invoke_variadic@method@rttr@@QEBA...` | invoke with an argument vector |
| `?get_property@type@rttr@@QEBA...` | look a property up by name |
| `?set_value@property@rttr@@QEBA...` | **write** a property |
| `?set_property_value@type@rttr@@QEBA...` | write by name in one call |
| `?get_value@property@rttr@@QEBA...` | read a property |

This is as close to a supported plugin surface as a shipping game gets without
advertising one. It is the single most important finding here, and it collapses
the reverse-engineering burden the brief was braced for.

---

## Verified: the writes work

Every row below was confirmed by reading the value back after the call. The
project rule that `pcall` returning true proves nothing applies equally to HTTP
200, so nothing here rests on a status code.

| Test | Before | Call | After | Verdict |
|---|---|---|---|---|
| Player stamina | 126.667 | `SetState?State=stamina&Value=60` | **60**, then **69.2** 0.4 s later | works — and the regen tick moving it afterwards proves the *simulation* adopted the value, not just a cached field |
| Player health down | 100 | `SetState?State=health&Value=95` | **95** | works |
| Player health restore | 95 | `SetState?State=health&Value=100` | **100** | works, reversible |
| Player damage | 100 | `CombatSoul/TakeDamage?Stamina=0&Health=5&SuppressHitReaction=true` | **95** | the real combat entry point applies damage |
| **Generic NPC damage** | pig at 100 | `TakeDamage?Health=10` on `SpawnedAnimal_Pig_7F983C91_0` | **90** | works on a live world NPC, not just the player |
| **Generic NPC death** | pig at 90 | `TakeDamage?Health=200` | **0**, `IsDead=true` | the death transition fires |

Contrast with the Lua results in `ARCHITECTURE-shared-world.md`: `actor:SetHealth`
and `soul:DealDamage` were inert on three subjects across both game phases. Same
game, same session, same underlying object — **the Lua bindings are stubs; the
reflected C++ methods are the real thing.** That is the correct reading of the
earlier negative result, and it is why "the exposed Lua surface is read-mostly"
was true and yet the conclusion drawn from it was too broad.

The pig was killed deliberately, with the user's authorisation, because a health
write that never triggers the death transition would be a silent failure mode for
shared combat. It is a `SpawnedAnimal_*`, the explicitly replaceable class.

### The reflected combat primitive

```
wh::rpgmodule::CombatSoul::TakeDamage(
    float Stamina,
    float Health,
    I_Soul* Attacker,            // DefaultValue=""
    bool   SuppressHitReaction,  // DefaultValue=false
    BodyPartData InjureBodypart) // DefaultValue=""
```

This is exactly the shape shared combat needs: damage split into stamina and
health, attacker attribution, optional hit reaction, and a body part for injuries.

**One parameter does not survive the HTTP boundary.** `Attacker` is an
`I_Soul*`, and RTTR has no registered string→pointer conversion, so every form
was rejected:

```
Failed to invoke method 'TakeDamage'. Failed to convert parameter
'Attacker=4c2dcffb-...' to type 'wh::rpgmodule::I_Soul*'.
```

Tried as a GUID, as an `/api/...` path, and as a soul name — all 400. This is a
**limitation of the transport, not of the method**: an in-process caller passes a
real pointer and never touches the converter. It is also the clearest single
argument for the native plugin over the HTTP prototype, because without
attribution a damaged NPC has nobody to aggro onto. **In-process attribution is
unverified** — it is the first thing the DLL should prove.

---

## 1. Injection and hooking — what does the binary expose?

**Two completely different targets, and the one you already launch is by far the
better one.**

| | Modding Tools (`KCD2Mod`) | Retail (`KingdomComeDeliverance2`) |
|---|---|---|
| Layout | **non-monolithic**, 40+ module DLLs | monolithic `WHGame.dll`, 89 MB |
| Exports | **mangled C++ symbols** — `CrySystem` 1087, `CryAISystem` 204, `EntityModule` thousands | almost none |
| RTTR runtime | **exported by name** | compiled in, not exported |
| Reflection REST API | **present** (`C_ModuleHttpServerListenerManager` in `Framework.dll`) | **absent** — zero matches |
| Build flavour | `Win64ReleaseSteamLTO_DLL`, has an `.msvcjmc` section (`/JMC`, a dev-build flag) | `Win64MasterMasterSteamPGO` |
| Control Flow Guard | **off** (`dllchar 0x0160`) — no CFG checks to defeat when detouring | off |
| ASLR | on — resolve as module base + RVA, never absolute |

So: **not raw hooking against a stripped shipping build.** Against the Modding
Tools build you get named exports plus a name-addressable object model. That is a
different and much safer discipline than the brief assumed.

The cost is that **the plugin is Modding-Tools-only**, which is what you already
require anyway (`LAUNCHING.md`), and both players need that Steam entry
installed. Retail keeps the RTTR *registrations* but exports nothing and has no
REST listener, so a retail port would mean locating RTTR internals by hand — a
real project, not a recompile. Recommend not attempting it.

**Is there a supported plugin loader?** Partially. `Cry::PluginManager::CSystem`
and a `CreatePlugins` symbol exist in `CrySystem.dll`, so the engine has the
CryEngine plugin machinery. But there is **no `cryplugin.csv` or `.cryproject`
string anywhere**, so the plugin list appears to be hardcoded rather than
data-driven, and I found no place to register a DLL from outside. **Unverified
rather than ruled out** — worth another hour before committing to injection.
Injection works regardless, and `KCDMP_launcher` is already written for it.

## 2. Anti-cheat — does KCD2 resist injection?

**No.** Searched both installs for `EasyAntiCheat`, `BattlEye`, `Denuvo`,
`VMProtect`, `Themida` and `.enigma` as both files and binary strings: zero hits.
Sections are ordinary (`.text/.rdata/.data/.pdata/.reloc`), no packer stubs, CFG
off. It is a single-player game with an official modding SDK, a debug REST server
and a Lua console.

The practical risks are ordinary native-code risks — a bad pointer crashes the
game rather than logging an error — plus one social one: the debug HTTP server
binds a port, and `http_startserver` accepts a password argument that is not
being used. Bind to loopback and keep it there.

### Milestone 1 — done, verified in-process

`native/` now builds `KCDMP.dll` and `KCDMP_LauncherInjector.exe` with MSVC
19.44 (`native/Build-Native.ps1`). Injected into the live game by pid:

```
CrySystem.dll base = 00007FFD464C0000
CrySystem.dll named exports = 1087
exports mentioning rttr      = 1013
  OK   type::get_by_name        (1 overload)
  OK   type::get_method         (2 overloads)
  OK   type::set_property_value (2 overloads)
  OK   method::invoke           (7 overloads)
  OK   property::set_value      (1 overload)     ... 15/15 resolved
RESULT reflection ABI fully reachable
```

**The game survived injection** — still rendering, debug API still answering,
87 threads, no crash. Classic `CreateRemoteThread(LoadLibraryA)`; nothing exotic
was needed, as expected given there is no anti-cheat.

Exports are matched **by prefix** against the live export table rather than by
hardcoded mangled string. Transcribing a 200-character mangled name by hand is a
silent-failure machine, and a prefix survives a signature change across a patch
instead of quietly resolving to null.

## 3. Entity identity — the stable cross-client key

**Settled far enough to design on, and it is `SharedSoulGuid` — the opposite of
what I guessed.**

Snapshots either side of a full game restart, same save
(`tools/soul-identity-run1.csv`, `run2.csv`), 840 souls present in both:

| Key | Stable across restart | Ambient `SpawnedAnimal_*` | Hand-placed |
|---|---|---|---|
| `SharedSoulGuid` | **840 / 840 (100 %)** | 48 / 48 | 792 / 792 |
| `Guid` | 834 / 840 (99 %) | 47 / 48 | 787 / 792 |

The six `Guid` failures are UI scaffolding, not world NPCs —
`InventoryDummyPlayer1[ui/Apse2_...]`, `Horse2[ui/...]` — plus one deer.
`SharedSoulGuid` did not move at all, **including for runtime-spawned ambient
animals**, which is what I expected to fail.

**Use `SharedSoulGuid` as the cross-client key.** Fall back to `Name` for
diagnostics, never to `Guid`.

### Closed: the GUIDs are shipped in the level data

The restart only proved persistence within one save. The stronger proof turned
out to be sitting on disk: **soul GUIDs are authored content in the level XML**,
so they are byte-identical on every installation of the game. No second save, no
second machine, no playline comparison needed.

`Data/Levels/trosecko/Layers/main/ttkc_troskovice/cemetery/_script/animal/vosycka.lyr`:

```xml
<Soul version="7">
  <SharedSoulGuid>74d93621-d457-4870-9e3e-ecbf41701c6d</SharedSoulGuid>
  <Guid>ffc6c12f-4d6a-48a1-8ba9-bb3214d4d006</Guid>
  <EntityGuid>7286bff6-28af-483a</EntityGuid>
  <Name>ttkc_vosycka</Name>
</Soul>
```

Both GUIDs match what the running game reports for that soul, exactly. Spot
checked the same way against live values for `ttkc_woman_6` (generic townsfolk)
and `ttkc_jezek`. There are **6,443 authored souls** across the three levels:
trosecko 1,402, kutnohorsko 4,914, klaster 127.

### But only for hand-placed souls — and that distinction matters

Two classes of soul, and only one is authored:

| Class | In level data? | Cross-client key |
|---|---|---|
| Hand-placed — named NPCs, guards, soldiers, townsfolk, horses | **yes** | `SharedSoulGuid`, authored, settled |
| Runtime-spawned — ambient wildlife, some scripted groups | **no** | **unresolved, assume unstable** |

`SpawnedAnimal_Pig_E8D210A1_0` appears nowhere in the level data, and neither
does its hex key. The generator is a format string in `XGenAIModule.dll`:

```
SpawnedAnimal_%s_%X_%u        -- class, some 32-bit key, index
```

Their GUIDs held across the restart because they are **saved**, not because they
are authored. Whether `%X` derives from an authored spawner or from a
session-dependent id is **unproven**, and the restart test could not tell the
difference because both loads read the same save. `rvacka_apprentice_1` — the
static brawl group that misled an earlier round of testing — is likewise absent
from level data.

**So my earlier speculation was right for the wrong reason and my correction to
it was also wrong.** Spawned animals really are the unstable class; the restart
diff appeared to refute that but could not actually see the distinction. Two
tests, two misreadings, settled only by going to the shipped data.

### The design consequence, which is a large simplification

The shareable set the goal actually needs — **rank-and-file soldiers at a siege,
town guards, generic townsfolk** — is exactly the authored, settled class.
Ambient wildlife is the unsettled class and is the least valuable thing to
share. So: **share authored souls, treat runtime-spawned entities as private.**
That sidesteps the open question entirely rather than waiting on it.

Better still, this replaces the runtime name-pattern heuristic in
`ARCHITECTURE-shared-world.md` ("Classifying an NPC at runtime") with something
mechanically derivable **offline**. The game's own layer tree is the authors'
classification:

```
main/_quest/...            <- 100 of 426 soul-bearing files in trosecko
main/ttkc_troskovice/...   <- settlement population
main/ttro_trosky/...
```

Across all three levels, 473 of 1,561 soul-bearing layer files sit under a
`_quest` branch. So the allow-list can be **generated from the shipped data and
audited in advance** — soul GUID, name, entity class, position and layer path
for every candidate — instead of pattern-matching names at runtime and hoping.

This keeps the existing rule ("allow-list positively, default to private") and
makes it checkable. It is not a complete classifier on its own: a unique named
NPC such as a quest-giving blacksmith lives in a settlement layer, not under
`_quest`, so the unique-vs-generic filter is still needed. But it now runs over
real authored data rather than string patterns.

`SoulList` carries two indices, `SoulsByGuid` and `SoulsByName`, and every soul
exposes both `Guid` and `SharedSoulGuid`. Both are addressable:
`/api/rpg/SoulList/SoulsByGuid/<guid>/Name` and
`/api/rpg/SoulList/SoulsByName/<name>/Guid` both resolve.

Of 846 souls sampled, **`Guid` and `SharedSoulGuid` differ for 831**. They are
not two names for one thing, and which of them is authored data rather than
per-session state is unverified.

The awkward part: the shareable class may be the one *without* a stable key.
Hand-placed NPCs (`ttkc_vosycka`, `tkop_ptacek`) are authored, so their identity
plausibly comes from level data. But `SpawnedAnimal_Pig_7F983C91_0` is spawned at
runtime — its GUID is likely minted per session. Its **name** embeds what looks
like a spawner hash (`7F983C91`) plus an index, which would be stable if the
spawner is deterministic. **So the likely cross-client key is the soul *name*,
not either GUID** — the opposite of what you would reach for first.

**The test, and it needs no second machine:** a snapshot of 846
name/Guid/SharedSoulGuid/Position rows is saved at
`tools/soul-identity-run1.csv`. Restart the game, load the same save, re-run
`tools/Probe-Reflection.ps1 -Snapshot`, and diff. Whatever survives a restart is
the candidate key; whatever does not is disqualified. Two loads of one save is a
fair proxy for two clients of one world, and it is the cheapest decisive test
available.

Until that runs, **treat identity as unresolved** and do not design the wire
protocol around GUIDs.

## 4. Authority — one client per area, or the relay?

**Damage-authoritative peers, relay as ordered broadcast.** Keep the relay
stateless, as designed.

The reasoning is forced by what the engine gives us. Both clients run a full
simulation of the same NPC with independent AI — there is no way to make one
client's brain drive the other's body, because the AI surface is thin (see
below). So each client keeps simulating locally, and only **damage events** and
**deaths** replicate:

- The client whose player landed a hit is authoritative **for that hit**, and
  sends `{targetKey, stamina, health, attackerKey, bodypart}`.
- Every other client applies it with `TakeDamage`, tagged so the hook does not
  re-broadcast it. Without that tag it loops forever.
- **Death is a separate, idempotent message**, not an inferred consequence of
  health reaching zero. Two clients computing "dead" independently from slightly
  divergent health will disagree; a client that has already applied it must
  ignore a repeat.

Per-hit authority rather than per-area ownership because hits are discrete,
attributable and rare compared to frames, and because area ownership needs a
handoff protocol that buys nothing here. Divergence in *health values* is
tolerable and self-correcting if death is authoritative; divergence in *who is
alive* is not.

**Cost:** one relay round trip per hit. At ~37 ms p50 through the current HTTP
channel plus relay latency, a hit lands on the peer roughly 100 ms late — fine
for a health bar, visible if you are watching the recipient flinch. In-process
the reflected call itself is free, so the budget is pure network.

## 5. How much of the Lua mod survives?

`kdcmp/Data/Scripts/Startup/kdcmp.lua` is ~2400 lines. Rough split:

- **Redundant once the DLL renders players** — the ghost NPC spawn/despawn
  lifecycle, position and rotation application, the `ExecuteString` inbound
  batching, and the `[KCD2-MP-DATA]` log emitter. The DLL reads and writes
  in-process; none of that plumbing has a job.
- **Worth keeping as data, not code** — the animation tables and speed
  thresholds. Those are empirically derived, they cost real time to establish,
  and they stay true regardless of what drives them. Port them to a data file the
  DLL reads; do not retype them as C++ literals.
- **Keep as-is for now** — anything touching UI. `UIAction` element listeners and
  the interaction prompt from WO-2 have no native equivalent identified yet, and
  the GUI module's reflected surface has not been examined.

The Lua mod stops being the transport and becomes, at most, a UI shim. Note this
also means the pak still needs to load, so Modding Tools stays in the loop.

---

## Aggro: no stimulus-injection surface exists

Attempted 2026-07-27, after attribution was shown not to follow from
`TakeDamage`. **The stimulus-replication mechanism proposed in
`ARCHITECTURE-shared-world.md` cannot be built as specified**, because nothing
on any name-addressable surface injects a perception, alarm or aggro state.

Everything below was probed, not assumed:

| Surface | What is there | Usable for aggro? |
|---|---|---|
| `xgen` (XGenAIModule) reflected | `SmartEntityDatabase`, `PerceptionHistory` — both read-only; `PerceptionHistory.GetRecords()` reads | **no** |
| `XBehaviorModule` reflected | **completely empty** — no properties, no methods | **no** |
| `XGenAIModule.dll` exports (1,784) | behaviour-tree attribute-enum glue (`E_crime_stimulusKind` and friends). `C_AISingletons::PerceptionManager()` returns the singleton, but **none of its methods are exported** | not by name |
| `C_SkirmishManager` reflected | `DebugTriggerEvent(soulName, eventName)` — callable, takes strings | **tested, no effect** |
| `SkirmishEventTypes` database | 25 real event names: `SoulAdded`, `SoulDied`, `HitTarget`, `Attack`, `Combo`, `MasterStrike`, … | names are real, triggering them is not |
| `FactionManager` / `NPCFaction` reflected | `GetFaction`, `GetRelation`, `PlayerReputation` — all queries | read-only |
| Lua `AI.*` | inert (established earlier) | **no** |

`DebugTriggerEvent` was the strongest candidate and it does nothing observable.
Triggered `SoulAdded`, `Attack` and `HitTarget` on a live NPC standing next to
the player; `IsSoulCharged`, `AttackersCount` and `Target` were unchanged after
each, and the player's own `AttackersCount` stayed 0. The call returns void and
raises nothing — **exactly the shape of the inert Lua stubs**, and a reminder
that a reflected method existing says nothing about it working. It presumably
routes into an already-running skirmish and has no effect on a soul outside one.

### Three ways forward, cheapest first

1. **Make the remote player a genuinely perceptible actor.** The presence layer
   already spawns ghost NPCs for remote players. If a ghost is a real actor
   entity rather than a puppet, the local AI perceives it through the game's own
   perception system and aggro emerges with **no injection at all** — a guard
   reacts to a hostile ghost the way it reacts to any NPC. This uses zero new
   API and works with the engine rather than around it. **Recommended.**
2. **Faction and reputation.** Not reflected, but `C_FactionBase::AddReputation`,
   `SetParent`, `IsPublicEnemy` and `GetRelationship` *are* exported from
   `RPGModule.dll`, so they are name-addressable natively. Coarse and social
   rather than per-encounter, but real and patch-resilient.
3. **Reverse-engineer `C_PerceptionManager`.** The singleton accessor is
   exported; its methods are not. This means vtable analysis and hardcoded
   offsets — precisely the fragile, silently-breaking-after-a-patch work the
   brief warned about. Last resort.

Option 1 is the only one that does not fight the engine, and it reframes the
problem usefully: the goal is not to *inject* aggro but to make the other player
**exist** convincingly enough that the AI aggroes on its own.

## What the reflection surface does *not* give you

Honest boundaries, because the surface is uneven — Warhorse registered richly
where they wanted a debug browser and barely at all elsewhere.

| Module | Reflected surface | Usable for |
|---|---|---|
| `rpg` (`SoulList`, `Soul`, `CombatSoul`) | **rich** — states, stats, skills, inventory, combat, 1491 souls indexed two ways | combat, health, presence, classification |
| `xgen` (AI) | **two properties**: `SmartEntityDatabase`, `PerceptionHistory`. No methods. | almost nothing |
| `ent` | **three properties**: `ClothingSystem`, `GameProfileManager`, `StashManager`. No methods. | almost nothing |

So **shared AI state, aggro and patrol synchronisation are not reachable by
reflection**, and the brief's "if one player distracts a guard, everyone sees it"
still needs the stimulus-replication approach from `ARCHITECTURE-shared-world.md`
§"Distraction does not need shared NPCs" — replicate the *event*, let each client's
own AI react. That advice survives intact and is now the recommended design
rather than a consolation prize.

Doors, containers and dropped items are likewise not reachable through `ent`.
Unverified whether they are reachable another way.

### The outbound problem

Reflection is pull-only: it cannot tell you that the local player just hit
something. `TakeDamage` is **not exported** from `RPGModule.dll` or
`CombatModule.dll`, so it cannot be detoured by name. Options, best first:

1. **Recover the address from the RTTR method wrapper.** The `rttr::method`
   object holds a callable that forwards to the real member function; walking it
   yields the true address, *derived at runtime* rather than hardcoded. Patch-
   resilient. Moderate effort, needs the RTTR wrapper layout worked out.
2. **Signals.** `wh::shared::C_SignalBase` appears throughout `Framework.dll`.
   If souls emit a damage or death signal, subscribing beats hooking. Unexplored.
3. **Poll `Soul.IsDead` and health** across the shared set. Simple, lossy, and it
   cannot attribute a hit. Acceptable as a stopgap for deaths only.

Do not hardcode a scanned offset for this. That is the failure mode the brief
warned about, and options 1 and 2 both avoid it.

---

## Traps found today, added to the list

- **A container read without `?depth=` serialises the entire object graph.**
  `GET /api/rpg/SoulList/SoulsByName` returned **658 MB**. Always pass
  `?depth=0` (keys only) or `?depth=1` (shallow), and use
  `?exclude=<comma list>` to drop heavy subtrees. `tools/KcdApi.ps1` caps every
  read for exactly this reason.
- **`?depth=1` on `SoulsByName` is a whole-world presence snapshot in one round
  trip** — name, GUID, position, `IsDead` for every soul. ~4 s and >20 MB, so not
  per-frame, but it makes periodic reconciliation nearly free compared with the
  Lua tick emitter.
- **The first request after connect takes ~2.15 s**, warm calls ~37 ms p50. This
  matches the WO-1 finding; anything with a short timeout must retry.
- **`POST` on a method path returns 400 where `GET` works.** Method invocation is
  `GET /api/<path>/<Method>?<Param>=<value>`. The POST path exists but wants a
  different shape ("POST methods supports only 1 parameter"); not worth pinning
  down while GET works.

---

## Recommended order

1. ~~Settle identity~~ — **done and closed**, `SharedSoulGuid`, proven authored
   from the shipped level XML. Applies to hand-placed souls only; runtime-spawned
   wildlife is unresolved and should be treated as private (§3).
2. ~~Get a C++ toolchain~~ — **done**, VS Build Tools 17.14 / MSVC 19.44,
   with CMake and Ninja. Not on PATH; `native/Build-Native.ps1` finds it.
3. ~~Injector and DLL skeleton~~ — **done**, injects cleanly, all 15 reflection
   entry points resolve in-process.
4. **Prove in-process attribution** — call `CombatSoul::TakeDamage` through
   resolved RTTR with a real `I_Soul*` attacker and check `AttackersCount`
   moved. This is the one thing HTTP could not test, and the authority model
   rests on it. **Next.**
5. **Then** the outbound hook (§"The outbound problem"), then the wire protocol,
   then wiring `KCDMP_launcher` to the now-real injector.

### How step 4 should be built

**This is a Warhorse fork of RTTR, not upstream, so vendoring upstream headers
is not an option.** Two independent tells:

- `type::get_by_name` takes **`std::basic_string_view<char>`**. Upstream 0.9.6
  takes `rttr::string_view`, a class of its own. Different type, different ABI.
- Classes that do not exist upstream live inside `namespace rttr`:
  `C_RTTROnScreenDebug`, `C_RTTRDebugUtils`, `C_RTTRRegistrationValidator`,
  `C_ContainerSerializer`, `E_PropertyMetadata`.

An earlier draft of this document recommended vendoring version-matched headers.
That was wrong and is withdrawn — there is no upstream version to match.

The ABI was instead recovered **statically**, by decoding function prologues out
of the DLL. Zero risk, and it needs no running game:

| Function | RCX | RDX | R8 | Returns |
|---|---|---|---|---|
| `type::get_by_name` (static) | hidden sret pointer | `&string_view` | — | through RCX |
| `type::is_valid` (const) | `this` | — | — | `AL` |
| `property::set_value` (const) | `this` | `&instance` | `&argument` | `AL` |

`type::is_valid` does `mov rax,[rbx]` straight off `this`, so **`rttr::type` is a
single pointer** — and it is returned indirectly, which means it is *not*
trivially copyable, consistent with upstream's user-declared copy constructor.
The same single-pointer shape holds for `method` and `property`; a whole family
of their pointer-taking constructors share one thunk at RVA `0x4F530`, which is
what a wrapper that only stores a pointer compiles to.

So the plan is to hand-declare minimal stand-in types whose **size and
triviality** match the originals, and let MSVC apply its own class-passing rules
to generate the calls. Same compiler, same rules, same result — without needing
the real declarations. Where a stand-in must be non-trivially-copyable to be
passed indirectly, give it a user-defined copy constructor.

`std::string_view` needs no stand-in at all: the game is MSVC-built, so our
`std::string_view` is layout-identical, and the disassembly confirms the callee
reads the data pointer from offset 0.

### Milestone 2 — done, the ABI model is validated in-process

Sizes and layouts, all read out of the binary rather than assumed:

| Type | Size | Layout | Evidence |
|---|---|---|---|
| `type`, `method`, `property` | 8 | one pointer | `is_valid` does `mov rax,[rbx]`; the pointer-taking wrapper ctors share one thunk at RVA `0x4F530` |
| `variant` | **24** | `{ char data[16]; void* policy; }` | ctor writes policy to `[this+0x10]`; dtor loads it and tail-calls with op=0; copy-ctor copies it and calls with op=1 |
| `argument` | **24** | `{ const void* data; uint64 ?; type }` | default ctor zeroes `+0` and `+8` then constructs a member at `+0x10`; `get_type` returns `[this+0x10]` |
| `instance` | ≥16 | `type` at offset 0 | `get_type` does `mov rax,[rbx]` |

**`argument` is 24 bytes here against upstream's 16.** Vendoring upstream
headers would have compiled cleanly and corrupted memory at runtime — the worst
available failure mode, and the reason this was measured rather than assumed.

Every call is wrapped in SEH. An access violation inside the game's process is
a hard exit with no diagnostic; `__try`/`__except` turns a wrong assumption into
a log line instead of a vanished game.

The validation is built so a wrong model cannot pass by accident:

```
ABI: get_by_name("wh::rpgmodule::Soul") -> data=0000021EFF6F7400 is_valid=true
ABI: get_by_name(<nonexistent>)         -> data=00007FFD46AF8360 is_valid=false
ABI: wh::rpgmodule::Soul::GetState   sig="GetState( wh::rpgmodule::SoulState )"
ABI: wh::rpgmodule::Soul::SetState   sig="SetState( wh::rpgmodule::SoulState, float )"
ABI: wh::rpgmodule::CombatSoul::TakeDamage
     sig="TakeDamage( float, float, classwh::rpgmodule::I_Soul*, bool, wh::entitymodule::BodyPartData const & )"
ABI: VALIDATED -- model matches the binary
```

The **negative control matters most**: a nonexistent type resolves *invalid*.
Without it, a model that returned plausible-looking garbage would have read as
success. And those signatures are byte-for-byte what the HTTP reflection browser
reported hours earlier by a completely independent path — two routes to the same
strings is strong corroboration that the hand-modelled convention is right.

Game alive throughout.

### What still blocks the first invoke

1. **`argument`'s middle eight bytes** are unidentified. Constructing one is
   unavoidable — every `invoke` takes them, and the useful templated
   constructors are header-inline, so they are not in the export table.
2. **`instance`'s full layout** likewise.
3. ~~Getting a live object pointer~~ — **solved.** `Shared.dll` exports it:

   ```
   ?GetInstance@C_GameInterface@shared@wh@@SAPEBV123@XZ          -> const C_GameInterface*
   ?GetWritableInstance@C_GameInterface@shared@wh@@SAPEAV123@XZ  -> C_GameInterface*
   ```

   A zero-argument static returning the exact root object the REST browser
   walks from — the trivial ABI case, no hidden pointers, result in RAX. From
   there the route to a soul is the same walk the HTTP API does:
   `GameInterface → RPGModule → SoulList → PlayerSoul → CombatSoul`.

   Navigation itself has to go through reflection: `RPGModule.dll` exports only
   121 symbols and they are almost all faction code — no `SoulList` accessor.

Items 1 and 2 are more prologue decoding of the kind already done twice, and
partially done:

- `instance` default ctor fills `+0` and `+8` from two separate calls, then
  zeroes a third field — consistent with `{ type; type; void* }`, 24 bytes, with
  `get_type` returning the one at `+0`. **GUESS**, not yet confirmed.
- `argument`'s copy ctor moves `+0`, `+8` and `+0x10`; its variant ctor asks the
  source variant's policy for a raw pointer (`op=7`) and stores the result.

Neither is worth more static decoding than that. The cheap way to settle both is
to build them, walk to `PlayerSoul`, read health natively, and **compare against
the value the HTTP API reports for the same soul at the same moment**. An
independent ground truth already exists, so a wrong layout shows up as a
mismatch or an SEH-caught fault rather than as a plausible-looking number.
