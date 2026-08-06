-- KCD2 Multiplayer - Mod Init Script
System.LogAlways("[KCD2-MP] === MOD INIT ===")

KCD2MP = {}
KCD2MP.running = false
KCD2MP.interpRunning = false
KCD2MP.tickCount = 0
KCD2MP.ghosts = {}
KCD2MP.ghostNames = {}          -- id → steam name (received via 0x03 Name packet from server)
KCD2MP.ghostInMenu = {}         -- id → true while that player has a menu open (WO-13, set by agent on 0x1D)
KCD2MP.labelCache = {}          -- id → {x,y,z,size,name}  updated by interp, drawn by render loop
KCD2MP.labelRunning = false
KCD2MP.horseGhosts = {}         -- id → {entity, entityId} horse ghost per player
KCD2MP.workingClass = "AnimObject"
KCD2MP.playerSneaking = false   -- set by OnAction hook when sneak key pressed
KCD2MP.isRiding = false         -- updated each interp tick (player on horse detection)
KCD2MP.logActions = false       -- set true only to discover action names (floods log)

-- WO-17: opt-in, off by default, decided locally per player -- see
-- KCD2MP_EnableAggro. Persists for the session (a plain Lua global survives
-- until the mod restarts); never auto-enabled, never negotiated with a peer.
KCD2MP.aggroEnabled = false

-- ===== Debug Logger =====
-- Messages are queued in KCD2MP.debugLog (max 50).
-- Server polls KCD2MP_PopLog() via evalLua and prints to its console.
KCD2MP.debugLog = {}
local MP_LOG_MAX = 50

local function mp_log(msg)
    local entry = string.format("[%.2f] %s", os.clock(), msg)
    table.insert(KCD2MP.debugLog, entry)
    if #KCD2MP.debugLog > MP_LOG_MAX then
        table.remove(KCD2MP.debugLog, 1)
    end
    System.LogAlways("[KCD2-MP] " .. msg)
end

-- Server calls this via evalLua to dequeue one message at a time
function KCD2MP_PopLog()
    if #KCD2MP.debugLog > 0 then
        return table.remove(KCD2MP.debugLog, 1)
    end
    return ""
end

mp_log("MOD INIT")

-- ===== Math Helpers =====

local function lerpVal(a, b, t)
    return a + (b - a) * t
end

-- Shortest-path angle lerp (radians), handles -pi/pi wrap
local function lerpAngle(a, b, t)
    local diff = b - a
    local twopi = math.pi * 2
    diff = diff - math.floor((diff + math.pi) / twopi) * twopi
    return a + diff * t
end

local function clamp(v, lo, hi)
    if v < lo then return lo elseif v > hi then return hi end
    return v
end

-- ===== Ping Display =====
-- Called by C# every ~2s after Pong. Stored for render loop to draw via DrawLabel.
-- Game.ShowNotification adds unwanted "@" decorators so we use DrawLabel instead.
function KCD2MP_ShowPing(ms)
    KCD2MP.ping = ms
    KCD2MP.pingText = string.format("Ping: %d ms", ms)
end

-- ===== Player Position =====

function KCD2MP_GetPos()
    if player then
        local pos = player:GetWorldPos()
        if pos then
            System.LogAlways(string.format("[KCD2-MP] pos: x=%.1f y=%.1f z=%.1f", pos.x, pos.y, pos.z))
            return pos
        end
    else
        System.LogAlways("[KCD2-MP] player is nil")
    end
    return nil
end

-- ===== Outbound State Emitter (WO-1) =====
-- The game has no push channel, so the agent used to poll: one HTTP call for
-- position plus two more to stuff yaw and mount state through the sv_servername
-- CVar and read it back. Measured at ~128 ms for one full sample, capping the
-- sync loop at 7.8 samples/s.
--
-- System.LogAlways costs ~20 us per line and kcd.log is readable by an external
-- tailer roughly 45 ms later, so the game can simply push instead. This emits
-- one line per tick; KcdMpClient tails the log. Three round trips become zero
-- and the rate becomes whatever this timer runs at.
--
-- Line format, space separated, fixed field count:
--   [KCD2-MP-DATA] v1 <seq> <clock> <x> <y> <z> <rotZ> <flags>
--
--   seq    monotonic, so the tailer can spot drops and reordering
--   clock  os.clock() at emit, so the agent can age the sample
--   flags  bit0 riding, bit1 sneaking
--
-- The version token is first so the parser can reject anything it does not
-- understand rather than misread it. Bump it on any field change.
KCD2MP.emitRunning = false
KCD2MP.emitSeq = 0
KCD2MP.emitIntervalMs = 20

local EMIT_VERSION = "v1"

-- Builds and writes one state line. Returns false when the player is not in a
-- state worth reporting (no world, mid-load).
function KCD2MP_EmitState()
    if not player then return false end

    local pos = nil
    pcall(function() pos = player:GetWorldPos() end)
    if not pos then return false end

    local ang = nil
    pcall(function() ang = player:GetWorldAngles() end)
    local rotZ = ang and ang.z or 0

    local flags = 0
    if KCD2MP.isRiding      then flags = flags + 1 end
    if KCD2MP.playerSneaking then flags = flags + 2 end

    KCD2MP.emitSeq = KCD2MP.emitSeq + 1
    System.LogAlways(string.format("[KCD2-MP-DATA] %s %d %.3f %.3f %.3f %.3f %.4f %d",
        EMIT_VERSION, KCD2MP.emitSeq, os.clock(), pos.x, pos.y, pos.z, rotZ, flags))
    return true
end

-- Every *Running flag in this file means "we intended this loop to run", NOT
-- "this loop is running". A save load destroys every pending Script.SetTimer
-- while leaving the globals set, so the flag stays true over a dead chain --
-- and because the Start* functions below early-return on the flag, nothing
-- could ever restart it. Observed live (WO-13): after a save load,
-- emitRunning and interpRunning both read true with ZERO heartbeats and zero
-- emitted frames for as long as you care to wait, and every remote player's
-- ghost stands frozen.
--
-- So each loop stamps a heartbeat, and the Start* functions treat a stale
-- stamp as "not actually running" and restart regardless of the flag.
local TICK_ALIVE_WINDOW = 1.0   -- seconds; all three loops run far faster

local function tickAlive(flag, stamp)
    return flag and stamp and (os.clock() - stamp) < TICK_ALIVE_WINDOW
end

function KCD2MP_EmitTick()
    if not KCD2MP.emitRunning then return end
    Script.SetTimer(KCD2MP.emitIntervalMs, KCD2MP_EmitTick)  -- reschedule FIRST: a Lua error must not kill the stream
    KCD2MP._emitAliveAt = os.clock()

    local ok, err = pcall(KCD2MP_EmitState)
    if not ok then
        -- Report once rather than every tick; at 50 Hz a hot error would bury the log.
        if not KCD2MP._emitErrLogged then
            KCD2MP._emitErrLogged = true
            System.LogAlways("[KCD2-MP] EmitTick error: " .. tostring(err))
        end
    end
end

-- intervalMs is optional; the agent passes its configured rate.
function KCD2MP_StartEmitter(intervalMs)
    if intervalMs and intervalMs >= 5 then KCD2MP.emitIntervalMs = intervalMs end
    if tickAlive(KCD2MP.emitRunning, KCD2MP._emitAliveAt) then return end
    KCD2MP.emitRunning = true
    KCD2MP._emitAliveAt = os.clock()   -- prime it: the first tick is one interval away
    KCD2MP._emitErrLogged = false
    System.LogAlways("[KCD2-MP] State emitter started (" .. KCD2MP.emitIntervalMs .. "ms)")
    Script.SetTimer(KCD2MP.emitIntervalMs, KCD2MP_EmitTick)
end

function KCD2MP_StopEmitter()
    KCD2MP.emitRunning = false
    System.LogAlways("[KCD2-MP] State emitter stopped after " .. KCD2MP.emitSeq .. " lines")
end

-- Legacy name, kept because the 500 ms KCD2MP_Tick calls it. Delegates so there
-- is only ever one [KCD2-MP-DATA] format for the tailer to parse.
function KCD2MP_WritePos()
    return KCD2MP_EmitState()
end

-- ===== Outbound Events (WO-2) =====
-- A second line type on the same log channel, for discrete things the player
-- did rather than continuous state. Accepting an invite has to travel game →
-- agent, and the log tail is the only outbound path (no sockets, no io), so it
-- rides here instead of resurrecting the sv_servername CVar hack.
--
--   [KCD2-MP-EVT] v1 <seq> <name> <arg>
--
-- Sequence numbers are separate from the state stream so a dropped position
-- frame cannot be mistaken for a dropped event.
KCD2MP.evtSeq = 0

function KCD2MP_EmitEvent(name, arg)
    KCD2MP.evtSeq = KCD2MP.evtSeq + 1
    System.LogAlways(string.format("[KCD2-MP-EVT] v1 %d %s %s",
        KCD2MP.evtSeq, tostring(name), tostring(arg or "")))
end

-- ===== Interaction Prompt UI (WO-2) =====
-- Drawn from the existing 8 ms label loop via System.DrawText. Game.ShowNotification
-- was already rejected for injecting '@' decorators, and DrawLabel is world-space,
-- so screen-space DrawText is the right tool for a prompt.
KCD2MP.invite = nil            -- {sid, who, kind, shownAt}
KCD2MP.interactionMsg = nil    -- {text, shownAt}
KCD2MP.diceTurn = nil          -- {text} -- optional glanceable hint; the launcher window is the real dice UI

local INVITE_TIMEOUT   = 30    -- matches the relay's invite expiry
local MSG_TIMEOUT      = 5

-- Called by the agent when a peer invites this player.
function KCD2MP_ShowInvite(sid, who, kind)
    KCD2MP.invite = { sid = sid, who = tostring(who), kind = tostring(kind), shownAt = os.clock() }
    mp_log("INVITE from " .. tostring(who) .. " (" .. tostring(kind) .. ") session " .. tostring(sid))
end

function KCD2MP_HideInvite()
    KCD2MP.invite = nil
end

-- Transient feedback: "Declined", "PeerDisconnected", and so on.
function KCD2MP_ShowInteractionMsg(text)
    KCD2MP.interactionMsg = { text = tostring(text), shownAt = os.clock() }
end

function KCD2MP_AcceptInvite()
    if not KCD2MP.invite then
        mp_log("No invite to accept")
        return false
    end
    KCD2MP_EmitEvent("invite_accept", KCD2MP.invite.sid)
    KCD2MP_HideInvite()
    KCD2MP_ShowInteractionMsg("Accepted")
    return true
end

function KCD2MP_DeclineInvite()
    if not KCD2MP.invite then return false end
    KCD2MP_EmitEvent("invite_decline", KCD2MP.invite.sid)
    KCD2MP_HideInvite()
    KCD2MP_ShowInteractionMsg("Declined")
    return true
end

-- WO-9: honest floor for appearance sync. The agent normally polls
-- EquipmentManager.EquippedArmorsByClassId itself (no Lua involved in
-- detection at all -- that read goes straight over the debug REST API), but
-- a player who wants to force it right now rather than wait for the poll or
-- the heartbeat can run this. Same event-channel pattern as invite_accept.
function KCD2MP_SyncAppearance()
    KCD2MP_EmitEvent("appearance_sync", "")
    mp_log("Requested immediate appearance resync")
    KCD2MP_ShowInteractionMsg("Appearance resync requested")
end

-- WO-11: honest floor for pause detection, same idea as KCD2MP_SyncAppearance
-- above. The agent watches kcd.log itself for the menu/inventory/skip-time
-- markers that were confirmed live (docs/WO-11-findings.md) -- no Lua
-- involved in detection there either -- but a tutorial popup and photo mode
-- were never confirmed to emit one, so this lets a player declare "I'm
-- effectively unavailable" by hand regardless of the reason. Toggles: this
-- side has no way to know whether the agent currently considers us paused,
-- so it just flips a manual flag and lets GameBridge OR it with automatic
-- detection.
function KCD2MP_SlowTime()
    KCD2MP_EmitEvent("slow_time_toggle", "")
    mp_log("Requested manual slow-time toggle")
end

-- Superseded by the WO-6 dice overlay below, which draws the whole match. Kept
-- as a one-liner so an older agent build talking to a newer pak still puts
-- something on screen instead of erroring.
function KCD2MP_ShowDiceTurn(text)
    if text == nil or text == "" then
        KCD2MP.diceTurn = nil
    else
        KCD2MP.diceTurn = { text = tostring(text) }
    end
end

-- Invites the nearest ghost. Lua picks the target because it already has both
-- the player's position and every ghost's; the agent only knows relay ids.
-- kindStr is "dice" or "duel".
function KCD2MP_InviteNearest(kindStr)
    kindStr = tostring(kindStr or ""):gsub("%s+", "")
    if kindStr == "" then kindStr = "dice" end

    local ppos = player and player:GetWorldPos()
    if not ppos then return false end

    local bestId, bestD = nil, nil
    for id, g in pairs(KCD2MP.ghosts or {}) do
        if g and g.entity then
            local ok, gp = pcall(function() return g.entity:GetWorldPos() end)
            if ok and gp then
                local d = (gp.x - ppos.x)^2 + (gp.y - ppos.y)^2 + (gp.z - ppos.z)^2
                if not bestD or d < bestD then bestD, bestId = d, id end
            end
        end
    end

    if not bestId then
        mp_log("No other player nearby to invite")
        KCD2MP_ShowInteractionMsg("No player nearby")
        return false
    end

    mp_log("Inviting ghost " .. tostring(bestId) .. " to " .. kindStr)
    KCD2MP_EmitEvent("invite_send", tostring(bestId) .. " " .. kindStr)
    KCD2MP_ShowInteractionMsg("Invite sent")
    return true
end

-- Draws the prompt and any transient message. Called from the label loop, which
-- already runs at 8 ms so text does not flicker between frames.
function KCD2MP_DrawInteractionUI()
    local inv = KCD2MP.invite
    if inv then
        if os.clock() - inv.shownAt > INVITE_TIMEOUT then
            KCD2MP.invite = nil
        else
            local left = math.ceil(INVITE_TIMEOUT - (os.clock() - inv.shownAt))
            System.DrawText(10, 60, inv.who .. " invites you to " .. inv.kind .. "  (" .. left .. "s)", 2)
            System.DrawText(10, 84, "mp_accept  /  mp_decline", 1.6)
        end
    end

    local msg = KCD2MP.interactionMsg
    if msg then
        if os.clock() - msg.shownAt > MSG_TIMEOUT then
            KCD2MP.interactionMsg = nil
        else
            System.DrawText(10, 110, msg.text, 1.6)
        end
    end

    if KCD2MP.diceTurn then
        System.DrawText(10, 134, KCD2MP.diceTurn.text, 1.6)
    end
end

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

-- outcome: "win" or "lose".
function KCD2MP_DiceEnd(outcome, s0, s1)
    D.scores[0] = tonumber(s0) or D.scores[0]
    D.scores[1] = tonumber(s1) or D.scores[1]
    D.outcome   = tostring(outcome or "lose")
    D.sel, D.hold, D.err = {}, nil, nil
    say((D.outcome == "win") and "The wager is thine."
                              or (D.peer .. " takes the pot."))
    KCD2MP_DiceRender()
    mp_log("DICE match ended: " .. D.outcome)
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
function KCD2MP_InviteDiceAtTable()
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
    return KCD2MP_InviteNearest("dice")
end

-- ===== Ghost NPC Spawn =====

-- WO-17: mp_enable_aggro on|off. Opt-in, off by default, decided locally on
-- this client only -- it does not need the other player's agreement, the
-- same way dice needed a session invite/accept but this does not, because it
-- only changes how THIS player's world treats an incoming ghost. Affects
-- every ghost spawned AFTER the toggle flips; an already-spawned ghost keeps
-- whatever tree it spawned with (respawn it, e.g. by having the peer
-- reconnect, to pick up a change). The agent hears about this via the same
-- log-tail event channel invite_accept already uses (KCD2MP_EmitEvent) --
-- it, not Lua, is what actually decides when to attach a ghost to the
-- hostile faction, since that write only exists in native code.
function KCD2MP_EnableAggro(arg)
    local s = tostring(arg or ""):lower()
    if s:find("on") then KCD2MP.aggroEnabled = true
    elseif s:find("off") then KCD2MP.aggroEnabled = false
    else
        mp_log("mp_enable_aggro: expected 'on' or 'off', got '" .. tostring(arg) .. "'")
        return false
    end
    KCD2MP_EmitEvent("aggro_toggle", KCD2MP.aggroEnabled and "on" or "off")
    mp_log("AGGRO " .. (KCD2MP.aggroEnabled and "ENABLED" or "disabled") ..
           " -- affects ghosts spawned from now on")
    KCD2MP_ShowInteractionMsg("Aggro: " .. (KCD2MP.aggroEnabled and "ON" or "OFF"))
    return true
end

function KCD2MP_SpawnGhost(id, x, y, z, rotZ)
    if KCD2MP.ghosts[id] then
        KCD2MP_RemoveGhost(id)
    end

    local pos = {x=x, y=y, z=z}
    local name = "kcd2mp_" .. id

    System.LogAlways(string.format("[KCD2-MP] Spawning ghost '%s' at %.1f,%.1f,%.1f", id, x, y, z))

    -- WO-20: deterministic real face. Keyed on the Steam name if it has
    -- already arrived (KCD2MP_SetGhostName runs at Handshake time on the
    -- server, before any Position packet -- see docs/WO-20-faces.md -- so in
    -- practice it almost always has), falling back to the same "Player<id>"
    -- string the nameplate itself falls back to so a spawn is never blocked
    -- waiting on the name.
    local faceKey = KCD2MP.ghostNames[id] or ("Player" .. tostring(id))
    local facePick = KCD2MP_PickFaceForPlayer(faceKey)

    -- WO-22: SharedSoulGuid is a TOP-LEVEL parameter of SpawnEntity's table, not
    -- something nested under Properties. Warhorse's own shipped scriptbind doc
    -- (C_ScriptBindXGenAIModule__SpawnEntity) gives a flat table -- Name,
    -- SharedSoulGuid, SoulArchetypeName, ClassName, Pos, Rot, NoAI,
    -- SchedulerProxyName, ... -- with no Properties key in it at all.
    --
    -- Passing it nested, as this did until WO-22, binds NO soul: the spawned
    -- ghost's SharedSoulGuid reads back all-zeroes and it gets an arbitrary
    -- engine-generated appearance. That is why every ghost was brainless --
    -- a Warhorse brain is a column on the soul row (brain_id in
    -- Libs/Tables/rpg/soul__*.xml), so no soul means no brain.
    --
    -- Passed correctly, the ghost gets the roster soul's real face, faction
    -- identity, reputation log and combat level -- and, verified live, it
    -- RECOVERS from being knocked unconscious (<=54s and <=26s over two
    -- cycles) where a brainless ghost stayed down forever. That is A1 from
    -- WO-16-release-candidate.md, fixed. See docs/WO-22-brain-lead.md.
    --
    -- SchedulerProxyName is deliberately NOT passed. It is what would make the
    -- ghost pick its own activities and walk off under its own power, which
    -- fights KCD2MP_InterpTick's position stream. It is not needed for the
    -- recovery fix -- the soul alone buys that -- so a ghost spawned this way
    -- stays byte-stationary, exactly as before. ForceMount is unaffected
    -- (re-tested against a real horse on this exact shape).
    --
    -- esModularBehaviorTree is gone rather than emptied: WO-21 proved it is
    -- inert and that "IdleSeq" names no tree anywhere in the shipped game
    -- data. It was never a live variable, so the aggro toggle's switch on it
    -- was a no-op. Aggro still works -- it comes from the native faction
    -- attach, as it always actually did.
    local entity = nil
    pcall(function()
        XGenAIModule.SpawnEntity{
            Name           = name,
            ClassName      = facePick.className,
            Pos            = {x, y, z},
            SharedSoulGuid = facePick.guid,
        }
        entity = System.GetEntityByName(name)
    end)
    if not entity then
        System.LogAlways("[KCD2-MP] XGenAI spawn failed, fallback System.SpawnEntity")
        local ok2, e2 = pcall(System.SpawnEntity, {
            class = facePick.className, position = pos, name = name,
            properties = { esFaction = "Civilians", guidSharedSoulId = facePick.guid },
        })
        if ok2 then entity = e2 end
    end
    System.LogAlways(string.format("[KCD2-MP] face pick for '%s': key=%s class=%s soul=%s guid=%s",
        id, faceKey, facePick.className, facePick.soulName, facePick.guid))

    if not entity then
        System.LogAlways("[KCD2-MP] SpawnEntity failed for ghost id=" .. tostring(id))
        return nil
    end

    -- Set faction via AI system (XGenAIModule ignores Properties.esFaction at spawn time)
    pcall(function()
        entity.Properties.esFaction = "Civilians"
        AI.ChangeParameter(entity.id, AIPARAM_FACTION, "Civilians")
    end)

    System.LogAlways("[KCD2-MP] Spawned entityId=" .. tostring(entity.id))

    -- Apply white/red armor preset (ClothingPreset first, then WeaponPreset + visor).
    --
    -- WO-20: white_red's item list is entirely male mesh variants ("_m0X").
    -- Confirmed live: an NPC_Female entity fault-freely accepts the preset
    -- call (pcall ok=true, no error) but nothing renders and
    -- EquippedArmorsByClassId reads back EMPTY afterwards -- not just missing
    -- the preset items, but stripped of the soul's own authored default
    -- outfit too, leaving her in the bare base layer. A plain NPC_Female
    -- spawned with NO preset call keeps her own default outfit fine (also
    -- confirmed live). So the preset call is actively destructive on a
    -- female-classed ghost, not merely ineffective -- skip it for her and
    -- let the soul's own authored outfit stand. The male path is unchanged.
    if facePick.className ~= "NPC_Female" then
        local p = KCD2MP.armorPresets.white_red
        pcall(function() entity.actor:EquipClothingPreset(p.preset) end)
        pcall(function() entity.actor:EquipWeaponPreset(p.weapons) end)
    end
    local ghostName = name
    Script.SetTimer(800, function()
        pcall(function() System.ExecuteCommand("closeVisorOn " .. ghostName) end)
    end)

    -- WO-17: human:DrawWeapon() is a real, visually-confirmed native mutation
    -- (unlike EquipWeaponPreset, which is cosmetic-only, WO-9) -- it does NOT
    -- flip CombatSoul.HasMeleeWeapon on an NPC (confirmed live: that flag
    -- tracks the AI's own combat-engagement state, not the item-in-hand
    -- visual), so this does not grant real retaliation capability. It only
    -- makes an aggro-flagged ghost look combat-ready rather than sheathed,
    -- which is worth doing for free since the call is proven harmless.
    if KCD2MP.aggroEnabled then
        Script.SetTimer(1000, function()
            local g = KCD2MP.ghosts[id]
            if g and g.entity and g.entity.human then
                pcall(function() g.entity.human:DrawWeapon() end)
            end
        end)
    end

    local r = rotZ or 0

    -- Interpolation state: buffer with prev packet (A) and target packet (B)
    -- alpha: 0 = at A, 1 = at B, >1 = dead reckoning beyond B
    -- alphaStep: how much alpha advances per 50ms tick (= 50ms / packetInterval)
    --   default assumes 200ms server tick -> step = 0.25 (reaches B in 4 ticks)
    local istate = {
        -- Previous packet (lerp source)
        px = x, py = y, pz = z, pr = r,
        -- Target packet (lerp destination)
        tx = x, ty = y, tz = z, tr = r,
        -- Current rendered position
        cx = x, cy = y, cz = z, cr = r,
        -- Interpolation progress
        alpha = 1.0,
        alphaStep = 0.25,
        -- Dead reckoning velocity (units/sec), computed from last two packets
        vx = 0, vy = 0, vz = 0,
        -- Last ACTUAL packet position (separate from tx/ty which DR extends)
        lastPacketX = x, lastPacketY = y,
        -- Ticks since last server packet (for dead reckoning timeout)
        ticksSincePacket = 0,
        -- Packet arrival count (for logging)
        packetCount = 0,
        -- Animation state
        animTag = "idle",     -- "idle"/"walk"/"run" - current animation state
        smoothedSpeed = 0,
        prevCx = x, prevCy = y,
        speedDropTicks = 0,   -- consecutive ticks with low speed after high speed
    }

    KCD2MP.ghosts[id] = {
        entity = entity,
        entityId = entity.id,
        istate = istate,
        facePick = facePick,
        faceKey = faceKey,
    }

    -- Schedule name apply after entity fully inits (soul may not be ready at spawn time).
    -- Uses Steam nick if already received via 0x03, else fallback "Player<id>".
    local captId = id
    Script.SetTimer(1500, function()
        local displayName = KCD2MP.ghostNames[captId] or ("Player" .. captId)
        KCD2MP_ApplyGhostName(captId, displayName)
    end)

    -- Auto-start interp loop as soon as we have a ghost to move
    KCD2MP_StartInterp()

    return entity
end

-- ===== Ghost Name (Steam nick above head) =====

-- Actually applies name to a ready entity. Logs before/after to diagnose soul.name write.
function KCD2MP_ApplyGhostName(id, name)
    local ghost = KCD2MP.ghosts[id]
    if not ghost or not ghost.entity then
        mp_log("ApplyName id=" .. id .. " no entity")
        return
    end
    local e = ghost.entity

    -- Read current soul.name before assignment (to see what the default is)
    local before = nil
    pcall(function() before = e.soul and e.soul.name end)

    -- Attempt 1: soul.name = plain string (KCD2 shows this in NPC nameplates)
    local ok1 = pcall(function() e.soul.name = name end)
    -- Attempt 2: soul.sName (alternative field name seen in some CryEngine versions)
    local ok2 = pcall(function() e.soul.sName = name end)
    -- Attempt 3: entity display name (used in some HUD contexts)
    local ok3 = pcall(function() e:SetName(name) end)

    -- Read back to verify assignment succeeded
    local after = nil
    pcall(function() after = e.soul and e.soul.name end)

    mp_log(string.format("ApplyName id=%s name=%s ok1=%s ok2=%s ok3=%s before=%s after=%s",
        id, name, tostring(ok1), tostring(ok2), tostring(ok3), tostring(before), tostring(after)))
end

-- Store name; if ghost already exists apply with short delay, else applied at spawn (1.5s).
function KCD2MP_SetGhostName(id, name)
    KCD2MP.ghostNames[id] = name
    local ghost = KCD2MP.ghosts[id]
    if ghost and ghost.entity then
        -- Ghost already alive when name packet arrives — apply after 300ms
        local captId = id
        local captName = name
        Script.SetTimer(300, function()
            KCD2MP_ApplyGhostName(captId, captName)
        end)
    end
    -- No ghost yet: name stored in ghostNames, applied at spawn (1.5s delay there)
end

-- ===== Horse Ghost Spawn / Remove =====

function KCD2MP_SpawnHorse(id, x, y, z, rotZ)
    if KCD2MP.horseGhosts[id] then
        KCD2MP_RemoveHorse(id)
    end

    local pos = {x=x, y=y, z=z}
    local horseName = "kcd2mp_horse_" .. id

    -- Use System.SpawnEntity only (XGenAIModule is async → creates orphan second entity)
    local horse = nil
    local ok2, h2 = pcall(System.SpawnEntity, {
        class = "Horse", position = {x=x, y=y, z=z},
        name = horseName, properties = { esFaction = "Civilians" },
    })
    if ok2 and h2 then horse = h2 end

    if not horse then
        mp_log("HorseSpawn FAILED id=" .. id)
        return nil
    end

    pcall(function() horse:SetWorldAngles({x=0, y=0, z=rotZ or 0}) end)
    pcall(function() horse:SetMountableByPlayer(false) end)
    -- Set faction directly. Do NOT use CryAction.RegisterWithAI - that gives the horse an
    -- AI object which fights against our SetWorldPos calls every tick.
    pcall(function() AI.ChangeParameter(horse.id, AIPARAM_FACTION, "Civilians") end)

    KCD2MP.horseGhosts[id] = {
        entity = horse,
        entityId = horse.id,
    }

    mp_log("HorseSpawn OK id=" .. id .. " entityId=" .. tostring(horse.id))

    Script.SetTimer(400, function()
        KCD2MP_MountNPCOnHorse(id)
    end)

    return horse
end

function KCD2MP_MountNPCOnHorse(id)
    local ghost     = KCD2MP.ghosts[id]
    local horseData = KCD2MP.horseGhosts[id]
    if not ghost or not ghost.entity or not horseData or not horseData.entity then
        mp_log("MountNPCOnHorse: missing entity id=" .. id)
        return
    end

    local horse = horseData.entity
    local human = ghost.entity.human
    mp_log(string.format("MountNPCOnHorse id=%s hasHuman=%s", id, tostring(human ~= nil)))

    if not human then
        local captId = id
        Script.SetTimer(1000, function() KCD2MP_MountNPCOnHorse(captId) end)
        return
    end

    local ok1 = pcall(function() human:ForceMount(horse.id) end)
    mp_log("ForceMount ok=" .. tostring(ok1) .. " id=" .. id)
    if not ok1 then return end

    -- Verify mount after short delay; if confirmed, try to suppress scheduler errors
    local captId = id
    Script.SetTimer(300, function()
        local g2 = KCD2MP.ghosts[captId]
        if not g2 then return end
        local mounted = false
        pcall(function() mounted = g2.entity.human and g2.entity.human:IsMounted() end)
        mp_log("IsMounted=" .. tostring(mounted) .. " id=" .. captId)
        if not mounted then return end

        g2.istate.nativeMounted = true
        mp_log("NATIVE MOUNT SUCCESS id=" .. captId)

        -- === OPTION C: suppress "No valid scheduler behavior while occupying stance" ===
        -- Try 1: send OnHorseMounted signal so scheduler updates its state
        local s1 = pcall(function() AI.Signal(SIGNALFILTER_SENDER, 1, "OnHorseMounted", g2.entity.id) end)
        -- Try 2: disable AI entirely so scheduler stops fighting the mount
        local s2 = pcall(function() g2.entity:EnableAI(false) end)
        -- Try 3: AI.AutoDisable keeps AI alive but prevents auto-sleep cycles
        local s3 = pcall(function() AI.AutoDisable(g2.entity.id, 0) end)
        -- Try 4: generic OnMount signal
        local s4 = pcall(function() AI.Signal(0, 1, "OnMount", g2.entity.id) end)
        mp_log(string.format("OptionC signals id=%s s1=%s s2=%s s3=%s s4=%s",
            captId, tostring(s1), tostring(s2), tostring(s3), tostring(s4)))
    end)
end

function KCD2MP_RemoveHorse(id)
    local horseData = KCD2MP.horseGhosts[id]
    if not horseData then return end
    if horseData.entityId then
        pcall(function() System.RemoveEntity(horseData.entityId) end)
    end
    KCD2MP.horseGhosts[id] = nil
    mp_log("RemoveHorse id=" .. id)
end

-- ===== Ghost Update (called by server each packet) =====

function KCD2MP_UpdateGhost(id, x, y, z, rotZ, isRiding)
    local ghost = KCD2MP.ghosts[id]

    -- Spawn if doesn't exist yet, then fall through to process isRiding on same call.
    if not ghost or not ghost.entity then
        KCD2MP_SpawnGhost(id, x, y, z, rotZ)
        ghost = KCD2MP.ghosts[id]
        if not ghost or not ghost.entity then return end  -- spawn failed
    end

    local istate = ghost.istate
    if not istate then return end

    local r = rotZ or istate.tr

    -- Velocity from actual packet positions (for dead reckoning).
    -- Use real elapsed time between packets instead of fixed SERVER_INTERVAL
    -- (echo mode sends every ~10ms, not 50ms, so fixed interval gave 5x underestimate).
    local ddx = x - (istate.lastPacketX or x)
    local ddy = y - (istate.lastPacketY or y)
    local now = os.clock()
    local dt = now - (istate.lastPacketTime or now)
    istate.lastPacketTime = now
    local raw_vx, raw_vy
    if dt > 0.005 and dt < 1.0 then
        raw_vx = ddx / dt
        raw_vy = ddy / dt
    else
        raw_vx = 0
        raw_vy = 0
    end
    istate.lastPacketDt = dt
    istate.vx = lerpVal(istate.vx or 0, raw_vx, 0.5)
    istate.vy = lerpVal(istate.vy or 0, raw_vy, 0.5)
    istate.lastPacketX = x
    istate.lastPacketY = y

    -- Log large target jumps; reset velocity on teleport/fast-travel
    -- Jump detection: XY only — Z changes from terrain must NOT reset velocity
    local jumpDist = math.sqrt(ddx*ddx + ddy*ddy)
    if jumpDist > 5.0 then
        istate.vx = 0
        istate.vy = 0
        mp_log(string.format("JUMP id=%s xyDist=%.2f vx/vy reset", id, jumpDist))
    elseif jumpDist > 2.0 then
        mp_log(string.format("JUMP id=%s xyDist=%.2f", id, jumpDist))
    end

    istate.tx = x
    istate.ty = y
    istate.tz = z
    istate.tr = r
    istate.ticksSincePacket = 0
    istate.packetCount = istate.packetCount + 1

    -- Horse riding sync
    local riding = (isRiding == true)
    local wasRiding = (istate.isRiding == true)
    istate.isRiding = riding

    if riding and not wasRiding then
        -- Player just mounted a horse: spawn horse ghost
        mp_log("Riding START id=" .. id)
        KCD2MP_SpawnHorse(id, x, y, z, r)
    elseif not riding and wasRiding then
        -- Player dismounted: remove horse ghost, restore walk animation
        mp_log("Riding STOP id=" .. id)
        -- Dismount if natively mounted
        if istate.nativeMounted then
            pcall(function() ghost.entity.human:ForceDismount() end)
            istate.nativeMounted = false
        end
        KCD2MP_RemoveHorse(id)
        istate.animTag = "idle"  -- force animation reset
    end

    if istate.packetCount % 40 == 1 then
        local spd = math.sqrt(raw_vx*raw_vx + raw_vy*raw_vy)
        mp_log(string.format("pkt#%d id=%s pos=%.1f,%.1f,%.1f spd=%.1f riding=%s",
            istate.packetCount, id, x, y, z, spd, tostring(riding)))
    end
end

-- ===== Exchange: read local player state + apply ghost from other player =====
-- Returns CSV "x,y,z,rotZ,stance"  (stance: "s"=stand, "c"=crouch/sneak)
-- gstance: other player's stance to apply to ghost
function KCD2MP_Exchange(ghost_id, gx, gy, gz, gr, gstance)
    -- Apply incoming ghost state
    if ghost_id and gx then
        KCD2MP_UpdateGhost(ghost_id, gx, gy, gz, gr, gstance)
    end
    -- Read and return local player state
    if not player then return "" end
    local pos = player:GetWorldPos()
    if not pos then return "" end
    local rot = 0
    pcall(function()
        local ang = player:GetWorldAngles()
        if ang then rot = ang.z or 0 end
    end)
    -- Stance: use OnAction-tracked flag (most reliable in KCD2)
    -- Fallback to engine API in case action hook missed something
    local stance = "s"
    if KCD2MP.playerSneaking then
        stance = "c"
    else
        pcall(function()
            local s = player:GetStance()
            if s == 2 or s == 3 then stance = "c" end
        end)
        if stance == "s" then
            pcall(function()
                if player.actor and player.actor.bSneaking then stance = "c" end
            end)
        end
    end
    return string.format("%.3f,%.3f,%.3f,%.4f,%s", pos.x, pos.y, pos.z, rot, stance)
end

-- Auto-start interp tick (safe to call multiple times)
function KCD2MP_StartInterp()
    -- Liveness, not the flag -- see the comment on tickAlive. A save load
    -- leaves interpRunning true over a dead timer chain, and the old
    -- flag-only guard here made that permanent: every remote ghost frozen for
    -- the rest of the session with no way to recover short of restarting the
    -- game.
    if not tickAlive(KCD2MP.interpRunning, KCD2MP._interpAliveAt) then
        KCD2MP.interpRunning = true
        KCD2MP._interpAliveAt = os.clock()
        System.LogAlways("[KCD2-MP] Interp tick started (20ms)")
        Script.SetTimer(20, KCD2MP_InterpTick)
    end
    -- Start label render loop if not already running (8ms < 16.7ms frame = no flicker)
    if not tickAlive(KCD2MP.labelRunning, KCD2MP._labelAliveAt) then
        KCD2MP.labelRunning = true
        KCD2MP._labelAliveAt = os.clock()
        System.LogAlways("[KCD2-MP] Label render loop started (8ms)")
        Script.SetTimer(8, KCD2MP_LabelTick)
    end
end

-- Update horse positions at 8ms to avoid 20ms stutter (physics fights SetWorldPos less).
--
-- Split out of KCD2MP_LabelTick for WO-13's external pump. InterpTick only
-- computes horseData.render*; this is what actually applies it, so a pump that
-- drove InterpTick alone would leave a mounted ghost's horse standing still
-- while the rider slid along on top of it.
function KCD2MP_ApplyHorseTransforms()
    for id, horseData in pairs(KCD2MP.horseGhosts) do
        if horseData.entity and horseData.renderX then
            pcall(function()
                horseData.entity:SetWorldPos({x=horseData.renderX, y=horseData.renderY, z=horseData.renderZ})
                horseData.entity:SetWorldAngles({x=0, y=0, z=horseData.renderR})
            end)
        end
    end
end

-- WO-13: driven by the agent over ExecuteString while a LOCAL menu has focus.
-- Script.SetTimer -- which schedules every tick in this file -- is frozen for
-- the whole duration of a local menu (WO-12 s0.3), so without this the other
-- players' ghosts stand still on your own screen while you are the one in the
-- inventory. ExecuteString-driven Lua keeps executing throughout (WO-12 s0.4),
-- which is the whole reason this works.
--
-- Deliberately does NOT pump KCD2MP_LabelTick's drawing half. DrawLabel and
-- DrawText are immediate-mode -- one frame per call -- so pumping them would
-- draw a nameplate on some frames and not others, i.e. strobe rather than
-- render. Measured pump rate live is 35-86 Hz against a 60 fps frame, which
-- is fast enough for motion to look continuous but is NOT frame-locked, so
-- the strobing is real. Labels therefore stay hidden for the duration of the
-- menu -- exactly what already happens today. This fix is about ghost bodies
-- moving, not about labels.
function KCD2MP_InterpPump()
    KCD2MP_InterpTick("ext")
    KCD2MP_ApplyHorseTransforms()
end

-- WO-13 Phase 2. Called by the agent when a PauseDown (0x1D) says a peer
-- entered or left a menu. Ghost ids are strings on this side (they key
-- KCD2MP.ghosts), so the caller must pass the same form it uses everywhere
-- else; tostring here rather than trusting that.
function KCD2MP_SetGhostMenuState(id, inMenu)
    id = tostring(id)
    KCD2MP.ghostInMenu[id] = inMenu and true or nil
    mp_log("GHOST_MENU id=" .. id .. " inMenu=" .. tostring(inMenu and true or false))
end

function KCD2MP_LabelTick()
    if not KCD2MP.labelRunning then return end
    Script.SetTimer(8, KCD2MP_LabelTick)
    KCD2MP._labelAliveAt = os.clock()
    KCD2MP_ApplyHorseTransforms()
    for id, lbl in pairs(KCD2MP.labelCache) do
        if lbl.size > 0 then
            pcall(function()
                System.DrawLabel({x=lbl.x, y=lbl.y, z=lbl.z}, lbl.size, lbl.name, 1, 1, 0, 1)
            end)
        end
    end
    -- Draw ping in top-left corner using 2D screen-space DrawText(x, y, text, size).
    if KCD2MP.pingText then
        pcall(function()
            System.DrawText(10, 10, KCD2MP.pingText, 2)
        end)
    end

    -- Interaction prompt (WO-2) shares this loop rather than adding a timer.
    pcall(KCD2MP_DrawInteractionUI)

    -- NOTE: the dice board deliberately does NOT ride this loop. This loop only
    -- starts when the agent connects and calls KCD2MP_StartInterp, so hanging
    -- the board off it meant the board silently never rendered with no agent
    -- running -- verified: labelRunning=false while diceOpen=true. The board is
    -- pushed into the game's own UI on state change instead, so it needs no
    -- per-frame loop at all.
end

-- ===== Animation Update =====

-- Sneak animation candidates (probed on first use, result cached).
local SNEAK_WALK_ANIMS = {
    "3d_sneak_walk_turn_strafe",
    "3d_sneaking_walk_turn_strafe",
    "3d_stealth_walk_turn_strafe",
    "3d_crouch_walk_turn_strafe",
}
local SNEAK_IDLE_ANIMS = {
    "sneak_idle_both",
    "sneaking_idle_both",
    "stealth_idle_both",
    "crouch_idle_both",
}
KCD2MP._sneakWalkAnim = nil
KCD2MP._sneakIdleAnim = nil

-- Riding animation candidates (probed on first use, result cached).
-- false = probed but none found (avoid re-probing every tick).
local RIDING_IDLE_ANIMS = {
    -- Confirmed working on KCD2 NPC class:
    "horse_idle",
    -- Simple names
    "riding_idle", "riding_idle_both", "horse_riding_idle",
    "mounted_idle", "horseback_idle", "cavalry_idle",
    -- 3d_ prefix (confirmed KCD2 convention)
    "3d_riding_idle", "3d_riding_idle_both",
    "3d_horse_idle", "3d_horse_idle_both",
    "3d_horseback_idle", "3d_mounted_idle",
    "3d_relaxed_horse_idle", "3d_relaxed_horse_idle_both",
    "3d_relaxed_riding_idle", "3d_relaxed_riding_idle_both",
    -- relaxed_ prefix (confirmed KCD2 convention)
    "relaxed_riding_idle", "relaxed_riding_idle_both",
    "relaxed_horse_idle", "relaxed_horse_idle_both",
    -- wagon / sit (seated pose that might work)
    "wagon_idle", "wagon_idle_both", "wagon_ride_idle",
    "sit_idle", "sit_idle_both", "3d_sit_idle",
    "seated_idle", "seated_idle_both",
    -- combat horse
    "combat_horse_idle", "combat_horse_idle_both",
    "3d_combat_horse_idle", "3d_combat_horse_idle_both",
    -- act / mm prefix
    "act_horse_idle", "mm_horse_idle",
    -- npc specific
    "npc_horse_idle", "npc_riding_idle",
}
local RIDING_GALLOP_ANIMS = {
    -- Based on confirmed idle pattern: 1d_idle_slope_relaxed_idle_rider_01
    "1d_gallop_slope_relaxed_gallop_rider_01",
    "1d_canter_slope_relaxed_canter_rider_01",
    "1d_trot_slope_relaxed_trot_rider_01",
    "1d_walk_slope_relaxed_walk_rider_01",
    -- Other candidates
    "horse_gallop", "horse_run", "horse_trot", "horse_canter",
    "riding_gallop", "riding_gallop_both",
    "3d_riding_gallop", "3d_horse_gallop",
    "relaxed_horse_run", "combat_horse_run", "mounted_gallop",
}
KCD2MP._ridingIdleAnim  = nil   -- nil=not probed yet, false=not found, string=found
KCD2MP._ridingGallopAnim = nil

-- Horse entity animation candidates (Horse class entity, not NPC riding).
local HORSE_ENTITY_IDLE_ANIMS = {
    -- Confirmed present on KCD2 horse entities (from mp_scan_horse on real game horse):
    "relaxed_idle",
    -- Other candidates:
    "idle", "stand", "horse_idle", "animal_idle",
    "idle_loop", "horse_idle_loop", "stand_loop",
    "loco_idle", "act_idle", "mm_idle",
    "walk_idle", "stand_idle",
    "horse_stand", "horse_stand_idle", "horse_rest",
}
-- Separate walk vs gallop so we don't accidentally use relaxed_walk for full gallop.
local HORSE_ENTITY_WALK_ANIMS = {
    "relaxed_walk", "relaxed_trot",
    "horse_walk", "horse_trot", "walk", "trot",
}
local HORSE_ENTITY_GALLOP_ANIMS = {
    -- Fastest gaits first — confirmed on KCD2 horse entities:
    "relaxed_gallop", "relaxed_canter", "relaxed_run",
    -- Other candidates:
    "gallop", "canter", "run",
    "horse_gallop", "horse_canter", "horse_run",
    "horse_loco_gallop", "horse_loco_run",
    "animal_gallop", "animal_run",
    "loco_gallop", "loco_run",
}
KCD2MP._horseEntityIdleAnim   = nil  -- nil=not probed, false=not found, string=found
KCD2MP._horseEntityWalkAnim   = nil
KCD2MP._horseEntityGallopAnim = nil

local function findAnim(entity, candidates)
    for _, name in ipairs(candidates) do
        local len = 0
        pcall(function() len = entity:GetAnimationLength(0, name) or 0 end)
        if len > 0 then return name end
    end
    return nil
end

-- Hysteresis thresholds (m/s).
-- Different enter/exit speeds prevent oscillation when speed hovers at a boundary.
-- Enter: must EXCEED this speed to switch INTO this state.
-- Exit:  must DROP BELOW this speed to switch OUT of this state (go lower).
local ANIM_UP   = { walk=1.0, run=2.5, sprint=4.0 }
local ANIM_DOWN = { walk=0.4, run=1.8, sprint=3.2 }

local function calcAnimTag(speed, cur, stance)
    if stance == "c" then
        return speed > 0.3 and "sneak_walk" or "sneak_idle"
    end
    -- Start from current tag and check if we cross hysteresis bands.
    local t = cur or "idle"
    if t == "sprint" then
        if speed < ANIM_DOWN.sprint then t = "run"   else return "sprint" end
    end
    if t == "run" then
        if     speed >= ANIM_UP.sprint  then return "sprint"
        elseif speed <  ANIM_DOWN.run   then t = "walk"  else return "run" end
    end
    if t == "walk" then
        if     speed >= ANIM_UP.sprint  then return "sprint"
        elseif speed >= ANIM_UP.run     then return "run"
        elseif speed <  ANIM_DOWN.walk  then return "idle" else return "walk" end
    end
    -- idle / sneak states
    if     speed >= ANIM_UP.sprint then return "sprint"
    elseif speed >= ANIM_UP.run    then return "run"
    elseif speed >= ANIM_UP.walk   then return "walk"
    else                                 return "idle" end
end

function KCD2MP_UpdateAnimation(id, ghost)
    local istate = ghost.istate
    local speed = istate.smoothedSpeed or 0
    local stance = istate.stance or "s"

    -- Sanity: can't be sneaking at running speeds (auto-clears bad toggle state)
    if stance == "c" and speed > 4.0 then stance = "s" end
    local wantTag = calcAnimTag(speed, istate.animTag, stance)

    local animName
    if wantTag == "sneak_walk" then
        if not KCD2MP._sneakWalkAnim then
            KCD2MP._sneakWalkAnim = findAnim(ghost.entity, SNEAK_WALK_ANIMS)
                                    or "3d_relaxed_walk_turn_strafe"
            mp_log("SneakWalkAnim: " .. KCD2MP._sneakWalkAnim)
        end
        animName = KCD2MP._sneakWalkAnim
    elseif wantTag == "sneak_idle" then
        if not KCD2MP._sneakIdleAnim then
            KCD2MP._sneakIdleAnim = findAnim(ghost.entity, SNEAK_IDLE_ANIMS)
                                    or "relaxed_idle_both"
            mp_log("SneakIdleAnim: " .. KCD2MP._sneakIdleAnim)
        end
        animName = KCD2MP._sneakIdleAnim
    else
        local anims = {
            sprint = "3d_relaxed_sprint_turn_strafe",
            run    = "3d_relaxed_run_turn_strafe",
            walk   = "3d_relaxed_walk_turn_strafe",
            idle   = "relaxed_idle_both",
        }
        animName = anims[wantTag]
    end

    -- Call StartAnimation every tick to override Mannequin's idle.
    -- blend=0.15s: short enough to react quickly, long enough to not look choppy.
    pcall(function() ghost.entity:StartAnimation(0, animName, 0, 0.15, 1.0, true) end)

    -- Log only when tag actually changes
    if istate.animTag ~= wantTag then
        mp_log(string.format("Anim: %s %s->%s spd=%.2f", id, istate.animTag or "?", wantTag, speed))
        istate.animTag = wantTag
    end
end

-- ===== Interpolation Tick (20ms) =====

-- Floor detection: physics raycast hits real geometry (roads, rocks, bridges).
-- Falls back to terrain elevation if raycast unavailable.
local function getFloorZ(x, y, curZ)
    local floorZ = nil
    local reliable = false

    -- Physics raycast: origin 2m above ghost, ray goes 12m DOWN.
    -- Direction vector magnitude = ray length in CryEngine: {z=-12} = 12m downward.
    -- This covers range [curZ+2 .. curZ-10] - hits bridges, stairs, terrain.
    -- Flags 15 = ent_terrain(1)|ent_static(2)|ent_rigid(4)|ent_sleeping_rigid(8)
    pcall(function()
        local hits = Physics.RayWorldIntersection(
            {x=x, y=y, z=curZ + 2.0},
            {x=0,  y=0, z=-12},
            15,
            1
        )
        if hits and hits[1] then
            local h = hits[1]

            -- Log raycast field layout once (helps identify correct field name)
            if not KCD2MP._rayFmtLogged then
                KCD2MP._rayFmtLogged = true
                local parts = {}
                for k, v in pairs(h) do
                    if type(v) == "number" then
                        parts[#parts+1] = k .. "=" .. string.format("%.2f", v)
                    elseif type(v) == "table" then
                        parts[#parts+1] = k .. "={z=" .. tostring(v.z) .. "}"
                    end
                end
                mp_log("RAY_FORMAT: " .. table.concat(parts, " "))
            end

            -- CryEngine may return hit point as h.pt, h.pos, or h.point
            local hz = nil
            if     h.pt    then hz = h.pt.z
            elseif h.pos   then hz = h.pos.z
            elseif h.point then hz = h.point.z
            end
            -- Accept hits within 10m below current position
            if hz and hz > curZ - 10.0 then
                floorZ   = hz
                reliable = true
            end
        end
    end)

    -- Fallback to terrain mesh (underestimates height on bridges/platforms)
    if not floorZ then
        pcall(function()
            local gz = Terrain.GetElevation(x, y)
            if gz then floorZ = gz end
        end)
    end

    return floorZ, reliable
end

-- `arg` is the timer id when this fires from Script.SetTimer, and the string
-- "ext" when the agent pumps it in through ExecuteString while a local menu
-- has focus (WO-13). Compared against the sentinel rather than tested for
-- truthiness, because a real timer id is truthy too.
--
-- A pumped call must NOT reschedule. Script.SetTimer is frozen for the whole
-- duration of a local menu (WO-12 s0.3), so every timer queued by a pumped
-- call would still be pending when the menu closes and fire as one burst.
function KCD2MP_InterpTick(arg)
    if not KCD2MP.interpRunning then return end
    if arg ~= "ext" then
        Script.SetTimer(20, KCD2MP_InterpTick)  -- reschedule FIRST: crash-safe, tick never stops
        -- Only a scheduled fire counts as the chain being alive. A pumped call
        -- must not stamp this, or the pump would make a dead chain look
        -- healthy and stop KCD2MP_StartInterp from ever rebuilding it.
        KCD2MP._interpAliveAt = os.clock()
    end

    -- Heartbeat: confirm tick is alive (every ~5s = 250 * 20ms)
    KCD2MP._tickN = (KCD2MP._tickN or 0) + 1
    if KCD2MP._tickN % 250 == 0 then
        local gc = 0; for _ in pairs(KCD2MP.ghosts) do gc = gc + 1 end
        mp_log("TICK_ALIVE #" .. KCD2MP._tickN .. " ghosts=" .. gc)
    end

    -- Fetch player position once per tick for label distance calculations.
    local _playerPos = nil
    if player then pcall(function() _playerPos = player:GetWorldPos() end) end

    for id, ghost in pairs(KCD2MP.ghosts) do
        local _ok, _err = pcall(function()  -- catch any crash, keep tick alive
        local istate = ghost.istate
        if istate and ghost.entity then
            istate.ticksSincePacket = istate.ticksSincePacket + 1

            -- If ghost drifted very far from target (>5m), teleport directly.
            -- Prevents STEP_CAP from locking ghost hundreds of meters away.
            local distSq = (istate.tx-istate.cx)*(istate.tx-istate.cx)
                         + (istate.ty-istate.cy)*(istate.ty-istate.cy)
                         + (istate.tz-istate.cz)*(istate.tz-istate.cz)
            if distSq > 25.0 then
                mp_log(string.format("TELEPORT id=%s dist=%.1f", id, math.sqrt(distSq)))
                istate.cx = istate.tx
                istate.cy = istate.ty
                istate.cz = istate.tz
                istate.cr = istate.tr
            end

            -- Non-destructive DR: project render target forward WITHOUT touching istate.tx/ty.
            -- istate.tx/ty stays = last received packet. When next packet arrives it's
            -- simply overwritten - no snap-back rubber-band.
            -- DR just makes the ghost look ahead of the last-known position while waiting
            -- for the next packet, keeping movement smooth at sprint speeds.
            local renderX = istate.tx or istate.cx
            local renderY = istate.ty or istate.cy
            local DR_MAX = 3  -- 3 * 20ms = 60ms lookahead (covers 50ms packet gap)
            local ticks = istate.ticksSincePacket or 0
            if ticks >= 1 and ticks <= DR_MAX then
                local vx = istate.vx or 0
                local vy = istate.vy or 0
                if math.sqrt(vx*vx + vy*vy) > 0.5 then
                    renderX = renderX + vx * (ticks * 0.020)
                    renderY = renderY + vy * (ticks * 0.020)
                end
            end

            -- Smooth ghost toward render target (DR-extended, never snaps back)
            local factor = 0.5
            local prevCx = istate.cx
            local prevCy = istate.cy
            local nx = lerpVal(istate.cx, renderX, factor)
            local ny = lerpVal(istate.cy, renderY, factor)
            local nz = istate.tz or istate.cz   -- Z tracks packet directly, no lerp (avoids sinking into rocks)

            istate.cx = nx
            istate.cy = ny
            istate.cz = nz
            istate.cr = lerpAngle(istate.cr, istate.tr, factor)

            local x = istate.cx
            local y = istate.cy
            local z = istate.cz
            local r = istate.cr

            -- Floor snap: correct ghost Z against raycast floor.
            -- Snap-UP: underground up to 10m (handles slopes, slight embedding).
            -- Snap-DOWN: hovering up to 2m (hover fix; >2m cap prevents snapping off bridges).
            -- Skip floor snap when riding: horse engine handles terrain, NPC follows horse.
            local sz = z
            if not istate.isRiding then
                local floorZ, reliable = getFloorZ(x, y, z)
                if floorZ then
                    local diff = sz - floorZ
                    if diff < -0.05 and diff > -10.0 then
                        -- Underground up to 10m: snap up to floor
                        sz = floorZ
                        istate.cz = floorZ
                    elseif diff > 0.05 and diff < 2.0 then
                        -- Hovering up to 2m above floor: snap down
                        sz = floorZ
                    end
                end
            end

            -- When nativeMounted, the engine links NPC to horse - skip manual NPC SetWorldPos.
            -- We only update horse position; rider follows automatically.
            local ok = true
            if not istate.nativeMounted then
                local _, err = pcall(function()
                    ghost.entity:SetWorldPos({x=x, y=y, z=sz})
                    ghost.entity:SetWorldAngles({x=0, y=0, z=r})
                end)
                if err then
                    System.LogAlways("[KCD2-MP] InterpTick err '" .. id .. "': " .. tostring(err))
                    ghost.entity = nil
                    ok = false
                end
            end
            if ok then
                -- Speed from rendered XY movement this tick
                local movedDx = nx - prevCx
                local movedDy = ny - prevCy
                local rendSpeed = math.sqrt(movedDx*movedDx + movedDy*movedDy) / 0.020
                istate.smoothedSpeed = lerpVal(istate.smoothedSpeed or 0, rendSpeed, 0.4)

                if istate.isRiding then
                    -- One-time riding diagnostic when interp tick first sees this ghost riding.
                    -- (% 50 == 1 never fires: interp=20ms, packets=10ms → only even counts seen)
                    if not istate._rideFirstTick then
                        istate._rideFirstTick = true
                        local hd = KCD2MP.horseGhosts[id]
                        local hasAI = false
                        pcall(function() hasAI = hd and hd.entity and hd.entity.AI ~= nil end)
                        mp_log(string.format("RIDE_FIRST id=%s hasHorse=%s hasAI=%s",
                            id, tostring(hd ~= nil), tostring(hasAI)))
                    end
                    -- Probe valid riding animations once (on first ghost that is riding).
                    if KCD2MP._ridingIdleAnim == nil then
                        KCD2MP._ridingIdleAnim = findAnim(ghost.entity, RIDING_IDLE_ANIMS) or false
                        mp_log("RideIdleAnim: " .. tostring(KCD2MP._ridingIdleAnim))
                    end
                    if KCD2MP._ridingGallopAnim == nil then
                        KCD2MP._ridingGallopAnim = findAnim(ghost.entity, RIDING_GALLOP_ANIMS) or false
                        mp_log("RideGallopAnim: " .. tostring(KCD2MP._ridingGallopAnim))
                    end

                    -- Engine sync auto-assigns idle rider anim at ForceMount time.
                    -- For gallop we must set it explicitly — engine does NOT auto-update.
                    -- ridingFallback: engine failed to mount, set all anims manually.
                    local isGallop = rendSpeed > 3.0
                    if istate.nativeMounted then
                        -- Only override for gallop; leave idle to engine sync system.
                        if isGallop and KCD2MP._ridingGallopAnim then
                            pcall(function()
                                ghost.entity:StartAnimation(0, KCD2MP._ridingGallopAnim, 0, 0.3, 1.0, true)
                            end)
                        end
                    else
                        local rideAnim = (isGallop and KCD2MP._ridingGallopAnim)
                                      or KCD2MP._ridingIdleAnim
                        if rideAnim then
                            pcall(function()
                                ghost.entity:StartAnimation(0, rideAnim, 0, 0.3, 1.0, true)
                            end)
                        end
                    end

                    -- Horse entity origin = ground level (~1.5m below rider/saddle).
                    -- getFloorZ from sz can hit the horse's own physics body (rigid) and return
                    -- a Z close to sz, putting the horse on top of the NPC ghost.
                    -- Fix: use sz-1.5 as default; only accept raycast if it finds ground
                    -- at least 0.5m below saddle (rules out horse/player body hits).
                    local horseGroundZ = sz - 1.5
                    local hFloorZ, _ = getFloorZ(x, y, sz)
                    if hFloorZ and (sz - hFloorZ) >= 0.5 then
                        horseGroundZ = hFloorZ
                    end
                    local horseData = KCD2MP.horseGhosts[id]
                    if horseData and horseData.entity then
                        local dt = 0.020
                        local vx = (x - (horseData.lastX or x)) / dt
                        local vy = (y - (horseData.lastY or y)) / dt
                        local spd = math.sqrt(vx*vx + vy*vy)
                        horseData.lastX = x
                        horseData.lastY = y

                        -- Smooth horse Z and rotation to remove raycast noise / snap artifacts
                        if not horseData.smoothZ then horseData.smoothZ = horseGroundZ end
                        horseData.smoothZ = lerpVal(horseData.smoothZ, horseGroundZ, 0.25)
                        if not horseData.smoothR then horseData.smoothR = r end
                        horseData.smoothR = lerpAngle(horseData.smoothR, r, 0.35)
                        local hz = horseData.smoothZ
                        local hr = horseData.smoothR

                        -- Probe horse entity animations once.
                        if KCD2MP._horseEntityIdleAnim == nil then
                            KCD2MP._horseEntityIdleAnim = findAnim(horseData.entity, HORSE_ENTITY_IDLE_ANIMS) or false
                            mp_log("HorseEntityIdleAnim: " .. tostring(KCD2MP._horseEntityIdleAnim))
                        end
                        if KCD2MP._horseEntityWalkAnim == nil then
                            KCD2MP._horseEntityWalkAnim = findAnim(horseData.entity, HORSE_ENTITY_WALK_ANIMS) or false
                            mp_log("HorseEntityWalkAnim: " .. tostring(KCD2MP._horseEntityWalkAnim))
                        end
                        if KCD2MP._horseEntityGallopAnim == nil then
                            KCD2MP._horseEntityGallopAnim = findAnim(horseData.entity, HORSE_ENTITY_GALLOP_ANIMS) or false
                            mp_log("HorseEntityGallopAnim: " .. tostring(KCD2MP._horseEntityGallopAnim))
                        end

                        -- Store render target for 8ms render loop (avoids 20ms stutter).
                        horseData.renderX = x
                        horseData.renderY = y
                        horseData.renderZ = hz
                        horseData.renderR = hr

                        -- Play horse entity animation based on speed.
                        -- relaxed_idle → engine sync assigns matching rider idle.
                        -- relaxed_gallop → we explicitly set rider gallop above.
                        local horseAnim
                        if spd > 3.0 then
                            horseAnim = KCD2MP._horseEntityGallopAnim or KCD2MP._horseEntityWalkAnim
                        elseif spd > 0.5 then
                            horseAnim = KCD2MP._horseEntityWalkAnim or KCD2MP._horseEntityGallopAnim
                        else
                            horseAnim = KCD2MP._horseEntityIdleAnim
                        end
                        if horseAnim then
                            pcall(function()
                                horseData.entity:StartAnimation(0, horseAnim, 0, 0.2, 1.0, true)
                            end)
                        end
                    end
                    -- NPC ghost Z = sz = packet player Z = saddle height (correct).
                    -- Already set above in the nativeMounted block. No extra offset needed.
                else
                    KCD2MP_UpdateAnimation(id, ghost)
                end

                -- Update label cache for the render loop (runs at 8ms to avoid flicker).
                -- When riding: sz = saddle height, head ~1.3m above saddle.
                -- When on foot: sz = feet, head ~1.8m above feet.
                local displayName = KCD2MP.ghostNames[id] or ("Player" .. tostring(id))
                -- WO-13 Phase 2: a player in a menu is standing perfectly still
                -- and not responding, which reads as broken. Say so instead.
                -- No pose work needed -- KCD2MP_UpdateAnimation already settles
                -- a stationary ghost into its idle animation on its own.
                if KCD2MP.ghostInMenu[id] then
                    displayName = displayName .. " [in menu]"
                end
                local labelZ = sz + (istate.isRiding and 1.1 or 1.8)
                local labelSize = 0  -- 0 = hidden (too far)
                if _playerPos then
                    local dx = x - _playerPos.x
                    local dy = y - _playerPos.y
                    local dz = labelZ - _playerPos.z
                    local dist = math.sqrt(dx*dx + dy*dy + dz*dz)
                    if dist <= 60.0 then
                        labelSize = math.max(0.3, math.min(2.0, 10.0 / math.max(dist, 1.0)))
                    end
                end
                KCD2MP.labelCache[id] = {x=x, y=y, z=labelZ, size=labelSize, name=displayName}
            end
        end
        end)  -- end pcall for ghost update
        if not _ok then
            mp_log("InterpTick ERR id=" .. tostring(id) .. ": " .. tostring(_err))
        end
    end

    -- Update local player riding state every 5 ticks (~100ms)
    if KCD2MP._ridingCheckTick == nil then KCD2MP._ridingCheckTick = 0 end
    KCD2MP._ridingCheckTick = KCD2MP._ridingCheckTick + 1
    if KCD2MP._ridingCheckTick >= 5 then
        KCD2MP._ridingCheckTick = 0
        if player then
            local riding = false
            -- Method 0: Find "Horse" class entity within 2.5m of player.
            -- When riding, horse origin is ~1.5m below saddle (player pos).
            -- Exclude our own ghost horses (kcd2mp_horse_*) to avoid false positives.
            pcall(function()
                local pos = player:GetWorldPos()
                if pos then
                    local ents = System.GetEntitiesInSphere(pos, 2.5)
                    if ents then
                        for _, e in ipairs(ents) do
                            local ec = "?"
                            local en = ""
                            pcall(function() ec = tostring(e.class or "?") end)
                            pcall(function() en = tostring(e:GetName() or "") end)
                            if ec == "Horse" and not en:find("kcd2mp_horse_") then
                                -- Require player to be >1.0m ABOVE horse pivot.
                                -- Horse entity pivot is at ground level; when mounted,
                                -- player Z = saddle height (~1.5m above ground).
                                -- Filters false positives when merely standing next to horse.
                                local horsePos = nil
                                pcall(function() horsePos = e:GetWorldPos() end)
                                if horsePos and (pos.z - horsePos.z) > 1.0 then
                                    riding = true
                                end
                            end
                        end
                    end
                end
            end)
            -- Method 1: KCD2 human:IsRiding() (returns nil in v1.5, kept as fallback)
            if not riding then
                pcall(function()
                    if player.human then
                        local r = player.human:IsRiding()
                        if r then riding = true end
                    end
                end)
            end
            -- Method 2: CryEngine linked parent
            if not riding then
                pcall(function()
                    local p = player:GetLinkedParent()
                    if p then riding = true end
                end)
            end
            KCD2MP.isRiding = riding
        end
    end

end

-- ===== Main Tick (500ms) - position reporting =====

function KCD2MP_Tick()
    KCD2MP.tickCount = KCD2MP.tickCount + 1
    local ok, err = pcall(function()
        KCD2MP_WritePos()

        if KCD2MP.tickCount % 20 == 0 then
            local ghostCount = 0
            for _ in pairs(KCD2MP.ghosts) do ghostCount = ghostCount + 1 end
            System.LogAlways(string.format("[KCD2-MP] tick=%d ghosts=%d",
                KCD2MP.tickCount, ghostCount))
        end
    end)
    if not ok then
        System.LogAlways("[KCD2-MP] Tick error: " .. tostring(err))
    end
    if KCD2MP.running then
        Script.SetTimer(500, KCD2MP_Tick)
    end
end

-- ===== Ghost Remove =====

function KCD2MP_RemoveGhost(id)
    local ghost = KCD2MP.ghosts[id]
    if not ghost then return end
    -- Remove horse ghost first (if riding)
    KCD2MP_RemoveHorse(id)
    if ghost.entityId then
        pcall(function() System.RemoveEntity(ghost.entityId) end)
    end
    KCD2MP.ghosts[id] = nil
    KCD2MP.labelCache[id] = nil
    -- A player who disconnects while in a menu must not leave a stale
    -- "[in menu]" tag behind for whoever next reuses this ghost id (WO-13).
    KCD2MP.ghostInMenu[id] = nil
    System.LogAlways("[KCD2-MP] Removed ghost: " .. id)
    -- Reset riding anim probes: if they were cached while NPC was ForceMount'd they may be
    -- wrong (false). Re-probe on next riding ghost (free NPC → correct results).
    KCD2MP._ridingIdleAnim = nil
    KCD2MP._ridingGallopAnim = nil
end

function KCD2MP_RemoveAllGhosts()
    local count = 0
    for id, _ in pairs(KCD2MP.ghosts) do
        KCD2MP_RemoveGhost(id)
        count = count + 1
    end
    -- Clean up any orphaned horse ghosts
    for id, _ in pairs(KCD2MP.horseGhosts) do
        KCD2MP_RemoveHorse(id)
    end
    System.LogAlways("[KCD2-MP] Removed " .. count .. " ghosts")
end

-- ===== Start / Stop =====

function KCD2MP_Start()
    if KCD2MP.running then
        System.LogAlways("[KCD2-MP] Already running")
        return
    end
    KCD2MP.running = true
    KCD2MP.tickCount = 0
    System.LogAlways("[KCD2-MP] Starting (pos tick=500ms, interp tick=50ms)")
    Script.SetTimer(500, KCD2MP_Tick)
    KCD2MP_StartInterp()
end

function KCD2MP_Stop()
    KCD2MP.running = false
    KCD2MP.interpRunning = false
    KCD2MP.labelRunning = false
    KCD2MP.labelCache = {}
    KCD2MP_RemoveAllGhosts()
    System.LogAlways("[KCD2-MP] Stopped")
end

-- ===== Test / Inspect =====

function KCD2MP_SpawnTest()
    if not player then return end
    local pos = player:GetWorldPos()
    if not pos then return end

    local ang = nil
    pcall(function() ang = player:GetWorldAngles() end)
    local ox, oy = 3, 0
    if ang then
        ox = math.sin(ang.z) * 3
        oy = math.cos(ang.z) * 3
    end

    KCD2MP_SpawnGhost("test_ghost", pos.x + ox, pos.y + oy, pos.z, ang and ang.z or 0)
end

function KCD2MP_InspectGhost()
    local ghost = nil
    for _, g in pairs(KCD2MP.ghosts) do ghost = g; break end
    if not ghost or not ghost.entity then
        System.LogAlways("[KCD2-MP] No ghost. Run mp_spawn_test first.")
        return
    end

    local ent = ghost.entity
    local istate = ghost.istate
    System.LogAlways("[KCD2-MP] === GHOST INSPECT ===")
    pcall(function() System.LogAlways("[KCD2-MP] name=" .. tostring(ent:GetName())) end)
    pcall(function() System.LogAlways("[KCD2-MP] class=" .. tostring(ent.class)) end)
    if istate then
        System.LogAlways(string.format("[KCD2-MP] interp: alpha=%.3f step=%.3f ticksSince=%d packets=%d",
            istate.alpha, istate.alphaStep, istate.ticksSincePacket, istate.packetCount))
        System.LogAlways(string.format("[KCD2-MP] prev=%.1f,%.1f,%.1f  target=%.1f,%.1f,%.1f  cur=%.1f,%.1f,%.1f",
            istate.px, istate.py, istate.pz,
            istate.tx, istate.ty, istate.tz,
            istate.cx, istate.cy, istate.cz))
        System.LogAlways(string.format("[KCD2-MP] velocity=%.2f,%.2f,%.2f u/s",
            istate.vx, istate.vy, istate.vz))
    end
    pcall(function()
        local pos = ent:GetWorldPos()
        System.LogAlways(string.format("[KCD2-MP] entity pos=%.2f,%.2f,%.2f", pos.x, pos.y, pos.z))
    end)
    System.LogAlways("[KCD2-MP] === END ===")
end

-- ===== Discovery helpers (unchanged) =====

function KCD2MP_FindNPCs()
    System.LogAlways("[KCD2-MP] === FINDING HUMAN NPCs ===")
    if not player then return end

    local ppos = player:GetWorldPos()

    local ok, err = pcall(function()
        local ents = System.GetEntitiesInSphere(ppos, 100)
        if not ents then return end

        local npcCount = 0
        for _, ent in ipairs(ents) do
            local hasChar = false
            pcall(function() hasChar = ent:IsSlotCharacter(0) end)

            if hasChar then
                local isHuman = false
                pcall(function()
                    if ent.soul or ent.human or ent.actor then isHuman = true end
                end)

                if isHuman then
                    local name = "?"
                    local eclass = "?"
                    pcall(function() name = ent:GetName() end)
                    pcall(function() eclass = ent.class or "?" end)

                    npcCount = npcCount + 1
                    System.LogAlways(string.format("[KCD2-MP] NPC: name=%s class=%s",
                        tostring(name), tostring(eclass)))

                    if npcCount >= 10 then
                        System.LogAlways("[KCD2-MP] ... (first 10 only)")
                        break
                    end
                end
            end
        end

        System.LogAlways("[KCD2-MP] Found " .. npcCount .. " human NPCs within 100m")
    end)
    if not ok then
        System.LogAlways("[KCD2-MP] FindNPCs error: " .. tostring(err))
    end
    System.LogAlways("[KCD2-MP] === END ===")
end

-- ===== Animation Discovery =====

-- Probe animation names - only GetAnimationLength > 0 is reliable
function KCD2MP_ProbeAnims()
    local ghost = nil
    for _, g in pairs(KCD2MP.ghosts) do ghost = g; break end
    if not ghost or not ghost.entity then
        System.LogAlways("[KCD2-MP] ProbeAnims: no ghost.")
        return
    end
    local ent = ghost.entity

    -- Full CryEngine path variants (no extension) + short names
    local candidates = {
        -- Short names
        "idle", "run", "walk", "sprint", "jog",
        "Idle", "Run", "Walk", "Sprint",
        -- Full path guesses (KCD2 convention)
        "animations/humans/male/locomotion/run_loop",
        "animations/humans/male/locomotion/walk_loop",
        "animations/humans/male/locomotion/idle_loop",
        "animations/humans/male/locomotion/run_fwd",
        "animations/humans/male/locomotion/walk_fwd",
        "animations/humans/male/locomotion/sprint_loop",
        "animations/humans/male/locomotion/run",
        "animations/humans/male/locomotion/walk",
        "animations/humans/male/locomotion/idle",
        -- KCD1-style paths
        "animations/characters/humans/male/locomotion/run_loop",
        "animations/characters/humans/male/locomotion/walk_loop",
        "animations/characters/humans/male/locomotion/idle_loop",
        -- Assets subfolder
        "animations/assets/humans/locomotion/run_loop",
        "animations/assets/humans/locomotion/walk_loop",
        -- Mannequin fragment names
        "MotionIdle", "MotionRun", "MotionWalk",
        "LocomotionIdle", "LocomotionRun", "LocomotionWalk",
        "Locomotion", "locomotion",
    }

    System.LogAlways("[KCD2-MP] === PROBING ANIMS ON GHOST ===")
    for _, name in ipairs(candidates) do
        local len = 0
        pcall(function() len = ent:GetAnimationLength(0, name) or 0 end)
        if len > 0 then
            System.LogAlways(string.format("[KCD2-MP] HIT: '%s' len=%.3f", name, len))
        end
    end
    System.LogAlways("[KCD2-MP] === END ===")
end

-- ===== Real Horse Scanner =====
-- Scans a real KCD2 horse NPC within 20m to discover animation names, AI methods,
-- horse.horse component API, rider linkage, etc. Helps calibrate ghost horse behavior.
function KCD2MP_ScanNearbyHorse()
    if not player then
        System.LogAlways("[KCD2-MP] ScanHorse: no player")
        return
    end
    local ppos = player:GetWorldPos()
    System.LogAlways("[KCD2-MP] === SCAN NEARBY HORSE ===")

    local ents = nil
    pcall(function() ents = System.GetEntitiesInSphere(ppos, 20) end)
    if not ents then
        System.LogAlways("[KCD2-MP] GetEntitiesInSphere failed")
        return
    end

    local animCandidates = {
        "idle","walk","trot","canter","gallop","run","stand",
        "idle_loop","walk_loop","trot_loop","canter_loop","gallop_loop","run_loop",
        "horse_idle","horse_walk","horse_trot","horse_canter","horse_gallop","horse_run",
        "horse_idle_loop","horse_walk_loop","horse_trot_loop","horse_gallop_loop",
        "horse_stand","horse_stand_idle","horse_rest",
        "horse_loco_idle","horse_loco_walk","horse_loco_trot","horse_loco_gallop",
        "animal_idle","animal_walk","animal_trot","animal_gallop","animal_run",
        "loco_idle","loco_walk","loco_run","loco_gallop","loco_trot",
        "act_idle","act_walk","act_run","act_gallop","act_trot",
        "mm_idle","mm_walk","mm_run","mm_gallop",
        "3d_idle","3d_walk","3d_run","3d_gallop","3d_trot",
        "relaxed_idle","relaxed_walk","relaxed_run",
        "stand_idle","stand_loop","rest_idle",
    }

    local found = 0
    for _, e in ipairs(ents) do
        local ec = "?"
        local en = ""
        pcall(function() ec = tostring(e.class or "?") end)
        pcall(function() en = tostring(e:GetName() or "") end)

        if ec == "Horse" and not en:find("kcd2mp_horse_") then
            found = found + 1
            System.LogAlways(string.format("[KCD2-MP] HORSE: name=%s id=%s", en, tostring(e.id)))

            -- Character file path (tells us the skeleton / animation set)
            pcall(function()
                local cf = e:GetCharacterFileName(0)
                System.LogAlways("[KCD2-MP] CharFile[0]: " .. tostring(cf))
            end)
            pcall(function()
                local cf = e:GetCharacterFileName(1)
                System.LogAlways("[KCD2-MP] CharFile[1]: " .. tostring(cf))
            end)

            -- Animation probe: slot 0 and slot 1
            local hits0, hits1 = {}, {}
            for _, nm in ipairs(animCandidates) do
                local l0 = 0; pcall(function() l0 = e:GetAnimationLength(0, nm) or 0 end)
                if l0 > 0 then hits0[#hits0+1] = nm .. "=" .. string.format("%.2f", l0) end
                local l1 = 0; pcall(function() l1 = e:GetAnimationLength(1, nm) or 0 end)
                if l1 > 0 then hits1[#hits1+1] = nm .. "=" .. string.format("%.2f", l1) end
            end
            System.LogAlways("[KCD2-MP] AnimSlot0: " .. (#hits0>0 and table.concat(hits0,", ") or "none"))
            System.LogAlways("[KCD2-MP] AnimSlot1: " .. (#hits1>0 and table.concat(hits1,", ") or "none"))

            -- horse.horse component
            local hc = nil; pcall(function() hc = e.horse end)
            if hc then
                local fns = {}
                pcall(function()
                    for k, v in pairs(hc) do
                        if type(v) == "function" then fns[#fns+1] = k end
                    end
                end)
                System.LogAlways("[KCD2-MP] horse.horse fns: " .. table.concat(fns, ", "))
                pcall(function() System.LogAlways("[KCD2-MP] HasRider: " .. tostring(e.horse:HasRider())) end)
                pcall(function() System.LogAlways("[KCD2-MP] IsMountable: " .. tostring(e.horse:IsMountable())) end)
            else
                System.LogAlways("[KCD2-MP] horse.horse = nil")
            end

            -- AI component methods
            local hasAI = false; pcall(function() hasAI = e.AI ~= nil end)
            System.LogAlways("[KCD2-MP] hasAI: " .. tostring(hasAI))
            if hasAI then
                local aiFns = {}
                pcall(function()
                    for k, v in pairs(e.AI) do
                        if type(v) == "function" then aiFns[#aiFns+1] = k end
                    end
                end)
                System.LogAlways("[KCD2-MP] AI fns: " .. table.concat(aiFns, ", "))
            end

            -- human / actor / soul
            pcall(function() System.LogAlways("[KCD2-MP] has human: " .. tostring(e.human ~= nil)) end)
            pcall(function() System.LogAlways("[KCD2-MP] has actor: " .. tostring(e.actor ~= nil)) end)
            pcall(function() System.LogAlways("[KCD2-MP] has soul: " .. tostring(e.soul ~= nil)) end)

            -- Properties
            pcall(function()
                if e.Properties then
                    local props = {}
                    for k, v in pairs(e.Properties) do
                        if type(v) ~= "table" then props[#props+1] = k .. "=" .. tostring(v) end
                    end
                    System.LogAlways("[KCD2-MP] Props: " .. table.concat(props, " | "))
                end
            end)

            if found >= 2 then break end
        end
    end

    if found == 0 then
        System.LogAlways("[KCD2-MP] No real horses within 20m (try within 20m of a horse NPC)")
    end
    System.LogAlways("[KCD2-MP] === END SCAN ===")
end

-- Find nearby HUMAN NPC and get their character model path, then copy to ghost
function KCD2MP_CopyNPCModel()
    if not player then return end
    local ppos = player:GetWorldPos()
    System.LogAlways("[KCD2-MP] === FIND HUMAN NPC + COPY MODEL ===")

    local ghost = nil
    for _, g in pairs(KCD2MP.ghosts) do ghost = g; break end
    if not ghost or not ghost.entity then
        System.LogAlways("[KCD2-MP] No ghost entity! Run server first.")
        return
    end

    local ok, err = pcall(function()
        local ents = System.GetEntitiesInSphere(ppos, 50)
        if not ents then return end

        local humanCount = 0
        for _, ent in ipairs(ents) do
            if ent ~= player then
                -- Must have soul or human (real human NPC, not horse/door/chest)
                local isHuman = false
                pcall(function()
                    isHuman = (ent.soul ~= nil) or (ent.human ~= nil)
                end)
                if not isHuman then
                    -- Also accept NPCs with actor table
                    pcall(function()
                        if ent.actor and ent.actor.__this then isHuman = true end
                    end)
                end

                if isHuman then
                    local ename = "?"
                    pcall(function() ename = ent:GetName() end)
                    local eclass = "?"
                    pcall(function() eclass = ent.class or "?" end)
                    System.LogAlways(string.format("[KCD2-MP] HUMAN NPC: %s (class=%s)", ename, eclass))
                    humanCount = humanCount + 1

                    -- Try to get character filename
                    local cdfPath = nil
                    pcall(function()
                        local ch = ent:GetCharacter(0)
                        if ch then
                            cdfPath = ch:GetFilePath()
                            System.LogAlways("[KCD2-MP]   GetCharacter(0):GetFilePath() = " .. tostring(cdfPath))
                        end
                    end)
                    pcall(function()
                        local fn = ent:GetCharacterFileName(0)
                        System.LogAlways("[KCD2-MP]   GetCharacterFileName(0) = " .. tostring(fn))
                        if fn and not cdfPath then cdfPath = fn end
                    end)
                    -- Check Properties for model path
                    pcall(function()
                        if ent.Properties then
                            for k, v in pairs(ent.Properties) do
                                if type(v) == "string" and #v > 3 then
                                    if k:lower():find("model") or k:lower():find("cdf") or
                                       k:lower():find("file") or k:lower():find("char") then
                                        System.LogAlways("[KCD2-MP]   Props." .. k .. " = " .. v)
                                        if not cdfPath then cdfPath = v end
                                    end
                                end
                            end
                        end
                    end)

                    -- Probe animations on this NPC
                    local animCandidates = {
                        "idle", "run", "walk", "sprint", "jog",
                        "Idle", "Run", "Walk", "Sprint",
                        "run_loop", "walk_loop", "idle_loop", "sprint_loop",
                        "run_fwd", "walk_fwd", "run01", "walk01", "idle01",
                        "mm_run_fwd", "mm_walk_fwd", "mm_idle",
                        "loco_run", "loco_walk", "loco_idle",
                        "act_run", "act_walk", "act_idle",
                    }
                    for _, aname in ipairs(animCandidates) do
                        local len = 0
                        pcall(function() len = ent:GetAnimationLength(0, aname) or 0 end)
                        if len > 0 then
                            System.LogAlways(string.format("[KCD2-MP]   ANIM HIT '%s' len=%.3f", aname, len))
                        end
                    end

                    -- If we found a CDF, try loading it onto ghost
                    if cdfPath and cdfPath ~= "" then
                        System.LogAlways("[KCD2-MP]   Loading CDF onto ghost: " .. cdfPath)
                        local loadOk, loadErr = pcall(function()
                            ghost.entity:LoadCharacter(0, cdfPath)
                        end)
                        System.LogAlways("[KCD2-MP]   LoadCharacter result: " .. tostring(loadOk) .. " " .. tostring(loadErr))

                        if loadOk then
                            -- Now probe ghost again
                            System.LogAlways("[KCD2-MP]   Re-probing ghost after CDF load:")
                            for _, aname in ipairs(animCandidates) do
                                local len = 0
                                pcall(function() len = ghost.entity:GetAnimationLength(0, aname) or 0 end)
                                if len > 0 then
                                    System.LogAlways(string.format("[KCD2-MP]   GHOST HIT '%s' len=%.3f", aname, len))
                                end
                            end
                        end
                    end

                    if humanCount >= 3 then break end
                end
            end
        end
        System.LogAlways("[KCD2-MP] Found " .. humanCount .. " human NPCs")
    end)
    if not ok then
        System.LogAlways("[KCD2-MP] Error: " .. tostring(err))
    end
    System.LogAlways("[KCD2-MP] === END ===")
end

-- Test AI.SetForcedNavigation on ghost (try to drive locomotion animation via AI)
function KCD2MP_TestAINav()
    local ghost = nil
    for _, g in pairs(KCD2MP.ghosts) do ghost = g; break end
    if not ghost then
        System.LogAlways("[KCD2-MP] TestAINav: no ghost")
        return
    end
    local eid = ghost.entityId
    System.LogAlways("[KCD2-MP] TestAINav: sending velocity {1,0,0} to entityId=" .. tostring(eid))

    -- Try passing velocity vector (tell AI it's moving forward)
    local ok1, e1 = pcall(function() AI.SetForcedNavigation(eid, {x=3, y=0, z=0}) end)
    System.LogAlways("[KCD2-MP]   SetForcedNavigation: " .. tostring(ok1) .. " " .. tostring(e1))

    local ok2, e2 = pcall(function() AI.SetSpeed(eid, 3) end)
    System.LogAlways("[KCD2-MP]   SetSpeed(3): " .. tostring(ok2) .. " " .. tostring(e2))

    local ok3, e3 = pcall(function() AI.Signal(0, 1, "OnMoveForward", eid) end)
    System.LogAlways("[KCD2-MP]   Signal OnMoveForward: " .. tostring(ok3) .. " " .. tostring(e3))
end

-- Deep scan: recursively list up to 3 levels, log files with .caf/.adb
function KCD2MP_ScanAnims()
    System.LogAlways("[KCD2-MP] === DEEP ANIM SCAN ===")

    local function scanDir(path, depth)
        local entries = nil
        pcall(function() entries = System.ScanDirectory(path) end)
        if not entries then return end
        for _, name in ipairs(entries) do
            local full = path .. "/" .. name
            -- Log CAF/ADB files immediately
            if name:find("%.caf$") or name:find("%.CAF$") then
                System.LogAlways("[KCD2-MP] CAF: " .. full)
            elseif name:find("%.adb$") or name:find("%.ADB$") then
                System.LogAlways("[KCD2-MP] ADB: " .. full)
            elseif depth < 3 then
                -- Recurse into subdirectory
                scanDir(full, depth + 1)
            end
        end
    end

    -- Scan humans animation tree
    scanDir("Animations/humans", 1)
    scanDir("Animations/assets", 1)
    scanDir("Animations/Mannequin/adb", 1)

    System.LogAlways("[KCD2-MP] === END DEEP SCAN ===")
end

-- Try AI.SetForcedNavigation to drive locomotion animation
-- dirX, dirY = movement direction (unit vector), speed = 0 to stop
function KCD2MP_SetGhostMovement(id, dirX, dirY, speed)
    local ghost = KCD2MP.ghosts[id]
    if not ghost or not ghost.entity then return end

    local eid = ghost.entityId
    if speed > 0 then
        -- Tell AI the entity is moving in this direction at this speed
        pcall(function() AI.SetSpeed(eid, speed) end)
        pcall(function()
            AI.SetForcedNavigation(eid, {x=dirX, y=dirY, z=0})
        end)
    else
        pcall(function() AI.SetForcedNavigation(eid, {x=0, y=0, z=0}) end)
        pcall(function() AI.SetSpeed(eid, 0) end)
    end
end

-- Read Mannequin ADB via CryEngine XML loader (reads from PAK)
function KCD2MP_ReadADB()
    System.LogAlways("[KCD2-MP] === READ ADB ===")

    local adbPaths = {
        "Animations/Mannequin/ADB/kcd_male_database.adb",
        "Animations/Mannequin/adb/kcd_male_database.adb",
        "animations/mannequin/adb/kcd_male_database.adb",
    }

    -- Try CryEngine XML loader (reads files from PAK virtual filesystem)
    for _, path in ipairs(adbPaths) do
        local node = nil
        local ok, err = pcall(function()
            node = System.LoadXMLFile(path)
        end)
        System.LogAlways("[KCD2-MP] LoadXMLFile(" .. path .. "): ok=" .. tostring(ok) .. " node=" .. tostring(node) .. " err=" .. tostring(err))
        if ok and node then
            System.LogAlways("[KCD2-MP] XML loaded! Walking nodes...")
            -- Walk XML tree looking for Fragment names
            local function walkNode(n, depth)
                if depth > 4 then return end
                local tag = ""
                local name = ""
                pcall(function() tag = n:getTag() end)
                pcall(function() name = n:getAttr("name") end)
                if name and name ~= "" then
                    System.LogAlways("[KCD2-MP] " .. string.rep("  ", depth) .. tag .. " name='" .. name .. "'")
                end
                local count = 0
                pcall(function() count = n:getChildCount() end)
                for i = 0, count - 1 do
                    local child = nil
                    pcall(function() child = n:getChild(i) end)
                    if child then walkNode(child, depth + 1) end
                end
            end
            walkNode(node, 0)
            System.LogAlways("[KCD2-MP] === END ===")
            return
        end
    end

    -- Fallback: ScanDirectory
    System.LogAlways("[KCD2-MP] LoadXMLFile failed for all paths. Scanning directories...")
    local dirs = {
        "Animations/Mannequin/ADB",
        "Animations/Mannequin/adb",
        "Animations/Mannequin/adb/adb",
    }
    for _, d in ipairs(dirs) do
        local entries = nil
        pcall(function() entries = System.ScanDirectory(d) end)
        if entries and #entries > 0 then
            System.LogAlways("[KCD2-MP] " .. d .. " -> " .. #entries .. " entries:")
            for i, e in ipairs(entries) do
                System.LogAlways("[KCD2-MP]   " .. e)
                if i > 30 then break end
            end
        else
            System.LogAlways("[KCD2-MP] " .. d .. " -> empty/nil")
        end
    end

    System.LogAlways("[KCD2-MP] === END ===")
end

-- Probe Mannequin animation tags on ghost via AI.SetAnimationTag
-- Tags drive which Mannequin fragments play (including locomotion)
function KCD2MP_ProbeAnimTags()
    local ghost = nil
    for _, g in pairs(KCD2MP.ghosts) do ghost = g; break end
    if not ghost then
        System.LogAlways("[KCD2-MP] ProbeAnimTags: no ghost")
        return
    end
    local eid = ghost.entityId
    System.LogAlways("[KCD2-MP] === PROBE ANIM TAGS ===")
    System.LogAlways("[KCD2-MP] entityId=" .. tostring(eid))

    -- Common Mannequin tag names for locomotion
    local tags = {
        "Moving", "moving", "Run", "run", "Walk", "walk",
        "Sprint", "sprint", "Locomotion", "locomotion",
        "Alert", "alert", "Relaxed", "relaxed",
        "InCombat", "Combat", "Idle", "idle",
        "Forward", "forward", "MoveForward",
        "Jogging", "Running", "Walking",
    }

    System.LogAlways("[KCD2-MP] Trying AI.SetAnimationTag:")
    for _, tag in ipairs(tags) do
        local ok, err = pcall(function()
            AI.SetAnimationTag(eid, tag)
        end)
        -- Log only errors or interesting results
        if not ok then
            System.LogAlways("[KCD2-MP]   tag='" .. tag .. "' ERROR: " .. tostring(err))
        else
            System.LogAlways("[KCD2-MP]   tag='" .. tag .. "' OK")
        end
    end

    -- Also try clearing tags
    pcall(function() AI.SetAnimationTag(eid, "") end)

    System.LogAlways("[KCD2-MP] === END ===")
end

-- Test the real animation names from ADB analysis
function KCD2MP_TestRunAnim()
    local ghost = nil
    for _, g in pairs(KCD2MP.ghosts) do ghost = g; break end
    if not ghost or not ghost.entity then
        System.LogAlways("[KCD2-MP] TestRunAnim: no ghost")
        return
    end
    local ent = ghost.entity
    local eid = ghost.entityId
    System.LogAlways("[KCD2-MP] === TEST REAL ANIM NAMES ===")

    local names = {
        "3d_relaxed_run_turn_strafe",
        "3d_relaxed_walk_turn_strafe",
        "relaxed_idle_both",
        "3d_armored_walk_turn_strafe",
        "3d_wounded_run_turn_strafe",
    }
    for _, name in ipairs(names) do
        local len = 0
        pcall(function() len = ent:GetAnimationLength(0, name) or 0 end)
        local started = false
        pcall(function() started = ent:StartAnimation(0, name) end)
        System.LogAlways(string.format("[KCD2-MP] '%s': len=%.3f started=%s",
            name, len, tostring(started)))
    end

    -- Also try AI tag "run"
    System.LogAlways("[KCD2-MP] Setting AI tag 'run'...")
    pcall(function() AI.SetAnimationTag(eid, "run") end)
    pcall(function() AI.SetSpeed(eid, 4) end)

    System.LogAlways("[KCD2-MP] === END ===")
end

-- ===== Terrain Debug =====

function KCD2MP_TerrainCheck()
    if not player then System.LogAlways("[KCD2-MP] TerrainCheck: no player"); return end
    local pos = player:GetWorldPos()
    if not pos then return end

    local ok, gz = pcall(function() return Terrain.GetElevation(pos.x, pos.y) end)
    System.LogAlways(string.format("[KCD2-MP] TerrainCheck: player pos=%.2f,%.2f,%.2f | Terrain.GetElevation=ok=%s gz=%s",
        pos.x, pos.y, pos.z, tostring(ok), tostring(gz)))

    -- Check ghost position vs terrain
    for id, ghost in pairs(KCD2MP.ghosts) do
        if ghost.entity then
            local gpos = nil
            pcall(function() gpos = ghost.entity:GetWorldPos() end)
            local tgz = nil
            if gpos then
                pcall(function() tgz = Terrain.GetElevation(gpos.x, gpos.y) end)
                System.LogAlways(string.format("[KCD2-MP] Ghost '%s': entity z=%.2f | terrain z=%s | diff=%s",
                    id, gpos.z, tostring(tgz), tgz and string.format("%.2f", gpos.z - tgz) or "?"))
            end
        end
    end
end

-- ===== Stance Probe =====

function KCD2MP_ProbeStance()
    if not player then System.LogAlways("[KCD2-MP] ProbeStance: no player"); return end
    System.LogAlways("[KCD2-MP] === STANCE PROBE ===")
    local s1, s2, s3 = nil, nil, nil
    local ok1 = pcall(function() s1 = player:GetStance() end)
    System.LogAlways("[KCD2-MP] GetStance() ok=" .. tostring(ok1) .. " val=" .. tostring(s1))
    local ok2 = pcall(function()
        if player.actor then
            s2 = player.actor.bSneaking
            System.LogAlways("[KCD2-MP] actor.bSneaking=" .. tostring(s2))
        else
            System.LogAlways("[KCD2-MP] actor=nil")
        end
    end)
    System.LogAlways("[KCD2-MP] === END ===")
end

-- ===== Spawn NPC with custom armor =====

-- Preset table (name -> {items, preset})
KCD2MP.armorPresets = {
    ghost = {
        items  = "00b7ed62-a7bd-4269-acfa-8d852366579b,10ff6d35-8c14-4871-8656-bdc3476d8b12",
        preset = "dc000001-0000-0000-0000-000000000000",
    },
    -- White/Red: LegsBrigandine04 + LegsPadded01 + knackersGloves + GambesonLong01
    -- + Brigandine10 + ArmPlate04 + CoifMail01 + BascinetVisor05 + BootsKnee03
    -- weapon: kkut_menhart preset (sermiry_longSwordMenhart)
    white_red = {
        items  = "a8b22da0-e42e-4d79-abe7-52e6eebad6eb"  -- LegsBrigandine04_m04_A5 (spodnie)
              .. ",cc1adb78-fa5a-45c9-be7b-b7b50e182cb3"  -- LegsPadded01_m02_C3 (nogawice)
              .. ",36a701ed-2144-452a-b113-385efba2c0d1"  -- rasuvUcen_knackersGloves
              .. ",46b051c4-d4e2-4f3a-8b88-e3f64dae4618"  -- GambesonLong01_m03_C3 (przeszywanica)
              .. ",1aadf1e5-c37b-41c3-bc65-354187022c91"  -- Brigandine10_m09_A5 (plate armor)
              .. ",a5322fcd-27b4-4f4e-bfbf-49c519c74c74"  -- ArmPlate04_m08_A5 (naramienniki)
              .. ",cfc1fd72-dbb7-49a4-8713-6acf215a72be"  -- CoifMail01_m02_C2 (coif mail)
              .. ",b6fe59ec-c854-402a-848e-a77f55661c19"  -- BascinetVisor05_m04_C4 (bascinet)
              .. ",a06cfbf0-3d59-4003-89d4-69a82eb735af", -- BootsKnee03_m01_C (buty)
        preset  = "dc000003-0000-0000-0000-000000000000",
        weapons = "af2dd849-92a4-4081-9955-0afcb861fcd5", -- kkut_menhart (sermiry_longSwordMenhart)
    },
    -- LegsPadded01(pikowane) + GambesonShort01 + CoifMail02 + MailShort01
    -- + Cuirass07 + ArmPlate04 + Gauntlets08 + LegsPlate03 + BascinetVisor04
    -- + longSwordDuel (inventory only) - no boots
    knight = {
        items  = "078e439b-1a5b-40ca-b009-d4abf6fcf810"  -- LegsPadded01_m07_C3 (pikowane)
              .. ",00b7ed62-a7bd-4269-acfa-8d852366579b"  -- GambesonShort01_m04_D2
              .. ",0b383bf7-a67b-4caa-9db8-501ed8d6aa9f"  -- CoifMail02_mPrague_B3
              .. ",0364c89d-ac13-44ef-94d5-22b4047e7a26"  -- MailShort01_m03_C4
              .. ",a8723887-ac6e-45a0-a6a4-0cf905716b6d"  -- Brigandine05_m04_C3 (silesian body)
              .. ",dcc178b9-ed1c-41c4-b2e7-ebda930e8af9"  -- BrigandineArm05_m11_B4 (silesian)
              .. ",2dd6ea92-4024-4113-97ed-6a23f19b39d9"  -- Gauntlets08_m01_B4
              .. ",1972ac07-f8e1-41f0-9fb4-cf115b0088ec"  -- LegsPlate03_m03_A5
              .. ",96841ac9-4cdc-41e7-a84e-d212389a0d71"  -- BascinetVisorScaring_m01_closed
              .. ",00cca9e3-8ef2-46db-8cbf-86ec51930919", -- longSwordDuel (inventory)
        preset = "dc000002-0000-0000-0000-000000000000",
    },
}

-- ===== WO-20 — deterministic face roster (guidSharedSoulId) =====
--
-- The appearance lever -- binding a spawned NPC's guidSharedSoulId spawn
-- property to a real soul's SharedSoulGuid, which makes the engine build a
-- full distinct head+body+hair+beard automatically -- is Jefferson25625's
-- find (AppearanceApi.md, github.com/DeepFriedDepp/kcd2-exports fork, used
-- with permission). Confirmed live against this project's own build
-- (docs/WO-20-faces.md), not trusted from their doc.
--
-- Their own soul_roster.lua (the actual 48-soul GUID list) was never
-- committed to the repo -- prose only, same pattern WO-18 found for their
-- whole C# stack. So this roster is our own: 48 real, hand-placed commoner
-- souls (24 male, 24 female), pulled live from this save's own SoulsByName
-- and spread across settlements for visual variety. SharedSoulGuid is the
-- authored, cross-session-stable key (NATIVE-PLUGIN-findings.md), so these
-- values hold regardless of which save or session picks them.
KCD2MP.faceRoster = {
    male = {
        {"tbuk_man_5",   "82d455d8-5a4c-4210-8cc4-b11c363bbd27"},
        {"tkop_man_1",   "f5587d56-3305-4138-99f9-5c3b7aeca709"},
        {"tkop_man_2",   "81a2ef00-57d1-4759-85a4-3f79d888dd63"},
        {"tneb_man_11",  "43b076df-4be8-f9d9-e2e4-dd5cafd0db96"},
        {"tneb_man_18",  "4a5baae4-2667-2892-178d-b47b10e562b3"},
        {"tpod_man_1",   "4e628918-2a38-c1ea-c786-2424123506ae"},
        {"tpod_man_5",   "4f45df7c-4667-77a0-a415-d03b0cd1e293"},
        {"tsem_man_21",  "4072c96a-3bb5-f744-078c-8ef89203a49c"},
        {"tsem_man_22",  "46356c7b-ab60-1377-e8e4-514c8a8dcfbb"},
        {"tsla_man_2",   "4166b913-6b12-1965-cbb6-509a49250ba6"},
        {"ttac_man_8",   "fd1af8c5-c500-4add-b0b6-6c0505fe80c2"},
        {"ttac_man_9",   "69dfede7-a999-43dd-9dfa-5bf0c5aefe01"},
        {"ttkc_man_26",  "cfa65480-f361-4cf8-80c5-1900b7846bc8"},
        {"ttkc_man_3",   "4b4c6520-21a6-6125-d814-564837f165a2"},
        {"ttro_man_30",  "40fd3055-48be-a9f5-de48-0b882695cca5"},
        {"ttro_man_59",  "7e4881d6-ffb7-416f-bbbe-49bc622747b2"},
        {"tvez_man_20",  "2f825ed0-1d9b-4df0-ad90-d6e2b136ce04"},
        {"tvez_man_21",  "4badc882-824c-407e-b823-059fa3e5df5b"},
        {"tvid_man_3",   "48ea5c5c-fcbb-6a90-be4d-8b7f7ad6a4ac"},
        {"tvid_man_7",   "6947a43f-30eb-49bd-9997-44396f01fcba"},
        {"tzda_man_6",   "94babc16-7944-4729-b13b-cdfb5e51da93"},
        {"tzda_man_9",   "aefb7006-ca4d-4d4e-b624-b351459806b4"},
        {"tzel_man_10",  "8158f557-018e-4016-95a4-024bb060bd18"},
        {"tzel_man_7",   "271ac033-a516-4928-b1f7-825bc57c46e3"},
    },
    female = {
        {"prepadeni_woman_1", "f9eeaaef-b0f7-437d-b5cc-043121267e87"},
        {"tpod_woman_3",      "cbea36af-a25c-4aa0-8ae4-d6b5a2fcc3f3"},
        {"tsem_woman_12",     "46ec6bf1-3bac-85d6-8ee7-f90b1b25a4a8"},
        {"tsem_woman_8",      "456dc2bd-1ede-2372-7ee7-fed064e80ea8"},
        {"tsem_woman_9",      "4187a4bf-c27a-dd4b-c348-7bec934968ad"},
        {"tsla_woman_1",      "4e9bdbd4-885f-b50b-3940-d9ff9a000382"},
        {"ttac_woman_3",      "48de9403-4fa6-32c3-7dd7-007ef5dc1489"},
        {"ttac_woman_4",      "49daaf6f-5119-420a-b7c6-33825b912bb3"},
        {"ttac_woman_7",      "ddf4ac93-d15d-4728-8083-16cf46f68444"},
        {"ttkc_woman_17",     "f9a94c81-d804-44ab-9d0e-9c4decefbcd0"},
        {"ttkc_woman_6",      "4763a986-8361-a712-61d9-bf6dd706ddb6"},
        {"ttkc_woman_9",      "7ac037fe-60ca-4212-a39f-0093cff270ba"},
        {"ttro_woman_10",     "ab87afbe-498c-42c3-ab3e-bef003b273be"},
        {"ttro_woman_11",     "1b21ebf4-0ccd-450e-b182-8703a01c6ff8"},
        {"ttro_woman_12",     "7759e6b2-6a88-4f30-a28f-bee35104370b"},
        {"tvez_woman_2",      "488e80ea-f98d-d0e1-8dc7-4359d4701b8d"},
        {"tvez_woman_3",      "00ec8c08-21d3-4f65-8c84-cf28958f0cde"},
        {"tvez_woman_5",      "9349eb0d-91e3-4f48-94bd-6ef73370036e"},
        {"tvid_woman_1",      "4bb85c62-b0f9-c430-27e5-2ecfd254df90"},
        {"tzda_woman_1",      "450fc04c-4a9d-a6c9-0af0-dc60678c39a9"},
        {"tzda_woman_4",      "e9cca65b-2a67-4b12-b892-673ffbcb61dc"},
        {"tzel_woman_1",      "4b80b89a-45f3-8861-ecc7-b67cc7c6f185"},
        {"tzel_woman_2",      "45032153-51cb-db4a-9ea0-69431518519a"},
        {"tzel_woman_3",      "499b3100-8025-ece1-c741-ef13d59db783"},
    },
}

-- djb2-style string hash. Pure +/*/% arithmetic, deliberately no bitwise
-- ops -- this mod's sandbox is stripped Lua 5.1, which has no bit library.
--
-- WO-20 correction, found live: this engine's embedded Lua uses 32-bit
-- FLOAT numbers, not doubles -- confirmed by probing KCD2MP_HashString with
-- a %2147483647 modulus (the obvious choice) and watching tostring(h) print
-- in scientific notation ("1.93453e+08") with the low digits already gone,
-- which then made "h % 2" parity flip unpredictably and sent every test
-- name to the same roster slot (or an out-of-range one). Float32 is only
-- exact for integers up to 2^24 (~16.7M), so every intermediate value here
-- is kept under a 65521 modulus (largest prime below 2^16) -- h*33 then
-- tops out around 2.16M, safely inside the exact range.
function KCD2MP_HashString(s)
    local h = 5381 % 65521
    for i = 1, #s do
        h = (h * 33 + string.byte(s, i)) % 65521
    end
    return h
end

-- Deterministic per-player face pick: same name key -> same soul, every
-- time, in this or any future session. Gender and the individual soul are
-- both derived from the same hash so one name always resolves to one look.
function KCD2MP_PickFaceForPlayer(nameKey)
    local h = KCD2MP_HashString(tostring(nameKey or ""))
    local isFemale = (h % 2) == 0
    local list = isFemale and KCD2MP.faceRoster.female or KCD2MP.faceRoster.male
    local idx = (math.floor(h / 2) % #list) + 1
    local pick = list[idx]
    return { className = isFemale and "NPC_Female" or "NPC", soulName = pick[1], guid = pick[2] }
end

-- Split "a,b,c" -> {"a","b","c"}, trims whitespace
local function splitCSV(s)
    local parts = {}
    for part in string.gmatch(s, "[^,]+") do
        local trimmed = part:match("^%s*(.-)%s*$")
        if trimmed and #trimmed > 0 then
            parts[#parts + 1] = trimmed
        end
    end
    return parts
end

-- Spawn NPC in front of player, add items to inventory, optionally equip via ClothingPreset.
-- items_csv    : comma-separated item GUIDs (inventory)
-- preset_guid  : ClothingPreset GUID for visual equip (must exist in clothing_preset__kdcmp.xml)
-- weapon_preset: WeaponPreset GUID (from weapon_preset.xml) - equips weapon in hand slot
function KCD2MP_SpawnArmoredNPC(items_csv, preset_guid, weapon_preset)
    if not player then
        System.LogAlways("[KCD2-MP] SpawnArmoredNPC: no player")
        return
    end
    local pos = player:GetWorldPos()
    if not pos then return end

    -- Spawn 3m in front of player
    local ox, oy = 3, 0
    local ang = nil
    pcall(function() ang = player:GetWorldAngles() end)
    if ang then
        ox = math.sin(ang.z) * 3
        oy = math.cos(ang.z) * 3
    end
    local spawnPos = {x = pos.x + ox, y = pos.y + oy, z = pos.z}

    KCD2MP.spawnCount = (KCD2MP.spawnCount or 0) + 1
    local npcName = "kcd2mp_npc_" .. KCD2MP.spawnCount

    System.LogAlways(string.format("[KCD2-MP] SpawnArmoredNPC '%s' at %.1f,%.1f,%.1f",
        npcName, spawnPos.x, spawnPos.y, spawnPos.z))

    local npc = nil
    local ok1, e1 = pcall(function()
        npc = System.SpawnEntity({class="NPC", name=npcName, position=spawnPos})
    end)
    if not ok1 or not npc then
        System.LogAlways("[KCD2-MP] SpawnArmoredNPC: SpawnEntity failed: " .. tostring(e1))
        return
    end
    System.LogAlways("[KCD2-MP] SpawnArmoredNPC: entityId=" .. tostring(npc.id))

    -- Visually equip via ClothingPreset FIRST (may reset inventory state)
    if preset_guid and preset_guid ~= "" then
        local ok2, e2 = pcall(function()
            npc.actor:EquipClothingPreset(preset_guid)
        end)
        System.LogAlways("[KCD2-MP] EquipClothingPreset " .. preset_guid
            .. ": ok=" .. tostring(ok2)
            .. (ok2 and "" or (" err=" .. tostring(e2))))
    end

    -- Add items to inventory AFTER preset (so preset cannot wipe them)
    local guids = (items_csv and items_csv ~= "") and splitCSV(items_csv) or {}
    System.LogAlways("[KCD2-MP] Adding " .. #guids .. " items to inventory")
    for i, guid in ipairs(guids) do
        local ok, e = pcall(function()
            local item = ItemManager.CreateItem(guid, 1, 1)
            npc.inventory:AddItem(item)
        end)
        System.LogAlways(string.format("[KCD2-MP]   item[%d] %s: ok=%s%s",
            i, guid, tostring(ok), ok and "" or (" err=" .. tostring(e))))
    end

    -- Equip weapon via WeaponPreset (visual + inventory, works for swords/shields)
    if weapon_preset and weapon_preset ~= "" then
        local ok3, e3 = pcall(function()
            npc.actor:EquipWeaponPreset(weapon_preset)
        end)
        System.LogAlways("[KCD2-MP] EquipWeaponPreset " .. weapon_preset
            .. ": ok=" .. tostring(ok3)
            .. (ok3 and "" or (" err=" .. tostring(e3))))

        -- Close visor after short delay using native console command
        -- pattern from VIA mod: closeVisorOn <entityName>
        local npcNameRef = npcName
        Script.SetTimer(800, function()
            pcall(function()
                System.ExecuteCommand("closeVisorOn " .. npcNameRef)
                System.LogAlways("[KCD2-MP] closeVisorOn " .. npcNameRef)
            end)
        end)
    end

    mp_log(string.format("SpawnArmoredNPC '%s' items=%d preset=%s weapons=%s",
        npcName, #guids, tostring(preset_guid or "none"), tostring(weapon_preset or "none")))
end

-- Spawn white/red armored NPC (uses XML preset dc000003 + weapon preset kkut_menhart)
function KCD2MP_SpawnWhiteRed()
    local p = KCD2MP.armorPresets.white_red
    KCD2MP_SpawnArmoredNPC(p.items, p.preset, p.weapons)
end

-- Spawn fully armored knight (all 6 pieces, uses XML preset dc000002)
function KCD2MP_SpawnKnight()
    local p = KCD2MP.armorPresets.knight
    KCD2MP_SpawnArmoredNPC(p.items, p.preset)
end

-- ===== Horse Diagnostics =====

-- Runs in MOD context (has access to Terrain, player, etc).
-- Writes result to sv_servername so probe_riding.ps1 can read it.
function KCD2MP_DiagRideDetect()
    if not player then
        System.SetCVar("sv_servername", "player=nil")
        return
    end
    local pos = player:GetWorldPos()
    if not pos then
        System.SetCVar("sv_servername", "GetWorldPos=nil")
        return
    end

    -- Find entities within 6m - list all classes to identify the horse
    local classes = {}
    pcall(function()
        local ents = System.GetEntitiesInSphere(pos, 6.0)
        if ents then
            for _, e in ipairs(ents) do
                if e ~= player then
                    local ec = "?"
                    local ep = nil
                    pcall(function() ec = tostring(e.class or "?") end)
                    if ec == "?" then pcall(function() ec = tostring(e:GetClass()) end) end
                    pcall(function() ep = e:GetWorldPos() end)
                    local d = ep and math.sqrt((ep.x-pos.x)^2+(ep.y-pos.y)^2+(ep.z-pos.z)^2) or 99
                    if d < 6 then
                        classes[#classes+1] = string.format("%s:%.1f", ec, d)
                    end
                end
            end
        end
    end)

    local clStr = table.concat(classes, " | ")
    if clStr == "" then clStr = "none" end
    -- Trim to fit CVar (max ~200 chars)
    if #clStr > 180 then clStr = clStr:sub(1,180) end
    System.SetCVar("sv_servername", clStr)
end

-- Probe ALL riding anim candidates on any ghost currently in riding state.
-- Shows which names have GetAnimationLength > 0.
-- Also tries to get current player animation name (for when player is on horse).
function KCD2MP_ProbeRidingAnims()
    -- Find first riding ghost
    local ghost = nil
    for _, g in pairs(KCD2MP.ghosts) do
        if g.istate and g.istate.isRiding then ghost = g; break end
    end
    -- Fall back to any ghost
    if not ghost then
        for _, g in pairs(KCD2MP.ghosts) do ghost = g; break end
    end
    if not ghost or not ghost.entity then
        System.LogAlways("[KCD2-MP] ProbeRidingAnims: no ghost. Spawn one first.")
        return
    end

    System.LogAlways("[KCD2-MP] === PROBE RIDING ANIMS ===")
    local ent = ghost.entity
    local allCandidates = {}
    for _, v in ipairs(RIDING_IDLE_ANIMS)   do allCandidates[#allCandidates+1] = v end
    for _, v in ipairs(RIDING_GALLOP_ANIMS) do allCandidates[#allCandidates+1] = v end
    -- Extra patterns
    local extras = {
        "horse", "Horse", "riding", "Riding", "mounted", "Mounted",
        "3d_horse", "3d_riding", "3d_mounted",
        "horse_walk", "horse_run", "horse_idle", "horse_gallop",
        "act_horse", "act_riding", "act_mounted",
        "loco_horse", "loco_riding",
    }
    for _, v in ipairs(extras) do allCandidates[#allCandidates+1] = v end

    local hits = 0
    for _, name in ipairs(allCandidates) do
        local len = 0
        pcall(function() len = ent:GetAnimationLength(0, name) or 0 end)
        if len > 0 then
            System.LogAlways(string.format("[KCD2-MP] RIDING HIT: '%s' len=%.3f", name, len))
            hits = hits + 1
        end
    end
    System.LogAlways(string.format("[KCD2-MP] Riding anims found: %d / %d tested", hits, #allCandidates))

    -- Also try to read the current animation name from player (if riding a horse right now)
    local ok, an = pcall(function()
        if player then
            local n = nil
            pcall(function() n = player:GetCurrentAnimationName(0) end)
            return n
        end
    end)
    System.LogAlways("[KCD2-MP] Player current anim: " .. tostring(an) .. " (useful if player is on horse)")
    System.LogAlways("[KCD2-MP] === END ===")
end

-- Find horse/animal entities near player and log their class names
function KCD2MP_FindHorses()
    if not player then System.LogAlways("[KCD2-MP] FindHorses: no player"); return end
    local ppos = player:GetWorldPos()
    System.LogAlways("[KCD2-MP] === FIND HORSES ===")

    local ok, err = pcall(function()
        local ents = System.GetEntitiesInSphere(ppos, 60)
        if not ents then System.LogAlways("[KCD2-MP] GetEntitiesInSphere returned nil"); return end

        local count = 0
        for _, ent in ipairs(ents) do
            if ent ~= player then
                local eclass = "?"
                local ename  = "?"
                pcall(function() eclass = tostring(ent.class or "?") end)
                pcall(function() ename  = tostring(ent:GetName()) end)

                -- Log anything that looks like it could be a horse or animal
                local lc = eclass:lower()
                local ln = ename:lower()
                if lc:find("horse") or lc:find("animal") or lc:find("mount") or lc:find("creature")
                   or ln:find("horse") or ln:find("roach") or ln:find("pebbles") or ln:find("animal")
                then
                    local pos = nil
                    pcall(function() pos = ent:GetWorldPos() end)
                    local dist = pos and math.sqrt((pos.x-ppos.x)^2+(pos.y-ppos.y)^2) or -1
                    System.LogAlways(string.format("[KCD2-MP] HORSE? class='%s' name='%s' dist=%.1fm",
                        eclass, ename, dist))
                    count = count + 1
                end
            end
        end

        -- Also just log ALL entity classes within 15m (to catch horses with unexpected class names)
        System.LogAlways("[KCD2-MP] --- All entities within 15m ---")
        for _, ent in ipairs(ents) do
            local eclass = "?"
            local ename  = "?"
            pcall(function() eclass = tostring(ent.class or "?") end)
            pcall(function() ename  = tostring(ent:GetName()) end)
            local pos = nil
            pcall(function() pos = ent:GetWorldPos() end)
            local dist = pos and math.sqrt((pos.x-ppos.x)^2+(pos.y-ppos.y)^2) or 99
            if dist < 15 then
                System.LogAlways(string.format("[KCD2-MP]   class='%s' name='%s' dist=%.1fm",
                    eclass, ename, dist))
            end
        end
        System.LogAlways(string.format("[KCD2-MP] Horse-like entities found: %d", count))
    end)
    if not ok then System.LogAlways("[KCD2-MP] FindHorses error: " .. tostring(err)) end
    System.LogAlways("[KCD2-MP] === END ===")
end

-- Force-spawn a horse using several class name guesses to find what works in KCD2
function KCD2MP_SpawnHorseTest()
    if not player then System.LogAlways("[KCD2-MP] SpawnHorseTest: no player"); return end
    local pos = player:GetWorldPos()
    if not pos then return end

    -- Offset 4m to the right of player
    local spawnPos = {x = pos.x + 4, y = pos.y, z = pos.z}

    local classes = {
        "Horse", "Animal", "HorseAnimal", "horse", "animal",
        "kcd_horse", "RPGHorse", "CreatureAnimal", "Creature",
    }

    System.LogAlways("[KCD2-MP] === SPAWN HORSE TEST ===")
    for _, cls in ipairs(classes) do
        local ok, ent = pcall(System.SpawnEntity, {
            class    = cls,
            position = spawnPos,
            name     = "kcd2mp_horsetest_" .. cls,
        })
        if ok and ent then
            System.LogAlways(string.format("[KCD2-MP] SUCCESS class='%s' entityId=%s", cls, tostring(ent.id)))
            -- Don't remove it - let user see which one appears in-game
        else
            System.LogAlways(string.format("[KCD2-MP] FAIL class='%s' err=%s", cls, tostring(ent)))
        end
    end
    System.LogAlways("[KCD2-MP] === END ===")
end

-- Log current riding detection state for the local player
function KCD2MP_RidingState()
    System.LogAlways("[KCD2-MP] === RIDING STATE ===")
    System.LogAlways("[KCD2-MP] KCD2MP.isRiding = " .. tostring(KCD2MP.isRiding))

    if not player then System.LogAlways("[KCD2-MP] player=nil"); return end

    -- Test method 1: human:IsRiding
    local ok1, r1 = pcall(function()
        if player.human then
            return player.human:IsRiding()
        end
        return "human=nil"
    end)
    System.LogAlways("[KCD2-MP] human:IsRiding() ok=" .. tostring(ok1) .. " val=" .. tostring(r1))

    -- Test method 2: GetLinkedParent
    local ok2, r2 = pcall(function() return player:GetLinkedParent() end)
    System.LogAlways("[KCD2-MP] GetLinkedParent() ok=" .. tostring(ok2) .. " val=" .. tostring(r2))

    -- Test method 3: soul state
    local ok3, r3 = pcall(function()
        if player.soul then return player.soul.bRiding end
        return "soul=nil"
    end)
    System.LogAlways("[KCD2-MP] soul.bRiding ok=" .. tostring(ok3) .. " val=" .. tostring(r3))

    -- Test method 4: actor mount
    local ok4, r4 = pcall(function()
        if player.actor then return player.actor:GetMount() end
        return "actor=nil"
    end)
    System.LogAlways("[KCD2-MP] actor:GetMount() ok=" .. tostring(ok4) .. " val=" .. tostring(r4))

    System.LogAlways("[KCD2-MP] === END ===")
end

function KCD2MP_GhostState()
    System.LogAlways("[KCD2-MP] === GHOST STATE ===")
    local count = 0
    for id, ghost in pairs(KCD2MP.ghosts) do
        count = count + 1
        local istate = ghost.istate or {}
        local horseData = KCD2MP.horseGhosts[id]
        System.LogAlways(string.format(
            "[KCD2-MP] Ghost id=%s isRiding=%s nativeMounted=%s ridingFallback=%s hasHorse=%s",
            tostring(id),
            tostring(istate.isRiding),
            tostring(istate.nativeMounted),
            tostring(istate.ridingFallback),
            tostring(horseData ~= nil)
        ))
        -- Check if NPC has .human and if IsMounted works
        if ghost.entity then
            local ok, mounted = pcall(function() return ghost.human and ghost.human:IsMounted() end)
            System.LogAlways("[KCD2-MP]   IsMounted ok=" .. tostring(ok) .. " val=" .. tostring(mounted))
            -- Check if horse entity exists
            if horseData and horseData.entity then
                local ok2, hasRider = pcall(function()
                    return horseData.entity.horse and horseData.entity.horse:HasRider()
                end)
                local ok3, isMountable = pcall(function()
                    return horseData.entity.horse and horseData.entity.horse:IsMountable()
                end)
                System.LogAlways("[KCD2-MP]   horse.HasRider ok=" .. tostring(ok2) .. " val=" .. tostring(hasRider))
                System.LogAlways("[KCD2-MP]   horse.IsMountable ok=" .. tostring(ok3) .. " val=" .. tostring(isMountable))
            end
        end
    end
    System.LogAlways("[KCD2-MP] Total ghosts=" .. count .. " horseGhosts=" .. (function()
        local n=0; for _ in pairs(KCD2MP.horseGhosts) do n=n+1 end; return n
    end)())
end

-- Test spawning entities via XGenAIModule with various class names.
-- Safe: each class wrapped in pcall, entity removed after 10s.
-- Usage: mp_test_xgen <ClassName>  (default: NullAI)
function KCD2MP_TestXGenSpawn(className)
    if not player then System.LogAlways("[KCD2-MP] TestXGenSpawn: no player"); return end
    local pos = player:GetWorldPos()
    if not pos then return end

    className = (className and className ~= "") and className or "NullAI"
    local testName = "kcd2mp_xgen_test"
    System.LogAlways("[KCD2-MP] TestXGenSpawn: trying ClassName=" .. className)

    -- Remove previous test entity if exists
    pcall(function()
        local old = System.GetEntityByName(testName)
        if old then System.RemoveEntity(old.id) end
    end)

    -- Try XGenAIModule.SpawnEntity
    local ok, err = pcall(function()
        local eid = XGenAIModule.SpawnEntity{
            Name      = testName,
            ClassName = className,
            Pos       = {pos.x + 2, pos.y, pos.z},
            Properties = { esFaction = "Civilians" },
        }
        System.LogAlways("[KCD2-MP] TestXGenSpawn: XGenAI returned eid=" .. tostring(eid))
        local ent = System.GetEntityByName(testName)
        if ent then
            System.LogAlways("[KCD2-MP] TestXGenSpawn: entity found id=" .. tostring(ent.id)
                .. " class=" .. tostring(ent.class))
            -- Check human/actor/horse sub-objects
            local hasSoul   = pcall(function() return ent.soul end)
            local hasHuman  = pcall(function() return ent.human end)
            local isMounted = pcall(function() return ent.human and ent.human:IsMounted() end)
            System.LogAlways("[KCD2-MP] TestXGenSpawn: hasSoul=" .. tostring(hasSoul)
                .. " hasHuman=" .. tostring(hasHuman)
                .. " IsMounted=" .. tostring(isMounted))
            -- Remove after 10s
            local eid2 = ent.id
            Script.SetTimer(10000, function()
                pcall(function() System.RemoveEntity(eid2) end)
                System.LogAlways("[KCD2-MP] TestXGenSpawn: removed test entity")
            end)
        else
            System.LogAlways("[KCD2-MP] TestXGenSpawn: entity NOT found by name after spawn")
        end
    end)
    if not ok then
        System.LogAlways("[KCD2-MP] TestXGenSpawn: CRASHED/ERROR: " .. tostring(err))
    end
end

-- ===== Register Console Commands =====

local ok, err = pcall(function()
    System.AddCCommand("mp_pos",         "KCD2MP_GetPos()",         "Get player position")
    System.AddCCommand("mp_start",       "KCD2MP_Start()",          "Start MP sync")
    System.AddCCommand("mp_stop",        "KCD2MP_Stop()",           "Stop MP sync")
    System.AddCCommand("mp_spawn_test",  "KCD2MP_SpawnTest()",      "Spawn test ghost")
    System.AddCCommand("mp_remove_all",  "KCD2MP_RemoveAllGhosts()","Remove all ghosts")
    System.AddCCommand("mp_inspect",     "KCD2MP_InspectGhost()",   "Inspect ghost interp state")
    System.AddCCommand("mp_find_npcs",   "KCD2MP_FindNPCs()",       "Find nearby human NPCs")
    System.AddCCommand("mp_probe_anims",   "KCD2MP_ProbeAnims()",    "Probe anim names on ghost (GetAnimationLength)")
    System.AddCCommand("mp_copy_npc",     "KCD2MP_CopyNPCModel()",  "Find human NPC, copy CDF to ghost, probe anims")
    System.AddCCommand("mp_scan_anims",   "KCD2MP_ScanAnims()",     "Scan animation directories")
    System.AddCCommand("mp_test_ai_nav",  "KCD2MP_TestAINav()",     "Test AI.SetForcedNavigation on ghost")
    System.AddCCommand("mp_read_adb",     "KCD2MP_ReadADB()",       "Read kcd_male_database.adb via CryEngine XML loader")
    System.AddCCommand("mp_probe_tags",   "KCD2MP_ProbeAnimTags()", "Probe Mannequin animation tags on ghost")
    System.AddCCommand("mp_test_run",     "KCD2MP_TestRunAnim()",   "Test 3d_relaxed_run_turn_strafe on ghost")
    System.AddCCommand("mp_terrain",      "KCD2MP_TerrainCheck()",  "Check player/ghost vs terrain height")
    System.AddCCommand("mp_probe_stance", "KCD2MP_ProbeStance()",   "Log player stance value (for crouch detection calibration)")
    System.AddCCommand("mp_sneak_on",     "KCD2MP.playerSneaking=true;System.LogAlways('[KCD2-MP] SNEAK ON (manual)')",  "Force ghost into sneak mode")
    System.AddCCommand("mp_sneak_off",    "KCD2MP.playerSneaking=false;System.LogAlways('[KCD2-MP] SNEAK OFF (manual)')", "Force ghost out of sneak mode")
    -- mp_spawn_armor <guid1,guid2,...>  -- inventory only (no visual unless preset given as 2nd arg)
    System.AddCCommand("mp_spawn_armor",  'KCD2MP_SpawnArmoredNPC("%LINE")',  "Spawn NPC with items: mp_spawn_armor guid1,guid2,...")
    System.AddCCommand("mp_spawn_knight",    "KCD2MP_SpawnKnight()",    "Spawn fully armored knight (BascinetVisor04+Cuirass07+Gauntlets08+LegsPlate03+MailLong01)")
    System.AddCCommand("mp_spawn_white_red", "KCD2MP_SpawnWhiteRed()", "Spawn white/red armored NPC (Brigandine10+BascinetVisor05+sword)")
    System.AddCCommand("mp_scan_horse",      "KCD2MP_ScanNearbyHorse()", "Scan real horse NPC within 20m: anims, AI fns, horse.horse API")
    System.AddCCommand("mp_find_horses",     "KCD2MP_FindHorses()",     "Find horse entities near player - shows class names")
    System.AddCCommand("mp_spawn_horse_test","KCD2MP_SpawnHorseTest()", "Force-spawn a horse at player position (class probe)")
    System.AddCCommand("mp_riding_state",    "KCD2MP_RidingState()",    "Log current riding detection state")
    System.AddCCommand("mp_emit_on",         "KCD2MP_StartEmitter()",   "Start [KCD2-MP-DATA] state emitter (WO-1 log transport)")
    System.AddCCommand("mp_emit_off",        "KCD2MP_StopEmitter()",    "Stop the state emitter")
    System.AddCCommand("mp_emit_once",       "KCD2MP_EmitState()",      "Emit a single state line")
    System.AddCCommand("mp_accept",          "KCD2MP_AcceptInvite()",   "Accept a pending interaction invite")
    System.AddCCommand("mp_decline",         "KCD2MP_DeclineInvite()",  "Decline a pending interaction invite")
    System.AddCCommand("mp_sync_appearance", "KCD2MP_SyncAppearance()", "Force an immediate appearance resync to peers (WO-9)")
    System.AddCCommand("mp_slow_time",       "KCD2MP_SlowTime()",       "Toggle manually broadcasting a paused/unavailable state to peers (WO-11 fallback)")
    System.AddCCommand("mp_invite",          'KCD2MP_InviteNearest("%LINE")', "Invite the nearest player: mp_invite dice|duel")
    System.AddCCommand("mp_ghost_state",     "KCD2MP_GhostState()",     "Dump all ghost riding/mount state")
    System.AddCCommand("mp_enable_aggro",    'KCD2MP_EnableAggro("%LINE")', "WO-17: opt-in NPC aggro on ghosts, this client only: mp_enable_aggro on|off")

    -- Dice overlay (WO-6). These console commands are the SUPPORTED path: the
    -- keybinds below them are unverified action-name guesses, exactly as WO-2's
    -- accept/decline were. Everything here is reachable without a working key.
    System.AddCCommand("mp_dice",        "KCD2MP_InviteDiceAtTable()", "Challenge the nearest player to dice -- only at a real dice table")
    System.AddCCommand("mp_dice_cast",   "KCD2MP_DiceConfirm()",       "Cast, or set aside the marked dice (depends on phase)")
    System.AddCCommand("mp_dice_mark",   'KCD2MP_DiceMark("%LINE")',   "Mark/unmark a die on the board: mp_dice_mark 1..6")
    System.AddCCommand("mp_dice_unmark_all", "KCD2MP_DiceUnmarkAll()", "Clear every pending mark without rerolling")
    System.AddCCommand("mp_dice_bank",   "KCD2MP_DiceBank()",          "Bank this hand and end thy turn")
    System.AddCCommand("mp_dice_yield",  "KCD2MP_DiceForfeit()",       "Yield the match")
    System.AddCCommand("mp_dice_close",  "KCD2MP_DiceClose()",         "Dismiss the dice board")
    System.AddCCommand("mp_dice_table",  "KCD2MP_ReportDiceTable()",   "Report the nearest dice table, for verifying table detection")
    System.AddCCommand("mp_dice_redraw", "KCD2MP_DiceRender()",        "Force the board to re-push (use if it ever goes stale)")
    System.AddCCommand("mp_dice_flush",  "KCD2MP_DiceFlush()",         "Clear every queued/shown tutorial panel -- fixes a stuck or flickering board")
    System.AddCCommand("mp_dice_scan",   'KCD2MP_ScanTables("%LINE")', "List nearby entity classes, to find a table's real class: mp_dice_scan 6")
    System.AddCCommand("mp_dice_seat",   "KCD2MP_ReportSeat()",        "Report the seat under you: distance, table id, teleport anchor")
    System.AddCCommand("mp_dice_gate",   'KCD2MP_DiceGate("%LINE")',   "Require a real table for mp_dice: mp_dice_gate on|off (default off for testing)")
    System.AddCCommand("mp_dice_demo",   "KCD2MP_DiceDemo()",          "Open the board with fake state, to review the visuals without a second player")
    System.AddCCommand("mp_test_xgen_nullai", 'KCD2MP_TestXGenSpawn("NullAI")', "Test XGenAIModule.SpawnEntity ClassName=NullAI")
    System.AddCCommand("mp_test_xgen_npc",    'KCD2MP_TestXGenSpawn("NPC")',    "Test XGenAIModule.SpawnEntity ClassName=NPC")
    System.AddCCommand("mp_test_xgen_horse",  'KCD2MP_TestXGenSpawn("Horse")',  "Test XGenAIModule.SpawnEntity ClassName=Horse")
    System.LogAlways("[KCD2-MP] Commands OK")
end)
if not ok then
    System.LogAlways("[KCD2-MP] Command error: " .. tostring(err))
end

-- ===== Sneak action handler (shared, installed by both hook paths) =====

-- Toggle-style sneak actions (each press flips state).
-- NOTE: chat_init_with_focus is NOT sneak – it's the focus/chat key (triggered by Tab/V).
-- Stance is detected via player:GetStance() polling in KCD2MP_Exchange (reliable fallback).
local SNEAK_TOGGLE_ACTIONS = {
    sneak_toggle=true, toggle_sneak=true,
}
-- Hold-style sneak: pressed=on, released=off (other games/bindings)
local SNEAK_HOLD_ACTIONS = {
    sneak=true, stealth=true, crouch=true,
    wh_sneak=true, wh_stealth=true,
    action_sneak=true, action_stealth=true,
    sneaking=true, stealth_mode=true,
}

-- Analog axis actions - ignore completely, they flood the log
local AXIS_ACTIONS = {
    combat_zone_mouse_x=true, combat_zone_mouse_y=true,
    mouse_x=true, mouse_y=true, look_lx=true, look_ly=true,
    move_lx=true, move_ly=true,
}

-- Accept/decline keybinds (WO-2).
--
-- These action names are UNVERIFIED GUESSES. The project rule is not to invent
-- API names, and the same applies to action ids, so the console commands
-- mp_accept / mp_decline are the supported path and these are a convenience that
-- may simply never fire. To find the real names: set KCD2MP.logActions = true,
-- press the key you want, and read the ACT lines out of kcd.log.
local ACCEPT_ACTIONS  = { ["dialog_answer1"] = true, ["confirm"] = true, ["ui_accept"] = true }
local DECLINE_ACTIONS = { ["dialog_answer2"] = true, ["cancel"] = true, ["ui_cancel"] = true }

-- Dice-invite keybind (WO-5). Same unverified-guess situation as accept/decline
-- above: not gated behind any of our own UI state (there is nothing to gate on
-- when *sending* an invite), so a wrong guess means this fires on whatever the
-- action really does elsewhere -- KCD2MP_InviteNearest is harmless to call
-- spuriously (worst case, an unwanted invite the other player just declines).
-- Picked from the same dialog_answerN family already accepted above rather
-- than a fresh guess, since dialog trees rarely go past two answers.
-- mp_invite dice is the verified, always-working fallback.
local DICE_INVITE_ACTIONS = { ["dialog_answer3"] = true, ["dialog_answer4"] = true }

-- Dice overlay keys (WO-6).
--
-- Second design. The first tried R/F/X/1-6 -- keys the game's OWN action map
-- already binds to something (toggle_torch, knock_out, call, action_qam_N) --
-- on the reasoning that our OnAction hook runs alongside the game's handler
-- and cannot consume input, so the key's normal side effect had to be
-- tolerable. Two things broke that plan in real play:
--   1. 1-6 also fires action_qam_N's WEAPON/food slot select, not just a
--      cosmetic toggle -- a live match drew a sword mid-game.
--   2. R (toggle_torch) turned out unreliable while seated -- exactly the
--      position this feature is for.
--
-- keybindSuperactions.xml (Libs/Config/, shipped in this mod's own pak) is
-- the actual fix: it is a plain, moddable XML action-map config, not
-- hardcoded, and a key can carry MULTIPLE named actions across different
-- `map=` contexts simultaneously. So instead of reusing an existing action
-- and hoping its side effect is harmless, this ships brand-new action names
-- (kcd2mp_dice_mark_1..6, kcd2mp_dice_cast, kcd2mp_dice_bank,
-- kcd2mp_dice_yield) on physical keys confirmed to have NOTHING else bound
-- to them anywhere in the file, so there is no side effect to tolerate at
-- all. map="interaction" was chosen because it was directly observed still
-- firing (use/talk/trigger_use) immediately after sitting down, unlike
-- "sitting"-shadowed actions.
--
-- Keys: F2, F4, F5, F6, F7, F8 mark dice 1-6 (see DICE_MARK_KEYS in the
-- panel code); F9 casts/sets aside; hold F11 banks; hold F12 yields; U
-- clears every pending mark without rerolling (KCD2MP_DiceUnmarkAll).
--
-- Four traps paid for finding these, none visible from this file alone:
--   1. Numpad 1-6 checked clean here (nothing else in this XML claims them)
--      but wasn't -- action_qam_N's weapon_slot_N sibling lives under
--      apse_qam_slots, which turned out to stay active during ordinary
--      play, not just with a menu open. Adding our own action to a key
--      never suppresses whatever else is already bound there.
--   2. The Numpad operator keys (*, +, -) and F1/F3/F10 are bound to
--      engine-level debug toggles (photo mode, flight mode, AI/animation
--      debug draw) entirely OUTSIDE this XML -- invisible to any check of
--      this file's contents. Numpad / is worse: it CRASHED the game.
--   3. H is also "clean" by this file's contents and is not safe either --
--      it opens a Modding Tools debug menu, same invisible-to-this-file
--      shape as trap 2. Every key actually used below was pressed live,
--      one at a time, and watched for anything happening at all -- that is
--      the only real proof; this file's contents are not enough on their
--      own, and neither is "nothing obviously bad happened" (Numpad 1-6).
--   4. Numpad . is a DIFFERENT kind of failure: not dangerous, just a dead
--      binding. "np_decimal" is not a control name this engine's action-map
--      recognises at all, so the whole entry silently never registers --
--      no crash, no debug menu, just nothing, indistinguishable at a glance
--      from a key that works but has nothing to do yet. Moved to U, which
--      is both unclaimed AND confirmed to actually fire once wired up.
--
-- Bank/yield tried U/Y briefly (to leave F11/F12 free for a future
-- invite-accept/decline bind) -- U/Y worked, but simplicity won: back on
-- F11/F12, which were already proven end-to-end, and U repurposed for
-- cancel instead of adding a fifth key family to the set.
--
-- All of these are gated on KCD2MP.dice.open, so none can fire outside a
-- match. The mp_dice_* console commands remain and always work.
local DICE_CONFIRM_ACTIONS = { ["kcd2mp_dice_cast"]  = true, ["toggle_torch"] = true }
local DICE_BANK_ACTIONS    = { ["kcd2mp_dice_bank"]  = true, ["knock_out"]    = true }  -- held
local DICE_YIELD_ACTIONS   = { ["kcd2mp_dice_yield"] = true, ["call"]         = true }  -- held
local DICE_CANCEL_ACTIONS  = { ["kcd2mp_dice_cancel"] = true }

-- Marking a die. kcd2mp_dice_mark_N's trailing digit is the die index, which
-- lines up with the numbered row drawn under the dice.
local function diceMarkIndex(action)
    local n = action:match("^kcd2mp_dice_mark_(%d)$")
    if n then
        local i = tonumber(n)
        if i and i >= 1 and i <= 6 then return i end
    end
    return nil
end

local function handleAction(action, activation, value)
    if AXIS_ACTIONS[action] then return end
    if KCD2MP.logActions then
        mp_log(string.format("ACT '%s' a=%s", tostring(action), tostring(activation)))
    end

    -- Only consume these while a prompt is actually up, so they never interfere
    -- with normal dialogue or menus.
    if KCD2MP.invite and activation == "press" then
        if ACCEPT_ACTIONS[action] then
            pcall(KCD2MP_AcceptInvite)
            return
        end
        if DECLINE_ACTIONS[action] then
            pcall(KCD2MP_DeclineInvite)
            return
        end
    end

    -- Dice overlay keys (WO-6). Checked BEFORE the invite key below, and every
    -- branch is gated on the board actually being open, so none of this can
    -- interfere with normal play -- or with an NPC dice game, which never opens
    -- this board.
    if KCD2MP.dice and KCD2MP.dice.open then
        if activation == "press" then
            local mark = diceMarkIndex(action)
            if mark then pcall(KCD2MP_DiceMark, mark); return end
            if DICE_CONFIRM_ACTIONS[action] then pcall(KCD2MP_DiceConfirm); return end
            if DICE_CANCEL_ACTIONS[action] then pcall(KCD2MP_DiceUnmarkAll); return end
            -- Bank and yield are irreversible, so they are hold-to-confirm:
            -- start the timer on press, and only KCD2MP_DiceHoldTick fires them.
            if DICE_BANK_ACTIONS[action]  then pcall(KCD2MP_DiceHoldBegin, "bank");    return end
            if DICE_YIELD_ACTIONS[action] then pcall(KCD2MP_DiceHoldBegin, "forfeit"); return end
        elseif activation == "release" then
            if DICE_BANK_ACTIONS[action] or DICE_YIELD_ACTIONS[action] then
                pcall(KCD2MP_DiceHoldEnd)
                return
            end
        end
    end

    -- Challenge the nearest player to dice (WO-5, gated to a real table in
    -- WO-6). Unlike accept/decline this has no KCD2MP.invite-style gate to
    -- check first -- see the comment on DICE_INVITE_ACTIONS above for why
    -- that's an accepted risk here. KCD2MP_InviteDiceAtTable refuses unless a
    -- DiceInteractor entity is actually in range, so a spurious press is now a
    -- no-op rather than an unwanted invite.
    if DICE_INVITE_ACTIONS[action] and activation == "press" then
        pcall(KCD2MP_InviteDiceAtTable)
        return
    end

    -- Toggle-style: each press of C flips sneak on/off
    if SNEAK_TOGGLE_ACTIONS[action] and activation == "press" then
        KCD2MP.playerSneaking = not KCD2MP.playerSneaking
        mp_log("SNEAK=" .. tostring(KCD2MP.playerSneaking) .. " toggle via '" .. action .. "'")
        return
    end

    -- Hold-style: press = on, release = off
    if SNEAK_HOLD_ACTIONS[action] then
        local pressed = (activation == "press" or activation == "hold"
                         or activation == 1 or activation == 2)
        if pressed ~= KCD2MP.playerSneaking then
            KCD2MP.playerSneaking = pressed
            mp_log("SNEAK=" .. tostring(pressed) .. " hold via '" .. action .. "'")
            KCD2MP.logActions = false
        end
    end
end

-- ===== Player hook =====

local ok2, err2 = pcall(function()
    if not (Player and Player.Client) then return end

    -- OnInit: fires when save is loaded
    local origOnInit = Player.Client.OnInit
    Player.Client.OnInit = function(self)
        if origOnInit then origOnInit(self) end
        System.LogAlways("[KCD2-MP] Player loaded!")
        KCD2MP_GetPos()

        -- Re-install OnAction hooks here (after player fully initialized).
        -- Player.Client.OnAction may be reset during game load; re-hooking in OnInit
        -- ensures our handler is always active.
        local origCA = Player.Client.OnAction
        Player.Client.OnAction = function(s, action, activation, value)
            if origCA then pcall(origCA, s, action, activation, value) end
            handleAction(action, activation, value)
        end
        System.LogAlways("[KCD2-MP] Client.OnAction hooked")
    end

    -- Also hook at mod-init time (catches actions before first save load)
    local origCA0 = Player.Client.OnAction
    Player.Client.OnAction = function(self, action, activation, value)
        if origCA0 then pcall(origCA0, self, action, activation, value) end
        handleAction(action, activation, value)
    end

    -- Also try Player.OnAction (non-Client path, some CryEngine versions use this)
    local origPA = Player.OnAction
    Player.OnAction = function(self, action, activation, value)
        if origPA then pcall(origPA, self, action, activation, value) end
        handleAction(action, activation, value)
    end

    System.LogAlways("[KCD2-MP] Player hooks OK (OnInit + OnAction x2)")
end)
if not ok2 then
    System.LogAlways("[KCD2-MP] Hook error: " .. tostring(err2))
end



