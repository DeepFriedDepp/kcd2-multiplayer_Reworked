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

-- ---------------------------------------------------------------- Phase 2
-- MP-AUTHORITY: per-NPC ownership transitions.
--   (g) a puppet start from ghost 1 logs acquire owner=1 via=stream
--   (h) the same puppet fed by ghost 2 logs owner-change from=1 owner=2
--   (i) release on silence logs release owner=2 via=silence with held_s
--   (j) the emitter logs acquire owner=self via=authority-default on the
--       authority and via=claim on a non-authority; untrack logs release
--   (k) a seven-argument call (older agent) logs owner=? and never errors
--   (l) MP-SUMMARY-MOD carries the auth_* counters and auth_model=claim

local NEXTID = 9000
local function mkEntity(name, x, y, z)
    NEXTID = NEXTID + 1
    local e = { class = "NPC", id = NEXTID, px = x or 0, py = y or 0, pz = z or 0, rz = 0, writes = {}, dead = false, hp = 100 }
    e.GetName = function(self) return name end
    e.GetWorldPos = function(self) return { x = self.px, y = self.py, z = self.pz } end
    e.GetWorldAngles = function(self) return { x = 0, y = 0, z = self.rz } end
    e.SetWorldPos = function(self, pos) self.px, self.py, self.pz = pos.x, pos.y, pos.z; self.writes[#self.writes + 1] = pos end
    e.SetWorldAngles = function(self, a) self.rz = a.z end
    e.StartAnimation = function() end
    e.actor = { IsDead = function() return e.dead end, IsUnconscious = function() return false end, GetHealth = function() return e.hp end }
    e.human = { IsWeaponDrawn = function() return false end, DrawWeapon = function() return true end, HolsterWeapon = function() return true end }
    return e
end
local function resetNpc()
    KCD2MP.npcPuppets = {}; KCD2MP.npcTracked = {}; KCD2MP.dragging = {}; KCD2MP.dragWatch = {}
    KCD2MP.npcPuppetRunning = false; KCD2MP._npcDivergeUntil = {}
    KCD2MP._authStats = { acquire = 0, release = 0, ownerChange = 0 }
    ENTS = {}; SPHERE = {}; TIMERS = {}; ERRS = {}
end

do -- (g)(h)(i)
    resetNpc(); clearLog()
    local e = mkEntity("auth_a", 0, 0, 0); ENTS["auth_a"] = e
    NOW = 100
    KCD2MP_ApplyNpcState("auth_a", 1, 0, 0, 0, 100, 0, 1)
    check("g: puppet start logs acquire owner=1 via=stream",
        logCount("MP-AUTHORITY npc=auth_a event=acquire owner=1 via=stream held_s=0.0 model=claim") == 1)
    NOW = 101
    KCD2MP_ApplyNpcState("auth_a", 1.5, 0, 0, 0, 100, 0, 1)
    check("h: same owner logs no owner-change", logCount("event=owner-change") == 0)
    NOW = 102.5
    KCD2MP_ApplyNpcState("auth_a", 2, 0, 0, 0, 100, 0, 2)
    check("h: new sender logs owner-change from=1 owner=2 with held_s",
        logCount("MP-AUTHORITY npc=auth_a event=owner-change owner=2 via=stream held_s=2.5 model=claim from=1") == 1)
    check("h: puppet records the new owner", KCD2MP.npcPuppets["auth_a"].owner == 2)
    -- silence: advance past releaseS and tick
    NOW = 102.5 + (KCD2MP.npcSync.releaseS or 3) + 1
    KCD2MP.npcPuppetRunning = true
    KCD2MP_NpcPuppetTick("ext")
    check("i: silence release logs release owner=2 via=silence",
        logCount("MP-AUTHORITY npc=auth_a event=release owner=2 via=silence held_s=" .. string.format("%.1f", (KCD2MP.npcSync.releaseS or 3) + 1) .. " model=claim") == 1,
        lastLog("event=release"))
    check("i: puppet gone", KCD2MP.npcPuppets["auth_a"] == nil)
    check("g-i: no Lua errors", #ERRS == 0, ERRS[1])
end

do -- (j) emitter side
    resetNpc(); clearLog()
    local e = mkEntity("auth_b", 5, 0, 0); ENTS["auth_b"] = e; SPHERE = { e }
    KCD2MP.npcSync.enabled = true; KCD2MP.npcSyncRunning = true
    KCD2MP.hitSensorOn = true
    KCD2MP._npcScanAt = 0; NOW = 200
    KCD2MP_NpcSyncTick()
    check("j: authority tracking logs acquire owner=self via=authority-default",
        logCount("MP-AUTHORITY npc=auth_b event=acquire owner=self via=authority-default") == 1, lastLog("MP-AUTHORITY"))
    -- move the NPC out of range -> untrack on the next scan
    e.px = 500; SPHERE = {}
    NOW = 203; KCD2MP._npcScanAt = 0
    KCD2MP_NpcSyncTick()
    check("j: untrack logs release owner=self via=untrack held_s=3.0",
        logCount("MP-AUTHORITY npc=auth_b event=release owner=self via=untrack held_s=3.0") == 1, lastLog("MP-AUTHORITY"))
    -- non-authority with a ghost present -> claim
    clearLog()
    KCD2MP.hitSensorOn = false
    KCD2MP.ghosts = { ["1"] = { entity = {}, istate = {} } }
    local e2 = mkEntity("auth_c", 4, 0, 0); ENTS["auth_c"] = e2; SPHERE = { e2 }
    NOW = 210; KCD2MP._npcScanAt = 0
    KCD2MP_NpcSyncTick()
    check("j: non-authority tracking logs acquire owner=self via=claim",
        logCount("MP-AUTHORITY npc=auth_c event=acquire owner=self via=claim") == 1, lastLog("MP-AUTHORITY"))
    check("j: and emits npc_claim", logCount("npc_claim auth_c") >= 1)
    KCD2MP.ghosts = {}; KCD2MP.npcSyncRunning = false
    check("j: no Lua errors", #ERRS == 0, ERRS[1])
end

do -- (k) older agent: seven arguments
    resetNpc(); clearLog()
    local e = mkEntity("auth_d", 0, 0, 0); ENTS["auth_d"] = e
    NOW = 300
    KCD2MP_ApplyNpcState("auth_d", 1, 0, 0, 0, 100, 0)
    check("k: seven-arg call logs owner=?", logCount("MP-AUTHORITY npc=auth_d event=acquire owner=? via=stream") == 1)
    KCD2MP_ApplyNpcState("auth_d", 1.2, 0, 0, 0, 100, 0)
    check("k: seven-arg call never logs owner-change", logCount("event=owner-change") == 0)
    check("k: no Lua errors", #ERRS == 0, ERRS[1])
end

do -- (l) summary counters
    clearLog()
    KCD2MP_LogSummary("test")
    local sm = lastLog("MP-SUMMARY-MOD") or ""
    check("l: summary carries auth counters", sm:find("auth_acquire=1 auth_release=0 auth_owner_changes=0 auth_model=claim", 1, true) ~= nil, sm)
end

-- Summary.
local pass, fail = 0, 0
for _, r in ipairs(RESULTS) do if r:sub(1, 4) == "PASS" then pass = pass + 1 else fail = fail + 1 end end
OUT = table.concat(RESULTS, "\n") .. string.format("\n%d passed, %d failed", pass, fail)
