# WO-22 — Findings & Progress Report

**Date:** 2026-08-06
**Repo:** DeepFriedDepp/kcd2-multiplayer_Reworked
**Branch:** `wo-22-brain-lead` (5 commits, pushed)
**Scope:** investigation of three external sources; one fix applied, built, installed
**Version/release changes:** none

---

## Summary

WO-21 escalated the ghost-brain problem to native reverse-engineering as unreachable from
Lua. It was reachable the whole time — through a function this mod already calls, with the
arguments in the wrong shape. **A1 is fixed, shipped and installed. No native work, no DLL
injection.**

| Gate | Result |
|---|---|
| A1 — floored ghost recovers | **FIXED** — wakes in ≤54 s / ≤26 s over two cycles |
| A2 — ghost fights back | **PARTIAL** — ghosts act, flee, take injuries; none seen to land a blow |
| Regression: ForceMount | **NO REGRESSION** — mounts in every spawn shape |
| Regression: position sync | **AVOIDED** — only occurs with the scheduler proxy, which is not shipped |
| Open | 1 measurement gap, 1 new user-facing risk |

---

## 1. Root cause

A Warhorse *brain* is not an entity property. It is a column on a **soul row** —
`brain_id` in `Libs/Tables/rpg/soul__*.xml`, pointing at `npc_basic` for 5,417 souls.
An entity gets a brain by getting a soul, and it gets a soul from `SharedSoulGuid`.

Warhorse's shipped scriptbind docs give `XGenAIModule.SpawnEntity` a **flat** parameter
table — `Name`, `SharedSoulGuid`, `SoulArchetypeName`, `ClassName`, `Pos`, `Rot`,
`SchedulerProxyName`, `NoAI`, `PerceptorObjectAI`, `SoulPoolName`, `Difficulty`. There is
no `Properties` key in it at all.

This mod passed the soul GUID nested inside `Properties`, so the engine discarded it.
Every ghost ever spawned was soulless, and therefore brainless.

The entire functional change (commit `7f066da`, `kdcmp.lua`, `KCD2MP_SpawnGhost`):

    XGenAIModule.SpawnEntity{
        Name       = name,
        ClassName  = facePick.className,
        Pos        = {x, y, z},
    -   Properties = { esFaction = "Civilians", esModularBehaviorTree = mbt,
    -                  guidSharedSoulId = facePick.guid },
    +   SharedSoulGuid = facePick.guid,
    }

`esModularBehaviorTree` removed rather than emptied — WO-21 proved it inert, so the aggro
toggle's switch on it was always a no-op. Aggro is unchanged; it comes from the native
faction attach, as it always actually did.

---

## 2. Verified effect (real `KCD2MP_SpawnGhost`, post-install)

| Property | Before | After |
|---|---|---|
| `SharedSoulGuid` | `00000000-0000-0000-0000-000000000000` | `40fd3055-48be-a9f5-de48-0b882695cca5` |
| Roster soul honoured | no — GUID discarded | yes — `ttro_man_30` |
| `CombatLevel` | −1 | 0.6488 |
| `FactionNode.UIName` | empty | `soul_ui_name_soldier` |
| Reputation log | orphan, no entries | inherited from the soul's faction |
| Armour preset | applied | still applied (`kcd2mp_whitered_armor`) |
| Position stability | byte-stable | byte-stable (6 samples / 45 s, 7 d.p.) |
| Recovers from unconsciousness | never | yes |

WO-20's face roster was already correct — its determinism was computing a GUID the engine
never read. It now resolves to a real authored soul, which is where the face, faction,
combat level *and brain* all come from together.

---

## 3. A1 evidence

WO-21's A1: knocked unconscious, health frozen to the decimal, position byte-identical,
held 9 and 16 minutes until removed, never recovered.

Same knockdown on a soul-backed ghost (`wo22U`, commoner soul, no scheduler proxy,
health forced to 4, knocked out unarmed):

    09:00:30  hp=4.0  unc=false
    09:00:41  hp=4.0  unc=TRUE    buffs=[unconscious, buff_infinite_blindness, low_health]
    09:01:25  hp=4.0  unc=true    position byte-identical throughout
    09:01:35  hp=4.0  unc=FALSE   stood up, Z back to exact ground level
    09:04:50  hp=4.0  unc=false   still stationary 3 min later, no wandering

    second cycle, same ghost:
    09:07:08  unc=TRUE    ->    09:07:34  unc=FALSE     (<=26 s)

WO-21's re-root-cause was right: the wake-up branches live in the `npc_basic_switch`
subbrain the ghost never had. Giving it the subbrain is what fixed it.

A separate proxied run recovered after 7 m 35 s and also resumed health regen, which the
proxy-less shape does not — so a frozen health value is not by itself the A1 signature;
the unconsciousness ending is.

---

## 4. Why `SchedulerProxyName` is not shipped

KM-A-93: a *spawned* NPC has no activity links of its own and needs a scheduler proxy to
inherit them. Passing it produces a fully autonomous NPC.

| Spawn shape | Soul bound | Moves on its own | Recovers | ForceMount |
|---|---|---|---|---|
| `Properties.guidSharedSoulId` (old) | no | no | never | works |
| `SharedSoulGuid` (**shipped**) | yes | no | yes | works |
| `+ SchedulerProxyName` | yes | yes — 70 m in 75 s | yes | works |

The two effects are separable, and that decided it: **the soul alone buys the recovery
fix; the proxy buys only a fight with `KCD2MP_InterpTick`'s position stream.** Proxied
ghosts patrolled, went for a drink, and in one case fled 150 m from a real guard before
dying — impressive, and incompatible with a position-synced ghost.

Both WO-21 regression risks tested. ForceMount does **not** regress in any shape. (One
intermediate reading said otherwise; that was an occupied-horse confound, corrected on
re-run.)

---

## 5. Open items — candidates for your WO list

**WO-A · Close the A1 measurement gap** *(small, blocking a clean claim)*
A knockdown-and-recovery cycle on a ghost spawned by `KCD2MP_SpawnGhost` itself was
attempted post-install and could not be completed. Recovery on the shipped path is
currently **inferred from an identical spawn shape, not measured on it**. Do it outside a
settlement's guard coverage, or have a hostile NPC do the knocking rather than the player.

**WO-B · Ghosts are now attackable-as-crime** *(user-facing, new, unresolved)*
A ghost carries a real soul and faction identity and spawns as `Civilians`. Attacking one
inside a settlement is a crime and draws guard aggro onto the attacking player —
encountered for real during testing, which is what ended the session. Real players punching
each other's ghosts in a town will hit this. Did not exist before ghosts had souls.

**WO-C · Move aggro onto the soul row** *(strongest follow-up lead)*
Hostility came from the soul row's own `factionName`, with no native `SetParent` attach and
no DLL injection — and it sidesteps WO-21's "donor bandit not loaded in this save"
fragility entirely, because the GUID comes from table data rather than save data. Untested
as a replacement for the current mechanism.

**WO-D · Re-test WO-20's Lua binds against a real brain** *(cheap)*
`AI.AddPersonallyHostile` and `AI.SetAttentiontarget` write real, verified engine state but
produced no action against a brainless ghost. Whether a brained ghost now acts on them is
untested.

**WO-E · Housekeeping**
- `PROJECT-STATE.md`'s A1 entry is now conditional on the old brainless spawn shape.
- A debug helper (`TestXGenSpawn`) still uses the old nested spawn shape.
- `XGenAIModule.AddLink(fromWUID, toWUID, 'TagName')` — the finer-grained route to
  scheduler links than borrowing another NPC as proxy — is registered and untried.
- `Build-And-Install-Mod.ps1`'s "stored entries" comment claims more than the evidence
  supports (see §7).

---

## 6. Prior-work corrections

- **WO-16** — `esModularBehaviorTree = "IdleSeq"` was never a real tree. Independently
  reconfirmed twice: `IdleSeq` appears in none of the 3,235 real behaviour-tree names in
  the extracted game scripts, and the retail Lua state dump shows it as a constant on every
  AI entity in a loaded save.
- **WO-20** — the faces were real, but not the *roster soul's* face; the GUID was being
  discarded. Fixed by this WO.
- **WO-21** — its negative findings all held. Its escalation to native work did not: the
  door it did not try was the parameter shape of a call the mod already made.
- The planned "try a real behaviour-tree name" experiment was **never run**, because the
  extracted data proved it could not work.

---

## 7. Other two sources

**Nexus aggression mod — category (A), parameter tuning only.**
One 758-byte pak, one file: a table patch setting ten combat-pacing parameters (every
inter-attack delay to zero, secondary attackers to full speed). Nine of ten keys have no
vanilla row; the tenth overrides `CombatAutoMaxAttackDelay` 2 → 0. No Lua, nothing native,
**no contact with brain assignment, trees, souls or factions.** Useful only as a reference
for the KM-A-12 table-patch convention.

**altire-dev/kcd-toolkit — adopt nothing.**
Five Python/wxWidgets GUI apps for asset modders. The pak builder's only extra feature is
size-capped splitting, irrelevant at this scale, and it writes `ZIP_DEFLATED` where ours
deliberately writes `NoCompression`. The asset finder searches pak *entry names*, not file
contents — strictly weaker than grepping extracted trees. There is also no Python on this
machine. Current tooling is equivalent or better throughout.

**Cross-finding:** both the shipped Nexus mod and the community pak builder use deflate
inside `.pak` files, contradicting `Build-And-Install-Mod.ps1`'s claim that the loader wants
stored entries. Two data points, `Libs/Tables` XML only. Not a reason to change the build —
NoCompression works and is conservative — but the comment overstates.

---

## 8. Delivery state

- Branch `wo-22-brain-lead`, 5 commits, pushed.
  PR: https://github.com/DeepFriedDepp/kcd2-multiplayer_Reworked/pull/new/wo-22-brain-lead
- Mod rebuilt (`kdcmp.pak`, 333,243 bytes) and installed to
  `D:\SteamLibrary\steamapps\common\KCD2Mod\Mods\kdcmp\`; `MOD INIT` confirmed after reload.
- New tooling: `tools/wo22-lua.ps1`, `tools/Wo22-Watch.ps1`.
- Gate docs: `docs/WO-22-brain-lead.md`, `WO-22-nexus-mod.md`, `WO-22-toolkit.md`,
  `WO-22-progress.md`.
- No `VERSION` or release changes. All 20+ test entities runtime-only and removed, verified
  by count.

## 9. Licensing

Neither external repository ships a LICENSE file, so both default to all-rights-reserved.
**Nothing was copied from either.** Only facts were taken from `muyuanjin/kcd2-mod-docs` —
a documented function signature, a database column name, a sentence of Warhorse's own
documentation. Any future reuse of actual files from either source needs a licensing answer
first.
