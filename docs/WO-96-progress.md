# WO-96 — progress

Divergence-triggered prompting, the `WAITING_FOR_PEER` state, sub-objective
mismatch detection, and an attempt to close the gap with Warhorse's own
narrow triggers. Findings: `docs/WO-96-findings.md`. Session date 2026-09-14.
No live game was reachable from this session (`:1403` refused); every claim
below is marked synthetic / code-verified / observed-from-files accordingly.

| Phase | Status |
|---|---|
| 0 — ground truth | Done. `main` at WO-95's head; WO-95 §5, WO-92 §5.2/§6/§7/§8, WO-94 §3–§6 read; `VERSION` 0.22.0 untouched. |
| 1 — divergence-gated prompt + `WAITING_FOR_PEER` | **Done, synthetic-verified (`tools/Test-WO96Synthetic.ps1`, 110/110).** Agent: `SendQuestDivergence` rides `ReportStoryDivergence`; the peer's approach is a beat hint only; `_lastSharedObjective` gives behind/ahead. Mod: `KCD2MP_QuestDivergence`, `KCD2MP_QuestConverged`, `KCD2MP_QuestWaiting*`, spent-beat gate, 60 s per-peer debounce, F12 / `mp_quest_hide` dismiss, status row at y=232. WO-94 harness updated for the new state/wording (101/101); WO-90/95/86/84 suites unchanged; client unit tests 72/72. Pak rebuilt with `-NoInstall`; not installed from this shell (AppData redirection rule). Committed as Phase 1. |
| 2 — sub-objective mismatch detection | See findings §3. |
| 3 — close the gap with a narrow trigger | See findings §4. |
| 4 — verification | See findings §5. |

## Phase 1 decisions, in one place

* **Trigger = the `[story] divergence` signal.** Proximity is no longer a
  condition; a peer's `quest_approach` only refines *which* beat is offered.
* **Who is behind**: the agent remembers the last marker the pair agreed on;
  whoever still sits on it is behind. When both have moved, the mod orders by
  production code (M05 > M03); same quest and no shared history → "cannot
  tell", shown as `STORY DIVERGED`.
* **Offer only across quests.** Same-quest divergence is `WAITING_FOR_PEER`
  ("reach their objective through ordinary play"); a quest-start Haste entry
  fired mid-quest advances nothing (the 2026-09-13 host proved it twice).
* **Spent beats.** A beat fired here this session is never offered again.
* **Debounce** 60 s per peer; a deferred offer waits in the status row and is
  raised by the 1 Hz tick when the gap has elapsed.
* **Decline** (F12) suppresses that beat for the session (unchanged from
  WO-94); later divergence to that quest becomes `WAITING_FOR_PEER`.
* **Update in place.** The row and its toast are per (peer objective, our
  objective, rel); a changed objective updates the row silently, a changed
  rel toasts again.
* **Prologue**: M01/M02 have no fireable beat, so divergence there is
  `WAITING_FOR_PEER` only — one toast, one row, nothing fires.
* **Not a lock.** No path pauses, gates input, or issues any console command
  other than `wh_concept_HasteTrigger` after F11 (synthetic (o)).

## Traps met this session

* PowerShell 5.1 treats `$out` and `$Out` as the same variable — a script
  parameter named `$Out` silently shadowed a `MemoryStream` and produced
  "String does not contain a method named ToArray".
* Git Bash `grep -rl` over 21,649 extracted quest files takes minutes; scope
  the search to the quest folder.
* `strings` is not on this machine; `grep -a` on the inflated save works.
