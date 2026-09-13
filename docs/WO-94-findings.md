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

* **Built, wired end to end, and the solo live ladder ran with the
  maintainer at the keyboard on a disposable save (§7.2).** Observed in
  `kcd.log`: the cheat gate is open, Haste is armed, proximity fires at the
  radius with 7 s of lead at a run, **F11 fires exactly the prompted beat
  and the engine drains a 14-trigger Haste plan**, F12 declines, the window
  closes at 120 s, the rows draw and nothing else stops working
  (maintainer's report). **Not live:** the two-machine path (approach
  crossing the wire, peer prompt, peer-side hazard tags) and the two fixes
  the ladder produced (§9), which are synthetic-only.
* **Scope held.** The registry is exactly the 32 M-coded main quests; side
  quests, activities, events and DLC files have no entry and are refused on
  every path (§3, §7.1 a–b) **(synthetic 101/101)**.
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

### 7.2 Live — the solo ladder, run 2026-09-13

Maintainer at the keyboard, disposable save near Troskovice (Trosky map),
agent connected (the **0.21.5 agent** — the new agent was not deployed;
only the pak was swapped, game closed, `Build-And-Install-Mod.ps1`,
relaunch). Console commands were sent from the coding shell over the
`:1403` channel and every result below was read from `kcd.log`; the key
presses and the screen report are the maintainer's.

| # | Check | Result **(observed)** |
|---|---|---|
| 0 | `wh_concept_HasteEnable` bare | engine printed `wh_concept_HasteEnable = 1 [REQUIRE_APP_RESTART]` — Haste armed at runtime |
| 1 | inert trigger `03_debug.99_debug_home_NOT_IMPLEMENTED` | `[CONSOLE] Executing console command …` → `<HasteTrigger> name:'Haste.03_debug.99_debug_home_NOT_IMPLEMENTED' is being triggered from haste` → `<Trace> name:'Haste.03_debug.trace2' not implemented`. **No `[VF_CHEAT]` refusal — WO-92 §9 open question 1 is closed: the cheat gate is open under the launcher.** |
| 2 | mod loaded, `mp_quest_status` | `QUEST sync is ON (32 main quests, 53 fireable beats, radius 35m, window 120s; current=nil level=nil …)` — nil because the old agent pushes neither |
| 3 | context pushed by hand (`#KCD2MP_QuestSetLevel("trosecko")`, `#KCD2MP_QuestSetCurrent("socky")`) | `QUEST level is now 'trosecko'`, `QUEST current main quest: socky (M03 Laboratores, 1 fireable beats)`, then within one tick `QUEST-APPROACH socky._initAndStart (M03) at 19.5m -- announcing to peers` + the `quest_approach` event line — **proximity detection fires live** |
| 4 | prompt raised (`#KCD2MP_QuestTestPrompt("socky._initAndStart")`) | `QUEST-PROMPT shown: TestPeer is nearing socky._initAndStart -- F11 catch up / F12 stay (no timeout)`; maintainer saw the rows and answered them by key |
| 5 | **F11** (pressed by the maintainer — by accident, twice) | `QUEST-CATCHUP FIRE #1: wh_concept_HasteTrigger socky._initAndStart` → `[CONSOLE] Executing console command 'wh_concept_HasteTrigger socky._initAndStart'` → `QUEST-CATCHUP ExecuteCommand returned true` → the engine drained **14 Haste triggers** in planner order: `socky.haste.teleportBeforeEndPreviousQuest` (`goto 2342.72 2068.25 112.25 …`, `TeleportPlayer Player 'Dude' … BEFORE pos=<2346.77 2087.35 111.57>`), `JanPtacek.stream`, `JanPtacek.setNaked`, `level_barrier.stream`, `nakup_koni__trosecko….ActivateSedivka`, `vezicko_kemp_banditu.stream`, **`prepadeni.endQuest`**, `zachrana.hastes.endPreviousQuest`, `bozena.stream`, `jindrich….basicEquip`, `JanPtacek.setBasicChlothingAndWeaponPreset`, **`zachrana.hastes.endQuest`**, `socky.haste.endPreviousQuest`, `socky.haste._initAndStart`; each with a `Readiness observer … started async waiting` / `… is ready` pair. Window closed itself: `QUEST-CATCHUP window closed for socky._initAndStart after 121s (0 hazard lines this session)`. The second press replayed the identical 14-trigger chain including the teleport — **WO-92 §6.3's "state-idempotent, side-effect-repeating" now observed.** |
| 6 | screen while rows up | maintainer: "nothing seemed out of the ordinary" — walking, inventory etc. unaffected. One visible effect of the replay: Henry appeared "a few feet in the air" — the `goto` z is 112.25 against ground ≈110.6 in the engine's own camera lines; Warhorse's coordinate, not ours |
| 7 | **F12** | `QUEST-PROMPT declined: staying on our own story for socky._initAndStart`, `quest_catchup decline` event, prompt nil, beat remembered as declined |
| 8 | walk-in lead time (announce memory cleared, maintainer walked out to 76.6 m and back at a run) | `QUEST-APPROACH socky._initAndStart (M03) at 35.8m`; emitter stream shows arrival within 3 m **7.0 s later** (≈4.7 m/s). At a walk that is roughly 12 s; on a galloping horse under 3 s |
| 9 | hazard lines during the two windows | **0** — no death, clock write, chain suspension or divergence release occurred, and the 19.5 m teleport was **missed** by the 1 Hz / 60 m/s rule (§9). The agent-side tags could not fire: old agent |

**Not live:** the two-machine path (kind 2/3/4 on the wire, the peer's
prompt and its `diverged` gate, peer-side hazard tags, ghost-teleport tag),
and the two fixes in §9 (rebuilt into the pak, not installed).

Engine lines worth knowing for future log reading (all observed): the
console echoes `[CONSOLE] Executing console command '<cmd>'`; a fire
produces `<HasteTrigger> name:'<full dotted path>' is being triggered from
haste` per trigger — note the **full** `Barbora.trosecko.<quest>.<module>.<trigger>`
path, resolved by the engine from the flat `<quest>.<trigger>` we send; a
relocation produces `TeleportPlayer Player 'Dude' … BEFORE pos=<x y z>`.

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

The session ran in two parts. **Part 1 (maintainer absent):** no game was
launched, attached to or commanded; neither `:1403` nor `:4600` was used;
no install file or save was touched; `Scripts.pak`, `English_xml.pak` and
the scriptbind docs were read from scratchpad copies. Every live point was
reached and **stopped**, and the session ended its turn with the procedure
written out. **Part 2 (maintainer present, "Go", disposable save):** the
same points were run, in order, with the maintainer doing the parts that
need hands and the session reading `kcd.log` — nothing was assumed.

| # | Point | Part 1 | Part 2 |
|---|---|---|---|
| 1 | Overlay does not intercept input (Phase 2.2) | stopped; static proof §4.3 | maintainer: nothing stopped working while the rows were up |
| 2 | F11/F12 reach the prompt (Phase 3.2) | stopped | F11 fired the prompted beat (twice, by accident); F12 declined |
| 3 | Overlay renders and persists | stopped | rows seen and answered by key |
| 4 | Proximity fires with lead time | stopped | 35.8 m, 7.0 s at a run |
| 5 | Force-advance does what WO-92 verified | stopped | 14-trigger plan drained, repeat replay observed |
| 6 | Pak install (needs the game closed) | — | maintainer closed the game on request; session installed; maintainer relaunched |
| 7 | Phase 4 release cut | not started | proceeds after this doc |

Two things were done **by hand from the shell** during part 2 and are
recorded so nobody mistakes them for shipped behaviour: the level and
current quest were pushed with `#KCD2MP_QuestSetLevel/SetCurrent` (the old
agent does not), and one catch-up window was cleared with
`#KCD2MP.quest.catchup=nil` to run the F12 test without waiting 120 s (the
line `QUEST test: window cleared by hand` marks it in the log).

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

### Found live, fixed synthetic-only (pak rebuilt, not re-installed)

* **The console refuses arguments to Lua-registered commands on this
  build.** `mp_quest_radius 35` → `[Warning] Too many arguments for:
  mp_quest_radius`, and nothing runs; `mp_enable_aggro on` (WO-17) → the
  same warning; bare `mp_enable_aggro` → the Lua receives the literal
  string `%LINE` ("got '%LINE'") **(observed)**. This is true of **every**
  `%LINE` command in `kdcmp.lua`, including WO-17/32/77/90's `on|off|<n>`
  toggles — so the field rollbacks documented for those work only as
  `#KCD2MP_…(…)` Lua, not as console commands. WO-94 ships argless
  `mp_quest_on` / `mp_quest_off` / `mp_quest_sync` (status) /
  `mp_quest_test_prompt`, treats the literal `%LINE` as "no argument", and
  its help text gives the `#` form for values. The older commands are left
  as they are and named here for their owners.
* **A Haste `goto` of 19.5 m was invisible to the local-teleport rule.** It
  sampled at 1 Hz and asked for > 60 m/s; the replay moved the player 19.5 m
  in one frame and the next 1 Hz sample saw 19.5 m/s **(observed)**. Fixed:
  `KCD2MP_QuestNotePos` runs on every emitter tick while a window is open
  and tags any > 4 m jump between two emits < 0.3 s apart (a gallop is
  ~0.25 m per 20 ms tick); the agent additionally tags the engine's own
  `TeleportPlayer Player 'Dude'` line. Both **(synthetic: WO-94 scenario f,
  +4 checks)**, neither re-run live.
* **The spreadsheet's titles found a real bug** (§3.1 note, committed
  `62c0e7e`): six quests' journal keys are not their XML names; matching on
  the key each root carries is what made M08/M44b/M46/M48b/M48c/M50
  resolvable at all.
* **Warhorse's `goto` points can float.** `socky.haste.teleportBeforeEndPreviousQuest`
  puts the player at z=112.25 where the engine's camera lines read the
  ground at ≈110.6; the maintainer landed "a few feet in the air"
  **(observed)**. Cosmetic, Warhorse's data, noted so it is not reported as
  a mod bug.

## 10. Named, not attempted

1. The two-machine live path: kinds 2/3/4 crossing the relay, the peer's
   `diverged` gate, peer-side hazard tags, the ghost-teleport tag, and the
   new agent deployed at both ends.
2. Re-running the solo ladder against the pak that carries §9's two fixes
   (installed only after the release cut).
3. Putting the level on the wire (hazard 1's other half).
4. Pruning same-position variants (finale) in the registry — a data edit
   the maintainer can make in `KCD2MP_MAINQUESTS` or by adding a filter to
   the extractor; the CSV has every candidate.
5. A wider fireable rule (+11 single setters) if the 53 prove too sparse.
6. `SaveGame`-node hazard (WO-92 hazard 4) — no runtime hook exists; the
   post-hoc detector from WO-84 is the only coverage.

---

## 11. Phase 4 — the release cut (0.22.0)

| Step | Result **(observed)** |
|---|---|
| `VERSION` | `0.21.5` → `0.22.0`, the string the work order stated |
| Pak | `Build-And-Install-Mod.ps1` rebuilt `kdcmp.pak` (644,915 bytes) from the post-fix Lua; the copy installed for the live ladder predates §9's two fixes |
| Agent / C# changed? | Yes — `GameBridge.cs`, `LogTailGameTransport.cs`, `StoryBeat.cs`, `Protocol.cs` (shared) → full republish through `Build-Installer.ps1` (launcher, agent, relay, master server as one set) |
| Native DLL | **Unchanged.** `git log -- native/` ends at WO-86 `d7da56a` (shipped in 0.21.1); the published `KCDMP.dll` sha256 is `be76ba6a578a…872c8984`, identical to the hash the 0.21.5 notes recorded |
| Installer | `release\KCDMP-Setup-0.22.0.exe`, 100,418,531 bytes (Inno reports 95.8 MB), sha256 `9827b7938b61aaa2be7d1e061e270b09785bad872b67e44efb74b3262588d63e`. **No DirectInstall ZIP built** — retired from this release on, recorded in `docs/VERSIONING.md` |
| Install matrix | `Test-InstallerDetect.ps1` **21/21**; `Test-InstallerUpgrade.ps1` **33/33** (virgin, upgrade from `KCDMP-Setup-0.21.5.exe`, idempotent re-run, half-applied repair, damaged-mod repair, unreplaceable-file negative control); `Test-Installer.ps1 -SteamRoot <fixture>` **43/43**, Add/Remove version `0.22.0`. **97/97.** Fixture-based, as WO-82/85/89: this shell's `%LocalAppData%` is sandbox-redirected. One invalid run preceded the 43/43 — a wrong fixture path made Setup abort at its Modding-Tools gate and every assertion fail on an absent install; it is recorded here so the log is not misread |
| `Verify-Install.ps1` | all six WO-94 markers `present` in `[BUILT app]` and `[BUILT pak]`; the two agent markers `ABSENT` in `[INSTALLED]`, correctly — the maintainer's machine still runs the 0.21.5 agent |
| README badges | **Main** badge is a hard-coded shields.io image + link: updated to `0.22.0` / `RELEASE-NOTES-0.22.0.md`. **Release** badge is shields.io's *dynamic* `github/v/release/...latest` image: it shows whatever GitHub's latest release is and is not edited by any file change here — it will read 0.22.0 once the maintainer publishes the GitHub release with the Setup exe. No script updates either; both confirmed by reading `README.md:9-10` |
| Release notes | `docs/releases/RELEASE-NOTES-0.22.0.md`, verification status stated as above |
| Totals this session | Lua 373 + C# 131 = **504 checks**; install matrix 97; **601 checks, 0 failures** |

Distributing the Setup exe — the GitHub release, the Discord post — is the
maintainer's, per `docs/VERSIONING.md`.

