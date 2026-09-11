-- WO-77 synthetic stream test for the NPC puppet renderer (kdcmp.lua's
-- KCD2MP_ApplyNpcState / KCD2MP_NpcPuppetTick). Driven by
-- Test-NpcSmoothSynthetic.ps1, which splices the real kdcmp.lua in at the
-- KDCMP splice marker below and runs the whole thing under MoonSharp with the
-- engine stubbed out. No game, relay or agent involved: this proves the
-- MATH of the renderer against known sample sequences, nothing about how it
-- looks on screen or how WO-60's claims behave under two-player pressure.
--
-- Part 1 (before the marker): engine stubs + a fake clock. Must precede
-- kdcmp.lua because it references System/Script/os.clock at load time.

NOW = 0                                  -- the fake wall clock, seconds
os.clock = function() return NOW end
LOG = {}; TIMERS = {}; ENTS = {}; ERRS = {}

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
Game = mkstub(); AI = mkstub(); Sound = mkstub(); UIAction = mkstub()

-- kdcmp.lua wraps every engine call in pcall, which would swallow a renderer
-- bug silently. Record what it swallows so the test can assert none.
local rawpcall = pcall
pcall = function(f, ...)
    local r = { rawpcall(f, ...) }
    if not r[1] then ERRS[#ERRS + 1] = tostring(r[2]) end
    return unpack(r)
end

-- @@KDCMP@@

-- Part 2: scenarios. Everything below runs after kdcmp.lua has loaded.

local RESULTS = {}
local function check(name, ok, detail)
    RESULTS[#RESULTS + 1] = (ok and "PASS  " or "FAIL  ") .. name .. (detail and ("  [" .. detail .. "]") or "")
end
local function near(a, b, eps) return math.abs(a - b) <= (eps or 1e-6) end
local function fmt(v) return string.format("%.5f", v) end

local function mkEntity(name, x, y, z)
    local e = { class = "NPC", id = 4660, px = x, py = y, pz = z, rz = 0, writes = {}, anims = {} }
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
    return e
end

local function reset(name, x, y, z)
    KCD2MP.npcPuppets = {}
    KCD2MP.npcPuppetRunning = false
    KCD2MP._npcPuppetAliveAt = nil
    KCD2MP._npcPuppetPumpAt = nil
    KCD2MP._chainLeakSeen = {}
    ENTS = {}
    local e = mkEntity(name, x, y, z)
    ENTS[name] = e
    ERRS = {}
    return e
end
local function pkt(name, x, y, z, rot) KCD2MP_ApplyNpcState(name, x, y, z, rot or 0, 100, 0) end
local function tick() KCD2MP_NpcPuppetTick("ext") end          -- the menu-pump entry: no reschedule
local function chainTick(gen) KCD2MP_NpcPuppetTick(nil, gen) end -- a real timer chain's entry
local function animTransitions(name, fromLog)
    local n = 0
    for i = fromLog + 1, #LOG do
        if LOG[i]:find("NPC-SYNC anim " .. name .. " ", 1, true) then n = n + 1 end
    end
    return n
end
local function noErrs(label)
    check(label .. ": no swallowed Lua errors in the render path", #ERRS == 0, ERRS[1])
end

local DELAY = KCD2MP_NpcSmoothDelayS()

-- ---------------------------------------------------------------- (d) DELAY
check("(d) emitMs is 100 ms after WO-77 Step 2", KCD2MP.npcSync.emitMs == 100, tostring(KCD2MP.npcSync.emitMs))
check("(d) DELAY derives as 1.2 x emitMs = 0.120 s", near(DELAY, 0.12), fmt(DELAY))
do
    local saved = KCD2MP.npcSync.emitMs
    KCD2MP.npcSync.emitMs = 250
    check("(d) DELAY tracks a changed emitMs (250 -> 0.300 s)", near(KCD2MP_NpcSmoothDelayS(), 0.30), fmt(KCD2MP_NpcSmoothDelayS()))
    KCD2MP.npcSync.emitMs = saved
    KCD2MP.npcSyncRunning = false
    local nT = #TIMERS
    KCD2MP_StartNpcSync()
    check("(d) the emit tick is scheduled at emitMs (100 ms)", #TIMERS == nT + 1 and TIMERS[#TIMERS].ms == 100,
        tostring(TIMERS[#TIMERS] and TIMERS[#TIMERS].ms))
    KCD2MP.npcSyncRunning = false
end
check("mp_npc_smooth defaults ON", KCD2MP.npcSmooth == true)

-- --------------------------------------------- (a) steady stream, 1.5 m/s
-- Packets every 100 ms (x = v*t), ticks every 50 ms, 0..2.0 s.
local V = 1.5
local A_last = {}       -- per-step last written x, for the D3 comparison
do
    local e = reset("npc_a", 0, 0, 0)
    local logStart = #LOG
    local okPos, okDelta, prevX, firstBad = true, true, nil, nil
    for i = 0, 40 do
        NOW = i * 0.05
        if i % 2 == 0 then pkt("npc_a", V * NOW, 0, 0) end
        tick()
        A_last[i] = e.px
        if NOW >= 0.12 + 1e-9 then
            local want = V * (NOW - DELAY)
            if not near(e.px, want, 1e-6) then okPos = false; firstBad = firstBad or string.format("t=%.2f x=%s want=%s", NOW, fmt(e.px), fmt(want)) end
            if prevX and not near(e.px - prevX, V * 0.05, 1e-6) then okDelta = false end
        end
        if NOW >= 0.12 + 1e-9 then prevX = e.px end
    end
    check("(a) steady stream renders exactly v*(now - DELAY) at every tick", okPos, firstBad)
    check("(a) per-tick advance is constant (v * 50 ms), no decay inside packet gaps", okDelta)
    check("(a) exactly one anim transition (idle -> walk) over 2 s of walking",
        animTransitions("npc_a", logStart) == 1, tostring(animTransitions("npc_a", logStart)))
    check("(a) StartAnimation only on transition + 1 s keep-alive (<= 4 calls in 2 s)", #e.anims <= 4, tostring(#e.anims))
    noErrs("(a)")

    -- ------------------------------------------ (b) hold at newest, no overshoot
    -- Stream stops at t=2.0 (x=3.0). Tick on to 2.5 s.
    local logHold = #LOG
    local okHold, okNoOver, holdBad = true, true, nil
    for i = 41, 50 do
        NOW = i * 0.05
        tick()
        if e.px > 3.0 + 1e-9 then okNoOver = false end
        if NOW >= 2.0 + DELAY + 1e-9 and not near(e.px, 3.0, 1e-9) then okHold = false; holdBad = string.format("t=%.2f x=%s", NOW, fmt(e.px)) end
    end
    check("(b) never overshoots the newest sample after the stream stops", okNoOver, fmt(e.px))
    check("(b) holds exactly at the newest sample once renderAt passes it (no extrapolation)", okHold, holdBad)
    check("(b) anim settles to idle after the hold grace (one transition walk -> idle)",
        KCD2MP.npcPuppets["npc_a"].animTag == "idle" and animTransitions("npc_a", logHold) == 1,
        tostring(KCD2MP.npcPuppets["npc_a"].animTag) .. " transitions=" .. tostring(animTransitions("npc_a", logHold)))
    noErrs("(b)")
end

-- ------------------------------------------------ (c) D3: doubled chain
-- Same schedule as (a), but the tick fires 2x (and 3x on every 5th step) at
-- each time step through the real chain entry, plus once through a STALE
-- generation (a confirmed leaked chain, mp_npc_chainfix off). Every write at
-- a given time must equal (a)'s single-chain write: time-based advance makes
-- the extra chains no-ops instead of doubling the movement.
do
    local e = reset("npc_a", 0, 0, 0)
    KCD2MP.npcChainFix = false
    local okSame, okIntra, bad = true, true, nil
    for i = 0, 40 do
        NOW = i * 0.05
        if i % 2 == 0 then pkt("npc_a", V * NOW, 0, 0) end
        local gen = KCD2MP.npcPuppetGen
        local before = #e.writes
        chainTick(gen)
        chainTick(gen)
        if i % 5 == 0 then chainTick(gen) end
        chainTick(gen - 1)                       -- the leaked chain
        for w = before + 1, #e.writes do
            if not near(e.writes[w].x, A_last[i], 1e-9) then
                okIntra = false
                bad = bad or string.format("t=%.2f chainwrite=%s single=%s", NOW, fmt(e.writes[w].x), fmt(A_last[i]))
            end
        end
        if not near(e.px, A_last[i], 1e-9) then okSame = false end
    end
    check("(c) D3: 3-4 chains per tick render the SAME position as one chain at every step", okSame and okIntra, bad)
    check("(c) D3: total displacement identical to the single chain (not multiplied)", near(e.px, A_last[40], 1e-9),
        fmt(e.px) .. " vs " .. fmt(A_last[40]))
    local leakLogged = false
    for i = 1, #LOG do if LOG[i]:find("CHAIN LEAK CONFIRMED", 1, true) then leakLogged = true end end
    check("(c) the stale generation was recognised as a leak (instrument intact) yet wrote no different position", leakLogged)
    noErrs("(c)")
    KCD2MP.npcChainFix = true      -- WO-78: restore the shipped default for (j)
end

-- ------------------------------------ (e) jittered arrivals, no churn
-- Arrival gaps between 60 and 170 ms (mean ~104 ms); packets arrive BETWEEN
-- ticks, as the agent's ExecuteString batch really does.
do
    local e = reset("npc_j", 0, 0, 0)
    local gaps = { 0.10, 0.07, 0.13, 0.16, 0.09, 0.11, 0.17, 0.08, 0.10, 0.12, 0.06, 0.14, 0.10, 0.15, 0.09, 0.11, 0.13, 0.07, 0.10 }
    local events = {}
    local t = 0
    events[#events + 1] = { t = 0, kind = "pkt" }
    for _, g in ipairs(gaps) do t = t + g; events[#events + 1] = { t = t, kind = "pkt" } end
    local tEnd = t
    for i = 0, math.floor(tEnd / 0.05) do events[#events + 1] = { t = i * 0.05, kind = "tick" } end
    table.sort(events, function(a, b)
        if a.t == b.t then return a.kind == "pkt" and b.kind ~= "pkt" end   -- strict: pkt before tick at equal t
        return a.t < b.t
    end)
    local logStart = #LOG
    local okMono, okNoOver, prevX, newestX, holds, ticks = true, true, nil, 0, 0, 0
    for _, ev in ipairs(events) do
        NOW = ev.t
        if ev.kind == "pkt" then
            newestX = V * NOW
            pkt("npc_j", newestX, 0, 0)
        else
            tick(); ticks = ticks + 1
            if prevX and e.px < prevX - 1e-9 then okMono = false end
            if e.px > newestX + 1e-9 then okNoOver = false end
            -- A hold tick renders AT the newest sample (renderAt is past it).
            if NOW > 0.2 and near(e.px, newestX, 1e-9) then holds = holds + 1 end
            prevX = e.px
        end
    end
    check("(e) jitter: rendered x never moves backwards", okMono)
    check("(e) jitter: rendered x never passes the newest real sample", okNoOver)
    check("(e) jitter: gaps > DELAY did produce hold-at-newest ticks (the grace path was exercised)", holds > 0,
        string.format("%d of %d ticks held", holds, ticks))
    check("(e) jitter: exactly one anim transition despite gaps up to 170 ms (hold grace)",
        animTransitions("npc_j", logStart) == 1, tostring(animTransitions("npc_j", logStart)))
    noErrs("(e)")
end

-- ------------------------ (f) packet after a moved-gated silence
-- Idle at x=0 for 1.5 s, then one packet at x=0.4. The move must render as
-- a DELAY-long slide at 3.33 m/s, not a 1.5 s crawl.
do
    local e = reset("npc_s", 0, 0, 0)
    NOW = 0; pkt("npc_s", 0, 0, 0); tick()
    for i = 1, 29 do NOW = i * 0.05; tick() end
    NOW = 1.50; pkt("npc_s", 0.4, 0, 0); tick()
    local x150 = e.px
    NOW = 1.55; tick(); local x155 = e.px
    NOW = 1.60; tick(); local x160 = e.px
    NOW = 1.65; tick(); local x165 = e.px
    check("(f) silence then move: t+0 at start of the clipped segment", near(x150, 0, 1e-6), fmt(x150))
    check("(f) silence then move: 50 ms in = 0.4 * (0.05/0.12)", near(x155, 0.4 * (0.05 / 0.12), 1e-6), fmt(x155))
    check("(f) silence then move: 100 ms in = 0.4 * (0.10/0.12)", near(x160, 0.4 * (0.10 / 0.12), 1e-6), fmt(x160))
    check("(f) silence then move: complete and holding by 150 ms (no slow slide across the gap)", near(x165, 0.4, 1e-9), fmt(x165))
    check("(f) segment speed reads as run (0.4 m / 0.12 s = 3.33 m/s)", KCD2MP.npcPuppets["npc_s"].animTag == "run",
        tostring(KCD2MP.npcPuppets["npc_s"].animTag))
    noErrs("(f)")
end

-- ------------------------------------------------ (g) teleport snap
do
    local e = reset("npc_t", 0, 0, 0)
    NOW = 0; pkt("npc_t", 0, 0, 0); tick()
    NOW = 0.10; pkt("npc_t", 10, 0, 0); tick()
    check("(g) a >5 m step snaps immediately (never smoothed)", near(e.px, 10, 1e-9), fmt(e.px))
    check("(g) the ring is cleared to the snapped sample", #KCD2MP.npcPuppets["npc_t"].ring == 1, tostring(#KCD2MP.npcPuppets["npc_t"].ring))
    noErrs("(g)")
end

-- ------------------------------------------------ (h) yaw wraps short way
do
    local e = reset("npc_r", 0, 0, 0)
    NOW = 0; pkt("npc_r", 0, 0, 0, 3.0); tick()
    NOW = 0.10; pkt("npc_r", 0, 0, 0, -3.0)
    NOW = 0.15; tick(); local r1 = e.rz
    NOW = 0.20; tick(); local r2 = e.rz
    check("(h) yaw lerps the short way through +/-pi, not through 0", math.abs(r1) > 3.0 and math.abs(r2) > math.abs(r1),
        fmt(r1) .. " " .. fmt(r2))
    noErrs("(h)")
end

-- ------------------------------------------------ (i) toggle off = legacy
do
    local e = reset("npc_l", 0, 0, 0)
    local nLog = #LOG
    KCD2MP_SetNpcSmooth("off")
    check("(i) mp_npc_smooth off logs the derived delay", LOG[#LOG]:find("interp delay 120 ms", 1, true) ~= nil, LOG[#LOG])
    NOW = 0; pkt("npc_l", 0, 0, 0); tick()
    NOW = 0.10; pkt("npc_l", 1.0, 0, 0); tick()
    check("(i) legacy renderer: per-tick 0.5 lerp toward the packet (x = 0.5)", near(e.px, 0.5, 1e-9), fmt(e.px))
    KCD2MP_SetNpcSmooth("on")
    NOW = 0.15; tick()
    check("(i) toggling back on renders from the ring (x = v*(0.15-0.12) on the 0->1 m over 0.1 s segment)",
        near(e.px, 1.0 * (0.03 / 0.10), 1e-6), fmt(e.px))
    check("(i) mp_npc_smooth is on again", KCD2MP.npcSmooth == true)
    noErrs("(i)")
end

-- ------------------------------- (j) WO-78: the per-packet restart caller
-- The puppet chain's second entry is KCD2MP_ApplyNpcState -> StartNpcPuppet on
-- EVERY inbound packet. The 2026-09-11 field session showed it restarting
-- once per ~1 s of a menu/dialog/cutscene suspension (67 host starts vs 34
-- for the 2.5 s-re-armed chains). With the shared probe gate a stale stamp
-- during a suspension arms one probe and starts nothing, however many
-- packets arrive.
do
    local e = reset("npc_j", 0, 0, 0)
    check("(j) mp_npc_chainfix defaults ON since WO-78", KCD2MP.npcChainFix == true, tostring(KCD2MP.npcChainFix))
    KCD2MP._chainProbe = {}
    NOW = 20.0; pkt("npc_j", 0, 0, 0)                 -- starts the chain (flag was false)
    local gen0 = KCD2MP.npcPuppetGen
    check("(j) the first packet on a stopped chain starts it at once", KCD2MP.npcPuppetRunning == true and gen0 ~= nil)
    chainTick(gen0)                                   -- one real fire: stamps alive
    local nT, nLog = #TIMERS, #LOG
    NOW = 25.0                                        -- 5 s suspension: stamp stale, chain suspended
    for k = 1, 10 do pkt("npc_j", 0.1 * k, 0, 0) end  -- packets keep arriving via ExecuteString
    check("(j) 10 packets during a suspension start no new generation", KCD2MP.npcPuppetGen == gen0,
        tostring(gen0) .. " -> " .. tostring(KCD2MP.npcPuppetGen))
    check("(j) exactly one probe armed for all 10 packets", #TIMERS == nT + 1 and TIMERS[nT + 1].ms == 400, tostring(#TIMERS - nT))
    check("(j) no 'puppet tick started' logged", animTransitions("__none__", nLog) == 0 and
        (function() for i = nLog + 1, #LOG do if LOG[i]:find("puppet tick started", 1, true) then return false end end return true end)())
    -- resume: the chain fires first, then the probe hops
    chainTick(gen0)
    NOW = 25.4; for i = nT + 1, #TIMERS do local t = TIMERS[i]; if not t.fired and NOW >= t.at + t.ms/1000 - 1e-9 then t.fired = true; t.f() end end
    NOW = 25.6; for i = nT + 1, #TIMERS do local t = TIMERS[i]; if not t.fired and NOW >= t.at + t.ms/1000 - 1e-9 then t.fired = true; t.f() end end
    check("(j) the probe found the resumed chain alive ('suspended, not dead') and restarted nothing",
        KCD2MP.npcPuppetGen == gen0 and KCD2MP._chainProbe.puppet == nil and
        (function() for i = nLog + 1, #LOG do if LOG[i]:find("CHAIN puppet was suspended, not dead", 1, true) then return true end end return false end)())
    -- a real death: stale stamp, nothing refreshes it, packets arrive
    NOW = 40.0
    local nT2, nLog2 = #TIMERS, #LOG
    pkt("npc_j", 2.0, 0, 0)
    check("(j) after a real death the first packet arms a probe, does not restart yet", KCD2MP.npcPuppetGen == gen0 and #TIMERS == nT2 + 1)
    NOW = 40.4; for i = nT2 + 1, #TIMERS do local t = TIMERS[i]; if not t.fired and NOW >= t.at + t.ms/1000 - 1e-9 then t.fired = true; t.f() end end
    NOW = 40.6; for i = nT2 + 1, #TIMERS do local t = TIMERS[i]; if not t.fired and NOW >= t.at + t.ms/1000 - 1e-9 then t.fired = true; t.f() end end
    check("(j) the probe confirmed death and restarted the puppet chain exactly once",
        KCD2MP.npcPuppetGen == gen0 + 1 and
        (function() local n = 0; for i = nLog2 + 1, #LOG do if LOG[i]:find("puppet tick started", 1, true) then n = n + 1 end end return n == 1 end)())
    noErrs("(j)")
end

OUT = table.concat(RESULTS, "\n")
