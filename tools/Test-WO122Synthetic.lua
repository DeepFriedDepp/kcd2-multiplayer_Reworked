-- WO-122 synthetic test, against the real kdcmp.lua under MoonSharp.
--
-- The Lua half of the shared-world foundations:
--   (a) shipped defaults: shared_world ON (since 0.30.0), owner_death ON, autosave 5 min;
--       WO122-BUILD once; the agent mirror event; the four commands
--   (b) owner death: a copy ALIVE here while the owner streams it dead asks
--       the agent (npc_owner_dead), throttled; once it reads dead the corpse
--       is put where the stream has it; the flip is not announced back
--   (c) the same again right after a "load" brings the copy back alive
--   (d) one-way: a stream saying alive never revives a local corpse
--   (e) mp_owner_death off / mp_npc_deathsync off: no request
--   (f) the one-shot resync path (no puppet) asks too
--   (g) the joiner's lock: never with mp_shared_world off; add + read-back;
--       a "load" wipe is noticed and re-asserted; a failed read-back is loud;
--       release on off
--   (h) the host's world save calls EnqueueAutoSave (SaveGameViaResting)
--       once per request and measures the frame gap
--   (i) mp_world_save needs mp_shared_world on
--   (j) mp_autosave_minutes range; (k) presets; (l) the receiver's line
--
-- Driven by Test-WO122Synthetic.ps1 through the WO-77 MoonSharp driver.
-- What this proves: the Lua half behaves as documented. It does NOT prove the
-- engine refuses a save under the lock, or that the owner's death lands on a
-- real NPC -- see docs/WO-122-findings.md for the live runs.
--
-- Part 1: engine stubs + a fake clock.

NOW = 0
os.clock = function() return NOW end
LOG = {}; TIMERS = {}; ENTS = {}; ERRS = {}; TOASTS = {}; CMDS = {}; CCMDS = {}

local function mkstub()
    return setmetatable({}, { __index = function(_, k) return function(...) return nil end end })
end
System = mkstub()
System.LogAlways = function(s) LOG[#LOG + 1] = tostring(s) end
System.GetCVarValue = function() return "0" end
System.GetEntityByName = function(n) return ENTS[n] end
System.GetEntitiesInSphere = function() return {} end
System.ExecuteCommand = function(s) CMDS[#CMDS + 1] = tostring(s) end
System.AddCCommand = function(name, body, help) CCMDS[name] = { body = tostring(body), help = tostring(help or "") } end
System.RemoveEntity = function(eid) for n, e in pairs(ENTS) do if e.id == eid then ENTS[n] = nil end end end
Script = mkstub()
Script.SetTimer = function(ms, f) TIMERS[#TIMERS + 1] = { ms = ms, f = f, at = NOW } end
AI = mkstub(); Sound = mkstub(); Physics = mkstub(); Terrain = mkstub()
UIAction = mkstub()
UIAction.CallFunction = function(panel, inst, fn, text) TOASTS[#TOASTS + 1] = tostring(text) end

-- The engine's named script locks, as WO-112 observed them: an add of a
-- held name is refused, a load wipes every lock.
LOCKS = {}; LOCKCALLS = 0; SAVEREQ = 0; LOCK_BROKEN = false
Game = mkstub()
Game.AddSaveLock = function(name, desc)
    LOCKCALLS = LOCKCALLS + 1
    if LOCK_BROKEN then return true end
    if LOCKS[name] then return false end
    LOCKS[name] = desc
    return true
end
Game.RemoveSaveLock = function(name) local had = LOCKS[name] ~= nil; LOCKS[name] = nil; return had end
Game.SaveGameViaResting = function() SAVEREQ = SAVEREQ + 1 end

player = nil

local rawpcall = pcall
pcall = function(f, ...)
    local r = { rawpcall(f, ...) }
    if not r[1] then ERRS[#ERRS + 1] = tostring(r[2]) end
    return unpack(r)
end

-- @@KDCMP@@

-- Part 2: scenarios.

local RESULTS = {}
local function check(name, ok, detail)
    RESULTS[#RESULTS + 1] = (ok and "PASS  " or "FAIL  ") .. name .. (detail and ("  [" .. tostring(detail) .. "]") or "")
end
local function countLog(needle, fromLog)
    local n = 0
    for i = (fromLog or 0) + 1, #LOG do if LOG[i]:find(needle, 1, true) then n = n + 1 end end
    return n
end
local function lastLog(needle, fromLog)
    for i = #LOG, (fromLog or 0) + 1, -1 do if LOG[i]:find(needle, 1, true) then return LOG[i] end end
    return nil
end
local function countEvt(name, argPrefix, fromLog)
    local n = 0
    for i = (fromLog or 0) + 1, #LOG do
        local l = LOG[i]
        if l:find("[KCD2-MP-EVT] v1 ", 1, true) and l:find(" " .. name .. " " .. (argPrefix or ""), 1, true) then n = n + 1 end
    end
    return n
end
local function noErrs(label) check(label .. ": no swallowed Lua errors", #ERRS == 0, ERRS[1]) end

local NEXTID = 9000
local function mkEntity(name, x, y, z)
    NEXTID = NEXTID + 1
    local e = { class = "NPC", id = NEXTID, px = x or 0, py = y or 0, pz = z or 0, rz = 0, writes = {}, dead = false, hp = 100 }
    e.GetName = function(self) return name end
    e.GetWorldPos = function(self) return { x = self.px, y = self.py, z = self.pz } end
    e.GetWorldAngles = function(self) return { x = 0, y = 0, z = self.rz } end
    e.SetWorldPos = function(self, p)
        self.px, self.py, self.pz = p.x, p.y, p.z
        self.writes[#self.writes + 1] = { x = p.x, y = p.y, z = p.z, at = NOW }
    end
    e.SetWorldAngles = function(self, a) self.rz = a.z end
    e.StartAnimation = function() end
    e.actor = { IsDead = function() return e.dead end, IsUnconscious = function() return false end, GetHealth = function() return e.hp end }
    e.human = { IsWeaponDrawn = function() return false end, DrawWeapon = function() return true end, HolsterWeapon = function() return true end,
                IsInDialog = function() return false end }
    return e
end

local function resetNpc()
    KCD2MP.npcPuppets = {}
    KCD2MP.npcPuppetRunning = false
    KCD2MP._npcPuppetAliveAt = nil
    KCD2MP._npcPuppetRetired = {}
    KCD2MP.npcDeathSync = true
    KCD2MP._npcDeathSeen = {}
    KCD2MP._npcDeathAnnounced = {}
    KCD2MP._npcDeathRemote = {}
    KCD2MP._npcDeathDiverged = {}
    KCD2MP.w122.ownerDeath = true
    KCD2MP.w122.ownerReq = {}
    ERRS = {}; TOASTS = {}
end

local function tick()
    NOW = NOW + 0.05
    KCD2MP_NpcPuppetTick(nil, KCD2MP.npcPuppetGen)
end
local function run(seconds, fn)
    local t_end = NOW + seconds
    while NOW < t_end do if fn then fn() end; tick() end
end

-- (a) defaults, marker, mirror, commands ---------------------------------------
do
    local w = KCD2MP.w122
    check("a: mp_shared_world ships ON (0.30.0)", w.sharedWorld == true)
    check("a: mp_owner_death ships ON", w.ownerDeath == true)
    check("a: mp_autosave_minutes ships 5", w.autosaveMinutes == 5)
    check("a: WO122-BUILD logged once at load", countLog("WO122-BUILD ") == 1, lastLog("WO122-BUILD"))
    local m = lastLog("WO122-BUILD") or ""
    check("a: the marker names the defaults and the lock", m:find("shared_world=on owner_death=on autosave_minutes=5 lock=kcdmp_host_only", 1, true) ~= nil, m)
    check("a: the mirror event went to the agent at load", countEvt("wo122_cfg", "shared_world=on owner_death=on autosave_min=5") == 1)
    for _, c in ipairs({ { "mp_shared_world", "KCD2MP_SetSharedWorld(%line)" }, { "mp_owner_death", "KCD2MP_SetOwnerDeath(%line)" },
                         { "mp_autosave_minutes", "KCD2MP_SetAutosaveMinutes(%line)" }, { "mp_world_save", "KCD2MP_WorldSaveNow()" } }) do
        check("a: " .. c[1] .. " is registered as " .. c[2], CCMDS[c[1]] and CCMDS[c[1]].body == c[2], CCMDS[c[1]] and CCMDS[c[1]].body)
    end
    check("a: nothing locked at load", next(LOCKS) == nil and LOCKCALLS == 0)
    -- The rest of the suite starts from off and turns it on itself (the
    -- off -> on transitions are what (g)-(i) test).
    KCD2MP_SetSharedWorld("off")
    check("a: off is still one command away", w.sharedWorld == false and next(LOCKS) == nil)
    noErrs("a")
end

-- (b) owner death on a living copy ---------------------------------------------
do
    resetNpc()
    local e = mkEntity("ttkc_man_2", 10, 10, 0); ENTS["ttkc_man_2"] = e
    local mark = #LOG
    -- the owner's stream: dead, lying at (13, 12, 0.2); this world's copy stands alive at (10, 10)
    KCD2MP_ApplyNpcState("ttkc_man_2", 13, 12, 0.2, 0, 0, 1, 0, 1, 1000)
    tick()
    check("b: one npc_owner_dead request at once", countEvt("npc_owner_dead", "ttkc_man_2 13.00 12.00 0.20 0", mark) == 1,
        lastLog("npc_owner_dead", mark))
    check("b: logged as MP-OWNERDEATH request=1", countLog("MP-OWNERDEATH npc=ttkc_man_2 request=1 local=alive stream=dead", mark) == 1)
    run(2.5, function() KCD2MP_ApplyNpcState("ttkc_man_2", 13, 12, 0.2, 0, 0, 1, 0, nil, nil) end)
    check("b: throttled -- still one request 2.5 s later", countEvt("npc_owner_dead", "ttkc_man_2", mark) == 1)
    run(1.0)
    check("b: a second request after 3 s", countEvt("npc_owner_dead", "ttkc_man_2", mark) == 2)
    check("b: the local death flip is not announced back (remote mark)", KCD2MP._npcDeathRemote["ttkc_man_2"] ~= nil)
    -- the agent's ApplyDeath lands: the copy is now dead where it stood
    local writesBefore = #e.writes
    e.dead = true; e.hp = 0; e.px, e.py, e.pz = 10, 10, 0
    tick()
    check("b: the landing is logged", countLog("MP-OWNERDEATH npc=ttkc_man_2 applied=dead requests=2", mark) == 1,
        lastLog("MP-OWNERDEATH npc=ttkc_man_2 applied", mark))
    check("b: the corpse was put where the owner's stream has it", math.abs(e.px - 13) < 0.01 and math.abs(e.py - 12) < 0.01,
        string.format("%.2f,%.2f", e.px, e.py))
    check("b: exactly one placement write", #e.writes == writesBefore + 1, tostring(#e.writes - writesBefore))
    check("b: residual after the placement read back as 0", (lastLog("applied=dead", mark) or ""):find("residual_m=0.00", 1, true) ~= nil)
    check("b: no npc_death announced for an owner-applied death", countEvt("npc_death", "ttkc_man_2", mark) == 0)
    run(5.0, function() KCD2MP_ApplyNpcState("ttkc_man_2", 13, 12, 0.2, 0, 0, 1, 0, nil, nil) end)
    check("b: no more requests once it is dead here", countEvt("npc_owner_dead", "ttkc_man_2", mark) == 2)
    check("b: no further writes on the settled corpse", #e.writes == writesBefore + 1, tostring(#e.writes - writesBefore))
    noErrs("b")

    -- (c) a load brings the copy back alive; the stream still says dead
    local mark2 = #LOG
    e.dead = false; e.hp = 100; e.px, e.py, e.pz = 10, 10, 0
    run(0.2, function() KCD2MP_ApplyNpcState("ttkc_man_2", 13, 12, 0.2, 0, 0, 1, 0, nil, nil) end)
    check("c: after the load: asked again at once", countEvt("npc_owner_dead", "ttkc_man_2", mark2) == 1, lastLog("MP-OWNERDEATH", mark2))
    e.dead = true; e.hp = 0
    tick()
    check("c: and it lands again, corpse on the stream's spot", countLog("applied=dead", mark2) == 1 and math.abs(e.px - 13) < 0.01)
    check("c: still nothing announced back", countEvt("npc_death", "ttkc_man_2", mark2) == 0)
    noErrs("c")
end

-- (d) one-way: a living stream never revives a local corpse -------------------
do
    resetNpc()
    local e = mkEntity("v_dead", 0, 0, 0); ENTS["v_dead"] = e
    KCD2MP_ApplyNpcState("v_dead", 0, 0, 0, 0, 100, 0, 0, 1, 1000)
    tick()
    e.dead = true; e.hp = 0
    local mark = #LOG
    local w0 = #e.writes
    run(3.0, function() KCD2MP_ApplyNpcState("v_dead", e.px + 3, 0, 0, 0, 100, 0, 0, nil, nil) end)
    check("d: no owner-death request (the stream says alive)", countEvt("npc_owner_dead", "", mark) == 0)
    check("d: the corpse gets no writes from the living stream", #e.writes == w0, tostring(#e.writes - w0))
    check("d: still dead here", e.dead == true)
    noErrs("d")
end

-- (e) the toggles ----------------------------------------------------------------
do
    resetNpc()
    local e = mkEntity("v_off", 0, 0, 0); ENTS["v_off"] = e
    local mark = #LOG
    KCD2MP_SetOwnerDeath("off")
    check("e: off is mirrored", countEvt("wo122_cfg", "shared_world=off owner_death=off", mark) == 1)
    KCD2MP_ApplyNpcState("v_off", 5, 5, 0, 0, 0, 1, 0, 1, 1000)
    run(4.0)
    check("e: owner_death off: no request", countEvt("npc_owner_dead", "", mark) == 0)
    KCD2MP_SetOwnerDeath("on")
    KCD2MP.npcDeathSync = false
    run(4.0, function() KCD2MP_ApplyNpcState("v_off", 5, 5, 0, 0, 0, 1, 0, nil, nil) end)
    check("e: mp_npc_deathsync off: no request either", countEvt("npc_owner_dead", "", mark) == 0)
    KCD2MP.npcDeathSync = true
    run(0.2, function() KCD2MP_ApplyNpcState("v_off", 5, 5, 0, 0, 0, 1, 0, nil, nil) end)
    check("e: both on: asks", countEvt("npc_owner_dead", "v_off", mark) == 1)
    check("e: a bad argument is refused", KCD2MP_SetOwnerDeath("maybe") == false and KCD2MP.w122.ownerDeath == true)
    local m2 = #LOG
    KCD2MP_SetOwnerDeath("%line")
    check("e: a bare call reports and changes nothing", KCD2MP.w122.ownerDeath == true and countLog("WO122-TOGGLE owner_death=on", m2) == 1)
    noErrs("e")
end

-- (f) the one-shot resync path ---------------------------------------------------
do
    resetNpc()
    local e = mkEntity("v_rs", 0, 0, 0); ENTS["v_rs"] = e
    local mark = #LOG
    KCD2MP_ApplyNpcState("v_rs", 4, 0, 0, 0, 0, 64 + 1, 0, 1, 1000)   -- RESYNC | DEAD, no puppet
    check("f: a resync naming a dead body alive here asks", countEvt("npc_owner_dead", "v_rs", mark) == 1, lastLog("MP-OWNERDEATH", mark))
    check("f: ...tagged via=resync", (lastLog("MP-OWNERDEATH npc=v_rs", mark) or ""):find("via=resync", 1, true) ~= nil)
    check("f: no puppet was created by the resync", KCD2MP.npcPuppets["v_rs"] == nil)
    noErrs("f")
end

-- (g) the joiner's lock ------------------------------------------------------------
do
    local w = KCD2MP.w122
    local mark = #LOG
    LOCKCALLS = 0
    check("g: dormant: with mp_shared_world off the lock is refused", KCD2MP_HostOnlyLock(true, "tick") == false)
    check("g: ...and the engine was never asked", LOCKCALLS == 0 and next(LOCKS) == nil)
    KCD2MP_SetSharedWorld("on")
    check("g: on is mirrored", countEvt("wo122_cfg", "shared_world=on", mark) == 1)
    check("g: first hold: held by read-back", KCD2MP_HostOnlyLock(true, "tick") == true and LOCKS["kcdmp_host_only"] == "The host saves this world.")
    check("g: logged asserted/first hold", countLog("MP-SAVELOCK asserted name=kcdmp_host_only why=tick n=1 readback=held -- first hold", mark) == 1,
        lastLog("MP-SAVELOCK", mark))
    check("g: the player is told once", countLog('MP-TOAST kind=msg text="Co-op: The host saves this world."', mark) == 1)
    local m2 = #LOG
    local calls0 = LOCKCALLS
    for _ = 1, 5 do NOW = NOW + 1; KCD2MP_HostOnlyLock(true, "tick") end
    check("g: steady state: silent, still held", countLog("MP-SAVELOCK", m2) == 0 and countLog("MP-TOAST", m2) == 0 and w.lockHeld)
    check("g: steady state: the engine is not asked every tick (each refused add logs an engine error)", LOCKCALLS == calls0, tostring(LOCKCALLS - calls0))
    NOW = NOW + 30
    KCD2MP_HostOnlyLock(true, "tick")
    check("g: ...but re-checked every 30 s with ONE add (refused = still held)", LOCKCALLS == calls0 + 1 and w.lockHeld, tostring(LOCKCALLS - calls0))
    LOCKS = {}   -- a load
    KCD2MP_HostOnlyLock(true, "after-load")
    check("g: a load's wipe is noticed and re-asserted", countLog("readback=held -- it was gone (a load wipes every lock; wiped 1x)", m2) == 1,
        lastLog("MP-SAVELOCK", m2))
    check("g: held again", LOCKS["kcdmp_host_only"] ~= nil and w.lockHeld)
    LOCK_BROKEN = true
    local m3 = #LOG
    NOW = NOW + 31   -- the next steady-state check
    KCD2MP_HostOnlyLock(true, "tick")
    check("g: a read-back that does not hold is loud", countLog("MP-SAVELOCK READBACK FAILED", m3) == 1 and w.lockHeld == false)
    LOCK_BROKEN = false; LOCKS = {}
    KCD2MP_HostOnlyLock(true, "tick")
    local m4 = #LOG
    KCD2MP_HostOnlyLock(false, "disconnect")
    check("g: release removes it", LOCKS["kcdmp_host_only"] == nil and countLog("MP-SAVELOCK released name=kcdmp_host_only why=disconnect", m4) == 1)
    KCD2MP_HostOnlyLock(true, "tick")
    KCD2MP_SetSharedWorld("off")
    check("g: mp_shared_world off releases at once", LOCKS["kcdmp_host_only"] == nil and w.lockHeld == false)
    check("g: bad argument refused", KCD2MP_SetSharedWorld("sometimes") == false and w.sharedWorld == false)
    local m5 = #LOG
    KCD2MP_HostOnlyLock(false, "agent-start")
    check("g: a release with nothing held is silent", countLog("MP-SAVELOCK", m5) == 0)
    LOCKS["kcdmp_host_only"] = "left by a killed agent"
    KCD2MP_HostOnlyLock(false, "agent-start")
    check("g: ...but a lock left behind is removed and logged", LOCKS["kcdmp_host_only"] == nil and countLog("MP-SAVELOCK released name=kcdmp_host_only why=agent-start", m5) == 1)
    noErrs("g")
end

-- (g2) a refused autosave tells the player, throttled
do
    local mark = #LOG
    KCD2MP.w122.refusedToldAt = -1e9
    KCD2MP_SaveRefused("autosave"); KCD2MP_SaveRefused("autosave")
    check("g2: each refusal is logged", countLog("MP-SAVELOCK refused kind=autosave", mark) == 2)
    check("g2: the player is told once in 30 s", countLog('MP-TOAST kind=msg text="The host saves this world."', mark) == 1)
    NOW = NOW + 31
    KCD2MP_SaveRefused("autosave")
    check("g2: and again after 30 s", countLog('MP-TOAST kind=msg text="The host saves this world."', mark) == 2)
    noErrs("g2")
end

-- (h) the host's world save ------------------------------------------------------
do
    local mark = #LOG
    SAVEREQ = 0
    TIMERS = {}
    check("h: a request enqueues one autosave", KCD2MP_HostWorldSave("schedule", 1) == true and SAVEREQ == 1)
    check("h: logged", countLog("MP-WORLDSAVE request why=schedule attempt=1 enqueue=true", mark) == 1)
    check("h: the frame-gap monitor is armed (a per-frame timer)", #TIMERS == 1 and TIMERS[1].ms == 0)
    KCD2MP_HostWorldSave("schedule", 2)
    check("h: a retry does not stack a second monitor", #TIMERS == 1 and SAVEREQ == 2)
    -- drive the monitor: 60 fps with one 180 ms stall (the save)
    local guard = 0
    while #TIMERS > 0 and guard < 2000 do
        guard = guard + 1
        local t = table.remove(TIMERS, 1)
        NOW = NOW + ((guard == 100) and 0.180 or 0.016)
        t.f()
    end
    local h = lastLog("MP-WORLDSAVE hitch", mark) or ""
    check("h: the hitch line reports the stall", h:find("frame_gap_max_ms=180", 1, true) ~= nil, h)
    noErrs("h")
end

-- (i) mp_world_save ------------------------------------------------------------
do
    local mark = #LOG
    check("i: refused with mp_shared_world off", KCD2MP_WorldSaveNow() == false and countEvt("world_save_request", "", mark) == 0)
    KCD2MP_SetSharedWorld("on")
    check("i: asks the agent with it on", KCD2MP_WorldSaveNow() == true and countEvt("world_save_request", "manual", mark) == 1)
    KCD2MP_WorldSaveDone(true, "playline1/autosave042.whs", "manual", 1, 900, "ok")
    check("i: the result is logged and shown", countLog("MP-WORLDSAVE result=saved file=playline1/autosave042.whs why=manual", mark) == 1
        and countLog('MP-TOAST kind=msg text="World saved: playline1/autosave042.whs"', mark) == 1)
    KCD2MP_SetSharedWorld("off")
    noErrs("i")
end

-- (j) mp_autosave_minutes --------------------------------------------------------
do
    local w = KCD2MP.w122
    local mark = #LOG
    check("j: 10 accepted", KCD2MP_SetAutosaveMinutes("10") == true and w.autosaveMinutes == 10)
    check("j: mirrored", countEvt("wo122_cfg", "shared_world=off owner_death=on autosave_min=10", mark) == 1)
    check("j: 0 accepted (no schedule)", KCD2MP_SetAutosaveMinutes("0") == true and w.autosaveMinutes == 0)
    check("j: 121 refused", KCD2MP_SetAutosaveMinutes("121") == false and w.autosaveMinutes == 0)
    check("j: 2.5 refused", KCD2MP_SetAutosaveMinutes("2.5") == false)
    check("j: words refused", KCD2MP_SetAutosaveMinutes("often") == false)
    local m2 = #LOG
    KCD2MP_SetAutosaveMinutes("%line")
    check("j: bare reports", countLog("WO122-TOGGLE autosave_minutes=0", m2) == 1)
    KCD2MP_SetAutosaveMinutes("5")
    noErrs("j")
end

-- (k) presets --------------------------------------------------------------------
do
    local w = KCD2MP.w122
    KCD2MP_ApplyPreset("legacy")
    check("k: legacy = owner_death off, shared_world off, autosave 5", w.ownerDeath == false and w.sharedWorld == false and w.autosaveMinutes == 5)
    KCD2MP_ApplyPreset("clean")   -- from legacy's off
    check("k: clean = owner_death on, shared_world on (the 0.30.0 default), autosave 5",
        w.ownerDeath == true and w.sharedWorld == true and w.autosaveMinutes == 5)
    check("k: each preset logs the three rows", countLog("MP-PRESET name=clean set=owner_death") == 1 and countLog("MP-PRESET name=clean set=shared_world") == 1
        and countLog("MP-PRESET name=clean set=autosave_minutes") == 1)
    noErrs("k")
end

-- (l) the receiver ---------------------------------------------------------------
do
    local mark = #LOG
    KCD2MP_WorldSavedIn(0, 3, "playline1/autosave042.whs", "0123456789abcdef0123456789abcdef", 41)
    check("l: MP-WORLDSAVED logged with a short md5", countLog("MP-WORLDSAVED from=0 seq=3 file=playline1/autosave042.whs md5=01234567 age_ms=41", mark) == 1)
    noErrs("l")
end

OUT = table.concat(RESULTS, "\n")
