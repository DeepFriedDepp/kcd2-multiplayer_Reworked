-- WO-78 synthetic test for the GHOST interp chain (kdcmp.lua's
-- KCD2MP_UpdateGhost / KCD2MP_InterpTick / KCD2MP_StartInterp) and the shared
-- probe-confirmed chain-restart gate (chainMayStart). Driven by
-- Test-GhostInterpSynthetic.ps1 through the WO-77 MoonSharp driver: the real
-- kdcmp.lua is spliced in at the marker below with the engine stubbed and
-- os.clock replaced by a fake clock. No game, relay or agent involved: this
-- proves the MATH and the GATE against known sequences, nothing about how a
-- ghost looks on screen.
--
-- Kept separate from Test-NpcSmoothSynthetic.lua on purpose: ghost and puppet
-- code are separate files/functions (WO-70 constraint 1), so are their tests.
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
local function near(a, b, eps) return math.abs(a - b) <= (eps or 1e-6) end
local function fmt(v) return string.format("%.5f", v) end
local function countLog(needle, fromLog)
    local n = 0
    for i = (fromLog or 0) + 1, #LOG do if LOG[i]:find(needle, 1, true) then n = n + 1 end end
    return n
end
local function noErrs(label)
    check(label .. ": no swallowed Lua errors in the render path", #ERRS == 0, ERRS[1])
end

local function mkEntity(x, y, z)
    local e = { class = "NPC", id = 4661, px = x, py = y, pz = z, rz = 0, writes = {}, anims = {} }
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
    return e
end

-- A ghost built directly (the spawn path needs XGenAIModule and the face
-- roster -- engine, not math). The istate mirrors KCD2MP_SpawnGhost's init
-- table field for field; if that table grows, grow this one.
local function resetGhost(id, x, y, z)
    KCD2MP.ghosts = {}
    KCD2MP.labelCache = {}
    KCD2MP.ghostDead = {}; KCD2MP.ghostHealth = {}; KCD2MP.ghostInMenu = {}
    KCD2MP._chainLeakSeen = {}
    KCD2MP._chainProbe = {}
    KCD2MP.interpRunning = true
    KCD2MP._interpAliveAt = NOW
    KCD2MP.interpGen = KCD2MP.interpGen or 1
    ERRS = {}; TOASTS = {}
    local e = mkEntity(x, y, z)
    KCD2MP.ghosts[id] = {
        entity = e, entityId = e.id,
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
    return e
end
local function pkt(id, x, y, z) KCD2MP_UpdateGhost(id, x, y, z, 0, false) end
local function chainTick(gen) KCD2MP_InterpTick(nil, gen) end      -- a real timer chain's fire
local function pumpTick() KCD2MP_InterpTick("ext") end              -- the menu pump's fire
-- Fire every timer queued since index `from` whose due time has passed,
-- in order, returning how many fired. Timers queued by a fired timer are
-- picked up in the same call if they are due too.
local function fireDue(from)
    local n = 0
    local i = (from or 0) + 1
    while i <= #TIMERS do
        local t = TIMERS[i]
        if not t.fired and NOW >= t.at + t.ms / 1000 - 1e-9 then
            t.fired = true; n = n + 1; t.f()
        end
        i = i + 1
    end
    return n
end

check("mp_ghost_chainfix defaults ON", KCD2MP.ghostChainFix == true, tostring(KCD2MP.ghostChainFix))

-- ----------------------------------------------- (ga) single chain, steady
-- Packets every 50 ms at 1.5 m/s along +x, chain fires every 20 ms, 2 s.
local V = 1.5
local GA = {}          -- per-step written x (or nil when the step wrote nothing)
do
    local e = resetGhost("1", 0, 0, 0)
    local gen = KCD2MP.interpGen
    local okMono, okBound, bad = true, true, nil
    local prev = 0
    for i = 0, 100 do
        NOW = i * 0.02
        if i % 5 == 0 then pkt("1", V * NOW, 0, 0) end
        local before = #e.writes
        chainTick(gen)
        GA[i] = e.px
        if e.px < prev - 1e-9 then okMono = false; bad = bad or string.format("t=%.2f x=%s prev=%s", NOW, fmt(e.px), fmt(prev)) end
        -- one 20 ms fire may close at most half the gap to a target at most
        -- (V*0.05 + DR 60 ms) ahead: a hard ceiling on a single step.
        if e.px - prev > (V * 0.05 + V * 0.06) + 1e-9 then okBound = false; bad = bad or string.format("t=%.2f step=%s", NOW, fmt(e.px - prev)) end
        prev = e.px
    end
    check("(ga) single chain: rendered x never moves backwards over 2 s of steady walking", okMono, bad)
    check("(ga) single chain: no single 20 ms step exceeds one packet gap + DR lookahead", okBound, bad)
    check("(ga) single chain: rendered x within 0.3 m of the true position at t=2.0 (lerp lag only)",
        math.abs(e.px - V * 2.0) < 0.3, fmt(e.px) .. " vs " .. fmt(V * 2.0))
    check("(ga) single chain writes once per fire (101 fires, 100 writes: the first fire is the dt seed)",
        #e.writes >= 99 and #e.writes <= 101, tostring(#e.writes))
    noErrs("(ga)")
end

-- --------------------------------------- (gc) same-frame duplicates + stale
-- (ga)'s schedule, but at each step the CURRENT generation fires 3x at the
-- same NOW (the field session's resumed-together chains) plus once through a
-- STALE generation. Every write at a step must equal (ga)'s; the stale fire
-- must be detected, toasted, and must not reschedule.
do
    local e = resetGhost("1", 0, 0, 0)
    KCD2MP.interpGen = KCD2MP.interpGen + 1
    local gen = KCD2MP.interpGen
    local okSame, okIntra, bad = true, true, nil
    local staleTimers = 0
    for i = 0, 100 do
        NOW = i * 0.02
        if i % 5 == 0 then pkt("1", V * NOW, 0, 0) end
        local before = #e.writes
        chainTick(gen); chainTick(gen); chainTick(gen)
        local nT = #TIMERS
        chainTick(gen - 1)                          -- the leaked chain
        if #TIMERS ~= nT then staleTimers = staleTimers + 1 end
        for w = before + 1, #e.writes do
            if not near(e.writes[w].x, GA[i], 1e-9) then
                okIntra = false
                bad = bad or string.format("t=%.2f write=%s single=%s", NOW, fmt(e.writes[w].x), fmt(GA[i]))
            end
        end
        if not near(e.px, GA[i], 1e-9) then okSame = false; bad = bad or string.format("t=%.2f x=%s single=%s", NOW, fmt(e.px), fmt(GA[i])) end
    end
    check("(gc) 3 same-frame chain fires render the SAME position as one chain at every step", okSame and okIntra, bad)
    check("(gc) total displacement identical to the single chain (not multiplied)", near(e.px, GA[100], 1e-9),
        fmt(e.px) .. " vs " .. fmt(GA[100]))
    check("(gc) the stale generation was detected: GHOST CHAIN LEAK CONFIRMED logged exactly once",
        countLog("GHOST CHAIN LEAK CONFIRMED") == 1, tostring(countLog("GHOST CHAIN LEAK CONFIRMED")))
    check("(gc) the leak line says the stale chain is exiting (mp_ghost_chainfix on)",
        countLog("stale chain exiting now") == 1)
    check("(gc) the leak was surfaced as a native toast", #TOASTS == 1 and TOASTS[1]:find("chain leak", 1, true) ~= nil, TOASTS[1])
    check("(gc) the stale chain never rescheduled itself (exited on every fire)", staleTimers == 0, tostring(staleTimers))
    noErrs("(gc)")
end

-- ---------------------------------- (gc2) two chains 10 ms out of phase
-- Chain A fires at t, chain B at t + 10 ms, both current. While the target
-- moves the two trajectories may differ slightly around packet arrivals;
-- once the stream stops (constant target) they must converge on the same
-- point. Neither may ever move backwards or overshoot the target.
do
    local e = resetGhost("1", 0, 0, 0)
    local gen = KCD2MP.interpGen
    local okClose, okMono, bad = true, true, nil
    local prev = 0
    for i = 0, 100 do
        NOW = i * 0.02
        if i % 5 == 0 then pkt("1", V * NOW, 0, 0) end
        chainTick(gen)
        if e.px < prev - 1e-9 then okMono = false end
        prev = e.px
        if not near(e.px, GA[i], 0.05) then okClose = false; bad = bad or string.format("t=%.2f two=%s one=%s", NOW, fmt(e.px), fmt(GA[i])) end
        NOW = i * 0.02 + 0.01
        chainTick(gen)
        if e.px < prev - 1e-9 then okMono = false end
        prev = e.px
    end
    check("(gc2) two phase-offset chains stay within 5 cm of the single-chain trajectory while moving", okClose, bad)
    check("(gc2) two phase-offset chains never move the ghost backwards", okMono)
    -- stream stops at x = V*2.0; both keep firing for 1 s. The WO-38 DR
    -- HOLDS at the 60 ms projection (it never reverts to the bare packet), so
    -- the rest point is packet + v * 0.060 -- same as a single chain.
    local target = V * 2.0 + (KCD2MP.ghosts["1"].istate.vx or 0) * 0.060
    for i = 101, 150 do
        NOW = i * 0.02; chainTick(gen)
        NOW = i * 0.02 + 0.01; chainTick(gen)
    end
    check("(gc2) after the stream stops both chains converge on the held DR point (1 mm)", near(e.px, target, 1e-3),
        fmt(e.px) .. " vs " .. fmt(target))
    noErrs("(gc2)")
end

-- ------------------------------------------ (gd) gate: suspended, not dead
-- The chain stamped alive at NOW; the clock then jumps 8 s (a menu, dialog
-- or cutscene suspended every timer). The agent's re-arm calls
-- KCD2MP_StartInterp: it must NOT start a second chain. The probe is armed
-- (suspended too); when everything resumes the chain stamps first, the probe
-- fires, finds it alive and logs the refusal.
do
    resetGhost("1", 0, 0, 0)
    KCD2MP.labelRunning = true; KCD2MP._labelAliveAt = NOW
    local gen0 = KCD2MP.interpGen
    local nT, nLog = #TIMERS, #LOG
    NOW = NOW + 8.0                          -- suspension: stamp is now 8 s stale
    KCD2MP_StartInterp()
    check("(gd) StartInterp during a suspension does not start a second interp chain",
        KCD2MP.interpGen == gen0 and countLog("Interp tick started", nLog) == 0,
        "gen " .. tostring(gen0) .. " -> " .. tostring(KCD2MP.interpGen))
    check("(gd) it armed exactly one probe per chain (interp + label = 2 timers at 400 ms)",
        #TIMERS == nT + 2 and TIMERS[nT + 1].ms == 400 and TIMERS[nT + 2].ms == 400, tostring(#TIMERS - nT))
    KCD2MP_StartInterp()                     -- the next re-arm 2.5 s later, still suspended
    NOW = NOW + 2.5
    KCD2MP_StartInterp()
    check("(gd) repeated re-arms while the probe is pending arm nothing more", #TIMERS == nT + 2, tostring(#TIMERS - nT))
    -- resume: the chains fire first (they were due), then the probes
    KCD2MP._interpAliveAt = NOW; KCD2MP._labelAliveAt = NOW
    NOW = NOW + 0.001
    fireDue(nT)                              -- first hops fire, arm the settle hops
    NOW = NOW + 0.25
    fireDue(nT)                              -- settle hops fire
    check("(gd) the probe found the chain alive: 'suspended, not dead' logged for interp and label",
        countLog("CHAIN interp was suspended, not dead", nLog) == 1 and countLog("CHAIN label was suspended, not dead", nLog) == 1)
    check("(gd) no restart happened and the probe entries were cleared",
        KCD2MP.interpGen == gen0 and KCD2MP._chainProbe.interp == nil and KCD2MP._chainProbe.label == nil)
    check("(gd) the refusal counter advanced by 2", KCD2MP._chainSuspendedN == 2, tostring(KCD2MP._chainSuspendedN))
    noErrs("(gd)")
end

-- --------------------------------------------- (ge) gate: really dead
-- A save load killed the chain: the stamp goes stale and NOTHING refreshes
-- it. The probe (armed after the load, into a working timer system) fires,
-- finds no heartbeat, and the chain restarts exactly once.
do
    resetGhost("1", 0, 0, 0)
    KCD2MP.labelRunning = true; KCD2MP._labelAliveAt = NOW
    KCD2MP._chainSuspendedN = 0
    local gen0 = KCD2MP.interpGen
    local nT, nLog = #TIMERS, #LOG
    NOW = NOW + 3.0                          -- post-load: stamp 3 s stale, no chain to refresh it
    KCD2MP_StartInterp()                     -- re-arm #1: arms the probes
    check("(ge) the first re-arm after a real death arms probes, does not restart yet",
        KCD2MP.interpGen == gen0 and #TIMERS == nT + 2)
    NOW = NOW + 0.4; fireDue(nT)
    NOW = NOW + 0.2; fireDue(nT)             -- settle hops: still no heartbeat
    check("(ge) the probe confirmed death and restarted: 'confirmed dead' + 'Interp tick started' once each",
        countLog("CHAIN interp confirmed dead", nLog) == 1 and countLog("Interp tick started", nLog) == 1
        and countLog("Label render loop started", nLog) == 1)
    check("(ge) the generation advanced by exactly one", KCD2MP.interpGen == gen0 + 1, tostring(KCD2MP.interpGen))
    local nT2 = #TIMERS
    KCD2MP_StartInterp()                     -- re-arm #2: the new chain is alive (fresh stamp)
    check("(ge) the next re-arm is a no-op against the fresh chain", KCD2MP.interpGen == gen0 + 1 and #TIMERS == nT2)
    -- the new chain's first fire carries the new generation
    local newChain = TIMERS[nT2 - 1].ms == 20 and TIMERS[nT2 - 1] or TIMERS[nT2]
    NOW = NOW + 0.02
    local nLog2 = #LOG
    newChain.f()
    check("(ge) the restarted chain runs under the current generation (no leak line)",
        countLog("GHOST CHAIN LEAK CONFIRMED", nLog2) == 0)
    noErrs("(ge)")
end

-- -------------------------------------------- (gg) the menu pump entry
do
    local e = resetGhost("1", 0, 0, 0)
    local gen = KCD2MP.interpGen
    NOW = 10.0; pkt("1", 0, 0, 0); chainTick(gen)
    NOW = 10.05; pkt("1", 0.5, 0, 0)
    local nT = #TIMERS
    local stamp = KCD2MP._interpAliveAt
    -- the render target is the packet plus the WO-38 DR lookahead (<= 60 ms
    -- of the estimated velocity); a fire may approach it, never pass it.
    local ceiling = 0.5 + (KCD2MP.ghosts["1"].istate.vx or 0) * 0.060 + 1e-9
    NOW = 10.07; pumpTick()
    check("(gg) a pumped fire renders (moved toward the packet, not past the DR target)", e.px > 0 and e.px <= ceiling,
        fmt(e.px) .. " <= " .. fmt(ceiling))
    check("(gg) a pumped fire never reschedules", #TIMERS == nT)
    check("(gg) a pumped fire never stamps the chain alive", KCD2MP._interpAliveAt == stamp)
    -- pumped fires at 80 Hz do not run away: 8 pumps over 100 ms still end
    -- inside the DR target (each fire is time-scaled, not "one tick")
    NOW = 10.10; pkt("1", 0.5, 0, 0)
    ceiling = 0.5 + (KCD2MP.ghosts["1"].istate.vx or 0) * 0.060 + 1e-9
    for k = 1, 8 do NOW = 10.10 + k * 0.0125; pumpTick() end
    check("(gg) 80 Hz pumping does not overshoot the DR target", e.px <= ceiling, fmt(e.px) .. " <= " .. fmt(ceiling))
    noErrs("(gg)")
end

OUT = table.concat(RESULTS, "\n")
