-- WO-123 synthetic test, against the real kdcmp.lua under MoonSharp.
--
-- The Lua half of the join (the host's pause):
--   (a) shipped: WO123-BUILD once, timeout 180, the mirror event, the commands
--   (b) mp_shared_world off: KCD2MP_JoinTry refuses, nothing is touched
--   (c) busy: combat, dialogue, cutscene, dead -> deferred, nothing paused;
--       the host is told once per 15 s
--   (d) the pause: ratio read then 0; every NPC/horse around paused, except
--       the dead, a lever-paused one and the mod's own ghost; the list kept;
--       the input hold; the "paused" answer
--   (e) the same join asked again: no second pause; another join: busy
--   (f) an NPC that streams in while paused is paused and added
--   (g) resume: the ratio restored, exactly the list resumed (a name the
--       lever took over is left to it), the hold released; idempotent
--   (h) mp_join_cancel resumes at once, here, and tells the agent
--   (i) the mod's own safety timer resumes; a stale timer never ends a newer join
--   (j) mp_shared_world off mid-join resumes
--   (k) mp_join_timeout range; (l) the on-screen bar; (m) mp_join_request
--
-- Driven by Test-WO123Synthetic.ps1 through the WO-77 MoonSharp driver.
-- What this proves: the Lua half behaves as documented. It does NOT prove
-- the engine freezes anything -- see docs/WO-123-findings.md for the live runs.

NOW = 0
os.clock = function() return NOW end
LOG = {}; TIMERS = {}; ENTS = {}; ERRS = {}; TOASTS = {}; CMDS = {}; CCMDS = {}; DRAWN = {}; MAPS = {}

local function mkstub()
    return setmetatable({}, { __index = function(_, k) return function(...) return nil end end })
end
System = mkstub()
System.LogAlways = function(s) LOG[#LOG + 1] = tostring(s) end
System.GetCVarValue = function() return "0" end
System.GetEntityByName = function(n) return ENTS[n] end
SPHERE = {}
System.GetEntitiesInSphere = function() local o = {}; for _, e in ipairs(SPHERE) do o[#o + 1] = e end; return o end
System.ExecuteCommand = function(s) CMDS[#CMDS + 1] = tostring(s) end
System.AddCCommand = function(name, body, help) CCMDS[name] = { body = tostring(body), help = tostring(help or "") } end
System.DrawText = function(x, y, t, s) DRAWN[#DRAWN + 1] = tostring(t) end
Script = mkstub()
Script.SetTimer = function(ms, f) TIMERS[#TIMERS + 1] = { due = NOW + ms / 1000, f = f } end
AI = mkstub(); Sound = mkstub(); Physics = mkstub(); Terrain = mkstub()
UIAction = mkstub()
UIAction.CallFunction = function() end
Game = mkstub()
RATIO = 15; WORLDTIME = 579321
Calendar = mkstub()
Calendar.GetWorldTimeRatio = function() return RATIO end
Calendar.SetWorldTimeRatio = function(r) RATIO = r end
Calendar.GetWorldTime = function() return WORLDTIME end
ActionMapManager = mkstub()
ActionMapManager.EnableActionMap = function(name, on) MAPS[#MAPS + 1] = name .. "=" .. tostring(on) end

COMBAT, DIALOG, DEAD = false, false, false
player = {
    GetName = function() return "Dude" end,
    GetWorldPos = function() return { x = 100, y = 100, z = 10 } end,
    soul = { IsInCombatDanger = function() return COMBAT end },
    human = { IsInDialog = function() return DIALOG end },
    actor = { IsDead = function() return DEAD end },
}

local rawpcall = pcall
pcall = function(f, ...)
    local r = { rawpcall(f, ...) }
    if not r[1] then ERRS[#ERRS + 1] = tostring(r[2]) end
    return unpack(r)
end

-- @@KDCMP@@

-- Part 2: scenarios.

local RESULTS = {}
local function check(name, ok, detail)
    RESULTS[#RESULTS + 1] = (ok and "PASS  " or "FAIL  ") .. name .. (detail and ("  [" .. tostring(detail) .. "]") or "")
end
local function countLog(needle, fromLog)
    local n = 0
    for i = (fromLog or 0) + 1, #LOG do if LOG[i]:find(needle, 1, true) then n = n + 1 end end
    return n
end
local function lastLog(needle, fromLog)
    for i = #LOG, (fromLog or 0) + 1, -1 do if LOG[i]:find(needle, 1, true) then return LOG[i] end end
    return nil
end
local function countEvt(name, argPrefix, fromLog)
    local n = 0
    for i = (fromLog or 0) + 1, #LOG do
        local l = LOG[i]
        if l:find("[KCD2-MP-EVT] v1 ", 1, true) and l:find(" " .. name .. " " .. (argPrefix or ""), 1, true) then n = n + 1 end
    end
    return n
end
local function countCmd(prefix, from)
    local n = 0
    for i = (from or 0) + 1, #CMDS do if CMDS[i]:sub(1, #prefix) == prefix then n = n + 1 end end
    return n
end
local function hasCmd(cmd, from)
    for i = (from or 0) + 1, #CMDS do if CMDS[i] == cmd then return true end end
    return false
end
-- the mod's toasts: every KCD2MP_ShowInteractionMsg leaves an MP-TOAST line (WO-98 Phase 6)
local function toasts(from)
    local o = {}
    for i = (from or 0) + 1, #LOG do
        local t = LOG[i]:match('MP%-TOAST kind=msg text="(.-)"')
        if t then o[#o + 1] = t end
    end
    return o
end
local function noErrs(label) check(label .. ": no swallowed Lua errors", #ERRS == 0, ERRS[1]) end
local function advance(seconds)
    local t_end = NOW + seconds
    while NOW < t_end do
        NOW = NOW + 0.25
        local due = {}
        for i = #TIMERS, 1, -1 do if TIMERS[i].due <= NOW then due[#due + 1] = TIMERS[i].f; table.remove(TIMERS, i) end end
        for _, f in ipairs(due) do f() end
    end
end

local NEXTID = 9000
local function mkEntity(name, cls, dead)
    NEXTID = NEXTID + 1
    local e = { class = cls or "NPC", id = NEXTID, dead = dead or false }
    e.GetName = function(self) return name end
    e.GetWorldPos = function(self) return { x = 101, y = 101, z = 10 } end
    e.actor = { IsDead = function() return e.dead end }
    ENTS[name] = e
    return e
end

local function world()
    SPHERE = { mkEntity("ttkc_man_2"), mkEntity("ttkc_man_22"), mkEntity("ttkc_woman_4", "NPC_Female"),
               mkEntity("ttkc_corpse_1", "NPC", true), mkEntity("ttkc_leverpaused"), mkEntity("horse_bohuta", "Horse"),
               mkEntity("chicken_1", "Animal"), mkEntity("hare_1", "Hare") }
    ENTS["hare_1"].soul = {}   -- an animal with a brain: paused; the soul-less prop chicken is not
    KCD2MP._npcPaused = { ttkc_leverpaused = 0 }
    -- the mod's own ghost body is never paused by a join
    local g = mkEntity("kcd2mp_1")
    KCD2MP.ghosts = { ["1"] = { entity = g } }
    SPHERE[#SPHERE + 1] = g
end

local function reset()
    ERRS = {}; TOASTS = {}; MAPS = {}; DRAWN = {}; TIMERS = {}
    COMBAT, DIALOG, DEAD = false, false, false
    KCD2MP.cutsceneActive = false
    RATIO = 15
    world()
end

-- (a) shipped defaults ---------------------------------------------------------
do
    local w = KCD2MP.w123
    check("a: join timeout ships 180 s", w.timeoutS == 180)
    check("a: WO123-BUILD logged once at load", countLog("WO123-BUILD ") == 1, lastLog("WO123-BUILD"))
    check("a: the marker names the defaults", (lastLog("WO123-BUILD") or ""):find("join_timeout_s=180 hold=noinput", 1, true) ~= nil)
    check("a: the mirror event went to the agent at load", countEvt("wo123_cfg", "timeout_s=180") == 1)
    for _, c in ipairs({ { "mp_join_cancel", "KCD2MP_JoinCancel()" }, { "mp_join_timeout", "KCD2MP_SetJoinTimeout(%line)" },
                         { "mp_join_request", "KCD2MP_JoinRequest()" }, { "mp_join_hold_probe", "KCD2MP_JoinHoldProbe(%line)" },
                         { "mp_join_hold", "KCD2MP_SetJoinHold(%line)" } }) do
        check("a: " .. c[1] .. " is registered as " .. c[2], CCMDS[c[1]] and CCMDS[c[1]].body == c[2], CCMDS[c[1]] and CCMDS[c[1]].body)
    end
    check("a: nothing paused at load", w.paused == false and RATIO == 15)
    noErrs("a")
end

-- (b) mp_shared_world off: refused, untouched -----------------------------------
do
    reset()
    local mark, cm = #LOG, #CMDS
    check("b: shared world ships off", KCD2MP.w122.sharedWorld == false)
    check("b: JoinTry refuses", KCD2MP_JoinTry("0000abcd", "Bob", 180) == false)
    check("b: answers busy shared-world-off", countEvt("join_try", "0000abcd busy shared-world-off", mark) == 1)
    check("b: the clock is untouched", RATIO == 15)
    check("b: no NPC paused", countCmd("wh_ai_PauseNPC", cm) == 0)
    check("b: no input map touched", #MAPS == 0)
    check("b: mp_join_request refuses too", KCD2MP_JoinRequest() == false and countEvt("join_request", "", mark) == 0)
    noErrs("b")
end

KCD2MP_SetSharedWorld("on")

-- (c) busy: deferred, nothing paused --------------------------------------------
do
    for _, case in ipairs({ { "combat", function() COMBAT = true end }, { "dialogue", function() DIALOG = true end },
                            { "cutscene", function() KCD2MP.cutsceneActive = true end }, { "dead", function() DEAD = true end } }) do
        reset()
        KCD2MP.w123.busyToldAt = -1e9
        case[2]()
        local mark, cm = #LOG, #CMDS
        check("c: " .. case[1] .. ": refused", KCD2MP_JoinTry("0000c001", "Bob", 180) == false)
        check("c: " .. case[1] .. ": answers busy " .. case[1], countEvt("join_try", "0000c001 busy " .. case[1], mark) == 1, lastLog("join_try", mark))
        check("c: " .. case[1] .. ": clock and NPCs untouched", RATIO == 15 and countCmd("wh_ai_PauseNPC", cm) == 0 and #MAPS == 0)
        local t = toasts(mark)
        check("c: " .. case[1] .. ": the host is told", #t == 1 and t[1]:find("Bob wants to join -- waiting (" .. case[1] .. ")", 1, true) ~= nil, t[1])
        NOW = NOW + 2
        KCD2MP_JoinTry("0000c001", "Bob", 180)
        check("c: " .. case[1] .. ": told once per 15 s, answered every time", #toasts(mark) == 1 and countEvt("join_try", "0000c001 busy", mark) == 2)
        noErrs("c " .. case[1])
    end
end

-- (d) the pause ---------------------------------------------------------------
local PAUSED_SET = { "ttkc_man_2", "ttkc_man_22", "ttkc_woman_4", "horse_bohuta", "hare_1" }
do
    reset()
    local w = KCD2MP.w123
    local mark, cm = #LOG, #CMDS
    check("d: JoinTry pauses", KCD2MP_JoinTry("0000d001", "Bob", 180) == true)
    check("d: the clock is frozen", RATIO == 0)
    check("d: the previous ratio kept", w.ratioWas == 15)
    for _, n in ipairs(PAUSED_SET) do check("d: " .. n .. " paused", hasCmd("wh_ai_PauseNPC " .. n, cm)) end
    check("d: exactly five pause commands", countCmd("wh_ai_PauseNPC", cm) == 5, tostring(countCmd("wh_ai_PauseNPC", cm)))
    check("d: the dead body is not paused", not hasCmd("wh_ai_PauseNPC ttkc_corpse_1", cm))
    check("d: the lever's puppet is not taken", not hasCmd("wh_ai_PauseNPC ttkc_leverpaused", cm))
    check("d: the mod's ghost is not paused", not hasCmd("wh_ai_PauseNPC kcd2mp_1", cm))
    check("d: a soul-less prop is not paused", not hasCmd("wh_ai_PauseNPC chicken_1", cm))
    check("d: an animal with a soul is paused", hasCmd("wh_ai_PauseNPC hare_1", cm))
    check("d: the list is kept", w.npcN == 5 and w.npcs["ttkc_man_2"] ~= nil and w.npcs["horse_bohuta"] ~= nil)
    check("d: input held (the engine's no_input map on)", MAPS[1] == "no_input=true" and #MAPS == 1, table.concat(MAPS, " "))
    check("d: answers paused 5", countEvt("join_try", "0000d001 paused 5", mark) == 1, lastLog("join_try", mark))
    local l = lastLog("MP-JOIN pause join=0000d001", mark) or ""
    check("d: one MP-JOIN pause line with the ratio and the count", l:find("ratio_was=15 ratio_now=0", 1, true) ~= nil and l:find("npcs_paused=5 skipped=2", 1, true) ~= nil, l)
    check("d: two timers armed (safety + rescan)", #TIMERS == 2, tostring(#TIMERS))
    noErrs("d")

    -- (e) the same join again, then another
    local cm2, m2 = #CMDS, #LOG
    check("e: the same join asked again: paused, no second pause", KCD2MP_JoinTry("0000d001", "Bob", 180) == true and countCmd("wh_ai_PauseNPC", cm2) == 0)
    check("e: answered paused again", countEvt("join_try", "0000d001 paused 5", m2) == 1)
    check("e: another join while paused: busy another-join", KCD2MP_JoinTry("0000eeee", "Eve", 180) == false and countEvt("join_try", "0000eeee busy another-join", m2) == 1)
    noErrs("e")

    -- (f) streamed in while paused
    local late = mkEntity("ttkc_latecomer")
    SPHERE[#SPHERE + 1] = late
    local cm3, m3 = #CMDS, #LOG
    advance(2.1)
    check("f: the late NPC is paused by the 2 s scan", hasCmd("wh_ai_PauseNPC ttkc_latecomer", cm3) and w.npcN == 6)
    check("f: and logged", countLog("added=1 npcs_paused=6", m3) == 1)
    check("f: nobody already paused is paused twice", countCmd("wh_ai_PauseNPC", cm3) == 1)
    noErrs("f")

    -- (g) resume
    KCD2MP._npcPaused["ttkc_man_22"] = NOW   -- the lever took this one over mid-join
    local cm4, m4 = #CMDS, #LOG
    MAPS = {}
    check("g: resume", KCD2MP_JoinResume("0000d001", "ready") == true)
    check("g: the ratio is back", RATIO == 15)
    for _, n in ipairs({ "ttkc_man_2", "ttkc_woman_4", "horse_bohuta", "ttkc_latecomer" }) do check("g: " .. n .. " resumed", hasCmd("wh_ai_ResumeNPC " .. n, cm4)) end
    check("g: the lever's name is left to the lever", not hasCmd("wh_ai_ResumeNPC ttkc_man_22", cm4))
    check("g: nothing outside the list resumed", countCmd("wh_ai_ResumeNPC", cm4) == 5, tostring(countCmd("wh_ai_ResumeNPC", cm4)))
    check("g: the hold released", MAPS[1] == "no_input=false" and #MAPS == 1, table.concat(MAPS, " "))
    local l = lastLog("MP-JOIN resume join=0000d001 reason=ready", m4) or ""
    check("g: MP-JOIN resume logged with its reason and counts", l:find("npcs_resumed=5 left_to_lever=1", 1, true) ~= nil and l:find("ratio_back=15", 1, true) ~= nil, l)
    check("g: the agent is told", countEvt("join_resumed", "0000d001 ready", m4) == 1)
    check("g: no toast for a ready resume", #toasts(m4) == 0, toasts(m4)[1])
    local cm5 = #CMDS
    check("g: a second resume is a no-op", KCD2MP_JoinResume("0000d001", "timeout") == false and countCmd("wh_ai_ResumeNPC", cm5) == 0 and RATIO == 15)
    advance(3)
    check("g: the rescan stopped with the resume", countCmd("wh_ai_PauseNPC", cm5) == 0)
    noErrs("g")
end

-- (h) mp_join_cancel -------------------------------------------------------------
do
    reset()
    KCD2MP_JoinTry("0000a001", "Bob", 180)
    local mark, cm = #LOG, #CMDS
    KCD2MP_JoinCancel()
    check("h: resumed at once, reason cancel", countLog("MP-JOIN resume join=0000a001 reason=cancel", mark) == 1 and RATIO == 15)
    check("h: every paused NPC resumed", countCmd("wh_ai_ResumeNPC", cm) == 5)
    check("h: the agent is told (join_cancel)", countEvt("join_cancel", "", mark) == 1)
    local t = toasts(mark)
    check("h: the host sees why", t[1] and t[1]:find("Join ended (cancel)", 1, true) ~= nil, t[1])
    noErrs("h")
end

-- (i) the mod's own safety timer -------------------------------------------------
do
    reset()
    KCD2MP_SetJoinTimeout("60")
    KCD2MP_JoinTry("0000b001", "Bob", 60)
    local mark = #LOG
    advance(60)
    check("i: still paused at the agent's timeout (the agent resumes first)", KCD2MP.w123.paused == true)
    advance(16)
    check("i: resumed by the mod at timeout + 15 s", countLog("MP-JOIN resume join=0000b001 reason=mod-safety-timeout", mark) == 1 and RATIO == 15)
    -- a stale timer never ends a newer join
    KCD2MP_JoinTry("0000b002", "Bob", 60)
    advance(30)
    KCD2MP_JoinResume("0000b002", "ready")
    KCD2MP_JoinTry("0000b003", "Bob", 60)
    local m2 = #LOG
    advance(50)   -- b002's timer (due at 75 s after its start) fires here
    check("i: b002's stale timer did not touch b003", countLog("reason=mod-safety-timeout", m2) == 0 and KCD2MP.w123.paused == true)
    KCD2MP_JoinResume("0000b003", "ready")
    KCD2MP_SetJoinTimeout("180")
    noErrs("i")
end

-- (j) mp_shared_world off mid-join ------------------------------------------------
do
    reset()
    KCD2MP_JoinTry("0000f001", "Bob", 180)
    local mark = #LOG
    KCD2MP_SetSharedWorld("off")
    check("j: the toggle resumes the host", countLog("MP-JOIN resume join=0000f001 reason=shared-world-off", mark) == 1 and RATIO == 15 and KCD2MP.w123.paused == false)
    KCD2MP_SetSharedWorld("on")
    noErrs("j")
end

-- (k) mp_join_timeout ---------------------------------------------------------------
do
    local w = KCD2MP.w123
    local mark = #LOG
    check("k: 60 accepted", KCD2MP_SetJoinTimeout("60") == true and w.timeoutS == 60)
    check("k: mirrored", countEvt("wo123_cfg", "timeout_s=60", mark) == 1)
    check("k: 29 refused", KCD2MP_SetJoinTimeout("29") == false and w.timeoutS == 60)
    check("k: 1801 refused", KCD2MP_SetJoinTimeout("1801") == false)
    check("k: 90.5 refused", KCD2MP_SetJoinTimeout("90.5") == false)
    local m2 = #LOG
    KCD2MP_SetJoinTimeout("%line")
    check("k: bare reports", countLog("WO123-TOGGLE join_timeout_s=60", m2) == 1)
    KCD2MP_SetJoinTimeout("180")
    noErrs("k")
end

-- (l) the bar ---------------------------------------------------------------------
-- WO-129 replaced the 20-block bar with the stage and its seconds (the host saw
-- "loading" with no progress for a minute in the first two-player session);
-- the wording checks follow KCD2MP_JoinBarText (tools/Test-WO129Synthetic.lua).
do
    reset()
    KCD2MP_JoinTry("0000c0de", "Bob", 180)
    DRAWN = {}
    KCD2MP_DrawInteractionUI()
    local all = table.concat(DRAWN, " | ")
    check("l: 'Bob is joining -- saving the world...' on screen", all:find("Bob is joining -- saving the world... 0 s", 1, true) ~= nil, all)
    check("l: the ladder starts on save", all:find("[>] save 0 s   [ ] send", 1, true) ~= nil, all)
    KCD2MP_JoinProgress("0000c0de", 62, "sending")
    DRAWN = {}
    KCD2MP_DrawInteractionUI()
    all = table.concat(DRAWN, " | ")
    check("l: sending shows 62%", all:find("Sending the world to Bob... 62%", 1, true) ~= nil and all:find("[x] save   [>] send 62%", 1, true) ~= nil, all)
    KCD2MP_JoinProgress("0000c0de", 100, "loading")
    DRAWN = {}
    KCD2MP_DrawInteractionUI()
    check("l: then 'Bob is loading your world... N s'", table.concat(DRAWN, " | "):find("Bob is loading your world... 0 s", 1, true) ~= nil, table.concat(DRAWN, " | "))
    KCD2MP_JoinProgress("ffffffff", 5, "sending")
    check("l: another join's progress is ignored", KCD2MP.w123.pct == 100)
    KCD2MP_JoinResume("0000c0de", "ready")
    DRAWN = {}
    KCD2MP_DrawInteractionUI()
    check("l: gone after the resume", table.concat(DRAWN, " | "):find("joining", 1, true) == nil)
    noErrs("l")
end

-- (n) mp_join_hold: the method, and a release that undoes the method the hold used
do
    reset()
    local w = KCD2MP.w123
    local mark = #LOG
    check("n: a bad method is refused", KCD2MP_SetJoinHold("glue") == false and w.holdMethod == "noinput")
    check("n: actionmap accepted", KCD2MP_SetJoinHold("actionmap") == true and w.holdMethod == "actionmap")
    check("n: mirrored to the agent", countEvt("wo123_cfg", "timeout_s=180 hold=actionmap", mark) == 1)
    MAPS = {}
    KCD2MP_JoinTry("0000e001", "Bob", 180)
    check("n: the pause holds with player + movement off", MAPS[1] == "player=false" and MAPS[2] == "movement=false", table.concat(MAPS, " "))
    KCD2MP_SetJoinHold("noinput")   -- changed mid-pause
    MAPS = {}
    KCD2MP_JoinResume("0000e001", "ready")
    check("n: the release undoes actionmap (the method held), not noinput", MAPS[1] == "player=true" and MAPS[2] == "movement=true" and #MAPS == 2, table.concat(MAPS, " "))
    MAPS = {}
    KCD2MP_JoinTry("0000e002", "Bob", 180)
    check("n: the next pause uses noinput", MAPS[1] == "no_input=true", table.concat(MAPS, " "))
    KCD2MP_JoinResume("0000e002", "ready")
    KCD2MP_SetJoinHold("none")
    MAPS = {}
    KCD2MP_JoinTry("0000e003", "Bob", 180)
    KCD2MP_JoinResume("0000e003", "ready")
    check("n: none touches no map", #MAPS == 0)
    KCD2MP_SetJoinHold("noinput")
    noErrs("n")
end

-- (o) after a load: the stale-pause resume, and the draw loop's backstop
do
    reset()
    local w = KCD2MP.w123
    check("o: a stale resume with nothing paused is a no-op", KCD2MP_JoinResumeStale("host-reload") == false)
    KCD2MP_JoinTry("0000f001", "Bob", 180)
    local m = #LOG
    check("o: a pause the load orphaned is resumed", KCD2MP_JoinResumeStale("host-reload") == true and w.paused == false and RATIO == 15)
    check("o: logged with the reason", countLog("MP-JOIN resume join=0000f001 reason=host-reload", m) == 1)
    -- the load killed the safety timer: only the draw loop is left
    KCD2MP_JoinTry("0000f002", "Bob", 60)
    TIMERS = {}
    NOW = NOW + 74
    KCD2MP_DrawInteractionUI()
    check("o: the draw loop keeps a pause inside timeout + 15 s", w.paused == true)
    NOW = NOW + 2
    local m2 = #LOG
    KCD2MP_DrawInteractionUI()
    check("o: past timeout + 15 s the draw loop resumes", w.paused == false and countLog("reason=mod-safety-timeout", m2) == 1)
    w.timeoutS = 180
    noErrs("o")
end

-- (m) mp_join_request -------------------------------------------------------------
do
    local mark = #LOG
    check("m: with mp_shared_world on it asks the agent", KCD2MP_JoinRequest() == true and countEvt("join_request", "", mark) == 1)
    noErrs("m")
end

OUT = table.concat(RESULTS, "\n")
