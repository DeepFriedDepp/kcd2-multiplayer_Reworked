# WO-126 Part A — progress

Session 2026-09-26, unattended, one pass. Findings are in
`docs/WO-126A-quest-map.md`. This file covers the method, the files read, the
tools used, the decisions taken without asking, and what is still
(inconclusive).

## 1. Constraints kept

| constraint | how |
|---|---|
| read-only; safe while the maintainer plays | nothing launched: no game, launcher, agent or relay. No REST console, no input, no build. Nothing written into the game's folders |
| read the game's files and the repo only | paks and binaries from the Modding Tools install were read in place. Pak entries were extracted to the session scratch folder. **No save file was opened**: save anatomy comes from the committed WO-112/115/125 docs |
| keep the machine usable | every Python process set itself to `BELOW_NORMAL_PRIORITY_CLASS` first. The Ghidra wrapper set its own priority to BelowNormal before starting Java, which inherits it |
| reuse Ghidra projects and notes | no fresh import or analysis. The two functions that needed decompiling were in the WO-111 Framework and GUIModule projects, opened `-readOnly -noanalysis`. Everything else came from exports, strings and RTTI, which cost seconds |
| commit the findings docs only | two files under `docs/`. Scratch scripts and data stay out of the repo |
| privacy and copyright | no paths, hosts, accounts or IDs of people; no external project names. Game text is cited by ID only. Quest titles are the ones already committed in `docs/WO-94-mainquest-registry.csv` |

## 2. Method, by phase

1. **Where quest state lives.**
   * Save side: the WO-112 chunk map and the WO-115/125 splice results
     (repo-verified docs), cross-checked against what the binaries serialize.
   * Live side:
     * exports and RTTI of ConceptModule, QuestModule, DialogModule and
       GUIModule;
     * the class names behind WO-97's live `FindNode` vtables;
     * signal and slot type strings;
     * the HUD sink's RTTR registration.
   * The save-marker path was **decompiled**: Framework
     `C_PlayerProfileWHManager::InitiateSaveGame` (RVA 0xEFDE0),
     `EnqueueAutoSave` (0xEF9E0) and `QuickSave` (0xEF8C0). Then import
     tables settled which modules call which function: PlayerModule imports
     only `EnqueueAutoSave`; DialogModule, GUIModule and WHGame import
     `InitiateSaveGame`.
2. **The old machinery.**
   * A background read-only audit of the WO-90..99.5 code at HEAD `0fa9fc1`,
     with file:line evidence for every piece. I spot-checked it:
     * the registry block and fire path in `kdcmp.lua`;
     * the stale-marker path in `GameBridge.cs`;
     * the fingerprint newest-save path;
     * the relay 0x37 gate;
     * `port_watch`'s gate.
   * Old field findings were classified against the shared-world facts from
     WO-102..129 (repo-verified docs).
3. **Conversations.**
   * Shipped Lua `BasicAIActions.lua` (talk hint, `OnTalk`), DialogModule
     strings and exports, the console help, the Warhorse scriptbind reference
     and `defaultProfile.xml` action maps.
   * Committed test logs (open-world dialogue lines) and WO-112's D1–D4
     observations.
4. **Cutscenes.**
   * `Libs/Tables/ui/cutscene.xml` (types and properties).
   * GUIModule strings and exports.
   * A Ghidra anchor pass over `C_CutscenePlayer`, `C_IngameCutscene`,
     `C_CutsceneHandler`, `C_InteractiveSceneManager`, Fader/SkipTime and
     TrackView strings.
   * Level holder entities in both levels' `objects_mission0.xml`.
5. **Catalogue.** A scratch extractor over the 32 main quests, described in
   §5 so it can be re-run.
6. **Part B map.** Written from phases 1–5. It compares options and makes no
   pick.

## 3. Files read

**Repo** (HEAD `0fa9fc1`, 0.30.0):
* `docs/DECISIONS-coop-design.md`.
* WO-58 test logs.
* WO-90, 92, 94, 95, 96, 97, 98, 99, 99.5, 102, 107, 112, 115, 122, 123, 124,
  125 and 127 findings or progress docs.
* `docs/WO-94-mainquest-registry.csv`, `docs/WO-96-mainquest-objectives.csv`,
  `docs/WO-96-objective-triggers.csv`.
* `kdcmp/Data/Scripts/Startup/kdcmp.lua`: the Shared Quests section
  14006–15136, the WO-102 block, puppet pause and hold, and `handleAction`.
* `dotnet/KcdMp.Client/`: `GameBridge.cs` (story, time-skip, reconnect and
  peer sections) with its Wo122/124/125/127 partials, `StoryBeat.cs`,
  `LogTailGameTransport.cs`, `SaveGameReader.cs`, `StoryFingerprint.cs`,
  `QuestObjectiveRegistry.cs`, `ClientConfig.cs`, `KcdMp.Client.csproj`.
* `dotnet/KcdMp.Server/Features/`: `ClientHandling/ClientSession.cs`,
  `ClientHandling/ClientHandler.cs`, `Tcp/TcpBroadcastService.cs`.
* `dotnet/KcdMp.Protocol/Protocol.cs`.
* `native/KCDMP/`: `concept_read.cpp`, `dllmain.cpp`, `main_thread.cpp`,
  `pipe_server.*`, `CMakeLists.txt`.
* `tools/`: `Verify-Install.ps1`, `Build-Installer.ps1`,
  `Build-MainQuestRegistry.ps1`, `Find-ObjectiveTriggers.ps1`,
  `Audit-ObjectiveFixHazards.py`, `Probe-ConceptRead.ps1`, and the quest
  `Test-*Synthetic` suites.
* `KCDMP_launcher/Pages/Home.razor.cs`, for the build check, read by the audit.

**Game** (Modding Tools install, read in place):
* `Scripts.pak`: 26,442 entries.
  * `Quests/Final`: 21,665 entries, of which the 32 main quests' subtrees are
    6,711 files.
  * `Scripts/Entities/AI/Shared/BasicAIActions.lua`.
* `Tables.pak`:
  * `Libs/Tables/ui/cutscene.xml`;
  * `Libs/Tables/player.xml`;
  * the player soul table;
  * `rpg/game_over.xml`, `game_over_type.xml`;
  * the script-context table.
* `IPL_GameData.pak`: `Libs/Config/defaultProfile.xml`,
  `interaction_filter.xml`, `keybindSuperactions.xml`.
* Both levels' `level.pak`: `mission_mission0.xml` and `objects_mission0.xml`
  (34,308 and 91,084 entities).
* The console help pages that ship with the tools, and the scriptbind
  reference.
* **Binaries** (strings, exports, imports, RTTI): ConceptModule, QuestModule,
  DialogModule, GUIModule, Framework, WHGame, EntityModule, PlayerModule,
  RPGModule, XGenAIModule, CryMovie, CryAction, DatabaseModule.

## 4. Tools

| tool | use |
|---|---|
| Python 3.14, standard library | `zipfile` pak listing and extraction; `xml.etree` parsing; the extractor and summaries |
| small PE readers (Python, written for this pass) | exports, imports, sections, strings with RVAs, MSVC RTTI type descriptors |
| Ghidra 12.1.3 headless | `-readOnly -noanalysis` on the reused WO-111 Framework and GUIModule projects. Four runs of two small read-only scripts: (1) string anchor → containing function → decompile; (2) decompile by address |
| background agent | the Phase 2 file:line audit of the repo, read-only |

**Side effects.** Files were written only to the session scratch folder. The
two reused Ghidra projects held transient lock files while open. I checked
afterwards: none left, and the project files are unchanged.

## 5. The catalogue extractor, so it can be re-run

1. **Find the quests.** List `Scripts.pak`. Pick the `Quests/Final` quest
   roots whose `<Quest …>` tag carries a `ProductionCode`. That gives 32,
   matching the WO-94 registry.
2. **Extract the XML.** Take each root XML and its same-named folder
   subtree.
3. **Count and extract by tag.**
   * Count nodes by tag.
   * Dialogues (`Dialog`, `ForcedDialog`, `FaderDialog`): class, role list,
     initiator, and whether any out-port is wired.
   * `CutsceneHandler`: holder alias and ports. `PlayTrackView` is counted as
     a background sequence.
   * `GameOver`: reason id, mapped to its name in `game_over.xml`.
   * `AdvanceWorldTime` / `PassLongTime`: time-of-day targets.
   * `PlayerAction_*`: teleports, bed scenes, gear.
   * Also: `SwitchPlayer` / `switchplayer` targets, `SwitchLevel`, door
     locks, trespass areas, input filters, saves and locks, kills and
     permadeath.
4. **Resolve cutscene holders.** A quest's asset registry is the level's
   `SmartObjectHolder` named after the quest; its `asset['<alias>']` links
   point to entity ids.
   * Follow each alias to the `CutsceneHolder`, and read `esCutsceneName` and
     the `teleport` / `fastForward` / `cutsceneData` links. A
     `PlayerLinkRerouter` fast-forward means "player repositioned".
   * Look up the type and properties in `cutscene.xml`.
5. **Attach the nearest objective.** Match the node's module path against the
   display paths in the WO-96 objectives CSV. This is a heuristic.

## 6. Decisions taken without asking

1. **No save opened**, including throwaway ones. The work order limits
   reading to paks, binaries and the repo, and WO-112/115/125 already mapped
   the save.
2. **"With the player"** means the dialogue's roles include `HENRY` /
   `JINDRICH_NEMUZE_Z_MAPY` or `BOHUTA_PLAYER` / `BOHUTA_NEMUZE_Z_MAPY`. The
   plain `BOHUTA` role is Godwin as an NPC.
   * The first pass counted it as the player, which inflated the counts.
   * Corrected before writing.
3. **Forced sleep** means `PlayerAction_WakeUp*` only. The `wake_up` library
   module turned out to be an NPC utility.
4. **Fights.**
   * A module counts if it holds combat nodes: duel behaviours, skirmish and
     fight starts, battle groups, ladders, gate bashing, `guardarea`.
   * Each is deduplicated to its own module, so the catalogue counts 165.
   * §5.3 lists 118. Registration, streaming, background, ladder-control and
     crime-check modules are counted but not listed.
   * Staged fights (`divadlo_*` that are real fights) are kept. Only
     background sequences are dropped.
5. **Both / host rule.** A mapping criterion, stated in the doc, not a design
   choice.
6. **M30** is counted through M50, because M30 instances M50's module tree.
7. **Godwin objective ranges** come from module order around the switch
   nodes. The switch nodes are data-verified; the range edges are inferred.
8. **Dialogue-holder teleports** are aggregated per level, not per quest:
   dialogue holders did not resolve by alias the way cutscene holders do.
9. **Registry defects** found by the audit (stale joiner marker, fingerprints
   against the solo world, no role gate on Haste) are recorded, not fixed.
   Part A changes no code.

## 7. What stays (inconclusive)

* All eleven live questions in `WO-126A-quest-map.md` §6.2.
  * Most important for Part B: Q1 (native objective read), Q2 (one in-port
    pulse), Q3 (the joiner's copy advancing or stalling), Q4 (resume before
    the timeout) and Q8 (joiner time jumps reaching the host).
* The `I_UIHudEventsQuest` vtable layout, and whether a proxy there sees
  every event.
* `C_Node::ActivateNode` / `DeactivateNode` / `Reset` semantics.
* The meaning of `StopWorldTime` on an Ingame cutscene. Only its string and
  path were read.
* Whether cutscene positioning completes when participants are suspended.
  Whether a dialogue's NPC-freeze step completes on an NPC that is already
  suspended.
* Whether `confirm` / `cancel` reach the mod's key hook (old prompt stray
  trigger).
* Whether a lost `OnCutsceneEnd` line (a load mid-cutscene) can leave joins
  deferred as "cutscene".
* How often joiner-local time jumps happen (H2).
* 29 cutscene handlers and 17 background sequences with no resolved type;
  per-quest dialogue-holder teleports.
* What a bystander sees and hears of the other player's cutscene or
  dialogue.
