# WO-22 progress — three external sources, one shared goal

Session run 2026-08-06. Pure investigation. Nothing was copied, ported or
vendored from any of the three sources; nothing shipped was changed.

---

## §1 — `muyuanjin/kcd2-mod-docs` — the headline

**The blocker is broken. A1 is fixed.**

WO-21 closed five doors and concluded the ghost's missing Warhorse brain was
"unreachable from every surface the mod can touch," escalating to native work.
That conclusion does not survive. The brain was reachable the whole time,
through a Lua bind this project already calls — with the wrong parameters.

The lever is **not** a behaviour-tree name. `esModularBehaviorTree` is inert,
and WO-21 was right about that twice over: `IdleSeq` appears in none of the
3235 real behaviour-tree names in extracted `Scripts/AI/`, and the retail
`lua_dump_state` shows every AI entity in a loaded save reporting it as a
constant. The originally-planned §1.2 test was not run because the data proves
it cannot work.

What the data shows instead:

- A brain is a **column on the soul row** — `brain_id` in
  `Libs/Tables/rpg/soul__*.xml`, `4b914d1c-…` = `npc_basic` on 5417 souls.
  An entity gets a brain by getting a soul.
- Warhorse's own KM-A-93 states that a **spawned** NPC has no activity links
  and needs a **scheduler proxy** to inherit them. That is what "the ghost does
  nothing" has always been.
- `XGenAIModule.SpawnEntity`'s shipped scriptbind doc gives a **flat** table
  with top-level `SharedSoulGuid` and `SchedulerProxyName`. This project passes
  `guidSharedSoulId` nested inside `Properties` and no proxy at all.

Tested live, read back rather than assumed:

| spawn shape | `SharedSoulGuid` reads back | faction / combat level | moves on its own | `ForceMount` |
|---|---|---|---|---|
| `Properties.guidSharedSoulId` (shipped) | `00000000-…` — **no soul bound** | none, `CombatLevel=-1` | no | works |
| top-level `SharedSoulGuid` | the real soul | guard identity, inherited reputation log, `CombatLevel=0.5` | no | works |
| `SharedSoulGuid` + `SchedulerProxyName` | the real soul | same | **yes — 70 m in 75 s** | works |

Soul-backed, scheduler-linked ghosts patrolled, confronted, got drunk, fled a
fight across 150 m of terrain, bled, and died. A hostile ghost needed **no
native faction attach and no DLL injection** — the hostile faction came from
the soul row, which also removes WO-21's "donor bandit not loaded in this save"
blocker entirely.

**Gate — A1: WORKED.** `wo22L`, knocked unconscious by the human with fists at
08:41:14, then health frozen at exactly 4.0 and position byte-identical across
45 consecutive samples — the exact WO-21 signature — **woke at 08:48:49**, 7
minutes 35 seconds later, and walked away regenerating. WO-21's ghosts were
held 9 and 16 minutes and never recovered, so this is a real recovery inside
that window, not a longer look. WO-21's re-root-cause
(the wake-up branches live in `npc_basic_switch`, the subbrain the ghost does
not have) was correct, and giving the ghost that subbrain is what fixed it.

**Gate — A2: PARTIAL.** A ghost now acts: it moves on its own decisions,
confronts, evades, flees, runs crime-reaction branches, and is a real
participant in combat. No ghost was seen to land a blow — every hostile one
chose to flee, which is a real behavioural decision rather than the old
inertness. "Fights back" is not demonstrated. WO-20's two writable binds were
not re-tested; whether a real brain now makes them actionable is flagged, not
answered.

**Gate — regressions.** `ForceMount` does **not** regress: plain, soul-only and
soul-plus-proxy ghosts all mount the same horse. (One intermediate reading this
session said otherwise; that was an occupied-horse confound, corrected on
re-run.) The position-sync conflict **is** real and confirmed by construction —
a scheduler-linked ghost walks away continuously.

**The two are separable, and that settles the shipping question.** Tested at
the human's direction after the above: `wo22U`, top-level `SharedSoulGuid` with
**no** `SchedulerProxyName`, knocked out unarmed twice — recovered both times
(**≤54 s** and **≤26 s**), stood back up, and stayed byte-stationary throughout,
before and after. So the soul alone buys A1's fix; the scheduler proxy buys only
the position-sync conflict. **Ship `SharedSoulGuid`, omit the proxy.**

**The fix is applied, built, installed and verified live.** A ghost spawned
through the real unmodified `KCD2MP_SpawnGhost` now reads back its roster
soul's `SharedSoulGuid` (previously all-zeroes), real `CombatLevel` and faction
identity, keeps its armour preset, and stays byte-stationary.

**One gap, stated plainly:** a knockdown-and-recovery cycle on a *mod-spawned*
ghost was attempted and could not be completed, so the shipped path's recovery
is inferred from an identical spawn shape rather than measured on the shipped
path itself. The reason is product-relevant and new: a ghost is now a
`Civilians`-faction NPC, so **the player attacking one in a settlement commits
a crime and draws guards.** That will happen to real players who punch each
other's ghosts in a town. Worth its own look before release.

Full detail and evidence: `docs/WO-22-brain-lead.md`.

---

## §2 — the Nexus aggression mod

**Category (A) — parameter tuning, as expected.** One 758-byte pak containing
one file: `Libs/Tables/rpg/rpg_param__ZMagusAggresiveCombatAI.xml`, a KM-A-12
table patch setting ten combat-pacing parameters (every inter-attack delay to
zero, secondary attackers to full speed). Nine of the ten keys have no vanilla
row; the tenth overrides `CombatAutoMaxAttackDelay` 2 → 0.

It touches **no** brain assignment, tree, soul or faction. No Lua, nothing
compiled or native. Useful only as a reference for the table-patch convention.

`docs/WO-22-nexus-mod.md`.

---

## §3 — `altire-dev/kcd-toolkit`

**Verdict: adopt nothing.** Five Python/wxWidgets GUI apps aimed at asset
modders. `kcd-pak-builder` writes `ZIP_DEFLATED` where ours deliberately writes
`NoCompression`, and its only extra feature is size-capped pak splitting,
irrelevant at this project's scale. `kcd-asset-finder` searches pak *entry
names*, not file contents — strictly less capable than grepping the extracted
trees, which §1's repo now ships ready-made. There is also no Python on this
machine. Current tooling is equivalent or better throughout.

`docs/WO-22-toolkit.md`.

---

## Cross-cutting: a small correction to our own build comment

Both §2's shipped Nexus mod and §3's community pak builder use deflate
compression inside `.pak` files, contradicting `Build-And-Install-Mod.ps1`'s
"the game's pak loader is happier with stored entries." Two data points, both
for `Libs/Tables` XML only. **Not a reason to change the build** —
NoCompression works and is the conservative choice — but the comment claims
more than the evidence supports.

## Licensing

Neither external repo ships a LICENSE file. Nothing was copied from either.
Only facts were taken from `kcd2-mod-docs` — a documented function signature, a
database column, a sentence of Warhorse's own documentation — which is what a
docs repo is for. Any future reuse of actual files from either needs a
licensing answer first; that is a follow-up decision, not this session's.

## Files touched

- `tools/wo22-lua.ps1` (new) — ExecuteString driver + `[WO22]` log reader
- `tools/Wo22-Watch.ps1` (new) — telemetry watcher with per-sample movement delta
- `docs/WO-22-brain-lead.md`, `docs/WO-22-nexus-mod.md`,
  `docs/WO-22-toolkit.md`, `docs/WO-22-progress.md` (new)

No changes to `kdcmp.lua`, `native/`, `dotnet/`, `VERSION`, the installer, or
`KCD2MP_SpawnGhost`'s shipped defaults. Every test entity was runtime-only and
removed; absence verified by name lookup at end of session.
