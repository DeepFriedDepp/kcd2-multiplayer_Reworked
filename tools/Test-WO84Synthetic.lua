-- WO-84 synthetic test for the three fixes this work order shipped:
--   * the ghost animation throttle (mp_anim_loop / KCD2MP_UpdateAnimation)
--   * puppet-chain generation retirement on a self-stop (KCD2MP_NpcPuppetTick)
--   * the orphan ghost-body sweep (KCD2MP_SweepStrayGhosts)
--
-- Driven by Test-WO84Synthetic.ps1 through the WO-77 MoonSharp driver: the
-- real kdcmp.lua is spliced in at the marker below with the engine stubbed and
-- os.clock replaced by a fake clock. No game, relay or agent involved.
--
-- What this proves: call counts, gating and bookkeeping against known
-- sequences. What it does NOT prove: that the game's animation queue actually
-- stops overflowing, that a ghost still looks right to a human, or that a
-- save-embedded body is really standing in a loaded world. Those need a live
-- session -- see docs/WO-84-findings.md.
--
-- Part 1 (before the marker): engine stubs + a fake clock.

NOW = 0                                  -- the fake wall clock, seconds
os.clock = function() return NOW end
LOG = {}; TIMERS = {}; ENTS = {}; ERRS = {}; TOASTS = {}

local function mkstub()
    return setmetatable({}, { __index = function(_, k) return function(...) return nil end end })
end
System = mkstub()
System.LogAlways = function(s) LOG[#LOG + 1] = tostring(s) end
System.GetCVarValue = function() return "0" end
System.GetEntityByName = function(n) return ENTS[n] end
System.GetEntitiesInSphere = function() return {} end
System.RemoveEntity = function(eid)
    for n, e in pairs(ENTS) do if e.id == eid then ENTS[n] = nil end end
end
Script = mkstub()
Script.SetTimer = function(ms, f) TIMERS[#TIMERS + 1] = { ms = ms, f = f, at = NOW } end
Game = mkstub(); AI = mkstub(); Sound = mkstub(); Physics = mkstub(); Terrain = mkstub()
UIAction = mkstub()
UIAction.CallFunction = function(panel, inst, fn, text) TOASTS[#TOASTS + 1] = tostring(text) end
player = nil

local rawpcall = pcall
pcall = function(f, ...)
    local r = { rawpcall(f, ...) }
    if not r[1] then ERRS[#ERRS + 1] = tostring(r[2]) end
    return unpack(r)
end

-- @@KDCMP@@

-- WO-102: these scenarios pin the 0.23.2 CLAIM model, which now ships as `mp_authority_host_off`
-- (host authority is the shipped default since WO-102; Test-WO102Synthetic.lua covers that side).
KCD2MP.wo102.authorityHost = false

-- Part 2: scenarios.

local RESULTS = {}
local function check(name, ok, detail)
    RESULTS[#RESULTS + 1] = (ok and "PASS  " or "FAIL  ") .. name .. (detail and ("  [" .. detail .. "]") or "")
end
local function countLog(needle, fromLog)
    local n = 0
    for i = (fromLog or 0) + 1, #LOG do if LOG[i]:find(needle, 1, true) then n = n + 1 end end
    return n
end
local function noErrs(label)
    check(label .. ": no swallowed Lua errors", #ERRS == 0, ERRS[1])
end

local NEXTID = 9000
local function mkEntity(name, x, y, z)
    NEXTID = NEXTID + 1
    local e = { class = "NPC", id = NEXTID, px = x or 0, py = y or 0, pz = z or 0,
                rz = 0, writes = {}, anims = {} }
    e.GetName = function(self) return name end
    e.GetWorldPos = function(self) return { x = self.px, y = self.py, z = self.pz } end
    e.SetWorldPos = function(self, p)
        self.px, self.py, self.pz = p.x, p.y, p.z
        self.writes[#self.writes + 1] = { x = p.x, y = p.y, z = p.z, at = NOW }
    end
    e.SetWorldAngles = function(self, a) self.rz = a.z end
    e.StartAnimation = function(self, layer, anim) self.anims[#self.anims + 1] = { anim = anim, at = NOW } end
    e.actor = {
        IsDead = function() return false end,
        IsUnconscious = function() return false end,
        GetHealth = function() return 100 end,
    }
    e.human = {
        IsWeaponDrawn = function() return false end,
        -- The Mannequin fragment path calls this; a real ghost entity has it.
        PlayAnim = function(self, frag, tag) return true end,
        DrawWeapon = function() return true end,
        HolsterWeapon = function() return true end,
    }
    return e
end

-- A ghost built directly: the real spawn path needs XGenAIModule and the face
-- roster, which are engine, not logic. istate mirrors KCD2MP_SpawnGhost's init.
local function resetGhost(id, x, y, z)
    KCD2MP.ghosts = {}
    KCD2MP.labelCache = {}
    KCD2MP.ghostDead = {}; KCD2MP.ghostHealth = {}; KCD2MP.ghostInMenu = {}
    KCD2MP.ghostWeaponDrawn = {}
    KCD2MP._chainLeakSeen = {}
    KCD2MP._chainProbe = {}
    KCD2MP.interpRunning = true
    KCD2MP._interpAliveAt = NOW
    KCD2MP.interpGen = KCD2MP.interpGen or 1
    KCD2MP.ghostAnimRefreshS = 1.0
    ERRS = {}; TOASTS = {}
    local e = mkEntity("kcd2mp_" .. tostring(id), x, y, z)
    ENTS["kcd2mp_" .. tostring(id)] = e
    KCD2MP.ghosts[id] = {
        entity = e, entityId = e.id, spawnName = "kcd2mp_" .. tostring(id),
        istate = {
            px = x, py = y, pz = z, pr = 0,
            tx = x, ty = y, tz = z, tr = 0,
            cx = x, cy = y, cz = z, cr = 0,
            alpha = 1.0, alphaStep = 0.25,
            vx = 0, vy = 0, vz = 0,
            lastPacketX = x, lastPacketY = y,
            ticksSincePacket = 0, packetCount = 0,
            animTag = "idle", smoothedSpeed = 0,
            prevCx = x, prevCy = y, speedDropTicks = 0,
            spawnedAtClock = NOW,
        },
    }
    return e, KCD2MP.ghosts[id]
end

-- ===== (a) the throttle: a stationary ghost on the scheduled chain =====
-- Pre-WO-84 this called StartAnimation on every one of the 100 ticks.
do
    local e, ghost = resetGhost("0", 0, 0, 0)
    KCD2MP_UpdateAnimation("0", ghost, false)          -- first call: the clip changes from nothing
    local afterFirst = #e.anims
    for i = 1, 100 do                                   -- 100 x 20 ms = 2.0 s
        NOW = NOW + 0.020
        KCD2MP_UpdateAnimation("0", ghost, false)
    end
    check("(a) the first update starts the clip once", afterFirst == 1, tostring(afterFirst))
    -- 2.0 s at a 1.0 s keep-alive = 2 refreshes. Anything near 100 is the old bug.
    check("(a) 2 s of 20 ms ticks on a stationary ghost = 3 StartAnimation calls, not 101",
        #e.anims == 3, tostring(#e.anims))
    check("(a) every call was the same idle clip",
        e.anims[1].anim == "relaxed_idle_both" and e.anims[3].anim == "relaxed_idle_both",
        tostring(e.anims[1].anim))
    noErrs("(a)")
end

-- ===== (b) a pumped frame never fires the keep-alive =====
-- The agent's menu pump ran at 62-86 Hz in the field session, into an
-- animation system that was not draining the queue.
do
    local e, ghost = resetGhost("0", 0, 0, 0)
    KCD2MP_UpdateAnimation("0", ghost, true)           -- first pumped call: clip changes
    local afterFirst = #e.anims
    for i = 1, 160 do                                   -- 2 s of 80 Hz pumping
        NOW = NOW + 0.0125
        KCD2MP_UpdateAnimation("0", ghost, true)
    end
    check("(b) the first pumped update still starts the clip (a change always renders)",
        afterFirst == 1, tostring(afterFirst))
    check("(b) 2 s of 80 Hz pumping adds NO keep-alive restarts", #e.anims == 1, tostring(#e.anims))
    noErrs("(b)")
end

-- ===== (c) a clip change under an unchanged tag still restarts =====
-- tag "idle" maps to two clips: relaxed_idle_both, and the combat guard idle
-- when the owner's weapon is drawn. A tag-only guard would never switch.
do
    local e, ghost = resetGhost("0", 0, 0, 0)
    KCD2MP._combatIdleAnim = "combat_rg_sz1_idle_lngsw_player"
    KCD2MP_UpdateAnimation("0", ghost, false)
    local before = #e.anims
    local tagBefore = ghost.istate.animTag
    KCD2MP.ghostWeaponDrawn["0"] = true
    NOW = NOW + 0.020
    KCD2MP_UpdateAnimation("0", ghost, false)          -- same tag, different clip
    check("(c) the tag did not change", ghost.istate.animTag == tagBefore and tagBefore == "idle",
        tostring(tagBefore) .. " -> " .. tostring(ghost.istate.animTag))
    check("(c) the clip change restarted the loop anyway", #e.anims == before + 1,
        tostring(before) .. " -> " .. tostring(#e.anims))
    check("(c) it is the combat guard idle", e.anims[#e.anims].anim == "combat_rg_sz1_idle_lngsw_player",
        tostring(e.anims[#e.anims].anim))
    NOW = NOW + 0.020
    KCD2MP_UpdateAnimation("0", ghost, false)
    check("(c) the very next tick does NOT restart it again", #e.anims == before + 1, tostring(#e.anims))
    KCD2MP._combatIdleAnim = nil
    noErrs("(c)")
end

-- ===== (d) a tag change restarts immediately, not at the next keep-alive =====
do
    local e, ghost = resetGhost("0", 0, 0, 0)
    KCD2MP_UpdateAnimation("0", ghost, false)
    local before = #e.anims
    ghost.istate.smoothedSpeed = 3.5                    -- run
    NOW = NOW + 0.020
    KCD2MP_UpdateAnimation("0", ghost, false)
    check("(d) idle -> run restarts on the same tick", #e.anims == before + 1,
        tostring(e.anims[#e.anims].anim))
    check("(d) the tag was recorded", ghost.istate.animTag == "run", tostring(ghost.istate.animTag))
    noErrs("(d)")
end

-- ===== (e) a one-shot releases the loop guard =====
-- A swing replaces the looped clip on layer 0. Without clearing the guard the
-- ghost would hold the swing pose until the next keep-alive.
do
    local e, ghost = resetGhost("0", 0, 0, 0)
    KCD2MP_UpdateAnimation("0", ghost, false)
    local before = #e.anims
    ghost.istate.oneShotUntil = NOW + 0.5               -- a swing is playing
    NOW = NOW + 0.020
    KCD2MP_UpdateAnimation("0", ghost, false)
    check("(e) the loop is not restarted while a one-shot plays", #e.anims == before, tostring(#e.anims))
    NOW = NOW + 0.6                                     -- the one-shot has expired
    KCD2MP_UpdateAnimation("0", ghost, false)
    check("(e) the tick after the one-shot re-asserts the loop", #e.anims == before + 1,
        tostring(#e.anims))
    check("(e) the one-shot window was cleared", ghost.istate.oneShotUntil == nil)
    noErrs("(e)")
end

-- ===== (e2) the vz-driven jump releases the loop guard too =====
-- That branch is the one one-shot site in the file that sets NO oneShotUntil,
-- so the expiry path in (e) never runs for it. A ghost running before and
-- after the jump would otherwise match on clip name and hold the jump pose.
do
    local e, ghost = resetGhost("0", 0, 0, 0)
    KCD2MP._jumpAnim = "3d_relaxed_jump"
    ghost.istate.smoothedSpeed = 3.5                    -- running
    KCD2MP_UpdateAnimation("0", ghost, false)
    local runClip = e.anims[#e.anims].anim
    check("(e2) running before the jump", runClip == "3d_relaxed_run_turn_strafe", tostring(runClip))
    -- Target the vz-driven branch specifically: jumpFragPlayed true is the
    -- state every airborne tick after the first is already in, and it is the
    -- only branch that plays a one-shot without setting oneShotUntil.
    ghost.istate.jumpFragPlayed = true
    ghost.istate.isAirborne = true
    NOW = NOW + 0.020
    KCD2MP_UpdateAnimation("0", ghost, false)
    check("(e2) the jump clip played", e.anims[#e.anims].anim == "3d_relaxed_jump",
        tostring(e.anims[#e.anims].anim))
    check("(e2) the loop guard was released", ghost.istate.animLoopName == nil)
    ghost.istate.isAirborne = false                     -- landed, still running
    local before = #e.anims
    NOW = NOW + 0.020
    KCD2MP_UpdateAnimation("0", ghost, false)
    check("(e2) landing re-asserts the run loop on the very next tick, not at the keep-alive",
        #e.anims == before + 1 and e.anims[#e.anims].anim == "3d_relaxed_run_turn_strafe",
        tostring(e.anims[#e.anims].anim))
    KCD2MP._jumpAnim = nil
    noErrs("(e2)")
end

-- ===== (f) the rollback lever restores the pre-WO-84 behaviour =====
do
    local e, ghost = resetGhost("0", 0, 0, 0)
    local n0 = #LOG
    KCD2MP_SetGhostAnimRefresh("0")
    check("(f) mp_ghost_anim_refresh 0 is accepted and says so",
        KCD2MP.ghostAnimRefreshS == 0 and countLog("restart every tick", n0) == 1,
        tostring(KCD2MP.ghostAnimRefreshS))
    for i = 1, 20 do
        NOW = NOW + 0.020
        KCD2MP_UpdateAnimation("0", ghost, false)
    end
    check("(f) with refresh 0 every tick restarts the clip again", #e.anims == 20, tostring(#e.anims))
    local n1 = #LOG
    KCD2MP_SetGhostAnimRefresh("banana")
    check("(f) a non-numeric argument is refused and the value is unchanged",
        KCD2MP.ghostAnimRefreshS == 0 and countLog("expected seconds", n1) == 1)
    KCD2MP_SetGhostAnimRefresh("1.0")
    check("(f) it can be set back", KCD2MP.ghostAnimRefreshS == 1.0, tostring(KCD2MP.ghostAnimRefreshS))
    noErrs("(f)")
end

-- ===== (g) the pumped flag is wired through KCD2MP_InterpTick =====
do
    local e, ghost = resetGhost("0", 0, 0, 0)
    KCD2MP_InterpTick("ext")
    check("(g) a pumped interp tick marks the frame pumped", KCD2MP._tickPumped == true,
        tostring(KCD2MP._tickPumped))
    local after = #e.anims
    for i = 1, 160 do
        NOW = NOW + 0.0125
        KCD2MP_InterpTick("ext")
    end
    check("(g) 2 s of pumped interp ticks add no keep-alive restarts", #e.anims == after,
        tostring(after) .. " -> " .. tostring(#e.anims))
    KCD2MP_InterpTick(nil, KCD2MP.interpGen)
    check("(g) a scheduled interp tick marks the frame NOT pumped", KCD2MP._tickPumped == false,
        tostring(KCD2MP._tickPumped))
    noErrs("(g)")
end

-- ===== (h) the self-stop race: an orphan timer is absorbed, not reported =====
-- The joiner's 2026-09-11 leak, reproduced: releases -> "puppet tick stopped
-- (no puppets)" -> a packet starts the next generation -> the retiring
-- generation's already-scheduled timer fires into the live chain.
do
    KCD2MP.npcPuppets = {}
    KCD2MP.npcPuppetRunning = false
    KCD2MP._npcPuppetAliveAt = nil
    KCD2MP._npcPuppetPumpAt = nil
    KCD2MP._npcPuppetRetired = {}
    KCD2MP._npcPuppetRetiredN = 0
    KCD2MP._chainLeakSeen = {}
    KCD2MP._chainLeakN = {}
    KCD2MP._chainProbe = {}
    ERRS = {}; TOASTS = {}
    ENTS["npc_x"] = mkEntity("npc_x", 0, 0, 0)

    KCD2MP_ApplyNpcState("npc_x", 0, 0, 0, 0, 100, 0)
    local genA = KCD2MP.npcPuppetGen
    check("(h) the first packet started a puppet chain", KCD2MP.npcPuppetRunning == true and genA ~= nil,
        tostring(genA))

    -- Let the stream go silent so the chain releases the puppet and stops.
    NOW = NOW + (KCD2MP.npcSync.releaseS or 3) + 1.0
    local nT = #TIMERS
    KCD2MP_NpcPuppetTick(nil, genA)                     -- the last scheduled fire of generation A
    check("(h) it rescheduled its successor BEFORE deciding to stop", #TIMERS == nT + 1,
        tostring(#TIMERS - nT))
    check("(h) the chain stopped itself: no puppets left", KCD2MP.npcPuppetRunning == false)
    check("(h) generation A was retired so its in-flight timer is accounted for",
        KCD2MP._npcPuppetRetired[genA] == true, tostring(genA))

    -- A packet inside the window restarts the chain at once (chainMayStart
    -- grants a stopped chain an immediate start -- that part is correct).
    local logMark = #LOG
    KCD2MP_ApplyNpcState("npc_x", 1, 0, 0, 0, 100, 0)
    local genB = KCD2MP.npcPuppetGen
    check("(h) a packet inside the window starts the next generation immediately",
        KCD2MP.npcPuppetRunning == true and genB == genA + 1,
        tostring(genA) .. " -> " .. tostring(genB))

    -- Now the orphan fires into the live chain. Pre-WO-84 this logged a leak.
    local nT2 = #TIMERS
    local writes0 = #ENTS["npc_x"].writes
    local absorbed0 = KCD2MP._npcPuppetRetiredN
    KCD2MP_NpcPuppetTick(nil, genA)
    check("(h) the orphan was absorbed, not reported as a leak",
        countLog("CHAIN LEAK CONFIRMED", logMark) == 0,
        tostring(countLog("CHAIN LEAK CONFIRMED", logMark)))
    check("(h) the orphan wrote nothing", #ENTS["npc_x"].writes == writes0, tostring(#ENTS["npc_x"].writes - writes0))
    check("(h) the orphan did not reschedule itself", #TIMERS == nT2, tostring(#TIMERS - nT2))
    check("(h) it was counted", KCD2MP._npcPuppetRetiredN == absorbed0 + 1,
        tostring(KCD2MP._npcPuppetRetiredN))
    check("(h) the retirement is one-shot: the entry is cleared", KCD2MP._npcPuppetRetired[genA] == nil)
    check("(h) no toast was raised for it", #TOASTS == 0, tostring(#TOASTS))
    check("(h) it did not even count as a leak", (KCD2MP._chainLeakN.puppet or 0) == 0,
        tostring(KCD2MP._chainLeakN.puppet))
    noErrs("(h)")
end

-- ===== (i) a REAL leak is still reported =====
-- The retirement must not blind the detector: a generation that never stopped
-- itself and is still running is the thing WO-69 built this instrument for.
do
    local logMark = #LOG
    KCD2MP._chainLeakSeen = {}
    TOASTS = {}
    local stale = KCD2MP.npcPuppetGen - 1               -- never retired
    KCD2MP_NpcPuppetTick(nil, stale)
    check("(i) an unretired stale generation is still reported as a leak",
        countLog("CHAIN LEAK CONFIRMED", logMark) == 1,
        tostring(countLog("CHAIN LEAK CONFIRMED", logMark)))
    check("(i) it still says the stale chain is exiting (mp_npc_chainfix on)",
        countLog("stale chain exiting now", logMark) == 1)
    check("(i) it still raises the toast", #TOASTS == 1, TOASTS[1])
    check("(i) and it is counted", (KCD2MP._chainLeakN.puppet or 0) == 1,
        tostring(KCD2MP._chainLeakN.puppet))
    -- The latch silences the loud line, but a SECOND leak must still be visible
    -- in the counter -- that is the whole point of separating them (WO-84).
    KCD2MP_NpcPuppetTick(nil, KCD2MP.npcPuppetGen - 1)
    check("(i) a second leak is still counted even though the latch silenced the line",
        (KCD2MP._chainLeakN.puppet or 0) == 2 and countLog("CHAIN LEAK CONFIRMED", logMark) == 1,
        tostring(KCD2MP._chainLeakN.puppet))
    noErrs("(i)")
end

-- ===== (j) the interp chain's retirement (preventative, never field-observed) =====
do
    KCD2MP._interpRetired = {}
    KCD2MP._interpRetiredN = 0
    KCD2MP._chainLeakSeen = {}
    local e, ghost = resetGhost("0", 0, 0, 0)
    KCD2MP.interpGen = (KCD2MP.interpGen or 1)
    local genA = KCD2MP.interpGen
    KCD2MP_Stop()
    check("(j) KCD2MP_Stop retires the generation whose timer is in flight",
        KCD2MP._interpRetired[genA] == true, tostring(genA))
    KCD2MP.interpRunning = true                          -- a reconnect starts a new chain
    KCD2MP.interpGen = genA + 1
    local logMark = #LOG
    local nT = #TIMERS
    KCD2MP_InterpTick(nil, genA)                         -- the orphan fires
    check("(j) the orphan is absorbed, not reported as a ghost chain leak",
        countLog("GHOST CHAIN LEAK CONFIRMED", logMark) == 0)
    check("(j) the orphan did not reschedule", #TIMERS == nT, tostring(#TIMERS - nT))
    check("(j) it was counted", KCD2MP._interpRetiredN == 1, tostring(KCD2MP._interpRetiredN))
    noErrs("(j)")
end

-- ===== (k) the orphan ghost-body sweep =====
do
    KCD2MP.ghosts = {}
    KCD2MP.horseGhosts = {}
    KCD2MP._orphanSeen = {}
    KCD2MP._orphanSweepAt = NOW - 1000   -- the throttle must not eat the first sweep
    KCD2MP._orphanRemovedN = 0
    KCD2MP.orphanSweep = true
    ERRS = {}
    -- The field shape: a body named kcd2mp_0 restored by a savegame, on a
    -- machine whose live ghost is kcd2mp_1.
    ENTS["kcd2mp_0"] = mkEntity("kcd2mp_0", 10, 10, 0)
    local liveEnt = mkEntity("kcd2mp_1", 20, 20, 0)
    ENTS["kcd2mp_1"] = liveEnt
    KCD2MP.ghosts["1"] = { entity = liveEnt, entityId = liveEnt.id, spawnName = "kcd2mp_1" }

    -- A non-immediate sweep is the periodic one: it confirms, then removes.
    local mark = #LOG
    local n1 = KCD2MP_SweepStrayGhosts(false)
    check("(k) the first sweep removes nothing", n1 == 0, tostring(n1))
    check("(k) it reports the candidate and says it will confirm",
        countLog("confirming on the next sweep", mark) == 1)
    check("(k) the orphan is still standing after one sweep", ENTS["kcd2mp_0"] ~= nil)

    local mark2 = #LOG
    NOW = NOW + 31
    local n2 = KCD2MP_SweepStrayGhosts(false)
    check("(k) the second sweep removes it", n2 == 1, tostring(n2))
    check("(k) the body is gone", ENTS["kcd2mp_0"] == nil)
    check("(k) it said it is removing", countLog("-- removing", mark2) == 1)
    check("(k) the TRACKED ghost was never touched", ENTS["kcd2mp_1"] ~= nil and KCD2MP.ghosts["1"] ~= nil)
    check("(k) the session total advanced", KCD2MP._orphanRemovedN == 1, tostring(KCD2MP._orphanRemovedN))

    -- Throttle: an unforced sweep inside the window does nothing at all.
    ENTS["kcd2mp_9"] = mkEntity("kcd2mp_9", 30, 30, 0)
    local mark3 = #LOG
    local n3 = KCD2MP_SweepStrayGhosts(false)
    check("(k) an unforced sweep inside the 30 s window is a no-op",
        n3 == 0 and countLog("SweepStrayGhosts", mark3) == 0, tostring(n3))
    NOW = NOW + 31
    KCD2MP_SweepStrayGhosts(false)          -- confirms
    NOW = NOW + 31
    KCD2MP_SweepStrayGhosts(false)          -- removes
    check("(k) past the window it runs again and removes the new orphan", ENTS["kcd2mp_9"] == nil)

    -- immediate=true is the shutdown caller: one pass, no confirmation, no throttle.
    ENTS["kcd2mp_8"] = mkEntity("kcd2mp_8", 60, 60, 0)
    local nImm = KCD2MP_SweepStrayGhosts(true)
    check("(k) immediate=true removes on the FIRST pass (the shutdown caller)",
        nImm == 1 and ENTS["kcd2mp_8"] == nil, tostring(nImm))

    -- A numeric ghost key must protect the name just as a string key does.
    ENTS["kcd2mp_5"] = mkEntity("kcd2mp_5", 40, 40, 0)
    KCD2MP.ghosts[5] = { entity = ENTS["kcd2mp_5"], entityId = ENTS["kcd2mp_5"].id }
    KCD2MP_SweepStrayGhosts(true)
    KCD2MP_SweepStrayGhosts(true)
    check("(k) a ghost tracked under a NUMERIC key is protected from even an immediate sweep",
        ENTS["kcd2mp_5"] ~= nil)

    -- The off switch.
    KCD2MP.ghosts = {}
    ENTS["kcd2mp_4"] = mkEntity("kcd2mp_4", 50, 50, 0)
    KCD2MP._orphanSeen = {}
    KCD2MP_SetOrphanSweep("off")
    NOW = NOW + 31
    KCD2MP_SweepStrayGhosts(false)
    NOW = NOW + 31
    KCD2MP_SweepStrayGhosts(false)
    check("(k) mp_ghost_sweep off disables it", KCD2MP.orphanSweep == false and ENTS["kcd2mp_4"] ~= nil)
    KCD2MP_SetOrphanSweep("on")
    check("(k) mp_ghost_sweep on re-enables it", KCD2MP.orphanSweep == true)
    noErrs("(k)")
end

OUT = table.concat(RESULTS, "\n")
