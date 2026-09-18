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

-- (f) first: the SHIPPED defaults -- host authority on, pos_native off
--     (still genuinely unmeasured), authority_pause and npc_scan_native on
--     (both live-verified 2026-09-18, the maintainer's own call to keep
--     new WO-102.5 machinery exercised rather than default back to the
--     already-known-broken pre-WO-102.5 path) -- and the 0.23.2 knobs
--     untouched.
check("f: shipped defaults: authority_host on, pos_native off, authority_pause on, npc_scan_native on",
      KCD2MP.wo102.authorityHost == true and KCD2MP.wo102.posNative == false
      and KCD2MP.wo102.authorityPause == true and KCD2MP.wo102.npcScanNative == true)
check("f: 0.23.2 NPC-sync defaults intact", KCD2MP.npcSync.enabled == true and KCD2MP.npcProx.enabled == true
      and KCD2MP.npcDiverge == true and KCD2MP.npcYield.enabled == true)
-- Every scenario below starts from the OFF baseline (the 0.23.2 model) and
-- switches on what it tests, so the off state is proven to be 0.23.2.
KCD2MP_Wo102Set("authority_host", false, "agent")
KCD2MP_Wo102Set("authority_pause", false, "agent")
KCD2MP_Wo102Set("npc_scan_native", false, "agent")

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
check("d: status line", logCount("WO102-STATUS authority_host=off pos_native=off authority_pause=off npc_scan_native=off authority=peer paused_npcs=0") == 1, lastLog("WO102-STATUS"))

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
    KCD2MP.wo102.authorityHost = false; KCD2MP.wo102.authorityPause = false   -- the 0.23.2 baseline
    KCD2MP.wo102.npcScanNative = false   -- default flipped on 2026-09-18; tests still exercise the off path explicitly
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

-- ---------------------------------------------------------------- Phase 4
-- Host authority (mp_authority_host_on):
--   (m) a NON-authority never claims: the sync tick emits no npc_claim, tracks
--       nothing, runs no drag sensor; flipping the toggle on drops an existing
--       claim stream (release via=host-authority-on)
--   (n) the AUTHORITY scans around every peer ghost: an NPC 95 m from the
--       player but 5 m from a ghost is tracked; cap = maxTracked x anchors;
--       the WO102-AUTHORITY scan anchors line is logged once
--   (o) a puppet the local world drags 97 m is NOT released: no MP-NPCDIVERGE,
--       an MP-AUTHORITY-VIOLATION kind=diverge line, the puppet still exists
--       and is still written
--   (p) sustained sub-8 m contention does NOT yield: no MP-NPCYIELD, a
--       kind=contention violation after `ticks` ticks
--   (q) pause lever: with authority_pause on, a puppet start executes
--       "wh_ai_PauseNPC <name>", a silence release executes wh_ai_ResumeNPC,
--       and switching the lever off resumes everything still paused
--   (r) with authority_host OFF the 0.23.2 paths run: the same 97 m drag
--       releases with MP-NPCDIVERGE and no violation is ever logged
--   (s) the pause lever alone (authority_host off) does nothing

local function cmdCount(pat)
    local n = 0
    for _, c in ipairs(CMDS) do if string.find(c, pat, 1, true) then n = n + 1 end end
    return n
end
local function resetAll4()
    resetNpc(); CMDS = {}; KCD2MP._npcPaused = {}; KCD2MP._authViolationAt = {}; KCD2MP._authViolationN = {}
    KCD2MP._authStats = { acquire = 0, release = 0, ownerChange = 0, pause = 0, resume = 0, violation = 0 }
    KCD2MP.wo102.authorityHost = false; KCD2MP.wo102.authorityPause = false
    KCD2MP.npcDiverge = true; KCD2MP.npcYield.enabled = true
    KCD2MP.ghosts = {}; KCD2MP._npcScanAnchors = nil
    -- WO-102.5 Phase 4
    KCD2MP.wo1025.together = false; KCD2MP._togetherWantSince = nil; KCD2MP._colocatePendingRelease = {}
end

do -- (m)
    resetAll4(); clearLog()
    KCD2MP.hitSensorOn = false
    KCD2MP.npcSync.enabled = true; KCD2MP.npcSyncRunning = true
    KCD2MP.ghosts = { ["1"] = { entity = {}, istate = {} } }
    local e = mkEntity("m_npc", 4, 0, 0); ENTS["m_npc"] = e; SPHERE = { e }
    NOW = 400; KCD2MP._npcScanAt = 0
    KCD2MP_NpcSyncTick()
    check("m: claim model first -- the non-authority claims (control)", logCount("npc_claim m_npc") >= 1 and KCD2MP.npcTracked["m_npc"] ~= nil)
    clearLog()
    KCD2MP_Wo102Set("authority_host", true, "agent")
    check("m: flipping on drops the claim stream", KCD2MP.npcTracked["m_npc"] == nil
          and logCount("MP-AUTHORITY npc=m_npc event=release owner=self via=host-authority-on") == 1, lastLog("MP-AUTHORITY"))
    check("m: the drop is logged", logCount("WO102-AUTHORITY host authority ON on a non-authority: dropped 1 claim stream") == 1)
    clearLog()
    NOW = 401; KCD2MP._npcScanAt = 0
    KCD2MP_NpcSyncTick(); NOW = 402; KCD2MP._npcScanAt = 0; KCD2MP_NpcSyncTick()
    check("m: under host authority the non-authority emits no npc_claim", logCount("npc_claim") == 0)
    check("m: and tracks nothing", next(KCD2MP.npcTracked) == nil)
    check("m: and logs no NPC-DRAG", logCount("NPC-DRAG") == 0)
    KCD2MP.npcSyncRunning = false
    check("m: no Lua errors", #ERRS == 0, ERRS[1])
end

do -- (n)
    resetAll4(); clearLog()
    KCD2MP.hitSensorOn = true
    KCD2MP.wo102.authorityHost = true
    KCD2MP.npcSync.enabled = true; KCD2MP.npcSyncRunning = true
    KCD2MP.wo1025.together = true   -- WO-102.5 Phase 4: peer anchors only scanned while together
    local ghostEnt = { GetWorldPos = function() return { x = 100, y = 0, z = 0 } end }
    KCD2MP.ghosts = { ["1"] = { entity = ghostEnt, istate = {} } }
    local far = mkEntity("n_far", 95, 0, 0); ENTS["n_far"] = far          -- 95 m from the player, 5 m from the ghost
    local near = mkEntity("n_near", 3, 0, 0); ENTS["n_near"] = near
    -- the sphere stub ignores the centre, so return both for every anchor
    SPHERE = { far, near }
    NOW = 500; KCD2MP._npcScanAt = 0
    KCD2MP_NpcSyncTick()
    check("n: NPC near the peer ghost is tracked by the authority", KCD2MP.npcTracked["n_far"] ~= nil)
    check("n: NPC near the player is tracked too", KCD2MP.npcTracked["n_near"] ~= nil)
    check("n: anchors line logged uncapped under host authority (WO-102.5 Phase 3)", logCount("WO102-AUTHORITY scan anchors=2 cap=uncapped") == 1)
    check("n: both stream as npc_state", logCount("npc_state n_far") >= 1 and logCount("npc_state n_near") >= 1)
    -- control: same scene with host authority off -> the far NPC is not tracked
    KCD2MP.wo102.authorityHost = false; KCD2MP.npcTracked = {}; clearLog()
    NOW = 503; KCD2MP._npcScanAt = 0
    KCD2MP_NpcSyncTick()
    check("n: control -- claim model tracks only the player's neighbourhood", KCD2MP.npcTracked["n_far"] == nil and KCD2MP.npcTracked["n_near"] ~= nil)
    KCD2MP.npcSyncRunning = false; KCD2MP.hitSensorOn = false
    check("n: no Lua errors", #ERRS == 0, ERRS[1])
end

-- Drives a puppet through `n` 50 ms ticks while the "local world" drags the
-- body `dragM` metres off our write each tick (the WO-90/WO-99 fixture shape).
local function dragPuppet(name, e, dragM, n, srcId)
    for i = 1, n do
        NOW = NOW + 0.05
        KCD2MP_ApplyNpcState(name, 10, 0, 0, 0, 100, 0, srcId or 1)   -- stream keeps it at x=10
        KCD2MP.npcPuppetRunning = true
        KCD2MP_NpcPuppetTick("ext")
        -- the local brain moves it away AFTER our write
        e.px = e.px + dragM
    end
end

do -- (o) diverge refused under host authority
    resetAll4(); clearLog()
    KCD2MP.wo102.authorityHost = true
    local e = mkEntity("o_npc", 10, 0, 0); ENTS["o_npc"] = e
    NOW = 600
    dragPuppet("o_npc", e, 97, 6)
    check("o: no MP-NPCDIVERGE under host authority", logCount("MP-NPCDIVERGE") == 0)
    check("o: puppet still exists", KCD2MP.npcPuppets["o_npc"] ~= nil)
    check("o: violation logged as kind=diverge", logCount("MP-AUTHORITY-VIOLATION npc=o_npc kind=diverge") >= 1, lastLog("MP-AUTHORITY-VIOLATION"))
    check("o: violation counter counts every event", (KCD2MP._authStats.violation or 0) >= 3, KCD2MP._authStats.violation)
    check("o: the body is still written each tick", #e.writes >= 6)
    check("o: no Lua errors", #ERRS == 0, ERRS[1])
end

do -- (p) yield refused under host authority
    resetAll4(); clearLog()
    KCD2MP.wo102.authorityHost = true
    local e = mkEntity("p_npc", 10, 0, 0); ENTS["p_npc"] = e
    NOW = 700
    dragPuppet("p_npc", e, 0.6, KCD2MP.npcYield.ticks + 3)
    check("p: no MP-NPCYIELD under host authority", logCount("MP-NPCYIELD") == 0)
    check("p: puppet never yielded", KCD2MP.npcPuppets["p_npc"] ~= nil and not KCD2MP.npcPuppets["p_npc"].yielded)
    check("p: violation logged as kind=contention", logCount("MP-AUTHORITY-VIOLATION npc=p_npc kind=contention") >= 1, lastLog("MP-AUTHORITY-VIOLATION"))
    check("p: no Lua errors", #ERRS == 0, ERRS[1])
end

do -- (q) pause lever
    resetAll4(); clearLog()
    KCD2MP.wo102.authorityHost = true; KCD2MP.wo102.authorityPause = true
    local e = mkEntity("q_npc", 0, 0, 0); ENTS["q_npc"] = e
    NOW = 800
    KCD2MP_ApplyNpcState("q_npc", 1, 0, 0, 0, 100, 0, 1)
    check("q: puppet start executes wh_ai_PauseNPC", cmdCount("wh_ai_PauseNPC q_npc") == 1, table.concat(CMDS, " | "))
    check("q: MP-AUTHORITY event=pause", logCount("MP-AUTHORITY npc=q_npc event=pause owner=1 via=wh_ai_PauseNPC") == 1)
    KCD2MP_ApplyNpcState("q_npc", 1.2, 0, 0, 0, 100, 0, 1)
    check("q: not paused twice", cmdCount("wh_ai_PauseNPC q_npc") == 1)
    NOW = 800 + (KCD2MP.npcSync.releaseS or 3) + 1
    KCD2MP.npcPuppetRunning = true; KCD2MP_NpcPuppetTick("ext")
    check("q: silence release executes wh_ai_ResumeNPC", cmdCount("wh_ai_ResumeNPC q_npc") == 1)
    check("q: MP-AUTHORITY event=resume via=silence", logCount("event=resume owner=? via=silence") == 1)
    -- lever off resumes everything still paused
    CMDS = {}
    local e2 = mkEntity("q2_npc", 0, 0, 0); ENTS["q2_npc"] = e2
    KCD2MP_ApplyNpcState("q2_npc", 1, 0, 0, 0, 100, 0, 1)
    check("q: second puppet paused", cmdCount("wh_ai_PauseNPC q2_npc") == 1)
    KCD2MP_Wo102Set("authority_pause", false)
    check("q: lever off resumes it", cmdCount("wh_ai_ResumeNPC q2_npc") == 1 and next(KCD2MP._npcPaused) == nil)
    -- host authority off also resumes
    KCD2MP.wo102.authorityPause = true; CMDS = {}
    local e3 = mkEntity("q3_npc", 0, 0, 0); ENTS["q3_npc"] = e3
    KCD2MP_ApplyNpcState("q3_npc", 1, 0, 0, 0, 100, 0, 1)
    KCD2MP_Wo102Set("authority_host", false)
    check("q: host authority off resumes too", cmdCount("wh_ai_ResumeNPC q3_npc") == 1)
    check("q: summary carries pause counters", (function() clearLog(); KCD2MP_LogSummary("t"); local l = lastLog("MP-SUMMARY-MOD") or ""; return l:find("auth_pauses=3 auth_resumes=3", 1, true) ~= nil end)(), lastLog("MP-SUMMARY-MOD"))
    check("q: no Lua errors", #ERRS == 0, ERRS[1])
end

do -- (r) the 0.23.2 path with the toggle off
    resetAll4(); clearLog()
    local e = mkEntity("r_npc", 10, 0, 0); ENTS["r_npc"] = e
    NOW = 900
    dragPuppet("r_npc", e, 97, 6)
    check("r: claim model releases on divergence (MP-NPCDIVERGE)", logCount("MP-NPCDIVERGE npc=r_npc") == 1)
    check("r: puppet released", KCD2MP.npcPuppets["r_npc"] == nil)
    check("r: no violation ever logged with the toggle off", logCount("MP-AUTHORITY-VIOLATION") == 0 and (KCD2MP._authStats.violation or 0) == 0)
    check("r: no pause command with the toggle off", cmdCount("wh_ai_PauseNPC") == 0)
end

do -- (s) pause lever alone is inert
    resetAll4(); clearLog()
    KCD2MP.wo102.authorityPause = true
    local e = mkEntity("s_npc", 0, 0, 0); ENTS["s_npc"] = e
    KCD2MP_ApplyNpcState("s_npc", 1, 0, 0, 0, 100, 0, 1)
    check("s: pause lever without host authority issues nothing", cmdCount("wh_ai_PauseNPC") == 0 and next(KCD2MP._npcPaused) == nil)
end

-- ---------------------------------------------------------------- Phase 3
--   (t) the live probe's Lua half: mp_probe_npc_pause picks the nearest NPC,
--       issues wh_ai_PauseNPC, moves it, judges HELD when the body stays,
--       animates, resumes with wh_ai_ResumeNPC and puts it back. (Only the
--       sequencing is provable here; what the engine does is the live probe.)
do
    resetAll4(); clearLog(); TIMERS = {}
    local e = mkEntity("t_npc", 3, 0, 0); ENTS["t_npc"] = e; SPHERE = { e }
    e.GetCurAnimation = function() return "relaxed_idle_both" end
    NOW = 1000
    KCD2MP_ProbeNpcPause()
    check("t: step 0/1 issue wh_ai_PauseNPC", cmdCount("wh_ai_PauseNPC t_npc") == 1 and logCount("MP-PAUSEPROBE step=1 npc=t_npc execute_ok=true") == 1)
    -- fire the timer chain in order (each step arms the next)
    local guard = 0
    while #TIMERS > 0 and guard < 10 do
        local tm = table.remove(TIMERS, 1); NOW = NOW + tm.ms / 1000; tm.f(); guard = guard + 1
    end
    check("t: step 3 judges HELD on a body that stayed put", logCount("verdict_pos=HELD") == 1, lastLog("MP-PAUSEPROBE step=3"))
    check("t: step 4 animates and resumes", logCount("MP-PAUSEPROBE step=4") == 1 and cmdCount("wh_ai_ResumeNPC t_npc") == 1)
    check("t: step 5 closes the probe", logCount("MP-PAUSEPROBE step=5") == 1)
    check("t: body put back", math.abs(e.px - 3) < 0.01)
    check("t: no Lua errors", #ERRS == 0, ERRS[1])
end

-- ---------------------------------------------------------------- Phase 5
--   (u) the request channel's Lua half: on a NON-authority under host
--       authority the puppet tick emits `npc_target <name>` for the nearest
--       live puppet within 4 m, `-` when none, once per change; nothing is
--       emitted with host authority off (byte-identical event channel)
do
    resetAll4(); clearLog()
    KCD2MP.wo102.authorityHost = true; KCD2MP.hitSensorOn = false
    local e = mkEntity("u_npc", 1.5, 0, 0); ENTS["u_npc"] = e
    NOW = 1100
    KCD2MP_ApplyNpcState("u_npc", 1.5, 0, 0, 0, 100, 0, 1)
    KCD2MP.npcPuppetRunning = true
    KCD2MP_NpcPuppetTick("ext")
    check("u: nearest puppet within 4 m is announced", logCount("npc_target u_npc") == 1, lastLog("npc_target"))
    KCD2MP_NpcPuppetTick("ext")
    check("u: announced once, not per tick", logCount("npc_target u_npc") == 1)
    -- the stream moves it out of reach
    for i = 1, 30 do NOW = NOW + 0.05; KCD2MP_ApplyNpcState("u_npc", 12, 0, 0, 0, 100, 0, 1); KCD2MP_NpcPuppetTick("ext") end
    check("u: out of reach -> npc_target -", logCount("npc_target -") >= 1, lastLog("npc_target"))
    -- a dead puppet is never a target
    clearLog()
    NOW = NOW + 0.05; KCD2MP_ApplyNpcState("u_npc", 1, 0, 0, 0, 0, 1, 1); e.px = 1
    KCD2MP_NpcPuppetTick("ext")
    check("u: a dead puppet is not a target", logCount("npc_target u_npc") == 0)
    -- host authority off: the channel goes quiet, with one final "-" if a target was held
    KCD2MP.wo102.authorityHost = false; clearLog()
    KCD2MP_NpcPuppetTick("ext"); KCD2MP_NpcPuppetTick("ext")
    check("u: host authority off emits no npc_target", logCount("npc_target") <= 1)
    check("u: no Lua errors", #ERRS == 0, ERRS[1])
end

-- ---------------------------------------------------------------- Phase 6
--   (v) the owner's burst emits one npc_state per NPC near the player OR a
--       peer ghost, flagged 64 (+dead/ko/drawn), capped; a non-authority
--       burst emits nothing and logs a skip
--   (w) a RESYNC packet for a name with no puppet snaps the copy once when it
--       is > 1 m off, creates no puppet, logs MP-NPCRESYNC dir=apply; a copy
--       0.5 m off is not moved; a copy within 2 m of the player or a local
--       corpse is skipped and named; an existing puppet treats it as an
--       ordinary packet (target updated, no apply line)
--   (x) mp_resync_npcs is registered argless and emits npc_resync_request
do -- (v)
    resetAll4(); clearLog()
    KCD2MP.hitSensorOn = true; KCD2MP.wo102.authorityHost = true
    local ghostEnt = { GetWorldPos = function() return { x = 100, y = 0, z = 0 } end }
    KCD2MP.ghosts = { ["1"] = { entity = ghostEnt, istate = {} } }
    local a = mkEntity("v_a", 5, 0, 0); a.dead = true; a.hp = 0
    local b = mkEntity("v_b", 95, 0, 0)
    local ghostBody = mkEntity("kcd2mp_1", 1, 0, 0)          -- excluded name
    SPHERE = { a, b, ghostBody }
    local n = KCD2MP_NpcResyncBurst("manual")
    check("v: burst emits one sample per eligible NPC", n == 2, n)
    check("v: excluded names are not emitted", logCount("npc_state kcd2mp_1") == 0)
    local la = lastLog("npc_state v_a") or ""
    check("v: dead NPC carries dead+resync (65)", la:match("(%d+)%s*$") == "65", la)
    local lb = lastLog("npc_state v_b") or ""
    check("v: live NPC carries resync (64)", lb:match("(%d+)%s*$") == "64", lb)
    check("v: burst line", logCount("MP-NPCRESYNC dir=burst reason=manual n=2 anchors=2") == 1, lastLog("MP-NPCRESYNC"))
    clearLog(); KCD2MP.hitSensorOn = false
    check("v: non-authority burst emits nothing", KCD2MP_NpcResyncBurst("manual") == 0 and logCount("npc_state") == 0 and logCount("dir=skip reason=manual cause=not-authority") == 1)
    check("v: no Lua errors", #ERRS == 0, ERRS[1])
end

do -- (w)
    resetAll4(); clearLog()
    KCD2MP.wo102.authorityHost = true; KCD2MP.hitSensorOn = false
    local far = mkEntity("w_far", 10, 10, 0); ENTS["w_far"] = far
    KCD2MP_ApplyNpcState("w_far", 20, 10, 0, 1.0, 100, 64, 0)
    check("w: far copy snapped once", #far.writes == 1 and far.px == 20 and far.rz == 1.0)
    check("w: no puppet created", KCD2MP.npcPuppets["w_far"] == nil)
    check("w: apply line", logCount("MP-NPCRESYNC dir=apply npc=w_far dist_m=10.00 moved=1 dead=0 owner=0") == 1, lastLog("MP-NPCRESYNC"))
    local close = mkEntity("w_close", 10, 0, 0); ENTS["w_close"] = close
    KCD2MP_ApplyNpcState("w_close", 10.5, 0, 0, 0, 100, 64, 0)
    check("w: 0.5 m off is not moved", #close.writes == 0 and logCount("npc=w_close dist_m=0.50 moved=0") == 1)
    local near = mkEntity("w_near", 1, 0, 0); ENTS["w_near"] = near      -- 1 m from the player at (0,0)
    KCD2MP_ApplyNpcState("w_near", 30, 0, 0, 0, 100, 64, 0)
    check("w: a body next to the player is skipped", #near.writes == 0 and logCount("npc=w_near dist_m=29.00 moved=0 dead=0 owner=0 skipped=near-player") == 1, lastLog("npc=w_near"))
    local corpse = mkEntity("w_corpse", 10, 0, 0); corpse.dead = true; ENTS["w_corpse"] = corpse
    KCD2MP_ApplyNpcState("w_corpse", 30, 0, 0, 0, 100, 64, 0)
    check("w: a local corpse is skipped", #corpse.writes == 0 and logCount("npc=w_corpse dist_m=20.00 moved=0 dead=0 owner=0 skipped=local-corpse") == 1)
    -- existing puppet: ordinary handling
    local pup = mkEntity("w_pup", 0, 5, 0); ENTS["w_pup"] = pup
    KCD2MP_ApplyNpcState("w_pup", 0, 5, 0, 0, 100, 0, 0)
    clearLog()
    KCD2MP_ApplyNpcState("w_pup", 0, 7, 0, 0, 100, 64, 0)
    check("w: an existing puppet takes it as a stream packet", KCD2MP.npcPuppets["w_pup"] ~= nil and KCD2MP.npcPuppets["w_pup"].ty == 7 and logCount("dir=apply npc=w_pup") == 0)
    check("w: summary counts", (function() clearLog(); KCD2MP_LogSummary("t"); return (lastLog("MP-SUMMARY-MOD") or ""):find("resync_applied=4 resync_moved=1 resync_skipped=2", 1, true) ~= nil end)(), lastLog("MP-SUMMARY-MOD"))
    check("w: no Lua errors", #ERRS == 0, ERRS[1])
end

do -- (x)
    clearLog()
    local c = CCMDS["mp_resync_npcs"]
    check("x: mp_resync_npcs registered argless", c ~= nil and not string.find(c.body, "%LINE", 1, true))
    KCD2MP_NpcResyncRequest()
    check("x: emits npc_resync_request", logCount("npc_resync_request manual") == 1)
end

-- ---------------------------------------------------------------- Phase 7
--   (y) the authority model's invariants over a simulated 200-tick session
--       on a NON-authority under host authority with two owned puppets fed
--       by owner 0 while its "local brain" keeps dragging both: ownership
--       never changes (zero owner-change), every acquire is via=stream from
--       owner 0, the machine emits nothing that claims (no npc_claim, no
--       npc_drag, no npc_state), no puppet is ever released to the local
--       world (no NPCDIVERGE, no NPCYIELD), and every write goes to the
--       stream's position; then mp_authority_host_off returns the claim
--       model exactly (the next drag releases with MP-NPCDIVERGE)
do
    resetAll4(); clearLog()
    KCD2MP.wo102.authorityHost = true; KCD2MP.hitSensorOn = false
    KCD2MP.npcSync.enabled = true; KCD2MP.npcSyncRunning = true
    KCD2MP.ghosts = { ["0"] = { entity = {}, istate = {} } }
    local a = mkEntity("y_a", 10, 0, 0); ENTS["y_a"] = a
    local b = mkEntity("y_b", 20, 0, 0); ENTS["y_b"] = b
    SPHERE = { a, b }
    NOW = 2000
    for i = 1, 200 do
        NOW = NOW + 0.05
        KCD2MP_ApplyNpcState("y_a", 10, 0, 0, 0, 100, 0, 0)
        KCD2MP_ApplyNpcState("y_b", 20, 0, 0, 0, 100, 0, 0)
        KCD2MP.npcPuppetRunning = true
        KCD2MP_NpcPuppetTick("ext")
        KCD2MP._npcScanAt = 0
        KCD2MP_NpcSyncTick()
        a.px = a.px + 0.4           -- sustained sub-8 m contention
        if i % 20 == 0 then b.px = b.px + 50 end   -- and the occasional 50 m yank
    end
    check("y: zero owner-change", logCount("event=owner-change") == 0)
    check("y: every acquire is via=stream from owner 0", logCount("event=acquire owner=0 via=stream") == 2 and logCount("event=acquire owner=self") == 0)
    check("y: the non-owner never emits a claim or state", logCount("npc_claim") == 0 and logCount("npc_drag") == 0 and logCount("npc_state") == 0)
    check("y: no puppet handed back", logCount("MP-NPCDIVERGE") == 0 and logCount("MP-NPCYIELD") == 0 and KCD2MP.npcPuppets["y_a"] ~= nil and KCD2MP.npcPuppets["y_b"] ~= nil)
    check("y: contention and yanks are logged as violations", logCount("MP-AUTHORITY-VIOLATION npc=y_a kind=contention") >= 1 and logCount("MP-AUTHORITY-VIOLATION npc=y_b kind=diverge") >= 1)
    local lastWrite = a.writes[#a.writes]
    check("y: writes go to the stream's position", lastWrite ~= nil and math.abs(lastWrite.x - 10) < 0.6, lastWrite and lastWrite.x)
    check("y: summary says model=host owner_changes=0", (function() clearLog(); KCD2MP_LogSummary("t"); local l = lastLog("MP-SUMMARY-MOD") or ""; return l:find("auth_owner_changes=0 auth_model=host", 1, true) ~= nil end)(), lastLog("MP-SUMMARY-MOD"))
    -- and back: the claim model returns exactly
    clearLog()
    KCD2MP_Wo102Set("authority_host", false)
    for i = 1, 8 do
        NOW = NOW + 0.05
        KCD2MP_ApplyNpcState("y_b", 20, 0, 0, 0, 100, 0, 0)
        KCD2MP_NpcPuppetTick("ext")
        b.px = b.px + 97
    end
    check("y: toggle off -> the WO-90 release fires again", logCount("MP-NPCDIVERGE npc=y_b") == 1 and KCD2MP.npcPuppets["y_b"] == nil)
    check("y: and no violation is logged under the claim model", logCount("MP-AUTHORITY-VIOLATION") == 0)
    KCD2MP.npcSyncRunning = false
    check("y: no Lua errors", #ERRS == 0, ERRS[1])
end

-- ------------------------------------------------------------ WO-102.5 Phase 1
--   (aa) resume guarantees beyond the three WO-102 paths: a paused name with
--        no tracked puppet is caught by the periodic reconciliation sweep
--        (rate-limited, runs from KCD2MP_NpcSyncTick regardless of npcSync
--        enabled or authority role); KCD2MP_Stop (`mp_stop`) and
--        KCD2MP_Wo102ResumeAll (the agent's own disconnect path) both
--        resume everything still paused
do
    resetAll4(); clearLog()
    KCD2MP.npcSyncRunning = true; KCD2MP.npcSync.enabled = true
    KCD2MP._npcReconcileAt = nil

    -- A pause with no puppet -- as if the puppet had been removed by some
    -- path that does not itself resume (the case this sweep exists for).
    KCD2MP._npcPaused["aa_orphan"] = 100
    KCD2MP.npcPuppets["aa_orphan"] = nil
    NOW = 1000; KCD2MP._npcScanAt = 0
    KCD2MP_NpcSyncTick()
    check("aa: the sweep resumes an orphaned pause", cmdCount("wh_ai_ResumeNPC aa_orphan") == 1
        and KCD2MP._npcPaused["aa_orphan"] == nil)
    check("aa: logs the reconcile line", logCount("WO102-AUTHORITY reconcile: resumed aa_orphan") == 1)
    check("aa: counted as a resume", logCount("MP-AUTHORITY npc=aa_orphan event=resume owner=? via=reconcile") == 1)

    -- Rate-limited: a second orphan appearing inside the same 5s window is
    -- NOT caught until the interval elapses again.
    CMDS = {}
    KCD2MP._npcPaused["aa_orphan2"] = NOW
    NOW = NOW + 1
    KCD2MP._npcScanAt = 0
    KCD2MP_NpcSyncTick()
    check("aa: rate-limited -- not swept inside the same window", cmdCount("wh_ai_ResumeNPC aa_orphan2") == 0)
    NOW = NOW + 5.0   -- >= kdcmp.lua's NPC_RECONCILE_INTERVAL_S
    KCD2MP._npcScanAt = 0
    KCD2MP_NpcSyncTick()
    check("aa: swept once the interval elapses", cmdCount("wh_ai_ResumeNPC aa_orphan2") == 1)

    -- mp_stop resumes everything still paused, tracked or not.
    CMDS = {}
    local e = mkEntity("aa_tracked", 0, 0, 0); ENTS["aa_tracked"] = e
    KCD2MP.npcPuppets["aa_tracked"] = { owner = 1 }
    KCD2MP._npcPaused["aa_tracked"] = NOW
    KCD2MP.running = true
    KCD2MP_Stop()
    check("aa: mp_stop resumes the tracked pause too", cmdCount("wh_ai_ResumeNPC aa_tracked") == 1
        and next(KCD2MP._npcPaused) == nil)

    -- KCD2MP_Wo102ResumeAll: the agent's own disconnect path.
    CMDS = {}
    KCD2MP._npcPaused["aa_agent"] = NOW
    KCD2MP_Wo102ResumeAll("agent-disconnect")
    check("aa: agent-disconnect wrapper resumes it", cmdCount("wh_ai_ResumeNPC aa_agent") == 1
        and next(KCD2MP._npcPaused) == nil)
    check("aa: logged with via=agent-disconnect", logCount("event=resume owner=? via=agent-disconnect") == 1)

    -- MP-SUMMARY-MOD carries the currently-paused count.
    KCD2MP._npcPaused["aa_now"] = NOW
    clearLog(); KCD2MP_LogSummary("t")
    check("aa: summary carries auth_paused_now", logCount("auth_paused_now=1") == 1, lastLog("MP-SUMMARY-MOD"))
    KCD2MP._npcPaused["aa_now"] = nil

    KCD2MP.npcSyncRunning = false
    check("aa: no Lua errors", #ERRS == 0, ERRS[1])
end

-- ------------------------------------------------------------ WO-102.5 Phase 2
--   (z) the native scan: KCD2MP_ApplyNativeScan gates non-conforming names;
--       mp_npc_rescan sources its candidate set from the push (not
--       System.GetEntitiesInSphere) only when npcScanNative is on AND the
--       push is fresh; a stale or never-received push falls back to the Lua
--       enumerate exactly as with the toggle off; mp_npc_scan_compare logs a
--       diff line
do
    resetAll4(); clearLog()
    KCD2MP.hitSensorOn = true
    KCD2MP.npcSync.enabled = true; KCD2MP.npcSyncRunning = true
    KCD2MP._nativeScan = { at = nil, names = {} }

    NOW = 699
    KCD2MP_ApplyNativeScan("z_a,z_b,bad name,z_c")
    check("z: gates a non-conforming name", #KCD2MP._nativeScan.names == 3
        and KCD2MP._nativeScan.names[1] == "z_a" and KCD2MP._nativeScan.names[2] == "z_b" and KCD2MP._nativeScan.names[3] == "z_c",
        table.concat(KCD2MP._nativeScan.names, ","))
    check("z: stamps a timestamp", KCD2MP._nativeScan.at == NOW)

    local za = mkEntity("z_a", 5, 0, 0); ENTS["z_a"] = za
    local zb = mkEntity("z_b", 6, 0, 0); ENTS["z_b"] = zb
    -- z_c is named but never spawned -- GetEntityByName returning nil for it
    -- must be tolerated, not error.
    local sphereOnly = mkEntity("z_sphere_only", 7, 0, 0); ENTS["z_sphere_only"] = sphereOnly
    SPHERE = { sphereOnly }

    -- toggle off: the push exists but is ignored, the Lua enumerate runs.
    NOW = 700; KCD2MP._npcScanAt = 0
    KCD2MP_NpcSyncTick()
    check("z: toggle off uses the Lua enumerate", KCD2MP.npcTracked["z_sphere_only"] ~= nil
        and KCD2MP.npcTracked["z_a"] == nil, next(KCD2MP.npcTracked))
    check("z: toggle off logs no MP-NPCSCAN consume line", logCount("MP-NPCSCAN dir=consume") == 0)

    -- toggle on, push fresh: the native names drive tracking, not SPHERE.
    KCD2MP.npcTracked = {}; clearLog()
    KCD2MP_Wo102Set("npc_scan_native", true, "agent")
    KCD2MP_ApplyNativeScan("z_a,z_b,z_c")
    NOW = 701; KCD2MP._npcScanAt = 0
    KCD2MP_NpcSyncTick()
    check("z: native path tracks the pushed names it can resolve",
        KCD2MP.npcTracked["z_a"] ~= nil and KCD2MP.npcTracked["z_b"] ~= nil and KCD2MP.npcTracked["z_sphere_only"] == nil,
        next(KCD2MP.npcTracked))
    check("z: logs verdict=native with the resolved count",
        logCount("MP-NPCSCAN dir=consume verdict=native pushed=3 resolved=2") == 1, lastLog("MP-NPCSCAN"))

    -- a stale push falls back to the Lua enumerate again (staleAfterS = 6 at scanMs=2000).
    KCD2MP.npcTracked = {}; clearLog()
    NOW = 701 + 7; KCD2MP._npcScanAt = 0
    KCD2MP_NpcSyncTick()
    check("z: a stale push falls back", KCD2MP.npcTracked["z_sphere_only"] ~= nil and KCD2MP.npcTracked["z_a"] == nil)
    check("z: logs the fallback reason", logCount("MP-NPCSCAN dir=consume verdict=fallback reason=stale") == 1)

    -- never received: same fallback, different reason.
    KCD2MP._nativeScan = { at = nil, names = {} }
    KCD2MP.npcTracked = {}; clearLog()
    NOW = NOW + 1; KCD2MP._npcScanAt = 0
    KCD2MP_NpcSyncTick()
    check("z: never-received also falls back", logCount("MP-NPCSCAN dir=consume verdict=fallback reason=never-received") == 1)

    -- compare: a fresh native push against the current Lua enumerate (SPHERE unchanged: {sphereOnly}).
    KCD2MP_ApplyNativeScan("z_a,z_only_native")
    clearLog()
    KCD2MP_NpcScanCompare()
    check("z: compare logs lua/native counts",
        logCount("MP-NPCSCAN dir=compare anchors=1 lua_n=1 native_n=2 both=0") == 1, lastLog("MP-NPCSCAN dir=compare anchors"))
    check("z: compare names the lua-only miss", logCount("only_lua=z_sphere_only") == 1)
    check("z: compare names the native-only extras", logCount("dir=compare only_native=") == 1)

    -- console commands registered argless (WO-94: the console drops arguments).
    for _, name in ipairs({ "mp_npc_scan_native_on", "mp_npc_scan_native_off", "mp_npc_scan_compare" }) do
        local c = CCMDS[name]
        check("z: " .. name .. " registered argless", c ~= nil and not string.find(c.body, "%LINE", 1, true))
    end

    KCD2MP.npcSyncRunning = false; KCD2MP.hitSensorOn = false; KCD2MP.wo102.npcScanNative = false
    check("z: no Lua errors", #ERRS == 0, ERRS[1])
end

-- ------------------------------------------------------------ WO-102.5 Phase 3
--   (bb) uncapped co-located ownership: every NPC in radius is tracked
--        regardless of maxTracked*anchors; the authority radius is
--        runtime-adjustable and validated, and announced to the agent on
--        the event channel; culling stops the stream for a tracked NPC
--        nobody is near, and re-entry (moving closer) streams it fresh --
--        at its current position, never a stale one -- rather than waiting
--        for the heartbeat
do
    resetAll4(); clearLog()
    KCD2MP.hitSensorOn = true
    KCD2MP.wo102.authorityHost = true
    KCD2MP.npcSync.enabled = true; KCD2MP.npcSyncRunning = true
    KCD2MP.wo1025.authorityRadius = 45.0
    KCD2MP.wo1025.cullRadius = 30.0
    KCD2MP.wo1025.npcCull = true

    -- more entities than maxTracked (5), all within the default radius
    local ents8 = {}
    for i = 1, 8 do
        local e = mkEntity("bb_npc" .. i, 5 + i, 0, 0)   -- 6..13 m from the player
        ENTS["bb_npc" .. i] = e
        ents8[#ents8 + 1] = e
    end
    SPHERE = ents8
    NOW = 2100; KCD2MP._npcScanAt = 0
    KCD2MP_NpcSyncTick()
    local trackedN = 0
    for _ in pairs(KCD2MP.npcTracked) do trackedN = trackedN + 1 end
    check("bb: every NPC in radius is tracked, uncapped", trackedN == 8, trackedN)

    -- radius validation.
    check("bb: rejects a non-numeric radius", KCD2MP_SetAuthorityRadius("banana") == false
        and KCD2MP.wo1025.authorityRadius == 45.0)
    check("bb: rejects an out-of-range radius", KCD2MP_SetAuthorityRadius("1000") == false
        and KCD2MP.wo1025.authorityRadius == 45.0)
    clearLog()
    check("bb: accepts a valid radius", KCD2MP_SetAuthorityRadius("90") == true
        and KCD2MP.wo1025.authorityRadius == 90.0)
    check("bb: logs the change", logCount("WO1025-RADIUS set=90.0 was=45.0") == 1)
    check("bb: announces it to the agent", logCount("authority_radius 90.0") == 1)

    -- an NPC beyond the OLD radius but within the new one is picked up on the next rescan.
    local far = mkEntity("bb_far", 80, 0, 0); ENTS["bb_far"] = far
    SPHERE = { far }
    NOW = 2101; KCD2MP._npcScanAt = 0
    KCD2MP_NpcSyncTick()
    check("bb: the wider radius reaches it", KCD2MP.npcTracked["bb_far"] ~= nil)

    -- culling: bb_far (80 m) is tracked but beyond cullRadius (30 m) -- no stream.
    CMDS = {}; clearLog()
    NOW = 2102
    KCD2MP_NpcSyncTick()
    check("bb: a far tracked NPC is not streamed", logCount("npc_state bb_far") == 0)

    -- move it into cull range: streamed fresh on the very next tick, at its
    -- CURRENT position (read live every tick, cull or not) -- not a stale one.
    far.px = 20   -- inside cullRadius of the player at (0,0)
    NOW = 2103
    KCD2MP_NpcSyncTick()
    check("bb: re-entry streams it immediately", logCount("npc_state bb_far 20.000") == 1, lastLog("npc_state bb_far"))
    check("bb: re-entry is logged", logCount("WO1025-CULL re-entry bb_far") == 1)

    -- cull off: it streams even while far.
    KCD2MP.wo1025.npcCull = false
    far.px = 80
    NOW = 2200; KCD2MP._npcScanAt = 0   -- force a rescan so bb_far is re-evaluated fresh
    KCD2MP_NpcSyncTick()
    check("bb: mp_npc_cull_off streams a far NPC too", logCount("npc_state bb_far 80.000") == 1)

    -- claim model unaffected: off host authority, the old cap and radius apply.
    KCD2MP.wo102.authorityHost = false; KCD2MP.npcTracked = {}; clearLog()
    SPHERE = ents8
    NOW = 2201; KCD2MP._npcScanAt = 0
    KCD2MP_NpcSyncTick()
    local claimTracked = 0
    for _ in pairs(KCD2MP.npcTracked) do claimTracked = claimTracked + 1 end
    check("bb: the claim model keeps its old cap", claimTracked == KCD2MP.npcSync.maxTracked, claimTracked)

    for _, cname in ipairs({ "mp_npc_cull_on", "mp_npc_cull_off" }) do
        local c = CCMDS[cname]
        check("bb: " .. cname .. " registered argless", c ~= nil and not string.find(c.body, "%LINE", 1, true))
    end

    KCD2MP.npcSyncRunning = false; KCD2MP.hitSensorOn = false
    KCD2MP.wo1025.authorityRadius = 45.0; KCD2MP.wo1025.npcCull = true
    check("bb: no Lua errors", #ERRS == 0, ERRS[1])
end

-- ------------------------------------------------------------ WO-102.5 Phase 4
--   (cc) co-location: hysteresis (enter/exit bands + dwell -- a momentary
--        crossing does not flip it), the transition gates peer-anchor
--        scanning, mid-interaction (engaged) freeze with a deferred sweep
--        once it clears, and departure handoff resets the state fresh
do
    resetAll4(); clearLog()
    KCD2MP.hitSensorOn = true
    KCD2MP.wo102.authorityHost = true
    KCD2MP.npcSync.enabled = true; KCD2MP.npcSyncRunning = true

    local ghostPos = { x = 200, y = 0, z = 0 }
    local ghostEnt = { GetWorldPos = function() return ghostPos end }
    KCD2MP.ghosts = { ["1"] = { entity = ghostEnt, istate = {} } }
    SPHERE = {}
    NOW = 3000; KCD2MP._npcScanAt = 0
    KCD2MP_NpcSyncTick()
    check("cc: starts apart", KCD2MP.wo1025.together == false)

    -- a MOMENTARY close crossing (< dwellS) must not flip it.
    ghostPos.x = 50
    NOW = 3001; KCD2MP._npcScanAt = 0
    KCD2MP_NpcSyncTick()
    check("cc: momentary closeness does not flip it yet", KCD2MP.wo1025.together == false)
    ghostPos.x = 200
    NOW = 3002; KCD2MP._npcScanAt = 0
    KCD2MP_NpcSyncTick()
    check("cc: backing off resets the dwell clock", KCD2MP._togetherWantSince == nil)

    -- sustained closeness for >= dwellS commits to together.
    ghostPos.x = 50
    NOW = 3010; KCD2MP._npcScanAt = 0
    KCD2MP_NpcSyncTick()
    check("cc: still apart -- dwell just started", KCD2MP.wo1025.together == false)
    NOW = 3010 + KCD2MP.wo1025.togetherDwellS + 0.5
    KCD2MP._npcScanAt = 0; clearLog()
    KCD2MP_NpcSyncTick()
    check("cc: sustained closeness commits to together", KCD2MP.wo1025.together == true)
    check("cc: enter is logged", logCount("WO1025-COLOCATE event=enter") == 1, lastLog("WO1025-COLOCATE"))

    -- together: an NPC near the (now close) peer is discoverable.
    local nearGhost = mkEntity("cc_near_ghost", 55, 0, 0); ENTS["cc_near_ghost"] = nearGhost
    SPHERE = { nearGhost }
    NOW = NOW + 0.1; KCD2MP._npcScanAt = 0
    KCD2MP_NpcSyncTick()
    check("cc: NPC near the close peer is tracked", KCD2MP.npcTracked["cc_near_ghost"] ~= nil)

    -- sustained distance commits to apart; the un-engaged NPC is released.
    ghostPos.x = 300
    local farT = NOW + 1
    NOW = farT; KCD2MP._npcScanAt = 0
    KCD2MP_NpcSyncTick()
    NOW = farT + KCD2MP.wo1025.togetherDwellS + 0.5
    KCD2MP._npcScanAt = 0; clearLog()
    KCD2MP_NpcSyncTick()
    check("cc: sustained distance commits to apart", KCD2MP.wo1025.together == false)
    check("cc: exit released the un-engaged NPC", KCD2MP.npcTracked["cc_near_ghost"] == nil)
    check("cc: exit is logged with a release count",
        logCount("WO1025-COLOCATE event=exit") == 1 and logCount("released=1") >= 1, lastLog("WO1025-COLOCATE"))

    -- back together, then mid-interaction freeze: an engaged NPC survives
    -- the "apart" transition, then is swept once it stops being engaged.
    ghostPos.x = 50
    NOW = NOW + 1; KCD2MP._npcScanAt = 0
    KCD2MP_NpcSyncTick()
    NOW = NOW + KCD2MP.wo1025.togetherDwellS + 0.5
    KCD2MP._npcScanAt = 0
    KCD2MP_NpcSyncTick()
    check("cc: together again for the freeze test", KCD2MP.wo1025.together == true)

    local fighter = mkEntity("cc_fighter", 0.5, 0, 0)   -- right next to the player: engaged range
    fighter.human.IsWeaponDrawn = function() return true end
    ENTS["cc_fighter"] = fighter
    SPHERE = { fighter }
    NOW = NOW + 0.1; KCD2MP._npcScanAt = 0
    KCD2MP_NpcSyncTick()
    KCD2MP_NpcSyncTick()
    check("cc: the fighter is tracked and engaged", KCD2MP.npcTracked["cc_fighter"] ~= nil)

    ghostPos.x = 300
    local farT2 = NOW + 1
    NOW = farT2; KCD2MP._npcScanAt = 0
    KCD2MP_NpcSyncTick()
    NOW = farT2 + KCD2MP.wo1025.togetherDwellS + 0.5
    KCD2MP._npcScanAt = 0; clearLog()
    KCD2MP_NpcSyncTick()
    check("cc: apart again", KCD2MP.wo1025.together == false)
    check("cc: the engaged fighter is frozen, not released", KCD2MP.npcTracked["cc_fighter"] ~= nil
        and KCD2MP._colocatePendingRelease["cc_fighter"] == true)
    check("cc: exit logs it as frozen",
        logCount("WO1025-COLOCATE event=exit") == 1 and logCount("frozen=1") >= 1, lastLog("WO1025-COLOCATE"))

    -- combat ends: the deferred sweep releases it on the very next tick.
    fighter.human.IsWeaponDrawn = function() return false end
    NOW = NOW + 0.1; clearLog()
    KCD2MP_NpcSyncTick()
    check("cc: deferred sweep releases it once combat ends", KCD2MP.npcTracked["cc_fighter"] == nil
        and KCD2MP._colocatePendingRelease["cc_fighter"] == nil)
    check("cc: the deferred release is logged", logCount("WO1025-COLOCATE deferred release now clear: cc_fighter") == 1)

    -- departure handoff: becoming the NEW authority resets the state fresh.
    KCD2MP.wo1025.together = true
    KCD2MP_SetHitSensor(false)
    KCD2MP_SetHitSensor(true)
    check("cc: new authority starts apart, fresh", KCD2MP.wo1025.together == false)

    KCD2MP.npcSyncRunning = false; KCD2MP.hitSensorOn = false
    check("cc: no Lua errors", #ERRS == 0, ERRS[1])
end

-- Summary.
local pass, fail = 0, 0
for _, r in ipairs(RESULTS) do if r:sub(1, 4) == "PASS" then pass = pass + 1 else fail = fail + 1 end end
OUT = table.concat(RESULTS, "\n") .. string.format("\n%d passed, %d failed", pass, fail)
