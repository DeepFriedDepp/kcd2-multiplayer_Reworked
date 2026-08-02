# WO-16 — brained ghost + hostile faction, combined

Investigated 2026-08-02 against KCD2 (Modding Tools build), a real playthrough
reloaded to `playline2\permanent002.whs` (the WO-15 checkpoint), with the
`kdcmp` mod deployed and loaded, and the human actively watching and reporting
what they saw on screen.

WO-15 fixed the `SetParent` ownership bug (ghosts can now join a hostile
faction without crashing the game) and separately confirmed a ghost *with* a
populated `esModularBehaviorTree` runs real perception. Those two things had
never been tested together, and the mod's own ghost spawner has always used
`esModularBehaviorTree=""` on the untested assumption that a populated tree
would fight `ForceMount`. This WO tests both assumptions directly, then
combines all three ingredients (real soul / hostile faction / working
behaviour tree) for the first time.

**Evidence discipline:** every claim below is either a live REST call against
`localhost:1403`, a line from the native plugin's own log
(`kcdmp-native.log`, next to the injected DLL — not `kcd.log`, which is a
different file the plugin never writes to), or a direct report from the human
watching the screen. Where a result could plausibly be a test-harness
artifact rather than a real effect, it was isolated and re-tested before being
trusted (see Phase 0.2).

---

## Phase 0.1 — what `esModularBehaviorTree` value is actually valid

**Not guessed. Probed the same way ghost clothing presets were originally
discovered: read the property off real, already-placed NPCs.**

A live NPC's `Properties` table isn't reflected over the debug REST API (that
surface only covers RTTR-registered C++ types), so this went through Lua:
`entity.Properties.esModularBehaviorTree`, read on several real nearby souls
via `ExecuteString` and logged back through `kcd.log`.

```
SpawnedAnimal_RoeDeerBuck_A5956213_1.mbt=IdleSeq
SpawnedAnimal_RoeDeerHind_8AB5D90A_6.mbt=IdleSeq
SpawnedAnimal_Hare_B30A5355_0.mbt=IdleSeq
tkop_ptacek.mbt=IdleSeq          (real placed NPC)
tsem_sedivka.mbt=IdleSeq         (Horse)
tvez_vorech.mbt=IdleSeq          (Dog)
```

`"IdleSeq"` came back identically across deer, a hare, a real NPC, a horse,
and a dog — a real, in-use, generic top-level tree name (almost certainly an
entry point that dispatches into archetype-specific sub-schedulers like
`npc_basic_scheduler`, seen elsewhere in `kcd.log`), not a per-species value.
`Properties.esArchetype` and `Properties.esFaction` both came back `nil` on
every one of these real NPCs — consistent with `ARCHITECTURE-shared-world.md`'s
existing note that `esFaction` reads `nil` off real NPCs from `Properties`.
`esModularBehaviorTree` is the one field that reads real data.

**Used `"IdleSeq"` for every test below.**

### A transport fact worth keeping

`ExecuteString`'s URL-encoded command has a length ceiling somewhere between
**1716 and 2190 encoded characters** — a 55-line Lua function definition sent
in one call truncated mid-function (`'end' expected ... near '<eof>'` in
`kcd.log`), while the same logic trimmed to ~1200 raw characters (1716
encoded) went through cleanly. Not documented anywhere before this session.
Future sessions sending nontrivial function bodies over this transport should
budget for it or split the definition across multiple calls.

---

## Phase 0.2 — does a populated tree break basic ghost behaviour on its own?

**No. Clean baseline, once a test-harness bug was isolated and corrected.**

Testing this without touching `KCD2MP_SpawnGhost` (per the WO's own
gating requirement) meant defining a runtime-only clone,
`KCD2MP_SpawnGhostWO16(id, x, y, z, rotZ, mbt)`, live via `ExecuteString` —
identical to `KCD2MP_SpawnGhost`'s spawn logic (same
`XGenAIModule.SpawnEntity` call, same armor/weapon preset, same `istate`
table, same `KCD2MP.ghosts[id]` registration so the mod's real interp/animation
loop drives it) with `esModularBehaviorTree` parameterized instead of hardcoded
`""`. **Never written to `kdcmp.lua` on disk** — defined only in the live Lua
VM for this session, gone on next restart.

Spawned `kcd2mp_wo16brain` with `mbt="IdleSeq"`:

- Registered as a real soul (`SoulsByName` entry, correct position, real
  `BaseClothingPresetName="kcd2mp_whitered_armor"`).
- **Appears repeatedly as a `PerceptorName` in
  `XGenAIModule.PerceptionHistory.GetRecords()`** — confirmed running
  perception, which the empty-tree ghost never does (the exact test
  `NATIVE-PLUGIN-findings.md` used to establish "cannot see").
- Human confirmed visually: "Looks/stands like a normal ghost."

Drove it through a synthetic 12 m walk-out-and-back via the mod's real
`KCD2MP_UpdateGhost(id, x, y, z, rotZ, isRiding)` — the same entry point a
real peer's position packets hit — to check whether it still responds to the
mod's own sync path. First pass: human reported it "running... but moved
sideways" while animating forward. **This was chased down, not accepted at
face value**: the test script held `rotZ=0` constant while sweeping only the
`x` coordinate. `SetWorldAngles` sets facing directly from whatever `rotZ` is
passed, independent of the actual direction implied by the position updates —
so a fixed wrong heading during pure-`x` movement is exactly a facing/travel
mismatch, a test-rig bug, not a tree-related regression. Re-tested holding
`rotZ=0` while sweeping `y` instead: "looks mostly like normal forward
running" (human noted a minor stutter between run-cycle steps, attributed to
the test's coarse 250 ms update interval, not the tree — and explicitly said
this level of polish wasn't the point of the test).

**Conclusion: a populated `esModularBehaviorTree` does not break spawn,
appearance, or the mod's own position-sync-driven movement/animation.** The
one anomaly observed traced cleanly to the test harness, not the ghost.

---

## Phase 0.3 — does a populated tree fight `ForceMount`?

**No. Identical to the empty-tree baseline in every measurable way.**

Mounted the brained ghost on a horse via the mod's real, unmodified path
(`KCD2MP_SpawnHorse` → `KCD2MP_MountNPCOnHorse`, which calls
`human:ForceMount`):

```
HorseSpawn OK id=wo16brain
MountNPCOnHorse id=wo16brain hasHuman=true
ForceMount ok=true id=wo16brain
IsMounted=true id=wo16brain
NATIVE MOUNT SUCCESS id=wo16brain
OptionC signals id=wo16brain s1=true s2=false s3=true s4=true
```

No `"No valid scheduler behavior while occupying stance"` error anywhere in
the log — the specific failure the empty-tree design choice was meant to
avoid, and it simply did not occur.

**Control, same session:** spawned a second ghost, `wo16control`, through the
mod's real, completely unmodified `KCD2MP_SpawnGhost` (empty tree, the
default every player gets) and the same horse path. Identical sequence,
identical `s1=true s2=false s3=true s4=true` signal pattern. `s2=false`
(`entity:EnableAI(false)` failing inside its `pcall`) is therefore a
pre-existing quirk of that suppression code, present regardless of tree
state — not something this WO introduced or needs to fix.

Human's visual check: both ghosts "standing on top of the horse, not sitting
like they are riding" — confirmed, on direct follow-up, that **both** the
brained and control ghost show this identically. This is a pre-existing
rendering artifact of `ForceMount` used bare (without the mod's separate
riding-animation state machine, which this ad hoc test-spawn function didn't
replicate), unrelated to the behaviour tree.

**Conclusion: `ForceMount` works identically with a populated tree as without
one.** The scheduler-vs-mount conflict the empty-tree design was defending
against did not materialize in this test, on either the brained ghost or the
control.

---

## Phase 1 — the combined test: brained + hostile-faction ghost, does anything react?

**Yes. A real, ordinary nearby NPC spontaneously attacked the ghost.** This is
the first time all three ingredients from `NATIVE-PLUGIN-findings.md`'s
original theory have been present on the same soul at the same time.

### Finding the faction pairing — real, not guessed

Read the target test area's actual civilian NPCs' faction via
`FactionNode/Parent` (WO-15's proven method): `ttkc_man_28` →
`trosecko_settlements_troskovice_commonFolk_peasants_parcel04`. Swept
`FactionManager.GetRelation` against several candidate hostile factions;
`trosecko_injustice_cuman` and `trosecko_enemies` both resolve to a real
`enemy` relation (reputation `-1`) against `trosecko_settlements`, the parent
of this NPC's own faction — confirming the target NPCs are reachable by a
faction-level hostility, not merely "hostile to player" (which
`animal_wild`, WO-15's donor, is *not* — checked and confirmed `neutral`
against this same civilian faction, so it would have been the wrong choice
here).

**Donor:** `trosecko_injustice_cuman` itself has `NumMembers="0"` — no
currently loaded member to copy from, matching WO-15's exact prior finding
that hostile factions are typically un-donatable. Found a populated
subfaction instead by walking `trosecko_enemies`'s children
(`trosecko_enemies_bandits`, 102 members; `trosecko_enemies_bandits_
prepadeniAmbushers_group1`, 10 members) and confirmed the leaf subfaction
inherits the same `enemy`/`-1` relation against `trosecko_settlements`.
`prepadeni_bandit_1` (a soul left over from this playthrough's earlier
ambush sequence — its entity has despawned, `Position="0,0,0"`, but its
*soul* persists in `SoulList` with a live, real `FactionNode.Parent`, per the
already-known "destroying the entity does not remove its soul" fact) is a
confirmed member: `Guid=4fc4eb57-9f12-4b65-8acc-ed9fb3f8730a`.

### Attaching the ghost

Built the native plugin fresh (`native/Build-Native.ps1`), staged a fresh copy
at `native/build/KCDMP_wo16_a/KCDMP.dll` per the project's fresh-injection
convention, wrote `kcdmp-faction.txt` (ghost GUID
`4894a5d4-2d02-2ea9-91e8-0b3da7b4093b`, donor GUID as above), injected into
the running game. `kcdmp-native.log`:

```
FACTION: donor soul = "4fc4eb57-9f12-4b65-8acc-ed9fb3f8730a"
FACTION: ghost Parent before = 0000000000000000 (expected null/orphan)
FACTION: calling SetParent(...) with an independently-owned copy
FACTION: SetParent returned -- parent_v2 is now SetParent's to have destroyed
FACTION: ghost Parent immediately after = 0000020EBD827200 (expected match)
```

No fault, no crash. Verified over HTTP, not just the immediate read-back:
`kcd2mp_wo16brain`'s `FactionNode/Parent/Name` read
`trosecko_enemies_bandits_prepadeniAmbushers_group1` both immediately and
after the fight below had played out. The donor's own membership held
throughout — checked twice, before and after — its `FactionNode/Parent`
still resolves cleanly to the same faction with no fault. (The faction's own
`NumMembers` attribute read `10` → `10` → `9` across the session's queries
while the actual `<Souls>` list consistently listed 10 real entries the whole
time, including after the ghost was later removed — read as a stale/lazy
counter, not data loss; the container itself never lost an entry.)

### The test spot

Player relocated (per the WO's safety requirement) away from the crowded
Kutná Hora-area settlement to an isolated clearing near a small hut with a
lone woodcutter, roughly 1400 m from the session's starting point, world
position **~2524, 2049, 118**. Three real NPCs within 60 m at test time:
`ttkc_man_28`, `ttkc_marketa`, `ttkc_dusko` (the woodcutter), plus a cattle
bull.

### Before the attach: perception asymmetry, worth recording on its own

Checked `PerceptionHistory.GetRecords()` while the ghost was still orphaned/
pre-faction-attach: `kcd2mp_wo16brain` appeared repeatedly as a
`PerceptorName` (it runs perception, per Phase 0.2), but **never once** as a
`PerceptibleName` inside another soul's `PerceptibleRecord` list, across a
full log capture, while the real nearby NPCs' perception jobs were
demonstrably active (they show real `PerceptibleRecord` entries for each
other). The ghost can perceive; nothing was registering it as something *to
be* perceived. This is the other half of the question
`NATIVE-PLUGIN-findings.md` left open ("whether it can be seen remains
unmeasured"), now measured: at least in this window, it could not.

### The reaction

Human, watching directly, first reported no visible reaction after the
attach ("The woodcutter is unphased" — screenshot confirmed the ghost
standing calmly a few meters from the woodcutter, who continued chopping
wood). Telemetry at that moment: `AttackersCount=0` on both, empty
`SkirmishStatistics` on all three nearby NPCs and the ghost.

**On a later poll, telemetry changed:** `AttackersCount` moved `0 → 1` on
both the ghost and `ttkc_dusko` at the same moment. Asked the human to look
again immediately — **"The woodcutter is now attacking the Playerwo16brain
Ghost NPC."** Telemetry at that point:

```
ghost   CombatSoul: AttackersCount=1  SkirmishStatistics Enemies=1 HumanEnemies=1 HistoryEnemies=1
dusko   CombatSoul: AttackersCount=0  SkirmishStatistics HistoryEnemies=1 Predominance=1.30
```

Let it play out. Human: **"He was attacking and landing hits, I saw blood
appear on the NPC."** The ghost never fought back (`IsUnarmed=true`,
`HasMeleeWeapon=false` throughout — the mod's `EquipWeaponPreset` is cosmetic
only, established already in WO-9; the ghost had no functional weapon to
retaliate with). Predominance swung decisively:
`ghost=-2.61, dusko=+2.61`. The ghost's soul state stayed `IsDead=false,
IsUnconscious=false` and its position never moved throughout.

**One more real observation, not the headline but genuine:** partway through
the fight the ghost's visual model disappeared — nametag stayed floating in
place, the woodcutter kept circling and swinging fists at the empty space
where it had stood. Telemetry through this: still `IsDead=false`, still
`AttackersCount=1`, still the same position. Whatever happened, it reads as a
rendering/animation-state anomaly on this specific kind of synthetically-
spawned combat target, not a death, unconsciousness, or despawn — the RPG
layer never stopped treating it as a live, present, actively-attacked soul.
Not investigated further this session (out of scope — the WO's deliverable
is whether aggro happens at all, not debugging every visual side effect of
it).

Removed the ghost afterward (`KCD2MP_RemoveGhost`) to end the fight cleanly.
Donor faction and game process both confirmed healthy after.

---

## Answering the gate, plainly

- **Did a populated behaviour tree break normal ghost behaviour on its own
  (Phase 0.2)?** No. Spawn, appearance, and the mod's own movement/animation
  sync all work identically to the empty-tree ghost. The one anomaly
  observed was traced to and confirmed as a test-harness bug (a bad `rotZ` in
  the synthetic driver), not a tree effect.
- **Did it break `ForceMount` (Phase 0.3)?** No. Mounted cleanly, no
  scheduler error, byte-for-byte identical signal pattern to a same-session
  empty-tree control ghost mounted the same way. The one visual quirk
  (standing rather than sitting on the horse) is pre-existing and present on
  both, unrelated to the tree.
- **Did anything actually react to the faction-hostile brained ghost (Phase
  1)? Yes.** An ordinary, un-scripted nearby NPC (a woodcutter) spontaneously
  turned on the ghost, attacked it, and landed real hits — confirmed both
  visually by the human and via `CombatSoul`/`SkirmishStatistics` telemetry
  moving from a genuine zero baseline. This is a real result: the three-
  ingredient theory (real soul / hostile faction / working behaviour tree)
  delivers real aggro when all three are actually present together, which
  had never been tested before this session.

**This is a real result worth celebrating.** Per the WO's own scope, this
session does not decide what happens next — whether/how to wire any of this
into the mod's default ghost path, how to handle the ghost's inability to
fight back, or the mid-fight rendering anomaly, are all explicitly deferred
to a later, separate decision.

Nothing here changed `KCD2MP_SpawnGhost`'s default parameters or any code
path the mod's normal runtime reaches. The test-spawn function was defined
live via the console for this session only and was never written to
`kdcmp.lua`. `probe_faction()` remains gated behind `kcdmp-faction.txt`,
exactly as WO-15 left it.
