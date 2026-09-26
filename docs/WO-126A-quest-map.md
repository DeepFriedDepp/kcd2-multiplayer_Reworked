# WO-126 Part A — the quest-sync map

Session 2026-09-26. **Static research only**: nothing launched, no console,
no input, no build, nothing written into the game's folders. Read: the
Modding Tools install's paks and binaries, and the repo. Method, files, tools
and gaps: `docs/WO-126A-progress.md`. Scope: the 32 base-game main quests
(`ProductionCode` M01–M51). Side quests and DLC are out by the maintainer's
rule.

Evidence marks: **(code-verified)** read in a binary · **(data-verified)**
read in game data · **(repo-verified)** read in our code or committed docs ·
**(observed)** only where an earlier WO observed it live, with the WO named ·
**(inconclusive)**. A guess says so. Game text is Warhorse's: lines and
quests are referred to by ID only.

Placeholders: `<MT>` Modding Tools install, `<repo>`. RVAs: this install's
binaries, image base 0x180000000.

---

## 0. Answer first

**Where quest state lives, and how to read and set it.**

* All main-quest progress is **concept-graph state**. In a save it is the
  ConceptModule chunk (`01f6/730a`): quest `State` nodes, objective logs, typed
  `State` "variables", timers, and the dialogue sequence-used ledger (dialogue
  nodes serialize inside the concept state, code-verified §1.1). A join
  carries it exactly. After the join it drifts: **both machines keep running
  their own copy of the graph**, and nothing carries a change across.
* **Cheap native read exists.** `C_ConceptManager::FindNode("Barbora.<level>.<quest>")`
  was resolved live (WO-97); the node it returns is a `C_Quest` (RTTI,
  code-verified today). `C_Quest::GetObjectives` / `GetObjective(name)` and
  `C_Objective::GetLogType` / `GetLastUpdateTime` are **exported public
  getters** (code-verified). Never called live.
* **Setting on another machine has three routes, none clean.**
  1. Haste: `wh_concept_HasteTrigger <quest>.<trigger>` (live, WO-94). It
     drives the real graph edge, but brings teleports, cumulative replays and
     side effects.
  2. Native in-port pulse (`I_Port` slot 15 on a `Set*` / `start` port;
     WO-97/99.5). Mapped and gated, **never fired**.
  3. The host's save, loaded at join or rejoin (live, WO-124/125). Exact, but
     costs a 12–60 s load.
  There is no state setter anywhere (WO-92).
* **Events.** Every objective change fires QuestModule signals
  `<E_LogType, C_Objective&, C_Quest&>` and `<E_QuestProgress, C_Quest&>`.
  They reach the HUD through one sink that the exported
  `C_QuestModule::SetUIHudEvents` can replace (code-verified).
  * The log line the old layer used (`InitiateSaveGame() … questNameOverride`)
    **is never printed on a locked joiner.** Quest checkpoint saves go
    PlayerModule → `EnqueueAutoSave`, which refuses under a script lock
    *before* `InitiateSaveGame` runs (code-verified §1.4).
  * Cutscene and dialogue starts are logged **on both machines**, with the
    quest module path and the dialogue's concept path.

**What of the old work to reuse.** None of it checks shared-world mode; all
of it still runs in 0.30.0 (repo-verified, §2).

| retire | reuse | rework |
|---|---|---|
| the Haste catch-up prompt: on the host it fires into the saved world | the concept read (`FindNode`) | divergence detection: the joiner's marker is stale for a whole session |
| save-file fingerprints on the joiner: they compare against the joiner's *solo* world | the cutscene edge channel | |
| | the objective registry (626 objectives → concept paths) | |
| | the WO-97 hazard audit tool | |
| | the wire kinds | |
| | the `DialogTwin_` exclusion | |

**Conversations.** A player conversation is a request the NPC's brain must
pick up. On the joiner every host-owned NPC is suspended, so the request times
out (observed, WO-112). Under host authority the joiner cannot claim an NPC
either (repo-verified, WO-102).

Quest-forced dialogues bypass the brain and **do** start on a suspended copy
(observed, WO-112). So the joiner's own quest copy can drop the joiner into
a local forced conversation the host never has.

A conversation's outcome exists only in the copy where it ran (dialogue
out-ports feed quest `State` ports). 291 of 335 forced and 373 of 603 fader
conversations with the player feed the graph (data-verified). **The host's
outcome must count.**

**Cutscenes.** Every main-quest cutscene is started by the quest graph
(`CutsceneHandler` → holder → cutscene-table type). The table has
Rendered / Ingame / Fader / SkipTime / FastTravel / Text / TrackView types.
An Ingame cutscene can:
* set the world time of day (61 of them);
* set the weather;
* load level layers;
* dispose of corpses;
* reposition the player;
* take the exclusive `cutscene` action map.

(data- and code-verified, §4.)

`wh_ui_PlayCutscene` plays **Rendered cutscenes only** (code-verified).
Anything else can be started on the joiner only through its own graph.

**Catalogue (§5).** 32 quests, 626 objectives, 6,711 subtree files. With the
player they hold:

| moment | count |
|---|---|
| forced conversations | 335 |
| fader conversations | 603 |
| player-started conversations | 115 |
| cutscene handlers | 337 |
| background sequences | 141 |
| fight-bearing modules (118 listed in §5.3) | 165 |
| fail states (46 distinct) | 81 |
| time-of-day sets | 128 |
| player outfit overrides | 38 |
| player teleports | 14 |
| level switches | 2 |
| player switches | 21 |

**Non-Henry (§5.4).** The only other playable character is Godwin
(PlayerId 1, data-verified). Eight Godwin stretches, each pinned to its
switch node and objective range:
* the prologue: M30 plus M50's siege modules;
* M05 end;
* M10;
* M37a;
* M37b;
* M46;
* M48c;
* the endgame: M50.

**Part B map (§6).** The models:
* host-authoritative mirroring;
* joiner actions applied on the host;
* rejoin/reload as the fallback;
* combinations.

§6 gives, for each, what the engine offers and what breaks, eleven smallest
live tests, and the hazards to the host's save, to quest progress and to
lasting sync.

---

## 1. Where quest progress lives

### 1.1 In a save

Chunk map from WO-112 §1.2; join behaviour from WO-115 §2 / WO-125 §1.2
(repo-verified docs). New today: the dialogue ledger's home and the joiner's
journal/codex split.

| block | holds | at a join the joiner gets | afterwards |
|---|---|---|---|
| `01f6/730a` ConceptModule | `<Roots>` XML: every non-default node state — quest `QuestProgress` States, objective `Logs` (`Started`/`Updated`/`Completed`/`Canceled` + `UpdateTime`), typed `State` "variables" (enum/bool/int), timers, random-event places | the host's, byte-identical (observed WO-115, save compared) | each machine advances its own copy |
| (same chunk) dialogue ledger | sequences used per dialogue node. DialogModule warns "Sequence '%s' cannot start with a digit. **Concept serialization** will not work." — dialogue nodes (`C_DialogueWrapper`) serialize inside the concept state (code-verified); WO-112's chunk map has no DialogModule chunk | the host's | per machine; no setter exists (WO-92: `SetSequenceUsed` 0 hits) |
| `01f6/7303` QuestModule | activity state (activity names, WO-92 §5.2) | host's | per machine |
| `01f8/7302/000A`, `0006` EntityModule | quest-item manager; quest-added stash items | host's; the joiner's quest-class items are stripped at splice (repo-verified, WO-115) | per machine |
| `01f8/7301` GUIModule | tracked quest, journal UI state, custom map marker | **the joiner's own** (spliced from the joiner's save, WO-115 §2) | per machine. A tracked quest missing from the host world: (inconclusive) |
| Henry `0x137E` perks | codex entries (quest rewards are perks, WO-112) | the joiner's own | quest rewards land on the Henry of the machine whose graph fires them |
| Henry stat id 8 `storyProgress` | story progress, granted by `StatReward Type="storyProgress"` at quest completions (data-verified, 22 nodes) | **the host's** (written at splice, by decision) | the joiner's copy grants its own completions to the joiner; overwritten at the next join |
| Henry `0x12FF` renown | renown total | the host's (by decision) | per machine |
| `01f8/7308/352D` map knowledge | POIs, fast-travel points | the joiner's own | per machine |
| souls / XGenAI | NPC state, script contexts set by quests (869 `SetEntityContext`, 197 `SetGameContext` in the main quests, data-verified), crime memory, dialogue mailboxes | the host's | per machine; host-owned NPCs are streamed and suspended on the joiner |
| `01f7` CryAction, `01f9/1f90` Framework | GameTokens, FlowSystem, global script variables | host's | per machine |

**What drifts on the joiner** after the join (repo-verified where marked;
inference where marked):

* Nothing replicates quest state after the join (repo-verified: the audit in
  §2; no quest-state channel exists).
* The joiner's copy advances only on triggers keyed on the joiner's own player.
  `AreaCheck`, player assets and item triggers use the local player
  (data-verified: the graph's `player` asset alias).
* Steps that wait on NPC behaviour, such as an NPC walking somewhere or a
  brain accepting a dialogue, should stall on the joiner, because host-owned
  NPCs there are suspended (WO-107/108 lever, default on). **Inference;
  a live test is §6.2 Q3.**
* The host's copy never sees the joiner at all. The joiner's avatar is a
  `kcd2mp_*` NPC, not `$__player` (repo-verified, WO-112 §4.3.1).
* The journal, map marks, HUD notices, codex, story stat, quest items,
  dialogue ledger, crime and reputation from quest events all follow the local
  copy.
* Time and weather set by a quest on the joiner move the joiner's clock and
  sky, and can reach the host (§6.3 H2).

### 1.2 Live: the read and set surface

| surface | read cheaply? | set on another machine? | through | side effects | evidence |
|---|---|---|---|---|---|
| objective marker line `InitiateSaveGame() … questNameOverride: '@qname_…\|@…'` | yes, but checkpoint-coarse (6 per 90 min, WO-90) and **host only** in a shared world | — | kcd.log tail | none | code-verified §1.4; repo-verified parser `StoryBeat.cs:43-71` |
| save file ConceptState | full state, offline, in 14–48 ms (WO-98) | only by loading the file (join, rejoin, reload) | `SaveGameReader` | a load: 12 s in-world (WO-125), 52–60 s from the menu (WO-124) | repo-verified; observed WO-96/124/125 |
| `C_ConceptManager::FindNode(path)` | yes; per frame is possible | — | native (`concept_read.cpp`, pipe `0x08`, no agent caller) | none | observed WO-97 (resolution only) |
| `C_Quest` / `C_Objective` getters | yes: `GetObjectives`, `GetObjective(name)`, `GetLogType`, `GetType`, `GetOrder`, `GetObjectiveName`, `GetLastUpdateTime`, `Logs(fn)`; `C_Quest::GetLastUpdateTime`, `GetLevelId` | — | native, **exported QuestModule functions** (`QEBA`, non-virtual) called on the `FindNode` result | none | code-verified (exports; RTTI `C_Quest` at QuestModule+0x93FA8 = the vtable WO-97 saw live) |
| data-port read | yes: `C_Node::GetPort` → the concrete port's `Read` (slot 16). Trigger ports only have the empty base | — | native | none | code-verified WO-99.5 |
| RTTR `Quest.Progress` (`C_TypedPortRef<E_QuestProgress>`) | read by the registered conversion | no (no reverse conversion, WO-92 §5.1) | RTTR | none | code-verified WO-92; (inconclusive) live |
| `wh_quest_DebugQuestLog`, `wh_concept_Debug*` | screen only, never in the log | — | console | none | code-verified WO-92 §7 |
| Haste trigger | — | **yes**, 1,014 triggers in the 32 quests (WO-94) | console `wh_concept_HasteTrigger <quest>.<trigger>` (Modding Tools build) | cumulative prerequisite replays; `ConsoleCommands` teleports (`goto` / `playerGoto`; 324 values name a level entity in the main quests, WO-94); every `On<State>` consumer of the transition (cutscenes, items, saves); repeats its side effects on re-fire | observed WO-94/95 |
| native in-port pulse | — | **mapped, never fired**: `FindNode` → `GetPort` → slot 15 on an In port (`State.SetDone`, `module.start`, `cutscenehandlerN.EnqueueCutscene` …) | native; gated by class, direction and `IsEmpty` | exactly the graph's own consumers of that edge; no inverse; void return (WO-43 trap) | code-verified WO-97/99.5 |
| `C_Node::ActivateNode` / `DeactivateNode` / `Reset(bool)` / `Hibernate` / `Wake` | — | exported mutators; semantics unknown | native | (inconclusive) | code-verified WO-92 §5.2 |
| HUD quest notice | — | presentation only: `C_UIHudEvents` methods `ShowQuestEvent` (parameters include `uiName`, `localizableName`, `questType`) and `ShowObjectiveEvent` are RTTR-registered | RTTR by name | a notice with no state behind it | code-verified (RTTR `method_wrapper` + name strings); (inconclusive) live |
| codex entries | — | Lua `AddPerk(def)` / `RemovePerk(def)` | Lua | none seen | observed WO-112 |
| script contexts | `soul:HasScriptContext` (Lua, WO-64/65) | native, through `C_ScriptContextManager` (WO-68, crime) | native | quest behaviour switches | repo-verified WO-65/68 |

Engine enums (code-verified WO-92, data-verified today):
* `E_QuestProgress` = None / Active / Done / Failed.
* Objective log declarations (`Type=`) in the 32 quests' XML: `Started` 626
  (one per objective), `Completed` 684, `Updated` 211, `Canceled` 138.

### 1.3 The engine's quest classes

| class | module | role | read | write |
|---|---|---|---|---|
| `C_ConceptManager` | ConceptModule | graph root; roots `Barbora`, `Haste` (live, WO-97); database `brambora` in every XML and log path | `FindNode` | — |
| `C_Level` | ConceptModule (+0x41E868) | `Barbora.trosecko` / `.kutnohorsko` | via `FindNode` | — |
| `C_Quest` | QuestModule (+0x93FA8) | one per quest; `quest_progress` out-port | getters (exported) | only through its `State` in-ports |
| `C_Gameplay` | QuestModule (+0x93DE0) | sub-module (e.g. `v_hospode.pytle_a_hadka`) | `FindNode` | its In ports (`start`, …) |
| `C_Objective` / `C_LogBase` | QuestModule | journal view over a `State` (no setters, WO-92) | getters (exported) | — |
| `State` node | ConceptModule | the real state; `Set<Value>` in-ports; `.<Value>` level bools and `.On<Value>` one-shot edges (~1 read in 4 is edge-triggered, WO-92) | data port | In-port pulse |
| `C_DialogueWrapper` | DialogModule (+0x23C288) | a dialogue node (`Dialog`/`ForcedDialog`/`FaderDialog`) | `FindNode` | In ports; the ledger has no setter |
| `C_CutsceneHandler` | GUIModule | quest node; ports `EnqueueCutscene`, `PlayCutscene`, `FinishCutscene`, outs `OnQueued`/`BeforePlay`/`AfterPlay`/`OnFinished` (data-verified) | — | In-port pulse |
| `HasteTrigger` | ConceptModule | named jump entry | — | console |
| `C_QuestModule` | QuestModule | `GetQuestManager` (no exports behind it), `GetUIHudEvents` / `SetUIHudEvents`, `SaveGame` / `LoadGame` | exported | — |

(code-verified: exports, RTTI, strings; WO-92/97 for the ConceptModule
internals.)

### 1.4 The events, and where the mod could listen

| event | where | host | joiner | carries | evidence |
|---|---|---|---|---|---|
| `InitiateSaveGame() type: %s, overwriteSaveId: %d, questNameOverride: '%s'` | kcd.log | yes, at every quest checkpoint save | **no.** PlayerModule's quest `SaveGame` node imports only `EnqueueAutoSave`. Under a script lock `EnqueueAutoSave` logs `AutoSave is disabled under a script lock '%s'` (the lock list, no quest) and returns before any `InitiateSaveGame`. `InitiateSaveGame` logs its line *before* its own lock checks, so the only joiner-side marker is a dialogue crucial-decision save (DialogModule calls `InitiateSaveGame` directly), followed by "…is ignored, because of script locks" | quest + objective string IDs | code-verified: Framework `EnqueueAutoSave` 0xEF9E0 and `InitiateSaveGame` 0xEFDE0 decompiled; PlayerModule and DialogModule import tables |
| `CutscenePlayer::{OnCutsceneInitialized\|PlayCutscene\|OnPositioningFinished\|OnCutsceneEnd\|FinalizeCutscene\|Interrupt\|ReleaseScene} called for <Type> cutscene '<name>' with holder '<h>' from module '<brambora::Barbora::level::quest::…>'` | kcd.log | yes | yes, for the joiner's own copy's cutscenes | cutscene, type, holder, quest module path | code-verified GUIModule strings 0x43B0D0…; observed WO-99.5 |
| `New dialogue '<Barbora.… concept path> (<type> - Id: N) (<origin>)' is starting. Params: souls = '…' forced = true\|false, forced decision = …` | kcd.log | yes | yes | **the dialogue's concept path**, participants, forced flag | code-verified DialogModule 0x21C5E0; observed in committed test logs (open-world dialogues) |
| `Soul '%s' requested dialog. Assigned id is %d` · `Canceling dialog request id %d … Request timed out.` · `Attempt to start dialog id %d … not in pending request list` · `Attempting to start new dialogue (runtime id '%d') …` · `Dialog ending [%s]` | kcd.log | yes | yes | request lifecycle | code-verified; observed WO-112 |
| `<HasteTrigger> name:'<full path>' is being triggered from haste` | kcd.log | the firing machine | the firing machine | the Haste path | observed WO-94 |
| `Switching to player %d` (PlayerSwitcher) | kcd.log | yes | the joiner's copy | player id | code-verified PlayerModule strings |
| QuestModule signals `C_Signal<E_LogType, C_Objective&, C_Quest const&>` and `C_Signal<E_QuestProgress, C_Quest&>` | native | yes | yes | objective, log type, quest progress | code-verified (signal type strings; GUIModule `C_UIQuestLog` slot signatures) |
| HUD sink `I_UIHudEventsQuest`, set by the exported `C_QuestModule::SetUIHudEvents`, read by `GetUIHudEvents` | native | yes | yes | every quest/objective HUD event | code-verified exports; a pass-through proxy is the cheapest listener. Vtable layout **(inconclusive)**, §6.2 Q5 |
| Lua callbacks from the quest graph | — | none | none | — | data-verified: no Lua/script node class in the 32 quests; 4 `Trace` nodes |

---

## 2. The old machinery, audited

Full file:line audit ran this session (read-only). Every piece is compiled
and live in 0.30.0, and **none of it checks `mp_shared_world`**
(repo-verified). Verdicts are for one shared world.

| piece (WO) | wired? | what it does today | fits one world? | verdict |
|---|---|---|---|---|
| main-quest registry `KCD2MP_MAINQUESTS` (94); `Build-MainQuestRegistry.ps1` | yes: 32 quests, 53 fireable beats, `kdcmp.lua:14086-14207`; generator offline | scope filter + beat list for proximity and prompts | the quest list yes; the catch-up beats no | **rework**: keep the quest list (codes, XML names, marker keys, levels) as Part B's scope; drop the beats |
| narrow fix table `KCD2MP_OBJECTIVE_FIXES` (17) + hazard blocklist (5) (96/97); `Find-ObjectiveTriggers.ps1`, `Audit-ObjectiveFixHazards.py` | yes, `:14209-14252` | offers F11 "grant objective" from a fingerprint gap | partly: the only vetted narrow setters | **rework**: candidate apply-set for mirroring; the audit tool vets any new trigger |
| readiness prompt + F11/F12 + `mp_quest_*` (94/96/98) | yes; commands registered unconditionally (`:13607-13618`); no role or world check before `ExecuteCommand` (`:14854-14892`) | fires `wh_concept_HasteTrigger` on the machine that pressed. The accept set also holds `confirm` / `cancel`, which are real action names in the shipped profile; whether they reach the hook is (inconclusive) | **no**: on the host it mutates the world the host saves; on the joiner it mutates a throwaway copy | **retire in a shared world** (hazard H1). Keep the key plumbing for Part B prompts |
| proximity approach (94) | yes, 1 Hz (`:14354-14394`) | announces nearby beats of the local quest | no | **retire** |
| divergence detection (90/96) + `WAITING_FOR_PEER` | yes, logtail transport | compares local vs peer objective markers | **no, and misleading**: the joiner prints no markers (§1.4); its `_localObjective` is seeded from the tail's last marker and survives joins, loads and reconnects (`GameBridge.cs:1468-1474, 1801`); it is sent to the host on first contact (`:4427-4435`). So the pair compares the joiner's **solo-world** objective against the host's | **rework**: the host's marker stays a coarse clock; a joiner-side source must come from §1.4's native events |
| fingerprints (96): `SaveGameReader`, `StoryFingerprint`, `QuestObjectiveRegistry`, kind 5 | yes; registry embedded (`KcdMp.Client.csproj:48-51`) | compares a peer's objective bits with "our newest save" | **no on the joiner**: `FindNewestSave` returns the joiner's own solo save (host copies are moved out within ~1.6 s, WO-125); host fingerprints raise false QUEST-GAP toasts, and `mp_quest_off` does not stop them (`kdcmp.lua:14740-14750`) | **retire the comparison; reuse the parts**: the 626-objective registry maps objectives to concept paths for native reads; the host can still fingerprint its own saves |
| hazard logging `CATCHUP-HAZARD` (94) | yes, dormant outside a 120 s window | tags deaths, teleports, clock writes, chain suspension | the hooks yes | **reuse** the hooks as story-side-effect instrumentation, re-keyed to a mirror window |
| cutscene edge channel, kind 6 (98) | yes; now read by WO-118 detach, WO-123 join deferral, WO-127 leash | logs and relays Rendered/Ingame starts and ends | yes | **reuse**; add the module path and the other types; add a reset on load (a lost end line defers joins as "cutscene", inconclusive) |
| native concept read (97/99.5): pipe `0x08`, `port_watch` | compiled (`CMakeLists.txt:12`); `0x08` has no agent caller; `port_watch` runs every frame, armed only by a `kcdmp-concept.txt` + `FIRE` token (`concept_read.cpp:412-431, 685-712`) | resolve nodes; read or fire ports | yes as a primitive | **reuse `FindNode`; rework** into a real read (the §1.2 getters) + a gated apply; a file-armed trigger with no session or role gate should not stay reachable in sessions (H3) |
| wire `0x37/0x38`, kinds 1–6 | yes; relay copies verbatim, no authority or kind gate (`ClientSession.cs:639-653`) | story telemetry | yes | **reuse** (room for new kinds; the next free message type byte is still `0x58`, as WO-127 recorded) |
| `DialogTwin_` / `kcd2mp_` exclusion (90) | yes, every path incl. relay | keeps per-machine stand-ins out of sync | yes, still required | **reuse** |
| WO-90 divergence release (180 s stand-off) | dead under host authority (logs `MP-AUTHORITY-VIOLATION` instead, `kdcmp.lua:7575-7581`) | — | no | **retire** (legacy preset only) |
| tests | all quest suites run in the release gate, but they assume `authorityHost=false`; nothing covers shared world or 0x37/0x38 relay round-trips | — | — | **rework** with Part B |
| `Verify-Install.ps1` pins | 2 agent + 4 pak markers (`:101-104, 145-151`) | — | — | any retirement edits them |

**The old field findings, one world later**

| finding (WO) | in a shared world | why |
|---|---|---|
| cutscenes starting ~0.8 s apart (95) | **remains, changed.** Each machine plays a cutscene only when its *own* graph fires it. The joiner gets it only if its copy's trigger fires for the joiner; otherwise it gets nothing | no hold primitive: `Movie.PauseSequences` does not hold a Rendered cutscene (observed WO-99.5); `wh_ui_PlayCutscene` is Rendered-only (code-verified) |
| conversation lockout when one player talks first (95, one sample) | **remains, now structural**: the joiner is locked out of every host-owned NPC | suspended brain → request timeout (observed WO-112) |
| NPC untalkable for one player while the other advanced (95) | **vanishes at the join** (exact state) and **returns** as soon as either copy advances | no live sync |
| catch-up landing at an authored point (95) | **vanishes for joins**; remains for any Haste-based mirror | Haste `goto`s (WO-94) |
| save reverts not closing gaps (95) | **vanishes by construction**: a host reload re-syncs the joiner; the joiner cannot save or revert | WO-125 (observed) |
| "walking corpse" after a scripted fight (95) | **death half fixed**: owner death, WO-122. **Knockdown / hit-reaction half remains**: the puppet hold still gates on dead/KO only (`kdcmp.lua:7299, 7333`) | combat work |

---

## 3. Conversations

### 3.1 How one starts

1. **Interaction.** Shipped Lua `BasicAIActions` (data-verified,
   `Scripts/Entities/AI/Shared/BasicAIActions.lua`).
   * The **talk** hint shows when `self.actor:CanTalk(user.id)` and the NPC is
     not in combat mode, unless it is in an arranged fight.
   * The hint is **disabled** by `soul:IsDialogRestricted(player.id)`, or when
     the *local* `player` is in combat danger or a tense circumstance. The
     `speech_bypassGreyOutByCrime` context overrides this.
   * `OnTalk` is a plain Lua table function:
     `self.actor:RequestDialog(user.id,'',false,true)`.
   * NPC chats use a separate path: `DoChat`, `HasChatRequest`,
     `AcceptChatRequest`.
2. **Request.** `C_DialogManager::RequestDialog`: "Soul '%s' requested
   dialog. Assigned id is %d". It signals the NPC's AI; the message
   "AI failed to send signal %s" exists. The **brain** must pick the request
   up, or `TimeOutRequest` cancels it after `wh_dlg_RequestTimeout`
   (code-verified strings; observed WO-112).
3. **Start.** `StartDialogRequest` → `StartDialogInt` → "Attempting to start
   new dialogue …" → "New dialogue '…' is starting …".
   * A player dialogue is queued through `EnqueuePlayerDialogue` into the
     `InteractiveSceneManager` queue, **the same queue as cutscenes**.
   * "Player dialogues which are not launched from queue are not played during
     interactive scene".
   * (code-verified)
4. **Scene.** Once the dialogue is running:
   * `C_DialogueTwinController::MakeTwin` replaces the participants with
     `DialogTwin_*` stand-ins. The originals are hidden
     (`wh_dlg_ShowOrigActor` exists to *not* hide them). There is special
     handling for player-twin overlap and horses.
   * `C_DialogCameraManager` runs the dialogue camera on the twin rig.
   * `C_PlayerDialogController` prepares the player; an obstacle can be
     placed around the dialogue (`wh_dlg_CreateObstacleForIngameNpcDialogues`).
     The dialogue requests and waits for the **NPC's pause/freeze**
     (`C_PlayerDialogController::UpdatePendingNPCPauseRequests`,
     `C_DialogInstance::OnNPCFrozen`).
   * The exclusive `dialog` action map takes the input (data-verified
     `defaultProfile.xml`: priority minigames, exclusivity 1).
   * A `DialogInstance` time pause stops the world clock (code-verified
     WO-112, DialogModule 0x684C3).
5. **Forced dialogues** (`ForcedDialog`, quest-driven) enter with `forced =
   true`, bypass the brain (observed WO-112 D2), and queue in the same scene
   queue. The message "Trying to enqueue dialogue forced from AI while other
   scene is running" exists.

### 3.2 What it requires and what it locks

| requires | evidence | locks | evidence |
|---|---|---|---|
| dialog system enabled (`wh_dlg_Enable`) | code-verified string "Dialog system is currently disabled" | player input: exclusive `dialog` map | data-verified |
| **a live brain on the NPC** (organic path) | observed WO-112 D3/D4; `wh_dlg_DebugNPCBrain` help: "Brain that NPCs should have assigned in order to start dialogue" | camera: dialogue camera on the twin rig | repo-verified WO-90 |
| **the local player as a participant**, and not animation-controlled | "Attempting to enqueue player dialogue without player as participant"; "Cannot dialog with player when player is animation controlled!" (code-verified) | the NPC: paused/frozen for the dialogue, replaced by a twin | code-verified |
| distance and angle: `wh_dlg_RequestMaxDistance` (squared), `RequestMaxAxisAngle`, `RequestMaxTotalAngle`; `AnalyzeRequest` | console help; code-verified | world time: the `DialogInstance` pause | code-verified WO-112 |
| quest state: the dialogue data must offer a decision (`CanTalk` / `HaveDialogFor`; conditions include `SequenceUsed`); "Dialog between %s and %s disabled by RPG" | code-verified | saves: crucial-decision saves on player-initiated dialogues ("must be a player initiated dialogue") — refused on a locked joiner | code-verified |
| no participant dead or muted | code-verified strings | the scene queue: no other interactive scene | code-verified |

### 3.3 On the joiner today

* Host-owned NPCs near the host are puppets on the joiner. Each is
  **suspended** on puppet start with `wh_ai_PauseNPC` (`kdcmp.lua:4156-4165`;
  the pause lever `authorityPause = true` since 0.26.4; repo-verified).
* Its talk hint still shows, because `CanTalk` is a dialogue-data check and
  not a brain check (data-verified).
* Pressing talk registers a request that **is never attempted and times
  out**. A later resume tries the stale id: "not in pending request list"
  (observed WO-112 D3/D4, one NPC, solo).
* The joiner cannot claim the NPC: under host authority a non-authority never
  emits `npc_claim`, and the relay's claim table is bypassed (repo-verified
  WO-102 §4.2).
* **The joiner's own graph still runs.**
  * A `ForcedDialog` it fires starts even with a suspended NPC
    (`WAITING_FOR_INTERACTION`, observed WO-112 D2).
  * The joiner can therefore be pulled into a local forced conversation that
    advances only the joiner's copy.
  * Whether the dialogue's own NPC-freeze step completes on an
    already-suspended NPC: **(inconclusive)**, §6.2 Q6.

### 3.4 Candidate routes for the joiner to talk

| route | what the engine offers | what breaks |
|---|---|---|
| **R1 resume the copy locally** for the conversation (scoped hand-over of one NPC) | `wh_ai_ResumeNPC` (`C_IntelligentObject::Suspend`/`Resume`, multi-owner context bits, WO-107). A resumed brain acts on a pending request at once (observed WO-112 D4; there the request had already timed out). `wh_dlg_RequestTimeout` is a cvar | host authority allows no second writer (WO-102): the host's stream keeps writing the original entity while the joiner's twin talks. The host's copy keeps its schedule. **The outcome lands in the joiner's copy only** (quest out-ports, ledger, items, money, reputation). Crucial-decision saves are refused under the lock |
| **R2 hand ownership to the joiner** for the conversation | the relay claim/hold machinery still exists but is bypassed under host authority; the host could pause its own copy (`wh_ai_PauseNPC`) | the same outcome problem; the host's copy is frozen mid-schedule; the host's own dialogue with that NPC is blocked meanwhile; the host's graph never hears |
| **R3 run it on the host and mirror it** | `ForceDialog` bypasses brain and positioning; the dialogue runs on the world's owner, so its outcome is the world's | player dialogues need the **local** player as a participant, so roles bind to the host's Henry, the host's input chooses, and the host is locked in the camera. The joiner sees and hears nothing; there is no API to show a remote dialogue |
| **R4 replay the same dialogue on both** (lockstep) | the same dialogue node exists on both copies; `DialogModule.ForceDialog`, `SetPlayerInteractiveState`, `wh_dlg_ForcedDecision` | choices, skill checks (stats differ per Henry), random sequences, the ledger and timing are per machine; the NPC is suspended on the joiner; two outcomes to reconcile |
| **R5 host-only talking** | block the joiner's talk hint (`RestrictDialog` is read by the hint, data-verified; `OnTalk` is wrappable Lua) and ask the host to talk | the joiner never plays a conversation; the joiner's own forced dialogues still pop (§3.3) unless its copy is held |
| **R6 global kill-switch on the joiner** | `wh_dlg_Enable 0` | kills barks, chats and forced dialogues too; untested (WO-90) |

### 3.5 Both players around one conversation

* **Watching or listening.** Dialogues run on one machine. The other machine
  gets only positions. Twins and cameras are local, and `DialogTwin_*` never
  syncs (WO-90).
  * The talker's avatar on the other screen stands still: its original entity
    is hidden and frozen while the twin talks (inference from the twin
    model).
  * Voice audio is played locally. Whether an in-world NPC–NPC dialogue is
    positional for a bystander: (inconclusive).
* **Camera.** On the talker's machine the camera moves onto the twin rig. On
  the other machine nothing happens.
* **Both trying to talk to the same NPC.**
  * On one machine: "Chat request '%d' refused due to all souls being present
    in another dialog", plus clash priorities ("… will be interrupted by" /
    "cannot be interrupted by", code-verified).
  * Across machines: two copies. The host's copy can be in a conversation
    with the host while the joiner's suspended copy times out.
  * Under R1/R2, two conversations with "the same" NPC can run in two copies
    at once, with divergent outcomes. They would need arbitration.

### 3.6 Where conversations advance quests

* Dialogue out-ports are wired into `State` `Set*` and module `start` ports.
  Example: `druhy_dialog_s_ptackem.nos_pytle` → `pytle_a_hadka.start` and
  `rekniPtackoviOPraci.SetDone` (code-verified WO-97).
* In the 32 quests, **291/335 forced, 373/603 fader, 12/115 player-started
  and 111/509 NPC-started** conversations with the player have out-ports
  (data-verified).
* The outcome counts only in the copy where it ran. **The host's must
  count**: the host's save is the world, and the next join overwrites the
  joiner's copy.
* So a conversation either runs on the host (R3/R5), or its outcome is applied
  on the host (R1/R2 plus a host-side apply, §6.1 B).

---

## 4. Cutscenes

### 4.1 How main-quest cutscenes start

1. **Quest node.** A `CutsceneHandler` names a `CutsceneHolder` asset alias
   (data-verified). Its In ports are `EnqueueCutscene` and `PlayCutscene`,
   plus `FinishCutscene` when `AutoFinish=false`. With `AutoPlay=false`, play
   usually waits for a streaming profile: `streamprofileshandling.onloaded` →
   `PlayCutscene`.
2. **Binding.** The quest's level asset registry (a `SmartObjectHolder` named
   after the quest, with `asset['alias']` links) points at a level
   `CutsceneHolder` entity. That entity has:
   * `esCutsceneName`;
   * `teleport` links to tagpoints for participants and horses;
   * `fastForward` links, including `PlayerLinkRerouter` for the player;
   * `cutsceneData`: `IngameCutsceneData` with `esSequenceName` and
     `esGameProfile`, or `SkipTimeCutsceneData` with a `Duration` or
     `TargetTime`.

   (data-verified, both levels' `objects_mission0.xml`.)
3. **Type.** `Libs/Tables/ui/cutscene.xml` holds, per name: Rendered (a
   video), Ingame (a sequence, with optional `Time`, `StartWeather`,
   `EndWeather`, `Checkpoints` and `CopySoulVisual`), TrackView, Fader,
   FastTravel, SkipTime, Text and Credits (data-verified).
4. **Player.** `C_CutscenePlayer` (GUIModule) runs every step and logs each
   one (§1.4):
   1. `EnqueueCutscene` (exported, 0x1456E0) queues it in the scene queue;
   2. positioning — "waiting for positioning of the NPCs";
   3. `OnPositioningFinished`;
   4. `PlayCutscene` — or it waits for the signal when `AutoPlay=false`;
   5. `OnCutsceneEnd`;
   6. `FinalizeCutscene`;
   7. `ReleaseScene`.

   (code-verified.)

In the 32 quests: **337 `CutsceneHandler` nodes**:

| type | count |
|---|---|
| Ingame | 123 |
| Fader | 115 |
| Text | 27 |
| SkipTime | 23 |
| Rendered | 9 |
| FastTravel | 9 |
| Credits | 2 |
| unresolved | 29 |

On top of those, **141 `PlayTrackView`** background sequences (battle and
background "theatre"). The resolved handlers name 289 distinct
cutscenes. 198 of the handlers resolve to holders with teleport links, 54
fast-forward the player, and 61 Ingame ones set a time of day.
(data-verified)

### 4.2 What a cutscene does

**To the player on the machine that plays it:**

| effect | how | evidence |
|---|---|---|
| input | exclusive `cutscene` / `text_cutscene` / `fader` / `no_input` action maps. The `interaction` map, which carries F11, should not be delivered meanwhile (inference from exclusivity); the mod refuses prompt answers during a cutscene anyway | data-verified maps; repo-verified refusal |
| teleports / forced positions | holder `teleport` tagpoints; player placed by the `PlayerLinkRerouter` fast-forward | data-verified |
| fades | Fader cutscenes (115); a sequence flagged as a regular cutscene will not play without a fader | data- and code-verified |
| time | Ingame `Time` → `C_IngameCutscene::SetTime` writes the world time of day (code-verified). `StopWorldTime` opens an "IngameCutscene" time pause (code: the string on that path; semantics inconclusive). Quests also call `AdvanceWorldTime` on `BeforePlay`/`AfterPlay` (data-verified) | code-verified |
| weather | `StartWeather` / `EndWeather` + blend | code/data-verified |
| level layers | `esGameProfile` layer profile loaded for the scene | code-verified string "Failed to load layer profile '%s' for ingame cutscene" |
| corpses | `DisposeOfCorpses` property | code-verified string |
| visuals | sequence actors are `AnimChar` doubles that copy their souls' look (`CopySoulVisual`, `SequenceEntitiesCopyVisual`); the player double copies the **local** Henry (inference) | code-verified strings; scriptbind docs |
| gear swaps | quest side, e.g. `UnequipPlayersArmorSlots` on `BeforePlay` (M33), `PlayerOutfitOverride` around scenes | data-verified |
| player switch | `switchplayer` on `BeforePlay`/`AfterPlay` (all Godwin transitions, §5.4) | data-verified |
| saves | engine locks block saves during cutscenes | code-verified WO-112 |
| mod chains | Rendered freezes every Lua timer chain; Ingame does not | observed WO-95 |

**To a second player standing nearby:**

* **On the host's screen** (the host's graph plays it): the joiner's avatar
  is an NPC with no holder link. It is neither positioned nor hidden, and it
  stays where the stream puts it, in shot or in the way (inference;
  (inconclusive) visually).
* **On the joiner's screen**: nothing plays unless the joiner's own copy
  fires the same handler.
  * The host's avatar freezes where the host's hidden player stands. For a
    Rendered cutscene the host's emitter stops, and stale heartbeats show it
    (repo-verified WO-99).
  * At the end the avatar jumps to where the host was placed.
* **If both copies fire it** (co-located, same state): each machine plays its
  own copy starring its own Henry double. The other player's avatar is not in
  it, and the two start about 0.8 s apart (observed WO-95).
* **World-level effects apply only on the playing machine**: time, weather,
  layers and corpses.
  * Clock divergence is pulled back by time sync only forward.
  * A joiner-side jump can travel to the host (§6.3 H2).

### 4.3 Starting a cutscene on the joiner from the host's signal

* **Rendered only, by console.** `wh_ui_PlayCutscene <name>` refuses anything
  else: "Cutscene '%s' is not a rendered cutscene." (code-verified:
  `C_CutscenePlayer::ConsoleCmdPlayCutscene`, GUIModule 0x1464A0, decompiled;
  `PlayVideoOnly` 0x1458F0 makes the same check). No quest node is on that
  path (inference from the decompile; live: §6.2 Q9). `wh_ui_StopCutscene`
  stops it.
* **Every other type goes through the joiner's own graph.**
  * Pulse the handler's `EnqueueCutscene` (and `PlayCutscene` when
    `AutoPlay=false`) In port natively, or fire a Haste trigger that drives
    the owning module.
  * State it needs first:
    * the owning module awake (not hibernated);
    * the holder's entities streamed and the stream profile loaded;
    * the participant souls present, for positioning. With suspended brains
      positioning may never finish: (inconclusive).
    * the scene queue free: no dialogue or other cutscene.
  * Firing it also fires every downstream consumer in the joiner's copy:
    `AfterPlay` → `AdvanceWorldTime`, `switchplayer`, `SaveGame`,
    `AddQuestItem` and so on.
* **No hold or seek primitive** exists for a quest cutscene (WO-90/95/99.5).

---

## 5. The main-quest catalogue (M01–M51)

### 5.1 How to read it

* Source: the quest XML subtree of each quest (6,711 files), the level
  holders and the cutscene table, all extracted from the `<MT>` paks (the
  same install every WO since 92 read). Counts are node counts,
  (data-verified), except where a column says otherwise.
* **M30 is thin on purpose.** Its battle content is M50's module tree
  (namespace `zoufalaObranaZaBohutu.zoufala_obrana_za_bohutu`), instanced in
  M30's `hibernable`. M50's counts cover both instances (data-verified).
* **Column keys.** Columns not listed here are node counts; "cutscenes" also
  shows `+N?` unresolved holders.

  | column | parts |
  |---|---|
  | talks F·Fd·P·N | conversations with the player as a participant (role `HENRY` or `BOHUTA_PLAYER`, or their `*_NEMUZE_Z_MAPY` variants): **F** `ForcedDialog`, **Fd** `FaderDialog`, **P** player-started `Dialog`, **N** NPC-started `Dialog` with out-ports (barks excluded) |
  | cutscenes R·I·Fa·ST·FT·Tx (bg) | `CutsceneHandler` types Rendered·Ingame·Fader·SkipTime·FastTravel·Text; **(bg)** = `PlayTrackView` background sequences |
  | fights | fight-bearing modules, deduplicated to the fight's own module (§5.3 lists them) |
  | kills·perma·fails | scripted `Kill`/`KillNpc` nodes · `PermaDeath` guards · distinct `GameOver` fail reasons |
  | time sets (cs) | `AdvanceWorldTime`/`PassLongTime` nodes (Ingame cutscenes that set `Time`) |
  | bed·jail | `PlayerAction_WakeUp*` (forced bed scenes) · captivity by hand-read module names |
  | gear outfit·equip·conf | `PlayerOutfitOverride` (29 name a confiscation target, 24 of them the player stash) · equip/unequip ops on the player · confiscation/deletion/inventory locks |
  | player tele · level | `PlayerAction_Teleport*` · `wh::game::SwitchLevel` |
  | locks·trespass·leave·filters | door locks · quest trespass areas · leave-area handlers and invisible walls · player input filters (`no_move`, `no_horse_mount`, …) |
  | B / H | moments counted **both-present** / **host-only** by the rule below |
* **The both / host rule** (criterion for Part A, not a design):
  * **Both-present:** the moment acts on, films, moves or tests the player.
    Conversations with the player, all cutscene types except background
    sequences, scripted fights, fail states, bed scenes, player gear,
    player teleports, level and player switches, input filters.
  * **Host-only:** the moment changes world state that the host's world
    carries and syncs or hides. NPC kills and permadeath (owner death wins,
    WO-122), time sets (the host is the clock), door locks, trespass areas
    (each machine enforces them on its own player), NPC teleports, weather,
    saves, background sequences.

### 5.2 The table

| code | quest | obj | talks F·Fd·P·N | cutscenes R·I·Fa·ST·FT·Tx (bg) | fights | kills·perma·fails | time sets (cs) | bed·jail | gear outfit·equip·conf | player tele · level | locks·trespass·leave·filters | B / H | non-Henry |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| M01 | `prepadeni` Easy Riders | 28 | 4·7·4·10 | 0·4·3·0·0·0 +1? | 3 | 0·0·1 | 5 (0) | 0·– | 0·14·0 | 0 | 0·0·1·13 | 63 / 17 | – |
| M02 | `zachrana` Fortuna | 52 | 6·10·2·15 | 0·4·3·0·0·0 (3) +1? | 2 | 1·1·0 | 7 (0) | 0·– | 0·2·3 | 0 | 0·0·0·3 | 50 / 27 | – |
| M03 | `socky` Laboratores | 8 | 8·12·4·1 | 1·6·1·0·0·0 | 2 | 0·0·1 | 3 (5) | 0·– | 1·2·0 | 0 | 0·0·2·1 | 41 / 12 | – |
| M05 | `svatba` Wedding Crashers | 37 | 25·99·18·1 | 0·3·18·0·0·0 +5? | 5 | 0·1·0 | 4 (0) | 1·– | 2·3·2 | 0 | 1·0·0·5 | 184 / 18 | short Godwin intermezzo at the quest end |
| M06 | `naTroskach` For Whom the Bell Tolls | 16 | 9·19·1·0 | 0·1·2·1·0·0 +1? | 0 | 0·0·1 | 3 (0) | 0·captivity: cell, forced labour | 2·0·1 | 0 | 4·11·0·0 | 37 / 33 | – |
| M07 | `nebakovPruzkum` Back in the Saddle | 27 | 13·31·7·14 | 0·0·10·3·2·1 +1? | 1 | 0·1·0 | 1 (0) | 0·– | 1·3·1 | 2 | 2·8·2·2 | 91 / 22 | – |
| M08 | `mucirna` Necessary Evil | 17 | 12·13·3·2 | 0·2·2·0·1·0 +4? | 3 | 8·2·1 | 6 (0) | 0·– | 1·0·0 | 1 | 2·5·1·1 | 42 / 39 | – |
| M09 | `utokNaNebakov` For Victory! | 20 | 14·14·2·8 | 1·3·4·0·0·0 (6) +1? | 16 | 15·0·2 | 7 (3) | 1·– | 0·2·1 | 1 | 2·3·1·2 | 76 / 54 | – |
| M10 | `bohutovaVlozka` Divine Messenger | 12 | 11·11·0·0 | 0·6·2·0·0·0 | 3 | 6·0·2 | 2 (1) | 0·Henry's part opens in a cell | 2·2·1 | 2 | 1·0·1·0 | 45 / 18 | Godwin obj 0–9; Henry obj 10–11 |
| M11 | `nebakovObrana` The Finger of God | 26 | 20·17·7·4 | 1·5·5·1·0·3 (8) +3? | 11 | 7·2·4 | 10 (5) | 0·– | 2·0·11 | 0 | 0·3·0·2 | 97 / 46 | – |
| M12 | `vezniNaTroskach` Storm | 15 | 5·5·1·1 | 0·8·6·0·0·0 +1? | 1 | 0·0·2 | 4 (2) | 0·gear confiscated, taken back | 1·3·4 | 0; `story_switch_to_kutnohorsko` | 3·1·0·0 | 38 / 29 | – |
| M30 | `posledniPomazani` Last Rites | 6 | 0·0·0·0 | see M50 | – | – | 1 (0) | – | – | 0; `story_switch_to_trosecko` | – | 2 / 1 (+M50) | prologue: all Godwin |
| M31 | `prijezdNaSuchdol` The Sword and the Quill | 8 | 6·9·0·0 | 1·3·5·2·0·1 | 2 | 0·0·1 | 3 (0) | 0·– | 11·11·0 | 1 | 1·4·0·2 | 55 / 16 | – |
| M32 | `sedmStatecnych` Speak of the Devil | 11 | 7·7·0·5 | 0·2·5·0·1·0 (1) | 2 | 2·0·1 | 1 (0) | 0·– | 0·2·1 | 1 | 1·0·2·0 | 36 / 17 | – |
| M33 | `hledaniLichtenstejna` Into the Underworld | 16 | 6·32·1·1 | 0·5·4·3·0·0 | 4 | 0·1·0 | 2 (5) | 1·– | 0·1·0 | 0 | 0·0·2·0 | 58 / 15 | – |
| M34 | `kralovskeStribro` Via Argentum | 24 | 7·36·0·0 | 0·1·2·0·0·0 | 7 | 0·6·0 | 0 (0) | 0·– | 0·0·0 | 0 | 6·2·5·0 | 53 / 28 | – |
| M35 | `zachranaPtacka` Taking French Leave | 15 | 12·13·4·3 | 0·4·1·1·0·4 | 1 | 2·2·3 | 6 (0) | 0·– | 0·0·1 | 3 | 2·0·1·0 | 50 / 32 | – |
| M37a | `setkaniVRatbori1` The King's Gambit | 20 | 21·21·2·7 | 0·7·2·1·0·3 (2) | 1 | 0·1·5 | 3 (7) | 0·– | 1·19·3 | 1 | 4·5·0·6 | 104 / 30 | Godwin obj 8–18 |
| M37b | `setkaniVRatbori2` The Feast | 11 | 6·7·0·2 | 0·3·2·2·0·1 | 3 | 3·0·0 | 1 (3) | 0·– | 0·5·0 | 1 | 2·2·0·1 | 35 / 19 | Godwin: feast and night battle |
| M38 | `sedmStatecnych2` The Devil's Pack | 34 | 11·39·3·2 | 0·3·7·0·0·2 (1) | 7 | 2·0·5 | 2 (0) | 1·– | 2·13·1 | 0 | 0·0·1·0 | 96 / 21 | – |
| M42 | `pogrom` Exodus | 11 | 7·3·6·0 | 0·2·1·0·2·0 (4) | 10 | 8·0·5 | 2 (2) | 0·– | 0·0·1 | 0 | 6·2·1·1 | 39 / 33 | – |
| M44a | `zikmunduvTabor` The Lion's Den | 33 | 16·48·8·1 | 0·3·6·2·1·0 | 5 | 6·1·5 | 1 (3) | 0·– | 1·1·1 | 0 | 2·0·3·0 | 101 / 24 | – |
| M44b | `utokNaMalesov` Dancing with the Devil | 18 | 18·6·13·7 | 0·5·5·1·0·2 (7) +2? | 16 | 5·4·2 | 8 (0) | 1·– | 0·0·1 | 0 | 3·1·1·2 | 79 / 48 | – |
| M45 | `papezskyLegat` Oratores | 23 | 14·34·1·4 | 0·4·3·3·2·3 | 6 | 3·0·2 | 11 (4) | 1·– | 2·2·5 | 0 | 12·3·1·0 | 86 / 55 | – |
| M46 | `prepadeniVlasskehoDvora` The Italian Job | 25 | 24·16·2·11 | 0·13·4·0·0·0 (3) +4? | 9 | 4·1·3 | 10 (6) | 1·– | 2·11·1 | 0 | 5·1·0·0 | 106 / 43 | Godwin obj 0–8; Henry obj 9–24 |
| M47 | `erik` Civitas Pragensis | 10 | 5·15·4·0 | 0·7·1·0·0·1 | 1 | 0·0·4 | 5 (5) | 0·– | 0·0·0 | 0 | 0·0·0·1 | 39 / 16 | – |
| M48a | `oblehaniSuchdole` So it begins… | 31 | 13·15·5·2 | 1·1·3·0·0·2 (25) | 4 | 7·1·3 | 3 (0) | 1·– | 0·1·0 | 0 | 2·0·1·1 | 54 / 58 | – |
| M48b | `rutinaAVypad` Besieged | 23 | 6·25·2·0 | 0·2·1·0·0·0 (32) | 13 | 13·0·1 | 3 (2) | 0·– | 0·2·0 | 0 | 1·0·0·0 | 52 / 60 | – |
| M48c | `hladAZmar` Hunger and Despair | 22 | 14·26·12·4 | 0·4·2·2·0·0 (12) +3? | 14 | 3·0·0 | 5 (4) | 1·– | 2·45·0 | 1 | 3·0·0·3 | 132 / 44 | short Godwin sermon scene |
| M49 | `stealthMiseZaJindru` Reckoning | 5 | 5·4·2·3 | 0·7·1·0·0·0 | 2 | 5·1·0 | 1 (0) | 0·– | 0·1·1 | 0 | 1·1·1·1 | 27 / 18 | – |
| M50 | `zoufalaObranaZaBohutu` Last Rites | 8 | 4·0·0·0 | 2·1·0·1·0·4 (35) | 6 | 2·0·3 | 4 (0) | 1·– | 3·1·0 | 0 | 3·0·0·2 | 31 / 53 | endgame Godwin: obj 0–7 |
| M51 | `finale` Judgement Day | 14 | 6·9·1·3 | 2·4·4·0·0·0 (2) +2? +2 credits | 5 | 2·0·1 | 4 (4) | 0·– | 2·7·0 | 0 | 3·1·0·3 | 49 / 21 | – |

**Reading it.**

* Every quest's story runs mostly through **both-present** moments.
* Host-only moments outnumber both-present ones only in the three siege
  quests M48a, M48b and M50 (background battle sequences and NPC kills).
* M05 (143 conversations with the player), M44a (73), M07 (65) and M48c (56)
  are the conversation-heaviest.
* M09, M44b, M48b/c, M42 and M11 are the fight-heaviest.
* Per-quest IDs (forced conversations, every cutscene by type with its time /
  skip / repositioning notes, fail states, time targets, gear and locks):
  Appendix A.

### 5.3 Scripted fights, flagged separately (feeds the combat work and WO-117)

One row per fight-bearing module:
* **kind** is taken from its nodes: `duel` = `duelbehavior*`; `battle` =
  battle groups, ladders, gate bashing; `skirmish` = `skirmish` /
  `fightstart` / skirmish triggers.
* **nearest objective** is by module path. That is a heuristic; an index of
  0 often means "a quest-wide module".
* Battle-group registration, streaming, background sequences and ladder
  control are counted but not listed.

(data-verified)

| code | fight module (`…parent.leaf`) | kind | nearest objective (index:id) |
|---|---|---|---|
| M01 | `ptackuv_pohyb_koridorem.ptacek_nebo_jindrich_v_ohrozeni` | skirmish | 20:dostan_se_s_ptackem_pryc |
| M01 | `utek.souboj_s_lapkou_na_kraji_utesu` | duel | 22:prezij |
| M01 | `serm_s_ptackem.duel_ptacek_vs_jindrich` | duel | 15:poraz_ptacka_v_duelu |
| M02 | `zachranalibrary.hledaci_a_prepadeni` | skirmish | 0:zastav_krvaceni_ |
| M02 | `zachranalibrary.seekerPatche` | skirmish | 0:zastav_krvaceni_ |
| M03 | `pranyr.cin_m0360t_socky__stocks_dialogue` | skirmish | 0:zjisti_jak_se_dostat_k_bergovovi |
| M03 | `v_hospode.hospodska_bitka` | skirmish | 7:bran_ptacka |
| M05 | `souboj_o_mysku.souboj_script` | duel | 6:poraz_urazeneho_protivnika |
| M05 | `hibernovana_cast.jindra_vyprovokoval_rvacku` | skirmish | 3:pockej_na_bergova |
| M05 | `rvacka.prubeh_rvacky` | skirmish | 20:bran_se |
| M05 | `npc_vs_npc_souboj_fandeni_a_ingame_dialog.duelnpcvsnpc` | duel | 0:najdi_cestu_na_svatbu |
| M05 | `svatba.svatebni_duel` | duel | 0:najdi_cestu_na_svatbu |
| M07 | `intro_a_duel.samotny_boj` | duel | 22:pomer_se_s_michalem_ve_zbrani |
| M08 | `bitva.skirmish_logic` | skirmish | 8:poraz_semina_a_jeho_muze |
| M08 | `mlady_semin_nalezen.souboj_henryho_s_haskem` | duel | 13:poraz_haska_v_duelu |
| M08 | `mlady_semin_nalezen.vyhlazeni_vojaku` | skirmish | 14:zbav_se_haskovych_muzu |
| M09 | `kovar_osina.pestni_souboj` | duel | 8:zajdi_pro_vyzbroj |
| M09 | `fridus.duel_s_florianem` | duel | 0:promluv_si_vecer_s_ptackem |
| M09 | `cesta_k_mlynu.nepratele_za_mlynem_cekaji_na_miste` | battle | 13:jdi_za_ptackem |
| M09 | `objective__najdi_cestu_pryc.hrac_je_v_prulezu` | battle | 16:projdi_kolem_zaseku |
| M09 | `souboj_se_zizkou.duel_s_zizkou` | duel | 17:prezij_souboj |
| M09 | `spusteni_trackview_za_padlymi_stromy.za_druhym_padlym_stromem` | battle | 13:jdi_za_ptackem |
| M09 | `prepadeni_v_rokli.spusteni_vykucharu_na_skalach` | battle | 13:jdi_za_ptackem |
| M10 | `cesta_na_nebakov_a_erik.fight_s_lapkama` | skirmish | 3:poraz_lapky |
| M10 | `cesta_na_nebakov_a_erik.lapkove_v_rokli` | skirmish | 2:jed_na_misto_prepadeni_u_nebakovskeho_mlyna |
| M10 | `nebakov.fight__potlaceni_vzpoury` | skirmish | 8:poraz_povstalce_a_ubran_nebakov |
| M11 | `bitva_o_tvrz_nebakov.celni_ztec_na_zebriky` | battle | 20:shod_zebriky |
| M11 | `bitva_o_tvrz_nebakov.final_stand` | battle | 24:pomoz_bohutovi_na_nadvori |
| M11 | `bitva_o_tvrz_nebakov.kamaradi` | battle | 19:bran_hrad |
| M11 | `bitva_o_tvrz_nebakov.obranci` | battle | 19:bran_hrad |
| M11 | `bitva_o_tvrz_nebakov.spodni_hrad_utocnici` | battle | 19:bran_hrad |
| M11 | `bitva_o_tvrz_nebakov.utocnici` | battle | 19:bran_hrad |
| M11 | `bitva_o_tvrz_nebakov.utok_na_branu` | battle | 21:odraz_utok_na_branu |
| M11 | `bitva_o_tvrz_nebakov.utok_ze_zalohy` | battle | 23:odraz_zalozni_utok |
| M11 | `nebakov_obrana__library.friendsdefend` | battle | 0:jdi_s_bohutou |
| M11 | `nebakov_obrana__library.nebakovobrana_attackwithladder` | battle | 0:jdi_s_bohutou |
| M11 | `hadka.fistfight_v_lazaretu` | duel | 7:nabidni_klare_pomoc |
| M12 | `pista.souboj_s_pistou` | duel | 1:podivej_se_po_rozkazech_v_pistovych_komnatach |
| M31 | `katerina.vyzva_kateriny` | duel | 5:utkej_se_se_straznym |
| M32 | `bitka_s_kubenkou.bitka_certovka` | skirmish | 1:pomoz_kubenkovi_v_bitce |
| M32 | `masivni_bitka_o_zachranu_certa.bitka` | skirmish | 6:zachran_sucheho_certa |
| M33 | `hledaniLichtenstejna_utils.FightingSamuelsManInTheTrap` | duel | 0:talkToKaterina |
| M33 | `loupeznik_kozina_prepada_opilce.kozina_utoci_na_hrace_script` | duel | 0:talkToKaterina |
| M33 | `s_vazounem_ve_spelunce.s_vazounem_na_pesti` | duel | 0:talkToKaterina |
| M33 | `hrac_prichazi_do_pasti.sarvatka_s_pohunky` | skirmish | 0:talkToKaterina |
| M34 | `hornici__smeny.druha_smena_horniku` | duel | 7:najdi_vstup_do_dolu |
| M34 | `hornici__smeny.prvni_smena_horniku` | duel | 8:zjisti_tezbu_frantovic_synku |
| M34 | `doly.predak_maslo_1` | duel | 6:promluv_si_s_kristianem_v_ustrani |
| M34 | `doly.rudokupec_herman` | skirmish | 6:promluv_si_s_kristianem_v_ustrani |
| M34 | `hute.vokrak` | skirmish | 17:najdi_vokraka |
| M34 | `boj_s_vavakovymi_muzi.fight_ruthard_vs_vavak` | skirmish | 1:pomoz_ruthardum |
| M34 | `tajna_mincovna.fight_with_buress_guards` | skirmish | 21:najdi_tajnou_mincovnu |
| M35 | `konfrontace_s_vavakem.bitka_s_vavakem` | skirmish | 2:poraz_mincmistra_a_jeho_muze |
| M37a | `duel_s_krystofem_oderinem.duel_with_krystof` | duel | 0:getToTownHall_beforeTimeRunsOut |
| M37b | `hibernable.bitva_za_jindru` | battle | 6:jed_na_pomoc_pratelum |
| M37b | `nocni_bitva.skirmish_na_nadvori` | battle | 4:zachran_bratra |
| M38 | `combat.startcombat` | skirmish | 2:najdi_matouse |
| M38 | `hovna.boj_s_hraci_kostek` | skirmish | 9:promluv_si_s_kostkari |
| M38 | `hovna.boj_s_hraci_kostek_2` | skirmish | 9:promluv_si_s_kostkari |
| M38 | `na_paloucku.boj_s_vesnicany` | skirmish | 19:zachran_komara |
| M38 | `na_paloucku.komar_po_osvobozeni` | skirmish | 22:promluv_si_s_komarem |
| M38 | `s_borutem_u_hrobu.bitka` | duel | 6:promluv_si_s_borutem |
| M42 | `obet_muz.utok_na_hrace` | skirmish | 4:jdi_za_samuelem |
| M42 | `obet_muz.utok_na_obet` | skirmish | 4:jdi_za_samuelem |
| M42 | `obet_zenska.utok_na_hrace` | skirmish | 4:jdi_za_samuelem |
| M42 | `k_matce_a_s_matkou.divadlo_u_bran` | skirmish | 4:jdi_za_samuelem |
| M42 | `divadlo_v_baraku.combat` | skirmish | 8:probij_se_domem |
| M42 | `cisteni_hospody_a_rozestaveni_nepratel.reacombat_v_hospode` | skirmish | 2:prohledej_hospodu |
| M42 | `posledni_obrana.chovani` | skirmish | 9:vydrz_napor_pred_synagogou |
| M44a | `odjezd_a_prepadeni.boj` | skirmish | 16:pobij_prazany |
| M44a | `odjezd_a_prepadeni.ditrich_behem_boje` | skirmish | 15:odjed_s_katzem_z_tabor |
| M44a | `poisonInfo.odlakani_musovy_straze` | duel | 29:pozadej_katerinu_o_pomoc_se_straznym |
| M44a | `faze_2.boj_s_bojs` | skirmish | 27:zabij_stepana |
| M44a | `zikmunduvTabor_utils.fightstart_with_config` | skirmish | 0:talkToZizkaStart |
| M44b | `protiutok_a_prepad_ve_vesnici.battle_trigger` | battle | 6:vyckej_na_rozkaz |
| M44b | `protiutok_a_prepad_ve_vesnici.bitva_s_posilami` | skirmish | 6:vyckej_na_rozkaz |
| M44b | `utok_na_vesnici.bitva_s_vesnicany` | skirmish | 4:zazen_vesnicany_na_utek |
| M44b | `boj_na_vnitrnim_nadvori.boj` | battle | 14:jdi_do_utoku |
| M44b | `finalni_boj_o_hrad.boj_ve_vezi_optional` | battle | 16:poraz_bergova_ve_vezi |
| M44b | `bitva.skirmish_na_vnejsim_nadvori` | battle | 9:prelez_hradbu |
| M44b | `ves_malesov.duel_s_certem_u_malesova` | duel | 2:promluv_si_s_certem |
| M45 | `zbavovani_se_pobudu.combat_uvnitr` | skirmish | 3:zbav_se_pobudu_na_ruthardce |
| M45 | `zbavovani_se_pobudu.vagabonds_combat` | skirmish | 3:zbav_se_pobudu_na_ruthardce |
| M45 | `honicka_na_konich.behaviors` | skirmish | 16:nenech_kardinala_utect |
| M45 | `v_podzemi.vykradaci_hrobu` | skirmish | 13:zbav_se_vykradacu_ve_sklepe |
| M45 | `vavakuv_klic` | skirmish | 6:promluv_si_s_zizkou |
| M45 | `vykradaci_ve_sklepu.combat` | skirmish | 0:zucastni_se_vychlechu_oty_z_bergova |
| M46 | `jindra__obrana_vlasskeho_dvora.attackers` | battle | 18:zdrz_utocniky_co_nejdele |
| M46 | `bitva_o_vlassky_dvur.utok_s_zebriky` | battle | 18:zdrz_utocniky_co_nejdele |
| M46 | `jindra__obrana_vlasskeho_dvora.boj_na_hradbach_vd` | battle | 19:odraz_zebriky |
| M46 | `jindra__obrana_vlasskeho_dvora.defenders` | battle | 18:zdrz_utocniky_co_nejdele |
| M46 | `jindra__skirmish_v_ruthardce.skirmish_v_ruthardce` | skirmish | 23:poraz_brabantovy_muze |
| M46 | `osvobozeni_panu.souboj_s_csabo` | skirmish | 16:osvobod_pany |
| M46 | `jindra__stealth_ve_vlasskem_dvore.ptacek_ceka` | skirmish | 9:zneskodni_straze |
| M46 | `jindra__zachrana_komara.combat_venku` | skirmish | 13:zachran_komara |
| M47 | `prijezd_na_kopec_a_souboj_s_erikem.duel_s_erikem` | duel | 0:rozluc_se_s_ruthardem_a_ostatnimi |
| M48a | `hibernables.nocni_utok` | battle | 27:shozene_zebriky |
| M48a | `prazane_utoci_z_pochodu_na_predhradi` | battle | 0:jdi_na_palisadu |
| M48b | `vypad.n2_faze_vypadu` | battle | 15:zneskodni_nepratelske_strelce |
| M48b | `vypad.n4_faze_vypadu` | battle | 16:zneskodni_pavezniky |
| M48b | `n1_faze_vypadu.enemyvojaci_strili` | battle | 15:zneskodni_nepratelske_strelce |
| M48b | `n1_faze_vypadu.strelci_strili_na_kopace` | battle | 15:zneskodni_nepratelske_strelce |
| M48b | `rutinaavypad.strelci_1_faze` | battle | 0:vyber_muze_na_vypad |
| M48c | `bitva_na_zadni_hradbe.skupinka_na_hradbe_bojujici_dokola` | battle | 0:dones_ptackovi_neco_k_jidlu |
| M48c | `celni_utok_prazskeho_vojska.boj_na_hradbach` | battle | 0:dones_ptackovi_neco_k_jidlu |
| M48c | `celni_utok_prazskeho_vojska.zebriky_na_zadni_hradbe` | battle | 0:dones_ptackovi_neco_k_jidlu |
| M48c | `shaneni_jidla_a_sezrani_psa.bitka_s_certem` | duel | 1:zeptej_se_u_hanse_na_jidlo |
| M49 | `sam_a_brabant.brabant` | skirmish | 0:najdi_kone_a_jed_pro_pomoc |
| M49 | `vstupni_brana.jindrich_a_straz_na_brane` | skirmish | 0:najdi_kone_a_jed_pro_pomoc |
| M50 | `bitevniCast.behem_bitvy` | battle | 0:zjisti_co_se_stalo |
| M50 | `bitevniCast.tezkoodenci_utoci_na_branu__sekernici` | battle | 0:zjisti_co_se_stalo |
| M50 | `bitevniCast.utocnici_na_bocni_hradbu` | battle | 0:zjisti_co_se_stalo |
| M50 | `bitevniCast.utok_na_bocni_hradbu__bitva` | battle | 0:zjisti_co_se_stalo |
| M50 | `bitevniCast.utok_na_bocni_hradbu__zebriky` | battle | 0:zjisti_co_se_stalo |
| M51 | `hibernation.cin_m5110k_finale__jost_army` | skirmish | 0:dobyj_zpatky_suchdol |
| M51 | `finale_bitva_na_nadvori.hrac_na_hradbach` | battle | 2:dostan_se_na_nadvori |
| M51 | `finale_bitva_na_nadvori.hracova_skupina` | battle | 0:dobyj_zpatky_suchdol |
| M51 | `finale_bitva_na_nadvori.nepratele_skupina_a` | battle | 0:dobyj_zpatky_suchdol |

The list above has 118 fight-bearing modules (of 165). Modules counted but
not listed:

| quest | not listed |
|---|---|
| M09 | 9 |
| M31 | 1 |
| M37b | 1 |
| M38 | 1 |
| M42 | 3 |
| M44b | 9 |
| M46 | 1 |
| M48a | 2 |
| M48b | 8 |
| M48c | 10 |
| M50 | 1 |
| M51 | 1 |

**For the combat work.**

* The **M50 `bitevniCast` fights run twice**: once in the prologue as Godwin,
  through M30, and again at the endgame.
* The **M11, M46, M48a–c and M50** sieges use battle groups, ladders and gate
  bashing. They are the densest NPC-sync load in the story.
* Duels (`duelbehavior*`) put the player one-on-one against a named NPC.
  With two players, the second player's hits on the duel NPC are a story
  hazard: fail states such as `game_over_zachranaPtacka_caponDied` key on
  named NPCs dying.

### 5.4 Non-Henry stretches

**Players.** `Libs/Tables/player.xml` lists exactly two players
(data-verified):

| PlayerId | who | soul | notes |
|---|---|---|---|
| 0 | Henry | `player_henry` | — |
| 1 | Godwin | `player_bohuta` | `FreezeReputation=true`, **`ShelveData=true`**, `FastTravelEnabled=false`, `ChangingClothesEnabled=false`, `QuestGiversEnabled=false` |

* The switch goes through `C_PlayerSwitcher` / `C_ShelverManager`, which
  shelves the other player's data. "Player switching can't be started,
  because level switching is in progress" (code-verified strings).
* The quest nodes are `SwitchPlayer` and the `switchplayer` library module.
  The module can heal and clean on switch (data-verified).

Objective ranges come from the WO-96 registry (index:id). **The switch
points are data-verified. The objective ranges are inferred from module
order and could be off by one at the edges (inconclusive).**

| stretch | starts (switch to 1) | Godwin plays | ends (switch to 0) |
|---|---|---|---|
| **Prologue**, M30 `posledniPomazani` + M50's `bitevniCast` | `posledniPomazani.hibernable` `SwitchPlayer` on `uvodni_cutscena.beforeplay` (intro cutscene) | M30 obj 0–5 (`jdi_po_schodech_na_predni_hradby` … `zbav_se_vsech_nepratel_na_hradbe`) | `zoufala_obrana_za_bohutu.bitevniCast.cin_m5020k_obranabohuta__siege_finale` `switchplayer` 0 on the battle-ending cutscene's `AfterPlay`; then M30 `finalAnointning.OnDone` → `SwitchLevel story_switch_to_trosecko` → M01 |
| **M05** `svatba`, end | `hibernovana_cast.prvni_bohutova_vlozka_v_uzicich.cin_m0540t_svatba__intermezzo_bohuta` on `changeweather11.OnExec`; entered from `svatba_skoncila` (the wedding ended) | no journal objective: a short scene sequence | `bohuta_s_rackem_a_hanusem.AfterPlay`; the module's `bohutova_vlozka_skoncila` ends the quest |
| **M10** `bohutovaVlozka` | `hibernation.bohutova_cast.v_zelejove.cin_m1010t_bohutovavlozka__bohuta_arrival` on `bohutaComesToZelejov.AfterPlay` | obj 0–9 (`promluv_si_s_uprchliky_ze_mlyna` … `promluv_si_s_hejtmanem`) | `hibernation.henryho_cast.cin_m1040t_bohutovavlozka__nebakov_jail` `AfterPlay` (+ a guard `SwitchPlayer` 0 if still Godwin); Henry does obj 10–11 |
| **M37a** `setkaniVRatbori1` | `h.bohuta_na_ratbori.cin_m3730k_setkaniratbor__transfer_ratbor` (`triggersequence5.B`) | obj 8–18 (`seznam_se_s_brabantem` … `promluv_si_lichtenstejnem_o_sehnane_podpore`); obj 0–7 are Henry's | `h.kunohorsky_snem_2.cin_m3760k_setkaniratbor__transfer_council` `BeforePlay`; Henry does obj 19 |
| **M37b** `setkaniVRatbori2` | `hibernable.cin_m3770k_setkaniratbor__night_ratbor` `BeforePlay` | the feast and the night battle (obj 0–5, 10) | `hibernable.cin_m3790k_setkaniratbordva__henry_arrives` `BeforePlay`; Henry does obj 6–9 |
| **M46** `prepadeniVlasskehoDvora` | `h.bohuta__cesta_do_vlasskeho_dvora.cutscena_a_prepnuti_hrace` (`cutscenehandler2.BeforePlay`; also the Haste `switchPlayer_bohuta`) | obj 0–8 (`jdi_do_vlasskeho_dvora` … `prones_zaverecnou_rec`) | `h.stealth.jindra__stealth_ve_vlasskem_dvore.prepnuti_hrace_a_priprava_npc` on `bohuta_se_neprozradil`; Henry does obj 9–24 (four more Haste-only `SwitchPlayer` 0 entry points) |
| **M48c** `hladAZmar` | `h.bohuta_kaze.cin_m4860k_oblehanisuchdol__bohuta_preaching` on `changeweather23_1.OnExec` | a sermon scene inside obj 0's open-world stretch, entered from `hrac_dorazil_na_pohreb` / `hrac_sel_spat` | the same module, `if19.True` |
| **Endgame**, M50 `zoufalaObranaZaBohutu` | `hibernable.q.bohuta_se_opije.cin_m4910k_stealthmise__abseil_down2` `BeforePlay` (plus a root `SwitchPlayer` on the `startBattle` Haste trigger) | obj 0–7 (`zjisti_co_se_stalo`, `jdi_na_nadvori`, then the siege defence) | the shared siege-finale `switchplayer` 0; M51 is Henry |

**Why this matters for Part B.**

* Godwin holds 38 forced, 42 fader and 39 other conversations with the player
  (data-verified).
* Decisions refuse joins in these stretches (WO-125). In mid-session the
  joiner is only told (WO-125 §7).
* The host's `$__player` becomes Godwin, with Henry's data shelved. The
  joiner's copy still has Henry as its player, in a world whose quest expects
  Godwin.

---

## 6. The map for Part B

### 6.1 Candidate sync models (not a pick)

**A. Host-authoritative quest state, mirrored live to the joiner.**

The host detects each change and sends (quest, objective / `State` node,
value, log type). The joiner applies it to its own copy.

Evidence:
* Detection:
  * `FindNode` is live (WO-97).
  * The `C_Quest` / `C_Objective` getters are exported (§1.2).
  * The signals and the HUD sink exist (§1.4).
  * The host's marker line still prints.
* Apply:
  * narrow Haste triggers exist for **17 of 626** objectives (WO-96/97);
  * the in-port pulse reaches every `State` `Set*` port (WO-97/99.5) but has
    never been fired;
  * cumulative Haste is live.

Risks:
* An applied transition fires the joiner's **own** consumers: cutscenes,
  quest items, saves, time sets, player switches, teleports. So the joiner
  also gets the side effects, at a different time and place.
* A value without its transition misses the edge-triggered consumers (~1 in
  4 reads, WO-92).
* The journal can change without the gameplay (the WO-97 sacks case).
* There is no inverse.
* Mirror order must follow the host's order.
* The joiner's copy is also advancing by itself (§1.1), so the two sources
  conflict.
* The dialogue ledger, codex and story stat need their own routes.

**B. The joiner's quest actions sent to the host to apply.**

The joiner's local story-relevant events are sent to the host, which applies
them to the world. The events are: a conversation outcome, a pickup, an area
entered, a fight won.

Evidence:
* The joiner's events are visible on the joiner: dialogue lines with concept
  paths, the native signals, cutscene lines.
* The WO-102 request channel (`ActionKind.NpcRequest`) is the precedent for
  joiner → host intents.
* Haste and the in-port pulse exist on the host.

Risks:
* Most story moments cannot *happen* on the joiner at all: host NPCs are
  suspended (§3.3), so there is often nothing to send.
* An outcome applied on the host fires host-side consumers (right for the
  world), but the joiner has already seen its own local version.
* Crime, money, items and reputation act on the local player
  (`$__player`, WO-112 §4.3.1).
* Duplicates arise when both players trigger the same beat.

**C. Rejoin / reload as the coarse fallback.**

At a checkpoint the joiner reloads the host's latest save.

Evidence:
* The route is exact by construction and already live: join, rejoin and the
  host reload taking the joiner along (observed WO-124/125).
* The host's checkpoint marker line and its scheduled world save give the
  trigger points (WO-122).

Risks:
* 12 s in-world (WO-125), 52–60 s from the menu (WO-124). The host pauses
  during the transfer (WO-123).
* The joiner's Henry rewinds to the pair of that save: gains since the last
  host save are lost (by decision).
* Engine save locks (cutscene, skip time, death, quest locks) delay the save.
* Frequent reloads break flow.

**D. Combinations**, each only listed:

* **Co-presence gating plus reload.** Both-present moments (§5.1) may start
  only with both players present (a leash and "ready?" prompts). Host-only
  moments run freely. A C-reload at each host checkpoint erases the joiner's
  drift.
* **Host-authoritative with a spectator joiner.** The joiner's copy is held:
  its own graph must not advance. The joiner watches, and the host's
  Rendered cutscenes are replayed on it by console. C-reloads come at
  checkpoints.
* **A for journal and presentation, C for truth.** The joiner is shown
  host-driven HUD notices (RTTR `ShowQuestEvent`) and mirrored objectives
  where a vetted narrow trigger exists. The world is reset at checkpoints.

### 6.2 Open questions only a live test can answer

| # | question | smallest live test |
|---|---|---|
| Q1 | Do the exported `C_Objective` getters, called on a `FindNode` result, return the journal's state? | solo, a disposable save with M03 active; read `socky`'s objectives natively and compare with the journal |
| Q2 | Does an in-port pulse on a zero-consumer `State` port (`rekniPtackoviOPraci.SetDone`, WO-97 T2) change exactly one objective, with nothing else? | solo, disposable save; pulse it, then run the Q1 read and look at the journal |
| Q3 | Does the joiner's copy advance on its own after a join, and where does it stall on suspended NPCs? | two machines; the joiner enters an area-triggered beat the host has not reached; Q1 reads on both |
| Q4 | Does a suspended NPC hold a conversation if the joiner resumes it **within** `wh_dlg_RequestTimeout` (route R1)? | solo; `wh_ai_PauseNPC`, `RequestDialog`, `wh_ai_ResumeNPC` after 1 s |
| Q5 | Does a pass-through proxy on `I_UIHudEventsQuest` (`GetUIHudEvents` / `SetUIHudEvents`) see every quest and objective event? | solo native probe: dump the sink's vtable, install a logging proxy, advance one objective |
| Q6 | Does a quest `ForcedDialog` start on the joiner against a host-owned (suspended) NPC, and does its NPC-freeze step finish? | solo with a manual pause plus a Haste trigger that forces a dialogue |
| Q7 | What does each screen show when the other player is in a cutscene or dialogue? | two machines, one Ingame cutscene, one conversation |
| Q8 | Does a joiner-local time set (an Ingame cutscene `Time` or `AdvanceWorldTime`) reach the host through the time-skip sync? | two machines; trigger one time-setting beat on the joiner and read the host's clock |
| Q9 | Does `wh_ui_PlayCutscene <rendered>` on the joiner play the host's video with no quest effect? | solo, one Rendered name from Appendix A |
| Q10 | What does the joiner's carried journal UI (tracked quest) do in a host world where that quest is not active? | solo; splice with the existing tools, load, open the journal |
| Q11 | Does the host's level switch (M12 end, M30 end) carry the joiner through the reload path? | two machines at the M12 end beat, or a Haste jump there on a throwaway save |

### 6.3 Hazards

**Could corrupt or poison the host's save.**

| # | hazard | evidence |
|---|---|---|
| H1 | the old catch-up prompt fires Haste into the host's world. It is reachable from a stale joiner marker (§2) or from `mp_quest_fire` / the test prompt | repo-verified path |
| H2 | a joiner-local quest time jump is broadcast as a time skip and applied forward on the host. The agent reports any settled clock jump, `ApplyTimeSkipAsync` applies what arrives, neither has a host or shared-world gate, and the relay routes 0x28 first-come from any client ("any player's sleep counts") | repo-verified `GameBridge.cs:2920-2975, 3800-3845`, `ClientHandler.cs:301-345`; frequency (inconclusive) |
| H3 | a file-armed `port_watch` on the host fires a concept port with no session or role gate | repo-verified; needs a file |
| H4 | a mirroring apply cannot be undone. A wrong pulse is in the next host autosave (5-minute schedule, WO-122) | repo-verified: WO-92 found no setter and no inverse |
| H5 | the joiner's damage kills a named NPC in the host's world → the host's quest fail state, e.g. `prepadeni_capon_killed` or `game_over_zachranaPtacka_caponDied` (46 fail reasons; many key on named NPCs) | data-verified reasons; damage path WO-121 |
| H6 | the host's quest `SaveGame` nodes (215 in the main quests) bake a story state the joiner never saw. That is the host-wins rule working, but it fixes the drift into the pair snapshot the joiner restores | data-verified count; by decision |

**Could soft-lock a quest.**

| # | hazard | evidence |
|---|---|---|
| S1 | the joiner cannot talk to host NPCs. A beat the host is not present for cannot progress on the joiner, and must not progress there in the host's name | observed WO-112 |
| S2 | a mirrored objective without its gameplay: "journal says done", the world disagrees (sacks ungrabbable) | repo-verified: WO-97's sacks case |
| S3 | a Godwin stretch in mid-session: the host's player becomes Godwin with Henry's data shelved; the joiner's copy keeps Henry | data-verified §5.4 |
| S4 | the joiner's own forced conversations and cutscenes take exclusive input on the joiner while its NPCs are suspended; a scene may never finish positioning | code/data-verified locks; (inconclusive) finish |
| S5 | a level switch mid-session (M12, M30); a joiner once died inside level-load finalisation at the Godwin→Henry switch (WO-90 finding 2, cause not recoverable from its logs) | observed WO-90; (inconclusive) now |
| S6 | leave-area handlers and invisible walls fire on each machine's own player; a joiner outside a quest area in its copy gets that copy's fail or teleport | data-verified (`leavelevelhandling_v2` modules and wall nodes in the main quests) |

**Could put the two machines permanently out of step (until a rejoin).**

| # | hazard | evidence |
|---|---|---|
| D1 | the dialogue ledger, codex, story stat, journal UI and map knowledge are per machine | §1.1 |
| D2 | one-shot `On<State>` edges: a mirror without transitions, or a transition without its gameplay | WO-92/97 |
| D3 | the joiner's copy advances on player-keyed triggers and the host never hears | §1.1 |
| D4 | quest items live only in the host's world; the joiner's Henry is stripped of them at each join (e.g. the M12→M31→M51 sword chain) | repo-verified WO-112/115 |
| D5 | time, weather, layers and corpses set by a cutscene on one machine only | §4.2 |
| D6 | two copies of the same NPC in two conversations (R1/R2) | §3.5 |

---

## 7. Corrections to standing belief

* **WO-112's design note D1** ("joiner claims the NPC via WO-60 claim/hold")
  predates host authority. Under the shipped model the joiner never emits
  `npc_claim`; the claim path is bypassed (WO-102 §4.2). Route R1/R2 needs a
  new hand-over.
* **Whether the marker line prints under the join lock** was left open:
  WO-122 never ran a quest checkpoint save under the lock. Settled here as
  **no for quest checkpoints** (code-verified §1.4). The consequence: a
  joiner's objective marker is stale for the whole session.
* **WO-92 §7 item 2** said the `CutscenePlayer` line "carries the quest's
  internal concept-graph name". It also carries the cutscene type and holder.
  Seven verbs are logged; the agent parses two (`PlayCutscene`,
  `OnCutsceneEnd`) (code-verified; repo-verified parser).
* **The dialogue ledger is concept state**, saved with the quests. WO-112 did
  not name its chunk.
* **`wh_ui_PlayCutscene` is Rendered-only** (code-verified). WO-90 had
  established only that `wh_ui_StopCutscene` stops what `wh_ui_PlayCutscene`
  played.

## 8. Not done, stated plainly

No live test of anything (Part A is static). The listener proxy (Q5), the
getter read (Q1) and every pulse (Q2) are code-verified only. Per-quest
objective ranges for Godwin are inferred at the edges. Dialogue holder
teleports were not resolved per quest (59 of 270 main-quest dialogue holders
carry teleport links, data-verified in aggregate). 29 cutscene handlers and 17
background sequences did not resolve to a type. Full list and reasons:
`docs/WO-126A-progress.md` §7.

---

## Appendix A — per-quest IDs

Forced conversations are listed by module ID; fader and player-started ones
are counted only (the progress doc gives the method that lists them).
Cutscenes are listed by their cutscene-table name, with notes: `sets` = the
time of day an Ingame cutscene writes, `skips` / `to` = a SkipTime duration
or target, `player repositioned` = the holder fast-forwards the player.
Time-of-day values are the quest's own `AdvanceWorldTime` targets. IDs only,
no text. (data-verified)

### M01 `prepadeni`
* forced conversations (4): `ptacek_ukoluje_jindricha_ohledne_bludiste`, `polylog_u_ohne`, `dialog_po_kostkach`, `vyjednavani_s_bergovovymi_muzi`
* also 7 fader and 4 player-started conversations with the player (counted, not listed)
* Ingame cutscenes: `prepadeni_meetingWithSheriff` (player repositioned), `prepadeni_armorLake`, `prepadeni_henryFalls`, `prepadeni_roadToCamp`
* Fader cutscenes: `prepadeni_streamPtaceksGroup` (player repositioned), `prepadeni_waitForStart`, `prepadeni_ptacekPutsOnHelmet`
* unresolved cutscenes: x1
* scripted-fight modules: 3 (listed in §5.3)
* fail states (`GameOver`): `prepadeni_capon_killed`
* time-of-day sets (`AdvanceWorldTime`): 17h, 19h15m, 19h30m, 21h30m, 18h30m
* player gear: BodyPartOverride x5, EquipPlayersItem x12, UnequipPlayersItem x2
* locations / locks: FilterInput x13, hrac_narazi_do_neviditelnych_sten x1

### M02 `zachrana`
* forced conversations (6): `lektvar_hotovej`, `prepadeni`, `s_babkou__zadani_obvazu__jidla__umyti_se`, `dialog_s_intruderem`, `pavlena__dialog_po_probuzeni`, `snidanovy_tetralog`
* also 10 fader and 2 player-started conversations with the player (counted, not listed)
* Ingame cutscenes: `zachrana_cestaPoBrehu`, `zachrana_prichodKeKorenarce`, `zachrana_probuzeni` (player repositioned), `zachrana_prespani`
* Fader cutscenes: `zachrana_posezeni` (player repositioned), `zachrana_afterHerbs`, `zachrana_posezeni`
* unresolved cutscenes: x1
* background sequences (`PlayTrackView`): 3
* scripted-fight modules: 2 (listed in §5.3)
* story deaths: 1 scripted kill nodes, 1 permadeath guards
* time-of-day sets (`AdvanceWorldTime`): 23h, 23h, 23h, 12h, 17h, 15h, 6h
* player gear: BodyPartOverride x7, DeleteNondivisibleItems_FromSoul x3, unequipallplayersitems x2
* locations / locks: FilterInput x3, keepdooropen x1, keepdoorunlocked x1

### M03 `socky`
* forced conversations (8): `hadka_na_pranyri`, `forced_s_rychtarovym_synem_po_kostkach_result`, `forced_hospodska_varuje`, `hospodska_forced`, `prvni_dialog_s_ptackem`, `forced_zacatek_bitky`, `forced_jindra_smrdi`, `trialog_s_kovarem_a_mlynarem`
* also 12 fader and 4 player-started conversations with the player (counted, not listed)
* Rendered cutscenes: `m03_trosky_journey`
* Ingame cutscenes: `socky_2_gate` (sets 15h), `socky_3_tavern` (sets 10h), `socky_6_pillary` (sets 12h50m; player repositioned), `socky_7_bergov` (sets 07h30m; player repositioned), `socky_5_departure`, `socky_4_katerina` (sets 10h; player repositioned)
* Fader cutscenes: `socky_faderAfterArrestDialog`
* scripted-fight modules: 2 (listed in §5.3)
* fail states (`GameOver`): `game_over_socky_commited_crime`
* time-of-day sets (`AdvanceWorldTime`): 10h00m, 13h20m, 7h30m
* player gear: EquipPlayersItem x1, PlayerOutfitOverride x1, unequipallplayersitems x1
* locations / locks: FilterInput x1, IntermissionTriggerByDistance x2, keepdooropen x2

### M05 `svatba`
* forced conversations (25): `jindra_bali_holku`, `s_hejtmanem_a_vujtkem_po_souboji`, `s_myskou`, `s_rychtarovym_synem`, `zaver_s_rychtarovym_synem`, `jindra_s_nevestou`, `kucharka_si_bere_jidlo`, `vysledek_s_drozdem`, `vysledek_s_hostinskou`, `vysledek_s_komorim`, `vysledek_s_kovarem`, `zabaveni_vina`, `michal_a_david`, `utesovani_nesikovne_tanecnice`, `po_tanci`, `s_konkubinou_komorim_a_seminem_sr`, `s_kovarem_a_seminem_sr_1`, `bohuta_s_rackem_a_hanusem`, `po_prvnim_duelu`, `po_druhem_duelu`, `po_tretim_duelu`, `s_komorim_o_ztracene_konkubine`, `s_konkubinou_a_ptackem`, `s_kovarem_o_ztracenem_meci`, `s_ptackem_a_konkubinou`
* also 99 fader and 18 player-started conversations with the player (counted, not listed)
* Ingame cutscenes: `svatba_weddingCeremony`, `svatba_fightWedding`, `svatba_guardsArrival`
* Fader cutscenes: `svatba_teleportBeforeGuardsArrival`, `svatba_fastTravelToWedding`, `svatba_duelWithVujtek`, `svatba_polylogAfterDuelWithVujtek`, `svatba_danceWithMyskaPlaceholder` (player repositioned), `svatba_atBailiffSonAndHuntsmanSon`, `svatba_atBailiffSonAndHuntsmanSonAfterBet`, `svatba_polylogWithBrideAndDrunkedMan`, `svatba_dialogWithBadDancer`, `svatba_danceWithDoubravkaPlaceholder` (player repositioned), `svatba_jindrichIsPoisoned` (player repositioned), `svatba_intermezzoBohuta_common` (player repositioned), `svatba_huntsmanGetUp`, `svatba_changeBehaviorForHuntsmam`, `svatba_dialogWithChamberlainPhaseFour`, `svatba_polylogWithPtacekAndConcubine`, `svatba_dialogWithBlacksmithPhaseFour`
* unresolved cutscenes: x5
* scripted-fight modules: 5 (listed in §5.3)
* story deaths: 0 scripted kill nodes, 1 permadeath guards
* time-of-day sets (`AdvanceWorldTime`): 22h, 9h; 2 with a wired value
* forced sleep / wake: 1 (PlayerAction_WakeUpOnBed)
* player gear: DeleteNondivisibleItems_FromSoul x1, DisableHorseInventory x1, EquipPlayersItem x2, PlayerOutfitOverride x2, unequipallplayersitems x1
* locations / locks: FilterInput x5, LockUp x1
* player switch: to 0 in `hibernovana_cast.prvni_bohutova_vlozka_v_uzicich`; to 1 in `hibernovana_cast.prvni_bohutova_vlozka_v_uzicich.cin_m0540t_svatba__intermezzo_bohuta`

### M06 `naTroskach`
* forced conversations (9): `bergov__co_dal`, `hrac_se_doflakal_a_jde_do_vezeni`, `straz__hybaj_do_prace`, `hrac_vujtek_magda_trialog`, `kabat__nemas_sperhaky`, `nikodem__po_kostkach_penize`, `nikodem__po_kostkach_ruzenec`, `ptacek_ve_vezeni`, `ptacek__v_lochu`
* also 19 fader and 1 player-started conversations with the player (counted, not listed)
* Ingame cutscenes: `naTroskach_endPrison` (player repositioned)
* Fader cutscenes: `naTroskach_studnaFall`, `naTroskach_startPrison` (player repositioned)
* SkipTime cutscenes: `naTroskach_prevozVMouce` (skips 1h)
* unresolved cutscenes: x1
* fail states (`GameOver`): `game_over_caponExecuted`
* time-of-day sets (`AdvanceWorldTime`): 07h00m, 18h00m, 7h0m
* player gear: DisableHorseInventory x1, PlayerOutfitOverride x2
* teleports: NPCs_TeleportIngame x2
* locations / locks: DisableDoorInteractivity x1, LockUp x3, areatrespassleveleffect x11, keepdooropen x2

### M07 `nebakovPruzkum`
* forced conversations (13): `kapitan_strazi__u_stolu`, `kapitan_strazi__u_stolu_po_duelu`, `streba_po`, `nebakovsky_pan__dialog_ve_vezeni`, `devecka_klara__dialog_o_rane`, `devecka_klara__dialog_po_sexu`, `statecny_civil_dialog`, `ptacek_a_straz_na_brane__polylog`, `vitaci_polylog_s_zizkou`, `ptacek_bez_zavodu`, `ptacek_po_zavodu`, `bergov__report_z_nebakovske_mise_a_start_m08`, `ptacekforcepo_ft`
* also 31 fader and 7 player-started conversations with the player (counted, not listed)
* Fader cutscenes: `nebakovPruzkum_nebakov`, `nebakovPruzkum_questStart`, `nebakovPruzkum_nebakovAfterIntroduction`, `nebakovPruzkum_trialogBergov`, `nebakovPruzkum_nebakPrison`, `nebakovPruzkum_civilianRun`
* SkipTime cutscenes: `nebakovPruzkum_sex` (skips 1h), `nebakovPruzkum_sex` (skips 1h; player repositioned), `nebakovPruzkum_sexCensured` (skips 1h; player repositioned)
* FastTravel cutscenes: `nebakovPruzkum_nebakovTravel`, `nebakovPruzkum_troskyTravel`
* Text cutscenes: `nebakovPruzkum_klaraHealing`
* unresolved cutscenes: x1
* scripted-fight modules: 1 (listed in §5.3)
* story deaths: 0 scripted kill nodes, 1 permadeath guards
* time-of-day sets (`AdvanceWorldTime`): 7h
* player gear: DeleteNondivisibleItems_FromSoul x1, EquipPlayersItem x3, PlayerOutfitOverride x1, ReplacePlayerHorse x2
* teleports: NPCs_TeleportOnHorse x2, PlayerAction_TeleportOnHorse x2
* locations / locks: DisableDoorInteractivity x1, FilterInput x2, IntermissionTriggerByDistance x2, LockDoor x1, areatrespassleveleffect x8

### M08 `mucirna`
* forced conversations (12): `ptacek_ceka_na_henryho_na_nadvori`, `s_ptackem_o_muceni`, `polylogs_po_navratu_z_mucirny_1`, `bergov_nebo_hasek_nejsou_v_sale`, `mucici_dialog_new`, `polylog_s_bergovem_po_vypaleni_semina`, `polylog_s_bergovem_po_vypaleni_semina__bez_haska`, `hasek_prisel_za_hracem_do_donjonu`, `dialog_s_nalezenym_oldrichem__alternativaa`, `dialog_s_hejtmanem_po_souboji`, `polylog_s_haskem_a_starym_seminem`, `polylog_s_obema_seminy_po_souboji`
* also 13 fader and 3 player-started conversations with the player (counted, not listed)
* Ingame cutscenes: `mucirna_vypaleniSemina_seminBurnDownBezPosil` (player repositioned), `mucirna_vypaleniSemina_seminBurnDownPosily` (player repositioned)
* Fader cutscenes: `mucirna_vypaleniSemina_seminJrFoundReportFader`, `mucirna_vypaleniSemina_seminJrFound`
* FastTravel cutscenes: `mucirna_vypaleniSemina_fastTravelToSemin`
* unresolved cutscenes: x4
* scripted-fight modules: 3 (listed in §5.3)
* fail states (`GameOver`): `game_over_crime_execution`
* story deaths: 8 scripted kill nodes, 2 permadeath guards
* time-of-day sets (`AdvanceWorldTime`): 18h30m, 16h50m, 22h30m, 21h30m, 20h; 1 with a wired value
* player gear: PlayerOutfitOverride x1
* teleports: NPCs_TeleportIngame x2, NPCs_TeleportOnHorse x2, PlayerAction_TeleportOnHorse x1
* locations / locks: DisableDoorInteractivity x2, FilterInput x1, IntermissionTriggerByDistance x1, areatrespassleveleffect x5, banusageofdoorswithexclusionarea x1, keepdooropen x2, keepdoorunlocked x1, unlockdoorsandkeepdoorsunlocked x1

### M09 `utokNaNebakov`
* forced conversations (14): `polylog_s_komorim_na_konich`, `force_po_prohranem_souboji_s_osinou`, `chat_s_cernym_bartosem_1`, `bergov_a_otazky`, `odevzdani_prstenu_pani`, `po_duelu_s_fridusem`, `herman_palecek`, `dialog_se_zenou`, `schuzka_ve_dvou_1`, `dialog_s_rytirem`, `rozhovor_po_kostkach`, `pokec_s_ptackem`, `polylog_s_bergovem_a_ptackem`, `polylog_s_rytiri`
* also 14 fader and 2 player-started conversations with the player (counted, not listed)
* Rendered cutscenes: `utokNaNebakov_cutscene_march_render`
* Ingame cutscenes: `utokNaNebakov_cutscene_march` (sets 7h30m; player repositioned), `utokNaNebakov_valley_beforeDuel` (sets 8h05m; player repositioned), `utokNaNebakov_valley_afterDuel` (sets 8h05m)
* Fader cutscenes: `utokNaNebakov_fader`, `utokNaNebakov_stopCrimeCutscene`
* unresolved cutscenes: x1
* background sequences (`PlayTrackView`): 6
* scripted-fight modules: 16 (listed in §5.3)
* fail states (`GameOver`): `game_over_utokNebakov_AmbushCapon`, `game_over_utokNebakov_TroskyCrime`
* story deaths: 15 scripted kill nodes, 0 permadeath guards
* time-of-day sets (`AdvanceWorldTime`): 20h, 8h, 22h, 6h29m, 9h30m, 8h05m; 1 with a wired value
* forced sleep / wake: 1 (PlayerAction_WakeUpOnBed)
* player gear: DeleteNondivisibleItems_FromSoul x1, EquipPlayersItem x2
* teleports: NPCs_TeleportIngame x8, NPCs_TeleportOnHorse x1, PlayerAction_TeleportOnHorse x1
* locations / locks: DisableDoorInteractivity x1, FilterInput x2, IntermissionTriggerByDistance x1, LockUp x1, areatrespassleveleffect x3, banusageofdoorswithexclusionarea x1, keepdoorunlocked x9

### M10 `bohutovaVlozka`
* forced conversations (11): `forced_po_prijezdu_ke_stajim`, `dialog_s_lapky`, `forcovany_dialog_ares_vojakem_u_mlyna`, `polylog_s_erikem_a_vudcem_lapku`, `dialog_s_zizkou`, `se_zizkou_po_souboji`, `dialog_s_zelejovskym_hospodskym`, `bohuta_zacina_mluvit_se_muzem_z_mlyna`, `bohuta_zacina_mluvit_se_zenou_z_mlyna`, `trialog_henry__ptacek__pista`, `zaverecne_rozhreseni`
* also 11 fader and 0 player-started conversations with the player (counted, not listed)
* Ingame cutscenes: `bohutovaVlozka_bohutaNebakov`, `bohutovaVlozka_standoffZizka` (player repositioned), `bohutovaVlozka_intro`, `bohutovaVlozka_nebakovJail`, `bohutovaVlozka_pistaRelease` (sets 17h30m), `bohutovaVlozka_zizkasEye`
* Fader cutscenes: `bohutovaVlozka_dismountingHorseCutscene`, `bohutovaVlozka_erikBanditPolylogCutscene`
* scripted-fight modules: 3 (listed in §5.3)
* fail states (`GameOver`): `game_over_bohutovaVlozka_banditsKilledEriksMen`, `game_over_bohutovaVlozka_riotAtNebakov`
* story deaths: 6 scripted kill nodes, 0 permadeath guards
* time-of-day sets (`AdvanceWorldTime`): 2 with a wired value
* player gear: DisableHorseInventory x1, EquipPlayersItem x1, PlayerOutfitOverride x2, weaponandclothingpresetoverride x1
* teleports: NPCs_TeleportIngame x1, NPCs_TeleportOnHorse x1, PlayerAction_TeleportOnHorse x1, PlayerAction_TeleportWithItems x1
* locations / locks: LockDoor x1, leavelevelhandling_v2 x1
* player switch: to 0 in `hibernation.henryho_cast`; to 1 in `bohutova_cast.v_zelejove.cin_m1010t_bohutovavlozka__bohuta_arrival`; to 0 in `hibernation.henryho_cast.cin_m1040t_bohutovavlozka__nebakov_jail`

### M11 `nebakovObrana`
* forced conversations (20): `rozkazy_pro_last_stand`, `force_polylog_s_michalem`, `dostavenicko_s_klarou`, `dostavenicko_s_klarou_2`, `force_polylog_pred_utokem`, `promluva_s_kecalem`, `predavka_leku_zajatym`, `prioritni_polylog_s_hermanem_a_bartosem`, `force_dialog_po_fistfightu`, `prio_intervence_za_zranene`, `diagnoza__marek`, `osetreni__marek`, `diagnoza__kozlik`, `osetreni__kozlik_1`, `diagnoza__marek`, `osetreni__marek`, `ptacek_ma_smutne_kecy`, `ptacek_po_kostkach`, `bohuta_o_strelbe_palnou_zbrani`, `bohuta_po_strelbe`
* also 17 fader and 7 player-started conversations with the player (counted, not listed)
* Rendered cutscenes: `nebakovObrana_nightmare_render`
* Ingame cutscenes: `nebakovObrana_startBattle` (sets 8h), `nebakovObrana_godFinger` (sets 8h), `nebakovObrana_godFingerShorter` (sets 8h), `nebakovObrana_enemyArmy` (sets 6h09m)
* Fader cutscenes: `nebakovObrana_coverGraveTeleport_fader_1`, `nebakovObrana_coverGraveTeleport_fader_2`, `nebakovObrana_coverGraveTeleport_fader_3`, `nebakovObrana_fastBattleTeleport_fader`, `nebakovObrana_fader`
* SkipTime cutscenes: `nebakovObrana_skipTime_sleep` (to 5h59m)
* Text cutscenes: `nebakovObrana_coverGrave_fader`
* unresolved cutscenes: x3
* background sequences (`PlayTrackView`): 8
* scripted-fight modules: 11 (listed in §5.3)
* fail states (`GameOver`): `DiedWhileUnconscious`, `game_over_bohutaDead`, `game_over_obranaNebakov_allGuysFallen`, `game_over_utokNebakov_NebakovCrime`
* story deaths: 7 scripted kill nodes, 2 permadeath guards
* time-of-day sets (`AdvanceWorldTime`): 8h, 8h, 20h29m, 18h, 6h9m, 19h, 19h20m, 19h40m, 20h, 20h29m
* player gear: DeleteNondivisibleItems_FromSoul x11, PlayerOutfitOverride x2
* locations / locks: FilterInput x2, areatrespassleveleffect x3, keepdoorunlocked x2

### M12 `vezniNaTroskach`
* forced conversations (5): `dialog_s_informatorem`, `tetralog_o_odchodu`, `pista_rozhodnuti`, `custom_dialog__muceni`, `zizka_katerina_bohuta__co_ted`
* also 5 fader and 1 player-started conversations with the player (counted, not listed)
* Ingame cutscenes: `vezniNaTroskach_prisonersConvoy_ingame` (sets 19h30m), `vezniNaTroskach_zikmundLetter`, `vezniNaTroskach_erikLeaves` (player repositioned), `vezniNaTroskach_pistaDefeatWindow`, `vezniNaTroskach_pistaDefeatDuel_sword`, `vezniNaTroskach_pistaDefeatDuel_alternativeWeapon`, `vezniNaTroskach_pistaDefeatDuel_unarmedOrRanged`, `vezniNaTroskach_katerinaInterrupt` (sets 20h)
* Fader cutscenes: `vezniNaTroskach_tortureSetup`, `vezniNaTroskach_placeholderFaderStreaming`, `vezniNaTroskach_faderPolylogNearGate`, `vezniNaTroskach_windowStreaming`, `vezniNaTroskach_pistaFightSetup`, `vezniNaTroskach_playerTakesEquip`
* unresolved cutscenes: x1
* scripted-fight modules: 1 (listed in §5.3)
* fail states (`GameOver`): `?`, `game_over_vezniNaTroskach_fleedDuel`
* time-of-day sets (`AdvanceWorldTime`): 4 with a wired value
* player gear: DeleteNondivisibleItems_FromSoul x1, DisableHorseInventory x1, EquipPlayersItem x3, PlayerOutfitOverride x1, soul_nonquestitemsconfiscation x2
* teleports: NPCs_TeleportIngame x3
* level switch: `story_switch_to_kutnohorsko`
* locations / locks: DisableDoorInteractivity x2, LockDoor x1, areatrespassleveleffect x1, keepdooropen x2, keepdoorunlocked x4, opendoorandkeepopen x8, unlockdoorandkeepunlocked x27

### M30 `posledniPomazani`
* time-of-day sets (`AdvanceWorldTime`): 1 with a wired value
* level switch: `story_switch_to_trosecko`
* player switch: to 1 in `hibernable`

### M31 `prijezdNaSuchdol`
* forced conversations (6): `jost__audience`, `katerina_pojdme_na_audienci`, `katerina__vyhodnoceni_vyzvy`, `schovanka__vstavej`, `zizka__pojdme_na_audienci`, `polylog__vecere_`
* also 9 fader and 0 player-started conversations with the player (counted, not listed)
* Rendered cutscenes: `prijezdNaSuchdol_pistaFlashback`
* Ingame cutscenes: `prijezdNaSuchdol_jostCutscenePart1`, `prijezdNaSuchdol_jostCutscenePart2`, `prijezdNaSuchdol_arrivalCutscene`
* Fader cutscenes: `prijezdNaSuchdol_customJostDialogFader`, `prijezdNaSuchdol_nearbyArenaTrialog`, `prijezdNaSuchdol_katerinaChallengeFader` (player repositioned), `prijezdNaSuchdol_teleportFader`, `prijezdNaSuchdol_streamFaderStart`
* SkipTime cutscenes: `prijezdNaSuchdol_fakeSleepBeforeNightmare` (to 8h), `bathhouse_skipTime_1h` (skips 1h)
* Text cutscenes: `prijezdNaSuchdol_suchdolFewDaysLater`
* scripted-fight modules: 2 (listed in §5.3)
* fail states (`GameOver`): `game_over_prijezdNaSuchdol_crimeComitted`
* time-of-day sets (`AdvanceWorldTime`): 8h30m, 18h, 17h30m
* player gear: EquipPlayersItem x2, PlayerOutfitOverride x11, playerequipitemandcreateifnotininventory x8, unequipallplayersitems x1
* teleports: NPCs_TeleportIngame x1, PlayerAction_TeleportOnHorse x1
* locations / locks: DisableDoorInteractivity x1, FilterInput x2, areatrespassleveleffect x4, keepdooropen x2, keepdoorunlocked x1, unlockdoorsandkeepdoorsunlocked x4

### M32 `sedmStatecnych`
* forced conversations (7): `hlavni_debriefing_v_certovce`, `forsovany_zizka_dialog_pro_cutscenu`, `trialog_s_zizkou_a_kubenkou`, `kubenka_po_sebrani_zbrani__8`, `kubenka_jde_na_misto_b__3`, `jindra_vyjednava`, `zizka_rozkazuje_a_debatuje`
* also 7 fader and 0 player-started conversations with the player (counted, not listed)
* Ingame cutscenes: `sedmStatecnych_meetingWithKubenka` (player repositioned), `sedmStatecnych_assault` (player repositioned)
* Fader cutscenes: `sedmStatecnych_afterAssault` (player repositioned), `sedmStatecnych_startQuest` (player repositioned), `sedmStatecnych_afterFight`, `sedmStatecnych_afterNegotiation`, `sedmStatecnych_prepareAssault`
* FastTravel cutscenes: `sedmStatecnych_fastTravelToCertovka`
* background sequences (`PlayTrackView`): 1
* scripted-fight modules: 2 (listed in §5.3)
* fail states (`GameOver`): `?`
* story deaths: 2 scripted kill nodes, 0 permadeath guards
* time-of-day sets (`AdvanceWorldTime`): 10h00m
* player gear: DeleteNondivisibleItems_FromSoul x1, EquipPlayersItem x2
* teleports: NPCs_TeleportOnHorse x4, PlayerAction_TeleportOnHorse x1
* locations / locks: DisableDoorInteractivity x1, IntermissionTriggerByDistance x1, leavelevelhandling_v2 x1

### M33 `hledaniLichtenstejna`
* forced conversations (6): `kozina__nacapan_v_doupeti`, `kozina__prechod_do_dialogu_behem_prepadeni_hrace`, `kozina__chycen_po_prepadeni`, `nemec_kozina__hrac_zasahuje`, `nemec__po_kole_kostek`, `lichtenstejn__jindra_vypravi`
* also 32 fader and 1 player-started conversations with the player (counted, not listed)
* Ingame cutscenes: `hledaniLichtenstejna_meetLichtenstejn` (sets 3h), `hledaniLichtenstejna_courtTrap` (sets 3h), `hledaniLichtenstejna_courtTrap_inside` (sets 3h), `hledaniLichtenstejna_samuelWins` (sets 3h), `hledaniLichtenstejna_samuelLost` (sets 3h)
* Fader cutscenes: `hledaniLichtenstejna_fader`
* SkipTime cutscenes: `hledaniLichtenstejna_waitForKozina` (skips 0d0h39m), `bathhouse_skipTime_3h` (skips 3h; player repositioned)
* scripted-fight modules: 4 (listed in §5.3)
* story deaths: 0 scripted kill nodes, 1 permadeath guards
* time-of-day sets (`AdvanceWorldTime`): 22h, 3h
* forced sleep / wake: 1 (PlayerAction_WakeUpOnBed)
* player gear: UnequipPlayersArmorSlots x1
* teleports: NPCs_TeleportIngame x1
* locations / locks: leavelevelhandling_v2 x2

### M34 `kralovskeStribro`
* forced conversations (7): `forced_po_kostkach`, `vokrak_a_prepadeni`, `vokrak_a_prepadeni_holec`, `ruthard_a_roza_po_bitce__forced_1`, `ruthard_a_roza_po_navratu`, `forced_konfrontace_burese`, `dialog_s_pregeri_1`
* also 36 fader and 0 player-started conversations with the player (counted, not listed)
* Ingame cutscenes: `kralovskeStribro_fightAtRuthardsMansion`
* Fader cutscenes: `kralovskeStribro_streamVokrak`, `kralovskeStribro_encounterWithVokrak`
* scripted-fight modules: 7 (listed in §5.3)
* story deaths: 0 scripted kill nodes, 6 permadeath guards
* locations / locks: LockDoor x6, areatrespassleveleffect x2, banusageofdoorswithexclusionarea x1, leavelevelhandling_v2 x5

### M35 `zachranaPtacka`
* forced conversations (12): `polylog_s_vavakem_final`, `zajimani_start`, `force_dialog_se_strazi_po_time_skipu`, `force_straz_po_area_triggeru`, `ruthardi_a_vavak_polylog`, `ruthard__uvodni_multilog_s_oderinem`, `ruthard__navazny_dialog_o_questu`, `ptacek_a_drabant__klaustrofobni_trialog`, `dialog_s_civilem_muz__podkoni`, `dialog_s_civilem_zena__kucharka`, `dialog_s_civilem_zena__ofka`, `alternativni_utek__trialog`
* also 13 fader and 4 player-started conversations with the player (counted, not listed)
* Ingame cutscenes: `zachranaPtacka_enemiesGather` (player repositioned), `zachranaPtacka_caponSaved`, `zachranaPtacka_escapingMalesovThroughGate`, `zachranaPtacka_escapingMalesovThroughSecretPassage` (player repositioned)
* Fader cutscenes: `zachranaPtacka_vavakFightFenceStream`
* SkipTime cutscenes: `zachranaPtacka_afterRuthardGuardDialog` (to 7h0m)
* Text cutscenes: `zachranaPtacka_holeDigging` (player repositioned), `zachranaPtacka_wallDismantling` (player repositioned), `zachranaPtacka_guardLeadingPlayerToRuthard`, `zachranaPtacka_caponThroughSecretPassage`
* scripted-fight modules: 1 (listed in §5.3)
* fail states (`GameOver`): `game_over_zachranaPtacka_brabantDied`, `game_over_zachranaPtacka_caponDied`, `game_over_zachranaPtacka_caponLostDuringRide`
* story deaths: 2 scripted kill nodes, 2 permadeath guards
* time-of-day sets (`AdvanceWorldTime`): 6 with a wired value
* player gear: DisableHorseInventory x1
* teleports: NPCs_TeleportIngame x2, NPCs_TeleportOnHorse x1, PlayerAction_TeleportOnHorse x1, PlayerAction_TeleportWithItems x2
* locations / locks: DisableDoorInteractivity x1, LockUp x1, keepdooropen x2, keepdoorunlocked x1, leavelevelhandling_v2 x1

### M37a `setkaniVRatbori1`
* forced conversations (21): `forced_dialog_s_ptackem_po_cs`, `zide`, `bohuta_se_bavi_s_lichtenstejnem`, `oderin_krystof_adler_ruthard_a_bohuta`, `seznameni_s_krystofem_1`, `bohuta_licht_a_jost__odevzdani_questu`, `stolba_pristihl_bohutu_v_trespassu`, `stolba_se_zpovida`, `majordomus__fail_dialog`, `dialog_zadani__rosenthal`, `splneni`, `dialog_zadani__plummel`, `splneni`, `rychtar__fail_dialog`, `zikmund_kara_konsele`, `pripitek_s_kralem`, `zikmund_rika_jindrovi_at_zustane`, `franta__prioritni_po_napadeni_hracem`, `franta_kuldanu__new_withou`, `trialog_franta_krejci_jindra`, `rozhovor_na_rozcesti`
* also 21 fader and 2 player-started conversations with the player (counted, not listed)
* Ingame cutscenes: `setkaniVRatbori1_transferRatbor` (sets 14h30m), `setkaniVRatbori1_rozporVKoalici` (sets 14h30m), `setkaniVRatbori1_zaverRady` (sets 14h30m), `setkaniVRatbori1_zikmundIntro` (sets 14h30m), `setkaniVRatbori1_transferCouncil` (sets 14h30m), `setkaniVRatbori1_start_cutscene` (sets 6h), `setkaniVRatbori1_retinueLeave_cutscene` (sets 6h)
* Fader cutscenes: `test_teleport`
* SkipTime cutscenes: `setkaniVRatbori1_skipTime_waitingForFranta` (skips 1h)
* Text cutscenes: `setkaniVRatbori1_ratbor`, `setkaniVRatbori1_skipTime_waitingForCouncil_textCutscene`, `setkaniVRatbori1_counsil`
* background sequences (`PlayTrackView`): 2
* scripted-fight modules: 1 (listed in §5.3)
* fail states (`GameOver`): `game_over_bohutaArrested`, `game_over_setkaniVRatbori1_SigismundDead`, `game_over_setkaniVRatbori1_disGuiseBlown`, `game_over_setkaniVRatbori1_kuttenbergCouncilStartedWithoutHenry`, `game_over_setkaniVRatbori1_mayhemAtCouncil_text`
* story deaths: 0 scripted kill nodes, 1 permadeath guards
* time-of-day sets (`AdvanceWorldTime`): 6h, 14h30m, 6h
* player gear: DisableHorseInventory x1, EquipPlayersItem x6, PlayerOutfitOverride x1, RestrictWeaponsInQAM x1, UnequipPlayersItem x13, soul_nonquestitemsconfiscation x1
* teleports: NPCs_TeleportIngame x4, NPCs_TeleportOnHorse x2, PlayerAction_TeleportOnHorse x1
* locations / locks: DisableDoorInteractivity x3, FilterInput x6, LockUp x1, areatrespassleveleffect x5, keepdooropen x5, keepdoorunlocked x5
* player switch: to 1 in `h.bohuta_na_ratbori.cin_m3730k_setkaniratbor__transfer_ratbor`; to 0 in `h.kunohorsky_snem_2.cin_m3760k_setkaniratbor__transfer_council`

### M37b `setkaniVRatbori2`
* forced conversations (6): `se_samem_a_rabinem`, `s_bohutou_zizkou_a_certem`, `s_ptackem_a_lichtenstejnem`, `martin_oderin__kartac_za_vloupani_do_kulny`, `slechticny__baleni_alternativni_poslani_pro_vino`, `sluzebna_dasa__vino_baleni`
* also 7 fader and 0 player-started conversations with the player (counted, not listed)
* Ingame cutscenes: `setkaniVRatbori2_partyStart_cutscene` (sets 23h), `setkaniVRatbori2_ratborAttack_cutscene` (sets 23h; player repositioned), `setkaniVRatbori2_henryArrives_cutscene` (sets 23h; player repositioned)
* Fader cutscenes: `setkaniVRatbori2_endQuestCleanupFader`, `setkaniVRatbori2_beforePostSkirmishDialogFader`
* SkipTime cutscenes: `setkaniVRatbori2_bohutaSexFader` (skips 1h), `setkaniVRatbori2_bohutaSexFaderCensored` (skips 1h)
* Text cutscenes: `setkaniVRatbori2_laterThatEvening`
* scripted-fight modules: 3 (listed in §5.3)
* story deaths: 3 scripted kill nodes, 0 permadeath guards
* time-of-day sets (`AdvanceWorldTime`): 22h0m
* player gear: EquipPlayersItem x5
* teleports: NPCs_TeleportIngame x3, PlayerAction_TeleportOnHorse x1
* locations / locks: FilterInput x1, LockUp x2, areatrespassleveleffect x2, keepdooropen x3, keepdoorunlocked x1
* player switch: to 1 in `hibernable.cin_m3770k_setkaniratbor__night_ratbor`; to 0 in `hibernable.cin_m3790k_setkaniratbordva__henry_arrives`

### M38 `sedmStatecnych2`
* forced conversations (11): `s_banditou_matousem`, `diagnoza`, `s_hansem_o_zranenem`, `leceni`, `s_hansem_z_uher__prioritni`, `s_hraci_kostek_po_boji`, `s_reznikem`, `s_borutem_po_bitce_`, `bude_mi_zle`, `navrat_ztracenych_synu`, `polylog_s_mikesem_a_kozlikem_po_nebakove`
* also 39 fader and 3 player-started conversations with the player (counted, not listed)
* Ingame cutscenes: `sedmStatecnych2_cutscene_hangmanHill`, `sedmStatecnych2_cutscene_komarHanged`, `sedmStatecnych2_cutscene_komarHanged_shot`
* Fader cutscenes: `sedmStatecnych2_dialogCamp`, `sedmStatecnych2_hansTeleportToCertovka`, `sedmStatecnych2_buryingRanek`, `sedmStatecnych2_playerConscious`, `sedmStatecnych2_streamHangingScene`, `sedmStatecnych2_teleportToCertovka`, `sedmStatecnych2_partyStart` (player repositioned)
* Text cutscenes: `sedmStatecnych2_partyPhase1`, `sedmStatecnych2_partyPhase2` (player repositioned)
* background sequences (`PlayTrackView`): 1
* scripted-fight modules: 7 (listed in §5.3)
* fail states (`GameOver`): `game_over_sedmStatecnych2_baillifExecutedHans`, `game_over_sedmStatecnych2_komarHanged`, `game_over_sedmStatecnych2_playerCameLateToSaveKomar`, `game_over_sedmStatecnych2_playerLeftKomarToDie`, `game_over_sedmStatecnych2_playerLeftMiskoviceAndHansDied`
* story deaths: 2 scripted kill nodes, 0 permadeath guards
* time-of-day sets (`AdvanceWorldTime`): 23h00m, 12h00m
* forced sleep / wake: 1 (PlayerAction_WakeUpOnBed)
* player gear: DeleteNondivisibleItems_FromSoul x1, EquipPlayersItem x13, PlayerOutfitOverride x2
* locations / locks: keepdoorunlocked x1, leavelevelhandling_v2 x1

### M42 `pogrom`
* forced conversations (7): `trialog_se_zachranenymi_lidmi`, `rozhovor_po_sesednuti`, `sam_matka_a_henry`, `trialog_u_matky_doma`, `hospoda_vycistena_a_sam_prichazi`, `dialog_s_lichtem_aby_hrac_sel_omrknout_hluk`, `uvodni_polylog`
* also 3 fader and 6 player-started conversations with the player (counted, not listed)
* Ingame cutscenes: `pogrom_defendSynagogue` (sets 6h; player repositioned), `pogrom_blockadeFire` (sets 6h)
* Fader cutscenes: `pogrom_loadingInSkirmishNearSynagogue` (player repositioned)
* FastTravel cutscenes: `pogrom_fastTravelToCertovka`, `pogrom_fastTravelToKutnaHora`
* background sequences (`PlayTrackView`): 4
* scripted-fight modules: 10 (listed in §5.3)
* fail states (`GameOver`): `DiedWhileUnconscious`, `game_over_licht_died_alone`, `game_over_licht_is_dead`, `game_over_pogrom_henryDiedByHalberd`, `game_over_sara_is_dead`
* story deaths: 8 scripted kill nodes, 0 permadeath guards
* time-of-day sets (`AdvanceWorldTime`): 23h00m, 06h00m
* player gear: DisableHorseInventory x1
* teleports: NPCs_TeleportIngame x1
* locations / locks: DisableDoorInteractivity x6, FilterInput x1, IntermissionTriggerByDistance x1, areatrespassleveleffect x2, keepdooropen x2, keepdoorunlocked x1

### M44a `zikmunduvTabor`
* forced conversations (16): `dialog_s_katzem__zadani_vysetrovani`, `ve_spitalu__kontrola_cherthana__nova_verze`, `forced__zacatek_chlastani`, `ditrich_po_kostkach`, `dialog_po_polylogu__jindra_a_katz`, `polylog_po_cs__ditrich_grozav`, `custom_dialog__s_katerinou_v_laznich`, `odjezd`, `forced_poly__naverbovani`, `straz_nacapala_jindru_a_vyhazuje_ho`, `ohledavani_tela`, `polylog_po_soudu__s_grozavem`, `polylog_po_soudu__s_vranou`, `youre_finally_awake__musa_po_omdleni`, `soud_s_musou__polylog`, `uvodni_polylog_misto_cs`
* also 48 fader and 8 player-started conversations with the player (counted, not listed)
* Ingame cutscenes: `cin_m4420k_zikmundtabor__cuman_murder` (sets 23h), `cin_m4430k_zikmundtabor__ambush_praguers_boomVar` (sets 7h30m), `cin_m4430k_zikmundtabor__ambush_praguers_no_boomVar` (sets 7h30m)
* Fader cutscenes: `zikmundtabor_initHaste`, `cin_m4430k_zikmundtabor_streamingPreparations`, `zikmundtabor_ambushFastForwardPreparation` (player repositioned), `zikmunduvTabor_teleport_toCertovka`, `zikmundtabor_bodyInvestigation`, `zikmundtabor_katerinaToCamp`
* SkipTime cutscenes: `zikmunduvTabor_skipTimeBeforeMurder` (to 23h), `zikmunduvTabor_skipTimeBeforeTrial` (to 9h00m)
* FastTravel cutscenes: `zikmunduvTabor_FT_toCertovka`
* scripted-fight modules: 5 (listed in §5.3)
* fail states (`GameOver`): `DiedInCombat`, `LostABattle`, `game_over_crime_execution`, `game_over_zikmundunduvTabor_musaGuardKilled`, `game_over_zikmundunduvTabor_timeLimitOut`
* story deaths: 6 scripted kill nodes, 1 permadeath guards
* time-of-day sets (`AdvanceWorldTime`): 7h00m
* forced sleep / wake: 12 (wake_up)
* player gear: DeleteNondivisibleItems_FromSoul x1, EquipPlayersItem x1, PlayerOutfitOverride x1
* locations / locks: IntermissionTriggerByDistance x3, LockUp x2

### M44b `utokNaMalesov`
* forced conversations (18): `dialog_se_samem`, `dialog_s_brabantem`, `dialog_s_certem`, `dialog_s_katerinou`, `dialog_pouze_s_mikesem`, `polylog_s_mikesem_a_kozlikem`, `planovaci_polylog_posledni_cast__certovka`, `planovaci_polylog__certovka`, `planovaci_polylog__tvrz_malesov`, `planovaci_polylog__vesnice_malesov`, `polylog_s_komarem_a_`, `uvodni_dialog_se_zizkou`, `zizka_po_prepadu_o_stealthu`, `zizka_pred_prepadem`, `polylog_s_ptackem_a_zizkou__po_boji`, `vyjednavaci_force_polylog_s_bergovem`, `force_dialog_s_certem`, `force_polylog_se_zizkou_o_stealthu`
* also 6 fader and 13 player-started conversations with the player (counted, not listed)
* Ingame cutscenes: `utokNaMalesov_cannonFired` (player repositioned), `utokNaMalesov_killingVillager`, `utokNaMalesov_duelWithCertLost` (player repositioned), `utokNaMalesov_duelWithCertWon`, `utokNaMalesov_duelWithCertEnd` (player repositioned)
* Fader cutscenes: `utokNaMalesov_prepareCertovkaMeetup`, `utokNaMalesov_assaultInVillageInitialization` (player repositioned), `utokNaMalesov_prepareTowerForSiege`, `utokNaMalesov_killingVillagerTeleport`, `utokNaMalesov_certDuel` (player repositioned)
* SkipTime cutscenes: `utokNaMalesov_certovkaEveningMeetup` (to 18h0m)
* Text cutscenes: `utokNaMalesov_gateOpening`, `utokNaMalesov_stealthMissionInitialization` (player repositioned)
* unresolved cutscenes: x2
* background sequences (`PlayTrackView`): 7
* scripted-fight modules: 16 (listed in §5.3)
* fail states (`GameOver`): `DiedWhileUnconscious`, `game_over_utokNaMalesov_Alarm`
* story deaths: 5 scripted kill nodes, 4 permadeath guards
* time-of-day sets (`AdvanceWorldTime`): 8 with a wired value
* forced sleep / wake: 1 (PlayerAction_WakeUpOnLastUsedBed)
* player gear: DisableHorseInventory x1
* locations / locks: DisableDoorInteractivity x3, FilterInput x2, IntermissionTriggerByDistance x1, areatrespassleveleffect x1, keepdooropen x2

### M45 `papezskyLegat`
* forced conversations (14): `roza__varuje_jindru_pred_otrapy`, `forced__roza_u_vstupu_do_tunelu`, `roze_se_nechce_pres_vodu`, `roza__vola_z_okna_dialog`, `ph_jindra_1brabant_komar__italstina_pro_zacatecniky`, `zizka__pred_odjezdem_do_kh`, `zizka_a_cert__plan_heistu`, `poly_zizka__pokyny_pred_prepadem`, `vykradaci_hrobu__dialog`, `poly_zizka_cert_brabant__rozdeluje_dalsi_ukoly`, `polak_a_uher`, `polylog__vyslech_bergova_a_plan_akc_e`, `kristian__o_planu_klici_atd_30`, `kristianovy_gorily__dialog_u_dveri`
* also 34 fader and 1 player-started conversations with the player (counted, not listed)
* Ingame cutscenes: `papezskyLegat_prepadeniLegata` (sets 6h), `papezskyLegat_smrtLegata` (sets 6h15m), `papezskyLegat_nocSRozou` (sets 19h30m), `papezskyLegat_nocSRozou_noSex` (sets 19h30m)
* Fader cutscenes: `papezskyLegat_teleportToRuthardka`, `papezskyLegat_rozaOpensDoor`, `papezskyLegat_puttingOnRobes`
* SkipTime cutscenes: `papezskyLegat_timeskipDoRana` (to 6h; player repositioned), `papezskyLegat_timeskipDoRanaWithRoza` (to 6h; player repositioned), `papezskyLegat_timeskipDoLorce` (to 4h)
* FastTravel cutscenes: `papezskyLegat_travelToLegate`, `papezskyLegat_returnToRuthardka`
* Text cutscenes: `papezskyLegat_travelToRuthardka`, `papezskyLegat_pointOfNoReturn`, `papezskyLegat_beforePolylogSuchdol`
* scripted-fight modules: 6 (listed in §5.3)
* fail states (`GameOver`): `game_over_papezskyLegat_crimeCommitedSuchdol`, `game_over_papezskyLegat_legateGotTooFar`
* story deaths: 3 scripted kill nodes, 0 permadeath guards
* time-of-day sets (`AdvanceWorldTime`): 6h, 6h15m, 0h, 0h, 6h, 18h00m, 19h30m, 18h, 12h, 15h, 17h30m
* forced sleep / wake: 1 (PlayerAction_WakeUpOnBed)
* player gear: DisableHorseInventory x5, PlayerOutfitOverride x2, UnequipPlayersArmorSlots x2
* teleports: NPCs_TeleportIngame x4, NPCs_TeleportOnHorse x3
* locations / locks: DisableDoorInteractivity x10, LockDoor x2, areatrespassleveleffect x3, keepdooropen x3, keepdoorunlocked x17, leavelevelhandling_v2 x1, unlockdoorsandkeepdoorsunlocked x2

### M46 `prepadeniVlasskehoDvora`
* forced conversations (24): `souvenir_shop`, `cp_brana_vlasskeho_dvora`, `cp_uvodni_slovo_legata`, `cp_zaverecne_slovo_drunk`, `cp_zaverecne_slovo_serious`, `cp_zaverecne_slovo_sober`, `cp_team_barbora`, `cp_team_opasedlec`, `dialog_s_kucharem_a_nazem`, `dialog_s_mestany`, `hans_uher_hint_dialog`, `cp_giuseppe_vita_krajana`, `force_polylog_v_krypte`, `cd_trashtalk_s_erikem`, `hans_a_bohuta_sedi_na_lavici`, `vyjednavani_s_csabou`, `polylog_po_osvobozeni`, `polylog_na_dvore`, `cp_zizka_na_hradbach`, `polylog_po_kuchyni`, `cp_brabant_a_ptacek__komar_chybi`, `cp_porada_v_kuchyni`, `brabant_a_ptacek_pred_bran`, `cp_zachrana_komara`
* also 16 fader and 2 player-started conversations with the player (counted, not listed)
* Ingame cutscenes: `prepadeniVlasskehoDvora_saveHenry` (sets 23h), `prepadeniVlasskehoDvora_wagonChase` (sets 22h45m), `prepadeniVlasskehoDvora_courtHall` (sets 19h30m), `prepadeniVlasskehoDvora_brabantTreason` (sets 23h), `prepadeniVlasskehoDvora_komarDeath` (sets 23h), `prepadeniVlasskehoDvora_lords`, `prepadeniVlasskehoDvora_lordsBrotherDead`, `prepadeniVlasskehoDvora_treasury`, `prepadeniVlasskehoDvora_cellarHole`, `prepadeniVlasskehoDvora_zizkaRobbery`, `prepadeniVlasskehoDvora_sex`, `prepadeniVlasskehoDvora_sexCensured`
* Fader cutscenes: `prepadeniVlasskehoDvora_street`, `prepadeniVlasskehoDvora_entrance`, `prepadeniVlasskehoDvora_trialog1`, `prepadeniVlasskehoDvora_kitchen`
* unresolved cutscenes: x4
* background sequences (`PlayTrackView`): 3
* scripted-fight modules: 9 (listed in §5.3)
* fail states (`GameOver`): `game_over_bohutaArrested`, `game_over_obranaNebakov_allGuysFallen`, `game_over_prepadeniVlasskehoDvora_bohutaExposed`
* story deaths: 4 scripted kill nodes, 1 permadeath guards
* time-of-day sets (`AdvanceWorldTime`): 23h, 22h45m, 23h; 7 with a wired value
* forced sleep / wake: 1 (PlayerAction_WakeUpOnBed)
* player gear: DisableHorseInventory x1, EquipPlayersItem x9, PlayerOutfitOverride x2, UnequipPlayersItem x1, unequipallplayersitems x1
* teleports: NPCs_TeleportIngame x1, NPCs_TeleportOnHorse x1
* locations / locks: DisableDoorInteractivity x5, areatrespassleveleffect x1, banusageofdoorswithexclusionarea x1
* player switch: to 0 in `h`; to 0 in `h.jindra__kryptou_do_ruthardky`; to 0 in `h.jindra__skirmish_v_ruthardce`; to 1 in `h.bohuta__cesta_do_vlasskeho_dvora.cutscena_a_prepnuti_hrace`; to 0 in `h.jindra__vlassky_dvur_ow.uvodni_polylog_a_priprava`; to 0 in `stealth.jindra__stealth_ve_vlasskem_dvore.prepnuti_hrace_a_priprava_npc`

### M47 `erik`
* forced conversations (5): `hrac_mluvi_s_erikem`, `hrac_mluvi_s_kubenkou_a_s_hansem`, `polylog_s_chlastajicimi`, `trialog_s_ptackem_a_kunstatem`, `zizka_probudil_hrace_a_rika_o_armade`
* also 15 fader and 4 player-started conversations with the player (counted, not listed)
* Ingame cutscenes: `erik_nocNaHradbach` (sets 3h), `erik_odjezdMestanuAPrijezdKubenky` (sets 10h), `erik_odjezdMestanuAPrijezdKubenky_rozaRomance` (sets 10h), `erik_prazaneTahnouNaSuchdol_erik`, `erik_prazaneTahnouNaSuchdol_noErik`, `erik_porazkaErikaAPrijezdArmady` (sets 16h), `erik_prijezdNaKopec` (sets 15h30m)
* Fader cutscenes: `erik_trialogSPtackemAKunstatem`
* Text cutscenes: `oblehani_punishment`
* scripted-fight modules: 1 (listed in §5.3)
* fail states (`GameOver`): `DiedInCombat`, `game_over_crime_execution`, `game_over_erik_chaseFailed`, `game_over_oblehaniSuchdole_crime`
* time-of-day sets (`AdvanceWorldTime`): 7h45m, 11h30m, 17h, 16h, 15h30m
* locations / locks: FilterInput x1

### M48a `oblehaniSuchdole`
* forced conversations (13): `bohuta_zadava_prohlidku_hradu`, `strazny_byl_probuzen`, `verbovani_dobrose_pera`, `janek_a_jaroslav`, `verbovani_mikese_a_kozlika`, `rozkazy__mikes_a_dobros`, `rozkazy__mikes_a_kozlik`, `rozkazy__wolfram_a_dobros`, `rozkazy__wolfram_a_kozlik`, `verbovani_sama_a_kubenky`, `trialog_lazaret`, `polylog_na_hradbach`, `zizka_chvali_hrace_a_ptacka`
* also 15 fader and 5 player-started conversations with the player (counted, not listed)
* Rendered cutscenes: `oblehaniSuchdole_zacinaOblehaniCasosber`
* Ingame cutscenes: `oblehaniSuchdole_odrazeniUtokuZPochodu`
* Fader cutscenes: `oblehaniSuchdole_zizkaVezeZasobyAJeNapaden`, `oblehaniSuchdole_streamPrvniBitvy`, `oblehaniSuchdole_afterOrder`
* Text cutscenes: `oblehani_punishment`, `oblehaniSuchdole_bedTimeSkip` (player repositioned)
* background sequences (`PlayTrackView`): 25
* scripted-fight modules: 4 (listed in §5.3)
* fail states (`GameOver`): `DiedWhileUnconscious`, `game_over_oblehaniSuchdole_crime`, `game_over_oblehaniSuchdole_gate_breached`
* story deaths: 7 scripted kill nodes, 1 permadeath guards
* time-of-day sets (`AdvanceWorldTime`): 16h00m, 15h37m, 01h30m
* forced sleep / wake: 1 (PlayerAction_WakeUpOnBed)
* player gear: EquipPlayersItem x1
* teleports: NPCs_TeleportIngame x1
* locations / locks: DisableDoorInteractivity x1, FilterInput x1, IntermissionTriggerByDistance x1, LockDoor x1, keepdooropen x2, keepdoorunlocked x3

### M48b `rutinaAVypad`
* forced conversations (6): `porada_v_palaci`, `zizka_mluvi_o_samote_s_jindrou`, `s_certem_po_vypadu`, `vyber_muzu__ras_wolfram`, `vyslech_zajatce_s_certem`, `trialog_presvedcovani_raneneho`
* also 25 fader and 2 player-started conversations with the player (counted, not listed)
* Ingame cutscenes: `rutinaAVypad_cutscene_siegeContinues` (sets 16h), `rutinaAVypad_cutscene_assaultResult` (sets 16h30m)
* Fader cutscenes: `rutinaAVypad_startAssault`
* background sequences (`PlayTrackView`): 32
* scripted-fight modules: 13 (listed in §5.3)
* fail states (`GameOver`): `DiedInCombat`
* story deaths: 13 scripted kill nodes, 0 permadeath guards
* time-of-day sets (`AdvanceWorldTime`): 10h0m, 16h00m, 17h00m
* player gear: EquipPlayersItem x2
* teleports: NPCs_TeleportOnHorse x1
* locations / locks: DisableDoorInteractivity x1, keepdooropen x1, keepdoorunlocked x1

### M48c `hladAZmar`
* forced conversations (14): `ingame_bohutovo_kazani`, `polylog_beseda_s_musou`, `musa_predava_polevku_z_bot`, `podkoni_zadava_projizdku`, `cert__vzdavaci_dialog`, `cert_chce_jist_psa`, `cert_predava_jidlo`, `s_katerinou_po_bezvedomi_v_boji_s_certem`, `louceni_s_bohutou_a_s_kubenkou`, `louceni_s_hansem_uhrem_a_s_certem`, `polylog_planovani_cesty_pro_posily`, `rozlouceni_s_ptackem`, `s_katerinou_pred_odchodem`, `s_zizkou_o_katerine`
* also 26 fader and 12 player-started conversations with the player (counted, not listed)
* Ingame cutscenes: `hladAZmar_hunger_despair` (sets 11h), `hladAZmar_court_siezed` (sets 17h), `hladAZmar_bohuta_preaching` (sets 12h30m), `hladAZmar_tower_seized` (sets 17h)
* Fader cutscenes: `hladAZmar_playerLostDuel` (player repositioned), `hladAZmar_eatingTheDog`
* SkipTime cutscenes: `hladAZmar_shoeSoupCooking` (skips 1h), `hladAZmar_dogSoupCooking` (skips 1h)
* unresolved cutscenes: x3
* background sequences (`PlayTrackView`): 12
* scripted-fight modules: 14 (listed in §5.3)
* story deaths: 3 scripted kill nodes, 0 permadeath guards
* time-of-day sets (`AdvanceWorldTime`): 11h, 21h30m, 22h30m, 12h30m, 17h
* forced sleep / wake: 1 (PlayerAction_WakeUpOnBed)
* player gear: PlayerOutfitOverride x2, UnequipPlayersItem x1, copyplayersitemtosoul x44
* teleports: NPCs_TeleportIngame x1, PlayerAction_TeleportWithItems x1
* locations / locks: DisableDoorInteractivity x2, FilterInput x3, LockUp x1, banusageofdoorswithexclusionarea x1, keepdoorunlocked x20
* player switch: to 1 in `h.bohuta_kaze.cin_m4860k_oblehanisuchdol__bohuta_preaching`; to 0 in `h.bohuta_kaze.cin_m4860k_oblehanisuchdol__bohuta_preaching`

### M49 `stealthMiseZaJindru`
* forced conversations (5): `vraceni_noze_pozdeji`, `finalni_dialog_s_aulitzem`, `post_fight_dialog`, `dialog_se_samem`, `dialog_na_brane`
* also 4 fader and 2 player-started conversations with the player (counted, not listed)
* Ingame cutscenes: `stealthMiseZaJindru_openingCutscene`, `stealthMiseZaJindru_aulitzIntro`, `stealthMiseZaJindru_aulitzKill`, `stealthMiseZaJindru_aulitzBrutal`, `stealthMiseZaJindru_aulitzSpare`, `stealthMiseZaJindru_finishWithoutSam`, `stealthMiseZaJindru_finishWithSam`
* Fader cutscenes: `stealthMiseZaJindru_interactiveBarnDoor`
* scripted-fight modules: 2 (listed in §5.3)
* story deaths: 5 scripted kill nodes, 1 permadeath guards
* time-of-day sets (`AdvanceWorldTime`): 00h00m
* player gear: DisableHorseInventory x1, EquipPlayersItem x1
* locations / locks: FilterInput x1, LockDoor x1, areatrespassleveleffect x1, banusageofdoorswithexclusionarea x1, leavelevelhandling_v2 x1

### M50 `zoufalaObranaZaBohutu`
* forced conversations (4): `bohuta_chlasta_s_ptackem_na_hradbach`, `bohuta_chlasta_s_ptackem_v_jidelne`, `bohuta_s_ptackem_chlastaji_ve_staji`, `bohuta_s_ptackem_rvou_na_prazany_z_hradeb`
* Rendered cutscenes: `zoufalaObranaZaBohutu_battleEndingCutsceneGameEnd`, `zoufalaObranaZaBohutu_battleOpeningCutsceneGameEnd` (player repositioned)
* Ingame cutscenes: `zoufalaObranaZaBohutu_initialCutscene`
* SkipTime cutscenes: `zoufalaObranaZaBohutu_drinkingWithCapon_morning` (to 10h0m; player repositioned)
* Text cutscenes: `zoufalaObranaZaBohutu_drinkingWithCapon_diningRoom` (player repositioned), `zoufalaObranaZaBohutu_drinkingWithCapon_stables`, `zoufalaObranaZaBohutu_drinkingWithCapon_bastion`, `zoufalaObranaZaBohutu_textIntro`
* background sequences (`PlayTrackView`): 35
* scripted-fight modules: 6 (listed in §5.3)
* fail states (`GameOver`): `game_over_bitvaZaBohutu_courtyard_lost`, `game_over_bitvaZaBohutu_walls_captured`, `game_over_posledniPomazani_wallsLost`
* story deaths: 2 scripted kill nodes, 0 permadeath guards
* time-of-day sets (`AdvanceWorldTime`): 4 with a wired value
* forced sleep / wake: 1 (PlayerAction_WakeUpOnBed)
* player gear: EquipPlayersItem x1, PlayerOutfitOverride x3
* locations / locks: DisableDoorInteractivity x3, FilterInput x2, keepdooropen x1, keepdoorunlocked x1
* player switch: to 1 in the quest root; to 1 in `q.bohuta_se_opije.cin_m4910k_stealthmise__abseil_down2`; to 0 in `zoufala_obrana_za_bohutu.bitevniCast.cin_m5020k_obranabohuta__siege_finale`

### M51 `finale`
* forced conversations (6): `s_bohutou_o_bitve_a_pohrbu`, `finale_s_otcem_a_matkou__obsolete`, `finalni_polylog_merged`, `finalni_polylog_s_rodici`, `debata_s_hanusem_a_ptackem`, `setkani_pratel`
* also 9 fader and 1 player-started conversations with the player (counted, not listed)
* Rendered cutscenes: `finale_jostArmy` (player repositioned), `finale_henryReturnsToTheresa`
* Ingame cutscenes: `finale_victoryGathering` (sets 10h), `finale_treeDream` (sets 19h), `finale_zizkasEye` (sets 19h45m), `finale_zikmundPissed` (sets 2h)
* Fader cutscenes: `finale_beforeBattleFader`, `finale_openGate`, `finale_samuelBurial` (player repositioned), `finale_waitingForSoulPlacementFader`
* Credits cutscenes: `creditsFirst`, `creditsSecond`
* unresolved cutscenes: x2
* background sequences (`PlayTrackView`): 2
* scripted-fight modules: 5 (listed in §5.3)
* fail states (`GameOver`): `DiedWhileUnconscious`
* story deaths: 2 scripted kill nodes, 0 permadeath guards
* time-of-day sets (`AdvanceWorldTime`): 22h40m; 3 with a wired value
* player gear: EquipPlayersItem x1, PlayerOutfitOverride x2, UnequipPlayersArmorSlots x1, weaponandclothingpresetoverride x5
* locations / locks: DisableDoorInteractivity x2, FilterInput x3, LockDoor x1, areatrespassleveleffect x1, unlockdoorsandkeepdoorsunlocked x1
