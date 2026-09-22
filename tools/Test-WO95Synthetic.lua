-- WO-95 synthetic test for the NPC packet-cadence instrument.
--
-- The 2026-09-13 two-player session logged, on both machines, every five
-- seconds:
--
--   NPC-SYNC packet cadence: n=11 mean=2057ms min=1923ms max=2206ms
--     (receiver assumes emitter 100ms; apply tick is <mp_puppet_rate>ms; ...)
--
-- with a session mean-of-means of 1,738 ms (host) and 1,887 ms (joiner), and
-- not one five-second window under 100 ms. Read literally that says the NPC
-- stream is starved roughly 17x. It is not. The emitter sends a MOVING NPC
-- every `emitMs` (100 ms) and a STILL one every `heartbeatS` (2 s), and the
-- instrument averaged both together, so the mean it printed was really a
-- measure of how many tracked NPCs happened to be standing still. That is
-- the one number a jitter work order is supposed to tune against.
--
-- WO-95 splits them. This scenario proves the split against the real
-- kdcmp.lua:
--   (a) a stream of MOVING packets is measured at its true gap, and the
--       idle-heartbeat counter stays at zero
--   (b) a stream of STILL packets (position unchanged within moveEps) is
--       counted as idle-heartbeat only and never enters the mean
--   (c) a realistic mixture reports both, and the moving mean is the moving
--       cadence -- not dragged toward the heartbeat as it was before
--   (d) the motion/still decision uses moveEps, so sub-epsilon float noise
--       on a standing NPC is still a heartbeat
--   (e) a gap that spans a resume (> 5 s, a release / save load / menu) is
--       still dropped entirely, as WO-69 intended
--   (f) the transition packet (first motion after stillness) is not averaged
--       in -- only motion-to-motion gaps are
--   (g) the counters reset after each dump, and a dump happens even when the
--       window held nothing but heartbeats
--
-- Driven by Test-WO95Synthetic.ps1 through the WO-77 MoonSharp driver: the
-- real kdcmp.lua is spliced in at the marker below with the engine stubbed
-- and os.clock replaced by a fake clock. No game, relay or agent involved.
--
-- What this does NOT prove: what the real cadence in a live session is (that
-- is the next field log's job -- this only makes the number mean what it
-- says), nor anything about the renderer that consumes the packets.
--
-- Part 1 (before the marker): engine stubs + a fake clock.

NOW = 0                                  -- the fake wall clock, seconds
os.clock = function() return NOW end
LOG = {}; TIMERS = {}; ENTS = {}; ERRS = {}; TOASTS = {}; SPHERE = {}
CMDS = {}
DRAWS = {}
ORIG_ONACTION_CALLS = 0

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
System.RemoveEntity = function(eid)
    for n, e in pairs(ENTS) do if e.id == eid then ENTS[n] = nil end end
end
Script = mkstub()
Script.SetTimer = function(ms, f) TIMERS[#TIMERS + 1] = { ms = ms, f = f, at = NOW } end
Game = mkstub(); AI = mkstub(); Sound = mkstub(); Physics = mkstub(); Terrain = mkstub()
UIAction = mkstub()
UIAction.CallFunction = function(panel, inst, fn, text) TOASTS[#TOASTS + 1] = tostring(text) end
WORLD_T = 1000
Calendar = { GetWorldTime = function() return WORLD_T end, SetWorldTime = function(t) WORLD_T = t end }

local rawpcall = pcall
pcall = function(f, ...)
    local r = { rawpcall(f, ...) }
    if not r[1] then ERRS[#ERRS + 1] = tostring(r[2]) end
    return unpack(r)
end

PPOS = { x = 0, y = 0, z = 0 }
PDEAD = false
player = {
    GetWorldPos   = function() return { x = PPOS.x, y = PPOS.y, z = PPOS.z } end,
    GetWorldAngles = function() return { x = 0, y = 0, z = 0 } end,
    actor = { GetHealth = function() return 100 end,
              IsDead = function() return PDEAD end,
              IsUnconscious = function() return false end },
    human = { IsWeaponDrawn = function() return false end },
    inventory = { GetMoney = function() return 1000 end },
}
Player = { Client = { OnAction = function(...) ORIG_ONACTION_CALLS = ORIG_ONACTION_CALLS + 1 end } }

-- @@KDCMP@@

-- WO-102: these scenarios pin the 0.23.2 CLAIM model, which now ships as `mp_authority_host_off`
-- (host authority is the shipped default since WO-102; Test-WO102Synthetic.lua covers that side).
KCD2MP.wo102.authorityHost = false

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
local function noErrs(label)
    check(label .. ": no swallowed Lua errors", #ERRS == 0, ERRS[1])
    ERRS = {}
end

local NEXTID = 7000
local function mkEntity(name, x, y, z)
    NEXTID = NEXTID + 1
    local e = { id = NEXTID, px = x or 0, py = y or 0, pz = z or 0, rz = 0, writes = {}, anims = {},
                dead = false, ko = false, hp = 100, Properties = {}, AI = {}, inventory = mkstub() }
    e.GetName = function(self) return name end
    e.GetWorldPos = function(self) return { x = self.px, y = self.py, z = self.pz } end
    e.GetWorldAngles = function(self) return { x = 0, y = 0, z = self.rz } end
    e.SetWorldPos = function(self, p) self.px, self.py, self.pz = p.x, p.y, p.z end
    e.SetWorldAngles = function(self, a) self.rz = a.z end
    e.StartAnimation = function(self, layer, anim) self.anims[#self.anims + 1] = { anim = anim, at = NOW } end
    e.actor = setmetatable({ IsDead = function() return e.dead end, IsUnconscious = function() return e.ko end,
                             GetHealth = function() return e.hp end },
                           { __index = function(_, k) return function(...) return nil end end })
    e.human = { IsWeaponDrawn = function() return false end, DrawWeapon = function() return true end,
                HolsterWeapon = function() return true end }
    ENTS[name] = e
    return e
end


local ST = KCD2MP.npcPacketStats

-- Every cadence line since `mark`, aggregated. The dump rides the 5 s timer
-- inside KCD2MP_NpcPuppetTick, so a scenario longer than five seconds is
-- split across several lines; summing them measures the scenario rather than
-- whichever slice happened to land last.
local function stats(mark)
    local a = { n = 0, sum = 0, min = nil, max = nil, idle = 0, lines = 0 }
    for i = (mark or 0) + 1, #LOG do
        local l = LOG[i]
        if l:find("NPC-SYNC packet cadence", 1, true) then
            a.lines = a.lines + 1
            local n    = tonumber(l:match("moving n=(%d+)")) or 0
            local mean = tonumber(l:match("mean=(%d+)ms")) or 0
            local mn   = tonumber(l:match("min=(%d+)ms")) or 0
            local mx   = tonumber(l:match("max=(%d+)ms")) or 0
            a.idle = a.idle + (tonumber(l:match("idle%-heartbeat n=(%d+)")) or 0)
            if n > 0 then
                a.n = a.n + n
                a.sum = a.sum + n * mean
                if a.min == nil or mn < a.min then a.min = mn end
                if a.max == nil or mx > a.max then a.max = mx end
            end
        end
    end
    a.mean = (a.n > 0) and (a.sum / a.n) or 0
    a.min = a.min or 0
    a.max = a.max or 0
    return a
end

-- Reset everything the puppet path keeps between scenarios.
local function resetPuppets()
    KCD2MP.npcPuppets = {}; KCD2MP.npcPuppetRunning = false; KCD2MP._npcPuppetAliveAt = nil
    KCD2MP._npcPuppetRetired = {}; KCD2MP._chainProbe = {}; KCD2MP._npcDivergeUntil = {}
    KCD2MP._npcDeathSeen = {}; KCD2MP._npcDeathRemote = {}; KCD2MP._npcDeathDiverged = {}
    ST.n, ST.sum, ST.min, ST.max, ST.idleN, ST.dumpAt = 0, 0, 1e9, 0, 0, NOW
    ENTS = {}
    ERRS = {}
end

-- Feed `count` packets `gapS` apart; `step` metres of travel per packet
-- (0 = a still NPC, i.e. the emitter's idle heartbeat). Returns the last x so
-- a following phase can continue from the same place instead of teleporting.
local function feed(name, count, gapS, step, x0)
    local x = x0 or 0
    for _ = 1, count do
        NOW = NOW + gapS
        if step ~= 0 then x = x + step end
        KCD2MP_ApplyNpcState(name, x, 0, 0, 0, 100, 0)
        KCD2MP_NpcPuppetTick(nil, KCD2MP.npcPuppetGen)
    end
    return x
end

-- Push the final partial window out so `stats` sees every sample.
local function flush()
    NOW = NOW + 5.01
    KCD2MP_NpcPuppetTick(nil, KCD2MP.npcPuppetGen)
end

check("hooks: kdcmp.lua loaded and installed its player hooks", countLog("Player hooks OK") == 1)
check("config: the emitter still sends moving NPCs at 100 ms and still ones at 2 s",
    KCD2MP.npcSync.emitMs == 100 and KCD2MP.npcSync.heartbeatS == 2.0,
    tostring(KCD2MP.npcSync.emitMs) .. "/" .. tostring(KCD2MP.npcSync.heartbeatS))

-- ---------------------------------------------------------------------------
-- (a) A purely MOVING stream is measured at its true gap.
-- ---------------------------------------------------------------------------
do
    resetPuppets()
    mkEntity("mover", 0, 0, 0)
    local mark = #LOG
    feed("mover", 20, 0.100, 0.5)            -- 10 Hz, half a metre each
    flush()
    local s = stats(mark)
    check("(a) a 100 ms moving stream reports a ~100 ms mean", s.mean >= 95 and s.mean <= 105, s.mean)
    check("(a) ...every gap is counted once the first packet is classified", s.n == 18, s.n)
    check("(a) ...and no heartbeat is counted", s.idle == 0, s.idle)
    check("(a) ...min and max bracket the real gap", s.min >= 95 and s.max <= 105,
        tostring(s.min) .. ".." .. tostring(s.max))
    noErrs("(a)")
end

-- ---------------------------------------------------------------------------
-- (b) A purely STILL stream never enters the mean.
-- ---------------------------------------------------------------------------
do
    resetPuppets()
    mkEntity("stander", 10, 0, 0)
    local mark = #LOG
    feed("stander", 8, 2.0, 0, 10)            -- the 2 s heartbeat, not moving
    flush()
    local s = stats(mark)
    check("(b) a 2 s heartbeat stream reports no moving samples at all", s.n == 0, s.n)
    check("(b) ...they are all counted as idle heartbeats", s.idle == 6, s.idle)
    check("(b) ...and the mean does not report the heartbeat as a cadence", s.mean == 0, s.mean)
    noErrs("(b)")
end

-- ---------------------------------------------------------------------------
-- (c) The field's own mixture: this is the regression the fix exists for.
--     Before WO-95 a session like 2026-09-13 -- a handful of moving NPCs
--     among many standing ones -- printed a ~1,700 ms "cadence".
-- ---------------------------------------------------------------------------
do
    resetPuppets()
    mkEntity("walker", 0, 0, 0)
    for i = 1, 4 do mkEntity("idler" .. i, 50 + i, 0, 0) end
    local mark = #LOG
    -- 8 s of world: the walker streams at 10 Hz, four NPCs heartbeat at 2 s.
    local wx, nextBeat = 0, NOW + 2.0
    for _ = 1, 80 do
        NOW = NOW + 0.100
        wx = wx + 0.5
        KCD2MP_ApplyNpcState("walker", wx, 0, 0, 0, 100, 0)
        if NOW >= nextBeat then
            nextBeat = NOW + 2.0
            for i = 1, 4 do KCD2MP_ApplyNpcState("idler" .. i, 50 + i, 0, 0, 0, 100, 0) end
        end
        KCD2MP_NpcPuppetTick(nil, KCD2MP.npcPuppetGen)
    end
    flush()
    local s = stats(mark)
    check("(c) with 4 idlers against 1 walker, the moving mean is still the walker's ~100 ms",
        s.mean >= 95 and s.mean <= 105, s.mean)
    check("(c) ...the idlers are visible, but separately", s.idle >= 4, s.idle)
    check("(c) ...the printed line names both the emit interval and the heartbeat",
        (lastLog("NPC-SYNC packet cadence", mark) or ""):find("receiver assumes emitter 100ms, heartbeat 2000ms", 1, true) ~= nil,   -- WO-110 Phase 6: the label says whose number it is
        lastLog("NPC-SYNC packet cadence", mark))
    -- The pre-WO-95 behaviour, computed over the same window for contrast:
    -- one mean over motion and heartbeat together.
    local oldMean = (s.n * s.mean + s.idle * 2000) / (s.n + s.idle)
    check("(c) the old all-packets mean would have been dragged well above the real cadence",
        oldMean > s.mean * 1.5, string.format("old %.0fms vs %.0fms", oldMean, s.mean))
    noErrs("(c)")
end

-- ---------------------------------------------------------------------------
-- (d) moveEps decides, so float noise on a standing NPC is a heartbeat.
-- ---------------------------------------------------------------------------
do
    resetPuppets()
    mkEntity("jitterer", 20, 0, 0)
    local mark = #LOG
    local eps = KCD2MP.npcSync.moveEps
    for i = 1, 10 do
        NOW = NOW + 2.0
        local x = 20 + ((i % 2 == 0) and (eps * 0.4) or 0)   -- below the epsilon, both ways
        KCD2MP_ApplyNpcState("jitterer", x, 0, 0, 0, 100, 0)
        KCD2MP_NpcPuppetTick(nil, KCD2MP.npcPuppetGen)
    end
    flush()
    local s = stats(mark)
    check("(d) sub-moveEps wobble is a heartbeat, not motion", s.n == 0 and s.idle == 8,
        tostring(s.n) .. "/" .. tostring(s.idle))
    -- and a step just over the epsilon IS motion
    resetPuppets()
    mkEntity("creeper", 30, 0, 0)
    mark = #LOG
    feed("creeper", 6, 0.100, eps * 2.0, 30)
    flush()
    s = stats(mark)
    check("(d) a step just over moveEps counts as motion", s.n == 4 and s.idle == 0,
        tostring(s.n) .. "/" .. tostring(s.idle))
    noErrs("(d)")
end

-- ---------------------------------------------------------------------------
-- (e) WO-69's >5 s drop still stands (a release, a save load, a menu).
-- ---------------------------------------------------------------------------
do
    resetPuppets()
    mkEntity("resumer", 0, 0, 0)
    local mark = #LOG
    local x = feed("resumer", 4, 0.100, 0.5)
    NOW = NOW + 30.0                            -- a menu / save load / release
    x = x + 0.5
    KCD2MP_ApplyNpcState("resumer", x, 0, 0, 0, 100, 0)
    KCD2MP_NpcPuppetTick(nil, KCD2MP.npcPuppetGen)
    feed("resumer", 4, 0.100, 0.5, x)
    flush()
    local s = stats(mark)
    check("(e) the 30 s resume gap is dropped, not averaged in", s.max <= 105, s.max)
    check("(e) ...and the surrounding moving gaps are still counted", s.n == 6, s.n)
    noErrs("(e)")
end

-- ---------------------------------------------------------------------------
-- (f) Only motion-to-motion gaps are averaged: the packet that ENDS a still
--     stretch carries motion, but its gap is the stillness, not the cadence.
-- ---------------------------------------------------------------------------
do
    resetPuppets()
    mkEntity("waker", 0, 0, 0)
    local mark = #LOG
    feed("waker", 4, 2.0, 0, 0)                 -- standing, heartbeating
    feed("waker", 5, 0.100, 0.5, 0)             -- then walks off at 10 Hz
    flush()
    local s = stats(mark)
    check("(f) the first motion packet after stillness is not averaged in", s.max <= 105, s.max)
    check("(f) ...only the gaps between two moving packets are (4 of the 5)", s.n == 4, s.n)
    check("(f) ...and the still stretch is still visible as heartbeats", s.idle == 3, s.idle)
    noErrs("(f)")
end

-- ---------------------------------------------------------------------------
-- (g) The window resets, and a heartbeat-only window still reports.
-- ---------------------------------------------------------------------------
do
    resetPuppets()
    mkEntity("mixed", 0, 0, 0)
    local mark = #LOG
    local x = feed("mixed", 10, 0.100, 0.5)
    flush()
    local first = stats(mark)
    check("(g) the first window reports its moving samples", first.n == 8, first.n)
    local mark2 = #LOG
    feed("mixed", 3, 2.0, 0, x)                 -- now it stands still, where it stopped
    flush()
    local second = stats(mark2)
    check("(g) a window holding nothing but heartbeats still prints a line", second.lines > 0, second.lines)
    check("(g) ...with the previous window's moving samples cleared",
        second.n == 0 and second.mean == 0, tostring(second.n) .. "/" .. tostring(second.mean))
    -- One, not two: the 5 s flush exceeded npcSync.releaseS, so the puppet was
    -- released and the first packet after it is a fresh, unclassified one --
    -- the same reset WO-69's >5 s drop exists for, reached the other way.
    check("(g) ...and its own heartbeats counted, after the release reset one", second.idle == 1, second.idle)
    check("(g) the counters are clear again after the dump",
        ST.n == 0 and ST.sum == 0 and (ST.idleN or 0) == 0, tostring(ST.n) .. "/" .. tostring(ST.idleN))
    noErrs("(g)")
end

OUT = table.concat(RESULTS, "\n")
