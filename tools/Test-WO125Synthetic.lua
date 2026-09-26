-- WO-125 synthetic test, against the real kdcmp.lua under MoonSharp: the
-- Lua half of continuity (per-world Henry files). Harness copied from
-- Test-WO124Synthetic.lua.
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
-- What this proves: the Lua half behaves as documented. What it does NOT
-- prove: anything about the engine or the agent (live: docs/WO-125-findings.md).

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
check("a: WO125-BUILD marker logged once", logCount("WO125-BUILD") == 1, lastLog("WO125-BUILD"))
check("a: mp_henry_reset registered", CCMDS.mp_henry_reset ~= nil and CCMDS.mp_henry_reset.body == "KCD2MP_Wo125Reset()")
check("a: mp_henry_files registered with the unquoted %line",
      CCMDS.mp_henry_files ~= nil and CCMDS.mp_henry_files.body == "KCD2MP_Wo125Files(%line)", CCMDS.mp_henry_files and CCMDS.mp_henry_files.body)
check("a: mp_join_henry help names fresh", CCMDS.mp_join_henry ~= nil and CCMDS.mp_join_henry.help:find("fresh", 1, true) ~= nil)
check("a: nothing is answered at load (no wo125_choice)", #evts("wo125_choice") == 0)
check("a: no Lua errors at load", #ERRS == 0, ERRS[1])

-- ---------------------------------------------------------------- (b)
do
    ERRS = {}
    check("b: mp_join_henry fresh accepted", KCD2MP_SetJoinHenry("fresh") == true and KCD2MP.w124.henry == "fresh")
    local c = evts("wo125_choice")
    check("b: typing it answers the agent (fresh)", #c == 1 and c[1] == "fresh", c[#c])
    check("b: auto is the 'bring my character' answer", KCD2MP_SetJoinHenry("auto") == true and evts("wo125_choice")[2] == "auto")
    check("b: playlineN/file answers too", KCD2MP_SetJoinHenry("playline3/permanent002") == true and evts("wo125_choice")[3] == "playline3/permanent002")
    local n = #evts("wo125_choice")
    check("b: bare only reports (no answer)", KCD2MP_SetJoinHenry("") == true and #evts("wo125_choice") == n)
    check("b: the unsubstituted placeholder only reports", KCD2MP_SetJoinHenry("%line") == true and #evts("wo125_choice") == n)
    check("b: junk refused, no answer", KCD2MP_SetJoinHenry("new") == false and #evts("wo125_choice") == n and KCD2MP.w124.henry == "playline3/permanent002")
    check("b: the cfg mirror still follows (wo124_henry_cfg)", (evts("wo124_henry_cfg")[#evts("wo124_henry_cfg")] or "") == "playline3/permanent002")
    KCD2MP_SetJoinHenry("auto")
    check("b: no Lua errors", #ERRS == 0, ERRS[1])
end

-- ---------------------------------------------------------------- (c)
do
    ERRS = {}; TIMERS = {}
    local qs = 0
    Game.QuickSave = function() qs = qs + 1; return true end
    local ok = KCD2MP_Wo125Snapshot("s1")
    local r = evts("wo124_reply")
    check("c: QuickSave requested once", ok == true and qs == 1)
    check("c: reply carries the token and ok=true", r[#r] == "s1 ok=true", r[#r])
    check("c: the hitch window is armed (a per-frame timer)", #TIMERS >= 1 and TIMERS[1].ms == 0)
    check("c: logged", lastLog("WO125-SNAPSHOT quicksave=requested") ~= nil, lastLog("WO125-SNAPSHOT"))
    Game.QuickSave = function() return false end
    ok = KCD2MP_Wo125Snapshot("s2")
    r = evts("wo124_reply")
    check("c: the engine refusing it -> ok=false", ok == false and r[#r] == "s2 ok=false", r[#r])
    Game.QuickSave = nil
    ok = KCD2MP_Wo125Snapshot("s3")
    r = evts("wo124_reply")
    check("c: no QuickSave bind -> ok=false", ok == false and r[#r] == "s3 ok=false", r[#r])
    check("c: counters", KCD2MP.w125.snaps == 1 and KCD2MP.w125.snapRefused == 2)
    check("c: no Lua errors", #ERRS == 0, ERRS[1])
end

-- ---------------------------------------------------------------- (d)
do
    ERRS = {}
    PLAYER.soul.GetNameStringId = function(self) return "char_26_uiName" end
    KCD2MP_Wo125PlayerIsHenry("h1")
    local r = evts("wo124_reply")
    check("d: char_26_uiName is Henry", r[#r] == "h1 henry=yes id=char_26_uiName", r[#r])
    PLAYER.soul.GetNameStringId = function(self) return "char_BOHUTA_uiName" end
    KCD2MP_Wo125PlayerIsHenry("h2")
    r = evts("wo124_reply")
    check("d: anyone else is not", r[#r] == "h2 henry=no id=char_BOHUTA_uiName", r[#r])
    player = nil
    KCD2MP_Wo125PlayerIsHenry("h3")
    r = evts("wo124_reply")
    check("d: no player -> not Henry", r[#r] == "h3 henry=no id=?", r[#r])
    player = PLAYER
    check("d: the missing player is caught (one pcall error, nothing else)", #ERRS <= 1, ERRS[1])
end

-- ---------------------------------------------------------------- (e)
do
    ERRS = {}
    check("e: mp_henry_files lists", KCD2MP_Wo125Files("") == true and evts("wo125_files")[1] == "")
    check("e: mp_henry_files delete <world>", KCD2MP_Wo125Files("delete 0a1b2c3d4e") == true and evts("wo125_files")[2] == "delete 0a1b2c3d4e")
    check("e: junk refused", KCD2MP_Wo125Files("rm -rf") == false and #evts("wo125_files") == 2)
    check("e: the placeholder lists", KCD2MP_Wo125Files("%line") == true and evts("wo125_files")[3] == "")
    KCD2MP_Wo125FilesShow("0a1b2c3d4e  last joined 2026-09-25  3 snapshot(s)|ffeeddccbb  last joined 2026-06-01  1 snapshot(s)")
    check("e: the agent's list is logged one line per world", logCount("WO125-FILES ") == 2, lastLog("WO125-FILES"))
    check("e: mp_henry_reset asks the agent", KCD2MP_Wo125Reset() == true and #evts("wo125_reset") == 1)
    check("e: no Lua errors", #ERRS == 0, ERRS[1])
end

-- ---------------------------------------------------------------- (f)
do
    ERRS = {}
    System.GetCVar = function(n) if n == "wh_sys_LastLoadedSave" then return "%USER%/saves/playline2/mpworld1a2b3c4d.whs" end return "0" end
    KCD2MP_Wo125LastLoaded("l1")
    local r = evts("wo124_reply")
    check("f: the last-loaded save, base name only (no folder)", r[#r] == "l1 last=mpworld1a2b3c4d", r[#r])
    System.GetCVar = function(n) if n == "wh_sys_LastLoadedSave" then return "C:\\x\\saves\\playline1\\quicksave022.whs" end return "0" end
    KCD2MP_Wo125LastLoaded("l2")
    r = evts("wo124_reply")
    check("f: a backslash path too", r[#r] == "l2 last=quicksave022", r[#r])
    System.GetCVar = function() return nil end
    KCD2MP_Wo125LastLoaded("l3")
    r = evts("wo124_reply")
    check("f: unreadable -> nil (the agent calls it inconclusive)", r[#r] == "l3 last=nil", r[#r])
    System.GetCVar = function() return "0" end
    check("f: no Lua errors", #ERRS == 0, ERRS[1])
end

-- Summary, in the shared driver's contract (Test-NpcSmoothSynthetic.ps1 reads
-- OUT: one PASS/FAIL line per check, then the totals).
local pass, fail = 0, 0
for _, r in ipairs(RESULTS) do if r:sub(1, 4) == "PASS" then pass = pass + 1 else fail = fail + 1 end end
OUT = table.concat(RESULTS, "\n") .. string.format("\n%d passed, %d failed", pass, fail)
