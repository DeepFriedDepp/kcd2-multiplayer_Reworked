# WO-6 progress log

Append-only. Newest entry at the bottom. If you are starting a new session,
read this file plus `docs/SESSION-PROMPT-wo6-native-dice.md` (what this WO
was asked to do) and, if picking up the in-game overlay work specifically,
`docs/SESSION-PROMPT-wo6-overlay-ui.md` (what to do next — a design pivot
happened at the end of this session, see below).

---

## Session 1 — 2026-07-28 — Phase 0.5, R0, R1, R2, and a design pivot

Started cold from `docs/SESSION-PROMPT-wo6-native-dice.md`. Did not reach
Phase 1/2 builds — R2 turned out to need far more investigation than
budgeted, and the session ended on a design pivot instead. Nothing here is
half-finished code; everything committed is either a completed research step
or a clean negative result with evidence.

### Housekeeping first

Found uncommitted changes from a prior session's verification pass already
in the working tree: a real bug fix (`Home.razor.cs`'s ping loop skipping
manually-added servers) and TEMP diagnostic logging left mid-investigation
in `DiceIpcClient.cs`. Committed the fix on its own, reverted the diagnostic
back to its original silent form. Also committed the prior session's raw
working documents (`VERIFICATION-REPORT.md`, `SESSION-SUMMARY-pre-final-wo.md`)
alongside the WO-6 session prompt itself.

### Phase 0.5 — licensing

Added `LICENSE` (GPLv3, fetched verbatim from gnu.org) and a "License and
Provenance" section to `README.md`. One clarification surfaced and resolved
with the human: GPL permits commercial resale of derivatives (copyleft means
derivatives must stay open, not that they can't be sold) — the human's actual
goal was closer to a non-commercial license, but chose GPLv3 anyway after
understanding the tradeoff, prioritizing dependency-compatibility and
staying aligned with "the fork will carry a GPL license" from the WO brief.

### R0 — framework/dependency scout

Searched Nexus/GitHub for existing native tooling. Found and evaluated:
`kcd2_rttr_dumper` (unlicensed, used as an unvendored local research
reference only — see below), `kcdx`/`KCSE-for-kcd2`/`KCD2ModLoader` (general
script-extender frameworks, declined — this project's own native plugin
already works and these would replace it rather than extend it),
`kcd2-modding-docs` (doesn't cover the dice/GUI surface, declined). Nothing
adopted as a dependency.

### R1 — mapping the reflected surface

**Static lead, before touching the game:** `kcd2_rttr_dumper`'s committed
57k-line static RTTR type dump led directly to `wh::guimodule::C_UIDice` —
a real reflected class with five methods (`ShowDiceScore` taking 14
parameters, `HideDiceScore`, `ShowDiceProperties`, `HideDiceProperties`,
`SetCurrentPlayer`) and zero properties.

**Live confirmation:** walked the debug REST API (`localhost:1403`) the same
way `NATIVE-PLUGIN-findings.md` did for `rpg`/`xgen`/`ent`. Confirmed
`C_UIDice` sits in `GUIModule.UIElements` (index 22) alongside the game's
other minigames (Pickpocketing, Shop, ShootingContest — same
one-singleton-per-minigame pattern) and is **genuinely empty even at
depth=4**, live, not just in the static dump.

**Environment correction, mid-session:** the human had launched via
`KCDMP_launcher` rather than the Modding Tools Steam entry directly. Debug
REST API unaffected (built into the game, independent of this mod's DLL).
`KCDMP.dll`'s *automatic* injection did hit the known 0-frames race
(`VERIFICATION-REPORT.md` Track 1) — manually re-injected a fresh copy into
the same already-running process, worked immediately (same fix already
verified last session). Automatic-injection race remains open, out of scope
here.

**Real game, real negative result:** played two real games against "Dicer
Filip." With known ground-truth scores mid-match (600/350 banked), searched
`C_UIDice`, `PlayerModule`, `PlayerSoul` (`CombatSoul` included),
`ent`/`concept`/`db`/`dialog`/`behavior`/`xgen` — neither value appears
anywhere. **Confirmed: pull-based reflection cannot see the dice minigame's
live state**, same shape as combat's already-solved outbound problem.
Evidence committed as `tools/dice-probe-*.xml`.

Side finding: `PlayerSoul`'s own internal `Name` is `"Dude"` in this build —
resolves the old "Dude decoy" note from `NATIVE-PLUGIN-findings.md` (not a
lookalike soul, the player's own soul).

### R2 — find the logical dice

**Found `wh::playermodule::C_Dice`** by cross-referencing `PlayerModule.dll`'s
export table (`dumpbin /exports`) against the static RTTR dump — a real
game-logic controller class the dump itself missed, confirmed via one
exported method: `SetPauseWorldTime(bool)`.

**Attempted an inline hook on `SetPauseWorldTime`**, with the human's
explicit go-ahead, to capture a live `C_Dice*` instance (no exported
accessor reaches one; nothing imports it via any checked module's IAT, so
the already-proven IAT-hook technique had no attachment point). Verified the
hook site was safe via `dumpbin /disasm` (13 bytes, four complete
instructions, no internal jumps/RIP-relative operands) before installing.
**Installed cleanly against the human's live game — no crash — but never
fired across two real transitions** (finishing an in-progress game, starting
a fresh one). Clean negative: `SetPauseWorldTime` is almost certainly not
part of ordinary NPC gambling.

**Brought in Ghidra** (12.1.2, official release) + Temurin JDK 21 (Ghidra
needs 17+, machine only had Java 8) to properly recover `rttr::array_range<T>`'s
ABI by decompilation — the same discipline already used for
`variant`/`argument`/`instance`, just with a real disassembler instead of
`dumpbin`. Ran headless auto-analysis against `CrySystem.dll`, wrote
`native/ghidra_scripts/DumpArrayRangeFuncs.java` to decompile
`get_methods`/`get_properties`. **Recovered the real layout**: hidden sret
buffer's first two 8-byte slots are a plain `{begin, end}` pointer pair into
a contiguous array of 8-byte elements, directly usable as `Method::data`/
`Property::data`. Built this into `rttr_abi.h`/`.cpp` and a new
`probe_dice_class()` that asks rttr directly, by name, for every
method/property `C_Dice` has — no guessing.

**Final result: `C_Dice` is not RTTR-registered at all.**
`get_by_name` resolves without faulting; `is_valid` is false. Clean,
trustworthy negative (same shape as this project's own negative-control
discipline). **This closes the entire reflection-based path for `C_Dice`
definitively** — the class is real but was never hooked up to the
introspection system this project has been using all night, so no amount
of further tooling can read it. Likely reading: `C_Dice` belongs to a
scripted/quest dice context, not the "walk up to any NPC and gamble"
interaction this project needs (the `dice_gameLevel`/`dice_betType`/
`SpokeWithDicePlayers`-shaped enums found earlier read like flowgraph glue
for exactly that different context).

**R-gate reached, early, for Tier III+ specifically**, per the WO's own
instruction to stop before building past Tier II. Full tier verdict is in
`docs/WO-6-native-dice-findings.md` §"R-gate: Tier verdict": R2 exhausted
this session without success; Tier I/II are fully unblocked and unaffected;
Tier III+ is not proven unreachable but nothing tried tonight reached it —
the next concrete lead (not pursued tonight) is decompiling the real caller
of `C_UIDice::ShowDiceScore` with the now-working Ghidra pipeline.

### The design pivot

Presented the tier verdict to the human plainly (no jargon, per their
request). Their response reframed the actual goal in a way that sidesteps
the whole native-reflection problem:

- **Restrict to PvP only, at real dice tables.** NPC games stay exactly as
  they are today, untouched, full native experience. Only two real players
  gambling together triggers this mod's own dice UI.
- **The UI must be in-game/on-screen, never the launcher window.** Their
  explicit complaint about WO-5's existing `DiceWindow.razor`: "clunky,
  boring, and appears in the LAUNCHER, and not in the game." The launcher
  should be a launcher, full stop.
- **Wants better visuals/animation than the existing plan's plain
  `DrawText` overlay**, but understands (after the tradeoff was explained)
  that real sprite/texture-based dice needs its own small research spike
  (has the GUI module's image-drawing surface ever been checked? — no,
  never examined, per `PROJECT-STATE.md` §5.1), separate from and much
  lower-risk than tonight's `C_Dice` investigation, since it's about
  drawing this mod's *own* data, not reading the game's hidden state.

This is, functionally, **Tier II** (the WO's own guaranteed floor) with two
refinements: gated to real tables + PvP only (rather than "invite
anywhere"), and explicitly positioned as the actual deliverable rather than
a fallback — no further native reflection work needed to build it.

**Nothing was implemented for this yet** — the human asked for a
documentation handoff instead, to pass to a fresh session. See
`docs/SESSION-PROMPT-wo6-overlay-ui.md`.

### State at end of session

- `KCDMP.dll` is injected and alive in the currently-running game (multiple
  research copies actually — `native/build/KCDMP_dice3/`,
  `native/build/KCDMP_diceclass/`, plus earlier `KCDMP_retry`/`KCDMP_retry2/`
  — all harmless duplicates from iterative re-injection during this session,
  gitignored, not part of the repo). None of this matters for a fresh
  session: the game will need re-launching and re-injecting from scratch
  next time regardless.
- Ghidra 12.1.2 and Temurin JDK 21 are installed locally (not part of this
  repo — official-source installs, large binaries). See
  `native/ghidra_scripts/README.md` for how to reuse the pipeline.
- All suites untouched this session (no relay/protocol/engine changes) —
  still exactly as green as WO-5 left them.
- Full technical evidence trail: `docs/WO-6-native-dice-findings.md`.

---

## Session 2 â€” 2026-07-29 â€” the visual capability answer, and the overlay built

Started cold from `docs/SESSION-PROMPT-wo6-overlay-ui.md` plus the human's
expanded brief ("every bell, every whistle"). Nothing in
`docs/WO-6-native-dice-findings.md` was reopened.

### The headline: the answer was already on this machine

Part A asked for open-web research into how KCD2 mods achieve custom visuals.
That was done (see `docs/WO-6-visual-capability.md`, Routes 4 and 5), but it is
not where the useful answer came from. Three local sources beat it outright:

1. **`Tools/modding/docs/script_bind/script_bind.zip`** â€” Warhorse's own
   generated Lua scriptbind reference, dated `script_bind_2025_01_14`, shipped
   inside the Modding Tools install this project has required since day one.
   5,014 pages of authoritative signatures. **Nobody on this project had ever
   opened it.** It is now the first place to look for any Lua API question.
2. **`Data/IPL_GameData.pak` â†’ `Libs/UI/`** â€” 28 `UIElements/*.xml` files, the
   live Flash UI definitions, including a full dice presentation API.
3. **Scriptbind registration strings inside the shipped DLLs** â€” ground truth for
   *this build*, which catches things the docs list but the binary does not
   register.

### What that produced

- **CryEngine's Flash UI system is fully intact and reachable from our Lua.**
  Confirmed live: `UIAction` is a table and `CallFunction`, `ShowElement`,
  `SetVariable`, `SetArray`, `SetPos`, `SetAlpha`, `SetScale`, `SetVisible`,
  `GotoAndPlay` and `RegisterElementListener` are all functions.
- **The game's HUD already exposes the dice presentation API we would have
  wanted to build**: `ShowDiceScore` (14 params), `AddDiceSelector(Id,X,Y,IsPlayer)`,
  `ShowDiceCursor`, `ShowDiceProperties` â€” plus `ShowTutorial` (HTML text),
  `ShowInfoText`, `ShowSkillCheckResult`, and `ApseModalDialog.OpenQuestionDialog`
  with real confirm/cancel callbacks. All **push-only**, which is the opposite
  direction from the closed native-state-read path, so none of this reopens it.
- **This also resolves a guess left open by session 1.**
  `WO-6-native-dice-findings.md` recorded `ShowDiceScore`'s 14 parameters from
  the RTTR dump as unnamed and explicitly flagged their meaning as "a **guess**".
  `HUD.xml` gives the real names.
- **`System` has no image/sprite primitive.** Clean negative, from the binary's
  own registration table and confirmed live. Every "draw a picture from Lua" idea
  dies there â€” which is exactly why the Flash route matters.
- **But `System.DrawText` takes a font name and RGB**, and the game ships
  `AlexanderQuill.ttf` registered as the CryFont `subtitles` (with a shadow
  pass). And **`Draw2DLine`** gives real screen-space vector geometry.
  Between them the "typographic floor" is actually a *vector* floor.
- **`DrawTriStrip` is documented by Warhorse but NOT registered in this build** â€”
  predicted from the DLL strings, then confirmed `nil` live. A useful reminder
  that the shipped docs describe a source tree, not this binary.

### Table identification (C1) â€” settled, with a real query

Not a heuristic and not a guess. `Scripts.pak` ships
`Entities/DiceInteractor.ent`, registering entity class **`DiceInteractor`**
against `Scripts/Entities/WH/Minigames/DiceInteractor.lua` â€” the script that puts
the `@ui_hud_play_dice` action on a `dice_board.cgf`. Run live:

```
System.GetEntitiesByClass("DiceInteractor")  ->  9 tables
  DiceInteractor1[Table/table_dice8_d4afcbd3-...]  d=1.2 m   <- player was standing at one
  DiceInteractor1[Table/table_dice4_14387850-...]  d=512.9 m
  ...seven more, 525 m - 1257 m
```

The distance spread is its own negative control â€” nearest 1.2 m, next 512.9 m â€”
so the 4 m gate cannot false-positive. Delivered as `KCD2MP_IsAtDiceTable(r)` /
`KCD2MP_NearestDiceTable(r)`, with `mp_dice_table` to re-verify after a patch.

### What was built

- **`docs/WO-6-visual-capability.md`** â€” five routes with evidence, effort and
  risk; the chosen tier; the probe results; licences checked. **No dependency
  adopted** (KCD2ModLoader is MIT and does have real ImGui drawing, but ImGui is
  the opposite of the brief's look and it is a second injected DLL â€” declined,
  with the reasoning recorded).
- **`docs/WO-6-overlay-design.md`** â€” palette, type, framing, the motion table
  (a moment per transition), state model, input feel.
- **The overlay itself**, in `kdcmp/Data/Scripts/Startup/kdcmp.lua`: an oak
  wager-board with a parchment score slip, vector dice with drawn pips,
  laid-paper ground, iron nailheads, leader dots, turn chevron, hold-to-confirm
  arc. Cast flicker with staggered settle, set-aside travel with gold flash,
  counting scores, sliding turn banner, bust shake + blood wash + "FARKLE", gold
  win flourish, open/close ramp. ~300 `Draw2DLine` calls per tick while open,
  zero when closed.
- **`tools/probe_visual.lua` + `tools/Probe-Visual.ps1`** â€” the A2 probe, in the
  proven `--@@BLOCK` harness. Read-only, self-cleaning, `-Cleanup` escape hatch.
- **Agent side**: `WireDiceFeedback` now pushes the full snapshot
  (`KCD2MP_DiceState`), rejections (`KCD2MP_DiceError`, with reasons in words)
  and the result (`KCD2MP_DiceEnd`); `OnGameEvent` handles `dice_intent` so the
  game is the input surface. **Engine and wire protocol untouched.**
- **`mp_dice_demo`** â€” drives the board through a full scripted match with
  fabricated snapshots. This exists because of the standing "one machine, no
  second human" constraint: it makes the visuals reviewable *today* instead of
  whenever a second PC appears. It sends no intents and cannot affect a session.

### Launcher window: retired, and the IPC decision

`DiceWindow.razor`, `DiceWindow.razor.css`, `Services/DiceIpcClient.cs` and
`Models/DiceModels.cs` are **deleted**, the `<DiceWindow />` mount and the DI
registration are gone. The launcher is a launcher.

The **agent-side** `DiceIpcServer`/`DiceIpcState` are **kept**, deliberately, and
that is documented at the top of `DiceIpcServer.cs`: it is the only way to
observe a real agent's dice state with no game running, and that is exactly how
WO-5 verified the agent-side dice code with two real `KcdMpClient` processes.
Deleting it would delete a proven headless test surface to save an idle loopback
listener. Not half-wired â€” deliberately unwired on the launcher side.

### Suites

All green, run this session: Farkle **59/59**, `Test-Dice` **10/10**,
`Test-Sessions` **22/22**, `Test-Combat` **14/14**, solution builds clean.
`Test-Pipe` needs the game plus the DLL and was not run â€” nothing native changed
this session.

### Traps hit

- **The console endpoint silently dropped a probe block** that was merely a bit
  long â€” no output, no error. Exactly what `probe_transport.lua`'s header warns
  about. Rewritten short, it worked first try. Keep blocks small.
- **`System.GetViewport()` returns a table**, not four values.
- **`powershell -File script.ps1 -Only a,b,c`** binds the whole comma list as ONE
  string, not an array. `Probe-Visual.ps1` now re-splits.
- **`HUD.xml` declares `<UIElement name="hud">` â€” lowercase.** The file is
  `HUD.xml`; the wrong case in `CallFunction` is a silent no-op.
- **Unicode die faces would be tofu.** AlexanderQuill has no U+2680..2685
  glyphs, so dice are vector-drawn, always. Recorded in the design doc before it
  could be made a second time.
- **A Blazor scoped `.css` outlives its component** and fails the build
  (`BLAZOR102`) â€” `DiceWindow.razor.css` had to go with `DiceWindow.razor`.

---

## NEEDS THE GAME â€” one sitting, in this order

Everything above was built without the game. These are the steps that need it,
batched. Steps 1-2 are prerequisites; 3-6 are independent after that.

**1. Install the new pak.** The game must be CLOSED for this.

```
powershell -ExecutionPolicy Bypass -File tools\Build-And-Install-Mod.ps1
```

Then launch via the **KCD2 Modding Tools** Steam entry, load a save, and confirm
`[KCD2-MP] === MOD INIT ===` in `kcd.log`.

**2. Review the board â€” the big one.** Walk to any tavern dice table, then in the
console:

```
mp_dice_demo
```

That plays a ~30 s scripted match: open, cast, set aside, score tick, turn
hand-off, bust, opponent's turn, a rejected intent, and a win. **Describe what
you see** â€” this is the actual deliverable and the thing to screenshot. In
particular:

- Is the panel **on screen and correctly placed**? If it is tiny in the top-left
  corner, 2-D draws address a fixed virtual space rather than the back buffer â€”
  run `mp_dice_space 800 600` and `mp_dice_demo` again. That one command is the
  whole fix.
- Is the text in a **medieval hand and coloured**, or plain and white? White and
  plain means this build kept `DrawText`'s legacy 4-argument form; say so and
  `KCD2MP.dice.richText` gets set false (layout and dice are unaffected).
- Do the **rules and ground fade**, or is everything solid? That answers whether
  `Draw2DLine` honours alpha.
- Does the **motion read** â€” do dice flicker and settle, does the score count up,
  does the bust shake, does the win flourish?

**3. The visual probe**, for the native panels the board can layer on top:

```
powershell -ExecutionPolicy Bypass -File tools\Probe-Visual.ps1
```

It pauses on each visual block and prints what to look for. **Watch the game**
during the pauses. Remember: a Flash call logging `=true` only means it did not
throw â€” only what you saw counts. If something gets stuck on screen, re-run with
`-Cleanup`.

Each panel that genuinely renders flips one flag in `KCD2MP.dice.native`
(`modal`, `infotext`, `sting`, `score`) â€” all default **off**, so nothing ships
enabled on a guess.

**4. Confirm table gating.** At a table: `mp_dice_table` should report a distance
of a couple of metres. Walk well away and run it again: it should report none
within 25 m. Then `mp_dice` should refuse away from a table and attempt an invite
at one.

**5. Find the real keys.** Set `KCD2MP.logActions = true`, press the key you want
for each of cast / mark / bank / yield, and read the `ACT '<name>'` lines out of
`kcd.log`. Send those names back â€” the current
`DICE_CONFIRM_ACTIONS`/`DICE_BANK_ACTIONS`/`DICE_YIELD_ACTIONS`/
`DICE_MARK_PREFIXES` tables are **unverified guesses** and are all gated on the
board being open, so a wrong guess is a dead key, never an unwanted action. The
`mp_dice_*` console commands work regardless.

**6. NPC dice unaffected â€” confirm by playing one.** Sit down with any dice NPC
and play a normal game. Nothing of this mod should appear: the board only opens
from a `SessionStarted(Dice)` or a `DiceState`, neither of which a native game
produces.

### Still unverified after all that, and honestly so

- **A real two-player match at real latency.** One machine, one copy of the game,
  no second human. The whole PvP path is designed and headlessly proven but the
  two-humans-at-one-table behaviour stays **unverified until a second machine
  exists**.
- **The frame cost of ~300 `Draw2DLine` calls per tick.** Reasoned, not measured.
  `KCD2MP.dice.groundStep` is the knob if it ever shows up.

