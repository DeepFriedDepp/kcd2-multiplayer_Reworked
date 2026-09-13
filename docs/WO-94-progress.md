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
| Phase 3.1 — synthetic | **Done, 101/101** (`tools/Test-WO94Synthetic.ps1`) + 26 new unit tests. Whole suite **504 checks, 0 failures** (366 → 373 Lua, 131 C#); build 0 errors, same 8 warnings as WO-89. |
| Phase 3.2 — live checks | **Run, with the maintainer at the keyboard, 2026-09-13** (findings §7.2): cheat gate open, Haste armed, proximity fires at 35.8 m with 7.0 s lead at a run, F11 fires the prompted beat and the engine drains a 14-trigger plan (repeat replay observed), F12 declines, rows drawn, nothing blocked. **Not live:** the two-machine path; the two fixes the ladder produced (console-argument trap, per-tick teleport watch) are synthetic-only. |
| Phase 3.3 — what needs two players | **Stated** in findings §7.3. |
| Phase 4 — release cut | **Done** (findings §11). `VERSION` = `0.22.0`; pak rebuilt; agent/protocol changed → full republish; native DLL confirmed byte-identical to 0.21.1/0.21.5 (`be76ba6a…`); `KCDMP-Setup-0.22.0.exe` built (95.8 MB, sha256 `9827b793…`), **no DirectInstall ZIP** (retired from here on); install matrix **97/97**; `Verify-Install` markers present in the build; Main badge → 0.22.0, Release badge is GitHub's dynamic latest-release image (follows the maintainer's GitHub release); `RELEASE-NOTES-0.22.0.md` written. |
| STOP-rule compliance | Part 1: six points reached, six stops. Part 2: each run with the maintainer present, results read from `kcd.log`, hand-driven steps marked in the log — findings §8. |

## What changed

| File | Change |
|---|---|
| `tools/Build-MainQuestRegistry.ps1` | New. Reads `<MT>/Data/Scripts.pak`, writes the registry block + CSV. Aborts on ≠32 quests, DLC-named M code, grammar mismatch, over-budget path. |
| `docs/WO-94-mainquest-registry.csv` | New. All 1,014 main-quest Haste triggers with path, position, cumulative/namespaced/test flags, fireable verdict. |
| `kdcmp/Data/Scripts/Startup/kdcmp.lua` | Shared Quests section (registry block keyed on each quest's own `qname_` marker stem with English titles, proximity tick, prompt, keys, fire, hazard window, per-tick teleport watch, argless `mp_quest_on/off` + 8 other console commands); hazard hooks at the death observer, remote death apply, `ApplyTimeSkip`, ghost teleport, chain-suspend verdict, divergence release, own-death edge; draw + emitter + OnAction wiring; `MP_NPC_DIVERGE_COOLDOWN_S` 60 → 180. |
| `dotnet/KcdMp.Protocol/Protocol.cs` | `StoryBeatKindApproach = 2`, `StoryBeatKindCatchupBegin = 3`, `StoryBeatKindCatchupEnd = 4`; doc. No version bump (relay verbatim, old receivers drop). |
| `dotnet/KcdMp.Client/StoryBeat.cs` | `TryQuestNameFromMarker`, `IsValidBeatPath`, `CatchupHazardTag`. |
| `dotnet/KcdMp.Client/LogTailGameTransport.cs` | `LevelDetected` (the `Loading level <x>` banner) and `CutsceneStateChanged` events. |
| `dotnet/KcdMp.Client/GameBridge.cs` | Quest/level push (+ on the 2.5 s re-arm), `quest_approach`/`quest_catchup` events, kinds 2/3/4 send + receive, prompt/moot, peer windows, `CATCHUP-HAZARD` tags on clock-jump, FATAL and cutscene lines, ghost-teleport detector, disconnect cleanup. |
| `dotnet/KcdMp.Client.Tests/StoryBeatTests.cs` | 26 new checks pinned to field markers and the path grammar. |
| `tools/Test-WO94Synthetic.{lua,ps1}` | New, 101 checks. |
| `tools/Test-WO90Synthetic.lua` | Stand-off lapse 61 → 181 s. |
| `tools/Verify-Install.ps1` | 2 agent markers + 4 pak markers for 0.22.0. |
| `README.md` | Shared Quests row in both feature tables; Testing section line. |
| `docs/WO-94-findings.md`, this file | New. |
| `docs/releases/RELEASE-NOTES-0.22.0.md` | New. |
| `docs/VERSIONING.md` | 0.22.0 row; DirectInstall ZIP retired from the build procedure. |
| `VERSION` | `0.21.5` → `0.22.0`. |
| `kdcmp/Data/kdcmp.pak` | Rebuilt. |
| `release/KCDMP-Setup-0.22.0.exe` | Built (not committed, per precedent). |

Not changed:
`native/`, the relay's code (it already relays 0x37 verbatim), the launcher,
WO-90's divergence rule beyond the one constant.

## Live results (2026-09-13, solo, disposable save) — findings §7.2

Cheat gate open (`wh_concept_HasteEnable = 1`); inert trigger executed with
no `[VF_CHEAT]`; `mp_quest_status` reports 32 quests / 53 beats; proximity
fired at 19.5 m when the quest was set and at **35.8 m on a real walk-in,
7.0 s before arrival at a run**; **F11 fired `wh_concept_HasteTrigger
socky._initAndStart` and the engine drained a 14-trigger plan** (teleport,
Hans streamed in, `prepadeni.endQuest`, `zachrana.hastes.endQuest`, …), the
window closed at 121 s, a second press replayed the identical chain; F12
declined and is remembered; the rows drew and nothing stopped working
(maintainer). Zero hazard lines in either window — no death, clock or
suspension happened, and the 19.5 m teleport slipped under the old rule
(fixed, synthetic-only).

## For the next session — the two-machine run

Both machines on 0.22.0 (the new agent is required at both ends: the old
one drops kinds 2–4 and pushes neither level nor quest).

1. Both players on **different** main-quest objectives (the marker must
   differ, or no prompt is shown by design). Player A walks toward a
   fireable beat of A's quest — `mp_quest_status` on A lists them with
   distances. Expect `QUEST-APPROACH` on A, `[quest] approaching …` in A's
   agent log, `[quest] <A> is approaching … -- objectives differ,
   prompting` in B's agent log, `QUEST-PROMPT shown` in B's `kcd.log`.
2. B presses **F11**. Expect `QUEST-CATCHUP FIRE` on B, `CATCH-UP FIRED BY
   PEER` in A's agent log, `QUEST-CATCHUP peer … fired` in A's `kcd.log`,
   and then — the point — any `CATCHUP-HAZARD` lines on **either** machine
   for 120 s. Paste them all.
3. Repeat with B not answering: the prompt must stay, nothing must fire,
   and WO-90's release must keep handling any dragged NPC (`NPC-DIVERGE …
   for 180s`).
4. `mp_quest_off` on one machine must stop both detection and prompts there.

## Traps recorded for future sessions

* **The console refuses arguments to Lua-registered commands on this build**
  (`[Warning] Too many arguments for: <cmd>`) and passes the literal `%LINE`
  when there is none. Every `on|off|<n>` `mp_*` command in `kdcmp.lua`,
  WO-17's onward, is affected; use `#KCD2MP_…(…)` Lua for values and
  register argless toggles. Live-verified, findings §9.
* **Six main quests' journal keys are not their XML names** (`qname_semin`
  is M08 `mucirna`, not a side quest). Match markers on the `qname_` literal
  each root carries; the extractor now emits it as `key`.

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
