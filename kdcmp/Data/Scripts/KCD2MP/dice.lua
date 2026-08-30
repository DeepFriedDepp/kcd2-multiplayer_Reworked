-- KCD2 Multiplayer - generated module split from Startup/kdcmp.lua
-- Loaded in a fixed order by Scripts/Startup/kdcmp.lua.

local mp_log = KCD2MP.util.log

-- ============================================================================
-- ===== Dice overlay (WO-6) ==================================================
-- ============================================================================
--
-- The in-game UI for a PvP Farkle match. Replaces the launcher window
-- (KCDMP_launcher/DiceWindow.razor), which is retired -- see docs/WO-6-*.md.
--
-- Renders ONLY what the relay sent. No score, no roll and no turn order is ever
-- computed here; the agent pushes a full DiceState snapshot and this draws it.
-- Same rule DiceClient.cs follows on the C# side.
--
-- The board is HTML pushed into the game's own tutorial panel via
-- UIAction.CallFunction("hud", -1, "ShowTutorial", ...) -- a gilded gothic
-- frame around illuminated parchment, rendered by the game. We supply the
-- markup; Warhorse supplies the art.
--
-- Art direction, palette and the state model are in docs/WO-6-overlay-design.md;
-- what can and cannot be rendered, with the evidence, is in
-- docs/WO-6-visual-capability.md. Read both before changing anything here --
-- most of the obvious ideas have already been tried against the real game and
-- do not work.

KCD2MP.dice = {
    open      = false,

    -- --- how it renders, all established against the real game --------------
    --
    -- The board is an HTML page pushed into the game's own tutorial panel
    -- (hud.ShowTutorial): a gilded gothic frame around illuminated parchment,
    -- rendered by the game itself.
    --
    -- This is the SECOND renderer. The first drew its own panel with
    -- System.Draw2DLine and it rendered NOTHING -- that call is registered,
    -- callable, returns cleanly, and r_enableAuxGeom is already 1, but no line
    -- ever reaches the screen. Only System.DrawText works in screen space, and
    -- plain text was the whole complaint. See docs/WO-6-visual-capability.md
    -- for the full evidence; do not reintroduce Draw2DLine here.
    -- Element id. ShowTutorial QUEUES rather than replaces, so every update is
    -- HideTutorial(id) then ShowTutorial(id, ...); pushing twice without the
    -- hide leaves the second push waiting behind the first. Found the hard way.
    panelId   = "kcd2mp_dice",
    -- The parchment panel IS the whole live board (score, dice, marks) --
    -- see KCD2MP_DiceRender and scheduleRender for how pushes are kept rare
    -- enough not to flicker: immediate on relay-driven state (open, a new
    -- DiceState, error, end), debounced on local rapid-fire input (marking).
    usePanel  = true,
    -- Marks/roll pushes ride the same debounce window so a burst of presses
    -- coalesces into one push instead of one each. See scheduleRender.
    renderDebounceMs = 250,
    -- Safety net, not the intended lifetime: every state change re-pushes, so
    -- the board is normally refreshed long before this expires. Was 120000 (2
    -- minutes) -- too short in practice: a live match hit a real stretch with
    -- no new relay-driven state (the seated-R bug meant no roll was ever sent),
    -- and the card visibly vanished mid-match while the session was still very
    -- much alive on the relay. 30 minutes is generous enough not to intrude on
    -- a legitimately slow human turn while still self-clearing eventually if
    -- this code ever truly stops refreshing. mp_dice_close/mp_dice_flush are
    -- the manual escape hatches if it's ever stuck sooner than that.
    panelMs   = 1800000,

    -- Glyphs VERIFIED renderable in this panel's font library. Everything else
    -- tried came back a tofu box: the Unicode die faces, every box-drawing
    -- character, and all geometric shapes including U+25CF. Worse, a plain
    -- ASCII '|' renders as NOTHING AT ALL -- hence the broken bar.
    pip       = "\226\128\162",   -- U+2022 BULLET
    rule      = "\226\128\148",   -- U+2014 EM DASH
    turnMark  = "\194\187",       -- U+00BB
    sep       = "\194\166",       -- U+00A6 BROKEN BAR
    leader    = "\194\183",       -- U+00B7 MIDDLE DOT

    -- Faces the panel's font library exposes (Libs/UI/fontconfig.xml).
    faceTitle = "DisplayFont",    -- Kingdom Come Display
    faceHand  = "Manuscript",     -- Warhorse Manuscript, a real blackletter hand
    faceBody  = "LightFont",

    -- Transient announcements that suit a line rather than the board.
    -- hud.ShowInfoText is confirmed rendering. hud.ShowDiceScore is confirmed
    -- INERT outside the native minigame, so it is not used at all.
    native    = { modal = false, infotext = true, sting = false },

    -- WO-33: groschen staked on the NEXT invite this client sends, set via
    -- mp_dice_wager. Purely local until it rides the Invite config -- the
    -- relay never computes or holds it, only echoes it back on DiceEnd so
    -- each client can apply it to its own Inventory. 0 = no stake.
    wagerAmount = 0,

    -- --- authoritative state, straight off the wire -------------------------
    role      = 0,             -- OUR SessionRole: 0 initiator, 1 acceptor
    turnRole  = 0,             -- whose turn it is
    target    = 4000,
    phase     = 0,             -- DicePhase: 0 AwaitingRoll, 1 AwaitingKeep
    scores    = { [0] = 0, [1] = 0 },
    turnTotal = 0,
    free      = {},            -- faces still on the board
    kept      = {},            -- faces set aside this turn
    peer      = "opponent",

    -- --- local, non-authoritative -------------------------------------------
    sel       = {},            -- which free dice the player has marked
    hold      = nil,           -- {action, t0} for hold-to-confirm
    outcome   = nil,           -- nil | "win" | "lose"
    err       = nil,           -- {text} from a DiceError
}

local D = KCD2MP.dice

-- Palette, as HTML colours against the panel's parchment. Pulled to KCD2's own
-- register: iron-gall ink, faded ink, candle gold, dried blood.
local COL = {
    ink   = "#2a2018",
    dim   = "#7a6a4f",
    gold  = "#c8a13c",
    -- Was #e8c25c -- too close to the parchment's own lightness to read at a
    -- glance (the live turn total, selected-die marks). Darkened for contrast;
    -- still reads as gold, just no longer washes out against the paper.
    bright= "#96691a",
    blood = "#8a1f14",
    -- Close to the parchment itself -- an "unlit" pip slot. First guess, not
    -- colour-picked from the real texture (no tooling for that); confirm
    -- against a live screenshot and adjust if it reads as too visible or too
    -- invisible.
    faint = "#c9b98f",
}

-- ===== html helpers =========================================================

local NBSP = "&nbsp;"

local function fnt(s, colour, size, face)
    local a = ""
    if face   then a = a .. " face='" .. face .. "'" end
    if size   then a = a .. " size='" .. tostring(size) .. "'" end
    if colour then a = a .. " color='" .. colour .. "'" end
    return "<font" .. a .. ">" .. s .. "</font>"
end

local function rep(s, n)
    local out = ""
    for _ = 1, (n or 0) do out = out .. s end
    return out
end

-- "2 500" -- thousands separated the way a tally board would.
local function groschen(n)
    local s = tostring(math.floor(tonumber(n) or 0))
    local out, c = "", 0
    for i = #s, 1, -1 do
        out = s:sub(i, i) .. out
        c = c + 1
        if c % 3 == 0 and i > 1 then out = NBSP .. out end
    end
    return out
end

-- 9, not 13: at 13 the rule wrapped onto a second line and the board grew a
-- row of orphaned dashes after every divider. The panel is narrower than it
-- looks, and its font is proportional, so this is measured against the real
-- thing rather than calculated.
local function ruleLine()
    return fnt(rep(D.rule, 9), COL.dim)
end

-- A name/score row with leader dots between. The panel's font is PROPORTIONAL
-- (verified: "1234567890" and "ABCDEFGHIJ" end at different widths), so the
-- dots cannot align a column exactly -- but leaders are precisely the device
-- that makes an approximate right edge read as intentional.
-- `score` is a NUMBER here, not pre-formatted markup. It used to take the
-- groschen() output and size the leaders with #score -- but that string contains
-- "&nbsp;" entities, so a 4-digit score counted as 10+ characters and the
-- leaders collapsed to the minimum on every row.
local function tallyRow(mark, name, score, colour)
    local digits = #tostring(math.floor(tonumber(score) or 0))
    local budget = 20 - #name - digits
    if budget < 2 then budget = 2 end
    return fnt(mark .. " " .. name .. " " .. rep(D.leader, budget)
               .. " " .. groschen(score), colour)
end

-- ===== dice =================================================================

-- Which of the 3x3 cells carry a pip, per face. Built from BULLET and
-- non-breaking space only: every row of every die uses the same two characters
-- in the same slots, which is what makes the grid line up vertically despite
-- the proportional font (verified in game with a 5 and a 2 side by side).
--
-- NOT the Unicode die faces U+2680..2685 -- those are tofu in this font, as are
-- all box-drawing and geometric shapes. Bullet is what survives.
local PIPCELLS = {
    [1] = { {0,0,0}, {0,1,0}, {0,0,0} },
    [2] = { {1,0,0}, {0,0,0}, {0,0,1} },
    [3] = { {1,0,0}, {0,1,0}, {0,0,1} },
    [4] = { {1,0,1}, {0,0,0}, {1,0,1} },
    [5] = { {1,0,1}, {0,1,0}, {1,0,1} },
    [6] = { {1,0,1}, {1,0,1}, {1,0,1} },
}

-- Three lines of HTML rendering a row of dice side by side.
-- faces: array of 1..6. colours: parallel array of hex, or nil for ink.
--
-- Every cell renders D.pip -- never NBSP. An "unlit" cell is a bullet coloured
-- COL.faint instead of blank space, so every die's row is always exactly three
-- BULLET glyphs wide, whatever the face. Blank space (NBSP) does not render at
-- the same width as a bullet in this proportional font, so a die's rendered
-- width used to depend on how many pips it had (a 1 much narrower than a 6),
-- which is what made the index row drift out from under its die -- no fixed
-- gap can compensate for a per-die width that keeps changing.
--
-- A thin divider (D.sep, the broken bar already proven renderable in the
-- action strip) between dice reads as an actual boundary between two dice,
-- rather than blank space that six 2-character F-key labels (F2..F8) no
-- longer had room for anyway -- fixed a line-wrap the wide all-NBSP gap
-- caused once labels stopped being a single digit.
local GAP = NBSP .. D.sep .. NBSP

local function diceRows(faces, colours)
    local out = { "", "", "" }
    for r = 1, 3 do
        for i, f in ipairs(faces) do
            local cells = PIPCELLS[f] or PIPCELLS[1]
            local dieColour = (colours and colours[i]) or COL.ink
            local s = ""
            for c = 1, 3 do
                local lit = cells[r][c] == 1
                s = s .. fnt(D.pip, lit and dieColour or COL.faint)
            end
            out[r] = out[r] .. s
            if i < #faces then out[r] = out[r] .. GAP end
        end
    end
    return out
end

-- A row under the dice naming the key that marks each one, so the player never
-- has to remember an arbitrary mapping. Shows the real key rather than a plain
-- 1..6 die index now that marking has real keybinds (WO-6) -- the mapping is
-- F2, F4-F8 (F3/F1/F10 are engine debug toggles, skipped), not a clean range,
-- so spelling it out here matters more than it used to. mp_dice_mark still
-- takes the die's POSITION (1-6, left to right), for the console fallback.
--
-- sel (optional) marks a die as selected: its label goes in brackets and gold,
-- matching the gold pips diceRows already gives a selected die above it. No
-- circle/X glyph is used -- the capability doc's verified-renderable set has
-- none (every geometric shape tried came back tofu) -- but '[' ']' are proven
-- safe, they are already used by the action-strip key() labels below.
local DICE_MARK_KEYS = { "F2", "F4", "F5", "F6", "F7", "F8" }

local function indexRow(n, sel)
    local s = ""
    for i = 1, n do
        local marked = sel and sel[i]
        local keyLabel = DICE_MARK_KEYS[i] or tostring(i)
        local label = marked and ("[" .. keyLabel .. "]") or (NBSP .. keyLabel .. NBSP)
        s = s .. fnt(label, marked and COL.bright or COL.dim, 12)
        if i < n then s = s .. GAP end
    end
    return s
end

-- Sizes trimmed from 18/14 -- this panel stacks a lot of rows (title, tally,
-- three pip rows, index row, set-aside, hand total, rules, action strip) and
-- the line spacing scales with font size, so shaving a couple of points off
-- the busiest block buys back real vertical room.
local function diceBlock(faces, colours, numbered, sel)
    if #faces == 0 then
        return fnt(NBSP .. D.leader .. " none " .. D.leader, COL.dim, 16)
    end
    local r = diceRows(faces, colours)
    local h = fnt(r[1] .. "<br/>" .. r[2] .. "<br/>" .. r[3], nil, 15)
    if numbered then h = h .. "<br/>" .. indexRow(#faces, sel) end
    return h
end

-- ===== the board ============================================================

local function buildHtml()
    local mine   = (D.turnRole == D.role) and (D.outcome == nil)
    local myCol  = mine and COL.gold or COL.ink
    local opCol  = (not mine and D.outcome == nil) and COL.gold or COL.ink

    local title = "The Wager"
    if D.outcome == "win"  then title = "Thine!" end
    if D.outcome == "lose" then title = D.peer .. " takes it" end

    local h = fnt(title, (D.outcome == "win") and COL.bright or COL.gold, 26, D.faceTitle)
              .. "<br/>" .. ruleLine() .. "<br/>"

    -- score slip: opponent above, us below, target underneath
    h = h .. tallyRow(mine and NBSP or D.turnMark, D.peer, D.scores[1 - D.role], opCol) .. "<br/>"
    h = h .. tallyRow(mine and D.turnMark or NBSP, "Thou",  D.scores[D.role],     myCol) .. "<br/>"
    h = h .. "<p align='right'>" .. fnt("of " .. groschen(D.target), COL.dim, 16) .. "</p>"

    if D.outcome then
        h = h .. ruleLine() .. "<br/>"
        h = h .. fnt("The wager is settled.", COL.dim, 18) .. "<br/>"
        h = h .. fnt("mp_dice_close", COL.dim, 16)
        return h
    end

    h = h .. ruleLine() .. "<br/>"

    -- the board: free dice, marked ones in bright gold so a pending keep is
    -- obviously reversible before it is sent. No tumble/reveal animation --
    -- a fresh roll just appears with its real faces, per the human's own call
    -- once the panel replaced DrawText: nothing fancy needed for a reroll.
    local faces, cols = {}, {}
    for i, f in ipairs(D.free) do
        faces[i] = f
        cols[i]  = D.sel[i] and COL.bright or COL.ink
    end
    h = h .. fnt("On the board", COL.dim, 16) .. "<br/>"
    h = h .. diceBlock(faces, cols, true, D.sel) .. "<br/>"

    -- set aside, in gold: these are locked in and scoring. Not numbered --
    -- there is no command that takes a set-aside die's index, so numbering them
    -- would only invite a keystroke that does nothing.
    local kf, kc = {}, {}
    for i, f in ipairs(D.kept) do kf[i] = f; kc[i] = COL.gold end
    h = h .. fnt("Set aside", COL.dim, 16) .. "<br/>"
    h = h .. diceBlock(kf, kc, false) .. "<br/>"

    h = h .. fnt("This hand ", COL.dim, 18)
          .. fnt(groschen(D.turnTotal), (D.turnTotal > 0) and COL.bright or COL.dim, 20) .. "<br/>"
    h = h .. ruleLine() .. "<br/>"

    -- The action strip shows REAL keys. It briefly listed console commands
    -- instead, because the keybinds at that point were unverified guesses and
    -- advertising dead keys reads as broken. The names behind these were
    -- captured from a live game (see DICE_CONFIRM_ACTIONS), so they can be
    -- shown honestly now. The mp_dice_* commands still work and are the
    -- fallback if a key is rebound.
    if D.err then
        h = h .. fnt(D.err.text, COL.blood, 18) .. "<br/>"
    end

    local function key(k, label, hot)
        return fnt("[" .. k .. "] ", hot and COL.gold or COL.dim, 16)
            .. fnt(label, hot and COL.ink or COL.dim, 16)
    end

    if mine then
        if D.phase == 1 then
            h = h .. fnt("key below", COL.gold, 16) .. fnt(" to mark, then ", COL.dim, 16)
                  .. key("F9", "set aside", true) .. "<br/>"
            h = h .. key("U", "clear marks", false) .. "<br/>"
        else
            h = h .. key("F9", "cast", true) .. "<br/>"
        end
        h = h .. key("hold F11", "bank", true) .. fnt("  " .. D.sep .. "  ", COL.dim, 16)
              .. key("hold F12", "yield", false)
    else
        h = h .. fnt(D.peer .. " is casting" .. D.leader .. D.leader .. D.leader, COL.dim, 18)
    end

    return h
end

-- ===== pushing it ===========================================================

-- ShowTutorial is a NOTIFICATION QUEUE, not a panel you can update in place.
-- Two rounds of learning here, both from watching the real thing:
--
--   1. Pushing an update without hiding leaves it waiting BEHIND the current
--      entry, so the board silently stops tracking the match.
--   2. HideTutorial(id) only dismisses the entry being DISPLAYED -- it advances
--      the queue rather than clearing it. Sixteen pushes across one demo match
--      therefore left sixteen queued entries, each asking for a long duration,
--      and the game cycled through them: fade out, fade in, next. On screen that
--      reads as the board flickering and looping forever, long after the match
--      has ended.
--
-- So every push flushes the WHOLE queue first. HideAllTutorials is a blunt
-- instrument -- it will also drop a genuine game tutorial that happens to be
-- showing -- which is accepted only because this runs solely during a PvP dice
-- match the player deliberately started.
--
-- panelMs is a safety net, not the intended lifetime: if this code ever stops
-- refreshing (agent dies, script error), the board expires by itself instead of
-- sitting on screen forever.
-- MEASURED, not assumed: a demo match pushes the panel 24 times in 30 seconds,
-- roughly one every 1.25 s. Each push is HideAllTutorials + ShowTutorial and the
-- panel replays its full fade-out/fade-in every time. That is the "flickering
-- horribly" -- not a loop, and not something queue management can fix.
--
-- ShowTutorial is a NOTIFICATION CARD. There is no in-place text update, so
-- rapid repeated pushes flicker -- but not EVERY push is rapid. A relay-driven
-- DiceState (a roll/keep/bank result) is naturally paced by however long a
-- turn takes; the thing that actually flickered was pushing once per LOCAL
-- mark press too, which can happen several times a second while choosing a
-- keep. So the fix is not "never push the panel", it's "don't push once per
-- keystroke": KCD2MP_DiceRender still pushes immediately for state that's
-- already paced (open, DiceState, DiceError, end); scheduleRender below is
-- what marking uses instead, coalescing a burst of presses into one push.
function KCD2MP_DiceRender()
    if not D.open then return end
    if not D.usePanel then return end
    local ok, html = pcall(buildHtml)
    if not ok then
        mp_log("DICE render error: " .. tostring(html))
        return
    end
    KCD2MP_DiceFlush()
    pcall(function()
        UIAction.CallFunction("hud", -1, "ShowTutorial",
            D.panelId, html, D.panelMs, false, 9, 0, false, "")
    end)
end

-- Coalesces bursty local input (marking dice) into one push instead of one
-- per press. Leading-edge: the first call after a quiet period schedules a
-- render renderDebounceMs later; any calls that land inside that window are
-- no-ops, because by the time the scheduled render actually runs it reads
-- whatever D.sel etc. looks like THEN -- which already includes them, since
-- Lua here is single-threaded and D.sel was mutated synchronously by the
-- caller before scheduleRender was ever called.
local renderScheduled = false
local function scheduleRender()
    if renderScheduled then return end
    renderScheduled = true
    Script.SetTimer(D.renderDebounceMs or 250, function()
        renderScheduled = false
        KCD2MP_DiceRender()
    end)
end

-- Drops every queued and displayed tutorial. Also exposed as mp_dice_flush, so
-- a stuck or flickering panel is always one command away from being cleared.
function KCD2MP_DiceFlush()
    pcall(function() UIAction.CallFunction("hud", -1, "HideAllTutorials") end)
    pcall(function() UIAction.CallFunction("hud", -1, "HideCurrentTutorial") end)
    pcall(function() UIAction.CallFunction("hud", -1, "HideTutorial", D.panelId) end)
end

local function say(text)
    if not D.native.infotext then return end
    pcall(function()
        UIAction.CallFunction("hud", -1, "ShowInfoText", text, 10, 2200, true)
    end)
end
KCD2MP_DiceSay = say

-- Hold-to-confirm needs a light tick, and only while a key is actually held.
local function holdTick()
    if not D.hold then return end
    Script.SetTimer(100, holdTick)
    KCD2MP_DiceHoldTick()
end
KCD2MP_DiceHoldPump = holdTick

-- ===== inbound: called by the agent =========================================

-- Opens the board. role is OUR SessionRole (0 initiator, 1 acceptor).
function KCD2MP_DiceOpen(role, peer, target)
    D.role      = tonumber(role) or 0
    D.peer      = tostring(peer or "opponent")
    D.target    = tonumber(target) or 4000
    D.scores    = { [0] = 0, [1] = 0 }
    D.turnTotal = 0
    D.free, D.kept, D.sel = {}, {}, {}
    D.outcome, D.err, D.hold = nil, nil, nil
    D.open = true
    KCD2MP_DiceRender()      -- the parchment card announcing the match
    mp_log("DICE overlay open vs " .. D.peer .. " to " .. tostring(D.target))
end

function KCD2MP_DiceClose()
    D.open, D.hold = false, nil
    -- Flush rather than hide one entry: anything still queued would otherwise
    -- keep surfacing after the match is over. Runs even if the board was already
    -- closed, so mp_dice_close doubles as "clear whatever is stuck on screen".
    KCD2MP_DiceFlush()
    mp_log("DICE overlay closed")
end

-- A full authoritative snapshot. freeCsv/keptCsv/bustedCsv are comma-separated
-- faces ("3,1,5,6"); empty string means none. Never a delta -- the relay
-- always sends the whole board, so this can replace state wholesale without
-- reconciling. bustedCsv is the roll that just busted (added after WO-5
-- shipped): FreeDice is already cleared by the time a bust reaches the wire,
-- so this is the only place the actual rolled faces ever appear.
function KCD2MP_DiceState(turnRole, s0, s1, turnTotal, target, phase, freeCsv, keptCsv, bustedCsv)
    local function parse(csv)
        local t = {}
        for m in tostring(csv or ""):gmatch("[^,]+") do
            local n = tonumber(m)
            if n then t[#t + 1] = n end
        end
        return t
    end

    -- A snapshot arriving with no board open means the agent connected mid-
    -- session, or SessionStarted was missed. Open FIRST -- KCD2MP_DiceOpen
    -- clears scores, dice and animation state, so opening after applying the
    -- snapshot would wipe the very state this call is delivering.
    if not D.open then KCD2MP_DiceOpen(D.role, D.peer, tonumber(target) or D.target) end

    local prevTurn = D.turnRole

    D.turnRole  = tonumber(turnRole) or 0
    D.scores[0] = tonumber(s0) or 0
    D.scores[1] = tonumber(s1) or 0
    D.turnTotal = tonumber(turnTotal) or 0
    D.target    = tonumber(target) or D.target
    D.phase     = tonumber(phase) or 0
    D.free      = parse(freeCsv)
    D.kept      = parse(keptCsv)
    D.sel       = {}          -- a new snapshot always clears a pending mark

    local bustedFaces = parse(bustedCsv)

    if D.turnRole ~= prevTurn then
        local mine = (D.turnRole == D.role)

        -- Used to be inferred from whether the score moved -- the relay did
        -- not label its snapshots at all. Now it does (bustedFaces), so this
        -- reads real state instead of guessing from a side effect of it.
        local busted = #bustedFaces > 0

        -- The turn hand-off and the bust are the two moments that want to
        -- punch, and a line across the middle of the screen punches harder
        -- than a change inside the panel. This is what ShowInfoText is for.
        if busted then
            local rolled = table.concat(bustedFaces, ", ")
            say((prevTurn == D.role) and ("Bust! Rolled " .. rolled .. " -- nothing scored.")
                                      or (D.peer .. " busts on " .. rolled .. "."))
        else
            say(mine and "Thy cast." or (D.peer .. " casts."))
        end
    end

    D.err = nil

    -- Immediate, not debounced: this is a relay-confirmed result, already
    -- paced by however long the turn took -- it is local rapid-fire input
    -- (marking) that needs coalescing, not this.
    KCD2MP_DiceRender()
end

-- The relay rejected an intent. State did not change; the board says why.
function KCD2MP_DiceError(reason)
    D.err = { text = tostring(reason or "not allowed") }
    KCD2MP_DiceRender()
end

-- outcome: "win" or "lose". wager (WO-33) is the agreed groschen stake,
-- echoed by the relay on the wire DiceEnd packet itself -- see Protocol.cs.
-- Applied here, once, to THIS client's own Inventory only: winner gains,
-- loser loses, never a write into the peer's save. This function is reached
-- only for a match that ran to a clean conclusion -- a mid-match disconnect
-- fires KCD2MP_DiceClose via SessionEnded instead (GameBridge.cs), never
-- this, so a dropped connection can never move money on either side.
function KCD2MP_DiceEnd(outcome, s0, s1, wager)
    D.scores[0] = tonumber(s0) or D.scores[0]
    D.scores[1] = tonumber(s1) or D.scores[1]
    D.outcome   = tostring(outcome or "lose")
    D.sel, D.hold, D.err = {}, nil, nil

    -- Live-checked this session (WO-33): the "Inventory" scriptbind the
    -- vendor docs describe as a global table does not exist in this sandbox
    -- at all. What IS real: player.inventory:GetMoney()/RemoveMoney(n) are
    -- genuine entity-scoped methods, confirmed with a controlled before/after
    -- read (7.9 -> 5.9 groschen for RemoveMoney(2)). There is no AddMoney
    -- anywhere reachable, on this object or via RTTR reflection. The win
    -- side instead uses ItemUtils.AddMoneyToInventory(who, amount), a real
    -- function the shipped game's own Scripts/Utils/ItemUtils.lua defines --
    -- money is a stackable item (guid 5ef63059-...) under the hood, and this
    -- is Warhorse's own sanctioned way to hand someone more of it, built on
    -- ItemManager.CreateItem + entity.inventory:AddItem, both independently
    -- proven elsewhere in this project (docs/kcd2_lua_api.md).
    wager = tonumber(wager) or 0
    if wager > 0 then
        local ok, err
        if D.outcome == "win" then
            ok, err = pcall(function() ItemUtils.AddMoneyToInventory(player, wager) end)
        else
            ok, err = pcall(function() player.inventory:RemoveMoney(wager) end)
        end
        mp_log("DICE wager " .. wager .. " " .. (D.outcome == "win" and "added" or "removed")
            .. " ok=" .. tostring(ok) .. " err=" .. tostring(err))
    end

    say((D.outcome == "win") and ("The wager is thine." .. (wager > 0 and (" +" .. wager .. " groschen.") or ""))
                              or (D.peer .. " takes the pot." .. (wager > 0 and (" -" .. wager .. " groschen.") or "")))
    KCD2MP_DiceRender()
    mp_log("DICE match ended: " .. D.outcome .. " wager=" .. wager)
end

-- ===== demo: review the board without a second player =======================
--
-- One machine, one copy of the game and no second human is the standing
-- constraint on this project, so the visuals would otherwise be unreviewable
-- until a second PC exists. This drives the board through a scripted match with
-- fabricated snapshots -- every moment the design specifies, in order, so the
-- look and the motion can actually be judged.
--
-- It calls the SAME entry points the agent calls and fabricates nothing the
-- relay would not send. It is a view of the presentation layer only: it sends
-- no intents, touches no session, and cannot affect a real match.
--
--   mp_dice_demo

local DEMO = {
    -- {delay after previous step (s), what to do}
    {0.0, function() KCD2MP_DiceOpen(0, "Dicer Filip", 2500) end},
    {0.8, function() KCD2MP_DiceState(0, 0,    0,   0, 2500, 0, "",            "") end},
    {1.2, function() KCD2MP_DiceState(0, 0,    0,   0, 2500, 1, "1,5,3,6,2,4", "") end},
    {2.2, function() KCD2MP_DiceState(0, 0,    0, 100, 2500, 0, "5,3,6,2,4",   "1") end},
    {1.6, function() KCD2MP_DiceState(0, 0,    0, 100, 2500, 1, "2,5,4,1,6",   "1") end},
    {1.8, function() KCD2MP_DiceState(0, 0,    0, 250, 2500, 0, "2,4,6",       "1,5,1") end},
    {1.6, function() KCD2MP_DiceState(0, 0,    0, 250, 2500, 1, "3,3,2",       "1,5,1") end},
    -- bust: turn passes and our banked score did NOT move. bustedCsv fabricates
    -- what the roll was -- 2,3,4,6 has no 1, no 5 and no triple, a real bust.
    {2.0, function() KCD2MP_DiceState(1, 0,    0,   0, 2500, 0, "",            "", "2,3,4,6") end},
    {2.4, function() KCD2MP_DiceState(1, 0,    0, 450, 2500, 1, "4,4,4,2",     "5,5") end},
    -- opponent banks: their score moves, so no bust sting
    {2.0, function() KCD2MP_DiceState(0, 0,  450,   0, 2500, 0, "",            "") end},
    {2.0, function() KCD2MP_DiceState(0, 0,  450,   0, 2500, 1, "1,1,1,4,2,6", "") end},
    {2.2, function() KCD2MP_DiceState(0, 0,  450,1000, 2500, 0, "4,2,6",       "1,1,1") end},
    -- a rejected intent
    {1.6, function() KCD2MP_DiceError("those dice score nothing") end},
    -- and a win
    {2.6, function() KCD2MP_DiceState(0, 2550, 450, 0, 2500, 0, "", "") end},
    {0.4, function() KCD2MP_DiceEnd("win", 2550, 450) end},
    {6.0, function() KCD2MP_DiceClose() end},
}

KCD2MP._demoStep = 0

local function demoTick()
    KCD2MP._demoStep = KCD2MP._demoStep + 1
    local s = DEMO[KCD2MP._demoStep]
    if not s then return end
    pcall(s[2])
    local nxt = DEMO[KCD2MP._demoStep + 1]
    if nxt then Script.SetTimer(math.floor(nxt[1] * 1000), demoTick) end
end

function KCD2MP_DiceDemo()
    KCD2MP._demoStep = 0
    mp_log("DICE demo: scripted match, ~30s")
    demoTick()
    return true
end

-- ===== outbound: player intents =============================================
--
-- Every one of these only EMITS. The relay decides whether it was legal, and
-- the answer arrives as the next snapshot or as a DiceError.

-- anyTime: forfeit is legal whenever the match is live -- conceding only on
-- your own turn would mean being unable to walk away from an opponent who has
-- stopped playing.
local function intent(s, anyTime)
    if not D.open then
        KCD2MP_ShowInteractionMsg("No dice match")
        return false
    end
    if D.outcome then return false end
    if not anyTime and D.turnRole ~= D.role then
        D.err = { text = "not thy turn", t0 = os.clock() }
        return false
    end
    KCD2MP_EmitEvent("dice_intent", s)
    return true
end

-- Marks or unmarks a die for the next Keep. Local only, freely reversible --
-- nothing leaves the machine until the player confirms.
function KCD2MP_DiceMark(i)
    i = tonumber(i)
    if not D.open or not i or not D.free[i] then return false end
    if D.turnRole ~= D.role then
        D.err = { text = "not thy turn" }
        scheduleRender()
        return false
    end
    if D.sel[i] then D.sel[i] = nil else D.sel[i] = true end
    D.err = nil
    -- Debounced, not immediate: marking can fire several times a second while
    -- choosing a keep, and pushing the panel once per press is the flicker
    -- this design already fixed once.
    scheduleRender()
    return true
end

-- Clears every pending mark without touching the roll itself, so a player who
-- marked, say, two 5s and then noticed a third can start over on the SAME
-- free dice instead of committing a suboptimal keep. Purely local, like
-- marking itself -- nothing is sent to the relay until KCD2MP_DiceConfirm.
function KCD2MP_DiceUnmarkAll()
    if not D.open or D.phase ~= 1 then return false end
    D.sel = {}
    D.err = nil
    scheduleRender()
    return true
end

-- The primary action, and it does double duty by phase: cast when the relay is
-- waiting for a roll, set aside the marked dice when it is waiting for a keep.
function KCD2MP_DiceConfirm()
    if not D.open then return false end
    if D.phase == 1 then
        local mask = 0
        for i = 1, 6 do if D.sel[i] then mask = mask + 2 ^ (i - 1) end end
        if mask == 0 then
            D.err = { text = "mark thy dice first" }
            KCD2MP_DiceRender()
            return false
        end
        return intent("keep " .. tostring(math.floor(mask)))
    end
    return intent("roll")
end

function KCD2MP_DiceBank()    return intent("bank")          end
function KCD2MP_DiceForfeit() return intent("forfeit", true) end

-- Hold-to-confirm. Bank and forfeit are irreversible, so they are deliberately
-- not on a single press: begin on key-down, fire only if the key survives long
-- enough, cancel on key-up. Pumped by its own short-lived timer, which only
-- runs while a key is actually down.
function KCD2MP_DiceHoldBegin(action)
    if not D.open or D.outcome then return end
    if D.hold then return end
    D.hold = { action = action, t0 = os.clock() }
    KCD2MP_DiceHoldPump()
end

function KCD2MP_DiceHoldEnd()
    D.hold = nil
end

function KCD2MP_DiceHoldTick()
    if not D.hold then return end
    local need = (D.hold.action == "forfeit") and 1.2 or 0.6
    if os.clock() - D.hold.t0 >= need then
        local a = D.hold.action
        D.hold = nil
        if a == "forfeit" then KCD2MP_DiceForfeit() else KCD2MP_DiceBank() end
    end
end

-- ===== dice tables (WO-6 C1) ================================================
--
-- Real tables only -- this mod's dice UI must never appear anywhere a player
-- happens to be standing.
--
-- "DiceInteractor" is not a guess. Scripts.pak ships Entities/DiceInteractor.ent
-- registering that class against Scripts/Entities/WH/Minigames/DiceInteractor.lua,
-- the script that puts the "@ui_hud_play_dice" action on a dice board
-- (objects/manmade/task_specific_props/entertainment/games/dice/dice_board.cgf).
--
-- UNVERIFIED until Probe-Visual.ps1's `dicetable` block is run at a real tavern
-- table: whether world-placed tables are actually instances of this class.
-- If they are not, set KCD2MP.dice.tableClass = nil to fall back to a plain
-- proximity check between the two players -- honest, flagged, and not the
-- default.
-- WO-6 revision: the strict "must be at a DiceInteractor" gate is correct for
-- shipping but hostile to testing, because every dice table in the world is
-- already occupied by an NPC and we cannot drive the native minigame anyway.
-- So the gate is now a list of accepted classes plus a switch.
--
--   requireTable = false  -- test mode, invite anywhere (DEFAULT for now)
--   requireTable = true   -- shipping behaviour, must be at an accepted table
--
-- `mp_dice_gate on|off` flips it live, and `mp_dice_scan` lists the entity
-- classes actually around the player so a generic table's real class name can be
-- ADDED to tableClasses from evidence rather than guessed at.
KCD2MP.dice.tableClasses = { "DiceInteractor" }
KCD2MP.dice.tableClass   = "DiceInteractor"   -- kept: first entry, back-compat
KCD2MP.dice.tableRadius  = 4.0
KCD2MP.dice.requireTable = false

-- Returns entity, distance -- or nil plus a reason. Searches every class in
-- KCD2MP.dice.tableClasses and returns the nearest hit across all of them.
function KCD2MP_NearestDiceTable(radius)
    radius = tonumber(radius) or KCD2MP.dice.tableRadius
    local classes = KCD2MP.dice.tableClasses
    if not classes or #classes == 0 then return nil, "table detection disabled" end
    local ppos = player and player:GetWorldPos()
    if not ppos then return nil, "no player position" end

    local best, bestD = nil, nil
    for _, cls in ipairs(classes) do
        local ok, list = pcall(System.GetEntitiesInSphereByClass, ppos, radius, cls)
        if ok and list then
            for _, e in ipairs(list) do
                local ok2, ep = pcall(function() return e:GetWorldPos() end)
                if ok2 and ep then
                    local d = math.sqrt((ep.x - ppos.x) ^ 2 + (ep.y - ppos.y) ^ 2 + (ep.z - ppos.z) ^ 2)
                    if not bestD or d < bestD then best, bestD = e, d end
                end
            end
        end
    end
    if not best then return nil, "no table within " .. tostring(radius) .. "m" end
    return best, bestD
end

-- Lists every entity near the player with its class, so a generic table's real
-- class name can be read off the log and ADDED to tableClasses. Evidence, not a
-- guess -- the same discipline that produced DiceInteractor in the first place.
function KCD2MP_ScanTables(radiusStr)
    local radius = tonumber(tostring(radiusStr or ""):match("%d+%.?%d*") or "") or 6.0
    local ppos = player and player:GetWorldPos()
    if not ppos then mp_log("SCAN: no player position"); return false end
    local ok, list = pcall(System.GetEntitiesInSphere, ppos, radius)
    if not ok or not list then mp_log("SCAN: query failed"); return false end
    mp_log(string.format("SCAN: %d entities within %.1fm", #list, radius))
    local seen = {}
    for _, e in ipairs(list) do
        local ok2 = pcall(function()
            local cls = e.class or "?"
            local nm  = tostring(e:GetName())
            local ep  = e:GetWorldPos()
            local d   = math.sqrt((ep.x-ppos.x)^2 + (ep.y-ppos.y)^2 + (ep.z-ppos.z)^2)
            -- one line per entity, but collapse identical classes past the third
            seen[cls] = (seen[cls] or 0) + 1
            if seen[cls] <= 3 then
                mp_log(string.format("SCAN  %-22s %-34s %.1fm", tostring(cls), nm, d))
            end
        end)
    end
    return true
end

-- ===== seats at ordinary tables (WO-6 revision) =============================
--
-- Found by scanning entity classes around a real seated player, not guessed.
-- Every tavern seat carries three linked entities, all within ~1.5 m:
--
--   ActionTrigger      sitActionTrigger[Table/table_oneSides_tavern1:...:Bench/...]
--   StanceSmartObject  smartObject2[Table/table_oneSides_tavern1:...:Bench/...]
--   SmartObjectHolder  smartObject[Table/table_oneSides_tavern1_<guid>]
--
-- sitActionTrigger is the useful one. It exists only at a seat attached to a
-- table, its position is a stable anchor to teleport the other player to, and
-- its NAME encodes the table -- so two players can be checked for being at the
-- SAME table rather than merely both sitting somewhere.
--
-- Note this detects "at a seat", not "currently seated": player:GetStance() is
-- not available in this build (returned nil when probed), so there is no direct
-- read of the sitting state. Proximity to the trigger is the proxy, and it is
-- honest to call it that.
KCD2MP.dice.seatRadius = 1.6

-- Pulls "Table/table_oneSides_tavern1" out of a sitActionTrigger's name, so the
-- same table can be recognised from either player's seat.
function KCD2MP_TableIdFromName(name)
    if not name then return nil end
    return (tostring(name):match("%[(Table[/%.][%w_]+)"))
end

-- Returns entity, distance, tableId -- or nil plus a reason.
function KCD2MP_NearestSeat(radius)
    radius = tonumber(radius) or KCD2MP.dice.seatRadius
    local ppos = player and player:GetWorldPos()
    if not ppos then return nil, "no player position" end
    local ok, list = pcall(System.GetEntitiesInSphereByClass, ppos, radius, "ActionTrigger")
    if not ok or not list then return nil, "entity query failed" end

    local best, bestD, bestName = nil, nil, nil
    for _, e in ipairs(list) do
        local ok2, nm = pcall(function() return tostring(e:GetName()) end)
        if ok2 and nm and nm:find("^sitActionTrigger") then
            local ok3, ep = pcall(function() return e:GetWorldPos() end)
            if ok3 and ep then
                local d = math.sqrt((ep.x-ppos.x)^2 + (ep.y-ppos.y)^2 + (ep.z-ppos.z)^2)
                if not bestD or d < bestD then best, bestD, bestName = e, d, nm end
            end
        end
    end
    if not best then return nil, "no seat within " .. tostring(radius) .. "m" end
    return best, bestD, KCD2MP_TableIdFromName(bestName)
end

function KCD2MP_IsAtSeat(radius)
    return (KCD2MP_NearestSeat(radius)) ~= nil
end

-- Reports the seat under the player: distance, table id, and the anchor position
-- the other player would be teleported to.
function KCD2MP_ReportSeat()
    local e, d, tid = KCD2MP_NearestSeat(6.0)
    if not e then
        mp_log("SEAT: none within 6m (" .. tostring(d) .. ")")
        KCD2MP_ShowInteractionMsg("No seat nearby")
        return false
    end
    local p = e:GetWorldPos()
    mp_log(string.format("SEAT: %.2fm table=%s anchor=%.2f,%.2f,%.2f",
        d, tostring(tid), p.x, p.y, p.z))
    KCD2MP_ShowInteractionMsg(string.format("Seat %.1fm  %s", d, tostring(tid)))
    return true
end

-- Flip the shipping gate on or off without a rebuild.
function KCD2MP_DiceGate(arg)
    local s = tostring(arg or ""):lower()
    if s:find("on") then KCD2MP.dice.requireTable = true
    elseif s:find("off") then KCD2MP.dice.requireTable = false end
    mp_log("DICE table gate = " .. tostring(KCD2MP.dice.requireTable))
    return true
end

function KCD2MP_IsAtDiceTable(radius)
    local e = KCD2MP_NearestDiceTable(radius)
    return e ~= nil
end

-- Verification helper for the C1 claim above. Run it standing at a real tavern
-- dice table, then again well away from one -- the away run is the negative
-- control that makes the at-table run mean anything.
function KCD2MP_ReportDiceTable()
    local e, d = KCD2MP_NearestDiceTable(25.0)
    if not e then
        mp_log("DICE TABLE: none within 25m (" .. tostring(d) .. ")")
        KCD2MP_ShowInteractionMsg("No dice table within 25m")
        return false
    end
    local ok, nm = pcall(function() return e:GetName() end)
    mp_log(string.format("DICE TABLE: '%s' at %.2fm", ok and tostring(nm) or "?", d))
    KCD2MP_ShowInteractionMsg(string.format("Dice table %.1fm away", d))
    return true
end

-- The gate the dice invite goes through. NPC dice games are untouched by any of
-- this: they never call into KCD2MP, and this only ever emits our own invite
-- event to our own agent.
-- The gate is now "at a seat attached to any table", per the design call that
-- every real dice table is NPC-occupied and the native minigame is unreachable
-- anyway. A dice-specific DiceInteractor still counts, so nothing is lost.
--
-- The seat's table id rides along on the invite: it is what lets the acceptor be
-- placed at the SAME table rather than merely at some table of their own.
-- WO-33: mp_dice_wager <amount>. Purely local -- takes effect on the NEXT
-- mp_dice/F9 invite this client sends, and does nothing to any invite already
-- pending. A negative or unparsable amount is treated as 0 (no wager) rather
-- than faulting; groschen are whole numbers here, so this floors.
function KCD2MP_SetDiceWager(line)
    local n = tonumber(tostring(line or ""):match("%-?%d+")) or 0
    KCD2MP.dice.wagerAmount = math.max(0, math.floor(n))
    KCD2MP_ShowInteractionMsg("Dice wager set to " .. KCD2MP.dice.wagerAmount)
    mp_log("Dice wager set to " .. KCD2MP.dice.wagerAmount)
end

function KCD2MP_InviteDiceAtTable()
    -- WO-33: check our OWN balance before sending, not after the peer accepts.
    -- RemoveMoney at DiceEnd would refuse anyway if this were skipped, but a
    -- match that couldn't have been paid for should never start.
    local wager = KCD2MP.dice.wagerAmount or 0
    if wager > 0 then
        local ok, have = pcall(function() return player.inventory:GetMoney() end)
        if not ok or not have or have < wager then
            KCD2MP_ShowInteractionMsg("Not enough groschen for that wager")
            mp_log("Refusing dice invite: wager " .. tostring(wager) .. " exceeds balance "
                .. tostring(ok and have or "?"))
            return false
        end
    end

    local seat, d, tid = KCD2MP_NearestSeat()
    if not seat and KCD2MP.dice.requireTable then
        -- fall back to a real dice table before refusing
        local e = KCD2MP_NearestDiceTable()
        if not e then
            KCD2MP_ShowInteractionMsg("Sit at a table first (" .. tostring(d) .. ")")
            return false
        end
    end
    if seat then
        local p = seat:GetWorldPos()
        KCD2MP.dice.seat = { tableId = tid, x = p.x, y = p.y, z = p.z }
        mp_log(string.format("DICE invite from seat table=%s anchor=%.2f,%.2f,%.2f",
            tostring(tid), p.x, p.y, p.z))
    else
        KCD2MP.dice.seat = nil
    end
    return KCD2MP_InviteNearest("dice", wager)
end


KCD2MP.modules.dice = true
