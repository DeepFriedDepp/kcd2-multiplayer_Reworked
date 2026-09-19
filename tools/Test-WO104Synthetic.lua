-- WO-104 synthetic test, against the real kdcmp.lua under MoonSharp.
--
-- Phase 0 -- world-time wire formatting:
--   (a) with tostring() made to behave like this build's engine Lua ("%g",
--       observed 2026-09-18: 1002550 -> '1.00255e+06'), KCD2MP_ReportWorldTime
--       still emits the exact integer for a clock above 1e6, and for a
--       fractional clock; the pre-WO-104 form is shown to break under the
--       same tostring so the mimic is proven to bite.
--
-- Phase 1 -- brainless replicas for contested NPCs (mp_npc_replica_on|off):
--   scenarios (b)..(i), appended below as the phase lands.
--
-- Phase 2 -- pause lever default:
--   (j) KCD2MP.wo102.authorityPause ships OFF; a puppet start under host
--       authority issues no wh_ai_PauseNPC.
--
-- Driven by Test-WO104Synthetic.ps1 through the WO-77 MoonSharp driver.
-- What this proves: the Lua half behaves as documented. What it does NOT
-- prove: anything about a live game -- see docs/WO-104-findings.md.
--
-- Part 1: engine stubs + a fake clock (same shape as Test-WO102Synthetic.lua).

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
System.GetEntity = function(id) for _, e in pairs(ENTS) do if e.id == id then return e end end return nil end
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
-- Spawned bodies: a full entity stub (position, angles, actor, human, soul)
-- so a replica can be driven by the puppet tick exactly like a world NPC.
NEXTID = 9000
function mkEntity(name, x, y, z, class)
    NEXTID = NEXTID + 1
    local e = { class = class or "NPC", id = NEXTID, px = x or 0, py = y or 0, pz = z or 0, rz = 0,
                writes = {}, dead = false, ko = false, hp = 100, hidden = 0, hides = {}, anims = {} }
    e.GetName = function(self) return name end
    e.GetWorldPos = function(self) return { x = self.px, y = self.py, z = self.pz } end
    e.GetWorldAngles = function(self) return { x = 0, y = 0, z = self.rz } end
    e.SetWorldPos = function(self, pos) self.px, self.py, self.pz = pos.x, pos.y, pos.z; self.writes[#self.writes + 1] = pos end
    e.SetWorldAngles = function(self, a) self.rz = a.z end
    e.StartAnimation = function(self, layer, anim) self.anims[#self.anims + 1] = anim end
    e.Hide = function(self, v) if v == nil then v = 1 end; self.hidden = v; self.hides[#self.hides + 1] = v end
    e.actor = { IsDead = function() return e.dead end, IsUnconscious = function() return e.ko end, GetHealth = function() return e.hp end }
    e.human = { IsWeaponDrawn = function() return e.drawnNow == true end,
                DrawWeapon = function() e.drawnNow = true; return true end,
                HolsterWeapon = function() e.drawnNow = false; return true end }
    e.soul = { GetId = function() return e.soulId or ("4e628918-2a38-c1ea-c786-2424" .. string.format("%08d", e.id)) end, name = name }
    return e
end
XGenAIModule.SpawnEntity = function(t)
    SPAWNS[#SPAWNS + 1] = t
    if SPAWN_FAIL then return nil end
    local p = t.Pos or { 0, 0, 0 }
    local e = mkEntity(t.Name, p[1], p[2], p[3], t.ClassName)
    if SPAWN_SOULLESS then e.soul = nil end
    e.spawnTable = t
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

-- WO-104 Phase 0: make tostring() behave like this build's engine Lua for
-- numbers. Standard Lua 5.1 uses "%.14g" (1002550 prints as 1002550);
-- the engine's build prints '1.00255e+06' -- i.e. plain "%g", six
-- significant digits. Installed BEFORE kdcmp.lua loads so every number the
-- mod stringifies goes through it, exactly as in the game.
local rawtostring = tostring
tostring = function(v)
    if type(v) == "number" then return string.format("%g", v) end
    return rawtostring(v)
end

-- @@KDCMP@@

-- Part 2: scenarios.

local RESULTS = {}
local function check(name, ok, detail)
    RESULTS[#RESULTS + 1] = (ok and "PASS  " or "FAIL  ") .. name .. (detail and ("  [" .. rawtostring(detail) .. "]") or "")
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
local function evtArg(evName)
    -- "[KCD2-MP-EVT] v1 <seq> <name> <arg>" -> arg of the LAST such event
    for i = #LOG, 1, -1 do
        local a = string.match(LOG[i], "^%[KCD2%-MP%-EVT%] v1 %d+ " .. evName .. " (.*)$")
        if a then return a end
    end
    return nil
end

-- ---------------------------------------------------------------- Phase 0
do -- (a) time_now formatting past 1e6
    -- The mimic itself bites: this is what the pre-WO-104 sender produced.
    check("a: tostring mimic reproduces the field failure", tostring(1002550) == "1.00255e+06", tostring(1002550))

    clearLog(); WORLD_T = 1002550
    KCD2MP_ReportWorldTime()
    check("a: time_now above 1e6 is the exact integer", evtArg("time_now") == "1002550", evtArg("time_now"))

    clearLog(); WORLD_T = 1002550.7
    KCD2MP_ReportWorldTime()
    check("a: fractional clock floors to a plain integer", evtArg("time_now") == "1002550", evtArg("time_now"))

    clearLog(); WORLD_T = 982149
    KCD2MP_ReportWorldTime()
    check("a: below 1e6 unchanged", evtArg("time_now") == "982149", evtArg("time_now"))

    clearLog(); WORLD_T = 4294967295   -- uint32 max, the agent's parse ceiling
    KCD2MP_ReportWorldTime()
    check("a: uint32 max still a plain integer", evtArg("time_now") == "4294967295", evtArg("time_now"))

    -- Round trip: the value the agent pushes back as a Lua literal parses to
    -- the same clock, and the mod's own forward-only apply accepts it.
    clearLog(); WORLD_T = 1002550
    KCD2MP_ApplyTimeSkip("peer", 1, "1002560", true)
    check("a: apply of a >1e6 target lands exactly", WORLD_T == 1002560, WORLD_T)
    check("a: no Lua errors", #ERRS == 0, ERRS[1])
end

-- Summary.
local pass, fail = 0, 0
for _, r in ipairs(RESULTS) do if r:sub(1, 4) == "PASS" then pass = pass + 1 else fail = fail + 1 end end
OUT = table.concat(RESULTS, "\n") .. string.format("\n%d passed, %d failed", pass, fail)
