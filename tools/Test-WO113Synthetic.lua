-- WO-113 synthetic test, against the real kdcmp.lua under MoonSharp.
--
-- The respawn policy is native (KCDMP.dll respawn.cpp); Lua owns only the
-- console toggle and forwards it the WO-27 state-mirror way. This suite pins
-- that half:
--   (a) shipped default: respawn ON; the WO113-BUILD marker is logged once at
--       load and names the shipped behaviour
--   (b) mp_respawn is registered with the %line placeholder (not %LINE, which
--       never matched -- WO-106/WO-109) and documents on|off
--   (c) mp_respawn off: the flag flips, ONE respawn_toggle event carries "off"
--       for the agent (-> pipe 0x0D -> the DLL), MP-RESPAWN-TOGGLE says
--       set=off was=on
--   (d) mp_respawn on: back, one event "on"
--   (e) a bare mp_respawn reports and changes nothing, emits nothing
--   (f) a bad argument is refused, nothing changes, nothing is emitted
--
-- Driven by Test-WO113Synthetic.ps1 through the WO-77 MoonSharp driver.
-- What this proves: the Lua half behaves as documented. What it does NOT
-- prove: anything native -- see docs/WO-113-progress.md for the live runs.
--
-- Part 1: engine stubs + a fake clock (the WO-108 harness, verbatim).

NOW = 0
os.clock = function() return NOW end
LOG = {}; TIMERS = {}; ENTS = {}; ERRS = {}; TOASTS = {}; SPHERE = {}
CMDS = {}; DRAWS = {}; SPAWNS = {}; CCMDS = {}

local function mkstub()
    return setmetatable({}, { __index = function(_, k) return function(...) return nil end end })
end
System = mkstub()
System.LogAlways = function(s) LOG[#LOG + 1] = tostring(s) end
System.GetCVarValue = function() return "0" end
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
XGenAIModule.SpawnEntity = function(t)
    SPAWNS[#SPAWNS + 1] = t
    local e = { class = t.ClassName, id = 9000 + #SPAWNS }
    e.GetName = function(self) return t.Name end
    e.GetWorldPos = function(self) return { x = 0, y = 0, z = 0 } end
    ENTS[t.Name] = e
    return e
end

player = { id = 1, GetName = function(self) return "Dude" end,
           GetWorldPos = function() return { x = 0, y = 0, z = 0 } end,
           GetWorldAngles = function() return { x = 0, y = 0, z = 0 } end,
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
local function cmdCount(pat)
    local n = 0
    for _, c in ipairs(CMDS) do if string.find(c, pat, 1, true) then n = n + 1 end end
    return n
end

local function evtCount(name, arg)
    local n = 0
    for _, l in ipairs(LOG) do
        if string.find(l, "[KCD2-MP-EVT] v1 ", 1, true) and string.find(l, " " .. name .. " " .. arg, 1, true) then n = n + 1 end
    end
    return n
end

-- (a) default + marker, read before any scenario touches them
check("a: respawn ships ON", KCD2MP.respawnEnabled == true, tostring(KCD2MP.respawnEnabled))
check("a: WO113-BUILD logged once at load", logCount("WO113-BUILD respawn=on ") == 1, lastLog("WO113-BUILD"))
local b = lastLog("WO113-BUILD") or ""
check("a: marker names the knockdown rule, the StopFight disengage and the black hold",
      string.find(b, "knockdown_rule=unarmed-recent-attacker-only knockdown=disengage-stopfight black_hold_s=6", 1, true) ~= nil, b)
check("a: marker names the grave and the 100 m wake rule",
      string.find(b, "grave=all-but-quest-items grave_model=conciliation_cross_d grave_expiry_game_days=3 wake=nearest-hangoverSpot-100m+", 1, true) ~= nil, b)

-- (b) console registration
local c = CCMDS["mp_respawn"]
check("b: mp_respawn registered", c ~= nil)
check("b: body passes the argument with %line", c ~= nil and string.find(c.body, "KCD2MP_SetRespawn(%line)", 1, true) ~= nil, c and c.body)
check("b: body does not use %LINE", c ~= nil and not string.find(c.body, "%LINE", 1, true))
check("b: help documents on|off", c ~= nil and string.find(c.help, "on|off", 1, true) ~= nil, c and c.help)

-- (c) off
clearLog()
local r = KCD2MP_SetRespawn("off")
check("c: off accepted", r == true)
check("c: flag off", KCD2MP.respawnEnabled == false)
check("c: one respawn_toggle off event for the agent", evtCount("respawn_toggle", "off") == 1, lastLog("[KCD2-MP-EVT]"))
check("c: toggle line says set=off was=on", logCount("MP-RESPAWN-TOGGLE set=off was=on") == 1, lastLog("MP-RESPAWN-TOGGLE"))

-- (d) on
clearLog()
r = KCD2MP_SetRespawn("on")
check("d: on accepted", r == true)
check("d: flag on", KCD2MP.respawnEnabled == true)
check("d: one respawn_toggle on event", evtCount("respawn_toggle", "on") == 1, lastLog("[KCD2-MP-EVT]"))
check("d: toggle line says set=on was=off", logCount("MP-RESPAWN-TOGGLE set=on was=off") == 1, lastLog("MP-RESPAWN-TOGGLE"))

-- (e) bare: report only
clearLog()
r = KCD2MP_SetRespawn(nil)
local r2 = KCD2MP_SetRespawn("")
check("e: bare reports", r == true and r2 == true and logCount("MP-RESPAWN-TOGGLE mp_respawn=on (usage: mp_respawn on|off)") == 2, lastLog("MP-RESPAWN-TOGGLE"))
check("e: bare changes nothing", KCD2MP.respawnEnabled == true)
check("e: bare emits nothing", logCount("[KCD2-MP-EVT]") == 0)

-- (f) a bad argument
clearLog()
r = KCD2MP_SetRespawn("maybe")
check("f: bad argument refused", r == false and logCount("mp_respawn: expected 'on' or 'off'") == 1, lastLog("mp_respawn"))
check("f: bad argument changes nothing", KCD2MP.respawnEnabled == true)
check("f: bad argument emits nothing", logCount("[KCD2-MP-EVT]") == 0)
check("f: no Lua errors", #ERRS == 0, ERRS[1])

-- Summary.
local pass, fail = 0, 0
for _, res in ipairs(RESULTS) do if res:sub(1, 4) == "PASS" then pass = pass + 1 else fail = fail + 1 end end
OUT = table.concat(RESULTS, "\n") .. string.format("\n%d passed, %d failed", pass, fail)
