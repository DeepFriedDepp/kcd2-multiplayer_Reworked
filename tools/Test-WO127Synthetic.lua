-- WO-127 synthetic test, against the real kdcmp.lua under MoonSharp: the
-- Lua half of the leash recorder. Harness copied from Test-WO125Synthetic.lua.
--
--   (a) mp_leash_trace registered with the unquoted %line; default off; no event at load
--   (b) on / off / bare / junk: only a change tells the agent (leash_trace)
--   (c) KCD2MP_LeashCtx: dialogue and fight flags while on; silent while off
--
-- What this proves: the Lua half behaves as documented. What it does NOT
-- prove: the native sample or the CSV (client tests + live: docs/WO-127-findings.md).
--[[ WO-125 header kept below for the stubs:
--
--   (a) the WO125-BUILD marker; mp_henry_reset / mp_henry_files registered
--       (mp_henry_files with the unquoted %line, like mp_join_henry)
--   (b) mp_join_henry now takes auto | fresh | playlineN/file; typing it sends
--       the first-join answer to the agent (wo125_choice); bare only reports
--   (c) KCD2MP_Wo125Snapshot: Game.QuickSave requested -> "ok=true" with the
--       token, the hitch window armed; refused (false) or missing -> "ok=false"
--   (d) KCD2MP_Wo125PlayerIsHenry: char_26_uiName = Henry, anything else not
--   (e) mp_henry_files: list / delete <world> / junk refused; the agent's
--       answer is logged one line per world; mp_henry_reset emits wo125_reset
--   (f) KCD2MP_Wo125LastLoaded: the engine's last-loaded save, base name only
--
-- (live: docs/WO-125-findings.md). ]]

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
check("a: mp_leash_trace registered with the unquoted %line",
      CCMDS.mp_leash_trace ~= nil and CCMDS.mp_leash_trace.body == "KCD2MP_SetLeashTrace(%line)", CCMDS.mp_leash_trace and CCMDS.mp_leash_trace.body)
check("a: help names the CSV and WO-128", CCMDS.mp_leash_trace ~= nil and CCMDS.mp_leash_trace.help:find("WO-128", 1, true) ~= nil)
check("a: default off", KCD2MP.leashTrace == false)
check("a: nothing emitted at load", #evts("leash_trace") == 0 and #evts("leash_ctx") == 0)
check("a: no Lua errors at load", #ERRS == 0, ERRS[1])

-- ---------------------------------------------------------------- (b)
do
    ERRS = {}
    check("b: bare only reports", KCD2MP_SetLeashTrace("") == true and #evts("leash_trace") == 0 and KCD2MP.leashTrace == false)
    check("b: the unsubstituted placeholder only reports", KCD2MP_SetLeashTrace("%line") == true and #evts("leash_trace") == 0)
    check("b: on tells the agent", KCD2MP_SetLeashTrace("on") == true and KCD2MP.leashTrace == true and evts("leash_trace")[1] == "on")
    check("b: logged in plain words", lastLog("WO127-LEASH trace=on") ~= nil, lastLog("WO127-LEASH"))
    check("b: junk refused, state kept", KCD2MP_SetLeashTrace("maybe") == false and KCD2MP.leashTrace == true and #evts("leash_trace") == 1)
    check("b: OFF (any case) tells the agent", KCD2MP_SetLeashTrace("OFF") == true and KCD2MP.leashTrace == false and evts("leash_trace")[2] == "off")
    check("b: no Lua errors", #ERRS == 0, ERRS[1])
end

-- ---------------------------------------------------------------- (c)
do
    ERRS = {}
    KCD2MP_LeashCtx()
    check("c: silent while off", #evts("leash_ctx") == 0)
    KCD2MP_SetLeashTrace("on")
    local inDlg, danger = false, 0
    player.human = { IsInDialog = function() return inDlg end }
    player.soul.IsInCombatDanger = function() return danger end
    KCD2MP_LeashCtx()
    check("c: neither", evts("leash_ctx")[1] == "d=0 f=0", evts("leash_ctx")[1])
    inDlg, danger = true, 1
    KCD2MP_LeashCtx()
    check("c: dialogue and fight", evts("leash_ctx")[2] == "d=1 f=1", evts("leash_ctx")[2])
    player.human = { IsInDialog = function() error("engine said no") end }
    danger = true
    KCD2MP_LeashCtx()
    check("c: a failing engine call reads as 0, fight=true boolean reads as 1", evts("leash_ctx")[3] == "d=0 f=1", evts("leash_ctx")[3])
    KCD2MP_SetLeashTrace("off")
    ERRS = {}   -- the deliberate engine error above was counted by the pcall wrapper
    check("c: no Lua errors", #ERRS == 0, ERRS[1])
end

-- Summary, in the shared driver's contract (Test-NpcSmoothSynthetic.ps1 reads
-- OUT: one PASS/FAIL line per check, then the totals).
local pass, fail = 0, 0
for _, r in ipairs(RESULTS) do if r:sub(1, 4) == "PASS" then pass = pass + 1 else fail = fail + 1 end end
OUT = table.concat(RESULTS, "\n") .. string.format("\n%d passed, %d failed", pass, fail)
