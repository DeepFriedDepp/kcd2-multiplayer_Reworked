-- WO-118 synthetic test, against the real kdcmp.lua under MoonSharp.
--
--   (a) defaults: mp_npc_native_write ON, mp_npc_detach ON; the WO118-BUILD
--       marker is logged at load; the npc_native_cfg event mirrors the
--       defaults to the agent at load
--   (b) no heartbeat -> no bind event is ever emitted and Lua writes the
--       puppet (SetWorldPos every tick), exactly the 0.27.0 path
--   (c) heartbeat alive -> ONE bind event with the documented fields; the
--       fresh puppet is not written while that first bind is in flight
--   (c2) no answer within 1 s -> Lua writes it; the late ack still hands it over
--   (c3) a refusal -> Lua writes at once, and a later retry never holds it again
--       (name, on, eid hex, wuid hex, anchor x/y/z, delay ms); Lua keeps
--       writing until the DLL acknowledges
--   (d) ack ok -> Lua stops writing positions for that puppet (no
--       SetWorldPos, no lastWrote baseline) while the gait/policy tick runs
--   (e) heartbeat stale (> 3 s) -> Lua writes the puppet again at once and
--       emits the unbind; the bind returns when the heartbeat does
--   (f) a nack (the DLL's own drop) -> Lua writes at once; the bind is
--       re-offered only after 10 s
--   (g) a dead / unconscious / carried stream -> unbind ("down"); Lua's own
--       down-body behaviour applies
--   (h) a swing cue -> a native hold event with the one-shot's duration
--   (i) mp_npc_native_write off -> cfg event, every puppet unbound, Lua
--       writes; on -> binds again
--   (j) detach: the pause at puppet start is followed by the two resets
--       (Stance, Unstance) through the console; MP-DETACH carries the
--       before->after state 0.6 s later; skipped (and logged) in dialogue and
--       during a cutscene; mp_npc_detach off issues nothing
--   (k) presets: clean = native on + detach on; legacy = native off +
--       detach off; both log a row for each
--   (l) mp_npc_trace: bare prints usage; a name emits npc_trace <name> <s>
--       (default 10, clamped 1..120); stop emits <last> 0; the console
--       commands are registered with the unquoted %line
--   (m) silence release, diverge release and a reload each send the unbind
--   (n) Phase 2b: the peer's ghost binds like a puppet (kcd2mp_<id>, delay
--       100 ms), stops its Lua write when owned, sends a hold for a one-shot,
--       unbinds while riding, and a drop hands it back
--
-- What this proves: the Lua half behaves as documented. What it does NOT
-- prove: anything about the DLL, the engine or a second machine.
--
-- Part 1: engine stubs + a fake clock (the WO-110 driver's shape).

NOW = 0
os.clock = function() return NOW end
LOG = {}; TIMERS = {}; ENTS = {}; ERRS = {}; TOASTS = {}; SPHERE = {}
CMDS = {}; DRAWS = {}; SPAWNS = {}; CCMDS = {}

local function mkstub()
    return setmetatable({}, { __index = function(_, k) return function(...) return nil end end })
end
System = mkstub()
System.LogAlways = function(s) LOG[#LOG + 1] = tostring(s) end
System.GetCVar = function() return "0" end
System.GetEntityByName = function(n) return ENTS[n] end
System.GetEntitiesInSphere = function() return SPHERE end
System.ExecuteCommand = function(s) CMDS[#CMDS + 1] = tostring(s) end
System.DrawText = function(x, y, text, size) DRAWS[#DRAWS + 1] = { x = x, y = y, text = tostring(text) } end
System.RemoveEntity = function(eid) for n, e in pairs(ENTS) do if e.id == eid then ENTS[n] = nil end end end
System.AddCCommand = function(name, body, help) CCMDS[name] = { body = tostring(body), help = tostring(help or "") } end
Script = mkstub()
Script.SetTimer = function(ms, f) TIMERS[#TIMERS + 1] = { ms = ms, f = f, at = NOW } end
Game = mkstub(); AI = mkstub(); Sound = mkstub(); Physics = mkstub(); Terrain = mkstub()
UIAction = mkstub()
UIAction.CallFunction = function(panel, inst, fn, text) TOASTS[#TOASTS + 1] = tostring(text) end
WORLD_T = 1000
Calendar = { GetWorldTime = function() return WORLD_T end, SetWorldTime = function(t) WORLD_T = t end }
XGenAIModule = mkstub()

player = { id = 1, GetName = function(self) return "Dude" end,
           GetWorldPos = function() return { x = 0, y = 0, z = 0 } end,
           GetWorldAngles = function() return { x = 0, y = 0, z = 0 } end,
           GetLinkedParent = function() return nil end,
           actor = { GetHealth = function() return 100 end, IsDead = function() return false end } }

local rawpcall = pcall
pcall = function(f, ...)
    local r = { rawpcall(f, ...) }
    if not r[1] then ERRS[#ERRS + 1] = tostring(r[2]) end
    return table.unpack(r)
end

-- @@KDCMP@@

-- Part 2: scenarios.

local RESULTS = {}
local function check(name, ok, detail)
    RESULTS[#RESULTS + 1] = (ok and "PASS  " or "FAIL  ") .. name .. (detail and ("  [" .. tostring(detail) .. "]") or "")
end
local function logCount(pat)
    local n = 0
    for _, l in ipairs(LOG) do if string.find(l, pat, 1, true) then n = n + 1 end end
    return n
end
local function lastLog(pat)
    for i = #LOG, 1, -1 do if string.find(LOG[i], pat, 1, true) then return LOG[i] end end
    return nil
end
local function clearLog() LOG = {} end
local function evts(name)
    local out = {}
    for _, l in ipairs(LOG) do
        local a = l:match("%[KCD2%-MP%-EVT%] v1 %d+ " .. name:gsub("_", "%%_") .. " (.*)$")
        if a then out[#out + 1] = a end
    end
    return out
end
local function cmdCount(pat)
    local n = 0
    for _, c in ipairs(CMDS) do if string.find(c, pat, 1, true) then n = n + 1 end end
    return n
end

-- (a) defaults -- read BEFORE any scenario touches them.
check("a: mp_npc_native_write ships ON", KCD2MP.npcNativeWrite == true)
check("a: mp_npc_detach ships ON", KCD2MP.npcDetach == true)
check("a: WO118-BUILD marker logged with both defaults",
      logCount("WO118-BUILD") == 1 and (lastLog("WO118-BUILD") or ""):find("npc_native_write=on", 1, true) ~= nil
      and (lastLog("WO118-BUILD") or ""):find("npc_detach=on", 1, true) ~= nil, lastLog("WO118-BUILD"))
check("a: the load mirrors the defaults to the agent (npc_native_cfg on on)", (evts("npc_native_cfg")[1] or "") == "on on", evts("npc_native_cfg")[1])
check("a: no Lua errors at load", #ERRS == 0, ERRS[1])

local NEXTID = 0x0E0000
local STATE = {}
local function mkEntity(name, x, y, z)
    NEXTID = NEXTID + 1
    local e = { class = "NPC", id = "userdata: " .. string.format("%016X", NEXTID), px = x or 0, py = y or 0, pz = z or 0, rz = 0, writes = {}, dead = false, hp = 100 }
    e.GetName = function(self) return name end
    e.GetWorldPos = function(self, t) t = t or {}; t.x, t.y, t.z = self.px, self.py, self.pz; return t end
    e.GetWorldAngles = function(self, t) t = t or {}; t.x, t.y, t.z = 0, 0, self.rz; return t end
    e.SetWorldPos = function(self, pos) self.px, self.py, self.pz = pos.x, pos.y, pos.z; self.writes[#self.writes + 1] = { x = pos.x, y = pos.y, z = pos.z, at = NOW } end
    e.SetWorldAngles = function(self, a) self.rz = a.z end
    e.StartAnimation = function() end
    e.GetAnimationLength = function() return 0.8 end
    e.SetFlags = function() end
    e.actor = { IsDead = function() return e.dead end, IsUnconscious = function() return false end, GetHealth = function() return e.hp end,
                GetCurrentAnimationState = function() return STATE[name] or "SittingIdle" end }
    e.human = { IsWeaponDrawn = function() return false end, DrawWeapon = function() return true end, HolsterWeapon = function() return true end,
                IsInDialog = function() return e.inDialog == true end }
    e.soul = { GetId = function() return "userdata: 05000000000001DC" end }
    ENTS[name] = e
    return e
end

local function reset()
    KCD2MP.wo102.authorityHost = true; KCD2MP.wo102.authorityPause = true
    KCD2MP.hitSensorOn = false
    KCD2MP.npcPuppets = {}; KCD2MP.npcTracked = {}
    KCD2MP.npcPuppetRunning = false; KCD2MP._npcDivergeUntil = {}
    KCD2MP._npcPaused = {}; KCD2MP._npcPauseExec = {}; KCD2MP._npcEverPaused = {}; KCD2MP._npcResumePending = {}
    KCD2MP._authViolationAt = {}; KCD2MP._authViolationN = {}
    KCD2MP._npcDeathRemote = {}; KCD2MP._npcDeathDiverged = {}; KCD2MP._npcDeathSeen = {}
    KCD2MP.npcDiverge = true; KCD2MP.npcYield.enabled = false
    KCD2MP.npcReplica.enabled = false; KCD2MP._npcReplicas = {}
    KCD2MP.npcSmooth = true; KCD2MP.npcPuppetTickMs = 50
    KCD2MP.npcSenderClock = true; KCD2MP._senderClock = {}
    KCD2MP.npcNativeWrite = true; KCD2MP.npcDetach = true; KCD2MP.cutsceneActive = false
    KCD2MP._npcNative = { aliveAt = nil, armed = false, on = false, bound = 0, writing = 0, binds = 0, acks = 0, nacks = 0, holds = 0, unbinds = 0 }
    KCD2MP._npcDetachStats = { issued = 0, skipped = 0, changed = 0, unchanged = 0 }
    KCD2MP.ghosts = {}
    ENTS = {}; SPHERE = {}; TIMERS = {}; ERRS = {}; CMDS = {}; STATE = {}
    clearLog()
end

local SEQ = 0
local function packet(name, sx, sy, sz, flags)
    SEQ = SEQ + 1
    KCD2MP_ApplyNpcState(name, sx, sy, sz or 0, 0, 100, flags or 0, 1, SEQ % 65536, math.floor(NOW * 1000))
end
local function tick(name, sx, sy, sz, flags)
    NOW = NOW + 0.05
    packet(name, sx, sy, sz, flags)
    KCD2MP.npcPuppetRunning = true
    KCD2MP_NpcPuppetTick("ext")
end
local function alive() KCD2MP_NpcNativeAlive(1, 1, 0, 0) end

-- ---------------------------------------------------------------- (c2) (c3)
do
    reset(); NOW = 250
    local e = mkEntity("c2_npc", 25, 25, 1)
    alive()
    for i = 1, 19 do alive(); tick("c2_npc", 25 + i * 0.07, 25, 1) end   -- 0.95 s, no answer
    check("c2: silent for 0.95 s while the bind is unanswered", #e.writes == 0, #e.writes)
    for i = 1, 4 do alive(); tick("c2_npc", 26.4 + i * 0.07, 25, 1) end
    check("c2: no answer after 1 s -> Lua writes it", #e.writes >= 2, #e.writes)
    KCD2MP_NpcNativeAck("c2_npc", 1, "ok")
    local w = #e.writes
    for i = 1, 5 do alive(); tick("c2_npc", 26.7 + i * 0.07, 25, 1) end
    check("c2: the late ack still hands it to the DLL", KCD2MP.npcPuppets.c2_npc.nativeOwned == true and #e.writes == w, #e.writes - w)

    reset(); NOW = 280
    local r = mkEntity("c3_npc", 28, 28, 1)
    alive()
    for i = 1, 4 do alive(); tick("c3_npc", 28 + i * 0.07, 28, 1) end
    check("c3: silent while the first bind is in flight", #r.writes == 0, #r.writes)
    KCD2MP_NpcNativeAck("c3_npc", 0, "not-living")
    alive(); tick("c3_npc", 28.4, 28, 1)
    check("c3: a refusal -> Lua writes at once", #r.writes == 1, #r.writes)
    for i = 1, 205 do alive(); tick("c3_npc", 28.4 + (i % 20) * 0.07, 28, 1) end   -- past the 10 s retry
    local nb = 0
    for _, v in ipairs(evts("npc_native")) do if v:find("c3_npc on ", 1, true) then nb = nb + 1 end end
    check("c3: the retry is offered", nb == 2, nb)
    check("c3: and Lua kept writing through it (no hold on a body Lua already writes)", #r.writes >= 205, #r.writes)
    check("c3: no Lua errors", #ERRS == 0, ERRS[1])
end

-- ---------------------------------------------------------------- (b)
do
    reset(); NOW = 100
    local e = mkEntity("b_npc", 10, 10, 0)
    for i = 1, 20 do tick("b_npc", 10 + i * 0.07, 10, 0) end
    check("b: no heartbeat -> no bind event", #evts("npc_native") == 0, #evts("npc_native"))
    check("b: no heartbeat -> Lua writes every tick", #e.writes >= 19, #e.writes)
    check("b: not healthy", KCD2MP_NpcNativeHealthy() ~= true)
    check("b: no Lua errors", #ERRS == 0, ERRS[1])
end

-- ---------------------------------------------------------------- (c) (d)
do
    reset(); NOW = 200
    local e = mkEntity("c_npc", 20, 20, 1)
    alive()
    tick("c_npc", 20.1, 20, 1)
    local ev = evts("npc_native")
    check("c: one bind event after the first healthy tick", #ev == 1, #ev)
    local f = {}
    for w in (ev[1] or ""):gmatch("%S+") do f[#f + 1] = w end
    check("c: bind fields: name on eidHex wuidHex ax ay az delayMs",
          f[1] == "c_npc" and f[2] == "on" and f[3] == string.format("%016X", NEXTID) and f[4] == "05000000000001DC"
          and tonumber(f[5]) == 20 and tonumber(f[6]) == 20 and tonumber(f[8]) == 120 and #f == 8, ev[1])
    local w0 = #e.writes
    check("c: the first tick sends the bind and writes nothing", w0 == 0, w0)
    for i = 1, 5 do alive(); tick("c_npc", 20.1 + i * 0.07, 20, 1) end
    check("c: no Lua write while the first bind is in flight (the DLL blends from the body)", #e.writes == w0, #e.writes - w0)
    check("c: an unanswered bind is not re-sent inside 3 s", #evts("npc_native") == 1, #evts("npc_native"))
    KCD2MP_NpcNativeAck("c_npc", 1, "ok")
    check("d: ack -> the puppet is native-owned", KCD2MP.npcPuppets.c_npc.nativeOwned == true)
    local w1 = #e.writes
    for i = 1, 10 do alive(); tick("c_npc", 20.5 + i * 0.07, 20, 1) end
    check("d: owned -> Lua writes no position", #e.writes == w1, #e.writes - w1)
    check("d: owned -> no Lua detector baseline", KCD2MP.npcPuppets.c_npc.lastWroteX == nil)
    check("d: the gait tick still runs (anim tag moves off idle)", KCD2MP.npcPuppets.c_npc.animTag ~= nil)
    check("d: MP-NPCWRITE bound line", logCount("MP-NPCWRITE npc=c_npc native=bound") == 1)
    check("d: no Lua errors", #ERRS == 0, ERRS[1])

    -- (e) heartbeat stale
    local wS = #e.writes
    NOW = NOW + 3.5   -- no alive() for 3.5 s
    tick("c_npc", 21.3, 20, 1)
    check("e: stale heartbeat -> Lua writes again at once", #e.writes == wS + 1, #e.writes - wS)
    check("e: stale heartbeat -> unbind event", (evts("npc_native")[#evts("npc_native")] or ""):find("c_npc off tick", 1, true) ~= nil, evts("npc_native")[#evts("npc_native")])
    check("e: ownership cleared", KCD2MP.npcPuppets.c_npc.nativeOwned == false)
    local nb = #evts("npc_native")
    alive(); tick("c_npc", 21.4, 20, 1)
    check("e: heartbeat back -> bind re-sent", #evts("npc_native") == nb + 1 and (evts("npc_native")[nb + 1] or ""):find("c_npc on ", 1, true) ~= nil, evts("npc_native")[nb + 1])
    check("e: no Lua errors", #ERRS == 0, ERRS[1])
end

-- ---------------------------------------------------------------- (f)
do
    reset(); NOW = 300
    local e = mkEntity("f_npc", 30, 30, 0)
    alive(); tick("f_npc", 30.1, 30, 0)
    KCD2MP_NpcNativeAck("f_npc", 1, "ok")
    local w = #e.writes
    alive(); tick("f_npc", 30.2, 30, 0)
    check("f: owned (precondition)", #e.writes == w)
    KCD2MP_NpcNativeAck("f_npc", 0, "entity-gone")
    alive(); tick("f_npc", 30.3, 30, 0)
    check("f: a drop -> Lua writes at once", #e.writes == w + 1, #e.writes - w)
    check("f: the drop is logged with its reason", logCount("MP-NPCWRITE npc=f_npc native=dropped reason=entity-gone") == 1, lastLog("MP-NPCWRITE npc=f_npc"))
    local nb = #evts("npc_native")
    for i = 1, 20 do alive(); tick("f_npc", 30.3 + i * 0.05, 30, 0) end   -- 1 s later
    check("f: no re-bind inside the 10 s retry window", #evts("npc_native") == nb, #evts("npc_native") - nb)
    NOW = NOW + 10
    alive(); tick("f_npc", 31.5, 30, 0)
    check("f: re-offered after 10 s", #evts("npc_native") == nb + 1, #evts("npc_native") - nb)
    check("f: no Lua errors", #ERRS == 0, ERRS[1])
end

-- ---------------------------------------------------------------- (g)
do
    reset(); NOW = 400
    local e = mkEntity("g_npc", 40, 40, 0)
    alive(); tick("g_npc", 40.1, 40, 0)
    KCD2MP_NpcNativeAck("g_npc", 1, "ok")
    alive(); tick("g_npc", 40.2, 40, 0, 1)   -- stream says dead
    local ev = evts("npc_native")
    check("g: a dead stream unbinds (down)", (ev[#ev] or ""):find("g_npc off down", 1, true) ~= nil, ev[#ev])
    check("g: ownership cleared", KCD2MP.npcPuppets.g_npc.nativeOwned == false)
    reset(); NOW = 410
    local c = mkEntity("g_car", 41, 41, 0)
    alive(); tick("g_car", 41.1, 41, 0)
    KCD2MP_NpcNativeAck("g_car", 1, "ok")
    alive(); tick("g_car", 41.2, 41, 0, 2 + 16)   -- unconscious + carried
    ev = evts("npc_native")
    check("g: an unconscious/carried stream unbinds too", (ev[#ev] or ""):find("g_car off down", 1, true) ~= nil, ev[#ev])
    check("g: no Lua errors", #ERRS == 0, ERRS[1])
end

-- ---------------------------------------------------------------- (h)
do
    reset(); NOW = 500
    local e = mkEntity("h_npc", 50, 50, 0)
    alive(); tick("h_npc", 50.1, 50, 0)
    KCD2MP_NpcNativeAck("h_npc", 1, "ok")
    alive(); tick("h_npc", 50.2, 50, 0, 8)   -- swing cue
    local hv = evts("npc_native_hold")
    check("h: a swing cue sends a native hold", #hv == 1 and (hv[1] or ""):find("^h_npc %d+$") ~= nil, hv[1])
    local ms = tonumber((hv[1] or ""):match("(%d+)$") or "0")
    check("h: the hold covers the one-shot (0.8 s clip / speed, capped 1.5 s)", ms > 0 and ms <= 1500, ms)
    reset(); NOW = 510
    mkEntity("h_lua", 51, 51, 0)
    tick("h_lua", 51.1, 51, 0)
    tick("h_lua", 51.2, 51, 0, 8)
    check("h: no hold event for a puppet Lua writes (no bind)", #evts("npc_native_hold") == 0)
    check("h: no Lua errors", #ERRS == 0, ERRS[1])
end

-- ---------------------------------------------------------------- (i)
do
    reset(); NOW = 600
    local e = mkEntity("i_npc", 60, 60, 0)
    alive(); tick("i_npc", 60.1, 60, 0)
    KCD2MP_NpcNativeAck("i_npc", 1, "ok")
    KCD2MP_SetNpcNativeWrite("off")
    check("i: off -> cfg event 'off on'", (evts("npc_native_cfg")[#evts("npc_native_cfg")] or "") == "off on", evts("npc_native_cfg")[#evts("npc_native_cfg")])
    check("i: off -> the puppet is no longer owned", KCD2MP.npcPuppets.i_npc.nativeOwned == false)
    local w = #e.writes
    alive(); tick("i_npc", 60.2, 60, 0)
    check("i: off -> Lua writes", #e.writes == w + 1)
    local nb = #evts("npc_native")
    for i = 1, 5 do alive(); tick("i_npc", 60.2 + i * 0.05, 60, 0) end
    check("i: off -> no bind events", #evts("npc_native") == nb)
    KCD2MP_SetNpcNativeWrite("on")
    alive(); tick("i_npc", 60.6, 60, 0)
    check("i: on -> bind again", #evts("npc_native") == nb + 1, #evts("npc_native") - nb)
    KCD2MP_SetNpcNativeWrite(nil)
    check("i: bare reports without changing", KCD2MP.npcNativeWrite == true and (lastLog("MP-NPCWRITE native_write=") or ""):find("native_write=on", 1, true) ~= nil)
    check("i: no Lua errors", #ERRS == 0, ERRS[1])
end

-- ---------------------------------------------------------------- (j)
do
    reset(); NOW = 700
    local e = mkEntity("j_seat", 70, 70, 0)
    STATE.j_seat = "SittingIdle"
    tick("j_seat", 70.5, 70, 0)
    check("j: pause issued", cmdCount("wh_ai_PauseNPC j_seat") == 1, table.concat(CMDS, " | "))
    check("j: Stance reset issued after the pause", cmdCount("wh_ai_NPCStateResetElement j_seat Stance") == 1)
    check("j: Unstance reset issued", cmdCount("wh_ai_NPCStateResetElement j_seat Unstance") == 1)
    local iP, iS = 0, 0
    for i, c in ipairs(CMDS) do
        if c == "wh_ai_PauseNPC j_seat" then iP = i end
        if c == "wh_ai_NPCStateResetElement j_seat Stance" then iS = i end
    end
    check("j: the reset follows the pause", iP > 0 and iS > iP)
    STATE.j_seat = "MotionIdle"
    for i = 1, 14 do tick("j_seat", 70.5 + i * 0.01, 70, 0) end   -- 0.7 s
    check("j: MP-DETACH carries before->after", logCount("MP-DETACH npc=j_seat stance=ok unstance=ok result=SittingIdle->MotionIdle changed=1 why=puppet-start") == 1, lastLog("MP-DETACH"))
    check("j: one call per puppet start (not per tick)", cmdCount("wh_ai_NPCStateResetElement j_seat Stance") == 1)
    -- dialogue
    reset(); NOW = 710
    local d = mkEntity("j_talk", 71, 71, 0)
    d.inDialog = true
    tick("j_talk", 71.2, 71, 0)
    check("j: in dialogue -> no reset, logged skip", cmdCount("wh_ai_NPCStateResetElement j_talk") == 0 and logCount("MP-DETACH npc=j_talk stance=skipped unstance=skipped result=skipped-dialog") == 1, lastLog("MP-DETACH"))
    -- cutscene
    reset(); NOW = 720
    mkEntity("j_cut", 72, 72, 0)
    KCD2MP.cutsceneActive = true
    tick("j_cut", 72.2, 72, 0)
    check("j: cutscene -> no reset, logged skip", cmdCount("wh_ai_NPCStateResetElement j_cut") == 0 and logCount("result=skipped-cutscene") == 1, lastLog("MP-DETACH"))
    -- toggle off
    reset(); NOW = 730
    mkEntity("j_off", 73, 73, 0)
    KCD2MP_SetNpcDetach("off")
    tick("j_off", 73.2, 73, 0)
    check("j: mp_npc_detach off -> nothing issued", cmdCount("wh_ai_NPCStateResetElement") == 0 and cmdCount("wh_ai_PauseNPC j_off") == 1)
    -- the authority never pauses, so never detaches
    reset(); NOW = 740
    mkEntity("j_auth", 74, 74, 0)
    KCD2MP.hitSensorOn = true
    tick("j_auth", 74.2, 74, 0)
    check("j: the authority neither pauses nor detaches", cmdCount("wh_ai_NPCStateResetElement") == 0 and cmdCount("wh_ai_PauseNPC") == 0)
    check("j: no Lua errors", #ERRS == 0, ERRS[1])
end

-- ---------------------------------------------------------------- (k)
do
    reset(); NOW = 800
    KCD2MP_ApplyPreset("legacy")
    check("k: legacy = native off, detach off", KCD2MP.npcNativeWrite == false and KCD2MP.npcDetach == false)
    check("k: legacy logs both rows", logCount("MP-PRESET name=legacy set=npc_native_write") == 1 and logCount("MP-PRESET name=legacy set=npc_detach") == 1)
    KCD2MP_ApplyPreset("clean")
    check("k: clean = native on, detach on", KCD2MP.npcNativeWrite == true and KCD2MP.npcDetach == true)
    check("k: clean logs both rows", logCount("MP-PRESET name=clean set=npc_native_write") == 1 and logCount("MP-PRESET name=clean set=npc_detach") == 1)
    check("k: no Lua errors", #ERRS == 0, ERRS[1])
end

-- ---------------------------------------------------------------- (l)
do
    reset(); NOW = 900
    KCD2MP_NpcTrace(nil)
    check("l: bare prints usage, emits nothing", logCount("MP-NPCTRACE usage") == 1 and #evts("npc_trace") == 0)
    KCD2MP_NpcTrace("ttkc_slama")
    check("l: default 10 s", evts("npc_trace")[1] == "ttkc_slama 10", evts("npc_trace")[1])
    KCD2MP_NpcTrace("ttkc_slama 500")
    check("l: clamped to 120 s", evts("npc_trace")[2] == "ttkc_slama 120", evts("npc_trace")[2])
    KCD2MP_NpcTrace("stop")
    check("l: stop -> last name, 0", evts("npc_trace")[3] == "ttkc_slama 0", evts("npc_trace")[3])
    KCD2MP_NpcTrace("bad;name")
    check("l: a non-entity name is refused", #evts("npc_trace") == 3)
    for _, c in ipairs({ "mp_npc_native_write", "mp_npc_detach", "mp_npc_trace" }) do
        check("l: " .. c .. " registered with the unquoted %line",
              CCMDS[c] ~= nil and CCMDS[c].body:find("(%line)", 1, true) ~= nil and CCMDS[c].body:find('"%line"', 1, true) == nil, CCMDS[c] and CCMDS[c].body)
    end
    KCD2MP_NpcTraceDone(417, "C:\\game\\kcdmp-trace-x.csv")
    check("l: trace done is logged", logCount("MP-NPCTRACE done rows=417") == 1)
    check("l: no Lua errors", #ERRS == 0, ERRS[1])
end

-- ---------------------------------------------------------------- (m)
do
    reset(); NOW = 1000
    mkEntity("m_sil", 80, 80, 0)
    alive(); tick("m_sil", 80.1, 80, 0)
    KCD2MP_NpcNativeAck("m_sil", 1, "ok")
    NOW = NOW + 3.2   -- stream silent past releaseS (3 s)
    alive()
    KCD2MP.npcPuppetRunning = true
    KCD2MP_NpcPuppetTick("ext")
    local ev = evts("npc_native")
    check("m: silence release unbinds", (ev[#ev] or ""):find("m_sil off silence", 1, true) ~= nil, ev[#ev])
    check("m: the puppet is gone", KCD2MP.npcPuppets.m_sil == nil)
    reset(); NOW = 1100
    mkEntity("m_rel", 81, 81, 0)
    alive(); tick("m_rel", 81.1, 81, 0)
    KCD2MP_NpcNativeAck("m_rel", 1, "ok")
    KCD2MP_OnChainDeadRestart("npcsync")
    ev = evts("npc_native")
    check("m: a reload unbinds every puppet", (ev[#ev] or ""):find("m_rel off reload", 1, true) ~= nil, ev[#ev])
    check("m: no Lua errors", #ERRS == 0, ERRS[1])
end

-- ---------------------------------------------------------------- (n)
-- WO-118 Phase 2b: the peer's ghost on the native writer. A ghost built
-- directly (as Test-GhostInterpSynthetic does: the spawn path is engine).
do
    reset(); NOW = 1200
    KCD2MP.ghosts = {}; KCD2MP.labelCache = {}; KCD2MP.ghostDead = {}; KCD2MP.ghostHealth = {}; KCD2MP.ghostInMenu = {}
    KCD2MP._chainLeakSeen = {}; KCD2MP._chainProbe = {}
    KCD2MP.interpRunning = true; KCD2MP._interpAliveAt = NOW; KCD2MP.interpGen = KCD2MP.interpGen or 1
    local e = mkEntity("kcd2mp_7", 90, 90, 0)
    local ist = { px = 90, py = 90, pz = 0, pr = 0, tx = 90, ty = 90, tz = 0, tr = 0, cx = 90, cy = 90, cz = 0, cr = 0,
                  alpha = 1.0, alphaStep = 0.25, vx = 0, vy = 0, vz = 0, lastPacketX = 90, lastPacketY = 90,
                  ticksSincePacket = 0, packetCount = 0, animTag = "idle", smoothedSpeed = 0,
                  prevCx = 90, prevCy = 90, speedDropTicks = 0, spawnedAtClock = NOW }
    KCD2MP.ghosts["7"] = { entity = e, entityId = e.id, istate = ist }
    local function gtick(x, riding)
        NOW = NOW + 0.03
        KCD2MP_UpdateGhost("7", x, 90, 0, 0, riding == true)
        KCD2MP_InterpTick("ext")
    end
    for i = 1, 5 do gtick(90 + i * 0.04) end
    check("n: no heartbeat -> no ghost bind, Lua writes", #evts("npc_native") == 0 and #e.writes >= 5, #e.writes)
    alive(); gtick(90.3)
    local ev = evts("npc_native")
    check("n: healthy -> ghost bind event for kcd2mp_7 with the ghost delay",
          #ev == 1 and ev[1]:find("^kcd2mp_7 on ") ~= nil and ev[1]:find(" 100$") ~= nil, ev[1])
    KCD2MP_NpcNativeAck("kcd2mp_7", 1, "ok")
    check("n: the ack lands on the ghost's istate", ist.nativeOwned == true)
    local w = #e.writes
    for i = 1, 6 do alive(); gtick(90.3 + i * 0.04) end
    check("n: owned ghost -> Lua writes no position", #e.writes == w, #e.writes - w)
    ist.oneShotUntil = NOW + 0.9
    alive(); gtick(90.6)
    local hv = evts("npc_native_hold")
    check("n: a one-shot on an owned ghost sends a native hold", #hv == 1 and hv[1]:find("^kcd2mp_7 %d+$") ~= nil, hv[1])
    alive(); gtick(90.62)
    check("n: one hold per one-shot window", #evts("npc_native_hold") == 1)
    ist.oneShotUntil = nil
    alive(); gtick(90.7, true)
    ev = evts("npc_native")
    check("n: a riding ghost unbinds", (ev[#ev] or ""):find("kcd2mp_7 off ghost", 1, true) ~= nil and ist.nativeOwned == false, ev[#ev])
    alive(); gtick(90.8, false)
    ev = evts("npc_native")
    check("n: dismounted -> bound again", (ev[#ev] or ""):find("^kcd2mp_7 on ") ~= nil, ev[#ev])
    KCD2MP_NpcNativeAck("kcd2mp_7", 0, "entity-gone")
    check("n: a drop hands the ghost back to Lua", ist.nativeOwned == false and ist.nativeRetryAt ~= nil)
    check("n: no Lua errors", #ERRS == 0, ERRS[1])
end

-- Summary, in the shared driver's contract (Test-NpcSmoothSynthetic.ps1 reads
-- the global OUT).
local pass, fail = 0, 0
for _, r in ipairs(RESULTS) do if r:sub(1, 4) == "PASS" then pass = pass + 1 else fail = fail + 1 end end
OUT = table.concat(RESULTS, "\n") .. string.format("\n%d passed, %d failed", pass, fail)
