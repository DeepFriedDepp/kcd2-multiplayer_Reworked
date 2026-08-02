# WO-15 — SkirmishManager during a live siege

Investigated 2026-08-02 against KCD2 (Modding Tools build), a real playthrough
reloaded to the intro siege (quest `zoufalaObranaZaBohutu`, "Desperate Defense
of Bohdaneč"-shaped Czech name), with the human actively playing — AI fighting
AI and the player fighting AI simultaneously, confirmed by the human before
any probe was trusted.

This is the specific untested condition the original aggro finding
(`NATIVE-PLUGIN-findings.md`) flagged but never checked: `DebugTriggerEvent`
"does nothing observable outside a running skirmish" was tested in the one
condition where it had no reason to do anything. This WO ran it, and
everything else in scope, during a real one.

**Evidence discipline used throughout:** every claim below is a live REST
call against `localhost:1403` (Modding Tools debug API), a before/after
comparison, or a `?info` reflection dump — not an assumption. Where a result
could plausibly be API noise rather than a real effect, a control was run to
rule that out (see "0.3" below).

---

## 0.1 — Logistics: how to get back into the siege

**No mission-jump, chapter-select, or level-load command exists.** Checked:
`docs/LAUNCHING.md` records that `+map` was deliberately dropped from the
launcher ("KCD2 loads a save; there is no level to boot into"); the RTTR
reflection surface and the CryEngine Lua scriptbind docs
(`Tools\modding\docs\script_bind\script_bind.zip`, extracted and searched)
expose no quest/chapter-jump entry point.

**What actually worked:** a full intro replay to reach the siege the first
time, then **a permanent-save reload got back into it a second time**, at an
earlier point in the same battle (mostly-full-health NPCs vs. the first
visit's partially-fought state). The save used:

```
Saved Games\kingdomcome2\saves\playline2\permanent002.whs
```

`permanent001.whs` (same playline, ~5 min older) is presumably the character-
creation/very-start checkpoint. `permanent002.whs` is the useful one — it
appears to be a story checkpoint at or very near the siege's start. **This is
the answer for a follow-up session**: load `playline2\permanent002.whs`
directly rather than replaying the intro from scratch. Whether it drops you
at the *exact* start of the battle or partway through wasn't pinned down
precisely (the reload showed most NPCs full-health with only a handful of
pre-existing casualties), but it is close enough to be repeatable and cheap.

---

## 0.2 — What `SkirmishManager` actually holds and does during a live skirmish

**Nothing. Confirmed, not assumed.**

```
GET /api/rpg/SkirmishManager?depth=0   -> <C_SkirmishManager />
GET /api/rpg/SkirmishManager?depth=5   -> <C_SkirmishManager />
GET /api/rpg/SkirmishManager?info      -> <Properties /> (zero), one Method
```

The `?info` reflection dump is the decisive piece: it doesn't just show an
empty XML walk (which could theoretically be a depth-serialisation quirk,
see the "traps" list in `NATIVE-PLUGIN-findings.md`), it shows **zero
registered properties, full stop**. There is nothing to be empty *of*. This
was checked against a known-populated object at the same depth
(`rpg/Calendar?depth=1` renders `GameplayTime`/`GameTime` attributes) to rule
out an API-wide glitch — the API's depth semantics work normally; the
manager genuinely has no reflected state.

This holds identically before, during, and after real AI-vs-AI combat
directly adjacent to the player. **The manager is not a roster, not a
combatant list, not a battle-state object.** It is a bare method-dispatch
facade with a single debug method and no other purpose visible to
reflection.

## 0.3 — `DebugTriggerEvent` re-tested live, in a real skirmish

**Still does nothing. This time the negative is much stronger than the
original.**

The original finding tested this against `AttackersCount` and
`IsSoulCharged`, which were already 0 and stayed 0 — a weak test, since
"stayed 0" and "the call did nothing" are hard to tell apart. This session had
a genuinely dynamic field to test against instead (see 0.5): `CombatSoul`'s
`SkirmishStatistics`, which **does** move during real fighting.

Method signature, confirmed via `?info` (the docs' guessed casing was
wrong — it's `soulName`/`eventName`, not `SoulName`/`EventName`):

```
DebugTriggerEvent( string const& soulName, string const& eventName )
```

**Control, to rule out API noise:** sampled one actively-engaged combatant's
`CombatSoul` 5 times, ~800 ms apart, with **no** call in between. Every field
was bit-identical across all 5 samples — the API itself introduces no jitter.

**Test:** picked a soul confirmed stable at that exact moment (`Enemies=0`,
`HistoryFriends=21`, `HistoryEnemies=15`, unmoving), fired
`DebugTriggerEvent(soulName, "HitTarget")`, then sampled 5 more times over the
next 2.5 s.

```
baseline:        Enemies=0 HumanEnemies=0 HistoryFriends=21 HistoryEnemies=15 AttackersCount=0
DebugTriggerEvent(soulName, "HitTarget") -> HTTP 200, void
+0.5s / +1.0s / +1.5s / +2.0s / +2.5s:  identical to baseline, every field, every sample
```

Meanwhile the same field **did** move 13 → 15 for this exact soul between the
control run and this run, a few seconds of real combat apart — proof the
field is live and sensitive, and proof the trigger call specifically produced
zero effect against a field that demonstrably responds to real events.
Repeated with `"Attack"` and `"SoulAdded"` against a different, actively
fluctuating soul with the same result: no attributable change distinguishable
from the ambient combat noise already present.

**Reading:** `DebugTriggerEvent` is not the seam. Whatever populates
`SkirmishStatistics` does not listen to it, at least not for these event
names. This closes the "retry it live" question from the original finding —
the earlier negative was correct, not merely untested.

## 0.4 — Does real AI-vs-AI combat create combat history?

**Yes — but not proven via the same method the original finding used, and
that distinction matters.**

`CombatSoul::HasCombatHistoryWithSoul(I_Soul* Soul, float MaxTime)` is a real,
reflected method (confirmed via `?info`) — but it takes an `I_Soul*`
parameter, the exact same transport wall that blocked `TakeDamage`'s
`Attacker` parameter in the original finding ("Failed to convert parameter...
to type `I_Soul*`"). **It could not be invoked over this HTTP transport in
this session either**, for the identical reason. This is not a new
limitation; it's the same one, now confirmed to apply here too.

What *was* readable, and answers the same underlying question by a different
route: `CombatSoul::SkirmishStatistics` (a `ReadOnly` reflected property,
confirmed via `?info`) carries `Friends`, `Enemies`, `HumanFriends`,
`HumanEnemies`, **`HistoryFriends`, `HistoryEnemies`**, and `Predominance`.
The `History*` fields are, functionally, exactly the combat-history tally
`HasCombatHistoryWithSoul` would report on — a per-soul, persistent-feeling
count of past friendly/hostile encounters, not the current-instant
`Friends`/`Enemies` snapshot.

Observed directly, live:

| Soul | Role | `HistoryFriends` | `HistoryEnemies` | Note |
|---|---|---|---|---|
| `frontWallMeleeMan_1` | attacker | 11 → 18 → 21 | 7 → 12 → 15 | rose across three samples taken minutes apart, purely from real fighting nearby |
| `defenders_sideWallSubstitute_2` | defender | 24 → 25 | 57 | inverse pattern to attackers, consistent with counting the opposing side |
| `tkop_ptacek` (named NPC, present at the siege) | defender-aligned | 24 | 57 | same shape as other defenders |

**These numbers moved under real combat and never moved under a synthetic
`DebugTriggerEvent` call (0.3).** That is the actual finding here: real
AI-vs-AI fighting populates a combat-history-shaped counter that a synthetic
stimulus does not touch — consistent with the original finding's conclusion
about `TakeDamage`'s `Attacker` parameter creating no history, just now
confirmed from the other side (real combat does create *something*
history-shaped; synthetic triggers still don't).

**What this is not:** proof that `HasCombatHistoryWithSoul(player, ...)`
would return true after real combat with the player specifically. That
method remains uninvokable over HTTP. The evidence here is the closest
available substitute, not the same measurement.

## 0.5 — Is there a registration/roster construct, and is it writable?

**Found, and it is a clean, safe negative on writability — which is good
news, not a dead end.**

`wh::rpgmodule::CombatSoul` (a component every `Soul` has, confirmed present
on real NPCs, the player, and the siege combatants alike) carries:

```
Property  IsSoulCharged      bool                                  ReadOnly
Property  AttackersCount     uint64                                ReadOnly
Property  SkirmishStatistics shared_ptr<S_SkirmishStatistics>      ReadOnly
Property  Target             I_Soul*                               ReadOnly
Property  IsUnarmed          bool                                  ReadOnly
Property  HasMeleeWeapon     bool                                  ReadOnly
Property  HasMissileWeapon   bool                                  ReadOnly
```

**Every single property on `CombatSoul` is `ReadOnly="1"`**, confirmed via
`?info` (not inferred from a failed write attempt — nothing was written).
`AttackersCount` moved from 0 to 1–5 for soldiers actively under attack in
real time, correlating with visible combat, and returned to 0 once the fight
moved on. `Target` (the current combat target, `I_Soul*`) never rendered any
value at any depth — the same pointer-serialisation wall as `TakeDamage`'s
`Attacker`, not a new problem.

**This is the roster the WO hypothesized — it exists, it is per-soul rather
than centralised on the manager, and it is entirely read-only.** There is no
`set_property_value` path onto it, so **there is no way to repeat the
`SetParent` mistake here** — that crash came from an ownership-transfer write
onto a `shared_ptr`-by-value parameter on a *method*; nothing here exposes a
settable property or a callable mutator over this data at all. Structurally
this is closer to `AttackersCount` (a live counter you can only read) than to
`FactionNode.Parent` (a live pointer you could, dangerously, overwrite).
**Nothing in this WO touched, or came close to touching, the faction-tree
write path.**

### Where the actual hostility comes from — and it's the already-known mechanism

Checked `FactionNode.Parent` (not `FactionNode` itself — see the correction
already on record in `NATIVE-PLUGIN-findings.md`: the node's own `Name` is
always the soul's own name, membership lives in `Parent`) for an attacker, a
defender, and a real hand-placed NPC (`tkop_ptacek`) present at the same
scene:

| Soul | `FactionNode.Parent.Name` | Members |
|---|---|---|
| `frontWallMeleeMan_1` (attacker) | `kutnohorsko_enemies_zoufalaObranaZaBohutuEnemyArmy` | 124 |
| `frontWallShooter_1` (defender) | `kutnohorsko_settlements_suchdol_soldiers_zoufalaObranaZaBohutuFriendly` | 42 |
| `tkop_ptacek` | `players_friends_ptacek` | 2 |

**This is the same general faction-tree mechanism already documented**, not
a separate or novel siege-only system. The two siege factions are
quest-authored (named after the quest itself,
`zoufalaObranaZaBohutu*Army`/`*Friendly`) and clearly built specifically for
this battle — but the *mechanism* connecting a soul to a faction and a
faction to a hostility relationship is the exact same `FactionNode.Parent` →
`Faction` chain already proven and already off-limits to write
(`C_FactionBase::SetParent`, the call that crashed the game once). Nothing
here reduces or changes that risk; nothing here is a new way around it
either.

---

## The two questions the WO asked to keep separate

**Does anything here work for the siege's own canned battle?** Yes, in the
sense that the siege runs on real, observable, internally-consistent
mechanics: authored hostile/friendly factions using the standard faction
tree, and a genuine live per-soul combat-engagement tracker
(`SkirmishStatistics`/`AttackersCount`) that responds to real fighting. This
is the first time either of those has been directly observed *during* actual
AI-vs-AI combat rather than inferred or tested synthetically.

**Does this generalise to open-world NPCs and a ghost?** **No new lever for
that was found.** Reasoning:

1. The specific factions driving this battle are quest-authored and
   siege-specific — not reusable as-is for an arbitrary open-world encounter.
2. The *general* mechanism they ride on (`FactionNode.Parent` → `Faction` →
   `GetRelation`) is the same one already known from the open world, already
   proven to have exactly one write path (`SetParent`), and that path is
   already known to be dangerous. This WO does not make it safer or offer an
   alternative.
3. `SkirmishStatistics` and `AttackersCount` are genuinely general-purpose —
   present on every soul, not siege-specific scaffolding — but they are
   **entirely read-only telemetry**. They tell you a fight is happening; they
   cannot be used to *start* one. There is no reflected way to add a soul to
   this tracking, mark it as an active combatant, or force `AttackersCount`
   upward.
4. `DebugTriggerEvent`, the one method that looked like it might inject a
   stimulus, is now confirmed dead under the exact live conditions where it
   had the best chance of working.

**So: this closes the specific untested condition from the original finding
(a clean, stronger negative on `DebugTriggerEvent`), and adds one genuinely
new, real data point (`SkirmishStatistics`/`AttackersCount` as a read-only
live combat tracker, and the confirmation that real combat — unlike
synthetic damage — does populate a history-shaped counter) — but it does not
reopen the general aggro-injection question.** The consequence recorded in
`PROJECT-STATE.md` §4 ("replicated damage hurts NPCs but does not make them
fight back") still stands.

---

---

## Addendum, same session: the `SetParent` ownership bug is fixed and verified live

The user explicitly authorized revisiting the faction-attachment mechanism
after reading the above — specifically, fixing the ownership bug rather than
leaving it permanently off-limits, since the original crash was a diagnosed,
fixable calling-convention mistake, not proof the mechanism itself is unsafe.
This section documents that follow-up work, done live in the same session,
against a fresh save (a town, not the siege).

### Root cause, confirmed by disassembly, not guessed

Ghidra-decompiled `C_FactionBase::SetParent` and its two call targets in
`RPGModule.dll` (`native/ghidra_scripts/DumpFactionSharedPtr.java`,
`DumpSharedPtrHelpers.java` — new, this session). `SetParent`'s body:

```
assign(&this->parent_, param_2);        // copy-assign: increments param_2's
                                         // target, releases this->parent_'s
                                         // previous value
if (param_2.rep != null) release(param_2);   // destroys its OWN by-value
                                              // parameter
```

That second line is the whole bug: `SetParent` unconditionally destroys
whatever `shared_ptr` it is handed, exactly as the x64 ABI requires for a
by-value class parameter. The original call passed the reflected `Variant`'s
own storage directly, so `SetParent`'s "destroy the parameter" step decremented
the *same* reference `call_variant_dtor` decremented again afterward — two
decrements for one increment, which is exactly the over-release that emptied
`animal_wild_enemy_trosecko`'s member list and crashed the game.

### The fix

Not a hand-rolled refcount increment against a guessed `_Ref_count_base`
offset — that would repeat the same class of mistake with different numbers.
Instead: call `get_property_value` on `Parent` a **second time**. RTTR must
copy-construct a `shared_ptr` into a variant's own storage to satisfy "a
variant owns its value" (this project has done exactly that read hundreds of
times this session alone, on `SkirmishStatistics`, `FactionNode`, etc., with
no corruption), so a second independent read is the proven-safe way to obtain
a second, independently-owned copy. Destroy the first copy normally; hand the
second to `SetParent` and do **not** destroy it — `SetParent`'s own body
already does. Applied to both the donor path (`native/KCDMP/rttr_abi.cpp`,
`probe_faction()`) and, for consistency, the `GetFaction`-by-name path.

### Live test, this session

Test subject: `wo15test`, a fully disposable entity spawned via
`System.SpawnEntity({class="NPC", ...})` (the mod's own `KCD2MP_SpawnGhost`
wasn't available — no mod pak loaded this session, pure Modding Tools). It
registered as a real `Soul` with a working `CombatSoul` and an orphan
`FactionNode` — no need to touch a real NPC or commit an in-game crime.

- **Tried first, safest option:** `GetFaction("animal")` by name, so no donor
  NPC would be needed at all. Faulted exactly as the original investigation's
  attempt did (`"the string argument shape is wrong"`) — **SEH-caught,
  harmless, game unaffected.** This confirms the `GetFaction` string-argument
  problem is real, separate from the ownership bug, and still unfixed. Not
  pursued further tonight.
- **Fell back to a real donor**, found without attacking anyone:
  `FactionManager::GetRelation("animal_wild", "player")` (a name-based method,
  crosses the HTTP boundary fine — both arguments are plain strings, no
  ownership transfer) returned `type="enemy"`, and a live, loaded wild hare
  (`SpawnedAnimal_Hare_A8873FA2_0`) was confirmed a member.
- **The fixed `SetParent` call ran clean.** `kcdmp-native.log`:
  `FACTION: SetParent returned` — no fault, no SEH catch needed.
- **Verified over an extended window, not just immediately** — the specific
  discipline the original incident's write-up demanded, since that incident's
  immediate read-back also looked correct:

  | Check | Immediately after | +60 s | +4 min |
  |---|---|---|---|
  | ghost `FactionNode/Parent/Name` | `animal_wild` | `animal_wild` | `animal_wild` |
  | donor's own `FactionNode/Parent/Name` | `animal_wild` (unchanged) | `animal_wild` | `animal_wild` |
  | `animal_wild` `NumMembers` | 66 | 66 | 66 |
  | debug API / game process | healthy | healthy | healthy |

  No reversion, no shrinkage, no crash. The donor's own membership — the
  thing that got silently destroyed last time — held throughout.

**This is a genuine fix, verified live, to the specific bug that made
`SetParent` off-limits.** It is not a new aggro mechanism by itself — see
below.

### What this does and does not mean for aggro

Checked immediately after confirming the faction attach was stable:
`wo15test`'s `CombatSoul/AttackersCount` stayed `0`, and the human confirmed
directly — nothing in town reacted to it (no turning, no drawn weapons, no
approach).

**This is expected, not a new negative result.** The original finding listed
three ingredients for option 1 to work: a real soul (yes), a hostile faction
(yes, now, for the first time), and *a functioning perception/behavior tree*.
`wo15test` logged `"RPG NOT GENERATED VIA SCRIPT"` at spawn — a raw
`System.SpawnEntity` call, not the mod's own ghost spawner, and very likely
missing the AI setup a proper ghost has. This session fixed and proved the
**third** ingredient (faction attachment no longer crashes); it did not
re-test the **second** (a brained ghost) together with the fix. Those two
have never been combined and tested together in one live session.

**Follow-up, clearly scoped, not started tonight:** spawn a ghost *with* a
behaviour tree (`esModularBehaviorTree` non-empty, or the mod's own
`KCD2MP_SpawnGhost` with that flag unset, accepting the `ForceMount` trade-off
already on record), attach it to a hostile faction with this now-fixed
`SetParent` call, and check whether a nearby NPC actually reacts. That is the
test that would finally answer whether option 1 delivers real aggro — this
session only removed the one confirmed blocker on the faction half of it.

### Not touched

- The `GetFaction` string-argument bug — real, confirmed still present,
  deliberately not investigated further this session.
- Anything about *why* a real siege battle's hostility works (the earlier
  part of this document) — unrelated to this fix, which was tested in a town
  against a disposable spawn, not the siege.
- No code changes to the mod's actual aggro/combat wiring — this is still
  native-plugin research code (`rttr_abi.cpp`), gated behind an opt-in
  `kcdmp-faction.txt` file, not called from anywhere the mod's normal runtime
  path reaches.

## What was not attempted, on purpose

- **No write was made to `SkirmishStatistics`, `FactionNode.Parent`, or
  anything else.** Every property discovered this session was confirmed
  `ReadOnly` before being ruled out as a lever, not after a failed or risky
  write attempt.
- **No code changes to the mod's combat/aggro/faction handling.** Pure
  investigation, per the WO's own scope.
- **`HasCombatHistoryWithSoul` was not invoked** — blocked by the same
  `I_Soul*` HTTP transport limitation as `TakeDamage`'s `Attacker` parameter,
  not attempted-and-failed differently. A native in-process call (the same
  escalation path already recommended for `TakeDamage` attribution in
  `NATIVE-PLUGIN-findings.md` "Prove in-process attribution") would be needed
  to actually invoke it — out of scope for a reflection-only session.
