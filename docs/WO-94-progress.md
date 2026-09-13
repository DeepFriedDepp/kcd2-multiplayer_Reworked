# WO-94 progress

Read `docs/WO-94-findings.md` first — it carries the evidence. This file is
the state-of-play.

## Status

| Item | State |
|---|---|
| Phase 0 — ground truth | **Done.** `main` at `42b1b1a` (WO-92's head), clean, `git pull` up to date. WO-92 read in full; WO-90 §3/§4 read. No WO-91 doc or commit exists on any branch. `Scripts.pak` sha256 matches WO-92's. |
| Phase 1.1 — F-keys | **Done.** F11 = `kcd2mp_dice_bank`, F12 = `kcd2mp_dice_yield`, read from `keybindSuperactions.xml:1009-1016` and `defaultProfile.xml:140-141`; already the dice-invite accept/decline binds since WO-33. Bound via the same `ACCEPT_ACTIONS`/`DECLINE_ACTIONS` tables. |
| Phase 1.2 — overlay mechanism | **Done.** `System.DrawText` from the 8 ms `KCD2MP_LabelTick` loop via `KCD2MP_DrawInteractionUI`; immediate-mode, so a line persists exactly as long as its state is set; the prompt has no timeout (synthetic: still drawn after an hour). Rows 160/184/208. |
| Phase 1.3 — registry | **Done.** `tools/Build-MainQuestRegistry.ps1` → generated block in `kdcmp.lua` + `docs/WO-94-mainquest-registry.csv`. Exactly 32 M-coded quests, 1,014 triggers, 138 positioned, **53 fireable**; 10 quests (incl. M01) have none. Grammar cross-checked: 22 authored paths match, 0 mismatch, 9 stale. No DLC, no side content. |
| Phase 1.4 — stand-off 60 s → 180 s | **Done.** One constant (`kdcmp.lua:2346`); WO-90's scenario lapse moved to 181 s; 70/70 still green. |
| Phase 2 — wiring | **Done.** Agent pushes quest + level to the mod; mod detects at 1 Hz and emits `quest_approach`; StoryBeat kinds 2/3/4 on the existing 0x37/0x38 bytes; receiving agent prompts only when both objectives are known and differ; F11 fires `wh_concept_HasteTrigger <quest>.<trigger>` via `System.ExecuteCommand`; F12 declines; not responding = nothing; hazard windows on both machines. Overlay non-interception proven statically (hook runs after the game's handler; harness proves the game's handler runs for every press); live confirmation pending. |
| Phase 3.1 — synthetic | **Done, 94/94** (`tools/Test-WO94Synthetic.ps1`) + 26 new unit tests. Whole suite **497 checks, 0 failures**; build 0 errors, same 8 warnings as WO-89. |
| Phase 3.2 — live checks | **STOPPED, none run.** No game process existed this session; the maintainer was not at the keyboard. Exact procedure in findings §8. |
| Phase 3.3 — what needs two players | **Stated** in findings §7.3. |
| Phase 4 — release cut | **Not started** (follows Phase 3 in the work order). `VERSION` unchanged at `0.21.5`. Everything for it is staged: `Verify-Install.ps1` markers added, README rows added, no native change since 0.21.1 (`git log -- native/`: last is WO-86 `d7da56a`, which 0.21.1 shipped). |
| STOP-rule compliance | Six points reached, six stops — findings §8. |

## What changed

| File | Change |
|---|---|
| `tools/Build-MainQuestRegistry.ps1` | New. Reads `<MT>/Data/Scripts.pak`, writes the registry block + CSV. Aborts on ≠32 quests, DLC-named M code, grammar mismatch, over-budget path. |
| `docs/WO-94-mainquest-registry.csv` | New. All 1,014 main-quest Haste triggers with path, position, cumulative/namespaced/test flags, fireable verdict. |
| `kdcmp/Data/Scripts/Startup/kdcmp.lua` | Shared Quests section (registry block, proximity tick, prompt, keys, fire, hazard window, 8 console commands); hazard hooks at the death observer, remote death apply, `ApplyTimeSkip`, ghost teleport, chain-suspend verdict, divergence release, own-death edge; draw + emitter + OnAction wiring; `MP_NPC_DIVERGE_COOLDOWN_S` 60 → 180. |
| `dotnet/KcdMp.Protocol/Protocol.cs` | `StoryBeatKindApproach = 2`, `StoryBeatKindCatchupBegin = 3`, `StoryBeatKindCatchupEnd = 4`; doc. No version bump (relay verbatim, old receivers drop). |
| `dotnet/KcdMp.Client/StoryBeat.cs` | `TryQuestNameFromMarker`, `IsValidBeatPath`, `CatchupHazardTag`. |
| `dotnet/KcdMp.Client/LogTailGameTransport.cs` | `LevelDetected` (the `Loading level <x>` banner) and `CutsceneStateChanged` events. |
| `dotnet/KcdMp.Client/GameBridge.cs` | Quest/level push (+ on the 2.5 s re-arm), `quest_approach`/`quest_catchup` events, kinds 2/3/4 send + receive, prompt/moot, peer windows, `CATCHUP-HAZARD` tags on clock-jump, FATAL and cutscene lines, ghost-teleport detector, disconnect cleanup. |
| `dotnet/KcdMp.Client.Tests/StoryBeatTests.cs` | 26 new checks pinned to field markers and the path grammar. |
| `tools/Test-WO94Synthetic.{lua,ps1}` | New, 94 checks. |
| `tools/Test-WO90Synthetic.lua` | Stand-off lapse 61 → 181 s. |
| `tools/Verify-Install.ps1` | 2 agent markers + 4 pak markers for 0.22.0. |
| `README.md` | Shared Quests row in both feature tables; Testing section line. |
| `docs/WO-94-findings.md`, this file | New. |

Not changed: `VERSION`, `kdcmp.pak` (rebuilt at release cut, per precedent),
`native/`, the relay's code (it already relays 0x37 verbatim), the launcher,
WO-90's divergence rule beyond the one constant.

## Live procedure (findings §8, condensed)

Solo, disposable save, agent connected:

1. Console `wh_concept_HasteEnable`; grep `kcd.log` for `HasteEnable` — a
   value, or a `[VF_CHEAT]` refusal (then `-devmode` on the launcher).
2. `mp_quest_status` — 32 quests / 53 beats line, current quest.
3. `mp_quest_test_prompt` — two rows under the ping; walk, inventory,
   weapon, sit: report anything blocked.
4. **F12** — rows gone, `QUEST-PROMPT declined` in the log.
5. `mp_quest_test_prompt socky._initAndStart` then **F11** — `QUEST-CATCHUP
   FIRE #1 …`, toast, status row, then the engine's own lines; paste every
   `CATCHUP-HAZARD` line from the next 120 s.
6. COLLECT LOGS.

Then "go" (Phase 4) or "skip live" (cut 0.22.0 with Phase 3 recorded as
not run).

## Traps recorded for future sessions

* **`goto <entity>` outnumbers `goto x y z` two to one** in the main quests;
  a registry that only reads coordinates misses most beats. Entity beats
  are resolved live with `System.GetEntityByName`, which also makes them
  level-safe.
* **Warhorse's authored `wh_concept_hasteTrigger` strings go stale** (9 of
  31 in the main quests). Validate grammar only where the target exists.
* **The engine lowercases quest names in `@qname_`** markers; the XML
  `Name=` is camelCase. Compare case-insensitively; fire with the XML case.
* **The `Type=` attribute never says "Main"**; `ProductionCode="M<nn>"` is
  the only main-quest marker in the corpus.
* **`unzip` cannot extract this pak's entries by wildcard** (it lists them
  but extracts one); .NET `ZipFile` reads it fine — the extractor uses that.
* **Windows Python cannot see Git Bash's `/tmp`**; write session scripts to
  the scratchpad path.
