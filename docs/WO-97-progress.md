# WO-97 progress

| Phase | State |
|---|---|
| 0 — audit the 22 shipped fix-table entries | **done** — 5 withdrawn, 17 ship, 160/160 synthetic |
| 1 — confirm the live read | **done** — node resolution confirmed live; port-value read still open |
| 2 — map `C_PortRef::Trigger` statically | **done** — mapped; C_PortRef route stalls, slot-15 route does not |
| 3 — identify target port, predict effect | **done** — two IN-ports, effect chain predicted, live-fire procedure written |
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

## Phase 2

`C_PortRef::Trigger` = RVA 0x34E610, `void __thiscall(C_PortRef*)`, virtual
slot [15] / +0x78. Convention trivial, nothing guessed.

Three results that change the plan:

* **`I_Port::Trigger` is an empty base virtual**, exactly like the
  `I_Port::Read` export WO-96 s7 warned about -- the trap generalises.
* **Only `C_ActiveTriggerPort` actually propagates.** `C_TriggerPort`,
  `C_EdgePort` and `C_DataPort` inherit the empty base, so triggering one
  returns cleanly having done nothing -- WO-43's lesson in native form. Phase 3
  must check the port's vtable against `C_ActiveTriggerPort::vftable`
  (ConceptModule+0x3F3130) before believing a fire.
* **Out-ports are not triggerable.** `PortDef::InTrigger` sets direction 1,
  `OutTrigger` sets 2, and `CanTrigger` refuses 2. The prompt's
  `druhy_dialog_s_ptackem.nos_pytle` is an OUT-port; the real targets are the
  in-ports it drives (`pytle_a_hadka.start`, `rekniPtackoviOPraci.SetDone`).

The stall the WO asked me to name: there is no public `C_PortRef` constructor,
and building one needs a fabricated `I_PortDef`. But `C_PortRef::Trigger`'s
whole payload is `port->vtbl[0x78](port)`, so the write path bypasses
`C_PortRef` entirely: FindNode -> C_Node::GetPort -> slot 15.

## Phase 3

Target is **two in-ports**, not the out-port the prompt names (Phase 2 ruled
out-ports untriggerable):

* T1 `Barbora.trosecko.socky.hibernable.v_hospode.pytle_a_hadka` port `start`
* T2 `Barbora.trosecko.socky.hibernable.v_hospode.rekniPtackoviOPraci` port `SetDone`

T1 -> `sackcarrying.start_minigame` -> `sackCaryying.SetZvedniPytelZeZdrojeStart`,
which is exactly the state WO-96 read out of the joiner's save. From there the
state drives BOTH the carry triggers (sacks become grabbable) AND, via
`Output.states`, the `nos_pytle_05` objective display.

**The prompt's premise here is wrong in our favour.** It warns that writing the
objective would fix the journal and leave the sacks ungrabbable. True of writing
the objective -- but `nos_pytle_05` is not a State node; its Progress is fed from
`sackcarrying.states`, so the journal line is a readout of the minigame's state.
Starting the module gives both halves from one pulse, and there is no way on
this path to get the journal without the gameplay.

T2 has **zero** Done/OnDone consumers at any depth -- a pure journal line, and
the paired effect that firing T1 alone would leave stuck Active.

Hazards over both chains: one `EnqueueSave`. No cutscene, teleport, item,
dialogue, clothing or move. Named limits: the shared library module was walked
by hand (the tool cannot follow a non-child file), and the tavern brawl in
`treti_faze` is reached by COMPLETING the minigame, not starting it.

Live-fire procedure written (findings s4.4), including the step-0 vtable check
against `C_ActiveTriggerPort::vftable` without which a fire is unfalsifiable:
both `C_PortRef::Trigger` and the empty `I_Port::Trigger` return void, so a
call that did nothing is indistinguishable from one that fired. The only
admissible evidence is the sacks becoming grabbable.

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
