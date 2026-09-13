# WO-92 — can a player's story state be force-advanced?

Investigation only. No feature was built, no `VERSION` change, and **no live game
was touched at any point in this session** (§8 lists every point where the
session stopped and why).

The question, as posed: *can a player's real story/quest state be safely
advanced to match another player's, and does it produce a genuinely consistent
world, not just a matching counter.*

Evidence tags, used on every claim and never rounded up:
**(observed)** — read directly in a file or binary, cited by path and
offset/line; **(code-verified)** — traced in disassembly or source actually
read; **(read-but-unrendered)** — documentation says so, not confirmed in a
shipped binary; **(inconclusive)** — the evidence does not decide it.

Path placeholders: `<repo>` = this working tree, `<MT>` =
the Modding Tools install root, `<RT>` = the retail install root.

---

## 0. Answer first

**Track A is not empty, and the reason WO-90 thought it was is a
methodological error this session found and corrected.**

There is a sanctioned story-advance lever: `wh_concept_HasteTrigger`, Warhorse's
own in-house story-jump facility, reachable today through the console channel
the mod already uses, with no new plumbing. **(code-verified, Modding Tools)**

**Track B was genuinely attempted and is a dead end for writes.** The RTTR
route — which looked strong, and which this project already has working
machinery for — fails on two independent grounds. The native export route
yields a real *read* surface and a trigger *pulse*, but no state setter
anywhere. **(code-verified)**

**And the consistency answer, which is the one that actually matters:**

> Haste is genuinely better than a state write — it injects at the same graph
> edge the real gameplay event drives, so the one-shot consumers really do
> fire. But it leaves seven named things unreconstructed, and in *this mod's
> shared world* a replay on one machine reaches into the other player's machine
> through six live paths. For the multiplayer question specifically the answer
> is **no**.

**Verdict, in the work order's own vocabulary: *exists but produces an
inconsistent world* — with the inconsistency named exactly (§6), plus *read
works, no safe write was found* for the native track (§5, §7).**

A single-player "jump me to beat N" would be defensible on this evidence. The
thing WO-92 was asked about — converging two live players — is not, as things
stand.

---

## 1. Phase 0 — ground truth

* `main` is at `05c9cb3`, WO-90's head, working tree clean. **(observed)**
* `docs/WO-90-findings.md` read in full.
* **There is no `docs/WO-91-findings.md`, and no WO-91 commit on any branch**
  (`git log --all --oneline | grep -i WO-91` → empty). WO-91 was written but
  never run. This session is entirely fresh ground on this question.
  **(observed)**

### 1.1 What WO-90 actually established, stated precisely

WO-90 §1's headline reads as "no quest system is reachable". The precise claim
is narrower and it matters: there is no quest **scriptbind**. The quest
**system** is fully present. This session confirms the narrow claim and
strengthens it in one direction while refuting the framing in another (§2).

---

## 2. THE CORRECTION — WO-90 gated on the wrong build

This is the single most consequential finding of the session, because it is
why a real lever went unseen.

WO-90 §3.2 states its method explicitly: *"every 'ships on this build' claim
below was confirmed by a retail string check."*

**The mod never runs on retail.** **(code-verified)**

| Gate | Evidence |
|---|---|
| Installer targets Modding Tools only | `installer/SteamDetect.iss:16` `#define ModdingToolsAppId "2429020"`, with the comment *"Retail KCD2 is a separate entry (1771300, installdir KingdomComeDeliverance2) and cannot run this mod"* |
| Installer aborts on retail | `installer/KCDMP.iss:742-747` — *"The KCD2 Modding Tools were not found, so there is nowhere to install the mod."* |
| Launcher refuses at startup | `KCDMP_launcher/Pages/Home.razor.cs:249` |
| Launcher refuses at Launch | `KCDMP_launcher/Pages/Home.razor.cs:483` — *"That looks like the retail game."* |
| Field sessions were Modding Tools | `docs/WO-58-test-logs/HostBundle/kcd.log:11` `Executable: …\KCD2Mod\Bin\Win64ReleaseSteamLTO_DLL\KingdomCome.exe`; same on the second machine at a different drive letter **(observed)** |

The discriminator is `Framework.dll` **and** `CrySystem.dll` beside the exe
(`Home.razor.cs:1101-1107`; the identical test at `SteamDetect.iss:85-92`, with
a comment saying it is deliberately the same). Retail ships 6 DLLs beside the
exe; Modding Tools ships 45. **(observed)**

**Consequence:** a Modding-Tools-only lever *is* usable by real players, and a
retail-absence result does **not** disqualify anything. WO-90's gate produced a
false negative. Every "ships on this build" question in future work orders
should be asked of the Modding Tools build.

### 2.1 The channel is already built

`GET http://localhost:1403/api/System/Console/ExecuteString?command=…`
— with a leading `#` the payload is Lua, **without it the payload is a console
command**. Both are in production use today. **(code-verified)**

* Lua: `dotnet/KcdMp.Client/HttpGameTransport.cs:225-228`.
* Console commands: `tools/Test-Aggro.ps1:75-79`; live-observed with a stock
  engine command at `docs/WO-30-findings.md:29-32`.
* From inside mod Lua: `System.ExecuteCommand(...)` at `kdcmp.lua:3922`, `:7768`.
* The `:1403` listener is Modding-Tools-only at the binary level —
  `C_ModuleHttpServerListenerManager` lives in `Framework.dll` and is 0-hit in
  the retail monolith. **(code-verified)**

So **no new transport work is needed to reach any console lever.**

---

## 3. Track A — the surface check

### 3.1 Method and scale

The shipped reference at `<MT>/ConsoleHTMLHelp/` was parsed completely:
**6,852 unique command/cvar entries with help text**, cross-validated 1:1
against `index.html`'s anchor list (0 missing, 0 extra). **(observed)**

Control case, to validate the method before trusting it: `wh_ai_PauseNPC` —
documented, and 0-hit across all 29 retail binaries, reproducing WO-90.
**(observed)** Positive control: `wh_ai_` = 665 hits in retail `WHGame.dll`, so
the scanner works.

### 3.2 The quest namespace is read-only

Name searches (with `Request` false positives filtered — 46 of 54 raw "quest"
name hits were `Request`): `quest`=8 true, `objective`=7, `story`=18 (16 of
them `History`), `chapter`=0, `journal`=0, `diary`=0, `playline`=7,
`activity`=15. **(observed)**

Help-**text** search — the "boring name, quest-writing help" hunt: `quest`=7
true of 92 raw, `objective`=25 (24 are dog-AI), `advance`=15 (all the adjective
"advanced"), `set stage`=0. **(observed)**

The whole `wh_quest_*` family, verbatim, is read/debug-draw:

| Command | Help text |
|---|---|
| `wh_quest_ListQuests` | "Lists all quests by name. For next page use wh_quest_ListQuestsPage." |
| `wh_quest_ListQuestsPage` | paging |
| `wh_quest_DebugQuestLog` | "Displays objectives and logs for quest (given by name, use wh_quest_ListQuests)" |
| `wh_quest_DebugQuestLogPage` | paging |
| `wh_quest_DebugQuestMarkers` | "Select quest by name for debug markers" |
| `wh_quest_activity_drawHibernation` | debug draw of the Activity Manager |
| `wh_quest_activity_forceActivityType` | "Next round will only wake this activity type. Use node name" |

Retail's complete `wh_quest_*` set is six names (adding the cvar
`wh_quest_ResetQuestsOnStartGame`); the two `activity_*` ones are
Modding-Tools-only. **(observed)** A reverse sweep over all 14,390
console-name-shaped retail strings found no additional quest/objective/story
command. **(observed)**

**No quest or objective setter console command exists in either build.**

### 3.3 But the lever is one namespace over

`wh_concept_*` — the concept graph **is** the quest state (§4). Retail ships 16
such cvars, all load/reload/debug. The Modding Tools build ships **23**, and
the extra seven are the `Haste` family, including:

> `wh_concept_HasteTrigger` — **"Fires a Haste trigger using its debug name."**

This is the lever. It is absent from retail — which is exactly why WO-90's
retail gate could not see it, and exactly why that gate was wrong.

---

## 4. What quest state actually is

Established from `Data/Scripts.pak`, which is **byte-identical in both
installs** (sha256 `bf3eca1046f4c2cb619a005cada24ea8cb0b2c9a598b5882e4ec3d6160485166`,
79,397,175 bytes) — so no build-drift trap applies to any data claim.
**(observed)**

* **24,401 quest XML files** under `Quests/{Final,Testing,Debug,Autotesting}`.
* A quest is a **Skald concept-node graph**, not a record:
  `<Quest Name=… Type="Micro">` with `<Ports>`, `<Definitions>`, `<Nodes>`,
  `<Objectives>`. **(observed)**
* An **Objective is a display view over a State node**, not the state itself.
  `C_Objective`'s exported API is getters only — **zero `Set*`**.
  **(code-verified)**
* A State node exposes three output kinds, and this is the crux:
  `.State` (the enum), `.<EnumName>` (a **level** bool, true while in that
  value), and `.On<EnumName>` (a **one-shot edge**, fires only on a real
  transition). Census over `Quests/Final`: 23,143 level reads, 7,829 `.State`
  reads, **10,251 `On*` edge reads**. **(observed)**
* The engine really runs two propagation mechanisms, confirmed by two
  separately-guarded recursion limits present in retail:
  `wh_concept_MaxNestedTriggerThreshold` (push) and
  `wh_concept_MaxNestedDataFetchThreshold` (pull). **(code-verified)**
* `E_QuestProgress` has 4 values `{None, Active, Done, Failed}`;
  `E_QuestType` 6, `E_LogType` 5, `E_ObjectiveType` 2 — recovered from retail
  RTTI and independently matched against the shipped XML. **(code-verified)**

**So ~1 in 4 consumers of quest state fires only on a genuine transition.** Any
mechanism that assigns a value rather than driving a transition misses them
permanently. That single fact governs everything below.

---

## 5. Track B — going native

Attempted on three fronts. All three were carried far enough to give a real
answer rather than a shrug.

### 5.1 The RTTR route — not viable, on two independent grounds

This looked like the strongest candidate and had the best prior support: the
project already has a working RTTR ABI (`native/KCDMP/rttr_abi.cpp`), and
memory records NPC health writes and lethal damage verified through it. Retail
*and* Modding Tools both carry the full quest RTTR schema — 44/45 wrapper
descriptors survive into retail, **every one carrying a `set_value` or
`set_as_ptr` policy**. **(code-verified)**

It still fails.

**(a) Semantic — decisive.** `Progress` is declared
`C_TypedPortRef<E_QuestProgress>`: a *reference to a graph port*, not a stored
field. `C_PortRef::Read` (ConceptModule RVA `0x34E500`) resolves a resolver at
`+0x38` to an `I_Port*` and virtual-dispatches; values are produced by
`C_Node::FetchData()`, a **const** method returning a variant **by value**.
Across ConceptModule's 404 exports the entire port surface is
`Read` / `Trigger` / `Unassign` / `FetchData` — **there is no `Write`, no
`SetValue`, no `Assign`**. **(code-verified)**

There is no stored value to overwrite. An RTTR `set_value` would assign the
*PortRef struct* — repointing a live graph edge, which is what the XML
deserializer does at load — and would not fire `.On<Enum>` edges at all,
because edge propagation is `I_Port::Trigger()`, a path `set_value` never
touches. In practice it would most likely just return `false`: the only
registered conversion on `C_TypedPortRef` is `operator E_QuestProgress`, the
*read* direction. There is no enum→PortRef conversion. **(code-verified)**

**(b) Instance — independent.** The chain to a live `C_QuestManager` is real
and fully traced: `GetWritableInstance()` → `C_GameInterface+0xB8` →
`C_ModulesManager::GetModuleByName("QuestModule")` → `C_QuestModule+0x10`. It
**dead-ends there**: `C_QuestManager` has zero exports, no `GetQuest`, no
`FindQuest`, no enumeration reachable by name. **(code-verified)**

**The tell.** `Framework.dll` is the *only* module in the entire install that
imports `property::set_value`, and its call sites are inside
`C_RTTRXMLDeserializer`. **RTTR property writing in this engine exists for
exactly one purpose: deserializing authored graphs from XML at load time.**
The engine's own runtime "make something happen" primitive is `Trigger()`.
**(code-verified)**

### 5.2 The export route — a real read surface, no setter

`QuestModule.dll` exports 89 symbols; 53% are `boost::optional<bool>` template
leakage and the rest are getters. Its "bulk save path"
(`C_QuestModule::LoadGame(C_InputChunk&)`) persists **activity-name strings**,
not quest state. Dead end for writes. **(code-verified)**

The answer was one DLL over. `ConceptModule.dll` exports a complete, callable
**read + pulse** surface:

* Read: `GetGameIface` → `[iface+0x128]` `C_ConceptModule` → `GetConceptManager`
  (`0x1C950`) → `FindNode(path)` (`0x16530`) → `C_Node::GetPort(name)`
  (`0x2B62E0`) → `I_Port::Read()` (slot 16 / `0x2B1CF0`), returning an
  `rttr::variant` — for which ConceptModule even ships a Lua bridge,
  `ConvertRttrVariantToLuaTable` (`0x2AF880`). **(code-verified)**
* Pulse: `?Trigger@C_PortRef@conceptmodule@wh@@UEBAXXZ` (`0x34E610`), takes
  only `this`, forwards to the referenced port's `Trigger` (slot 15). Quest XML
  confirms nodes carry named `Direction="In" Type="trigger"` ports, so this is
  a data-level Haste equivalent. **(code-verified)**
* Also exported and mutating: `ActivateNode` `0x2B8710`,
  `ActivateNodeWithoutSideEffects` `0x2B8760`, `DeactivateNode` `0x2B8900`,
  `Reset(bool)` `0x2B8510`, `Hibernate` `0x2B89A0`, `Wake` `0x2B8AC0`.

**Still missing:** no `I_Port` value setter exists — you can pulse a trigger
port, you cannot assign one. All Modding-Tools-only (retail ships neither DLL
separately). The `C_ConceptPath` grammar `FindNode` expects is unverified.

### 5.3 Lua — confirmed absent, more strongly than WO-90 claimed

* The documented `QuestSystem.*` API (36 methods across two documented classes)
  is **0-hit across all ten extracted binaries in BOTH builds**. It is a stale
  KCD1-era doc page — integer `objectiveId`, "Reload quest DB tables" —
  incompatible with the named-enum graph KCD2 actually runs. It was not cut
  from retail; **it never existed in KCD2**. **(observed)**
* Retail registers 69 scriptbind classes by RTTI. `C_ScriptBindQuest` is not
  among them, and **RTTI is not stripped in retail, so this absence is
  decisive.** **(code-verified)**
* Across 402 scriptbind method names recovered from surviving `__FUNCTION__`
  strings (32 classes), not one is quest-related. **(code-verified)**
* **The shipped game's own Lua never calls the quest system.** 290 `.lua` files
  in `Scripts.pak`; `QuestSystem` appears 12 times, every one a local
  identifier, and there is not a single `QuestSystem.<method>` call anywhere.
  **(observed)**
* The two most-suspected hiding places are clean: `Variables` registers 11
  generic name/value methods with no quest semantics; `Database` likewise.
  **(code-verified)**

---

## 6. The lever, and what it costs

### 6.1 Haste is real, shipped, and armed by default

`wh_concept_HasteTrigger` is registered via `IConsole::AddCommand` (vtable slot
`+0x108`) in MT `ConceptModule.dll` — registration site RVA `0x11d01d`, handler
RVA `0x11d340`, flags `2`. **(code-verified)**

The master switch `wh_concept_HasteEnable` registers with **default value 1**
(`mov r9d,1` at `0x11d05b-0x11d07e`), flags `0x2002` where `0x2000` is
`REQUIRE_APP_RESTART`. **(code-verified — single-source, see §9)**

Firing it validates and fails closed: missing argument, malformed path, unknown
node and container-only node each log a specific warning, return false, and
**mutate nothing**. No crash path was found. **(code-verified)**

On success it resolves the dotted path, runs `Prerequisites` through
`C_HasteTriggerPlanner` (with infinite-loop detection), then per queued trigger
pulses its `OnTrigger` port and executes its `ConsoleCommands` array via
`IConsole::ExecuteString`. Single-node plans fire synchronously; multi-node
plans drain across frames. **(code-verified)**

**Coverage is excellent.** 4,853 `<HasteTrigger>` nodes across 1,763 files in
the whole pak; 3,745 across 1,523 files in `Quests/Final`. **205 of 219 Final
quests (93.6%)** have at least one, and **all 32 main-story quests M01–M51 are
covered** — including `prepadeni` (M01, 22 triggers), the quest from WO-90's
field session. The 14 with none are all peripheral. **(observed)**

Path grammar is `<questName>.<triggerName>`; intermediate module levels flatten
away unless declared `HasteNamespace="true"` (358 such declarations).
**(code-verified)**

**Two prompt premises corrected.** `debug_set*` is *not* "the closest thing to a
targeted setter" — it is 4 triggers out of 3,745 (0.1%). The real
targeted-setter population is **1,432 triggers (38.2%)** whose `OnTrigger`
drives a State node via `SetTrue`/`SetDone`/`SetActive`/etc. Cumulative replay
is **799 (21.3%)**, carried by the `Prerequisites` port, not by name
convention. **(observed)**

### 6.2 Why Haste is genuinely better than a state write

This is the part that surprised the investigation, and it is well-evidenced.

**A HasteTrigger is injected at the same graph edge the real gameplay event
drives** — not at the state field. In
`Quests/Final/Barbora/kutnohorsko/dvojityAgent/zadani_a_otazky_ohledne_janova_ukolu.xml`
the module's `<Output>` carries *both*
`jan__zadani_a_otazky_ohledne_ukolu.jindra_prijima_januv_ukol` (the real
dialogue) *and* `22___Accept_quest_from_Jan.OnTrigger` into the one port.
**Nothing downstream can tell the two apart.** **(code-verified)**

And a State node's `Set<Value>` in-port produces a real transition that pulses
`.On<Value>` — and pulses it **only** on transition. Warhorse's own
`Quests/Debug/Haste/utils/doonce.xml` proves it: a module whose entire body is
`State<bool> did`, `do → SetTrue`, `did.OnTrue → exec`. If `SetTrue` did not
pulse `OnTrue` the module could never fire; if it pulsed on every `SetTrue` it
would not be "once". **(code-verified)**

1,168 of 4,966 `OnTrigger` edges land on State set-ports. 503 edge-triggered
consumers hang off haste-driven States, and all of them fire.

The replay is also **sequential and time-spaced, not a batch**:
`DelayedConsoleExecution` walks the command array one element at a time with a
2-second *GameTime* gap, so each step propagates and streams before the next.
**(code-verified)**

**So a raw state write produces "a matching counter". Haste does not. It solves
the one-shot problem.** That is a real and positive result.

### 6.3 What Haste still does not restore — named exactly

1. **The dialogue `SequenceUsed` ledger, bidirectionally and at scale.** 17,490
   `SequenceUsed` occurrences across 3,075 files; 6,751 `ThisSequenceUsed`
   across 2,725. **6,686 negated `!ThisSequenceUsed()` guards** read false after
   a jump, so conversations that already happened become offerable again; and
   **6,184 positive `SequenceUsed('name')` guards** also read false, so those
   branches become permanently unreachable. Unreconstructible:
   `SetSequenceUsed` / `MarkSequenceUsed` / `ResetSequenceUsed` = **0
   occurrences** in the entire pak. **(code-verified)**
2. **Rewards and quest items, partially.** 157 modules transitively reach
   `<AddReward>` from a HasteTrigger out of 737 nodes; 94 reach
   `<AddQuestItem>` out of 450. Worked failure: `dvojityAgent`'s
   `22___Accept_quest_from_Jan` drives the quest-progress output but not the
   sibling `jan_dava_jindrovi_listinu_s_peceti`, so `jansDocument` stays `None`
   — **quest active, no quest document.** **(code-verified)**
   *Calibrated honestly:* this is the minority case — 2,079 of 2,333 (89.1%) of
   trigger output ports in haste-touched modules **are** haste-driven, and part
   of the remaining 11% are mutually-exclusive branches, not gaps.
3. **Crime memory and NPC schedules**, except where hand-wired. Warhorse's own
   repair module `migration_simple.xml` does exactly three things — forget
   crime data per human soul, re-activate scheduler links by `LinkTag`, apply a
   `fastForward` link effect — and exists in only ~120 instances game-wide.
   **(code-verified)**
4. **Discovered locations / fast-travel network** — essentially outside Haste's
   vocabulary; POI discovery is driven by visiting. Only 107 `ShowMapMarker`,
   8 `POIDiscoveryStatusChangedTrigger` nodes exist. **(code-verified)**
5. **All elapsed-time semantics.** Timers count from `SetRunning`, so every
   "wait N days" clock restarts at the jump moment. 200 modules reach a
   `<Timer>` from a haste trigger. **(code-verified)**
6. **Character progression** — skills, perks, stats are not part of the quest
   graph.
7. **Ordering, for 85% of triggers.** Only 732 of 4,853 declare any
   `Prerequisites` at all. **(code-verified)**

Also: the replay is **state-idempotent but side-effect-repeating**. Re-running
a cumulative entry point is safe for State nodes (DoOnce semantics), but the
`ConsoleCommands` replay unconditionally every time — teleports, kills and item
grants included. **(code-verified)**

### 6.4 The multiplayer hazards — six live paths from B's replay into A

This is the part nobody had looked at, and it is what turns a defensible
single-player mechanism into an indefensible multiplayer one.

| # | Hazard | Evidence |
|---|---|---|
| 1 | **Teleports always cross the wire, and there is no level identity on the wire at all.** B's `goto` appears on A's machine as an instant ghost teleport; A gets no signal B has left. | `kdcmp.lua:274-297` emits `[KCD2-MP-DATA] v2 …` every 20 ms with **no level field**; zero `GetLevelName` anywhere in `kdcmp.lua` or `dotnet/KcdMp.Client/*.cs`. `goto` is 536 of the 764 resolvable `ConsoleCommands` arrays. **(code-verified)** |
| 2 | **A Haste `KillNpc` step can kill the other player's NPCs.** The death observer is **cause-blind** — it announces on any witnessed alive→dead transition — and both NPC sync and death sync default ON. `dvojityAgent`'s own replay contains `40___Kill_all_Laszlos_ambushers`. | `kdcmp.lua:2244` `mp_npc_death_observe`; the only guard is first-sight-already-dead. `kdcmp.lua:2234` `npcDeathSync = true`; `kdcmp.lua:1921` npcSync default. **(code-verified)** |
| 3 | **Streaming divergence is destructive in one direction.** NPCs are addressed by static level entity name across the wire; if B's haste streams a quest NPC somewhere else, whichever side claims it drags the other side's copy to its coordinates. | `kdcmp.lua:2892-2893` drops a stream for an absent entity; name-addressed sync via `SoulsByName`. **(code-verified)** |
| 4 | **`SaveGame` nodes fire from haste and bake a ghost body into B's save** — a failure this project has already root-caused. 170 modules reach a `<SaveGame>` node from a haste trigger. | `docs/WO-84-findings.md:79-81`. **(code-verified)** |
| 5 | **A Haste world-clock advance on B is broadcast to A.** | `GameBridge.cs:344` `TimeJumpThresholdSeconds = 900`; `:1927-1929` reports; `kdcmp.lua:695` applies forward-only. Haste ships explicit time controls (`Quests/Debug/Haste/time.xml` fires `#forwardTime(N)`). **(code-verified)** |
| 6 | **Any cutscene the replay queues suspends every Lua chain on B** — B's emitter stops, A's ghost of B freezes, NPC claims lapse at the 5 s silence expiry. The replay itself is immune, because it runs on the concept graph's own Timer. | `kdcmp.lua:318-336` (WO-78's "SUSPENDED IS NOT DEAD"), restart gate `:362-372`. **(code-verified)** |

Separately: **`07_switchPlayers.bohuta` / `.henry` sit on the same command
surface** and swap the controlled character; 10 modules reach `<SwitchPlayer>`
from a haste trigger. This project has already recorded that a second Player
entity crashes the game (WO-26). **(code-verified)**

### 6.5 It also reverses this project's own architecture decision

`docs/ARCHITECTURE-shared-world.md:10-15` puts quests, dialogue, journal,
reputation and discovered locations on the **private** side, for a stated
reason that still holds (`:29-31`):

> *"Questing **is** world mutation in this game, so the boundary cannot fall
> between world and progression."*

That is not a reason never to revisit it — but it is a decision that must be
reopened deliberately, not walked into.

---

## 7. The read half — "read works" is a real result

Stated separately because the work order explicitly counts it as a valid
outcome.

**What does NOT work, and this refutes the obvious plan:** `wh_quest_DebugQuestLog`
and all three `wh_concept_Debug*` cvars emit through `wh::C_DebugDraw`, which
`vsprintf`s into a 512-byte buffer and hands the string to the renderer's
aux-text object. **There is no `ILog`, no trace write and no `fwrite` on those
paths — nothing they print reaches `kcd.log`.** **(code-verified)** They are
screen-draws, useless to a log-tailing mod. `wh_concept_DebugShowOnlyChanged`
is exactly "the story position as a diff" conceptually, but it is screen-only,
per-frame, and enormous (the chunk it enumerates was measured growing
24,592 → 135,202 bytes over seven saves in one 90-minute game).

**What does work, today:**

1. The shipped `questNameOverride` marker WO-90 already parses
   (`StoryBeat.cs`, wire kinds `0x37`/`0x38`) — coarse: 6 fires in 90 minutes.
   **Note:** the `InitiateSaveGame()` log line itself is **Modding-Tools-only**
   (`Framework.dll`, `C_PlayerProfileWHManager::InitiateSaveGame`), though the
   `QuestNameOverride` save **field** is retail-present. **(observed)**
2. **An unused, denser signal already in the log:**
   `CutscenePlayer::PlayCutscene … from module 'brambora::Barbora::<level>::<quest>::<submodule>::<node>'`
   — fired **14 times** in the same 90 minutes the shipped marker fired 6, and
   it carries the quest's **internal concept-graph name** rather than a
   localisation key. This is the cheapest available win and needs no new
   mechanism. **(observed)**
3. `.whs` saves are **fully open**: `[u32 0xFFFFFFFF][i32 descLen][plaintext
   UTF-8 XML description][zlib blocks][64-byte footer]` — not a zip, not
   encrypted. Quest state is human-readable inside: a `ConceptState` `<Roots>`
   tree with objectives as `<_name value="Started|Active|Done|…"/>` leaves, each
   carrying a `<Logs>` list with `UpdateTime`. **(observed, on copies)**
   Offline-only, so it cannot push a live update — but it is a complete,
   parseable story fingerprint.
4. `soul:HasScriptContext(name)` is a genuine Lua-reachable read of
   quest-driven per-soul state (2,202 `SetEntityContext` + 365 `SetGameContext`
   nodes drive them). It is a behaviour-switch read, not a story fingerprint.
   **(code-verified)**

**Recommendation for the follow-up work order: build the readiness prompt on
kcd.log parsing, and take the `CutscenePlayer` module path first.**

---

## 8. STOP-rule compliance — every point the session paused

Required by the work order's definition of done. **No live game was launched,
attached to, or commanded at any point in this session. No native function was
called. No Lua was injected. Neither the `:1403` nor the `:4600` channel was
used. No file in either game install was modified. No save file was modified,
moved or deleted** — the one save inspected was copied to a scratch directory
first and read there.

Points where the work reached a live-game boundary and **stopped**:

| # | Point reached | Why it stopped |
|---|---|---|
| 1 | Track A found `wh_concept_HasteTrigger` and needed to know whether a `VF_CHEAT` command executes as the launcher starts the game. | Needs a running game. Resolved as far as static analysis allows (§9 open question 1), then stopped. |
| 2 | Needed `wh_concept_HasteEnable`'s **runtime** value (it is `REQUIRE_APP_RESTART`, so a config could override the compiled default). | Needs a running game. Stopped. |
| 3 | Ready to fire the inert probe `wh_concept_HasteTrigger 03_debug.99_debug_home_NOT_IMPLEMENTED`. | Needs a running game **and a disposable save**. Not fired. Procedure written up in §10. |
| 4 | Ready to fire the reversible probe `…hledaniLichtenstejna.60___teleport_katerina`. | Same. Not fired. |
| 5 | RTTR route: ready to attempt `set_property_value` on `nodes::Objective::Progress` to settle §5.1(a) empirically. | Needs a running game, and it is a **moderate-risk write**. Not attempted. Superseded anyway — §5.1 answers it statically. |
| 6 | Export route: ready to validate the instance chain and the `FindNode` path grammar against a live process. | Needs a running game. Not attempted. |
| 7 | Ready to test whether the cause-blind death observer announces for a Haste `KillNpc` — the sharpest cross-player hazard. | Needs **two** machines and two disposable saves. Not attempted. |

Everything that could be settled from static files — Ghidra on
`ConceptModule.dll` / `QuestModule.dll`, the `ConsoleHTMLHelp/` reference, the
quest XML corpus, the binaries, the repo, and a copied save — was done freely
and is reported above.

---

## 9. Confidence, and what is single-source

**The survey pass was adversarially verified**: 24 load-bearing claims
independently re-checked by separate agents — 7 CONFIRMED, 14 OVERSTATED
(corrected in place above), **3 REFUTED**. The refutations are in §11.

**The deep pass was NOT adversarially verified.** All 20 verification agents
failed on a session limit before running. So every claim in §5 and §6 —
including the Haste registration disassembly, `HasteEnable`'s default of 1, the
RTTR semantic argument, and the census numbers — is **single-source**. It is
detailed, internally consistent and heavily cited, but it has not been
independently reproduced. **Treat §6.1's "armed by default" in particular as
code-verified-but-unreplicated**, which is precisely why §10's first step is a
zero-risk read rather than a trigger.

### Open questions that only a live game settles

1. **Does a `VF_CHEAT` command execute at all as the launcher starts the game?**
   Static reading says yes: `CXConsole::ExecuteString` (MT `CrySystem.dll` fn
   `0x27aaf0`) refuses cheat-flagged commands unless `gEnv->[+0x3d2]` is set or
   `CSystem::IsDevMode()` is true; and `CSystem::Init` (`0x1f93d0`) passes
   `devMode=TRUE` unless `-nodevmode` is on the command line, while the
   launcher passes **no arguments at all** (`Home.razor.cs:521-526`).
   **(code-verified, never observed running.)** This is the single thing
   standing between the static result and a working lever.
   The discriminator string to grep for on failure:
   `[CVARS]: [EXECUTE] command wh_concept_HasteEnable is marked [VF_CHEAT]`.
   If it fails, the fix is one line — add `-devmode` to the launcher's
   `ProcessStartInfo`.
2. `wh_concept_HasteEnable`'s runtime value (see §8 point 2).
3. Whether a multi-node `Prerequisites` plan drains reliably, and how long it
   takes — it could span a save/load or a menu and leave a quest half-advanced.

---

## 10. If the maintainer wants to probe this — the safe ladder

**Not run in this session.** Solo, agent stopped, disposable save only, with the
whole save folder copied out first.

* **Rung 0 — zero risk, read-only.** Send `wh_concept_HasteEnable` as a bare
  cvar query over the existing channel and grep `kcd.log` for the value or for
  the `[VF_CHEAT]` refusal. This answers open question 1 and mutates nothing.
* **Rung 1 — provably inert.**
  `wh_concept_HasteTrigger 03_debug.99_debug_home_NOT_IMPLEMENTED`.
  `Quests/Debug/Haste/debug.xml:35` declares it self-closing — no
  `Prerequisites`, no `ConsoleCommands`, no `IsActive` — and its only consumer
  anywhere in the pak is a `<Trace>` node printing a string
  (`debug.xml:132-138`). **(code-verified)**
* **Rung 2 — reversible.**
  `wh_concept_HasteTrigger hledaniLichtenstejna.60___teleport_katerina`. Its
  entire wiring is a one-element array holding
  `goto 3165.71 653.04 53.63 -4.26 0.00 129.65`. Record a bare `goto` first and
  revert with it after. **(code-verified)**
* **Rung 3 — irreversible story mutation.** Anything driving a State node. Only
  on a genuinely disposable save.

**Do not set `wh_concept_HasteOnly`** — it empties the entire concept-graph
load list (fn `0x18b60`), so the game loads only the Haste debug graph and no
quest content at all. **(code-verified)**

---

## 11. Corrections to standing project belief

Three refutations from the verified survey pass, plus two premise corrections:

1. **`wh_sys_LoadGame` is ABSENT from retail.** The apparent retail hit is a
   substring false positive of the unrelated cvar `wh_sys_LoadGameFilter`.
   WO-73's "headless world solved via shipped `wh_sys_LoadGame`" holds for the
   **Modding Tools build only**. Also MT-only: `wh_sys_SaveAllGames`,
   `wh_sys_TestSaveGame`, `wh_sys_TestLoadGame`. **(observed)**
2. **Most `wh_quest_*` entries are CVars, not commands** — you set them to a
   quest name rather than calling them with an argument.
   `wh_quest_DebugQuestLog` is a genuine command. **(code-verified)**
3. **`wh_quest_ResetQuestsOnStartGame` is a string only, not a registered
   console command** — no help string, no adjacent registration. Not a lever.
   **(observed)**
4. **The prompt's `C_BypassedConnections` premise is refuted.** It is the
   connection-storage/re-entrancy policy template parameter of Warhorse's
   generic signal-slot library, not a quest concept and nothing to do with
   bypassing preconditions. `Bypass` appears **0 times** across all 24,401
   quest XML files and `C_BypassedConnections` 0 times in retail.
   **(code-verified)**
5. **`TestModule.dll` contains no unit tests.** The literal `TEST` occurs once
   in 21,340 strings, as the unrelated token `TEST_DIALOG_EXIST`. It is a
   data-driven functional-autotest framework of 163 RTTR-reflected command
   classes, it imports **zero** functions from `QuestModule.dll`, and its four
   quest commands are 100% read-only. The prompt's hope that it would hand over
   a calling convention does not pay out — though it does independently
   corroborate the Haste gate, shipping
   `wh::tests::C_Haste` with the assertion text
   *"Check 'GetGameIface()->GetConceptModule()->GetHasteRegister()' has failed:
   Haste is not supported."* **(observed)**

Two methodology notes for whoever reuses this session's artefacts:

* The pre-extracted string dumps use a **5-character minimum**, silently hiding
  `Main`, `Side`, `None`, `Done`, `Logs`, `Hint`. Go to the raw binary for
  short names.
* Those dumps carry **file offsets, not RVAs**. Several first-pass claims
  quoted them as addresses; map through the PE section table before using one.
  (`.rdata` VA `0x3a03000` / RAW `0x3a02200`, imagebase `0x180000000` for
  retail `WHGame.dll`.)

---

## 12. Named, not attempted

1. **The live probe ladder (§10).** Blocked on a maintainer with a disposable
   save. Rung 0 is zero-risk and answers the one question that gates everything.
2. **The `CutscenePlayer` module-path signal (§7.2).** Already in the log,
   denser than the shipped marker, carries internal names. Cheapest available
   improvement to story telemetry and needs no engine cooperation.
3. **Offline `.whs` story fingerprinting (§7.3).** The format is fully decoded.
   A parser would give complete story state for comparison — read-only,
   offline, zero runtime risk. It cannot push an update.
4. **A no-emit quarantine**, if Haste convergence is ever pursued: the gate is
   not "does Haste work" but "can B's client be fully silenced for the whole
   replay" — emitter, claims and death-announce frozen, plus a forced
   save/reload afterwards, with A never told. Even then §6.3's seven items
   remain.
5. **Re-running the deep pass's 20 adversarial verifiers** (§9). They never
   ran. Until they do, §5 and §6 are single-source.
6. **Auditing other WO-90-era conclusions that used the retail gate** (§2).
   This session found one false negative; there may be more.
