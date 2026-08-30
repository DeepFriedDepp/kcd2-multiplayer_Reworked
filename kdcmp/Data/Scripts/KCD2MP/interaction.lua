-- KCD2 Multiplayer - generated module split from Startup/kdcmp.lua
-- Loaded in a fixed order by Scripts/Startup/kdcmp.lua.

local mp_log = KCD2MP.util.log

-- ===== Interaction Prompt UI (WO-2) =====
-- Drawn from the existing 8 ms label loop via System.DrawText. Game.ShowNotification
-- was already rejected for injecting '@' decorators, and DrawLabel is world-space,
-- so screen-space DrawText is the right tool for a prompt.
KCD2MP.invite = nil            -- {sid, who, kind, shownAt}
KCD2MP.interactionMsg = nil    -- {text, shownAt}
KCD2MP.diceTurn = nil          -- {text} -- optional glanceable hint; the launcher window is the real dice UI

local INVITE_TIMEOUT   = 30    -- matches the relay's invite expiry
local MSG_TIMEOUT      = 5

-- Called by the agent when a peer invites this player. wager (WO-33) is
-- groschen at stake, 0 for none -- shown in the prompt so the player knows
-- what's riding on it before answering, and checked against player.inventory:GetMoney()
-- in KCD2MP_AcceptInvite before an accept is actually sent.
function KCD2MP_ShowInvite(sid, who, kind, wager)
    KCD2MP.invite = { sid = sid, who = tostring(who), kind = tostring(kind),
                       wager = tonumber(wager) or 0, shownAt = os.clock() }
    mp_log("INVITE from " .. tostring(who) .. " (" .. tostring(kind) .. ") session " .. tostring(sid)
        .. " wager=" .. tostring(KCD2MP.invite.wager))
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

    -- WO-33: refuse locally, before the match ever starts, rather than
    -- discovering mid-game that a loss can't actually be paid. RemoveMoney
    -- itself already refuses to go negative (per the shipped scriptbind docs),
    -- but that's a safety net, not a substitute for telling the player why.
    local wager = KCD2MP.invite.wager or 0
    if wager > 0 then
        local ok, have = pcall(function() return player.inventory:GetMoney() end)
        if not ok or not have or have < wager then
            mp_log("Cannot accept: wager " .. tostring(wager) .. " exceeds balance "
                .. tostring(ok and have or "?"))
            KCD2MP_ShowInteractionMsg("Not enough groschen for that wager")
            return false
        end
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

-- ===== Time-skip sync (WO-38 Phase 1) =====
-- Day/night synchronisation. Calendar.SetWorldTime is the one Lua world
-- mutation ever verified working in this project (ARCHITECTURE-shared-world.md:
-- +3600 moved the clock exactly one hour, live), and its own scriptbind doc
-- says "Must not be set backwards" -- so every apply here is forward-only.
-- Detection of the local player's own skips lives agent-side (the kcd.log
-- AfterSkipTime markers, WO-11); Lua only answers "what time is it" and
-- applies/announces a peer's resolved skip.

-- A world day is 86,400 world-seconds. Consistent with the live WO-era
-- observation: worldTime 388805 % 86400 = 43205 s = 12.0014 h, matching the
-- hour 12.0015 read in the same probe.
local WORLD_DAY_SECONDS = 86400

-- Called by the agent (skip end, plus a ~10 s poll for the clock-jump
-- watcher). Rides the ordinary event channel.
function KCD2MP_ReportWorldTime()
    local ok, t = pcall(function() return Calendar.GetWorldTime() end)
    if ok and t then
        KCD2MP_EmitEvent("time_now", tostring(math.floor(t)))
    else
        mp_log("ReportWorldTime: Calendar.GetWorldTime unavailable")
    end
end

-- "8:00 AM" from a worldTime in seconds-from-level-start.
function KCD2MP_FormatWorldTime(t)
    local secOfDay = t % WORLD_DAY_SECONDS
    local h = math.floor(secOfDay / 3600)
    local m = math.floor((secOfDay % 3600) / 60)
    local ampm = (h >= 12) and "PM" or "AM"
    local h12 = h % 12
    if h12 == 0 then h12 = 12 end
    return string.format("%d:%02d %s", h12, m, ampm)
end

-- Called by the agent when a peer's skip resolves. who = their display name,
-- kind = Protocol.TimeSkipKind* (0 = bed sleep), target = their resulting
-- worldTime, quiet = apply without announcing (a joined skip's own result).
function KCD2MP_ApplyTimeSkip(who, kind, target, quiet)
    target = tonumber(target)
    if not target then return end
    local ok, cur = pcall(function() return Calendar.GetWorldTime() end)
    if not ok or not cur then
        mp_log("ApplyTimeSkip: Calendar.GetWorldTime unavailable")
        return
    end
    if target > cur then
        local ok2, err = pcall(function() Calendar.SetWorldTime(target) end)
        mp_log(string.format("ApplyTimeSkip: %d -> %d (%s)", cur, target,
            ok2 and "written" or ("FAILED " .. tostring(err))))
        -- WO-59: a quiet apply that moves the clock more than an hour is a
        -- session-convergence jump (connect-time sync across a multi-day
        -- save gap), and silently changing the sky under the player without
        -- a word reads as a bug. One neutral line, no peer attribution.
        if quiet and ok2 and (target - cur) > 3600 then
            KCD2MP_ShowInteractionMsg("Clock synced forward to the session's time ("
                .. KCD2MP_FormatWorldTime(target) .. ")")
        end
    else
        -- Forward-only: already at or past the target (e.g. our own skip
        -- overshot a peer's). Keep our clock; divergence is bounded by the
        -- overshoot, never by hours.
        mp_log(string.format("ApplyTimeSkip: already at %d >= %d, keeping our clock", cur, target))
    end
    if not quiet then
        local verb = (tonumber(kind) == 0) and " slept till " or " passed time to "
        KCD2MP_ShowNativeToast(tostring(who) .. verb .. KCD2MP_FormatWorldTime(target))
    end
end

-- ===== Weather sync (WO-40 Phase 3) =====
-- EnvironmentModule.BlendTimeOfDay(profile, blendDuration, force) is the
-- officially documented weather write (Warhorse's own perf scripts and the
-- debug weather quest use it). There is NO current-profile read, so the
-- session's weather is arbitrated agent-side (damage-authority holder picks
-- and broadcasts); this is just the apply.
function KCD2MP_ApplyWeather(profile, blend)
    profile = tostring(profile or "")
    if profile == "" then return end
    local b = tonumber(blend) or 30
    local ok, err = false, nil
    if EnvironmentModule and EnvironmentModule.BlendTimeOfDay then
        ok, err = pcall(function()
            EnvironmentModule.BlendTimeOfDay(profile, b, true)
        end)
        -- WO-40 live battery: a blend<=1 is a SNAP request (late-join
        -- convergence); ForceImmediateWeatherUpdate is what actually applies
        -- it at once (rain 0 -> 0.82 within seconds, live-verified), while
        -- longer blends complete on their own (rain decayed to ~0 over ~60 s
        -- under blend=30, also live-verified).
        if ok and b <= 1 then
            pcall(function() EnvironmentModule.ForceImmediateWeatherUpdate() end)
            pcall(function() EnvironmentModule.RebuildClouds() end)
        end
    else
        err = "EnvironmentModule.BlendTimeOfDay not registered"
    end
    mp_log("ApplyWeather '" .. profile .. "' blend=" .. tostring(b)
        .. (ok and " (blending)" or (" FAILED: " .. tostring(err))))
end

-- Probe/manual override: mp_weather <profile> sets a profile locally (not
-- broadcast -- this is a probe, not a sync source); bare mp_weather reports
-- the one readable weather value (rain intensity).
function KCD2MP_WeatherCmd(arg)
    local s = tostring(arg or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" or s == "%LINE" then
        local ok, rain = pcall(function() return EnvironmentModule.GetRainIntensity() end)
        mp_log("Weather: GetRainIntensity=" .. (ok and tostring(rain) or "unavailable")
            .. " (no current-profile read exists on this surface)")
        return
    end
    KCD2MP_ApplyWeather(s, 5)
end

-- The game's own HUD info text -- native KCD2 font, centered, the same
-- surface the dice overlay's say() uses (live-verified there). The user's
-- explicit direction on seeing the DrawText toast live: "I want it in the
-- middle of the screen using the standard KCD2 font... it looks janky being
-- in the top left and is not immersive." DrawText remains the fallback if
-- the UIAction path ever fails.
function KCD2MP_ShowNativeToast(text)
    local ok = pcall(function()
        UIAction.CallFunction("hud", -1, "ShowInfoText", tostring(text), 10, 5000, true)
    end)
    if not ok then
        KCD2MP_ShowInteractionMsg(text)
    end
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
-- kindStr is "dice" or "duel". wagerAmount (WO-33) is dice-only groschen,
-- ignored for any other kind.
function KCD2MP_InviteNearest(kindStr, wagerAmount)
    kindStr = tostring(kindStr or ""):gsub("%s+", "")
    if kindStr == "" then kindStr = "dice" end
    wagerAmount = tonumber(wagerAmount) or 0

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

    local payload = tostring(bestId) .. " " .. kindStr
    if kindStr == "dice" then payload = payload .. " " .. tostring(math.floor(wagerAmount)) end

    mp_log("Inviting ghost " .. tostring(bestId) .. " to " .. kindStr
        .. (kindStr == "dice" and (" wager=" .. tostring(wagerAmount)) or ""))
    KCD2MP_EmitEvent("invite_send", payload)
    KCD2MP_ShowInteractionMsg(wagerAmount > 0 and ("Invite sent (wager " .. wagerAmount .. ")") or "Invite sent")
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
            local stake = (inv.wager and inv.wager > 0) and ("  for " .. inv.wager .. " groschen") or ""
            System.DrawText(10, 60, inv.who .. " invites you to " .. inv.kind .. stake .. "  (" .. left .. "s)", 2)
            System.DrawText(10, 84, "F11 accept / F12 decline  (or mp_accept / mp_decline)", 1.6)
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

-- WO-50: mp_debug_hud on|off. Flips the release-default r_DisplayInfo
-- override above without a rebuild, so a future debugging session can get
-- the build/memory/FPS block back. Does not touch the ping/network
-- indicator -- that is a separate System.DrawText call, not this CVar.
function KCD2MP_DebugHud(arg)
    local s = tostring(arg or ""):lower()
    if s:find("on") then
        KCD2MP.debugHud = true
        System.SetCVar("r_DisplayInfo", "3")
    elseif s:find("off") then
        KCD2MP.debugHud = false
        System.SetCVar("r_DisplayInfo", "0")
    else
        mp_log("mp_debug_hud: expected 'on' or 'off', got '" .. tostring(arg) .. "'")
        return false
    end
    mp_log("DEBUG HUD (r_DisplayInfo) = " .. tostring(System.GetCVarValue("r_DisplayInfo")))
    return true
end

-- ===== Ghost NPC Spawn =====

-- WO-17: mp_enable_aggro on|off. Opt-in, off by default, decided locally on
-- this client only -- it does not need the other player's agreement, the
-- same way dice needed a session invite/accept but this does not, because it
-- only changes how THIS player's world treats an incoming ghost. The agent
-- hears about this via the same log-tail event channel invite_accept already
-- uses (KCD2MP_EmitEvent) -- it, not Lua, is what actually decides when to
-- attach a ghost to the hostile faction, since that write only exists in
-- native code.
--
-- WO-27: this is a single live flag (GameBridge._aggroEnabled), checked at
-- hit-time for every ghost, not baked in per-ghost at spawn -- flipping it
-- takes effect on the very next hit for every ghost already in the world, no
-- respawn or reconnect needed. Reactive combat itself (a ghost defending
-- itself, joining a nearby fight) is unconditional and always on regardless
-- of this toggle (WO-26); what this toggle adds is a ~20s native hostile-
-- faction attach so nearby NPCs recognize the ghost as an enemy generally,
-- not just whoever it's already fighting (WO-27's live A/B test).
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


KCD2MP.modules.interaction = true
