# WO-57 progress — "play the story together": eight-phase design synthesis

## Session 1 — 2026-08-25 (Fable 5)

1. Copied the MMO design reference verbatim to `docs/WO-57-mmo-reference.md`
   per the prompt.
2. Corrected two prompt premises before starting: `docs/WO-33-findings.md`
   does not exist (dice corpus is WO-23/24/25), and WO-54 (the live
   two-human session) never happened — it died on the launcher hostname
   rejection WO-55 later fixed. Phase 3 therefore keeps WO-51's plan
   standing, per the prompt's own instruction for that case.
3. Deep-read the phase-relevant corpus: WO-25 (dice negatives + vip-class
   live A/B), WO-51 (in full), WO-47 (§ ranged vocabulary, § zone gap),
   WO-42 §9.2 (zone-tagged descriptors), WO-40 (dialogue detection gap),
   WO-6-native-dice + WO-6-visual-capability (dice reflection closure, UI
   ceiling), WO-48 (spawn recipe, item machinery), WO-28 (PvP damage
   plumbing), WO-15 (live siege anatomy), WO-52 (NetSerialize sweep),
   WO-56 (topology conclusion), plus the live pause-marker code
   (`LogTailGameTransport.cs`) and the 0x22 apply point (`GameBridge.cs`).
4. Light static fact-checking (game not running — REST probe timed out, so
   no live probes; all new evidence is on-disk):
   - `OverrideNextThrow`, `C_ScriptBind_Dice` RTTI, and
     `wh::playermodule::C_Dice::StartDice`/`OnGameStateChanged`/
     `SetSelectedDie` `__FUNCTION__` strings all located in
     `PlayerModule.dll` — the WO-42 disassembly method has its anchors.
   - Found a start surface nobody had probed:
     `Minigame.StartDice(tableId, playerId, opponentNpcId)` /
     `StartDiceWithScore(…, targetScore)` / `StartDiceByName(name)` —
     registration strings in PlayerModule.dll + full signatures in the
     shipped scriptbind docs + `DiceInteractor.lua` (extracted from
     Scripts.pak) showing the vanilla dialogue-mediated start and a
     commented-out direct `StartDiceByName` call.
   - Extracted `AlchemyTable.lua`/`Smithery.lua`: stations gate on a live
     per-entity `nUserId` occupancy field (Phase 5 answered at the Lua
     layer, no reflection needed).
   - Scriptbind docs: `human:IsInDialog()` and `Dialog.IsSoulInDialog(wuid)`
     exist (Phase 4 detection), `GameRules.SetInvulnerability(id, bool)`
     exists but the `GameRules` global is nil on this build (WO-38) — so
     Phase 6's no-death rail 2 is a native setter-recovery job, and
     `Actor.RequestKnockOut(target)` is a documented KO-finish candidate.
5. Wrote `docs/WO-57-findings.md`: all eight phases reached — 1, 4, 5, 6 at
   full depth with new static findings; 2, 3 as synthesis on the standing
   corpus; 7, 8 honestly scoped for follow-ups (7: two bounded tests before
   any investment; 8: deferred behind WO-A–D plus an unmeasured capacity
   bound). Shared-vs-individual verdicts stated per phase, including three
   deliberate "keep it individual" calls (dialogue's world-freeze, station
   hard-locks, crime/consequence export from duels).
6. Follow-up shortlist produced (findings §end): activity-channel WO first,
   then WO-A (now unblocked by WO-55), ranged visibility, dice disassembly,
   duels, UI ceiling test, sieges deferred.

No code, no VERSION change, no live game contact. Scratchpad-only
extractions (entity Lua, doc pages) were not committed.
