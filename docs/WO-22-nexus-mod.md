# WO-22 §2 — the Nexus aggression mod, classified

Examined 2026-08-06. Source file supplied by the human, already downloaded:
`C:\Users\Jonasty\Downloads\AggresiveCombatAI-1014-2-1744976616.zip`
(1,186 bytes) and its extracted folder alongside it.

**Classification: (A) — pure parameter tuning on NPCs that already have real
brains.** It does not touch brain assignment, behaviour trees, souls, factions,
or anything AI-structural. Useful only as a data-format reference.

## File inventory

The whole mod, in full:

```
ZMagusAggresiveCombatAI/
  mod.manifest                                    282 B
  Data/ZMagusAggresiveCombatAI.pak                758 B
    Libs/Tables/rpg/rpg_param__ZMagusAggresiveCombatAI.xml   1,147 B
```

Three entries in the pak, two of which are directory records. One real file.

`mod.manifest` is minimal and mostly unfilled (`description`, `version`,
`created_on` all literally `Unknown`); `modid` is `zmagusaggresivecombatai`,
author `Magus`.

**Not compiled, not native, no Lua.** A single table patch, in the exact form
KM-A-12 documents: `rpg_param__<modid>.xml`, i.e. a table part whose part name
equals the modid, which the loader treats as a patch rather than an addition.

## What it changes

Ten `rpg_param` keys, all combat-pacing:

| key | mod value | vanilla `rpg_param.xml` |
|---|---|---|
| `CombatAutoAggressionDiffScale` | 100 | not present |
| `CombatAutoAttackDelayIncreasePerAttacker` | 0 | not present |
| `CombatAutoAttackDelayIncreasePerAttackerHorse` | 0 | not present |
| `CombatAutoAttackDelayIncreasePerAttackerMissile` | 0 | not present |
| `CombatAutoAttackDelaySigma` | 0 | not present |
| `CombatAutoMaxAttackDelay` | 0 | **2** |
| `CombatAutoNPCOpponentAtkDelayCoef` | 0 | not present |
| `CombatAutoScaleDefensivenessDelayRel` | 0 | not present |
| `CombatMovePlayerSecondaryAttackerHuntMultiplier` | 100 | not present |
| `CombatMovePlayerSecondaryAttackerSpeedMultiplier` | 100 | not present |

Diffed against the vanilla `Libs/Tables/rpg/rpg_param.xml` already extracted in
`scratch-wo22/vanilla/`. Only one key — `CombatAutoMaxAttackDelay`, 2 → 0 — has
a vanilla row to override. The other nine are absent from the vanilla table.

The effect is transparent from the names: every inter-attack delay driven to
zero (including the per-additional-attacker back-off that normally stops a
group from swinging at you all at once), attack-delay randomisation removed,
and secondary attackers told to close at full speed. NPCs that already fight
simply fight without pauses. It is a difficulty/pacing mod.

The nine absent keys are worth one caution: either the engine defines defaults
for them in code and the table row is purely an override (the likely reading,
given `KM-A-20 RPG Constants Params` documents many params that are engine-side
constants), or nine of the ten lines do nothing at all. This mod's own
effectiveness is not something this session tested, and it does not matter for
our purposes either way.

## Why it is category (A) and not (B)

Nothing in it references `brain_id`, `subbrain`, `esModularBehaviorTree`, any
`Scripts/AI/` tree file, `soul`, or `factionName`. It is one row-set in one RPG
parameter table. **It does not touch brain assignment at any level**, and it
offers nothing toward A1 or A2 — those are not pacing problems.

## What it is actually useful for

Exactly the "data-format reference" the framing anticipated, and one thing more:

- It is a **working, published example of the KM-A-12 table-patch convention**
  — `<table>__<modid>.xml` inside `Data/<modid>.pak`, at the real in-pak path
  `Libs/Tables/rpg/`. If this project ever ships a table patch, this is the
  minimal correct shape.
- Its pak is a ZIP with the single real file stored **`Defl:N` (deflated, 70%
  ratio)** — not stored/zero-compression. This is a shipped mod with real
  users. It is direct evidence against the "KCD2 paks must be zero-compression
  ZIPs" belief, at least for `Libs/Tables` XML. See `docs/WO-22-toolkit.md`,
  which finds the same thing independently in `kcd-pak-builder`.

## Licensing

Nothing was copied. Reuse was never in question — there is nothing here to
reuse but ten integers and a directory layout, and the layout is Warhorse's
documented convention rather than this author's invention.
