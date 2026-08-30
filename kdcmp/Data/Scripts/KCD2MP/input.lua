-- KCD2 Multiplayer - generated module split from Startup/kdcmp.lua
-- Loaded in a fixed order by Scripts/Startup/kdcmp.lua.

local mp_log = KCD2MP.util.log

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

-- Combat visibility (WO-39 Phase 1): the local player's own attack/block
-- inputs, mirrored to peers as cosmetic one-shots on this player's ghost.
-- CONFIRMED by the mp_log_actions live pass 2026-08-18: real melee swings
-- fire 'attack_primary_mouse' press/release, one pair per swing; blocking
-- fires 'block' with activation 'hold' (spammed per frame while held) and
-- 'release' -- NEVER 'press', which is why the handler below edge-detects
-- the first hold. 'attack_abort' also fires on releases; deliberately not
-- listed (it is the abort, not the swing). The unconfirmed non-mouse
-- variants stay for gamepad input, same harmless-if-never-fires idiom as
-- the dialog_answerN guesses above.
local COMBAT_SWING_ACTIONS = {
    attack_primary_mouse=true,                        -- CONFIRMED live
    attack_secondary_mouse=true,                      -- same family (stab)
    attack_primary=true, attack_secondary=true,       -- gamepad guesses
}
local COMBAT_BLOCK_ACTIONS = {
    block=true,                                       -- CONFIRMED live (hold/release)
    combat_block=true, wh_block=true,                 -- gamepad guesses
}

-- Accept/decline keybinds (WO-2, real binds added WO-33).
--
-- dialog_answer1/2 etc. below are UNVERIFIED GUESSES, kept only because
-- removing them costs nothing and they might someday turn out real. The
-- actual primary path, added WO-33, reuses kcd2mp_dice_bank (F11) /
-- kcd2mp_dice_yield (F12) -- keys already live-verified safe and wired
-- end-to-end for in-match bank/yield (WO-6 comment block in
-- keybindSuperactions.xml). Reusing them costs zero new key-testing risk:
-- outside an active match (KCD2MP.dice.open false) these two actions are
-- never consumed by the dice-board block below, so they fall through here
-- unclaimed. mp_accept / mp_decline remain the documented console fallback.
local ACCEPT_ACTIONS  = { ["dialog_answer1"] = true, ["confirm"] = true, ["ui_accept"] = true,
                           ["kcd2mp_dice_bank"] = true }
local DECLINE_ACTIONS = { ["dialog_answer2"] = true, ["cancel"] = true, ["ui_cancel"] = true,
                           ["kcd2mp_dice_yield"] = true }

-- Dice-invite keybind (WO-5, real bind added WO-33). dialog_answer3/4 are the
-- same kind of unverified guess as above, kept harmlessly. The real primary
-- path reuses kcd2mp_dice_cast (F9) -- same reasoning as accept/decline: F9
-- is already proven safe and unclaimed outside an active match, since the
-- dice-board block below only consumes it (as "confirm/cast") when
-- KCD2MP.dice.open is true and returns early. KCD2MP_InviteDiceAtTable
-- itself refuses unless a DiceInteractor entity is actually in range, so a
-- spurious F9 press elsewhere in the world is a no-op, not an unwanted
-- invite. mp_invite dice remains the documented console fallback.
local DICE_INVITE_ACTIONS = { ["dialog_answer3"] = true, ["dialog_answer4"] = true,
                               ["kcd2mp_dice_cast"] = true }

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

    -- Combat visibility (WO-39): mirror attack/block inputs to peers.
    -- Deliberately NO return -- this hook must never consume combat input;
    -- the game's own handler already ran (we are chained after it), and a
    -- swing that also triggered something else must keep doing so.
    if COMBAT_SWING_ACTIONS[action] then
        if activation == "press" or activation == 1 then
            local now = os.clock()
            if now - (KCD2MP._lastSwingEmit or 0) >= 0.15 then
                KCD2MP._lastSwingEmit = now
                KCD2MP_EmitEvent("combat", "swing")
            end
        end
    elseif COMBAT_BLOCK_ACTIONS[action] then
        -- 'block' never fires 'press' on this build -- only a per-frame
        -- 'hold' stream and a 'release' (confirmed live). Edge-detect the
        -- first hold so one raise of the guard is one event, not sixty.
        local held = (activation == "press" or activation == "hold"
                      or activation == 1 or activation == 2)
        if held and not KCD2MP._blockHeld then
            KCD2MP._blockHeld = true
            -- WO-40 Phase 6 (the choke miscue): the 'block' action also fires
            -- during weaponless grabs -- the footage's choke-out rendered as
            -- a phantom shield-block on the observer's screen. A block cue
            -- with no weapon out is never a real guard; drop it. Real
            -- unarmed blocking is rare and reads fine as nothing.
            if KCD2MP.weaponDrawn then
                KCD2MP_EmitEvent("combat", "block")
            end
        elseif activation == "release" then
            KCD2MP._blockHeld = false
        end
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




KCD2MP.modules.input = true
