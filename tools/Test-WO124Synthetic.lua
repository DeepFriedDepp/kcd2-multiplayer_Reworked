-- WO-124 synthetic test, against the real kdcmp.lua under MoonSharp: the
-- Lua half of the joiner's side of the join.
--
--   (a) the WO124-BUILD marker and mp_join_henry (registered with the
--       unquoted %line); the load mirrors join_henry=auto to the agent
--   (b) the HOST's session mode: KCD2MP_Wo124SessionMode(true) lets the
--       joiner's save lock hold with its own mp_shared_world off; (false)
--       releases it; nothing locks with neither
--   (c) KCD2MP_Wo124Where: no player / no Dude -> menu; a player -> world;
--       a load in progress -> loading
--   (d) KCD2MP_Wo124Lock answers "lock=held" with the lock read back
--   (e) KCD2MP_Wo124Henry answers money, class:amount items and skills
--   (f) KCD2MP_Wo124LoadGame runs wh_sys_LoadGame <pl> <name>; refuses a bad
--       playline or a name with anything but [A-Za-z0-9_]
--   (g) mp_join_henry: auto | playlineN/file accepted, anything else refused
--
-- What this proves: the Lua half behaves as documented. What it does NOT
-- prove: anything about the engine, the agent or the DLL (the join itself is
-- live-tested, docs/WO-124-findings.md).

NOW = 0
os.clock = function() return NOW end
LOG = {}; TIMERS = {}; ENTS = {}; ERRS = {}; TOASTS = {}; SPHERE = {}
CMDS = {}; DRAWS = {}; SPAWNS = {}; CCMDS = {}; LOCKS = {}

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
-- The engine's script lock: a second add of a held name is refused (WO-122).
Game.AddSaveLock = function(name, desc) if LOCKS[name] then return false end LOCKS[name] = true; return true end
Game.RemoveSaveLock = function(name) local had = LOCKS[name] == true; LOCKS[name] = nil; return had end
LOADING = false
Game.IsLoadingEngineSaveGame = function() return LOADING end
UIAction = mkstub()
UIAction.CallFunction = function(panel, inst, fn, text) TOASTS[#TOASTS + 1] = tostring(text) end
WORLD_T = 1000
Calendar = { GetWorldTime = function() return WORLD_T end, SetWorldTime = function(t) WORLD_T = t end }
XGenAIModule = mkstub()
ITEMS = {}
ItemManager = { GetItem = function(id) return ITEMS[id] end }

local PLAYER = { id = 1, GetName = function(self) return "Dude" end,
           GetWorldPos = function() return { x = 0, y = 0, z = 0 } end,
           GetWorldAngles = function() return { x = 0, y = 0, z = 0 } end,
           GetLinkedParent = function() return nil end,
           actor = { GetHealth = function() return 100 end, IsDead = function() return false end },
           inventory = { GetMoney = function() return 15.1 end, GetInventoryTable = function() return { "i1", "i2" } end },
           soul = { GetSkillLevel = function(self, n) return 7 end, GetSkillProgress = function(self, n) return 0.25 end } }
player = PLAYER

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

-- ---------------------------------------------------------------- (a)
check("a: WO124-BUILD marker logged once", logCount("WO124-BUILD") == 1, lastLog("WO124-BUILD"))
check("a: mp_join_henry registered with the unquoted %line",
      CCMDS.mp_join_henry ~= nil and CCMDS.mp_join_henry.body == "KCD2MP_SetJoinHenry(%line)", CCMDS.mp_join_henry and CCMDS.mp_join_henry.body)
check("a: the load mirrors join_henry=auto", (evts("wo124_henry_cfg")[1] or "") == "auto", evts("wo124_henry_cfg")[1])
check("a: dormant defaults (no session mode, lock free)", KCD2MP.w124.sessionShared == false and next(LOCKS) == nil)
check("a: no Lua errors at load", #ERRS == 0, ERRS[1])

-- ---------------------------------------------------------------- (b)
do
    ERRS = {}
    KCD2MP.w122.sharedWorld = false
    check("b: no toggle, no host mode -> the lock is refused", KCD2MP_HostOnlyLock(true, "tick") == false and LOCKS.kcdmp_host_only == nil)
    KCD2MP_Wo124SessionMode(true)
    check("b: the host's shared world is followed", KCD2MP.w124.sessionShared == true and lastLog("WO124-SESSION") ~= nil, lastLog("WO124-SESSION"))
    check("b: with the host's mode the lock holds (toggle off here)", KCD2MP_HostOnlyLock(true, "join") == true and LOCKS.kcdmp_host_only == true)
    KCD2MP_Wo124SessionMode(false)
    check("b: the host going separate releases the lock", LOCKS.kcdmp_host_only == nil and KCD2MP.w122.lockHeld == false)
    check("b: no Lua errors", #ERRS == 0, ERRS[1])
end

-- ---------------------------------------------------------------- (c)
do
    ERRS = {}
    player = nil; ENTS = {}; LOADING = false
    KCD2MP_Wo124Where()
    local w = evts("wo124_where")
    check("c: no player, no Dude -> menu", w[#w] == "menu", w[#w])
    player = PLAYER
    KCD2MP_Wo124Where()
    w = evts("wo124_where")
    check("c: a player -> world", w[#w] == "world", w[#w])
    LOADING = true
    KCD2MP_Wo124Where()
    w = evts("wo124_where")
    check("c: a load in progress -> loading", w[#w] == "loading", w[#w])
    LOADING = false
    check("c: no Lua errors", #ERRS == 0, ERRS[1])
end

-- ---------------------------------------------------------------- (d) (e)
do
    ERRS = {}
    LOCKS = {}
    KCD2MP.w122.lockHeld = false
    KCD2MP_Wo124SessionMode(true)
    KCD2MP_Wo124Lock("t0k1")
    local r = evts("wo124_reply")
    check("d: the lock reply carries the token and 'held'", (r[#r] or ""):find("^t0k1 lock=held") ~= nil, r[#r])
    ITEMS = { i1 = { class = "aaaa", amount = 3 }, i2 = { class = "bbbb" } }
    KCD2MP_Wo124Henry("t0k2")
    r = evts("wo124_reply")
    local h = r[#r] or ""
    check("e: Henry reply: money", h:find("^t0k2 money=15%.10 ") ~= nil, h)
    check("e: Henry reply: class:amount items", h:find("items=aaaa:3;bbbb:1 ", 1, true) ~= nil, h)
    check("e: Henry reply: skills", h:find("skills=fencing:7:0.2500", 1, true) ~= nil, h)
    KCD2MP_Wo124SessionMode(false)
    check("d/e: no Lua errors", #ERRS == 0, ERRS[1])
end

-- ---------------------------------------------------------------- (f) (g)
do
    ERRS = {}; CMDS = {}
    check("f: a valid load runs", KCD2MP_Wo124LoadGame(2, "mpworld1a2b3c4d", "join") == true and CMDS[#CMDS] == "wh_sys_LoadGame 2 mpworld1a2b3c4d", CMDS[#CMDS])
    local n = #CMDS
    check("f: playline 7 is refused", KCD2MP_Wo124LoadGame(7, "save021", "x") == false and #CMDS == n)
    check("f: a name with a space is refused", KCD2MP_Wo124LoadGame(1, "save 021", "x") == false and #CMDS == n)
    check("f: a name with a path is refused", KCD2MP_Wo124LoadGame(1, "../x", "x") == false and #CMDS == n)
    check("g: mp_join_henry playline2/save021", KCD2MP_SetJoinHenry("playline2/save021") == true and KCD2MP.w124.henry == "playline2/save021"
          and (evts("wo124_henry_cfg")[#evts("wo124_henry_cfg")] or "") == "playline2/save021")
    check("g: mp_join_henry junk refused", KCD2MP_SetJoinHenry("C:/x/y.whs") == false and KCD2MP.w124.henry == "playline2/save021")
    check("g: mp_join_henry auto", KCD2MP_SetJoinHenry("auto") == true and KCD2MP.w124.henry == "auto")
    check("g: bare mp_join_henry reports", KCD2MP_SetJoinHenry("") == true and KCD2MP.w124.henry == "auto")
    check("f/g: no Lua errors", #ERRS == 0, ERRS[1])
end

-- Summary, in the shared driver's contract (Test-NpcSmoothSynthetic.ps1 reads
-- OUT: one PASS/FAIL line per check, then the totals).
local pass, fail = 0, 0
for _, r in ipairs(RESULTS) do if r:sub(1, 4) == "PASS" then pass = pass + 1 else fail = fail + 1 end end
OUT = table.concat(RESULTS, "\n") .. string.format("\n%d passed, %d failed", pass, fail)
