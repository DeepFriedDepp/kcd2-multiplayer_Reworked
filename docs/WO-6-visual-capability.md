# WO-6 — visual capability: what this mod can actually draw

Research for the in-game PvP dice overlay. Question: **how good can our own UI
look?** This is a *presentation* question — what we can push onto the screen —
and is unrelated to `docs/WO-6-native-dice-findings.md`, which closed the
opposite direction (*reading* the native minigame's hidden state). Nothing here
reopens that.

Discipline, same as everywhere else in this project: **proven / unverified /
guessed**, with the evidence that produced each claim. A vendor document or a
web page is a *lead*; it becomes proven when it runs.

Status legend used below:

- **PROVEN-ONDISK** — read out of the shipped game build or Warhorse's own
  shipped documentation. Strong, but still not proof it works from *our*
  sandbox.
- **PROVEN-INGAME** — observed working from `kdcmp.lua` against a running game.
- **UNVERIFIED** — plausible, with a named reason, not yet run.
- **NEGATIVE** — checked and it is not there.

---

## Executive summary

The brief assumed two tiers: a "rich tier" (images/Scaleform, maybe
unreachable) and a "typographic tier" (text only, the guaranteed floor). The
real picture is better than both, and it did not come from the open web — it
came from **files already on this machine**:

1. **CryEngine's Flash UI system is fully intact in KCD2**, including the Lua
   binding (`UIAction.CallFunction`, `SetVariable`, `SetArray`, `SetPos`,
   `SetAlpha`, `SetScale`, `GotoAndPlay`, `RegisterElementListener`).
   *(PROVEN-ONDISK)*
2. **The game's own HUD already exposes a full dice presentation API** —
   `ShowDiceScore` with 14 *named* parameters, `AddDiceSelector`,
   `ShowDiceCursor`, `ShowDiceProperties` — all **push-only**, which is exactly
   the direction we need. *(PROVEN-ONDISK)*
3. **The Modding Tools ship Warhorse's own Lua scriptbind documentation**, which
   this project had never opened. It is the authoritative signature reference.
   *(PROVEN-ONDISK)*
4. **`System.DrawText` takes a font name and RGB**, not just a size — and the
   game ships `AlexanderQuill.ttf` registered as the CryFont named
   `subtitles`. *(PROVEN-ONDISK, arity unverified against this build)*
5. **`System` has no image/sprite draw primitive.** Clean negative, from the
   binary's own scriptbind registration table. *(NEGATIVE)*

So the floor is not "text on a black screen." The floor is **the game's own
calligraphic font, in colour, with a shadow pass, framed by real 2-D vector
lines** — and the ceiling is **the game's own dice scoreboard art, rendered by
the game, fed by our relay-authoritative engine.**

---

## Where the evidence came from

Three sources, in descending order of trustworthiness:

| Source | What it is | Why it is trustworthy |
|---|---|---|
| `Tools/modding/docs/script_bind/script_bind.zip` | Warhorse's own generated Lua scriptbind reference, dated `script_bind_2025_01_14`, shipped inside the KCD2 Modding Tools install this project already requires | Vendor documentation, on disk, for this exact toolchain. 5,014 HTML pages. |
| `Data/IPL_GameData.pak` → `Libs/UI/**` | The shipped UI definitions: 28 `UIElements/*.xml` files binding named functions to `.gfx` assets | The actual data the running game loads |
| Scriptbind registration strings inside `Bin/Win64ReleaseSteamLTO_DLL/*.dll` | The literal method-name strings `CScriptBind_*` registers with Lua | Ground truth for *this build* — it catches methods the generic docs list but this build does not register (see `DrawTriStrip` below) |

The open web (A1 as briefed) was searched and is covered in "Community
techniques" below, but it was **not** where the useful answer came from. Worth
recording as a lesson: the vendor shipped the answer in the install directory.

---

## Route 1 — the game's own Flash UI, driven from Lua *(the ceiling)*

### What exists

CryEngine's Flash UI system reads every XML in `Libs/UI/UIElements/`, binds each
to a `.gfx` (Scaleform) asset, and exposes the declared functions to Lua,
flowgraph and C++. KCD2 ships 28 such elements.

*(PROVEN-ONDISK — extracted from `Data/IPL_GameData.pak`)*

```
AlchemyBook  ApseCharacter  ApseCodexList  ApseCraftingContent
ApseCraftingList  ApseInventoryInfo  ApseInventoryList  ApseMap
ApseMapLegendList  ApseModalDialog  ApsePlayerInfo  ApsePlayerList
ApseQuestLogDiary  ApseQuestLogList  ForgeBuilderPlan  GameOver
GeneralBook  HorseInspect  HUD  ItemSelection  ItemTransfer
LoadingScreen  LockPicking  Menu  Overlay  Pickpocketing  Progress
SkipTime
```

**Trap already found:** the file is `HUD.xml` but the element is declared
`<UIElement name="hud" …>` — **lowercase `hud`** is the name `CallFunction`
wants. Getting this wrong is a silent no-op, not an error.

### The Lua binding

`CryAction.dll`'s `CScriptBind_UIAction` registers, in this build:

```
StartAction  EndAction  ShowElement  HideElement  RequestHide
ReloadElement  UnloadElement  CallFunction  SetVariable  GetVariable
SetArray  GetArray  GotoAndPlay  GotoAndStop  GotoAndPlayFrameName
GotoAndStopFrameName  RegisterElementListener  RegisterActionListener
RegisterEventSystemListener  Unregister{Element,Action,EventSystem}Listener
```

*(PROVEN-ONDISK — string scan of the shipped `CryAction.dll`)*

Warhorse's shipped docs additionally give exact signatures, and list
`SetPos`/`GetPos`, `SetScale`/`GetScale`, `SetRotation`/`GetRotation`,
`SetAlpha`/`GetAlpha`, `SetVisible`/`IsVisible` operating on **named
MovieClips inside an element** — i.e. real transform and fade control over the
game's own art.

Authoritative signatures *(PROVEN-ONDISK, from the vendor docs)*:

```lua
UIAction.CallFunction( elementName, instanceID, functionName, [arg1], [arg2], ... )
UIAction.ShowElement( elementName, instanceID )
UIAction.HideElement( elementName, instanceID )
UIAction.SetVariable( elementName, instanceID, varName, value )
UIAction.SetArray( elementName, instanceID, arrayName, luaTable )
UIAction.SetPos( elementName, instanceID, movieClipName, vec3 )
UIAction.SetAlpha( elementName, instanceID, movieClipName, float )
UIAction.SetScale( elementName, instanceID, movieClipName, vec3 )
UIAction.SetRotation( elementName, instanceID, movieClipName, vec3 )
UIAction.SetVisible( elementName, instanceID, movieClipName, bool )
UIAction.GotoAndPlay( elementName, instanceID, movieClipName, frame )
UIAction.RegisterElementListener( table, elementName, instanceID, eventName, callbackName )
-- callback form: Callback(elementName, instanceId, eventName, argTable)
```

`instanceID` is `-1` for "all instances"; a non-existent instance id is
*created* on use.

### The dice functions the HUD already has

From `Libs/UI/UIElements/HUD.xml` *(PROVEN-ONDISK)*. This also **resolves a
guess** left open in `docs/WO-6-native-dice-findings.md`, which recorded
`ShowDiceScore`'s 14 parameters from the RTTR dump as unnamed and said their
meaning "is a **guess**, not yet confirmed." Here are the real names:

```xml
<function name="ShowDiceScore" funcname="fc_showDiceScore">
  <param name="TargetScore"        type="int" />
  <param name="PlayerName"         type="int" />
  <param name="CurrentPlayer"      type="int" />
  <param name="TotalPlayer"        type="int" />
  <param name="SelectedPlayer"     type="int" />
  <param name="BadgePlayerName"    type="string" />
  <param name="BadgePlayerCurrent" type="int" />
  <param name="BadgePlayerTotal"   type="int" />
  <param name="CurrentNPC"         type="int" />
  <param name="TotalNPC"           type="int" />
  <param name="SelectedNPC"        type="int" />
  <param name="BadgeNPCName"       type="string" />
  <param name="BadgeNPCCurrent"    type="int" />
  <param name="BadgeNPCTotal"      type="int" />
</function>

<function name="HideDiceScore"  funcname="fc_hideDiceScore"/>
<function name="AddDiceSelector" funcname="fc_addDiceSelector">
  <param name="Id"       type="int" />
  <param name="X"        type="float" desc="position in 1920x1080 space" />
  <param name="Y"        type="float" desc="position in 1920x1080 space" />
  <param name="IsPlayer" type="bool"  desc="true if it is player, false if it is opponent" />
</function>
<function name="RemoveDiceSelector" funcname="fc_removeDiceSelector"><param name="Id" type="int"/></function>
<function name="ShowDiceCursor" funcname="fc_showDiceCursor">
  <param name="X" type="float"/><param name="Y" type="float"/>
</function>
<function name="HideDiceCursor" funcname="fc_hideDiceCursor" />
<function name="ShowDiceProperties" funcname="fc_showDiceProperties">
  <param name="DiceName" type="string"/><param name="DiceValue" type="int"/>
</function>
<function name="HideDiceProperties" funcname="fc_hideDiceProperties" />
```

Mapping onto our `DiceSnapshot` is close to one-to-one: `TargetScore` →
`TargetScore`, `CurrentPlayer` → `TurnTotal` (this player's turn-in-progress),
`TotalPlayer` → this player's banked score, `SelectedPlayer` → the score of the
currently selected keep, and the `*NPC` triple → the opponent's mirror. The
`Badge*` fields are the special-dice display our engine deliberately scoped out
(`DieKind`, `WO-5-dice.md`); they take empty string / zero.

`PlayerName` being typed `int` is the one genuinely odd field — almost
certainly a name/localisation id rather than a string. **UNVERIFIED**; the probe
tests `0` first.

### Other native panels worth having

All *(PROVEN-ONDISK)*, all push-only, all rendered in the game's real art:

| Element / function | Why it matters here |
|---|---|
| `hud.ShowTutorial(Id, Text, Duration, InDialogue, Priority, Layout, ActionHintEnable, OverlayLink)` | The tutorial parchment box. `Text` is documented **"can be HTML"** — a framed, styled, animated rich-text panel |
| `hud.ShowInfoText(Text, Priority, Duration, Background)` | Centre-screen info line with an optional shadow ground |
| `hud.ShowNotification(infoText)` | Corner notification |
| `hud.ShowSkillCheckResult(Name, Result)` | Native success/fail flourish — a ready-made *bust* and *win* sting |
| `hud.SetBubbleText(Id, Text, SpeakerName, PlayerDistance)` | Speaker-attributed bubble — a gambler's taunt line |
| `hud.SetFaderState(State, Layout)`, `hud.SetFullModeVignette(Value)` | Cinematic framing when a match starts |
| `ApseModalDialog.OpenQuestionDialog(Question, ActionConfirm, ActionCancel, HintConfirm, HintCancel)` | A **native yes/no modal**, with real `OnQuestionDialogConfirmClicked` / `OnQuestionDialogCancelClicked` events back to Lua — the correct home for the dice *invite* prompt, replacing the `DrawText` toast |
| `ApseModalDialog.OpenRandomEventDialog(Caption, Description, IconId, HasTimer, …)` + `RandomEventDialogUpdateTimer(RelativeTime)` + `ShowRandomEventResult(Stopped, Message)` | A framed caption/description card with an icon and a live timer bar — the closest thing in the game to a BG3 event panel |

Declared MovieClips we can transform/fade directly, including
`DiceContainer` → `bl.diceScoreContainer`, `TutorialMessage` → `tl.tutorial`,
`InfoText`, `PopUpBackground`, `FancyEvent`, `SkillCheck`, `Vignette`, `Fader`,
`DiceCursor`. *(PROVEN-ONDISK)*

### What is not yet proven about this route

1. **Is `UIAction` present and callable in our stripped Lua sandbox?**
   `docs/kcd2_lua_api.md` records `UIAction.RegisterElementListener` as verified
   in-game, so the table exists. `CallFunction` specifically is **UNVERIFIED**.
2. **Will `hud.ShowDiceScore` render outside the native dice minigame?** The
   ActionScript behind `fc_showDiceScore` may gate on a HUD game mode
   (`SetGameMode` exists) or expect the minigame's own container to be visible.
   **UNVERIFIED — this is the single most important thing the probe answers.**
3. **Do the dice *themselves* come with it?** Almost certainly not. In the
   native minigame the six dice are physical 3-D props on the table; the HUD
   only draws the scoreboard, the selector highlights and the cursor. So even in
   the best case this route gives us a **native scoreboard**, and the dice faces
   remain ours to draw. Plan accordingly — that is a hybrid, not a free win.
4. **Reported community caveat:** `UIAction.RegisterElementListener` has been
   reported to crash on UI transitions in KCD2 if registered carelessly
   ([Nexus LuaDB thread](https://www.nexusmods.com/kingdomcomedeliverance2/mods/1523?tab=posts)).
   **Unverified**, but a reason to wrap every registration in `pcall` and to
   unregister on session end.

**Effort:** low to try (a handful of `pcall`'d Lua lines). **Risk:** low —
worst case a call is a no-op or throws inside a `pcall`. **Payoff:** the
highest available.

---

## Route 2 — vector drawing from `System` *(the floor, and it is a real floor)*

`CryScriptSystem.dll`'s `CScriptBind_System` registers, in this build
*(PROVEN-ONDISK — string scan)*:

```
DrawText  DrawLabel  DrawLine  Draw2DLine  SetScissor  GetViewport
ProjectToScreen  SetScreenFx  GetScreenFx  SetPostProcessFxParam  LoadFont
ScreenToTexture  SetConsoleImage
```

Signatures from the vendor docs *(PROVEN-ONDISK)*:

```lua
System.DrawText( x, y, text, font, size, r, g, b )   -- screen space
System.DrawLabel( vPos, fSize, text, r, g, b, alpha ) -- world space
System.Draw2DLine( p1x, p1y, p2x, p2y, r, g, b, alpha ) -- screen space
System.DrawLine( p1, p2, r, g, b, alpha )             -- world space
System.SetScissor( x, y, w, h )
System.ProjectToScreen( point )                       -- world -> screen
System.GetViewport( )
```

Three things here that this project did not know it had:

- **`Draw2DLine`** — screen-space vector lines with full RGBA. Frames, rules,
  dividers, pip dots, bars, and (stacked closely) filled panels. This is what
  turns "text on nothing" into "an object on the screen."
- **`DrawText` takes a font name and colour.** `kdcmp.lua` currently calls
  `System.DrawText(10, 60, text, 2)` — four arguments, so that `2` is landing in
  the **font** slot, not the size slot. It renders, so the engine is falling
  back gracefully; it also means the mod has never actually set a size or a
  colour. **UNVERIFIED whether this build's arity matches the doc** — the probe
  settles it.
- **`GetViewport`** — resolution-independent layout instead of hardcoded pixels.

### The font, which is the whole aesthetic argument

`Engine/Engine.pak` ships *(PROVEN-ONDISK)*:

```
Fonts/AlexanderQuill.ttf    <- medieval quill hand
Fonts/VeraMono.ttf
Fonts/default.xml    -> VeraMono, 2-pass (text + 1px black shadow)
Fonts/hud.xml        -> VeraMono, additive blend
Fonts/console.xml    -> VeraMono
Fonts/subtitles.xml  -> AlexanderQuill, 2-pass (text + 1px black shadow)
```

So **`System.DrawText(x, y, text, "subtitles", size, r, g, b)`** should render
in the game's own calligraphic hand, with a built-in drop shadow, in any
colour. That single call is the difference between "a mod's debug HUD" and
"something that belongs in Kingdom Come." **UNVERIFIED until the probe runs**,
but the font, the fontshader and the parameter are all confirmed present.

A mod can also ship its own `Fonts/kcd2mp.xml` fontshader (pointing at the
game's existing `AlexanderQuill.ttf`, no redistribution) with a custom
multi-pass effect — e.g. a gold pass over a heavy shadow — and `System.LoadFont`
exists to register it. **UNVERIFIED**, second-order polish, not needed for v1.

### Clean negatives on this route

- **No image / sprite / texture draw exists on `System`.** The registration
  table above is the complete list; there is no `DrawImage`, `Draw2DImage`,
  `DrawSprite` or equivalent. *(NEGATIVE)* Every "draw a picture from Lua" idea
  dies here, and that is why Route 1 matters.
- **`DrawTriStrip` is documented but not registered in this build.** Warhorse's
  docs describe `System.DrawTriStrip(handle, nMode, vtxs, r, g, b, alpha)`, but
  the string does not appear in `CryScriptSystem.dll`'s registration table
  (`DrawText`, `DrawLabel`, `DrawLine`, `Draw2DLine`, `DrawFrameControl` do).
  *(NEGATIVE, this build)* Worth stating plainly as a warning about the docs:
  **they describe a source tree, not necessarily this binary.** Filled polygons
  must be faked with stacked `Draw2DLine` calls.

**Effort:** low — pure Lua, no new files, no dependency. **Risk:** near zero,
this is an extension of primitives already shipping. **Payoff:** a genuinely
designed panel. This ships regardless of what Route 1 does.

---

## Route 3 — ship our own `.gfx` + `UIElements` XML *(not recommended for v1)*

In principle a mod can drop `Libs/UI/UIElements/kcd2mp_dice.xml` plus
`Libs/UI/kcd2mp_dice.gfx` into its pak and get a brand-new element the Flash UI
system registers at load, then drive it with `UIAction.CallFunction`. That is
the unrestricted-canvas answer.

**Why it is not the plan:**

- **Authoring the `.gfx` is the blocker.** `.gfx` is Scaleform's compiled SWF
  format. Producing one normally means Adobe Flash/Animate authoring plus
  Scaleform's `gfxexport`, which is not freely distributable. JPEXS Free Flash
  Decompiler can *read* and edit `.gfx` (this is how the HUD-texture mods work —
  see the community section), but round-tripping a newly authored file with
  working ActionScript is a different and much less reliable operation.
  **UNVERIFIED that we can produce a loadable one at all.**
- **UNVERIFIED that the engine scans mod paks for new UIElements XML.** Our mod
  pak's `Libs/Tables/…` merge works because data tables merge by filename
  convention; the Flash UI directory scan is a different mechanism.
- Either failure costs a whole session and delivers nothing, while Route 1 +
  Route 2 together already clear the design bar.

**Effort:** high. **Risk:** high, two independent unknowns. **Verdict:**
recorded as the ceiling-above-the-ceiling, deliberately not attempted now.

---

## Route 4 — texture/`.dds` replacement (the "face rework" pipeline)

The human's premise was that face-rework and UI-overhaul mods prove custom
visuals are reachable. Correct that they prove *something*, but it is
**apples to oranges** for this feature, and the honest answer is: that pipeline
cannot draw our panel.

How those mods work *(sourced from the community write-up cited below, and
consistent with the pak contents above)*: extract `Libs/UI/Textures/*.dds`,
repaint them (BC3/DXT5), repack into a mod pak; the game loads the mod's copy
instead. `hud.gfx` references those textures, sometimes whole files and
sometimes sub-regions of an atlas. Face reworks are the same idea one directory
over — replacing character textures/meshes.

**Why it does not help here:** it changes *what an existing element looks like*.
It cannot introduce a new element, and it cannot bind live values. The
community guide says this explicitly — element layout "is controlled by the game
code or `.gfx` files," not by textures. Our dice panel is defined by changing
numbers every second; a static texture swap has no way to express that.

Where it *could* matter: as a second-order polish pass **on top of Route 1** —
if we end up using a native panel and want its art restyled. Out of scope for
v1. **Effort:** medium. **Risk:** low but also low value here. **Verdict:**
not adopted.

---

## Route 5 — third-party script extenders

Re-evaluated specifically as a route to custom *rendering*, which is the
question `docs/WO-6-native-dice-findings.md` §R0 did not ask (it declined these
as general hooking frameworks, correctly, for a different reason).

| Candidate | Rendering capability | License | Verdict |
|---|---|---|---|
| [`xiaoxiao921/KCD2ModLoader`](https://github.com/xiaoxiao921/KCD2ModLoader) | **Real** — Dear ImGui bound directly into Lua. Loads as a `d3d12.dll` proxy next to `KingdomCome.exe` | **MIT** — GPLv3-compatible | **Declined for v1.** The capability is real and the license is fine, but (a) ImGui's look is the *opposite* of the brief — it reads as a debug tool, and dragging it to parchment-and-blackletter means loading a TTF and restyling every widget, which is more work than Route 2 for a worse result; (b) it is a second injected DLL alongside our own `KCDMP.dll`, on a proxy-DLL path we have never tested against the Modding Tools build; (c) it would be a hard dependency on the whole mod for one panel. Recorded as the fallback if Routes 1 and 2 both somehow fail. |
| [`violetanvil/kcdx`](https://github.com/violetanvil/kcdx) | **None found.** Hooking, byte patching, Address Library, AOB scanning, console commands, cosaves — no ImGui, no D3D overlay, no drawing hooks | MIT (repo claim; GitHub's API previously reported NOASSERTION) | **Declined**, same conclusion as R0 and for a stronger reason: it does not solve the drawing problem at all |
| Warhorse official Modding Tools | **Yes, and it is what we are using** — the `script_bind` docs and the `Libs/UI` data are the entire basis of Routes 1 and 2 | Already a required dependency of this project | **Adopted** (no change — it was already required) |

**No new dependency is adopted.** Nothing to vendor, pin, or license-check
beyond what the project already requires.

---

## Community techniques — what the open web added

Searched Nexus, GitHub and modding wikis per the brief. Summary of what the
KCD/KCD2 scene actually does for visuals, and how it lands against the above:

- **HUD/UI mods are texture-and-`.gfx` work.** The reference write-up is
  [*Creating "Clean & Minimal HUD and Map" Mod*](https://theartofdev.com/2025/06/12/kcd-clean-minimal-hud-mod/):
  `.pak` → `Libs/UI/Textures/*.dds` edited in paint.net at BC3/DXT5, `hud.gfx`
  inspected with JPEXS to find which texture (or atlas sub-region) an element
  uses. It states outright that repositioning elements cannot be done from
  textures alone. Confirms Route 4's ceiling.
- **Sizeable KCD2 HUD-mod ecosystem**, all on that same pipeline —
  [Sleek Modular HUD](https://www.nexusmods.com/kingdomcomedeliverance2/mods/1388),
  [HUD and Inventory Rework](https://www.nexusmods.com/kingdomcomedeliverance2/mods/309),
  [Interactive UI Rework](https://www.nexusmods.com/kingdomcomedeliverance2/mods/312).
  Notable: mods that touch `hud.gfx` or its textures are mutually incompatible,
  while position-only mods can coexist. **Relevant to us:** Routes 1 and 2 touch
  *neither*, so our overlay is compatible with every HUD mod on Nexus. That is a
  real, non-obvious argument for this approach.
- **Script extenders exist and are maintained** — covered in Route 5.
- **Nothing found** where a mod adds its own `UIElements` XML + `.gfx`. Absence
  of evidence, not evidence of absence, but it is consistent with Route 3 being
  hard.

Sources are linked inline above; none of it is treated as proof.

---

## A2 — the in-game probe

Everything above that is marked UNVERIFIED is settled by one script,
`tools/Probe-Visual.ps1`, run once against a live game. It is written to be
read-only and non-destructive: every call is inside `pcall`, and anything it
shows, it hides again.

What it answers, in order of importance:

1. Does `UIAction` exist in our sandbox, and what is on it?
2. Does `UIAction.CallFunction("hud", -1, "ShowInfoText", …)` put text on
   screen? (cheapest possible proof that the whole Flash route works)
3. Does `hud.ShowDiceScore(…)` render the native dice scoreboard **outside** a
   native dice game?
4. Does `AddDiceSelector` / `ShowDiceCursor` draw at arbitrary 1920×1080 coords?
5. Does `ApseModalDialog.OpenQuestionDialog` open, and does its confirm/cancel
   event reach a Lua callback?
6. Does `System.DrawText` accept `(x, y, text, font, size, r, g, b)` — i.e. is
   the vendor-documented arity real in this build?
7. Does `"subtitles"` (AlexanderQuill) render as a font name?
8. Does `System.Draw2DLine` draw, with alpha?
9. Does `System.GetViewport` return usable numbers?

### Results — programmatic blocks, run 2026-07-29 against a live game

Run against the human's already-running Modding Tools session (save loaded,
`GameTime=15012022`). Raw output in `tools/probe-visual-results.txt`.

**1. `UIAction` is real, and the whole Flash route is reachable from our
sandbox.** *(PROVEN-INGAME)* This was the single biggest unknown and it came
back clean:

```
vis.UIAction=table
vis.ui.CallFunction=function          vis.ui.SetPos=function
vis.ui.ShowElement=function           vis.ui.SetAlpha=function
vis.ui.HideElement=function           vis.ui.SetScale=function
vis.ui.SetVariable=function           vis.ui.SetVisible=function
vis.ui.SetArray=function              vis.ui.GotoAndPlay=function
vis.ui.StartAction=function           vis.ui.RegisterElementListener=function
```

**2. The `System` draw surface is exactly what the binary said.**
*(PROVEN-INGAME)*

```
vis.sys.DrawText=function     vis.sys.Draw2DLine=function    vis.sys.SetScissor=function
vis.sys.DrawLabel=function    vis.sys.GetViewport=function   vis.sys.LoadFont=function
vis.sys.DrawLine=function     vis.sys.ProjectToScreen=function
vis.sys.DrawTriStrip=nil
```

`DrawTriStrip` coming back **nil** is worth calling out: Warhorse's own docs
document it, and the DLL's registration table said it was absent. The live game
agrees with the binary, not the docs. That is the whole argument for checking
registration tables rather than trusting vendor documentation — and it is the
reason no filled polygons are used anywhere in the overlay.

**3. `System.GetViewport()` returns a TABLE, not four values.**
*(PROVEN-INGAME)* The obvious multiple-return reading is wrong:

```
vis.viewport.x=0  vis.viewport.y=0  vis.viewport.width=1920  vis.viewport.height=1080
```

So the real back buffer is addressable and the overlay can lay out
resolution-independently.

**4. Dice tables are trivially identifiable — C1 is settled.**
*(PROVEN-INGAME)* `System.GetEntitiesByClass("DiceInteractor")` returned **nine**
tables, with the player standing **1.2 m from one**:

```
DiceInteractor1[Table/table_dice8_d4afcbd3-…]   d=1.2
DiceInteractor1[Table/table_dice4_14387850-…]   d=512.9
DiceInteractor1[Table/table_dice3_74a5fb67-…]   d=525.3
…six more, 557 m – 1257 m
```

The distance spread is its own negative control: one table is essentially under
the player's hand and the next is half a kilometre away, so a 4 m gate cannot
false-positive. `System.GetEntitiesInSphereByClass(pos, 60, "DiceInteractor")`
returned 1, confirming the sphere form works too. `DiceMinigameCup` is also a
live class.

### Still needing a human's eyes

The remaining questions are all "did it appear, and what did it look like",
which no script can answer. They are batched into the runbook in
`docs/WO-6-progress.md`:

- Does `DrawText` accept `(x, y, text, font, size, r, g, b)` in this build, and
  does `"subtitles"` render as AlexanderQuill?
- Which coordinate space do 2-D draws address — the real back buffer or a fixed
  virtual one?
- Does `Draw2DLine` honour alpha?
- Do `hud.ShowInfoText` / `ShowDiceScore` / `AddDiceSelector` / `ShowTutorial` /
  `ShowSkillCheckResult` and `ApseModalDialog.OpenQuestionDialog` actually
  render outside their normal context?

**One caveat on the Flash calls, stated plainly:** every one of them will log
`=true` as long as it does not throw, and `UIAction.CallFunction` is very
unlikely to throw for a name it does not recognise. **A `true` there is not
evidence anything appeared.** Only the description of the screen decides it.

### A trap this probe hit, and the fix

The first version of the `dicetable` block produced **no output at all** — no
error, no log line, nothing. Not a Lua bug: it is the exact failure
`probe_transport.lua`'s header already documents, where the console endpoint
silently drops a chunk that is long or structurally complex. Rewritten as one
short statement, it worked immediately. **Keep probe blocks small.**

---

## Chosen visual tier

**Decided: hybrid, built floor-first.** The A2 run above strengthens this rather
than changing it — `UIAction.CallFunction` being live means the native panels
are genuinely worth wiring, but whether each one *renders* is still unknown, so
none of them may be load-bearing.

- **Ship Route 2 unconditionally.** The dice tray, faces, keep/free state,
  frame, banners and every animated transition are drawn by us with
  `DrawText` + `Draw2DLine`, in AlexanderQuill, in a parchment-and-iron palette.
  No dependency, no unknowns, works today. This is the deliverable.
- **Layer Route 1 on top, per capability, each behind its own probe result.**
  Each native panel is an independent enhancement that degrades to the Route 2
  drawing if the probe says no:
  - invite prompt → `ApseModalDialog.OpenQuestionDialog`, else the drawn toast
  - bust / win sting → `hud.ShowSkillCheckResult`, else a drawn flash
  - turn hand-off → `hud.ShowInfoText`, else a drawn banner
  - scoreboard → `hud.ShowDiceScore`, else our drawn score card
- **Do not attempt Route 3** this session. **Do not adopt Route 5.**

Rationale: the brief's own rule — the proven floor must ship and must not be
blocked by the rich tier. Structuring every native panel as an *optional
upgrade over a working drawn equivalent* means the probe's outcome changes how
good it looks, never whether it works.
