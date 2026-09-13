# WO-94 — Shared Quests: the readiness prompt (build)

Builds "Yes" on the mechanism WO-92 found (`wh_concept_HasteTrigger`), for
the 32 main-story quests only, with the hazard logging the maintainer's
"fix it when we see it" plan needs. WO-92's verdict and its named tradeoffs
(§6.3, §6.4 there) are taken as decided and are not re-argued here.

Evidence tags, on every claim, never rounded up: **(observed)** read
directly in a file, binary or log, cited; **(code-verified)** traced in
source actually read; **(synthetic)** proven by a harness run this session,
with the count; **(not verified)** built but never seen running.

Path placeholders: `<repo>` = this working tree, `<MT>` = the Modding Tools
install root.

---

## 0. Answer first

* **Built, wired end to end, 497 checks green, not run in a live game.**
  Every live check reached a STOP point (§8) and the maintainer was not at
  the keyboard. No game process existed at any point this session
  **(observed: `tasklist` empty for KingdomCome/KcdMp at start; no live
  channel was opened)**.
* **Scope held.** The registry is exactly the 32 M-coded main quests; side
  quests, activities, events and DLC files have no entry and are refused on
  every path (§3, §7a–b) **(synthetic 94/94)**.
* **Coverage is honest and smaller than the quest count.** 1,014 Haste
  triggers across the 32 quests; 138 carry a position; **53 are fireable**
  (positioned AND cumulative AND not namespaced AND not a Warhorse
  test/debug entry). **Ten quests, including the prologue M01, have no
  fireable beat and will never prompt** (§3.4) **(observed, from the pak)**.
* **The one write is one string:** `wh_concept_HasteTrigger <quest>.<trigger>`
  through `System.ExecuteCommand`, the call already in production for
  `closeVisorOn` **(code-verified, `kdcmp.lua` pre-existing sites)**. Across
  every synthetic scenario it is the only console command the feature ever
  issues **(synthetic, scenario h)**.
* **Nothing pauses**, on any path: no `t_scale`, pause, freeze or dialogue
  kill-switch is issued anywhere **(synthetic, scenario h)**, and the
  prompt cannot block input because the OnAction hook runs after the game's
  own handler and cannot consume anything (§4.3) **(code-verified)**.
* **Hazard logging shipped on both machines**: `CATCHUP-HAZARD` lines in
  the mod, `[CATCHUP-HAZARD …]` tags on the agent, only inside a window,
  naming the beat, who fired it, and how long ago (§6) **(synthetic,
  scenario f)**.
* **WO-90's divergence release is untouched except one constant**: the
  stand-off is 180 s (was 60). Its own 70-check suite still passes with the
  lapse moved to 181 s **(synthetic 70/70)**.

---

## 1. Phase 0 — ground truth

* `main` at `42b1b1a` (WO-92's head) at session start, clean; `git pull`
  reported up to date **(observed)**.
* `docs/WO-92-findings.md` read in full; `docs/WO-90-findings.md` §3–§4
  read. **No WO-91 doc or commit exists** (`git log --all | grep WO-91`
  empty; `ls docs | grep 91` empty) — same as WO-92 found **(observed)**.
* No game running at any point. The `:1403` and `:4600` channels were never
  used **(observed)**.
* `<MT>/Data/Scripts.pak` sha256
  `bf3eca1046f4c2cb619a005cada24ea8cb0b2c9a598b5882e4ec3d6160485166`,
  79,397,175 bytes — byte-identical to the pak WO-92 worked from
  **(observed)**.

---

## 2. Phase 1 — the pieces that stood regardless of the Yes-path

### 2.1 The keys: F11 / F12, from the dice code, not re-derived

`kdcmp/Data/Libs/Config/keybindSuperactions.xml:1009-1016` **(observed)**:

```xml
<superaction name="kcd2mp_dice_bank" …>  <action name="kcd2mp_dice_bank"  map="interaction"/> <control input="f11" …/>
<superaction name="kcd2mp_dice_yield" …> <action name="kcd2mp_dice_yield" map="interaction"/> <control input="f12" …/>
```

`defaultProfile.xml:140-141` registers both with `onPress="1" onRelease="1"`
**(observed)**. In `kdcmp.lua`, `ACCEPT_ACTIONS` already contains
`kcd2mp_dice_bank` and `DECLINE_ACTIONS` already contains `kcd2mp_dice_yield`
— the dice-invite prompt has used exactly these two for accept/decline
since WO-33 **(code-verified)**. The readiness prompt binds to the same two
tables, nothing new.

**Why this is safe by construction (stated, per the work order, not
re-derived):** the dice board's branch in `handleAction` consumes these
actions only while `KCD2MP.dice.open` is true, and it runs before the quest
branch and returns. A readiness prompt raised during a live match therefore
waits, unanswered, until the match closes; a press never reaches two
consumers. The invite branch runs first of all and has the same property.
Order in the hook: invite → dice board → **quest prompt** → dice invite →
combat mirrors → sneak **(code-verified; synthetic scenario e proves both
precedences)**.

### 2.2 The overlay: what draws the ping, and whether it can hold a line

`KCD2MP_LabelTick` re-arms itself every 8 ms (`Script.SetTimer(8, …)`) and
each tick calls `System.DrawText(10, 10, KCD2MP.pingText, 2)` when
`pingText` is set, then `KCD2MP_DrawInteractionUI` **(code-verified,
`kdcmp.lua` ~4807–4827)**. `DrawText` is immediate-mode — one frame per call
— so persistence is nothing more than "the state is still set on the next
tick"; there is no engine-side timeout to fight. The invite line clears
itself only because `KCD2MP_DrawInteractionUI` compares `shownAt` against
`INVITE_TIMEOUT` (30 s) **(code-verified)**. The readiness prompt has no
such comparison and is drawn for as long as `KCD2MP.quest.prompt` is set —
an hour of fake clock later it is still drawn **(synthetic, scenario d)**.

Two caveats that are facts, not risks invented here:

* The label loop **starts only when the agent connects**
  (`KCD2MP_StartInterp`), so with no agent there is no prompt — irrelevant,
  since without an agent there is no peer either **(code-verified, comment
  at the end of `KCD2MP_LabelTick`)**.
* Rows: ping 10, invite 60/84, message 110, dice hint 134, **quest prompt
  160/184, catch-up status 208** — no overlap with any existing row
  **(code-verified)**.

### 2.3 The registry — bounded, generated, cross-checked

See §3.

### 2.4 The stand-off: 60 s → 180 s

`MP_NPC_DIVERGE_COOLDOWN_S = 180.0` (`kdcmp.lua:2346`), one constant; the
release log line prints it, so the field will read "for 180s"
**(code-verified; synthetic scenarios g here and f in WO-90's suite)**.
Nothing else in the divergence rule changed: threshold 8 m, 3 hits in 30 s,
receiver-side, one-sided **(code-verified, diff)**.

---

## 3. The main-quest registry

### 3.1 How "main quest" is identified — not guessed

Every quest XML root under `Quests/Final` is `<Quest Name="…" … >`; the
main-story ones carry `ProductionCode="M<nn>"`. Census over all 21,649
files: exactly **32** roots with an M code — `M01 prepadeni` through
`M51 finale`, including the lettered `M37a/b`, `M44a/b`, `M48a/b/c`
**(observed)**. None sits in a `dlc*`-named file; the DLC quests
(`Barbora/dlc2_*`) have no M code **(observed)**. The 32 match WO-92 §6.1's
"all 32 main-story quests M01–M51" exactly, and `Type=` on `<Quest>` is
never "Main" in this corpus (Activity 66, Micro 54, Side 62, Event 1,
Racing 1) — the production code is the only marker **(observed)**.

The extractor (`tools/Build-MainQuestRegistry.ps1`) aborts unless it finds
exactly 32, and aborts if any M-coded file name contains `dlc`
**(code-verified)**.

### 3.2 Path grammar — verified against Warhorse's own strings

WO-92 §6.1 gives `<questName>.<triggerName>` with intermediate modules
flattening unless `HasteNamespace="true"`. This session validated that
against the paths Warhorse authored *inside the same 32 quests* as
`wh_concept_hasteTrigger <path>` console strings: 37 distinct strings, 31
naming a main quest, **22 match the computed set exactly, 0 mismatches**,
and 9 are stale — 5 name `posledniPomazani.complete*` triggers that live in
`zoufalaObranaZaBohutu`'s files, 4 name triggers that exist nowhere in the
pak **(observed)**. The build aborts on any *grammar* mismatch (trigger
exists in the named quest under a different computed path) and merely
reports stale strings **(code-verified)**.

**Namespaced triggers (30 of 1,014) are never emitted as fireable.** No
main-quest namespaced path is authored anywhere in the corpus (the only
three-segment authored paths are `01_rpg.*`, a debug module), so their
grammar is unverifiable here **(observed)**. They are counted in the CSV.

### 3.3 Where a beat "is" — position resolution

A trigger's plan is: Prerequisites first (an array of `ConceptPaths`), then
its own `ConsoleCommands` one string at a time (WO-92 §6.1,
code-verified there). The extractor walks that order, following nested
`wh_concept_hasteTrigger` commands and prerequisite paths within the same
quest, and takes the **last player relocation** it meets **(code-verified)**:

| Form | Count in the 32 quests | Resolved as |
|---|---|---|
| `goto X Y Z …` | 149 seven-token + 9 three-token | fixed point |
| `goto <entity>` | 324 | level entity, resolved live |
| `playerGoto <level> X Y Z …` | (part of 182 `playerGoto`/`playergoto`) | fixed point + level |
| `playerGoto <entity>` | (rest) | level entity |

**(observed, `Value="…"` census.)** Arrays are `MakeArray` → `Constant`
children in document order, or `JoinArrays` recursively; 5 triggers hang
off a `Function`/`Switch` output and are recorded as unresolved
**(observed)**.

Result: **138 positioned** (57 fixed-point, 81 entity). The two maps'
coordinate ranges overlap, so fixed-point beats carry their quest folder's
level (`trosecko` / `kutnohorsko`) and the mod skips them when the loaded
level is known to differ; entity beats are level-safe by themselves
**(code-verified; synthetic scenario c)**.

### 3.4 Which beats are fireable — and the coverage that follows

Fireable = positioned **and** cumulative (has Prerequisites or fires other
triggers — Warhorse's "set the world up for this point" entry, not a lone
setter or a bare teleport) **and** not namespaced **and** not named
`test|debug|gamescom` (four such: `socky.debug_initAndStart`,
`bohutovaVlozka.testOnly_startQuestSkipIntro`,
`sedmStatecnych2._gamescom_activatePoint`,
`finale.commonDebugReconstruction`) **(observed)**.

**53 fireable beats**: 36 entity-positioned, 17 fixed-point; 20 positioned
by their own commands, 33 by their chain **(observed)**. Longest path 54
chars against a 128 wire budget **(observed)**.

| Code | Quest | Triggers | Fireable |
|---|---|---|---|
| M01 | prepadeni | 22 | **0** |
| M02 | zachrana | 32 | **0** |
| M03 | socky | 9 | 1 |
| M05 | svatba | 25 | 2 |
| M06 | naTroskach | 16 | **0** |
| M07 | nebakovPruzkum | 24 | 3 |
| M08 | mucirna | 34 | 1 |
| M09 | utokNaNebakov | 43 | 1 |
| M10 | bohutovaVlozka | 30 | 1 |
| M11 | nebakovObrana | 51 | 4 |
| M12 | vezniNaTroskach | 33 | 1 |
| M30 | posledniPomazani | 3 | **0** |
| M31 | prijezdNaSuchdol | 10 | 1 |
| M32 | sedmStatecnych | 18 | 1 |
| M33 | hledaniLichtenstejna | 36 | 1 |
| M34 | kralovskeStribro | 19 | 5 |
| M35 | zachranaPtacka | 21 | 2 |
| M37a | setkaniVRatbori1 | 53 | 3 |
| M37b | setkaniVRatbori2 | 16 | 1 |
| M38 | sedmStatecnych2 | 48 | 1 |
| M42 | pogrom | 40 | 2 |
| M44a | zikmunduvTabor | 50 | **0** |
| M44b | utokNaMalesov | 36 | 1 |
| M45 | papezskyLegat | 27 | 2 |
| M46 | prepadeniVlasskehoDvora | 39 | **0** |
| M47 | erik | 15 | 2 |
| M48a | oblehaniSuchdole | 54 | 1 |
| M48b | rutinaAVypad | 66 | **0** |
| M48c | hladAZmar | 29 | **0** |
| M49 | stealthMiseZaJindru | 8 | **0** |
| M50 | zoufalaObranaZaBohutu | 41 | **0** |
| M51 | finale | 66 | 16 |

**Ten quests never prompt.** The prologue (M01, the quest from WO-90's
field session) has no relocation command anywhere in its 22 triggers, so
there is nothing for proximity to see **(observed)**. This is the mechanism's
data, not a bug in the detector; the CSV lets the maintainer see every
excluded trigger and why.

**Two shapes worth knowing before the first live session:**

* **Most fireable beats are quest-start entries** (`01_initAndStart` and
  kin), positioned where the quest begins. In practice the prompt will
  appear on B when A *starts* a main quest (A's objective marker names it,
  A is standing at its start), asking B to jump to that quest's start.
  Mid-quest beats exist for M34 (mines / smelter / mint), M45, M35, M37a.
* **Same-position ties resolve to the first in registry order.** The finale's
  16 `initAndStart_*` variants all sit on `finale_previousQuestEnd` and
  encode story choices (Mikeš/Wolfram, Kozlík/Dobroš, Sam, dog). Firing
  variant 01 imposes those choices on B — a concrete instance of WO-92
  §6.3's accepted inconsistency, named here so it is not a surprise.
  Pruning is a CSV/registry edit, no code.

A wider rule (positioned single setters that drive a State node, not
cumulative) would add 11 beats **(observed)**. Not adopted: WO-92 §6.1's
lever is the cumulative replay.

### 3.5 Bounded, by construction

The Lua table is generated between two markers and committed; nothing at
runtime can add a quest or a beat. Every peer-supplied string is refused
unless it is a registered fireable path — checked in the agent for shape
(`StoryBeat.IsValidBeatPath`: ASCII `[A-Za-z0-9_.]`, one dot, ≤128) *before*
it is interpolated into Lua, and again in the mod against the registry
(`KCD2MP_QuestIsRegistryBeat`) before it can reach the screen or
`ExecuteCommand` **(code-verified; synthetic scenarios a, d, e and 26 unit
tests)**.

**Side content triggers none of this, verified explicitly:** with the
player standing exactly on `kralovskeStribro.02_startMines` while the
current quest is `semin` (a real side quest from the field log), or unknown,
or M01, no approach is emitted and no prompt can exist **(synthetic,
scenario b)**; `semin.init`, `combat_tutorial_pro.start`,
`dlc2_selling__days_outside_kh_counter.init` and an injection-shaped string
are all refused **(synthetic, scenario a)**.

---

## 4. Phase 2 — the wiring

### 4.1 The flow

1. **Agent → mod: context.** The log tail already parses the
   `questNameOverride` marker (WO-90). WO-94 extracts the quest half,
   lowercased (`@qname_poslednipomazani_1DR8` → `poslednipomazani`; the
   engine lowercases `posledniPomazani` there — field log 2026-08-25
   **(observed)**), and pushes `KCD2MP_QuestSetCurrent`. The engine's level
   banner `============================ Loading level trosecko ============================`
   (observed twice across the field bundles) is parsed into
   `KCD2MP_QuestSetLevel`. Both are re-pushed on the agent's existing 2.5 s
   re-arm so a restarted game's fresh Lua gets them **(code-verified)**.
2. **Mod, 1 Hz on the emitter tick:** nearest un-announced fireable beat of
   the current quest inside `mp_quest_radius` (35 m) → one
   `[KCD2-MP-EVT] quest_approach <quest>.<trigger>`; a beat re-announces
   only after 10 min **(code-verified; synthetic c)**.
3. **Agent → relay → agent:** StoryBeat `0x37` kind 2 with the path; the
   relay copies the body verbatim (unchanged code, `TcpBroadcastService`);
   a WO-90 receiver checks `kind == 1` and drops it, so no version bump
   **(code-verified, `ClientSession.cs:463-470`, `GameBridge` receive
   branch)**.
4. **Receiving agent:** prompt only when *both* objectives are known and
   differ (`_localObjective` vs `_peerObjective[g]`, exact string) →
   `KCD2MP_QuestShowPrompt(g, who, path, 1)`; otherwise the same call with
   `0`, which the mod logs and ignores **(code-verified; synthetic d)**.
5. **Mod:** validates against the registry, refuses declined beats and
   beats while a catch-up is running, sets `KCD2MP.quest.prompt`, drawn
   every 8 ms until answered or moot **(synthetic d)**.
6. **F11 / `mp_quest_yes`:** `System.ExecuteCommand("wh_concept_HasteTrigger <path>")`,
   logged before and after (a `pcall` returning true proves only that Lua
   did not throw — WO-43's lesson, stated in the code), native toast,
   hazard window opened, `quest_catchup begin <path>` event → agent sends
   kind 3 **(synthetic e)**.
7. **F12 / `mp_quest_no`:** declined, remembered for the session,
   `quest_catchup decline` event (log only) **(synthetic d, e)**.
8. **Not responding:** nothing. Thirty minutes of fake clock: prompt still
   up, no command, no event; WO-90's release fires underneath and stands
   off 180 s **(synthetic g)**.
9. **Moot:** peer leaves, or the pair's objectives converge on either side's
   next marker → `KCD2MP_QuestPromptMoot` **(code-verified; synthetic d)**.

### 4.2 Confirming the trigger name for a beat

Every fireable path in the Lua table came out of the XML by name, and the
grammar was cross-checked against 22 Warhorse-authored paths with no
mismatch (§3.2). Cross-reference to WO-90's observed beat: the field
objective `@qname_prepadeni_KsSs|@prepadeni_nasleduj_ptacka_ZyXB` resolves
to quest `prepadeni` = M01, whose 22 triggers are all in the CSV
(`01_init`, `endQuest`, `hibernation.*`, …) and none of which is positioned
— so for that specific beat the honest answer is "confirmed to exist,
confirmed not fireable by proximity" **(observed)**.

### 4.3 The overlay intercepts nothing — static proof, live check pending

`Player.Client.OnAction` is wrapped as
`origCA(...) ; handleAction(...)` — the game's handler runs first,
unconditionally, and our hook's `return` only ends *our* handler
**(code-verified, `kdcmp.lua` Player hook block)**. In the harness a
stand-in for the game's handler is installed *before* the splice and is
called exactly twice (press + release) for every key, including while the
prompt is up and while it fires **(synthetic e)**. F11/F12 have nothing
else bound anywhere in the shipped action map — the WO-6 comment block
records that each was pressed live, one at a time, and watched
**(observed, comment; inherited, not re-tested here)**. What static reading
cannot show is whether *rendering* a DrawText row interferes with anything;
it is the same call the ping has used since WO-1 with no such report, and
it is on the live list (§8).

---

## 5. The Yes-path — built exactly on WO-92

* Command: `wh_concept_HasteTrigger <quest>.<trigger>` (WO-92 §6.1's
  registration; the cvar name is case-insensitive at the console — Warhorse's
  own arrays spell it `wh_concept_hasteTrigger` 143 times and
  `wh_concept_HasteTrigger` 22 times in the same quests **(observed)**; the
  mod uses the documented capitalisation).
* Channel: `System.ExecuteCommand` from mod Lua, in production at
  `kdcmp.lua` (`closeVisorOn`) — WO-92 §2.1 **(code-verified)**.
* Precondition WO-92 left open, still open: **does a `VF_CHEAT` command
  execute as the launcher starts the game** (§9 there, static reading says
  yes, never observed). If it does not, `kcd.log` will carry
  `[CVARS]: [EXECUTE] command wh_concept_HasteEnable is marked [VF_CHEAT]`
  and the fix is `-devmode` on the launcher's `ProcessStartInfo`. This is
  the first live check (§8) **(not verified)**.
* Fires only registry beats; a second fire is refused while a window is
  open; `mp_quest_fire <path>` exists for the solo probe and has the same
  gate **(synthetic e)**.

---

## 6. Hazard logging — the six paths, each with a hook

WO-92 §6.4 named six ways a replay on one machine reaches the other. Each
has a distinct line that appears **only inside a window** — a local one
(this machine fired) or a peer-announced one (kind 3 received) — and names
the beat, who fired it, where, and the age in seconds. Outside a window the
same events print only their ordinary lines **(synthetic f: 0 hazard lines
before the fire, tagged during, 0 after the 120 s close)**.

| WO-92 hazard | Mod line (`kcd.log`, `[KCD2-MP] CATCHUP-HAZARD <kind> …`) | Agent tag (`[CATCHUP-HAZARD …]` suffix) |
|---|---|---|
| 1 untracked teleport | `teleport-local` (own position > 60 m/s between 1 Hz samples); `teleport-ghost` (ghost snap > 5 m in the interp) | ghost position jump > 50 m and > 60 m/s between samples |
| 2 killed shared NPC | `npc-death` (observer's alive→dead), `npc-death-remote` (peer's FATAL applied), `player-death` (own, edge) | on every FATAL sent (two sites) and every FATAL applied |
| 3 dragged/streamed NPC | `npc-dragged` (a WO-90 divergence release) | — |
| 4 SaveGame-baked ghost | — (a SaveGame node leaves no runtime edge to hook; the WO-84 detector for the *result* still runs) | — |
| 5 world-clock jump | `clock` (any `ApplyTimeSkip` write, with the delta) | `[timeskip] clock jumping …` and `clock went backward …` |
| 6 cutscene suspends chains | `chain-suspend` (WO-78's "was suspended, not dead" verdict) | `Rendered cutscene STARTED/ended` on the tail's edge |

Hazard 4 has no runtime hook and is stated as such; everything else is
wired **(code-verified; synthetic f exercises remote death, clock, own
death, local teleport, chain-suspend, peer window; the ghost-teleport and
agent tags are code-verified only)**.

The window is 120 s (`mp_quest_window`), from WO-92's measured drain
(2 s GameTime per command, single-node plans synchronous). Every window
open/close is itself logged, with the session's hazard count at close.

---

## 7. Phase 3 — verification

### 7.1 Synthetic — `tools/Test-WO94Synthetic.ps1`, 94 checks

(a) bounded registry, refusals; (b) side content triggers nothing;
(c) proximity: once per beat, nearest wins, radius, other-map skip,
level-unknown behaviour, entity beat live/absent, `mp_quest_sync off`;
(d) prompt state machine incl. one-hour persistence and decline memory;
(e) keys incl. exact command string, invite and dice-board precedence, the
game's own handler always running, `mp_quest_fire`/`mp_quest_test_prompt`
gates; (f) hazard window on both sides, expiry, silence outside; (g) not
responding + WO-90 release with the 61 s/181 s lapse; (h) no pausing
command, and `wh_concept_HasteTrigger` the only command ever issued.

Whole suite this session, all green: Lua 48 + 35 + 72 + 47 + 70 + **94** =
366; C# 72 (46 + **26** new) + 59 = 131. **497 checks, 0 failures.**
`dotnet build KCD2-MP.sln`: 0 errors, the same 8 warnings as WO-89
**(observed)**.

### 7.2 Live — every one a STOP point, none run

None of the following has happened. See §8 for exactly what the maintainer
must do.

1. `wh_concept_HasteEnable` bare query → does the cheat gate let it through.
2. `mp_quest_test_prompt` → the two rows render at 160/184 and persist;
   walking, looking, opening the inventory and fighting all still work
   with the rows up.
3. F11 / F12 on a real keyboard → `QUEST-CATCHUP FIRE` / `QUEST-PROMPT
   declined` in `kcd.log`.
4. `mp_quest_fire <beat>` on a **disposable save** → the engine's own
   lines after the fire (WO-92 §10 rungs 1–3 apply verbatim).
5. Two machines, real objectives differing → the approach crosses, the
   prompt appears on the right side only, lead time is usable.

### 7.3 What only a real two-player session can confirm

* That a peer's prompt shows the beat *they* would recognise as "the next
  step" — the registry positions are Warhorse's own jump points, not the
  quest designer's objective markers.
* Whether 35 m is enough lead: ~12 s on foot, ~3 s at a gallop.
* Which of the six hazards actually fire in practice, and whether the
  ordinary WO-90 release plus the hazard lines are enough to "fix it when
  we see it".
* The finale-variant tie (§3.4) — whether B ever wants variant 01 imposed.

---

## 8. STOP-rule compliance

**No live game was launched, attached to, or commanded. No Lua was injected.
Neither `:1403` nor `:4600` was used. No file in either game install was
modified. No save was touched.** The Modding Tools' `Scripts.pak` and the
scriptbind docs zip were *read* (copied to the session scratchpad and read
there) **(observed)**.

Points reached and stopped, in order:

| # | Point | State |
|---|---|---|
| 1 | Phase 2.2 — confirm the overlay does not intercept input: static proof done (§4.3), live confirmation needed | **Stopped.** Built everything that does not need it first. |
| 2 | Phase 3.2 — F11/F12 reach the prompt | **Stopped.** |
| 3 | Phase 3.2 — overlay renders and persists | **Stopped.** |
| 4 | Phase 3.2 — proximity fires with lead time | **Stopped.** |
| 5 | Phase 3.2 — the force-advance does what WO-92 verified | **Stopped.** |
| 6 | Phase 4 — release cut | **Not started.** It follows Phase 3 in the work order and the release notes must state Phase 3's outcome; the maintainer may direct "skip live, cut it" and it proceeds. |

**What the maintainer needs to do, solo, on a disposable save, agent
connected (so the label loop runs):**

1. Launch through the launcher as usual. In the console: `wh_concept_HasteEnable`
   (bare). Then in `kcd.log` grep `HasteEnable`. A value line = the gate is
   open; a `[VF_CHEAT]` refusal = report it, the fix is one launcher line.
2. `mp_quest_status` — expect the "QUEST sync is ON (32 main quests, 53
   fireable beats …)" line and your current quest, if it is a main quest.
3. `mp_quest_test_prompt` — two text rows appear under the ping. Walk, look
   around, open and close the inventory, draw a weapon, sit at a table.
   Report anything that stops working while they are up.
4. Press **F12**. The rows disappear; `kcd.log` has `QUEST-PROMPT declined`.
5. `mp_quest_test_prompt socky._initAndStart` (M03's start, Troskovice;
   any registered beat works) then press **F11**. Expect
   `QUEST-CATCHUP FIRE #1: wh_concept_HasteTrigger socky._initAndStart`,
   the toast, the "Catch-up in progress" row, and then — this is the real
   test — whatever the engine logs next. Any `CATCHUP-HAZARD` lines in the
   following 120 s are the point of the feature; paste them.
6. Bundle `kcd.log` and the agent log via COLLECT LOGS as usual.

Then say "go" for Phase 4, or "skip live" to cut the release with Phase 3
recorded as not run.

---

## 9. Corrections and notes for standing belief

* **WO-92 §7's recommendation ("build the prompt on reads, not writes") was
  overridden by the maintainer**, knowingly; this session built the write.
  The read half (approach detection, divergence gate) is exactly what WO-92
  recommended and is the larger part of the code.
* **`goto <entityName>` is the common form, not `goto x y z`.** WO-92 counted
  536 goto arrays; in the 32 main quests, 324 of the `goto` values name an
  entity and 158 carry coordinates **(observed)**. Entity-positioned beats
  are resolved live and turned out to be the majority of the fireable set
  (36 of 53).
* **Warhorse's own Haste debug strings go stale.** Nine authored paths in
  the main quests point at renamed or moved triggers. Anyone using authored
  strings as ground truth must filter, as the extractor does.
* **The `Loading level <name>` banner is a usable level signal** the agent
  never had; WO-92 §6.4 hazard 1 ("no level identity on the wire at all")
  now has a local half. It is still not on the wire.
* **The 8 build warnings are unchanged from WO-89**; none is in WO-94 code.

## 10. Named, not attempted

1. The live ladder (§8) — the whole of Phase 3.2.
2. Phase 4 — the release cut, blocked on the STOP rule, ready to run.
3. Putting the level on the wire (hazard 1's other half).
4. Pruning same-position variants (finale) in the registry — a data edit
   the maintainer can make in `KCD2MP_MAINQUESTS` or by adding a filter to
   the extractor; the CSV has every candidate.
5. A wider fireable rule (+11 single setters) if the 53 prove too sparse.
6. `SaveGame`-node hazard (WO-92 hazard 4) — no runtime hook exists; the
   post-hoc detector from WO-84 is the only coverage.
