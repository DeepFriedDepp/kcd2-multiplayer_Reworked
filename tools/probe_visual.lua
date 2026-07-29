-- WO-6 visual-capability probes (A2).
--
-- Answers, against a real running game, everything docs/WO-6-visual-capability.md
-- marks UNVERIFIED. Two kinds of question, and they are reported differently:
--
--   * Programmatic  -- "does this API exist / did the call throw?" Answers go to
--     kcd.log as [KCD2-MP-PROBE] lines and Probe-Visual.ps1 collects them.
--   * Visual        -- "did anything appear on screen, and what did it look
--     like?" No script can answer this. Those blocks put something on screen and
--     leave it there for a fixed window; the HUMAN reports what they saw.
--     A call that returns cleanly and draws nothing is the expected failure
--     mode here, so "no error" is never treated as success.
--
-- Output convention, matching probe_transport.lua:
--   [KCD2-MP-PROBE] vis.<key>=<value>
--
-- KEEP EACH BLOCK SMALL. Long or deeply-nested chunks are silently dropped by
-- the console endpoint -- no output, no error, nothing in the log. This is
-- already documented in probe_transport.lua and cost real time there.
--
-- Nothing here is destructive: every game call is wrapped in pcall, every
-- element this shows is hidden again by the `cleanup` block, and no CVar,
-- game mode, fader or vignette is touched. Run `cleanup` if you stop early.
--
-- Driven by tools/Probe-Visual.ps1.

--@@BLOCK reset
-- Fresh namespace on every run so a re-run never inherits a half-set mode or a
-- still-running timer from the previous one.
if KCD2MPVIS and KCD2MPVIS.stop then pcall(KCD2MPVIS.stop) end
KCD2MPVIS = { mode = nil, running = false, t0 = 0, frames = 0 }
System.LogAlways("[KCD2-MP-PROBE] vis.reset=ok")

--@@BLOCK inventory_system
-- Which draw primitives this build actually exposes to Lua. The shipped
-- CryScriptSystem.dll registers DrawText/DrawLabel/DrawLine/Draw2DLine/
-- SetScissor/GetViewport/ProjectToScreen and NOT DrawTriStrip; this confirms
-- that from inside the sandbox, which is the only context that counts.
local function P(k,v) System.LogAlways("[KCD2-MP-PROBE] vis."..k.."="..tostring(v)) end
for _,n in ipairs({"DrawText","DrawLabel","DrawLine","Draw2DLine","DrawTriStrip",
                   "SetScissor","GetViewport","ProjectToScreen","LoadFont"}) do
    P("sys."..n, type(System[n]))
end

--@@BLOCK inventory_uiaction
-- Does the Flash UI binding exist in our sandbox at all? kcd2_lua_api.md records
-- RegisterElementListener as verified; CallFunction is the one that matters and
-- has never been checked.
local function P(k,v) System.LogAlways("[KCD2-MP-PROBE] vis."..k.."="..tostring(v)) end
P("UIAction", type(rawget(_G,"UIAction")))
if type(UIAction) == "table" then
    for _,n in ipairs({"CallFunction","ShowElement","HideElement","SetVariable",
                       "SetArray","SetPos","SetAlpha","SetScale","SetVisible",
                       "GotoAndPlay","RegisterElementListener","StartAction"}) do
        P("ui."..n, type(UIAction[n]))
    end
end

--@@BLOCK viewport
-- Resolution, so the overlay can lay out in fractions instead of magic pixels.
-- Return shape is unknown (x,y,w,h is the guess) -- log everything it gives back.
-- Returns a TABLE, not four values: {x=0, y=0, width=..., height=...}.
local t = System.GetViewport()
for k, v in pairs(t) do
    System.LogAlways("[KCD2-MP-PROBE] vis.viewport."..tostring(k).."="..tostring(v))
end

--@@BLOCK drawloop
-- Screen-space draws only survive one frame, so anything visual needs a
-- self-rescheduling timer -- the same pattern kdcmp.lua's label loop uses, and
-- the one the real overlay will use. 8 ms beats a 16.7 ms frame, so no flicker.
-- Auto-stops after 25 s so a forgotten probe can never leave art on screen.
KCD2MPVIS.tick = function()
    if not KCD2MPVIS.running then return end
    Script.SetTimer(8, KCD2MPVIS.tick)   -- reschedule FIRST, a draw error must not kill the loop
    KCD2MPVIS.frames = KCD2MPVIS.frames + 1
    if os.clock() - KCD2MPVIS.t0 > 25 then KCD2MPVIS.running = false; return end
    local f = KCD2MPVIS[KCD2MPVIS.mode or ""]
    if f then pcall(f) end
end
KCD2MPVIS.start = function(mode)
    KCD2MPVIS.mode = mode; KCD2MPVIS.t0 = os.clock(); KCD2MPVIS.frames = 0
    if not KCD2MPVIS.running then KCD2MPVIS.running = true; Script.SetTimer(8, KCD2MPVIS.tick) end
    System.LogAlways("[KCD2-MP-PROBE] vis.loop.start="..tostring(mode))
end
KCD2MPVIS.stop = function()
    KCD2MPVIS.running = false
    System.LogAlways("[KCD2-MP-PROBE] vis.loop.frames="..tostring(KCD2MPVIS.frames))
end

--@@BLOCK drawtext_shapes
-- THE font question. kdcmp.lua currently calls DrawText(x,y,text,size) -- four
-- args -- but Warhorse's own scriptbind docs say the signature is
-- (x, y, text, font, size, r, g, b), which would mean that 4th argument has
-- always been landing in the FONT slot, not size.
--
-- Four labelled lines drawn at once. The human reports which differ. If B/C/D
-- are coloured and sized while A is not, the documented arity is real; if all
-- four look identical, this build kept the 4-arg form and colour is out of
-- reach for DrawText (DrawLabel still takes RGBA regardless).
--
-- "subtitles" is the CryFont bound to AlexanderQuill.ttf -- the game's own
-- medieval hand. If line C renders in it, the whole typographic tier is solved.
KCD2MPVIS.text = function()
    System.DrawText(60, 200, "A  legacy 4-arg call", 2)
    System.DrawText(60, 230, "B  default font, amber, 8-arg", "default", 2, 1.0, 0.78, 0.25)
    System.DrawText(60, 260, "C  subtitles font (AlexanderQuill)", "subtitles", 2, 1.0, 0.88, 0.60)
    System.DrawText(60, 290, "D  hud font, green", "hud", 2, 0.3, 1.0, 0.3)
end
KCD2MPVIS.start("text")

--@@BLOCK drawtext_space
-- THE layout question, and it decides every coordinate in the overlay.
-- CryEngine has historically drawn 2-D labels in a VIRTUAL 800x600 space
-- regardless of resolution, but some builds use real back-buffer pixels.
-- kdcmp.lua's existing draws are all near the top-left corner, where both
-- spaces agree, so they have never distinguished the two.
--
-- Markers are placed at the right and bottom edges of each candidate space.
-- Whichever pair sits near the screen edge is the real space; the other pair is
-- far off screen and invisible.
KCD2MPVIS.space = function()
    System.DrawText(10,   10,  "TL origin", 2)
    System.DrawText(700,  300, "800x600: RIGHT edge marker", 2)
    System.DrawText(300,  560, "800x600: BOTTOM edge marker", 2)
    System.DrawText(1650, 300, "1920x1080: RIGHT edge marker", 2)
    System.DrawText(300,  1020,"1920x1080: BOTTOM edge marker", 2)
end
KCD2MPVIS.start("space")

--@@BLOCK draw2dline_space
-- Draw2DLine's coordinate space is undocumented for this build: CryEngine has
-- used both normalised 0..1 and raw pixels across versions. Draw both and let
-- the human say which box appeared -- guessing this wrong would silently place
-- the entire overlay frame off screen.
--   RED   box = pixel space   (100,400) .. (500,600)
--   GREEN box = normalised    (0.6,0.6) .. (0.9,0.8)
local function box(x1,y1,x2,y2,r,g,b)
    System.Draw2DLine(x1,y1,x2,y1,r,g,b,1); System.Draw2DLine(x2,y1,x2,y2,r,g,b,1)
    System.Draw2DLine(x2,y2,x1,y2,r,g,b,1); System.Draw2DLine(x1,y2,x1,y1,r,g,b,1)
end
KCD2MPVIS.lines = function()
    box(100, 400, 500, 600, 1, 0.2, 0.2)
    box(0.6, 0.6, 0.9, 0.8, 0.2, 1, 0.2)
    System.DrawText(60, 380, "RED = pixel space   GREEN = 0..1 space", 2)
end
KCD2MPVIS.start("lines")

--@@BLOCK draw2dline_alpha
-- Alpha is what makes a drawn panel read as an object with a ground rather than
-- floating strokes. Four horizontal rules at descending alpha; the human reports
-- whether they fade. If alpha is ignored, the design loses its parchment ground
-- and has to lean on line density instead.
KCD2MPVIS.alpha = function()
    local a = {1.0, 0.66, 0.33, 0.12}
    for i = 1, 4 do
        System.Draw2DLine(100, 620 + i*14, 520, 620 + i*14, 0.95, 0.82, 0.45, a[i])
    end
    System.DrawText(60, 610, "four rules, alpha 1.0 / 0.66 / 0.33 / 0.12", 2)
end
KCD2MPVIS.start("alpha")

--@@BLOCK flash_infotext
-- Cheapest possible proof that the whole Flash UI route works. If a line of text
-- appears centre-screen in the game's own style, then UIAction.CallFunction
-- reaches hud.gfx and every other native panel below is worth trying.
-- NOTE the element name is lowercase "hud" -- HUD.xml declares <UIElement
-- name="hud">, and the wrong case is a silent no-op, not an error.
local ok, err = pcall(function()
    UIAction.CallFunction("hud", -1, "ShowInfoText", "KCD2-MP probe: info text", 10, 6000, true)
end)
System.LogAlways("[KCD2-MP-PROBE] vis.flash.infotext="..tostring(ok).." "..tostring(err))

--@@BLOCK flash_notification
-- Second, independent Flash call with a different function and arity, so a
-- single-function failure can be told apart from the binding not working.
local ok, err = pcall(function()
    UIAction.CallFunction("hud", -1, "ShowNotification", "KCD2-MP probe: notification")
end)
System.LogAlways("[KCD2-MP-PROBE] vis.flash.notification="..tostring(ok).." "..tostring(err))

--@@BLOCK flash_dicescore
-- THE headline question. Does the game's own dice scoreboard render when we push
-- values into it OUTSIDE a native dice game? Values are deliberately distinctive
-- (target 2500, player 1234/600, opponent 987/350) so they cannot be confused
-- with anything the game itself would show.
--
-- PlayerName is typed int in HUD.xml -- almost certainly a name/localisation id,
-- not a string. 0 is the first guess; if the panel appears with a blank or wrong
-- name that is still a pass for the important part.
local ok, err = pcall(function()
    UIAction.CallFunction("hud", -1, "ShowDiceScore",
        2500, 0, 1234, 600, 150, "", 0, 0, 987, 350, 0, "", 0, 0)
end)
System.LogAlways("[KCD2-MP-PROBE] vis.flash.dicescore="..tostring(ok).." "..tostring(err))

--@@BLOCK flash_diceselector
-- The selection highlights and cursor, documented as taking positions "in
-- 1920x1080 space". If these draw at arbitrary coordinates we can highlight our
-- own dice with the game's own art instead of drawing selection rectangles.
local ok, err = pcall(function()
    UIAction.CallFunction("hud", -1, "AddDiceSelector", 1, 760.0, 700.0, true)
    UIAction.CallFunction("hud", -1, "AddDiceSelector", 2, 880.0, 700.0, false)
    UIAction.CallFunction("hud", -1, "ShowDiceCursor", 1000.0, 700.0)
end)
System.LogAlways("[KCD2-MP-PROBE] vis.flash.diceselector="..tostring(ok).." "..tostring(err))

--@@BLOCK flash_tutorial
-- The tutorial parchment box. HUD.xml documents its Text param as "can be HTML",
-- which would give a framed, styled, rich-text panel for free. The markup here
-- is deliberately mixed so the human can report whether it rendered as styled
-- text or leaked through as literal angle brackets.
local html = "<font color='#d8b45a' size='22'>Wagers</font><br/>" ..
             "<b>Jonas</b> stakes <font color='#c8a13c'>40</font> groschen."
local ok, err = pcall(function()
    UIAction.CallFunction("hud", -1, "ShowTutorial", "kcd2mp_probe", html, 8000, false, 5, 0, false, "")
end)
System.LogAlways("[KCD2-MP-PROBE] vis.flash.tutorial="..tostring(ok).." "..tostring(err))

--@@BLOCK flash_skillcheck
-- A ready-made success/fail flourish. If this fires standalone it is the bust
-- sting and the win flourish, in native art, for one call.
local ok, err = pcall(function()
    UIAction.CallFunction("hud", -1, "ShowSkillCheckResult", "Dice", 1)
end)
System.LogAlways("[KCD2-MP-PROBE] vis.flash.skillcheck="..tostring(ok).." "..tostring(err))

--@@BLOCK flash_modal_listen
-- Registers the callback BEFORE opening the modal, so a confirm/cancel cannot be
-- missed. Wrapped in pcall because RegisterElementListener has been reported to
-- crash on UI transitions in KCD2 if registered carelessly -- if this block is
-- the one that kills the game, that report is confirmed and the invite prompt
-- stays on our own drawn toast.
KCD2MPVIS.onModal = function(elementName, instanceId, eventName, args)
    System.LogAlways("[KCD2-MP-PROBE] vis.modal.event="..tostring(eventName))
end
local ok, err = pcall(function()
    UIAction.RegisterElementListener(KCD2MPVIS, "ApseModalDialog", -1, "", "onModal")
end)
System.LogAlways("[KCD2-MP-PROBE] vis.flash.modallisten="..tostring(ok).." "..tostring(err))

--@@BLOCK flash_modal_open
-- A native yes/no modal is the right home for the dice invite prompt. Answer it
-- in game: the reply should appear above as vis.modal.event=<something>.
-- If it opens and cannot be dismissed, run the `cleanup` block.
local ok, err = pcall(function()
    UIAction.CallFunction("ApseModalDialog", -1, "OpenQuestionDialog",
        "Jonas challenges thee to a game of dice. Dost thou accept?",
        "confirm", "cancel", "Accept", "Decline")
end)
System.LogAlways("[KCD2-MP-PROBE] vis.flash.modalopen="..tostring(ok).." "..tostring(err))

--@@BLOCK dicetable
-- C1: are real in-world dice tables identifiable?
--
-- Not a guess. Scripts.pak ships Entities/DiceInteractor.ent, which registers the
-- entity class "DiceInteractor" against Scripts/Entities/WH/Minigames/
-- DiceInteractor.lua -- the script that puts the "@ui_hud_play_dice" action on a
-- dice board (model .../games/dice/dice_board.cgf). So the query is a plain
-- class lookup, and the only open question is whether a real tavern table in the
-- world is actually one of these entities.
--
-- ANSWERED 2026-07-29 -- kept so it can be re-run after a game patch. Every
-- DiceInteractor in the world, with its distance. Deliberately ONE short
-- statement: an earlier, longer version of this block was silently dropped by
-- the console endpoint with no output and no error, which is the exact trap
-- probe_transport.lua's header warns about. Short blocks are reliable.
local p = player:GetWorldPos()
local l = System.GetEntitiesByClass("DiceInteractor")
for i, e in ipairs(l) do
    local q = e:GetWorldPos()
    local d = math.sqrt((q.x-p.x)^2 + (q.y-p.y)^2 + (q.z-p.z)^2)
    System.LogAlways(string.format("[KCD2-MP-PROBE] vis.table%d %s d=%.1f", i, tostring(e:GetName()), d))
end

--@@BLOCK cleanup
-- Undo everything this probe could have put on screen. Safe to run at any point,
-- including on its own if a block left something up.
-- Tolerates KCD2MPVIS never having been created, so this block is safe to run
-- on its own via -Cleanup after a crash or a fresh game start.
if type(KCD2MPVIS) ~= "table" then KCD2MPVIS = {} end
KCD2MPVIS.running = false
KCD2MPVIS.mode = nil
local function try(fn) pcall(fn) end
try(function() UIAction.CallFunction("hud", -1, "HideDiceScore") end)
try(function() UIAction.CallFunction("hud", -1, "RemoveDiceSelector", 1) end)
try(function() UIAction.CallFunction("hud", -1, "RemoveDiceSelector", 2) end)
try(function() UIAction.CallFunction("hud", -1, "HideDiceCursor") end)
try(function() UIAction.CallFunction("hud", -1, "HideTutorial", "kcd2mp_probe") end)
try(function() UIAction.CallFunction("hud", -1, "HideInfoText") end)
try(function() UIAction.CallFunction("ApseModalDialog", -1, "CloseQuestionDialog") end)
-- UnregisterElementListener takes (table, elementName) -- NOT the callback name.
try(function() UIAction.UnregisterElementListener(KCD2MPVIS, "ApseModalDialog") end)
System.LogAlways("[KCD2-MP-PROBE] vis.cleanup=done")
