# Session prompt — WO-6 continued: verify the dice board, then the next WO

Paste everything below the rule into a fresh session. Working directory
`C:\Users\Jonasty\Documents\KCD2_MP`. Prefix commits `WO-6:`.

---

You are a senior engineer continuing an unofficial multiplayer mod for
*Kingdom Come: Deliverance II*. Repo `DeepFriedDepp/kcd2-multiplayer_Reworked`,
branch `main`. Read `docs/WO-6-progress.md` end to end before touching anything —
it is long, and the last third is the part that matters.

## The goal

Two players walk up to a table in the world and gamble against each other. The
dice engine is **done and proven** — relay-authoritative Farkle
(`dotnet/KcdMp.Farkle`, 59 tests), wire packets `0x16`–`0x19`, `Test-Dice.ps1`
10/10. This work order is **presentation and input only**. Do not change the
engine or the wire protocol without stating a reason up front.

## State: everything below is committed, nothing below is verified in game

`git log --oneline` — the WO-6 run ends at `4075061`.

**HEAD is ahead of what is installed.** The human's last build predates
`4075061`, so `mp_dice_seat`, `mp_dice_scan`, `mp_dice_gate` and the DrawText
board are **not** in their running game. First action of the next session:

```
powershell -ExecutionPolicy Bypass -File tools\Build-And-Install-Mod.ps1
```

(game must be CLOSED), then relaunch via the **KCD2 Modding Tools** Steam entry,
load a save, and confirm `[KCD2-MP] === MOD INIT ===` in `kcd.log`. If that line
is absent the script failed to load — see the BOM trap below.

## What was built

- **The board renders through the game's own UI.** `System.Draw2DLine` renders
  NOTHING in this build (registered, callable, silent, `r_enableAuxGeom`
  already 1). `System.DrawText` is the only screen-space primitive that works.
  The live board is DrawText; the game's gilded parchment panel
  (`hud.ShowTutorial`) fires only at match start and end.
- **Launcher dice window retired.** `DiceWindow.razor` and friends deleted. The
  agent-side `DiceIpcServer` is deliberately kept as a headless test surface.
- **Agent pushes full `DiceState`** into `KCD2MP_DiceState`; `dice_intent` rides
  the log-tail event channel back. Engine untouched.
- **Keybinds discovered, not guessed** (captured via `KCD2MP.logActions`):
  `R` cast/set-aside, `1`–`6` mark, hold `F` bank, hold `X` yield. All
  `mp_dice_*` console commands still work as fallback.
- **Seat gating** on `sitActionTrigger` — see below.

## THE THREE THINGS TO VERIFY FIRST

Each is a one-line check and each is currently an unproven claim.

**1. The seat gate has no negative control.** A 60-tick capture of a seated
player showed a `sitActionTrigger` at 0.5–0.9 m every single tick — but the
player never moved away, so there is **no evidence it disappears when you are
not at a seat**, which is the whole basis of the gate. Also unknown: whether
1.6 m is the right radius, or whether standing 3 m from a bench falsely passes.

Run, in this order, and record each:
- stand ~10 m from any bench → `mp_dice_seat` → expect *no seat within 6m*
- stand ~3 m from a bench (not seated) → `mp_dice_seat` → gives the
  false-positive distance; tighten `KCD2MP.dice.seatRadius` below it if needed
- sit down → `mp_dice_seat` → expect <1 m plus a table id

**2. Is the board actually steady now?** `mp_dice_demo`. The flicker was
*measured* at 24 panel pushes in 30 s, each replaying the card's fade animation;
the fix moves the live board to DrawText and cuts the panel to 2 pushes. Whether
that reads as steady on screen is unconfirmed. `KCD2MP.dice.usePanel = false`
disables the card entirely if it still intrudes.

**3. Do the keybinds fire, and is `action_qam_N` safe?** Never tested in a live
match. Specific worry: `action_qam_1`–`6` are the QAM slots and **may consume an
item** (food, potion) when pressed. If marking die 3 drinks something, move
marking to another key family.

## Known limitations, stated honestly

- **The demo ignores input.** `mp_dice_demo` replays fabricated snapshots with no
  relay behind it. Keys do nothing during it. It is for judging visuals only.
- **A real match needs four things running**: relay
  (`dotnet run --project dotnet\KcdMp.Server -- --port 7778`), agent
  (`dotnet run --project dotnet\KcdMp.Client -- --host localhost --no-voice`),
  the game with the mod, and **a second player on a second machine**. There is
  one PC and one copy of the game here, so two-human play is designed and
  headlessly proven but **unverified**, and must stay labelled that way.
- **Seat detection is "at a seat", not "seated".** `player:GetStance()` is
  unavailable in this build (returned nil across 60 samples). Proximity is a
  proxy.
- Our `OnAction` hook **cannot consume input**, so any bound key also performs
  its normal game function. That is why cast is `R` (torch) and not `E` — `use`
  at a dice table would launch the NPC minigame underneath our board.

## Traps — every one of these cost real time

- **A UTF-8 BOM silently kills the entire mod script.** Lua 5.1 cannot parse it;
  the whole file fails to compile, no commands register, and the only evidence is
  one line in `kcd.log`. PowerShell 5.1's `Set-Content -Encoding utf8` writes a
  BOM — always use `New-Object System.Text.UTF8Encoding($false)`.
  `Build-And-Install-Mod.ps1` now refuses to pack a BOM'd `.lua`.
- **When the mod looks absent, grep `kcd.log` for `Startup/kdcmp` FIRST.** The
  load line and any error are always there and are decisive.
- **`ShowTutorial` is a notification queue, not a panel.** No in-place update.
  `HideTutorial(id)` only dismisses the *displayed* entry — it advances the queue
  rather than clearing it. Use `HideAllTutorials`.
- **Registered ≠ functional.** `Draw2DLine`, `DrawTriStrip` and
  `hud.ShowDiceScore` are all reachable and all inert. A scriptbind entry proves
  nothing; only observed effect does.
- **Font CodeTable presence ≠ glyph exists.** Roman numerals, `■` and the PUA
  glyphs are in KCD2's font table and render as tofu. ASCII `|` renders as
  *nothing at all*. Verified renderable set is in `WO-6-visual-capability.md`.
- **Lua 5.1 has no `\u` escape.** `\u0027` produces the literal text `u0027`.
- **The debug console silently drops oversized/complex chunks** — no output, no
  error. Build long strings by appending ~150-character pieces.
- **MEASURE, don't reason.** Three separate wrong diagnoses this session
  (flicker, vector rendering, missing commands) were each resolved in minutes
  once instrumented. Add a counter or read the log before theorising.

## Working method that saves rebuild cycles

Most iteration needs **no rebuild**. The debug console
(`/api/System/Console/ExecuteString?command=#<lua>`) can call any `KCD2MP_*`
function, set any `KCD2MP.dice.*` field, define new functions, and register new
console commands at runtime. Only source changes need a pak rebuild + relaunch.
Several cycles were wasted this session not doing this.

## Next WO — a large custom overlay with custom art

The human's own idea, and the right next step. The tutorial panel is a ceiling:
it cannot show images (`<img src='img://...'>` parses but never resolves — the
text field has no image loader, proven with a path copied verbatim out of
`hud.gfx`). The dice art exists in the game (`Libs/UI/Textures/Dynamic/dice_0.dds`
… `dice_5.dds`, `dice_frame_yellow.dds`) and cannot be reached. **This is a
display-surface problem, not an asset problem** — art from Nexus or hand-drawn
art hits the same wall.

Three routes, costed at the end of `docs/WO-6-progress.md`:

1. **Reuse a bigger existing UIElement.** 28 exist; only `hud` was really tested.
   `GeneralBook` is the standout — 1024×1024, and it declares both a `Texts` and
   an **`Images`** array. A probe was started and is **inconclusive** (the game
   entered a level load mid-probe). Cheapest thing to try. Caveat: its constraint
   is `fixdyntexsize`, so it may render to a dynamic texture rather than screen.
2. **Ship our own `.gfx` UIElement.** Full control; needs Scaleform authoring
   tooling we do not have, and it is unverified whether a mod pak registers a new
   `UIElements` XML at all. Two unknowns; worst cost/benefit.
3. **Draw from the native plugin.** `KCDMP.dll` is already injected with proven
   main-thread marshalling. Hooking D3D12 present gives unlimited size, custom
   textures, full art direction, and touches no game asset so it conflicts with
   nothing. `xiaoxiao921/KCD2ModLoader` (MIT, GPLv3-compatible) is an off-the-shelf
   implementation with ImGui bound into Lua — and ImGui can draw arbitrary
   textured quads, so the dice can be our own `.dds` with no ImGui chrome.

**Recommendation: try 1, and treat 3 as the real answer.** It is the only route
without a ceiling, and this project has already demonstrated the native
capability it needs. Do not start any of this until the three verification items
above are done — the text board is what exists today and should be confirmed
working before it is replaced.

## Reading order

1. `docs/WO-6-progress.md` — the whole narrative, traps, and the next-WO costing
2. `docs/WO-6-visual-capability.md` — what can and cannot be rendered, with
   evidence, plus the glyph inventory
3. `docs/WO-6-overlay-design.md` — art direction; **read its SUPERSEDED banner
   first**, the vector half is dead
4. `docs/WO-5-dice.md` — engine, protocol, IPC
5. `docs/PROJECT-STATE.md` — ledger and corrections
6. `docs/kcd2_lua_api.md` — the Lua surface, including the drawing limits

## Environment

Game via the **KCD2 Modding Tools** Steam entry
(`D:\SteamLibrary\steamapps\common\KCD2Mod`), not the base game. GPLv3 fork.
`$env:DOTNET_ROOT = "$env:USERPROFILE\.dotnet-sdk8"; $env:PATH = "$env:DOTNET_ROOT;$env:PATH"`
before any `dotnet` command. Suites: Farkle 59/59, `Test-Dice` 10/10,
`Test-Sessions` 22/22, `Test-Combat` 14/14 — all green at `4075061`.
