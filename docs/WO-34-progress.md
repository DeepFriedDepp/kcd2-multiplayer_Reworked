# WO-34 progress — first two-player bug report

## 2026-08-15

**Trigger:** the first bug report from two real humans on two separate machines
(Discord, `.littytitty`, v0.11.5). Four symptoms: players hostile to each other,
one arrested and pilloried, that player relabelled "Ruffian" and attacked by
ambient NPCs after a reload, and a dead ghost's body sliding around tracking the
live player.

### What was done

**Systems audit first, per the WO.** Asked what a soul-backed ghost plugs into
that nobody had checked, rather than chasing the four symptoms. Read from the
shipped `Tables.pak` / `English_xml.pak`: the crime table (a ghost is a full
crime victim — `pickpocket` 550/2 days, `assault` 1500/5, `murder` 20000/7,
`corpseViolation` 2000/5), the reputation tables (crime penalties route to
*faction + nearbyfactions + superfaction*, so hurting a ghost damages your
standing with a **real settlement**), `soul_vip_class` (all 48 roster souls
unprotected), `soul_crime_role` (bandit souls are flagged *renegade*), and the
1,028-node faction tree.

**The audit found the cause.** `KCD2MP.faceRoster.male` shipped **five
`trosecko_enemies_bandits_*` souls** out of 24 — public enemies, ~1 player in
10. Harmless until WO-22 made `SharedSoulGuid` actually bind; live since.

**Reproduced on the shipped build before diagnosing.** Ghosts spawned through
the real, unmodified `KCD2MP_SpawnGhost` and read back over the RTTR reflection
API:

- `tbuk_man_5` → `FactionNode/UIName` = `soul_ui_name_ruffian` → **"Ruffian"**,
  the reporter's screenshot exactly. Kopanina and Zdar give "Bandit"; only
  Bukovina gives "Ruffian", so only the live read separates them — a paper chain
  through `social_class.xml` looked right and was the wrong path.
- Two bandit-soul ghosts killed by ambient NPCs; a commoner control spawned at
  the same moment 8 m away untouched at 100 HP.
- `props.esFaction` reads back `Civilians` and changes nothing.
  `AI.GetFactionOf` does not exist in this build (`nil`) — why no prior session
  could check the mod's own faction override.
- Corpse-drag reproduced: a confirmed-dead ghost tracked the position stream
  **7 m**, one interp tick behind.

**Two fixes.**

1. The five bandit souls removed from the roster. Verified after the edit by
   walking the full faction tree: no remaining roster soul has `publicEnemy`
   anywhere in its ancestry (43 souls, 19 male + 24 female).
2. Issue D: new `mp_ghost_is_corpse` (owner-died **or** entity-died);
   `KCD2MP_InterpTick` skips the position write and animation when frozen and
   anchors the nameplate to the body's real position;
   `KCD2MP_ReconcileGhosts` recycles a locally-dead ghost so its owner does not
   stay permanently invisible.

**Gate D passed** on the installed build, with a positive control: a live ghost
still tracks position (5/5 samples), a dead one is byte-identical across 8
samples while the target moves 8 m, and the recycle round trip respawns a fresh
alive ghost at exactly the streamed position.

### Human decisions recorded

- **Roster fix:** remove the five, not replace them — accepting that the modulus
  change reshuffles *every* male player's face on this build.
- **Issue A** (player-vs-ghost crime): decide after the roster fix, on evidence
  from two real players.
- **Issue B** (arrest/pillory): the human's stated intent — *"if you reload a
  save/die, you are no longer a criminal, just like in the base game"* — already
  holds; the mod contains no crime code at all (checked). What the tester saw
  was not a criminal record surviving a reload, it was the ghost's identity
  being deterministically re-derived. A Ruffian reloads as a Ruffian.

### Not closed

The wider crime/reputation surface (§7 of the findings): every ghost, including
every corrected one, is a full crime victim whose mistreatment costs real money,
jail and real settlement standing. Also flagged: noble souls (crimes scale up)
and guard/militia souls (carry the `soldier` crime role) still in the roster,
consequences unmeasured; no attacker attribution (`GetAttackersCount` unbound);
and the fix has not been confirmed by two real players, which is how it was
found.

### Files touched

- `kdcmp/Data/Scripts/Startup/kdcmp.lua` — roster, `mp_ghost_is_corpse`,
  `KCD2MP_InterpTick` freeze, `KCD2MP_ReconcileGhosts` corpse recycling
- `kdcmp/Data/kdcmp.pak` — rebuilt and installed
- `tools/wo34-probe.ps1` (new) — one-shot Lua probe driver
- `docs/WO-34-findings.md` (new), `docs/WO-34-progress.md` (this file)

No change to `VERSION`, no installer build, per `docs/VERSIONING.md`. No
`dotnet/`, relay or native changes.
