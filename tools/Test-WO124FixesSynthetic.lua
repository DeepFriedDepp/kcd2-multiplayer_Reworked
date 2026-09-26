-- WO-124 Phase 6 synthetic test, against the real kdcmp.lua under MoonSharp:
-- the two fixes from the 0.28.3 peer test (not behind mp_shared_world).
--
--   (i) 6a: Riding STOP dismounts a mounted avatar even when the latched flag
--       missed the mount, reads it back, and only then may the native writer
--       have it; a dismount that does not take keeps the writer off and is
--       retried; a mount that lands after the stop is taken off at once
--
-- What this proves: the Lua half behaves as documented. What it does NOT
-- prove: the engine's mount/dialogue behaviour (live runs: docs/WO-124-findings.md).

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

-- ---------------------------------------------------------------- shared entity + reset
local NEXTID = 0x0F0000
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
    e.EnableAI = function() end
    e.GetParent = function() return e.parent end
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
    KCD2MP.ghosts = {}; KCD2MP.horseGhosts = {}
    ENTS = {}; SPHERE = {}; TIMERS = {}; ERRS = {}; CMDS = {}; STATE = {}
    LOG = {}
end

local SEQ = 0
local function tick(name, sx, sy, sz, flags)
    NOW = NOW + 0.05
    SEQ = SEQ + 1
    KCD2MP_ApplyNpcState(name, sx, sy, sz or 0, 0, 100, flags or 0, 1, SEQ % 65536, math.floor(NOW * 1000))
    KCD2MP.npcPuppetRunning = true
    KCD2MP_NpcPuppetTick("ext")
end
local function alive() KCD2MP_NpcNativeAlive(1, 1, 0, 0) end

-- ---------------------------------------------------------------- (i) 6a
local function mkGhost(id, mountedAtStart)
    local e = mkEntity("kcd2mp_" .. id, 90, 90, 0)
    e.mounted = mountedAtStart == true
    e.dismountTakes = true
    e.dismounts = 0
    e.human.IsMounted = function() return e.mounted end
    e.human.ForceMount = function() e.mounted = true end
    e.human.ForceDismount = function() e.dismounts = e.dismounts + 1; if e.dismountTakes then e.mounted = false end end
    local ist = { px = 90, py = 90, pz = 0, pr = 0, tx = 90, ty = 90, tz = 0, tr = 0, cx = 90, cy = 90, cz = 0, cr = 0,
                  alpha = 1.0, alphaStep = 0.25, vx = 0, vy = 0, vz = 0, lastPacketX = 90, lastPacketY = 90,
                  ticksSincePacket = 0, packetCount = 0, animTag = "idle", smoothedSpeed = 0,
                  prevCx = 90, prevCy = 90, speedDropTicks = 0, spawnedAtClock = NOW - 10 }
    KCD2MP.ghosts[id] = { entity = e, entityId = e.id, istate = ist }
    return e, ist
end
local function gtick(id, x, riding)
    NOW = NOW + 0.03
    alive()
    KCD2MP_UpdateGhost(id, x, 90, 0, 0, riding == true)
    KCD2MP_InterpTick("ext")
end
local function binds(id)
    local n = 0
    for _, a in ipairs(evts("npc_native")) do if a:find("^kcd2mp_" .. id .. " on ") then n = n + 1 end end
    return n
end
do
    reset(); NOW = 1300
    KCD2MP.labelCache = {}; KCD2MP.ghostDead = {}; KCD2MP.ghostHealth = {}; KCD2MP.ghostInMenu = {}
    KCD2MP._chainLeakSeen = {}; KCD2MP._chainProbe = {}
    KCD2MP.interpRunning = true; KCD2MP._interpAliveAt = NOW; KCD2MP.interpGen = KCD2MP.interpGen or 1
    KCD2MP_SpawnHorse = function() end   -- the horse spawn is engine work; not under test here

    -- i1: the peer rides; the body is mounted but the 300 ms check missed it (flag false)
    local e, ist = mkGhost("8", true)
    ist.isRiding = true; ist.nativeMounted = false
    gtick("8", 90.1, false)   -- Riding STOP
    check("i1: Riding STOP force-dismounts a body that reads mounted (flag missed)", e.dismounts == 1 and e.mounted == false, e.dismounts)
    check("i1: MP-DISMOUNT logged with the read-back",
          (lastLog("MP-DISMOUNT id=8 why=riding-stop") or ""):find("flag=false live=true force=ok after=false", 1, true) ~= nil,
          lastLog("MP-DISMOUNT id=8"))
    for i = 1, 4 do gtick("8", 90.1 + i * 0.04, false) end
    check("i1: off the horse -> the native writer may have it", binds("8") >= 1, binds("8"))

    -- i2: a dismount that does not take keeps the writer off and is retried
    reset(); NOW = 1400
    KCD2MP.interpRunning = true; KCD2MP._interpAliveAt = NOW
    KCD2MP_SpawnHorse = function() end
    local e2, ist2 = mkGhost("9", true)
    e2.dismountTakes = false
    ist2.isRiding = true; ist2.nativeMounted = true
    gtick("9", 90.1, false)
    check("i2: still mounted after the dismount -> pending", ist2.dismountPending == true, tostring(ist2.dismountPending))
    for i = 1, 30 do gtick("9", 90.1 + i * 0.03, false) end   -- 0.9 s
    check("i2: no bind while the avatar is on the horse", binds("9") == 0, binds("9"))
    check("i2: the dismount is retried", e2.dismounts >= 2, e2.dismounts)
    e2.dismountTakes = true
    for i = 1, 30 do gtick("9", 91 + i * 0.03, false) end
    check("i2: once it takes, pending clears and the writer binds", ist2.dismountPending == nil and binds("9") >= 1, binds("9"))

    -- i3: never bind a mounted avatar, whatever the stream says
    reset(); NOW = 1500
    KCD2MP.interpRunning = true; KCD2MP._interpAliveAt = NOW
    local e3, ist3 = mkGhost("10", true)
    e3.dismountTakes = false
    for i = 1, 6 do gtick("10", 90 + i * 0.04, false) end
    check("i3: a mounted avatar (not riding on the stream) is not bound", binds("10") == 0, binds("10"))
    check("i3: the refusal is logged once", logCount("MP-NPCBIND refused kcd2mp_10") == 1, logCount("MP-NPCBIND refused kcd2mp_10"))
    e3.mounted = false; e3.parent = { id = "horse" }
    ist3.dismountPending = nil
    for i = 1, 6 do gtick("10", 91 + i * 0.04, false) end
    check("i3: a parented avatar is not bound either", binds("10") == 0, binds("10"))

    -- i4: the mount lands after Riding STOP (inside the 300 ms check)
    reset(); NOW = 1600
    KCD2MP.interpRunning = true; KCD2MP._interpAliveAt = NOW
    local e4, ist4 = mkGhost("11", false)
    local horse = mkEntity("horse_11", 91, 90, 0)
    horse.id = "horse-11"
    KCD2MP.horseGhosts["11"] = { entity = horse, isWorldHorse = false }
    ist4.isRiding = true
    KCD2MP_MountNPCOnHorse("11")
    check("i4: ForceMount issued, the check armed", e4.mounted == true and #TIMERS >= 1, #TIMERS)
    ist4.isRiding = false   -- Riding STOP came first
    local t = TIMERS[#TIMERS]; TIMERS = {}
    t.f()
    check("i4: the late mount is taken off, not latched", e4.mounted == false and ist4.nativeMounted ~= true, tostring(ist4.nativeMounted))
    check("i4: logged", lastLog("MP-DISMOUNT id=11 the mount landed after Riding STOP") ~= nil)

    check("i: no Lua errors", #ERRS == 0, ERRS[1])
end

-- Summary, in the shared driver's contract (Test-NpcSmoothSynthetic.ps1 reads
-- OUT: one PASS/FAIL line per check, then the totals).
local pass, fail = 0, 0
for _, r in ipairs(RESULTS) do if r:sub(1, 4) == "PASS" then pass = pass + 1 else fail = fail + 1 end end
OUT = table.concat(RESULTS, "\n") .. string.format("\n%d passed, %d failed", pass, fail)
