-- WO-121 synthetic test, against the real kdcmp.lua under MoonSharp.
--
-- The movement/combat policy is native (KCDMP.dll motion.cpp / hits.cpp) and
-- the agent's; Lua owns the seven toggles, the WO121-BUILD marker, one park of
-- its own clip loop on native-animated bodies, and the engagement flag edge.
-- This suite pins that half:
--   (a) shipped defaults: all seven on; WO121-BUILD once, friendly fire on
--       with its reason (bleeding not carried), protocol v8
--   (b) the seven commands are registered with %line and document on|off
--   (c) a toggle off: flag flips, one wo121_cfg event, WO121-TOGGLE line
--   (d) a bare call reports and changes nothing; (e) nonsense is refused
--   (f) the gait gate: Lua defers to the engine only while the agent's
--       heartbeat is fresh AND the DLL says gait is armed
--   (g) the park stops the clip once
--   (h) the host's friendly-fire session value
--   (i) engagement: an engaged avatar leaves ignorance and the 2.5 s
--       re-assert leaves it alone; release restores the session setting
--   (j) mp_preset_legacy turns all seven off, mp_preset_clean back on
--
-- Driven by Test-WO121Synthetic.ps1 through the WO-77 MoonSharp driver.
-- What this proves: the Lua half behaves as documented. Nothing native.
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

-- (a) defaults + marker
local w = KCD2MP.w121
local keys = { "avatarGait", "npcGait", "avatarMoves", "avatarCombat", "npcRows", "attribution", "friendlyFire" }
local allOn = true
for _, k in ipairs(keys) do if w[k] ~= true then allOn = false end end
check("a: all seven toggles ship ON", allOn)
check("a: WO121-BUILD logged once at load", logCount("WO121-BUILD ") == 1, lastLog("WO121-BUILD"))
local m = lastLog("WO121-BUILD") or ""
check("a: marker says friendly_fire=on and protocol=v8", string.find(m, "friendly_fire=on protocol=v8", 1, true) ~= nil, m)
check("a: marker names the bleeding gap", string.find(m, "bleeding is not carried", 1, true) ~= nil, m)
check("a: marker names mp_preset_legacy", string.find(m, "mp_preset_legacy", 1, true) ~= nil, m)

-- (b) console registration
local cmds = { { "mp_avatar_gait", "avatarGait" }, { "mp_npc_gait", "npcGait" }, { "mp_avatar_moves", "avatarMoves" },
               { "mp_avatar_combat", "avatarCombat" }, { "mp_npc_rows", "npcRows" }, { "mp_npc_attribution", "attribution" },
               { "mp_friendly_fire", "friendlyFire" } }
for _, nk in ipairs(cmds) do
    local c = CCMDS[nk[1]]
    check("b: " .. nk[1] .. " registered with %line", c ~= nil and string.find(c.body, 'KCD2MP_Wo121Set("' .. nk[2] .. '", %line)', 1, true) ~= nil, c and c.body)
    check("b: " .. nk[1] .. " documents on|off, no %LINE", c ~= nil and string.find(c.help, "on|off", 1, true) ~= nil and not string.find(c.body, "%LINE", 1, true), c and c.help)
end

-- (c) a toggle off
clearLog()
check("c: off accepted", KCD2MP_Wo121Set("avatarGait", "off") == true)
check("c: flag off", w.avatarGait == false)
check("c: one wo121_cfg event with avatar_gait=off", evtCount("wo121_cfg", "avatar_gait=off") == 1, lastLog("[KCD2-MP-EVT]"))
check("c: WO121-TOGGLE line", logCount("WO121-TOGGLE avatarGait=off") == 1, lastLog("WO121-TOGGLE"))
KCD2MP_Wo121Set("avatarGait", "on")

-- (d) bare
clearLog()
check("d: bare accepted", KCD2MP_Wo121Set("npcRows", "") == true)
check("d: bare changes nothing", w.npcRows == true)
-- (e) nonsense
clearLog()
check("e: nonsense refused", KCD2MP_Wo121Set("npcRows", "maybe") == false)
check("e: nonsense changes nothing and emits nothing", w.npcRows == true and logCount("[KCD2-MP-EVT]") == 0)
check("e: unknown key refused", KCD2MP_Wo121Set("noSuchKey", "on") == false)

-- (f) the gait gate
w.aliveAt = nil
check("f: no heartbeat -> Lua keeps its loop", KCD2MP_Wo121GaitNative(true) == false)
KCD2MP_Wo121Alive(true, true, true)
check("f: fresh heartbeat + gait armed -> engine owns the avatar", KCD2MP_Wo121GaitNative(true) == true)
check("f: ... and NPC copies", KCD2MP_Wo121GaitNative(false) == true)
KCD2MP_Wo121Set("npcGait", "off")
check("f: mp_npc_gait off -> NPC copies back to Lua", KCD2MP_Wo121GaitNative(false) == false)
KCD2MP_Wo121Set("npcGait", "on")
NOW = NOW + 3.5
check("f: stale heartbeat (> 3 s) -> Lua takes the loop back", KCD2MP_Wo121GaitNative(true) == false)
KCD2MP_Wo121Alive(false, true, true)
check("f: gait not armed in the DLL -> Lua keeps its loop", KCD2MP_Wo121GaitNative(true) == false)

-- (g) the park
local stops = 0
local ent = { StopAnimation = function(self, a, b) stops = stops + 1 end }
local st = { animLoopName = "walk" }
local before = w.parked
KCD2MP_Wo121Park(ent, st, "kcd2mp_7")
check("g: park stops the clip once", stops == 1 and st.w121Parked == true and st.animLoopName == nil)
check("g: park is counted and logged", w.parked == before + 1 and logCount("WO121-GAIT body=kcd2mp_7 lua_clip=parked") == 1)

-- (h) the host's friendly-fire session value
KCD2MP_FriendlyFireSession(false, "host")
check("h: session off from the host", w.ffSession == false and w.ffFrom == "host" and logCount("MP-FF session friendly_fire=off from=host") == 1)
KCD2MP_FriendlyFireSession(true, "host")

-- (i) engagement vs the ignorance re-assert
local ig = {}
AI.SetIgnorant = function(id, v) ig[#ig + 1] = { id = id, v = v } end
KCD2MP.ghosts = KCD2MP.ghosts or {}
KCD2MP.ghosts[3] = { entity = { id = 7003 } }
KCD2MP.ghostsIgnorant = true
KCD2MP_Wo121Engage(3, true)
check("i: engage lifts ignorance", #ig == 1 and ig[1].id == 7003 and ig[1].v == 0, #ig)
check("i: engage is logged", logCount("WO121-ENGAGE ghost=3 engaged -> SetIgnorant(0) ok=true") == 1, lastLog("WO121-ENGAGE"))
ig = {}
KCD2MP_ReassertGhostIgnorance()
local touched = false
for _, c in ipairs(ig) do if c.id == 7003 then touched = true end end
check("i: the re-assert leaves an engaged avatar alone", not touched)
ig = {}
KCD2MP_Wo121Engage(3, false)
check("i: release restores ignorance (session setting on)", #ig == 1 and ig[1].v == 1)
ig = {}
KCD2MP_ReassertGhostIgnorance()
touched = false
for _, c in ipairs(ig) do if c.id == 7003 and c.v == 1 then touched = true end end
check("i: after release the re-assert covers it again", touched)
KCD2MP.ghostsIgnorant = false
ig = {}
KCD2MP_Wo121Engage(3, true); KCD2MP_Wo121Engage(3, false)
check("i: with mp_ghost_ignorant off, release leaves it perceivable", #ig == 2 and ig[2].v == 0)
KCD2MP.ghostsIgnorant = true
KCD2MP_Wo121Engage(99, true)
check("i: an unknown ghost is logged, not an error", logCount("WO121-ENGAGE ghost=99 on=true -- no ghost body") == 1)
KCD2MP.ghosts[3] = nil

-- (j) presets
KCD2MP_ApplyPreset("legacy")
local allOff = true
for _, k in ipairs(keys) do if w[k] ~= false then allOff = false end end
check("j: mp_preset_legacy turns all seven off", allOff)
KCD2MP_ApplyPreset("clean")
allOn = true
for _, k in ipairs(keys) do if w[k] ~= true then allOn = false end end
check("j: mp_preset_clean turns all seven back on", allOn)
check("j: no Lua errors", #ERRS == 0, ERRS[1])

-- Summary.
local pass, fail = 0, 0
for _, res in ipairs(RESULTS) do if res:sub(1, 4) == "PASS" then pass = pass + 1 else fail = fail + 1 end end
OUT = table.concat(RESULTS, "\n") .. string.format("\n%d passed, %d failed", pass, fail)
