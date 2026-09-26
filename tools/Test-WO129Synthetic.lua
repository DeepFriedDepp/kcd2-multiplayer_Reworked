-- WO-129 synthetic test, against the real kdcmp.lua under MoonSharp.
-- Harness (stubs, mkEntity) copied from Test-WO102Synthetic.lua.
--
--   (a) the host's join bar names the stage and counts that stage's seconds;
--       only "sending" shows a percentage (the first session read 100 % for
--       the whole 1-2 min the joiner spent loading)
--   (b) a host running a SHARED world keeps every peer as an NPC scan anchor
--       and never goes "apart" (the first session's host respawned 369 m
--       away and the NPCs around the joiner left the stream)
--   (c) control: separate worlds keep the WO-102.5 apart/release behaviour
--
-- What this proves: the Lua halves. What it does NOT prove: a live
-- two-machine session (docs/WO-129-findings.md).

NOW = 0
os.clock = function() return NOW end
LOG = {}; TIMERS = {}; ENTS = {}; ERRS = {}; TOASTS = {}; SPHERE = {}
CMDS = {}; DRAWS = {}; SPAWNS = {}; CCMDS = {}; LOCKS = {}

local function mkstub()
    return setmetatable({}, { __index = function(_, k) return function(...) return nil end end })
end
System = mkstub()
System.LogAlways = function(s) LOG[#LOG + 1] = tostring(s) end
System.GetCVarValue = function() return "0" end
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
Game.AddSaveLock = function(name, desc) if LOCKS[name] then return false end LOCKS[name] = true; return true end
Game.RemoveSaveLock = function(name) local had = LOCKS[name] == true; LOCKS[name] = nil; return had end
UIAction = mkstub()
UIAction.CallFunction = function(panel, inst, fn, text) TOASTS[#TOASTS + 1] = tostring(text) end
WORLD_T = 1000
Calendar = { GetWorldTime = function() return WORLD_T end, SetWorldTime = function(t) WORLD_T = t end,
             GetWorldTimeRatio = function() return 15 end, SetWorldTimeRatio = function() end }
XGenAIModule = mkstub()

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
NEXTID = 5000
local function mkEntity(name, x, y, z)
    NEXTID = NEXTID + 1
    local e = { class = "NPC", id = NEXTID, px = x or 0, py = y or 0, pz = z or 0, rz = 0, dead = false, hp = 100 }
    e.GetName = function(self) return name end
    e.GetWorldPos = function(self) return { x = self.px, y = self.py, z = self.pz } end
    e.GetWorldAngles = function(self) return { x = 0, y = 0, z = self.rz } end
    e.SetWorldPos = function(self, pos) self.px, self.py, self.pz = pos.x, pos.y, pos.z end
    e.SetWorldAngles = function(self, a) self.rz = a.z end
    e.StartAnimation = function() end
    e.actor = { IsDead = function() return e.dead end, IsUnconscious = function() return false end, GetHealth = function() return e.hp end }
    e.human = { IsWeaponDrawn = function() return false end, IsInDialog = function() return false end }
    return e
end

-- ---------------------------------------------------------------- (a)
do
    ERRS = {}
    local t, l = KCD2MP_JoinBarText("Anna", "saving", 0, 3.7)
    check("a: saving names the stage with seconds", t == "Anna is joining -- saving the world... 3 s", t)
    check("a: saving ladder", l == "[>] save 3 s   [ ] send   [ ] load   [ ] ready", l)
    t, l = KCD2MP_JoinBarText("Anna", "sending", 62.4, 1)
    check("a: sending shows the transfer percentage", t == "Sending the world to Anna... 62%", t)
    check("a: sending ladder", l == "[x] save   [>] send 62%   [ ] load   [ ] ready", l)
    t, l = KCD2MP_JoinBarText("Anna", "loading", 100, 34.2)
    check("a: loading counts seconds, never '100%'", t == "Anna is loading your world... 34 s" and not t:find("%%"), t)
    check("a: loading ladder", l == "[x] save   [x] send   [>] load 34 s   [ ] ready", l)
    t = KCD2MP_JoinBarText(nil, "loading", 100, -5)
    check("a: no partner name / negative seconds are safe", t == "your partner is loading your world... 0 s", t)
    -- the draw path: a new stage restarts its clock, the log key stays stable per stage
    local w = KCD2MP.w123
    w.joinId, w.partner, w.paused, w.pausedAt, w.timeoutS = "00c0ffee", "Anna", true, 100, 180
    w.phase, w.phaseAt, w.pct = "sending", 100, 40
    NOW = 101; KCD2MP_JoinProgress("00c0ffee", 100, "loading")
    check("a: a new stage starts its own clock", w.phaseAt == 101 and w.phase == "loading")
    NOW = 101.5; KCD2MP_JoinProgress("00c0ffee", 100, "loading")
    check("a: the same stage keeps it", w.phaseAt == 101)
    clearLog(); DRAWS = {}
    NOW = 135; KCD2MP_JoinDrawUI(); NOW = 136; KCD2MP_JoinDrawUI()
    local seen = false
    for _, d in ipairs(DRAWS) do if d.text == "Anna is loading your world... 35 s" then seen = true end end
    check("a: drawn with the stage's elapsed seconds", seen)
    check("a: the title logs once per stage, not once a second", logCount("MP-SCREEN row=join_title") == 1, lastLog("MP-SCREEN row=join_title"))
    w.paused = false
    check("a: no Lua errors", #ERRS == 0, ERRS[1])
end

-- ---------------------------------------------------------------- (b)/(c)
local function reset()
    KCD2MP.npcPuppets = {}; KCD2MP.npcTracked = {}; KCD2MP.dragging = {}; KCD2MP.dragWatch = {}
    KCD2MP._npcPaused = {}; KCD2MP._npcResumePending = {}; KCD2MP._npcEverPaused = {}
    KCD2MP.wo102.npcScanNative = false
    KCD2MP.hitSensorOn = true
    KCD2MP.wo102.authorityHost = true
    KCD2MP.npcSync.enabled = true; KCD2MP.npcSyncRunning = true
    KCD2MP.wo1025.together = false; KCD2MP._togetherWantSince = nil; KCD2MP._colocatePendingRelease = {}
    KCD2MP._npcScanAnchors = nil
    ENTS = {}; SPHERE = {}; ERRS = {}
end

do -- (b) shared world hosted here: the far peer stays an anchor, nothing is released
    reset(); clearLog()
    KCD2MP.w122.sharedWorld = true
    local ghostPos = { x = 370, y = 0, z = 0 }
    KCD2MP.ghosts = { ["1"] = { entity = { GetWorldPos = function() return ghostPos end }, istate = {} } }
    local nearPeer = mkEntity("b_near_peer", 372, 0, 0); ENTS["b_near_peer"] = nearPeer
    local nearHost = mkEntity("b_near_host", 3, 0, 0); ENTS["b_near_host"] = nearHost
    SPHERE = { nearPeer, nearHost }
    NOW = 1000; KCD2MP._npcScanAt = 0
    KCD2MP_NpcSyncTick()
    check("b: shared world: together at once, whatever the distance", KCD2MP.wo1025.together == true)
    check("b: said once", logCount("WO129-SHARED") == 1, lastLog("WO129-SHARED"))
    check("b: two scan anchors", logCount("WO102-AUTHORITY scan anchors=2") == 1, lastLog("WO102-AUTHORITY scan"))
    check("b: the NPC by the far peer is owned", KCD2MP.npcTracked["b_near_peer"] ~= nil)
    check("b: and streamed (not culled: within 60 m of an anchor)", logCount("npc_state b_near_peer") >= 1)
    -- a long time apart: never releases, never toasts "apart"
    for i = 1, 5 do NOW = 1000 + i * 10; KCD2MP._npcScanAt = 0; KCD2MP_NpcSyncTick() end
    check("b: still together after 50 s apart", KCD2MP.wo1025.together == true)
    check("b: no apart release", logCount("WO1025-COLOCATE event=exit") == 0 and KCD2MP.npcTracked["b_near_peer"] ~= nil)
    check("b: no 'Players apart' toast", logCount("Players apart") == 0)
    check("b: no Lua errors", #ERRS == 0, ERRS[1])
end

do -- (c) control: separate worlds (shared off) -- the WO-102.5 behaviour stands
    reset(); clearLog()
    KCD2MP.w122.sharedWorld = false
    local ghostPos = { x = 370, y = 0, z = 0 }
    KCD2MP.ghosts = { ["1"] = { entity = { GetWorldPos = function() return ghostPos end }, istate = {} } }
    local nearPeer = mkEntity("c_near_peer", 372, 0, 0); ENTS["c_near_peer"] = nearPeer
    SPHERE = { nearPeer }
    NOW = 2000; KCD2MP._npcScanAt = 0
    KCD2MP_NpcSyncTick()
    check("c: separate worlds: apart stays apart", KCD2MP.wo1025.together == false)
    check("c: one anchor only", KCD2MP._lastAnchors ~= nil and #KCD2MP._lastAnchors == 1)
    check("c: the far peer's NPC is not owned", KCD2MP.npcTracked["c_near_peer"] == nil)
    check("c: no WO129-SHARED line", logCount("WO129-SHARED") == 0)
    KCD2MP.npcSyncRunning = false; KCD2MP.hitSensorOn = false
    check("c: no Lua errors", #ERRS == 0, ERRS[1])
end

local pass, fail = 0, 0
for _, r in ipairs(RESULTS) do if r:sub(1, 4) == "PASS" then pass = pass + 1 else fail = fail + 1 end end
OUT = table.concat(RESULTS, "\n") .. string.format("\n%d passed, %d failed", pass, fail)
