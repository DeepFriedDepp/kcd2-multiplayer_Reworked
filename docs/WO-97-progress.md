# WO-97 progress

| Phase | State |
|---|---|
| 0 — audit the 22 shipped fix-table entries | **done** — 5 withdrawn, 17 ship, 160/160 synthetic |
| 1 — confirm the live read | **STOP** — needs deployed DLL + maintainer at the keyboard |
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
