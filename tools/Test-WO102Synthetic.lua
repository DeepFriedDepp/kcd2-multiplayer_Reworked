-- WO-102 synthetic test, against the real kdcmp.lua under MoonSharp.
--
-- Phase 0 -- the toggle set:
--   (a) a console flip logs WO102-TOGGLE and emits one wo102_toggle event
--   (b) an agent-sourced push mirrors the flag and emits NOTHING (no echo)
--   (c) an unknown toggle name is refused and changes no flag
--   (d) mp_wo102_status logs every flag and the authority role
--   (e) the WO-102 console commands are registered ARGLESS (the console
--       drops arguments on this build, docs/WO-94) -- no "%LINE" anywhere
--   (f) with every toggle off, the mod's NPC-sync globals read exactly the
--       0.23.2 defaults (npcSync on, npcProx on, diverge on, yield on)
--
-- Later phases append their scenarios below (Phase 2 MP-AUTHORITY, Phase 4
-- host authority, Phase 6 resync).
--
-- Driven by Test-WO102Synthetic.ps1 through the WO-77 MoonSharp driver.
-- What this proves: the Lua half of every toggle behaves as documented and
-- the off state is the shipped state. What it does NOT prove: anything about
-- a live game -- see docs/WO-102-findings.md for what is and is not verified.
--
-- Part 1: engine stubs + a fake clock.

NOW = 0
os.clock = function() return NOW end
LOG = {}; TIMERS = {}; ENTS = {}; ERRS = {}; TOASTS = {}; SPHERE = {}
CMDS = {}; ALLCMDS = {}; DRAWS = {}; SPAWNS = {}; CCMDS = {}

local function mkstub()
    return setmetatable({}, { __index = function(_, k) return function(...) return nil end end })
end
System = mkstub()
System.LogAlways = function(s) LOG[#LOG + 1] = tostring(s) end
System.GetCVarValue = function() return "0" end
System.GetEntityByName = function(n) return ENTS[n] end
System.GetEntitiesInSphere = function() return SPHERE end
System.ExecuteCommand = function(s) CMDS[#CMDS + 1] = tostring(s); ALLCMDS[#ALLCMDS + 1] = tostring(s) end
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

-- ---------------------------------------------------------------- Phase 0

-- (f) first: the off state IS the 0.23.2 state.
check("f: wo102 toggles default off", KCD2MP.wo102.authorityHost == false and KCD2MP.wo102.posNative == false)
check("f: 0.23.2 NPC-sync defaults intact", KCD2MP.npcSync.enabled == true and KCD2MP.npcProx.enabled == true
      and KCD2MP.npcDiverge == true and KCD2MP.npcYield.enabled == true)

-- (a) console flip.
clearLog()
local ok = KCD2MP_Wo102Set("authority_host", true)
check("a: console flip returns true", ok == true)
check("a: WO102-TOGGLE line logged", logCount("WO102-TOGGLE name=authority_host state=on was=off source=console") == 1)
local evt = lastLog("[KCD2-MP-EVT]")
check("a: one wo102_toggle event emitted", logCount("[KCD2-MP-EVT] v1") == 1 and evt ~= nil
      and string.find(evt, "wo102_toggle authority_host on", 1, true) ~= nil, evt)
check("a: flag set", KCD2MP.wo102.authorityHost == true)

-- (b) agent push: mirrors, no echo.
clearLog()
KCD2MP_Wo102Set("pos_native", true, "agent")
check("b: agent push sets the flag", KCD2MP.wo102.posNative == true)
check("b: agent push emits no event", logCount("[KCD2-MP-EVT]") == 0)
check("b: agent push still logs the line", logCount("WO102-TOGGLE name=pos_native state=on was=off source=agent") == 1)
KCD2MP_Wo102Set("pos_native", false, "agent")
KCD2MP_Wo102Set("authority_host", false, "agent")
check("b: agent push off restores both", KCD2MP.wo102.authorityHost == false and KCD2MP.wo102.posNative == false)

-- (c) unknown name.
clearLog()
local bad = KCD2MP_Wo102Set("frobnicate", true)
check("c: unknown toggle refused", bad == false and logCount("WO102-TOGGLE unknown toggle") == 1)
check("c: unknown toggle changes nothing", KCD2MP.wo102.authorityHost == false and KCD2MP.wo102.posNative == false)

-- (d) status.
clearLog()
KCD2MP_Wo102Status()
check("d: status line", logCount("WO102-STATUS authority_host=off pos_native=off authority=peer") == 1)

-- (e) argless commands (registration runs at file load, captured in CCMDS).
local names = { "mp_authority_host_on", "mp_authority_host_off", "mp_pos_native_on", "mp_pos_native_off", "mp_wo102_status" }
local allReg, allArgless, missing = true, true, ""
for _, n in ipairs(names) do
    local c = CCMDS[n]
    if not c then allReg = false; missing = missing .. n .. " "
    elseif string.find(c.body, "%LINE", 1, true) then allArgless = false end
end
check("e: WO-102 commands registered", allReg, missing ~= "" and ("missing: " .. missing) or nil)
check("e: WO-102 commands are argless (no %LINE)", allArgless)

-- Summary.
local pass, fail = 0, 0
for _, r in ipairs(RESULTS) do if r:sub(1, 4) == "PASS" then pass = pass + 1 else fail = fail + 1 end end
OUT = table.concat(RESULTS, "\n") .. string.format("\n%d passed, %d failed", pass, fail)
