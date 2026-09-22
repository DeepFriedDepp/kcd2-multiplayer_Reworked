-- WO-110 synthetic test, against the real kdcmp.lua under MoonSharp.
--
--   (a) shipped 0.26.5 defaults: native NPC position read OFF (R1), track cap
--       200 (R3), streaming radius 60 m (2.4); the WO110-BUILD marker is
--       logged at load with every new default
--   (b) R3 chunked push: KCD2MP_ApplyNativeScan(csv, gen, idx, total) commits
--       only when every chunk of a generation has arrived, in any order; a
--       one-argument call commits at once; a half-delivered generation
--       expires after 10 s and never commits
--   (c) R3 cap setter: bare reports, floor 10, ceiling 400 (loud), the value
--       travels on the npc_track_max event
--   (d) 2.4 cull radius setter: bare reports, floor 10, HARD ceiling 150
--       (loud clamp), and the cull test in KCD2MP_NpcSyncTick uses the new
--       value (an NPC at 45 m streams at 60 m, is culled at 30 m)
--   (e) R14: the smooth renderer interpolates Z on the same segment as XY
--       (mid-segment Z is the midpoint, not the newer sample)
--   (f) R14: MP-NPCZ fires when the read-back Z differs from the written Z
--       by more than 5 cm, throttled to one line per 2 s per puppet, and
--       carries the delta sign; a body exactly where it was written logs
--       nothing; the 5 s rollup line carries the counts
--   (g) R14: the contention detector sees a pure-Z displacement (a body
--       yanked 1 m down reads as kind=contention/relax, not silence)
--   (h) presets: clean = 0.26.5 (read native off, cap 200, radius 60);
--       legacy = 0.26.4 (read native on, cap 40, radius 30); both log every
--       value; the pause lever stays ON in both
--   (i) the new console commands are registered with the unquoted %line
--
-- What this proves: the Lua half behaves as documented. What it does NOT
-- prove: anything about the engine or a second machine.
--
-- Part 1: engine stubs + a fake clock (the WO-108 driver's shape).

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
local function evtCount(name, argPrefix)
    local n = 0
    for _, l in ipairs(LOG) do
        if l:find("[KCD2-MP-EVT] v1 ", 1, true) and l:find(" " .. name .. " " .. (argPrefix or ""), 1, true) then n = n + 1 end
    end
    return n
end

-- (a) defaults -- read BEFORE any scenario touches them.
check("a: native NPC position read ships OFF (R1)", KCD2MP.wo1025.readNative == false, tostring(KCD2MP.wo1025.readNative))
check("a: track cap ships 200 (R3)", KCD2MP.wo1025.npcTrackMax == 200, tostring(KCD2MP.wo1025.npcTrackMax))
check("a: streaming radius ships 60 m (2.4)", KCD2MP.wo1025.cullRadius == 60.0, tostring(KCD2MP.wo1025.cullRadius))
check("a: pause lever still ON, replicas/yield still OFF, dwell 10 (WO-108 defaults kept)",
      KCD2MP.wo102.authorityPause == true and KCD2MP.npcReplica.enabled == false and KCD2MP.npcYield.enabled == false and KCD2MP.wo1025.resumeDwellS == 10.0)
check("a: WO110-BUILD marker logged with every new default",
      logCount("WO110-BUILD") == 1 and (lastLog("WO110-BUILD") or ""):find("npc_read_native=off", 1, true) ~= nil
      and (lastLog("WO110-BUILD") or ""):find("npc_track_max=200", 1, true) ~= nil
      and (lastLog("WO110-BUILD") or ""):find("cull_radius_m=60", 1, true) ~= nil, lastLog("WO110-BUILD"))
check("a: no Lua errors at load", #ERRS == 0, ERRS[1])

local NEXTID = 0x0D0000
local function mkEntity(name, x, y, z)
    NEXTID = NEXTID + 1
    local e = { class = "NPC", id = "userdata: " .. string.format("%016X", NEXTID), px = x or 0, py = y or 0, pz = z or 0, rz = 0, writes = {}, dead = false, hp = 100 }
    e.GetName = function(self) return name end
    e.GetWorldPos = function(self, t) t = t or {}; t.x, t.y, t.z = self.px, self.py, self.pz; return t end
    e.GetWorldAngles = function(self, t) t = t or {}; t.x, t.y, t.z = 0, 0, self.rz; return t end
    e.SetWorldPos = function(self, pos) self.px, self.py, self.pz = pos.x, pos.y, pos.z; self.writes[#self.writes + 1] = { x = pos.x, y = pos.y, z = pos.z, at = NOW } end
    e.SetWorldAngles = function(self, a) self.rz = a.z end
    e.StartAnimation = function() end
    e.SetFlags = function() end
    e.actor = { IsDead = function() return e.dead end, IsUnconscious = function() return false end, GetHealth = function() return e.hp end }
    e.human = { IsWeaponDrawn = function() return false end, DrawWeapon = function() return true end, HolsterWeapon = function() return true end }
    e.soul = { GetId = function() return "userdata: 05000000000001DC" end }
    ENTS[name] = e
    return e
end

local function reset()
    KCD2MP.wo102.authorityHost = true; KCD2MP.wo102.authorityPause = true
    KCD2MP.wo102.npcScanNative = false; KCD2MP.wo102.posNative = false
    KCD2MP.hitSensorOn = false
    KCD2MP.npcPuppets = {}; KCD2MP.npcTracked = {}; KCD2MP.dragging = {}; KCD2MP.dragWatch = {}
    KCD2MP.npcPuppetRunning = false; KCD2MP._npcDivergeUntil = {}
    KCD2MP._npcPaused = {}; KCD2MP._npcPauseExec = {}; KCD2MP._npcEverPaused = {}; KCD2MP._npcResumePending = {}
    KCD2MP._authViolationAt = {}; KCD2MP._authViolationN = {}
    KCD2MP._authStats = { acquire = 0, release = 0, ownerChange = 0, pause = 0, resume = 0, violation = 0 }
    KCD2MP._pauseStats = { relax = 0, gap = 0, reassert = 0, refusedNoPuppet = 0, refusedAuthority = 0, dwellResumes = 0, cancelled = 0 }
    KCD2MP._npcZStats = { n = 0, sumAbs = 0, maxAbs = 0, sinkN = 0, floatN = 0 }
    KCD2MP._nativeScan = { at = nil, names = {}, pos = {} }; KCD2MP._nativeScanChunks = {}
    KCD2MP._chainDeadRestartAt = nil; KCD2MP._pauseReassertedAt = 0; KCD2MP._npcReconcileAt = nil
    KCD2MP._npcDeathRemote = {}; KCD2MP._npcDeathDiverged = {}; KCD2MP._npcDeathSeen = {}
    KCD2MP.npcDiverge = true; KCD2MP.npcYield.enabled = false
    KCD2MP.npcReplica.enabled = false; KCD2MP._npcReplicas = {}
    KCD2MP.wo1025.resumeDwellS = 10.0; KCD2MP.wo1025.readNative = false
    KCD2MP.wo1025.npcTrackMax = 200; KCD2MP.wo1025.cullRadius = 60.0; KCD2MP.wo1025.npcCull = true
    KCD2MP.npcSmooth = true; KCD2MP.npcPuppetTickMs = 50
    KCD2MP.npcSync.enabled = true; KCD2MP.npcSyncRunning = true
    KCD2MP.ghosts = {}; KCD2MP._npcScanAnchors = nil; KCD2MP._lastAnchors = nil
    ENTS = {}; SPHERE = {}; TIMERS = {}; ERRS = {}; CMDS = {}; SPAWNS = {}
    clearLog()
end

-- one packet for `name`, then one puppet tick
local function tick(name, sx, sy, sz, flags)
    NOW = NOW + 0.05
    KCD2MP_ApplyNpcState(name, sx, sy, sz or 0, 0, 100, flags or 0, 1)
    KCD2MP.npcPuppetRunning = true
    KCD2MP_NpcPuppetTick("ext")
end

-- ---------------------------------------------------------------- (b)
do
    reset(); NOW = 100
    -- out-of-order chunks of one generation: nothing commits until the last
    KCD2MP_ApplyNativeScan("b_c:7:8:9:0:1", 5, 3, 3)
    check("b: a partial generation does not commit", KCD2MP._nativeScan.at == nil and #KCD2MP._nativeScan.names == 0)
    KCD2MP_ApplyNativeScan("b_a:1:2:3:0.5:0", 5, 1, 3)
    check("b: still partial after 2 of 3", KCD2MP._nativeScan.at == nil)
    KCD2MP_ApplyNativeScan("b_b:4:5:6:1.0:0", 5, 2, 3)
    check("b: commits when the last chunk lands", KCD2MP._nativeScan.at == NOW and #KCD2MP._nativeScan.names == 3, tostring(#KCD2MP._nativeScan.names))
    check("b: chunk order is restored (idx 1..3)", KCD2MP._nativeScan.names[1] == "b_a" and KCD2MP._nativeScan.names[2] == "b_b" and KCD2MP._nativeScan.names[3] == "b_c")
    check("b: positions parsed per name", KCD2MP._nativeScan.pos.b_b and KCD2MP._nativeScan.pos.b_b.x == 4 and KCD2MP._nativeScan.pos.b_c.isHorse == true)
    check("b: the generation's accumulator is released", next(KCD2MP._nativeScanChunks) == nil)
    -- the pre-WO-110 one-argument shape commits at once and replaces
    NOW = NOW + 1
    KCD2MP_ApplyNativeScan("b_z:0:0:0:0:0")
    check("b: a one-argument call commits at once and replaces the set", KCD2MP._nativeScan.at == NOW and #KCD2MP._nativeScan.names == 1 and KCD2MP._nativeScan.names[1] == "b_z")
    -- a half-delivered generation expires
    KCD2MP_ApplyNativeScan("b_q:0:0:0:0:0", 9, 1, 2)
    NOW = NOW + 11
    KCD2MP_ApplyNativeScan("b_r:0:0:0:0:0", 10, 1, 2)   -- a NEW generation's first chunk sweeps the stale one
    check("b: a generation older than 10 s is dropped, never committed", KCD2MP._nativeScanChunks[9] == nil and KCD2MP._nativeScanStats.dropped >= 1 and KCD2MP._nativeScan.names[1] == "b_z")
    -- a duplicate chunk (a re-sent statement) does not double-count
    KCD2MP_ApplyNativeScan("b_r:0:0:0:0:0", 10, 1, 2)
    check("b: a duplicate chunk does not complete a generation", KCD2MP._nativeScan.names[1] == "b_z")
    -- a single-chunk generation (total=1) commits at once
    KCD2MP_ApplyNativeScan("b_s:1:1:1:0:0", 11, 1, 1)
    check("b: total=1 commits at once", KCD2MP._nativeScan.names[1] == "b_s")
    check("b: no Lua errors", #ERRS == 0, ERRS[1])
end

-- ---------------------------------------------------------------- (c)
do
    reset(); NOW = 200
    check("c: bare reports the current cap", KCD2MP_SetNpcTrackMax(nil) == true and logCount("MP-NPCTRACK cap=200") == 1)
    clearLog()
    check("c: sets and announces", KCD2MP_SetNpcTrackMax("120") == true and KCD2MP.wo1025.npcTrackMax == 120 and evtCount("npc_track_max", "120") == 1 and logCount("MP-NPCTRACK cap set=120 was=200") == 1)
    clearLog()
    check("c: floor 10", KCD2MP_SetNpcTrackMax("3") == true and KCD2MP.wo1025.npcTrackMax == 10 and logCount("raised to the floor of 10") == 1)
    clearLog()
    check("c: ceiling 400, loud", KCD2MP_SetNpcTrackMax("9999") == true and KCD2MP.wo1025.npcTrackMax == 400 and logCount("CLAMPED to the ceiling of 400") == 1)
    check("c: garbage rejected", KCD2MP_SetNpcTrackMax("many") == false and KCD2MP.wo1025.npcTrackMax == 400)
    check("c: no Lua errors", #ERRS == 0, ERRS[1])
end

-- ---------------------------------------------------------------- (d)
do
    reset(); NOW = 300
    check("d: bare reports", KCD2MP_SetCullRadius(nil) == true and logCount("WO1025-CULL-RADIUS current=60.0") == 1)
    clearLog()
    check("d: sets", KCD2MP_SetCullRadius("90") == true and KCD2MP.wo1025.cullRadius == 90 and logCount("WO1025-CULL-RADIUS set=90.0 was=60.0") == 1)
    clearLog()
    check("d: floor 10", KCD2MP_SetCullRadius("2") == true and KCD2MP.wo1025.cullRadius == 10 and logCount("raised to the floor of 10") == 1)
    clearLog()
    check("d: HARD ceiling 150, loud", KCD2MP_SetCullRadius("500") == true and KCD2MP.wo1025.cullRadius == 150 and logCount("EXCEEDS THE HARD CEILING") == 1)
    check("d: garbage rejected", KCD2MP_SetCullRadius("far") == false and KCD2MP.wo1025.cullRadius == 150)
    -- the cull test in the owner's sync tick reads the live value
    KCD2MP.hitSensorOn = true
    KCD2MP.wo1025.readNative = false
    local far = mkEntity("d_far", 45, 0, 0); SPHERE = { far }
    KCD2MP.npcTracked["d_far"] = { since = NOW }
    KCD2MP._lastAnchors = { { x = 0, y = 0, z = 0 } }
    KCD2MP_SetCullRadius("60"); clearLog()
    NOW = NOW + 0.1; KCD2MP_NpcSyncTick()
    check("d: an NPC at 45 m streams at radius 60", evtCount("npc_state", "d_far") == 1, tostring(evtCount("npc_state", "d_far")))
    KCD2MP_SetCullRadius("30"); clearLog()
    KCD2MP.npcTracked["d_far"].lastX = nil   -- force a re-emit decision
    NOW = NOW + 0.1; KCD2MP_NpcSyncTick()
    check("d: the same NPC is culled at radius 30", evtCount("npc_state", "d_far") == 0 and KCD2MP.npcTracked["d_far"].culled == true)
    check("d: no Lua errors", #ERRS == 0, ERRS[1])
end

-- ---------------------------------------------------------------- (e)
do
    reset(); NOW = 400
    KCD2MP.npcSync.emitMs = 100
    local e = mkEntity("e_a", 0, 0, 10); e.SetFlags = function() end
    -- two samples 100 ms apart, 1 m apart in X and 1 m apart in Z
    tick("e_a", 0, 0, 10)
    NOW = NOW + 0.05
    KCD2MP_ApplyNpcState("e_a", 1, 0, 11, 0, 100, 0, 1)
    local p = KCD2MP.npcPuppets["e_a"]
    -- render exactly halfway into the segment: the two samples are stamped
    -- 0.05 s apart (stamp1, stamp2); DELAY = 1.2 * emitMs = 0.12 s, so at
    -- NOW = stamp2 + 0.095 the render point (NOW - DELAY) is stamp2 - 0.025
    -- = stamp1 + 0.025, halfway between them.
    NOW = NOW + 0.095
    KCD2MP_NpcPuppetTick("ext")
    local w = e.writes[#e.writes]
    check("e: mid-segment X is interpolated (about 0.5)", w and math.abs(w.x - 0.5) < 0.15, w and string.format("x=%.3f", w.x))
    check("e: mid-segment Z is interpolated on the SAME segment (about 10.5), not the newer sample (11)", w and math.abs(w.z - 10.5) < 0.15, w and string.format("z=%.3f", w.z))
    check("e: no Lua errors", #ERRS == 0, ERRS[1])
end

-- ---------------------------------------------------------------- (f)
do
    reset(); NOW = 500
    local e = mkEntity("f_a", 0, 0, 20)
    tick("f_a", 0, 0, 20)
    -- body exactly where it was written: no line
    for i = 1, 5 do tick("f_a", 0, 0, 20) end
    check("f: a body where it was written logs no MP-NPCZ", logCount("MP-NPCZ npc=f_a") == 0)
    -- the engine sinks the body 12 cm below every write
    local realSet = e.SetWorldPos
    e.SetWorldPos = function(self, pos) realSet(self, pos); self.pz = pos.z - 0.12 end
    clearLog()
    for i = 1, 3 do tick("f_a", 0, 0, 20) end
    check("f: MP-NPCZ fires on a >5 cm read-back difference", logCount("MP-NPCZ npc=f_a") == 1, lastLog("MP-NPCZ"))
    local l = lastLog("MP-NPCZ npc=f_a") or ""
    check("f: the line carries wrote/read/delta with a negative (sinking) delta", l:find("wrote=20.000", 1, true) and l:find("read=19.880", 1, true) and l:find("delta=-0.120", 1, true), l)
    -- throttled: 10 more ticks inside 2 s add no line
    for i = 1, 10 do tick("f_a", 0, 0, 20) end
    check("f: throttled to one line per 2 s per puppet", logCount("MP-NPCZ npc=f_a") == 1, tostring(logCount("MP-NPCZ npc=f_a")))
    NOW = NOW + 2.1
    tick("f_a", 0, 0, 20)
    check("f: a second line after 2 s", logCount("MP-NPCZ npc=f_a") == 2)
    check("f: the counters saw only sinks", KCD2MP._npcZStats.sinkN >= 10 and KCD2MP._npcZStats.floatN == 0 and math.abs(KCD2MP._npcZStats.maxAbs - 0.12) < 0.001, string.format("sink=%d float=%d max=%.3f", KCD2MP._npcZStats.sinkN, KCD2MP._npcZStats.floatN, KCD2MP._npcZStats.maxAbs))
    -- the rollup rides the 5 s cadence dump (needs a packet-cadence sample)
    NOW = NOW + 5.1
    tick("f_a", 0.2, 0, 20); tick("f_a", 0.4, 0, 20)
    KCD2MP.npcPacketStats.dumpAt = 0
    tick("f_a", 0.6, 0, 20)
    check("f: MP-NPCZ-SUMMARY rollup logged with counts", logCount("MP-NPCZ-SUMMARY n=") >= 1 and (lastLog("MP-NPCZ-SUMMARY") or ""):find("sink_n=", 1, true) ~= nil, lastLog("MP-NPCZ-SUMMARY"))
    check("f: no Lua errors", #ERRS == 0, ERRS[1])
end

-- ---------------------------------------------------------------- (g)
do
    reset(); NOW = 600
    KCD2MP.wo102.authorityHost = true
    local e = mkEntity("g_a", 0, 0, 30)
    for i = 1, 3 do tick("g_a", 0, 0, 30) end
    -- a pure-Z yank: the body reads 1 m below the write, every tick
    local realSet = e.SetWorldPos
    e.SetWorldPos = function(self, pos) realSet(self, pos); self.pz = pos.z - 1.0 end
    clearLog()
    for i = 1, 12 do tick("g_a", 0, 0, 30) end
    check("g: a pure-Z displacement reaches the contention detector (was XY-only)",
          logCount("MP-AUTHORITY-VIOLATION npc=g_a") >= 1, lastLog("MP-AUTHORITY-VIOLATION"))
    local v = lastLog("MP-AUTHORITY-VIOLATION npc=g_a") or ""
    check("g: its dist_m is the 3-D magnitude (1.00)", v:find("dist_m=1.00", 1, true) ~= nil, v)
    check("g: no Lua errors", #ERRS == 0, ERRS[1])
end

-- ---------------------------------------------------------------- (h)
do
    reset(); NOW = 700
    KCD2MP.wo102.posNative = false; KCD2MP.wo102.npcScanNative = true
    clearLog()
    KCD2MP_ApplyPreset("legacy")
    check("h: legacy = 0.26.4: read native ON, cap 40, radius 30, lever ON, replicas OFF, yield OFF, dwell 10",
          KCD2MP.wo1025.readNative == true and KCD2MP.wo1025.npcTrackMax == 40 and KCD2MP.wo1025.cullRadius == 30
          and KCD2MP.wo102.authorityPause == true and KCD2MP.npcReplica.enabled == false and KCD2MP.npcYield.enabled == false and KCD2MP.wo1025.resumeDwellS == 10.0,
          string.format("rn=%s cap=%s cull=%s pause=%s", tostring(KCD2MP.wo1025.readNative), tostring(KCD2MP.wo1025.npcTrackMax), tostring(KCD2MP.wo1025.cullRadius), tostring(KCD2MP.wo102.authorityPause)))
    check("h: legacy logs a row for every WO-110 value", logCount("MP-PRESET name=legacy set=npc_read_native") == 1 and logCount("MP-PRESET name=legacy set=npc_track_max") == 1 and logCount("MP-PRESET name=legacy set=cull_radius_m") == 1)
    check("h: legacy announces the cap to the agent", evtCount("npc_track_max", "40") == 1)
    clearLog()
    KCD2MP_ApplyPreset("clean")
    check("h: clean = 0.26.5: read native OFF, cap 200, radius 60",
          KCD2MP.wo1025.readNative == false and KCD2MP.wo1025.npcTrackMax == 200 and KCD2MP.wo1025.cullRadius == 60)
    check("h: the toast names the versions", (TOASTS[#TOASTS] or ""):find("0.26.5", 1, true) ~= nil or logCount("Preset applied: clean (0.26.5 defaults)") >= 1, TOASTS[#TOASTS])
    check("h: authority model untouched", KCD2MP.wo102.authorityHost == true and KCD2MP.wo102.posNative == false and KCD2MP.wo102.npcScanNative == true)
    check("h: no Lua errors", #ERRS == 0, ERRS[1])
end

-- ---------------------------------------------------------------- (i)
do
    for _, name in ipairs({ "mp_npc_track_max", "mp_cull_radius" }) do
        local c = CCMDS[name]
        check("i: " .. name .. " registered with an unquoted %line", c ~= nil and c.body:find("(%line)", 1, true) ~= nil and not c.body:find('"%line"', 1, true), c and c.body)
    end
end

for _, r in ipairs(RESULTS) do print(r) end
local pass, fail = 0, 0
for _, r in ipairs(RESULTS) do if r:sub(1, 4) == "PASS" then pass = pass + 1 else fail = fail + 1 end end
print(string.format("RESULT: %d passed, %d failed", pass, fail))
