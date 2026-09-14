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
| 2 — sub-objective mismatch detection | **Done on the save-file surface, not the native one.** The ConceptModule export route (WO-92 §5.2) was NOT called: no live game this session and `KCDMP.dll` cannot be deployed from this shell. It was sharpened statically with Ghidra 12.1.3 on MT `ConceptModule.dll` (signatures + register layout + the fact that the exported `I_Port::Read` is the empty base implementation — findings §3.1) and handed off. Detection instead reads the same concept-graph state from the autosave the engine writes at every marker: `tools/Build-MainQuestObjectives.ps1` → `mainquest-objectives.json` (626 objectives, 601 with a display node, registry id `b6b917b72323`); `SaveGameReader` / `StoryFingerprint` / `QuestObjectiveRegistry` in the agent; StoryBeat kind 5 on the existing 0x37/0x38 wire; registry-id mismatch refuses comparison; `KCD2MP_QuestObjectiveGap` in the mod. **Known-answer check run on the real 2026-09-13 host save** (`--fingerprint autosave009.whs socky`): the marker's objective reads active, the optional wedding objective active, the sacks none — exactly the journal at 16:21; saves 005/007/008 show done/active progressions (findings §3.3). 89/89 unit tests, 123/123 Lua synthetic. Not run across two machines. Committed as Phase 2. |
| 3 — close the gap with a narrow trigger | **Attempted with a full census, honest result.** `tools/Find-ObjectiveTriggers.ps1` (WO-94's extraction) → `docs/WO-96-objective-triggers.csv`: 626 objectives, 39 with a direct narrow trigger, 24 clean, **22 grant triggers** generated into `KCD2MP_OBJECTIVE_FIXES` in kdcmp.lua. The mod offers one through the existing F11 prompt when the local player is in that quest and the peer's fingerprint shows the objective in that state; same channel, hazard window, spent/declined gates; no teleport by construction. **The sacks of M03 have no narrow trigger anywhere in `socky`** — the bag gap is named, not closed (findings §4.3). 16 of 32 quests have at least one fix. Not fired live. Committed as Phase 3. |
| 4 — verification | Synthetic 142/142 (WO-96), regression WO-94 101, WO-90 70, WO-95 32, WO-86 47, WO-84 72; xunit 89/89; known-answer probe on the real host save (findings §3.3). Live list in findings §5.4. |

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
