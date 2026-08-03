# WO-16 progress — brained ghost + hostile faction, combined test

2026-08-02. Read `docs/WO-16-findings.md` for the evidence and conclusions;
this is the session log and repeatability notes.

## Save backup

Before any testing, backed up the active save:
`Saved Games\kingdomcome2\saves\playline2\{permanent001,permanent002}.whs`
copied to `Saved Games\kingdomcome2\saves\playline2_wo16backup\`. The session
loaded `permanent002.whs` (7:56 AM checkpoint, the same one WO-15 used).

## What happened, in order

1. Read the four required docs (`WO-15-findings.md` incl. addendum,
   `WO-15-progress.md`, `kdcmp.lua`'s `KCD2MP_SpawnGhost`/`ForceMount`
   context, `NATIVE-PLUGIN-findings.md`'s three-ingredient theory).
2. Found the game already running via Modding Tools but with **no mod
   loaded** (`kcd.log` had no `MOD INIT` line) and unsaved since 7:56 AM.
   Backed up the save, then rebuilt+redeployed `kdcmp.pak`
   (`tools\Build-And-Install-Mod.ps1`, game closed first as it requires),
   human relaunched via Modding Tools and reloaded `permanent002.whs`.
3. **Phase 0.1.** Probed `esModularBehaviorTree` on real nearby NPCs/animals
   via Lua (`entity.Properties.esModularBehaviorTree`) — found `"IdleSeq"`
   used identically across deer, a hare, a horse, a dog, and a real placed
   NPC. Used this value for every test. Also discovered a real transport
   limit on `ExecuteString` (encoded length ceiling between 1716–2190 chars)
   the hard way, via a truncated function definition.
4. **Phase 0.2/0.3.** Defined `KCD2MP_SpawnGhostWO16` live via the console
   (never written to `kdcmp.lua`) — a parameterized clone of
   `KCD2MP_SpawnGhost` with `esModularBehaviorTree` settable. Spawned a
   brained ghost, confirmed clean baseline behaviour (spawn/visual/movement),
   chased down and resolved a sideways-movement report as a test-harness
   `rotZ` bug (not a tree effect), then confirmed `ForceMount` works
   identically to a same-session empty-tree control ghost (`wo16control`,
   spawned through the real unmodified `KCD2MP_SpawnGhost`).
5. **Phase 1.** Found a real hostile-faction pairing (`trosecko_enemies_
   bandits_prepadeniAmbushers_group1`, confirmed `enemy`/`-1` against
   `trosecko_settlements`, the parent of the test area's real civilian
   faction) with a real donor soul (`prepadeni_bandit_1`, a despawned-but-
   still-in-`SoulList` leftover from this playthrough's earlier ambush
   sequence). Built the native plugin fresh, staged it at
   `native/build/KCDMP_wo16_a/`, wrote `kcdmp-faction.txt`, injected into the
   running game (human confirmed before injecting). `probe_faction()` ran
   clean. Human relocated to an isolated spot (a small hut clearing, ~1400 m
   from the start point, three real NPCs nearby) per the WO's safety
   requirement before this step.
6. Watched for a reaction. Human first reported none after ~30s+ of
   watching. A later telemetry poll showed `AttackersCount` moving 0→1 on
   both the ghost and one nearby NPC (`ttkc_dusko`, a woodcutter) at the same
   moment; asked the human to look immediately — confirmed a real, ongoing
   attack, landing hits, visible blood. Let it play out, captured telemetry
   throughout, then removed the ghost to end it cleanly.
7. Verified donor faction and game process integrity after (both healthy;
   see findings doc for the `NumMembers` counter quirk that turned out to be
   benign, not corruption).

## Faction pairing and location used, for repeatability

- **Ghost faction (target):** `trosecko_enemies_bandits_
  prepadeniAmbushers_group1` — confirmed `enemy`/reputation `-1` against
  `trosecko_settlements`.
- **Donor soul:** `prepadeni_bandit_1`, GUID
  `4fc4eb57-9f12-4b65-8acc-ed9fb3f8730a`. Its entity has despawned
  (`Position="0,0,0"`) but its soul persists in `SoulList` with a live,
  queryable `FactionNode.Parent` — didn't need to be physically present or
  nearby to serve as a donor.
- **Test location:** world position **~2524, 2049, 118** — a small hut
  clearing with a lone woodcutter (`ttkc_dusko`) and two other civilian NPCs
  (`ttkc_man_28`, `ttkc_marketa`) nearby, reached by walking roughly 1400 m
  from the `permanent002.whs` start point, away from the main settlement.
- **Ghost `esModularBehaviorTree` value used:** `"IdleSeq"`.

## Build note

`native/Build-Native.ps1` was re-run this session (no source changes —
`probe_faction()` is reused exactly as WO-15 left it, per the WO's own
instruction not to re-fix it). Output copied to a fresh path,
`native/build/KCDMP_wo16_a/KCDMP.dll`, before injecting — re-triggering
`probe_faction()` against an already-injected DLL needs a fresh `LoadLibrary`
path, same convention as `KCDMP_wo15_donor` etc. `kcdmp-faction.txt` lives
next to that copy, in the gitignored `native/build/` tree, written by hand for
this one test — not committed as reusable tooling, same as WO-15.

## Not committed as reusable tooling

- `KCD2MP_SpawnGhostWO16`, the parameterized test-spawn function — defined
  live via `ExecuteString` for this session only, gone on next game restart,
  never written to `kdcmp.lua`.
- The ad hoc PowerShell probe scripts used throughout (behaviour-tree probe,
  synthetic movement driver, hostile-faction sweep, perception check) —
  one-off, following the existing pattern in `tools/KcdApi.ps1` and
  `tools/Probe-AI-Behaviour.ps1`, not added to `tools/`.

## What was not attempted, on purpose

- No fix or further investigation of the mid-fight rendering anomaly (ghost
  model disappearing while still logically alive and under attack) — a real
  observation, explicitly out of scope to chase down this session.
- No change to `KCD2MP_SpawnGhost`'s default parameters, and no wiring of
  any of this into a path the mod's normal runtime reaches. Pure test, per
  the WO's own framing — how (or whether) to ship any of this is explicitly
  deferred to a later decision.
- `GetFaction`-by-name's `CryStringT` argument bug — still real, still
  unfixed, not touched (the donor-soul method was used instead, per the WO's
  explicit instruction).

## Follow-up a future session could pick up, if there's appetite

1. **What actually triggered the attack.** The ghost never appeared as a
   `PerceptibleRecord` target for any nearby NPC in the pre-attack
   observation window, yet the attack happened anyway — worth understanding
   whether it came through the perception pipeline eventually catching up,
   or some other mechanism (a periodic faction-hostility scan, proximity
   check, etc.). Not answered this session.
2. **The mid-fight disappearing-ghost anomaly.** Worth a focused look if this
   capability is ever pursued further — does it happen every time, is it
   related to the ghost being unarmed/unable to trigger its own hit-reaction
   animations, etc.
3. **The ghost's inability to fight back.** `EquipWeaponPreset` is cosmetic
   only (established in WO-9); the ghost had no functional weapon and never
   became `HasMeleeWeapon=true`. If real two-way combat were ever wanted,
   this is the next blocker, not the faction/perception mechanism tested
   here.

Per the WO's own scope, none of this is a decision this session makes —
just what's now known to be true, and what's still open.

---

**Update, 2026-08-02, later the same day:** items 2 and 3 above were picked
up in a follow-on session that closed both gaps, got the feature's real
shape confirmed by the human (changed from this WO's own proposal in
response to explicit feedback), and shipped it as real, permanent,
toggle-gated code — see `docs/WO-16-release-candidate.md` for the full gate.
Short version: (2) root-caused, not fixed, scoped as a known v1 limitation;
(3) investigated further (native `EquipmentManager.EquipItem` and
`human:DrawWeapon()`, both real but neither grants combat capability),
scoped as one-sided aggro for v1. Item 1 (what actually triggers a nearby
NPC's attack) remains genuinely unanswered.
