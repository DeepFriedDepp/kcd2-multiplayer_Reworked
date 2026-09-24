-- WO-108 synthetic test, against the real kdcmp.lua under MoonSharp.
--
--   (a) shipped defaults: pause lever ON, replicas OFF, yield OFF, dwell 10 s;
--       the WO108-BUILD marker line is logged at load
--   (b) the suspend-set invariant: the authority never pauses (MP-PAUSE
--       event=refused why=this-machine-is-authority); a puppet start on the
--       non-authority does
--   (c) identity: every MP-PAUSE line carries wuid= eid= body= exec=
--   (d) the violation line has no `paused=`; it has pause_issued= pause_exec=
--   (e) relax tagging: a displacement pointing at the anchor, a few percent of
--       the distance, tags kind=relax and does not count as a violation; a
--       perpendicular push is still kind=contention; a 131 m yank is still
--       kind=diverge
--   (f) mp_resume_all resumes everything ever paused and switches the lever off
--   (g) presets: legacy sets the 0.26.3 values, clean sets them back, every
--       value logs one MP-PRESET line, the authority model is untouched
--   (h) the coverage-gap detector: a paused puppet with no writes past
--       releaseS + 5 s is logged MP-PAUSE-GAP reason=no-writes and resumed; a
--       paused name with no puppet and no pending dwell is reason=untracked
--   (i) the dwell: a silence release holds the pause, a stream that returns
--       inside the dwell cancels the resume without a second PauseNPC, a
--       stream that stays away resumes via=dwell
--   (j) reload re-assert: after a confirmed-dead chain restart the sweep
--       re-issues wh_ai_PauseNPC once for every live paused puppet
--   (k) the new console commands are registered; the summary line carries
--       the pause counters
--
-- What this proves: the Lua half behaves as documented. What it does NOT
-- prove: that the engine suspends anything (docs/WO-107-ai-suppression.md
-- is the solo evidence; two-player is the peer test this build exists for).
--
-- Part 1: engine stubs + a fake clock (the WO-102 driver's shape).

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

-- (a) defaults and the build marker -- read BEFORE any scenario touches them.
local DEF_PAUSE, DEF_REPLICA, DEF_YIELD, DEF_DWELL =
    KCD2MP.wo102.authorityPause, KCD2MP.npcReplica.enabled, KCD2MP.npcYield.enabled, KCD2MP.wo1025.resumeDwellS
check("a: pause lever ships ON", DEF_PAUSE == true, tostring(DEF_PAUSE))
check("a: replicas ship OFF", DEF_REPLICA == false, tostring(DEF_REPLICA))
check("a: yield ships OFF", DEF_YIELD == false, tostring(DEF_YIELD))
check("a: resume dwell ships 10 s", DEF_DWELL == 10.0, tostring(DEF_DWELL))
check("a: yield thresholds untouched (still the violation detector's)", KCD2MP.npcYield.dispM == 0.30 and KCD2MP.npcYield.ticks == 10)
check("a: WO108-BUILD marker logged at load with the shipped values",
      logCount("WO108-BUILD pause_lever=on npc_replica=off npc_yield=off resume_dwell_s=10.0") == 1, lastLog("WO108-BUILD"))
check("a: authority model defaults unchanged", KCD2MP.wo102.authorityHost == true and KCD2MP.wo102.posNative == true and KCD2MP.wo102.npcScanNative == true)

local NEXTID = 0x0C0000
local function mkEntity(name, x, y, z)
    NEXTID = NEXTID + 1
    local e = { class = "NPC", id = "userdata: " .. string.format("%016X", NEXTID), px = x or 0, py = y or 0, pz = z or 0, rz = 0, writes = {}, dead = false, hp = 100 }
    e.GetName = function(self) return name end
    e.GetWorldPos = function(self, t) t = t or {}; t.x, t.y, t.z = self.px, self.py, self.pz; return t end
    e.GetWorldAngles = function(self, t) t = t or {}; t.x, t.y, t.z = 0, 0, self.rz; return t end
    e.SetWorldPos = function(self, pos) self.px, self.py, self.pz = pos.x, pos.y, pos.z; self.writes[#self.writes + 1] = { x = pos.x, y = pos.y } end
    e.SetWorldAngles = function(self, a) self.rz = a.z end
    e.StartAnimation = function() end
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
    KCD2MP._pauseRefusedAuthLogged = nil
    KCD2MP._chainDeadRestartAt = nil; KCD2MP._pauseReassertedAt = 0; KCD2MP._npcReconcileAt = nil
    KCD2MP._npcDeathRemote = {}; KCD2MP._npcDeathDiverged = {}
    KCD2MP.npcDiverge = true; KCD2MP.npcYield.enabled = false
    KCD2MP.npcReplica.enabled = false; KCD2MP._npcReplicas = {}
    KCD2MP.wo1025.resumeDwellS = 10.0
    KCD2MP.npcSync.enabled = true; KCD2MP.npcSyncRunning = true
    KCD2MP.ghosts = {}; KCD2MP._npcScanAnchors = nil
    ENTS = {}; SPHERE = {}; TIMERS = {}; ERRS = {}; CMDS = {}; SPAWNS = {}
    clearLog()
end

-- one packet at (sx, sy) for `name`, then one puppet tick
local function tick(name, sx, sy, flags)
    NOW = NOW + 0.05
    KCD2MP_ApplyNpcState(name, sx, sy, 0, 0, 100, flags or 0, 1)
    KCD2MP.npcPuppetRunning = true
    KCD2MP_NpcPuppetTick("ext")
end
local function syncTick() KCD2MP._npcScanAt = NOW; KCD2MP_NpcSyncTick() end

-- ---------------------------------------------------------------- (b)
do
    reset(); NOW = 100
    KCD2MP.hitSensorOn = true                         -- this machine IS the authority
    local e = mkEntity("b_npc", 10, 0, 0)
    tick("b_npc", 10, 0)
    check("b: authority: puppet exists but no wh_ai_PauseNPC is issued", KCD2MP.npcPuppets["b_npc"] ~= nil and cmdCount("wh_ai_PauseNPC") == 0)
    check("b: authority: refusal logged once with the reason", logCount("MP-PAUSE npc=b_npc event=refused") == 1
          and (lastLog("MP-PAUSE npc=b_npc") or ""):find("why=this-machine-is-authority", 1, true) ~= nil, lastLog("MP-PAUSE"))
    tick("b_npc", 10, 0)
    check("b: authority: refusal is logged once, counted every time", logCount("event=refused") == 1 and KCD2MP._pauseStats.refusedAuthority >= 2)
    check("b: _npcPaused stays empty on the authority", next(KCD2MP._npcPaused) == nil)

    reset(); NOW = 110
    local e2 = mkEntity("b2_npc", 10, 0, 0)
    tick("b2_npc", 10, 0)
    check("b: non-authority: puppet start issues exactly one wh_ai_PauseNPC", cmdCount("wh_ai_PauseNPC b2_npc") == 1, table.concat(CMDS, " | "))
    check("b: the suspend set is a subset of the puppet set", KCD2MP._npcPaused["b2_npc"] ~= nil and KCD2MP.npcPuppets["b2_npc"] ~= nil)
    check("b: no Lua errors", #ERRS == 0, ERRS[1])
end

-- ---------------------------------------------------------------- (c)
do
    reset(); NOW = 200
    local e = mkEntity("c_npc", 10, 0, 0)
    tick("c_npc", 10, 0)
    local l = lastLog("MP-PAUSE npc=c_npc event=pause") or ""
    check("c: pause line carries wuid from soul:GetId()", l:find("wuid=05000000000001DC", 1, true) ~= nil, l)
    check("c: pause line carries the entity id hex tail", l:find("eid=" .. string.format("%016X", NEXTID), 1, true) ~= nil, l)
    check("c: pause line carries body class, exec verdict, why and owner",
          l:find("body=NPC", 1, true) and l:find("exec=ok", 1, true) and l:find("why=puppet-start", 1, true) and l:find("owner=1", 1, true), l)
    -- resume line: same fields
    KCD2MP.wo1025.resumeDwellS = 0
    NOW = NOW + 4; KCD2MP.npcPuppetRunning = true; KCD2MP_NpcPuppetTick("ext")
    local r = lastLog("MP-PAUSE npc=c_npc event=resume") or ""
    check("c: resume line carries the same identity fields", r:find("wuid=05000000000001DC", 1, true) and r:find("eid=", 1, true) and r:find("exec=ok", 1, true) and r:find("why=silence", 1, true), r)
    check("c: MP-AUTHORITY pause/resume lines still logged (WO-102 vocabulary kept)", logCount("MP-AUTHORITY npc=c_npc event=pause") == 1 and logCount("MP-AUTHORITY npc=c_npc event=resume") == 1)
    check("c: no Lua errors", #ERRS == 0, ERRS[1])
end

-- ---------------------------------------------------------------- (d) + (e)
local CONTEND = KCD2MP.npcYield.ticks + 2
do
    -- perpendicular push: genuine contention, not relax
    reset(); NOW = 300
    local e = mkEntity("d_npc", 10, 0, 0)
    tick("d_npc", 10, 0)
    for i = 1, CONTEND do
        e.py = e.py + 0.6                        -- something pushes it sideways each tick
        tick("d_npc", 10, 0)
    end
    local v = lastLog("MP-AUTHORITY-VIOLATION npc=d_npc") or ""
    check("d: a violation was logged", v ~= "", v)
    check("d: no field named paused=", v:find(" paused=", 1, true) == nil, v)
    check("d: pause_issued=1 and pause_exec=ok are present", v:find("pause_issued=1", 1, true) ~= nil and v:find("pause_exec=ok", 1, true) ~= nil, v)
    check("e: perpendicular push is kind=contention", v:find("kind=contention", 1, true) ~= nil, v)
    check("e: contention counted as a violation", (KCD2MP._authStats.violation or 0) >= 1 and KCD2MP._pauseStats.relax == 0)

    -- relax-shaped: stream sits 10 m from where the engine had the body; between
    -- writes the body creeps 5 % of the way back toward that anchor
    reset(); NOW = 320
    local e2 = mkEntity("e_npc", 10, 0, 0)          -- anchor (10, 0)
    tick("e_npc", 0, 0)                              -- stream at (0, 0): >5 m -> snap
    for i = 1, CONTEND + 2 do
        local p = KCD2MP.npcPuppets["e_npc"]
        if p and p.lastWroteX then
            e2.px = p.lastWroteX + 0.05 * (p.ax - p.lastWroteX)
            e2.py = p.lastWroteY + 0.05 * (p.ay - p.lastWroteY)
        end
        tick("e_npc", 0, 0)
    end
    local rv = lastLog("MP-AUTHORITY-VIOLATION npc=e_npc") or ""
    check("e: decay toward the anchor is tagged kind=relax", rv:find("kind=relax", 1, true) ~= nil, rv)
    check("e: relax line still carries anchor_m and cos for audit", rv:find("anchor_m=", 1, true) ~= nil and rv:find("cos=1.00", 1, true) ~= nil, rv)
    check("e: relax is counted separately and NOT as a violation", KCD2MP._pauseStats.relax >= 1 and (KCD2MP._authStats.violation or 0) == 0,
          "relax=" .. tostring(KCD2MP._pauseStats.relax) .. " violation=" .. tostring(KCD2MP._authStats.violation))
    check("e: relax never reaches the replica trigger", #SPAWNS == 0 and logCount("MP-NPCREPLICA") == 0)

    -- 131 m yank: still a diverge, whatever direction
    reset(); NOW = 340
    local e3 = mkEntity("f_npc", 10, 0, 0)
    tick("f_npc", 0, 0)
    e3.px = e3.px + 131
    tick("f_npc", 0, 0)
    local dv = lastLog("MP-AUTHORITY-VIOLATION npc=f_npc") or ""
    check("e: 131 m yank is kind=diverge", dv:find("kind=diverge", 1, true) ~= nil and dv:find("dist_m=131", 1, true) ~= nil, dv)
    check("e: diverge counted as a violation, puppet kept (host authority never hands back)", (KCD2MP._authStats.violation or 0) == 1 and KCD2MP.npcPuppets["f_npc"] ~= nil)
    check("d/e: no Lua errors", #ERRS == 0, ERRS[1])
end

-- ---------------------------------------------------------------- (f)
do
    reset(); NOW = 400
    mkEntity("f1", 1, 0, 0); mkEntity("f2", 2, 0, 0); mkEntity("f3", 3, 0, 0)
    tick("f1", 1, 0); tick("f2", 2, 0)
    -- f3 was paused earlier this session and already resumed: still in the ever-set
    tick("f3", 3, 0)
    KCD2MP.wo1025.resumeDwellS = 0
    KCD2MP.npcPuppets["f3"] = nil; KCD2MP._npcPaused["f3"] = nil          -- bookkeeping lost it (the case the sweep exists for)
    CMDS = {}
    local n = KCD2MP_ResumeAllPaused("mp_resume_all")
    check("f: lever switched OFF", KCD2MP.wo102.authorityPause == false)
    check("f: every currently-paused name resumed", cmdCount("wh_ai_ResumeNPC f1") >= 1 and cmdCount("wh_ai_ResumeNPC f2") >= 1 and next(KCD2MP._npcPaused) == nil)
    check("f: the ever-paused sweep also resumes the name the bookkeeping lost", cmdCount("wh_ai_ResumeNPC f3") == 1)
    check("f: no PauseNPC is issued by the sweep", cmdCount("wh_ai_PauseNPC") == 0)
    check("f: summary line names lever_was=on lever_now=off and the count", (lastLog("MP-PAUSE resume-all") or ""):find("swept=3 lever_was=on lever_now=off", 1, true) ~= nil, lastLog("MP-PAUSE resume-all"))
    check("f: returns the swept count", n == 3, tostring(n))
    -- with the lever off, the next puppet tick does NOT re-pause
    KCD2MP.npcPuppetRunning = true; NOW = NOW + 0.05; KCD2MP_NpcPuppetTick("ext")
    check("f: nothing re-paused 50 ms later", cmdCount("wh_ai_PauseNPC") == 0)
    check("f: no Lua errors", #ERRS == 0, ERRS[1])
end

-- ---------------------------------------------------------------- (g)
do
    reset(); NOW = 500
    KCD2MP.wo102.authorityHost = true; KCD2MP.wo102.posNative = false; KCD2MP.wo102.npcScanNative = true
    KCD2MP.npcPuppetTickMs = 200; KCD2MP.wo1025.authorityRadius = 45
    clearLog()
    KCD2MP_ApplyPreset("legacy")
    -- WO-110: `legacy` is the 0.26.4 build now (lever on, replicas off, yield
    -- off, dwell 10 -- WO-108's own defaults), and what it puts BACK is the
    -- 0.26.4 behaviour WO-110 changed: the native position read (R1).
    check("g: legacy -> 0.26.4: lever on, replicas off, yield off, dwell 10, native NPC read on",
          KCD2MP.wo102.authorityPause == true and KCD2MP.npcReplica.enabled == false and KCD2MP.npcYield.enabled == false and KCD2MP.wo1025.resumeDwellS == 10.0
          and KCD2MP.wo1025.readNative == true,
          string.format("pause=%s replica=%s yield=%s dwell=%s readNative=%s last=%s", tostring(KCD2MP.wo102.authorityPause), tostring(KCD2MP.npcReplica.enabled),
              tostring(KCD2MP.npcYield.enabled), tostring(KCD2MP.wo1025.resumeDwellS), tostring(KCD2MP.wo1025.readNative), tostring(lastLog("WO103-READNATIVE") or lastLog("MP-NPCREAD"))))
    check("g: legacy re-applies the shared values too (puppet rate, radius)", KCD2MP.npcPuppetTickMs == 50 and KCD2MP.wo1025.authorityRadius == 300)
    local nLegacy = logCount("MP-PRESET name=legacy set=")
    check("g: every value logs one MP-PRESET line (21)", nLegacy == 21, tostring(nLegacy))   -- WO-110: + npc_track_max, cull_radius_m, npc_senderclock; WO-113: + respawn; WO-118: + npc_native_write
    check("g: applied line says authority_model=untouched", logCount("MP-PRESET applied name=legacy values=21 authority_model=untouched") == 1, lastLog("MP-PRESET applied"))
    check("g: legacy -> vanilla death (WO-113 respawn off)", KCD2MP.respawnEnabled == false)
    check("g: legacy -> 0.26.4 arrival-time stamps", KCD2MP.npcSenderClock == false)
    check("g: legacy -> 0.26.4 cull radius 30", KCD2MP.wo1025.cullRadius == 30)
    check("g: legacy -> 0.26.4 track cap 40", KCD2MP.wo1025.npcTrackMax == 40 and logCount("[KCD2-MP-EVT] v1 ") >= 1)
    check("g: authority model untouched by legacy", KCD2MP.wo102.authorityHost == true and KCD2MP.wo102.posNative == false and KCD2MP.wo102.npcScanNative == true)
    clearLog()
    KCD2MP_ApplyPreset("clean")
    check("g: clean -> lever on, replicas off, yield off, dwell 10",
          KCD2MP.wo102.authorityPause == true and KCD2MP.npcReplica.enabled == false and KCD2MP.npcYield.enabled == false and KCD2MP.wo1025.resumeDwellS == 10.0)
    check("g: clean logs 21 values too", logCount("MP-PRESET name=clean set=") == 21)
    check("g: clean -> respawn on (WO-113 default)", KCD2MP.respawnEnabled == true)
    check("g: clean -> sender clock on", KCD2MP.npcSenderClock == true)
    check("g: clean -> cull radius 60", KCD2MP.wo1025.cullRadius == 60)
    check("g: clean -> track cap 200", KCD2MP.wo1025.npcTrackMax == 200)
    check("g: a from->to line names the R1 flip", logCount("MP-PRESET name=clean set=npc_read_native from=true to=false") == 1)
    check("g: clean -> native NPC read off (WO-110 R1 default)", KCD2MP.wo1025.readNative == false)
    check("g: round trip lands on the shipped defaults", KCD2MP.wo102.authorityPause == DEF_PAUSE and KCD2MP.npcReplica.enabled == DEF_REPLICA
          and KCD2MP.npcYield.enabled == DEF_YIELD and KCD2MP.wo1025.resumeDwellS == DEF_DWELL)
    check("g: authority model untouched by clean", KCD2MP.wo102.authorityHost == true and KCD2MP.wo102.posNative == false and KCD2MP.wo102.npcScanNative == true)
    check("g: unknown preset refused", KCD2MP_ApplyPreset("bogus") == false and logCount("MP-PRESET unknown preset 'bogus'") == 1)
    check("g: no Lua errors", #ERRS == 0, ERRS[1])
end

-- ---------------------------------------------------------------- (h)
do
    reset(); NOW = 600
    local e = mkEntity("h_npc", 10, 0, 0)
    tick("h_npc", 10, 0)
    check("h: paused and a puppet", KCD2MP._npcPaused["h_npc"] ~= nil and KCD2MP.npcPuppets["h_npc"] ~= nil)
    -- the puppet chain dies (no more puppet ticks); packets stop; only the sync tick runs
    CMDS = {}
    NOW = NOW + 4; syncTick()                    -- < releaseS + 5 s: nothing yet
    check("h: inside the gap window nothing is resumed", cmdCount("wh_ai_ResumeNPC") == 0 and KCD2MP.npcPuppets["h_npc"] ~= nil)
    NOW = NOW + 6; syncTick()                    -- 10 s without a packet, reconcile due
    check("h: MP-PAUSE-GAP reason=no-writes logged", logCount("MP-PAUSE-GAP npc=h_npc reason=no-writes") == 1, lastLog("MP-PAUSE-GAP"))
    check("h: gap -> resumed and the stale puppet dropped", cmdCount("wh_ai_ResumeNPC h_npc") == 1 and KCD2MP._npcPaused["h_npc"] == nil and KCD2MP.npcPuppets["h_npc"] == nil)
    check("h: resume line says via=gap-no-writes", logCount("event=resume owner=? via=gap-no-writes") == 1)
    check("h: gap counted", KCD2MP._pauseStats.gap == 1)

    -- untracked: paused, no puppet, no pending
    CMDS = {}; clearLog()
    KCD2MP._npcPaused["h_orphan"] = NOW
    NOW = NOW + 5.1; syncTick()
    check("h: untracked pause logged as MP-PAUSE-GAP reason=untracked", logCount("MP-PAUSE-GAP npc=h_orphan reason=untracked") == 1)
    check("h: ...and resumed via=reconcile (the WO-102.5 line kept)", cmdCount("wh_ai_ResumeNPC h_orphan") == 1
          and logCount("WO102-AUTHORITY reconcile: resumed h_orphan") == 1 and logCount("event=resume owner=? via=reconcile") == 1)
    check("h: no Lua errors", #ERRS == 0, ERRS[1])
end

-- ---------------------------------------------------------------- (i)
do
    reset(); NOW = 700
    local e = mkEntity("i_npc", 10, 0, 0)
    tick("i_npc", 10, 0)
    CMDS = {}
    NOW = NOW + 3.5; KCD2MP.npcPuppetRunning = true; KCD2MP_NpcPuppetTick("ext")   -- silence release
    check("i: silence release drops the puppet but holds the pause", KCD2MP.npcPuppets["i_npc"] == nil and KCD2MP._npcPaused["i_npc"] ~= nil)
    check("i: release logged with +dwell, no ResumeNPC yet", logCount("MP-PAUSE npc=i_npc event=release") == 1
          and (lastLog("event=release") or ""):find("why=silence+dwell", 1, true) ~= nil and cmdCount("wh_ai_ResumeNPC") == 0, lastLog("event=release"))
    check("i: pending deadline set", KCD2MP._npcResumePending["i_npc"] ~= nil)
    NOW = NOW + 5; syncTick()
    check("i: 5 s in: still pending, not resumed, not a gap", cmdCount("wh_ai_ResumeNPC") == 0 and logCount("MP-PAUSE-GAP") == 0)
    -- the stream comes back inside the dwell
    tick("i_npc", 10, 0)
    check("i: stream back -> cancel, no second PauseNPC", logCount("MP-PAUSE npc=i_npc event=cancel") == 1 and cmdCount("wh_ai_PauseNPC") == 0
          and KCD2MP._npcResumePending["i_npc"] == nil and KCD2MP._npcPaused["i_npc"] ~= nil, lastLog("MP-PAUSE npc=i_npc"))
    check("i: cancel counted", KCD2MP._pauseStats.cancelled == 1)
    -- and goes away for good
    CMDS = {}
    NOW = NOW + 3.5; KCD2MP.npcPuppetRunning = true; KCD2MP_NpcPuppetTick("ext")
    NOW = NOW + 9; syncTick()
    check("i: 9 s in: still held", cmdCount("wh_ai_ResumeNPC") == 0)
    NOW = NOW + 1.2; syncTick()
    check("i: past the dwell: resumed via=dwell", cmdCount("wh_ai_ResumeNPC i_npc") == 1 and logCount("event=resume owner=? via=dwell") == 1
          and KCD2MP._npcPaused["i_npc"] == nil and KCD2MP._npcResumePending["i_npc"] == nil)
    check("i: dwell resume counted", KCD2MP._pauseStats.dwellResumes == 1)
    -- dwell 0 = the 0.26.3 shape
    reset(); NOW = 760; KCD2MP.wo1025.resumeDwellS = 0
    mkEntity("i0_npc", 10, 0, 0); tick("i0_npc", 10, 0); CMDS = {}
    NOW = NOW + 3.5; KCD2MP.npcPuppetRunning = true; KCD2MP_NpcPuppetTick("ext")
    check("i: dwell 0 resumes at once via=silence", cmdCount("wh_ai_ResumeNPC i0_npc") == 1 and logCount("event=resume owner=? via=silence") == 1)
    check("i: no Lua errors", #ERRS == 0, ERRS[1])
end

-- ---------------------------------------------------------------- (j)
do
    reset(); NOW = 800
    mkEntity("j1", 1, 0, 0); mkEntity("j2", 2, 0, 0)
    tick("j1", 1, 0); tick("j2", 2, 0)
    CMDS = {}; clearLog()
    KCD2MP._chainDeadRestartAt = NOW             -- what chainMayStart stamps on a confirmed-dead restart
    NOW = NOW + 0.1; tick("j1", 1, 0); tick("j2", 2, 0)   -- packets keep flowing
    NOW = NOW + 5.0; syncTick()
    check("j: both live puppets re-asserted once", cmdCount("wh_ai_PauseNPC j1") == 1 and cmdCount("wh_ai_PauseNPC j2") == 1)
    check("j: reassert lines carry identity and why=chain-dead-restart", logCount("MP-PAUSE npc=j1 event=reassert") == 1
          and (lastLog("MP-PAUSE npc=j1 event=reassert") or ""):find("why=chain-dead-restart", 1, true) ~= nil, lastLog("event=reassert"))
    check("j: summary of the re-assert logged", logCount("MP-PAUSE reasserted 2 pause(s)") == 1)
    check("j: counted", KCD2MP._pauseStats.reassert == 2)
    CMDS = {}
    NOW = NOW + 0.1; tick("j1", 1, 0); tick("j2", 2, 0)
    NOW = NOW + 5.0; syncTick()
    check("j: not re-asserted again without a new restart", cmdCount("wh_ai_PauseNPC") == 0)
    check("j: no Lua errors", #ERRS == 0, ERRS[1])
end

-- ---------------------------------------------------------------- (k)
do
    local names = { "mp_preset_clean", "mp_preset_legacy", "mp_resume_all", "mp_resume_dwell", "mp_authority_pause_on", "mp_authority_pause_off" }
    local missing = ""
    for _, n in ipairs(names) do if not CCMDS[n] then missing = missing .. n .. " " end end
    check("k: WO-108 console commands registered", missing == "", missing)
    check("k: mp_resume_dwell takes an argument with the lowercase placeholder", CCMDS["mp_resume_dwell"] and CCMDS["mp_resume_dwell"].body:find("%line", 1, true) ~= nil)
    check("k: the pause_on help no longer claims the lever is broken", CCMDS["mp_authority_pause_on"] and CCMDS["mp_authority_pause_on"].help:find("ON by default since 0.26.4", 1, true) ~= nil)
    reset(); NOW = 900
    KCD2MP._pauseStats.relax = 3; KCD2MP._pauseStats.gap = 1; KCD2MP._npcResumePending["k"] = NOW + 5
    clearLog(); KCD2MP_LogSummary("t")
    local sm = lastLog("MP-SUMMARY-MOD") or ""
    check("k: summary carries the pause counters", sm:find("pause_relax=3 pause_gaps=1 pause_reasserts=0 pause_dwell_resumes=0 pause_cancelled=0 pause_pending=1 pause_refused=0", 1, true) ~= nil, sm)
    clearLog(); KCD2MP_Wo102Status()
    check("k: status line carries pending/ever/dwell and the two flipped flags", (lastLog("WO102-STATUS") or ""):find("pause_pending=1 pause_ever=0 pause_dwell_s=10.0 npc_replica=off npc_yield=off", 1, true) ~= nil, lastLog("WO102-STATUS"))
    -- mp_resume_dwell setter
    clearLog()
    check("k: dwell setter accepts 4", KCD2MP_SetResumeDwell("4") == true and KCD2MP.wo1025.resumeDwellS == 4 and logCount("MP-PAUSE dwell set=4.0s was=10.0s") == 1)
    check("k: dwell setter rejects nonsense", KCD2MP_SetResumeDwell("abc") == false and KCD2MP.wo1025.resumeDwellS == 4)
    check("k: dwell setter bare reports", KCD2MP_SetResumeDwell("") == true and logCount("MP-PAUSE dwell=4.0s") == 1)
    check("k: no Lua errors", #ERRS == 0, ERRS[1])
end

-- Summary.
local pass, fail = 0, 0
for _, r in ipairs(RESULTS) do if r:sub(1, 4) == "PASS" then pass = pass + 1 else fail = fail + 1 end end
OUT = table.concat(RESULTS, "\n") .. string.format("\n%d passed, %d failed", pass, fail)
