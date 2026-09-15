# WO-97 progress

| Phase | State |
|---|---|
| 0 — audit the 22 shipped fix-table entries | **done** — 5 withdrawn, 17 ship, 160/160 synthetic |
| 1 — confirm the live read | **done** — node resolution confirmed live; port-value read still open |
| 2 — map `C_PortRef::Trigger` statically | pending |
| 3 — identify target port, predict effect | pending |
| End gate — build 0.22.4 from a fresh clone | pending |

## Phase 0

Walked the 19 entries WO-96 did not spot-check, plus re-walked its 3, with a
new transitive chain walker (`tools/Audit-ObjectiveFixHazards.py`). Five
entries' `On<State>` pulse chains reach a `CutsceneHandler.EnqueueCutscene`
and were withdrawn:

* `vezniNaTroskach.startApolenaGameplay`
* `sedmStatecnych.sedmStatecnych_kubenkaZachranen`
* `setkaniVRatbori2.pickWineSkip`
* `pogrom.04a_cutscene_blockadeFire`
* `prepadeniVlasskehoDvora.init_end2`

Two of WO-96's own hazard examples turned out wrong (docs/WO-97-findings.md
§1.4). Nothing was fired; every row is code-verified.

## Phase 1

Environment was made perfect by the maintainer (game up, save loaded, launcher
Connect completed, `KCDMP.dll` injected -- all verified from this shell) and the
read still could not be attempted: **`KCDMP.dll` has no ConceptModule code at
all**. WO-96 decompiled the read path but never implemented it. Verdict stated
as failed, not partial.

Static half *is* done, and closes both of WO-96 s3.1's open items:

* **separator = `.`** (0x2E), traced through the `C_ConceptPath` ctor ->
  `SimpleTokenize` -> the static-init constructor of the separator global ->
  the `.rdata` literal at RVA 0x3ED4E4;
* **`GetNode` descent** = per-node vtable slot `+0x48` ("resolve one child by
  name"), called in a loop, one `pop_front` of the path per hop, until the
  path's remaining count at `+0x28` hits zero or a hop returns null.

Also recovered: `ConceptModule.dll` carries full mangled symbols, so
`C_PortRef::Trigger` (`0x34E610`), `C_PortRef::Read` (`0x34E500`),
`C_PortRef::GetPort` (`0x34E690`) and `I_Port::CanTrigger` (`0x2B1E30`) are
named, not inferred. `C_PortRef::Read` is the concrete way past WO-96 s7's
`I_Port::Read` export trap.

**Deviation approved and carried out.** The read shipped as pipe command
`0x08` (read-only), built here, deployed by the maintainer, fired live.
`FindNode` resolves real nodes at every depth; the roots are `Barbora` and
`Haste`; the second Hans dialogue is addressable. One bug on the way: a
negative CryString refCount makes the engine substitute the empty string, so
the first build read nothing and returned null for everything (findings
s2.1b). Port *values* are still unread -- that needs `C_Node::GetPort` and the
concrete `C_PortRef::Read`, neither implemented, so the sacks known-answer
check stays inconclusive.

## Deviations

* **Considered and dropped:** chasing `IsHidden=true` on two kept entries
  (`complete_findRuthard`, `hideBeforeBattleMainObjective`) to decide whether
  `wh_concept_HasteTrigger` can fire a hidden trigger at all. Dropped: the
  console help does not say, and settling it needs the live game — cheaper in
  the Phase 1 session than by disassembly. Recorded as note C.
* **Taken:** committed a Python tool into an otherwise all-PowerShell `tools/`.
  Reason: the audit is a graph walk across ~20 XML files per entry; rewriting
  it in PowerShell would have cost more than it was worth, and Python 3.14.7
  *is* present on this machine (the standing "no Python locally" note is
  stale).
